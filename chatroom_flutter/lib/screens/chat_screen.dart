/// 聊天主界面
///
/// 布局：左侧边栏（好友/群组列表）+ 右侧聊天区域
/// 管理员可见额外"管理面板"按钮

import 'package:flutter/material.dart';

import '../models/chat_models.dart';
import '../services/ime_bridge.dart';
import '../services/socket_service.dart';
import '../services/state_manager.dart';
import '../widgets/chat_view.dart';
import '../widgets/dialogs.dart';
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

  @override
  void initState() {
    super.initState();
    _state.addListener(_onStateChanged);
  }

  @override
  void dispose() {
    _state.removeListener(_onStateChanged);
    _inputCtrl.dispose();
    // ChatScreen 退出时释放 IME 桥接焦点，但保留进程（后续登录界面可能需要）
    ImeBridgeManager.instance.releaseFocus();
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted && !_state.isLoggedIn) {
      // 被踢出或断开连接 → 返回登录
      Navigator.of(context).pushReplacementNamed('/login');
      return;
    }
    // 展示临时通知（操作确认、错误等），不进入系统消息会话
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

    _inputCtrl.clear();
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
    showAddFriendDialog(context, (username) {
      widget.socketService.addFriend(username);
    });
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

  void _showDeleteFriendDialog(String username) {
    showDeleteFriendDialog(context, username, () {
      widget.socketService.deleteFriend(username);
    });
  }

  void _showGroupMenuDialog(ChatTarget target) {
    final groupId = int.tryParse(target.key.substring(6));
    if (groupId == null) return;
    final group = _state.groups.where((g) => g.id == groupId).firstOrNull;
    if (group == null) return;
    // 打开菜单即预取成员列表，使菜单中的人数实时更新
    widget.socketService.fetchGroupMembers(groupId);
    showGroupMenuDialog(context, group, (g) {
      showGroupInfoDialog(context, g);
    }, (gid) {
      widget.socketService.leaveGroup(gid);
      _state.leaveGroup(gid);
    });
  }

  void _logout() {
    widget.socketService.disconnect();
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
                        _state.selectChat(key);
                        _maybeLoadInitialHistory(key);
                      },
                      onAddFriend: _showAddFriendDialog,
                      onCreateGroup: _showCreateGroupDialog,
                      onJoinGroup: _showJoinGroupDialog,
                      unreadOf: _state.unreadOf,
                      onDeleteFriend: _showDeleteFriendDialog,
                      onGroupLongPress: _showGroupMenuDialog,
                    ),

                    // 分隔线
                    const VerticalDivider(width: 1),

                    // === 右侧：聊天区域 ===
                    Expanded(
                      child: _state.currentChat != null
                          ? ChatView(
                              chatKey: _state.currentChat!,
                              chatTitle:
                                  _state.displayNameForChat(_state.currentChat!),
                              messages: _state.getMessages(_state.currentChat!),
                              username: _state.username!,
                              inputCtrl: _inputCtrl,
                              canSend: _state.currentChat != '服务器' &&
                                  _state.connectionStatus !=
                                      ConnectionStatus.reconnecting,
                              onSend: _sendMessage,
                              onSendFile: _sendFile,
                              onRecall: _confirmRecall,
                              onLoadHistory: (beforeId) => _loadHistory(
                                  _state.currentChat!, beforeId),
                              hasMoreHistory: _state.hasMoreHistory,
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
        (username, accept) {
      if (accept) {
        widget.socketService.acceptFriend(username);
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
