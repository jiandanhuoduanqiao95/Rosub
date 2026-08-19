/// 聊天主界面
///
/// 布局：左侧边栏（好友/群组列表）+ 右侧聊天区域
/// 管理员可见额外"管理面板"按钮

import 'dart:async';

import 'package:flutter/material.dart';

import '../models/chat_models.dart';
import '../services/ime_bridge.dart';
import '../services/session_store.dart';
import '../services/socket_service.dart';
import '../services/state_manager.dart';
import '../services/taskbar_notifier.dart';
import '../widgets/chat_view.dart';
import '../widgets/dialogs.dart';
import '../widgets/raw_text_field.dart';
import '../widgets/sidebar.dart';

class ChatScreen extends StatefulWidget {
  final SocketService socketService;

  const ChatScreen({super.key, required this.socketService});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _state = AppState.instance;
  final _inputCtrl = TextEditingController();

  /// 阶段 K2：草稿自动保存防抖（输入停顿后同步服务端）
  Timer? _draftDebounce;

  /// 阶段 K3（P-16 修订）：免打扰到期巡检（每 30s 检查一次，
  /// 到期自动关闭免打扰开关并 SnackBar 提醒——声音通道随即恢复）
  Timer? _dndExpiryTimer;

  @override
  void initState() {
    super.initState();
    _state.addListener(_onStateChanged);
    _dndExpiryTimer = Timer.periodic(
        const Duration(seconds: 30), (_) => _checkDndExpiry());
  }

  @override
  void dispose() {
    _draftDebounce?.cancel();
    _dndExpiryTimer?.cancel();
    _state.removeListener(_onStateChanged);
    _inputCtrl.dispose();
    // ChatScreen 退出时释放 IME 桥接焦点，但保留进程（后续登录界面可能需要）
    ImeBridgeManager.instance.releaseFocus();
    super.dispose();
  }

  /// 免打扰到期检查：到期 → 自动关闭开关 + 提醒用户
  void _checkDndExpiry() {
    if (TaskbarNotifier.checkDndExpiry()) {
      _state.showNotice('免打扰时段已结束，已自动关闭免打扰');
    }
  }

  /// 阶段 K2：输入变化 → 立即写本地草稿状态 + 防抖同步服务端
  /// （修复：仅在切换会话/发送时才同步 → 输入后直接退出草稿丢失）
  /// 系统消息会话（'服务器'）只读：不写草稿元数据、不同步服务端，
  /// 否则 set_draft {peer_key='服务器'} 会被服务端按非好友拒绝，
  /// 弹出"错误：服务器 不是您的好友"（P-46 缺陷修复）
  void _onInputChanged(String text) {
    final key = _state.currentChat;
    if (key == null || key == '服务器') return;
    _state.setConversationDraft(key, text);
    _draftDebounce?.cancel();
    _draftDebounce = Timer(const Duration(milliseconds: 800), () {
      if (!_state.isLoggedIn) return;
      widget.socketService.saveConversationDraft(key, text);
    });
  }

  /// 立即同步当前输入为草稿（切换会话/发送/退出前调用），并取消防抖
  /// 系统消息会话（'服务器'）只读：不触发草稿同步（P-46 缺陷修复）
  void _flushDraft() {
    final key = _state.currentChat;
    if (key == null || key == '服务器') return;
    _draftDebounce?.cancel();
    _draftDebounce = null;
    widget.socketService.saveConversationDraft(key, _inputCtrl.text);
  }

  void _onStateChanged() {
    // 展示临时通知（操作确认、错误、强制下线提示等），先于登出跳转
    while (_state.noticeQueue.isNotEmpty) {
      final notice = _state.noticeQueue.first;
      _state.consumeNotice();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(notice),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
    if (mounted && !_state.isLoggedIn) {
      // 被踢出或断开连接 → 返回登录
      Navigator.of(context).pushReplacementNamed('/login');
      return;
    }
  }

  void _sendMessage() {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty) return;

    final current = _state.currentChat;
    if (current == null || current == '服务器') return;

    if (current.startsWith('group_')) {
      final groupId = int.tryParse(current.substring(6));
      if (groupId != null) {
        widget.socketService.sendGroupChat(groupId, text);
      }
    } else {
      widget.socketService.sendChat(current, text);
    }

    _draftDebounce?.cancel();
    _inputCtrl.clear();
    // 阶段 K2：发送后清除草稿（本地状态经 onInputChanged 同步，服务端显式同步）
    _state.setConversationDraft(current, '');
    widget.socketService.saveConversationDraft(current, '');
  }

  void _sendFile() async {
    final current = _state.currentChat;
    if (current == null || current == '服务器') return;

    final result = await showFilePicker(context);
    if (result != null) {
      widget.socketService.sendFile(current, result.path, result.name);
    }
  }

  /// 拉取历史消息（阶段 E 上滑加载）
  Future<void> _loadHistory(String chatKey, String? beforeMessageId) async {
    if (chatKey == '服务器') return;
    if (chatKey.startsWith('group_')) {
      final groupId = int.tryParse(chatKey.substring(6));
      if (groupId != null) {
        await widget.socketService.fetchHistory(
          groupId: groupId,
          beforeMessageId: beforeMessageId,
        );
      }
    } else {
      await widget.socketService.fetchHistory(
        to: chatKey,
        beforeMessageId: beforeMessageId,
      );
    }
  }

  /// 发起消息搜索（阶段 H5）：私聊限定会话，群聊按 group_id；系统会话无搜索入口
  void _runSearch(String keyword) {
    final current = _state.currentChat;
    if (current == null || current == '服务器') return;
    if (current.startsWith('group_')) {
      final groupId = int.tryParse(current.substring(6));
      if (groupId != null) {
        widget.socketService.searchHistory(keyword, groupId: groupId);
      }
    } else {
      widget.socketService.searchHistory(keyword, to: current);
    }
  }

  /// 退出搜索模式（阶段 H5）
  void _exitSearch() {
    final current = _state.currentChat;
    if (current != null) {
      _state.clearSearchResults(current);
    }
  }

  /// 选中会话时，仅当会话无消息时触发首次历史加载（阶段 E6）
  /// 已有消息（如离线消息）不重复加载，上滑加载由 ScrollController 负责
  void _maybeLoadInitialHistory(String chatKey) {
    if (chatKey == '服务器') return;
    if (!_state.hasMoreHistory(chatKey)) return;
    if (_state.getMessages(chatKey).isEmpty) {
      _loadHistory(chatKey, null);
    }
  }

  void _showAddFriendDialog() {
    // 阶段 J（P1-10）：添加好友 → 用户搜索对话框（搜索 + 验证消息 + 可选备注名）
    showUserSearchDialog(
      context,
      onSearch: (keyword) => widget.socketService.searchUsers(keyword),
      onAdd: (username, message, note) {
        widget.socketService.addFriend(username, message: message);
        // 阶段 J 修复：发送请求时询问的备注名暂存，对方接受后自动设置
        if (note.isNotEmpty) {
          _state.setPendingFriendNote(username, note);
        }
      },
    );
  }

  void _showCreateGroupDialog() {
    showCreateGroupDialog(context, (name) {
      widget.socketService.createGroup(name);
    });
  }

  void _showJoinGroupDialog() {
    showJoinGroupDialog(context, (id) {
      widget.socketService.joinGroup(id);
    });
  }

  void _showAdminPanel() {
    showAdminPanel(context, widget.socketService, _state);
  }

  void _showChangePasswordDialog() {
    showChangePasswordDialog(context, widget.socketService);
  }

  void _showFriendMenuDialog(String username) {
    // 阶段 J（P1-8/9）：长按好友 → 好友管理（资料/备注/分组/拉黑/删除）
    // 阶段 K（P1-11/13）：置顶/静音入口 + 乐观状态更新
    showFriendManageDialog(
      context,
      username,
      onViewProfile: () => _showProfileDialog(username),
      onSetNote: () => _showSetNoteDialog(username),
      onSetGroup: () => _showSetGroupDialog(username),
      onBlock: () => _showBlockConfirm(username),
      onUnblock: () => widget.socketService.unblockUser(username),
      // 删除确认文本已展示在管理对话框中，直接删除
      onDelete: () => widget.socketService.deleteFriend(username),
      pinned: _state.isPinned(username),
      muted: _state.isMuted(username),
      onTogglePin: (v) {
        _state.setConversationPinned(username, v);
        if (v) {
          widget.socketService.pinConversation(username);
        } else {
          widget.socketService.unpinConversation(username);
        }
      },
      onToggleMute: (v) {
        _state.setConversationMuted(username, v);
        widget.socketService.muteConversation(username, v);
      },
    );
  }

  void _showProfileDialog(String username) {
    widget.socketService.fetchProfile(username);
    showProfileDialog(
      context,
      username: username,
      profile: _state.profileOf(username),
      onRefresh: () => widget.socketService.fetchProfile(username),
      onEdit: username == _state.username ? _showEditProfileDialog : null,
    );
  }

  void _showEditProfileDialog() {
    final nicknameCtrl = TextEditingController(
        text: _state.profileOf(_state.username!)?.nickname ?? '');
    final signatureCtrl = TextEditingController(
        text: _state.profileOf(_state.username!)?.signature ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑资料'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RawTextField(
              controller: nicknameCtrl,
              hintText: '昵称',
              showChineseInput: true,
            ),
            const SizedBox(height: 8),
            RawTextField(
              controller: signatureCtrl,
              hintText: '个性签名',
              showChineseInput: true,
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              widget.socketService.updateMyProfile(
                nickname: nicknameCtrl.text.trim(),
                signature: signatureCtrl.text.trim(),
              );
              Navigator.pop(ctx);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _showBlockConfirm(String username) {
    showBlockConfirmDialog(context, username, () {
      widget.socketService.blockUser(username);
    });
  }

  void _showSetNoteDialog(String username) {
    showSetFriendNoteDialog(context, username, (note) {
      widget.socketService.setFriendNote(username, note);
    });
  }

  void _showSetGroupDialog(String username) {
    showSetFriendGroupDialog(context, username, (group) {
      widget.socketService.setFriendGroup(username, group);
    });
  }

  void _showGroupMenuDialog(ChatTarget target) {
    final groupId = int.tryParse(target.key.substring(6));
    if (groupId == null) return;
    final group = _state.groups.where((g) => g.id == groupId).firstOrNull;
    if (group == null) return;
    // 打开菜单即预取成员列表，使菜单中的人数实时更新
    widget.socketService.fetchGroupMembers(groupId);
    showGroupMenuDialog(
        context,
        group,
        (g) {
          showGroupInfoDialog(context, g);
        },
        (gid) {
          widget.socketService.leaveGroup(gid);
          _state.leaveGroup(gid);
        },
        // 阶段 K（P1-11/13）：群组置顶/静音入口 + 乐观状态更新
        pinned: _state.isPinned(target.key),
        muted: _state.isMuted(target.key),
        onTogglePin: (v) {
          _state.setConversationPinned(target.key, v);
          if (v) {
            widget.socketService.pinConversation(target.key);
          } else {
            widget.socketService.unpinConversation(target.key);
          }
        },
        onToggleMute: (v) {
          _state.setConversationMuted(target.key, v);
          widget.socketService.muteConversation(target.key, v);
        });
  }

  void _logout() {
    // 阶段 K2：退出前立即同步当前输入为草稿（防抖未触发时草稿不丢失）
    _flushDraft();
    widget.socketService.disconnect();
    // 退出登录：清除 session（H3/H4 修复），否则登录页 _initSession
    // 会读取残留 session 立即自动登录，把用户拉回聊天页导致无法退出
    SessionStore.clear();
    if (mounted) {
      Navigator.of(context).pushReplacementNamed('/login');
    }
  }

  Future<void> _confirmRecall(String messageId) async {
    final current = _state.currentChat;
    if (current == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('撤回消息'),
        content: const Text('确定撤回这条消息吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('撤回'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      widget.socketService.recallMessage(messageId, current);
    }
  }

  /// 阶段 K5（P1-2）：引用回复对话框
  Future<void> _showReplyMessageDialog(String messageId) async {
    final current = _state.currentChat;
    if (current == null || current == '服务器') return;
    final ctrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('引用回复'),
        content: RawTextField(
          controller: ctrl,
          hintText: '输入回复内容',
          showChineseInput: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('发送'),
          ),
        ],
      ),
    );
    if (confirmed == true && ctrl.text.trim().isNotEmpty) {
      widget.socketService.replyMessage(messageId, ctrl.text, current);
    }
  }

  /// 阶段 K5（P1-3）：转发目标选择对话框（好友 + 群组）
  Future<void> _showForwardTargetDialog(String messageId) async {
    final targets = [
      for (final f in _state.friends)
        ChatTarget(key: f, displayName: _state.displayNameForChat(f)),
      for (final g in _state.groups)
        ChatTarget(key: g.chatKey, displayName: g.displayName, isGroup: true),
    ];
    if (targets.isEmpty) {
      _state.showNotice('暂无可转发的好友或群组');
      return;
    }
    final target = await showDialog<ChatTarget>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('转发到'),
        content: SizedBox(
          width: 280,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final t in targets)
                ListTile(
                  dense: true,
                  leading: Icon(
                      t.isGroup ? Icons.group_rounded : Icons.person_rounded),
                  title: Text(t.displayName),
                  onTap: () => Navigator.pop(ctx, t),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (target != null) {
      widget.socketService.forwardMessage(messageId, target.key);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _state,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: Text('聊天室 - ${_state.username ?? ""}'),
            actions: [
              // 文件请求指示器
              if (_state.hasPendingFileRequests)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Badge(
                    label: Text('${_state.pendingFileRequests.length}'),
                    child: IconButton(
                      icon: const Icon(Icons.folder_rounded),
                      tooltip: '待处理文件请求',
                      onPressed: _showFileRequests,
                    ),
                  ),
                ),

              // 好友请求指示器
              if (_state.pendingRequests.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Badge(
                    label: Text('${_state.pendingRequests.length}'),
                    child: IconButton(
                      icon: const Icon(Icons.people_rounded),
                      tooltip: '待处理好友请求',
                      onPressed: _showFriendRequests,
                    ),
                  ),
                ),

              // 管理员面板
              if (_state.isAdmin)
                IconButton(
                  icon: const Icon(Icons.admin_panel_settings),
                  tooltip: '管理面板',
                  onPressed: _showAdminPanel,
                ),

              // 设置（阶段 K3：提示音/免打扰）
              IconButton(
                icon: const Icon(Icons.settings_rounded),
                tooltip: '设置',
                onPressed: () => showSettingsDialog(context),
              ),

              // 个人资料（阶段 J：P0-2）
              IconButton(
                icon: const Icon(Icons.account_circle_rounded),
                tooltip: '个人资料',
                onPressed: () => _showProfileDialog(_state.username!),
              ),

              // 修改密码（阶段 G3）
              IconButton(
                icon: const Icon(Icons.lock_outline_rounded),
                tooltip: '修改密码',
                onPressed: _showChangePasswordDialog,
              ),

              // 退出
              IconButton(
                icon: const Icon(Icons.logout),
                tooltip: '退出',
                onPressed: _logout,
              ),
            ],
          ),
          body: Column(
            children: [
              // === 重连中横幅 ===
              if (_state.connectionStatus == ConnectionStatus.reconnecting)
                Material(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '连接断开，正在重连…'
                            '（第 ${_state.reconnectAttempts} 次）',
                            style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onErrorContainer),
                          ),
                        ),
                        TextButton(
                          onPressed: _logout,
                          child: const Text('退出'),
                        ),
                      ],
                    ),
                  ),
                ),
              Expanded(
                child: Row(
                  children: [
                    // === 左侧：会话列表 ===
                    Sidebar(
                      chatTargets: _state.chatTargets,
                      currentChat: _state.currentChat,
                      onSelectChat: (key) {
                        // 阶段 K2：切换会话前同步保存旧会话草稿（本地 + 服务端），
                        // 再恢复新会话草稿到输入栏（先 selectChat，避免草稿回写
                        // 到旧会话）
                        // 系统消息会话（'服务器'）只读：不写本地草稿元数据（P-46 缺陷修复）
                        final previous = _state.currentChat;
                        if (previous != null &&
                            previous != key &&
                            previous != '服务器') {
                          _state.setConversationDraft(previous, _inputCtrl.text);
                          _flushDraft();
                        }
                        _state.selectChat(key);
                        _inputCtrl.text = _state.draftOf(key);
                        _maybeLoadInitialHistory(key);
                      },
                      onAddFriend: _showAddFriendDialog,
                      onCreateGroup: _showCreateGroupDialog,
                      onJoinGroup: _showJoinGroupDialog,
                      unreadOf: _state.unreadOf,
                      onDeleteFriend: _showFriendMenuDialog,
                      onGroupLongPress: _showGroupMenuDialog,
                      isOnline: _state.isOnline,
                      friendGroups: _state.friendsByGroup,
                      isPinned: _state.isPinned,
                      isMuted: _state.isMuted,
                    ),

                    // 分隔线
                    const VerticalDivider(width: 1),

                    // === 右侧：聊天区域 ===
                    Expanded(
                      child: _state.currentChat != null
                          ? ChatView(
                              chatKey: _state.currentChat!,
                              chatTitle: _state
                                  .displayNameForChat(_state.currentChat!),
                              messages: _state.isSearchMode(_state.currentChat!)
                                  ? _state.searchResults(_state.currentChat!)
                                  : _state.getMessages(_state.currentChat!),
                              username: _state.username!,
                              inputCtrl: _inputCtrl,
                              canSend: _state.currentChat != '服务器',
                              onSend: _sendMessage,
                              onSendFile: _sendFile,
                              onRecall: _confirmRecall,
                              onLoadHistory: (beforeId) =>
                                  _loadHistory(_state.currentChat!, beforeId),
                              hasMoreHistory: _state.hasMoreHistory,
                              transferFraction: _state.transferFraction,
                              isSearchMode:
                                  _state.isSearchMode(_state.currentChat!),
                              searchQuery:
                                  _state.searchQueryOf(_state.currentChat!),
                              onSearch: _runSearch,
                              onSearchExit: _exitSearch,
                              onRetrySend: (messageId) => widget.socketService
                                  .retryPendingMessage(messageId),
                              // 阶段 K2：输入变化 → 本地草稿状态 + 防抖自动保存
                              onInputChanged: _onInputChanged,
                              // 阶段 K5：消息操作（引用/转发/表情/仅我删除）
                              onReplyMessage: _showReplyMessageDialog,
                              onForwardMessage: _showForwardTargetDialog,
                              onAddReaction: (messageId, emoji) {
                                final key = _state.currentChat;
                                if (key != null) {
                                  widget.socketService
                                      .addReaction(messageId, emoji, key);
                                }
                              },
                              onDeleteMessage: (messageId) {
                                final key = _state.currentChat;
                                if (key != null) {
                                  _state.removeMessageLocally(key, messageId);
                                }
                              },
                            )
                          : const Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.chat_rounded,
                                      size: 64, color: Colors.grey),
                                  SizedBox(height: 16),
                                  Text(
                                    '选择一个会话开始聊天',
                                    style: TextStyle(
                                        color: Colors.grey, fontSize: 16),
                                  ),
                                ],
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showFriendRequests() {
    showFriendRequestsDialog(context, _state.pendingRequests.toList(),
        (username, accept, note) {
      if (accept) {
        widget.socketService.acceptFriend(username);
        // 阶段 J：接受时填写的备注 → 设置好友备注名
        if (note.isNotEmpty) {
          widget.socketService.setFriendNote(username, note);
        }
      } else {
        widget.socketService.rejectFriend(username);
      }
    });
  }

  void _showFileRequests() {
    showFileRequestsDialog(context, _state.pendingFileRequests.toList(),
        (request, accept) {
      if (request.isGroupFile) {
        widget.socketService.respondGroupFileRequest(
          request.messageId,
          request.groupId!,
          accept,
        );
      } else {
        widget.socketService.respondFileRequest(
          request.messageId,
          request.sender,
          accept,
        );
      }
    });
  }
}
