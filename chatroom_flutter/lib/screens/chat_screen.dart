/// 聊天主界面
///
/// 布局：左侧边栏（好友/群组列表）+ 右侧聊天区域
/// 管理员可见额外"管理面板"按钮

import 'dart:async';

import 'package:flutter/material.dart';

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../config.dart';
import '../l10n/app_strings.dart';
import '../models/chat_models.dart';
import '../services/chat_exporter.dart';
import '../services/file_drop.dart';
import '../services/ime_bridge.dart';
import '../services/session_store.dart';
import '../services/socket_service.dart';
import '../services/sticker_store.dart';
import '../services/theme_settings.dart';
import '../services/state_manager.dart';
import '../services/taskbar_notifier.dart';
import '../widgets/chat_view.dart';
import '../widgets/dialogs.dart';
import '../widgets/image_annotation_editor.dart';
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

  /// 阶段 M2：群邀请以入口保留（AppBar badge + 列表对话框），无即时弹窗

  @override
  void initState() {
    super.initState();
    _state.addListener(_onStateChanged);
    _dndExpiryTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => _checkDndExpiry());
    // 阶段 N3（P2-4 文件拖拽发送）：接收 GTK 拖入的文件路径
    FileDrop.instance.ensureListening();
    FileDrop.instance.setOnFilesDropped(_onFilesDropped);
    // 阶段 O1 修订（2026-08-31 多公告并存）：进入聊天页时对当前会话
    // （重连恢复场景）拉取群公告历史
    final initial = _state.currentChat;
    if (initial != null) {
      _maybeFetchGroupAnnouncements(initial);
    }
  }

  @override
  void dispose() {
    FileDrop.instance.setOnFilesDropped(null);
    _draftDebounce?.cancel();
    _dndExpiryTimer?.cancel();
    _state.removeListener(_onStateChanged);
    _inputCtrl.dispose();
    // ChatScreen 退出时释放 IME 桥接焦点，但保留进程（后续登录界面可能需要）
    ImeBridgeManager.instance.releaseFocus();
    super.dispose();
  }

  /// 阶段 N3（P2-4 文件拖拽发送）：拖入文件 → 既有上传通道
  /// （sendFile 依据大小自动走 M8 大文件分流；系统会话只读不发送）。
  /// R-P5 修订：图片文件自动进入标注编辑器（编辑后发送或直接发送原图）
  Future<void> _onFilesDropped(List<String> paths) async {
    final key = _state.currentChat;
    if (key == null || key == '服务器' || paths.isEmpty) return;
    for (final path in paths) {
      final name = path.split(RegExp(r'[/\\]')).last;
      if (name.isEmpty || name == '.' || name == '..') continue;
      if (isImageFilename(name)) {
        try {
          final bytes = await File(path).readAsBytes();
          await _sendImageWithEditor(bytes, filename: name, filePath: path);
        } catch (_) {
          widget.socketService.sendFile(key, path, name);
        }
      } else {
        widget.socketService.sendFile(key, path, name);
      }
    }
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

  /// 阶段 O4（快捷回复）/ O5（定时消息前置）：向指定会话发送既定文本
  /// （不经输入框，不清草稿）
  void _sendTextTo(String chatKey, String text) {
    if (text.trim().isEmpty) return;
    if (chatKey.startsWith('group_')) {
      final groupId = int.tryParse(chatKey.substring(6));
      if (groupId != null) {
        widget.socketService.sendGroupChat(groupId, text);
      }
    } else {
      widget.socketService.sendChat(chatKey, text);
    }
  }

  Future<void> _sendFile() async {
    final current = _state.currentChat;
    if (current == null || current == '服务器') return;

    final result = await showFilePicker(context);
    if (result != null) {
      // R-P5 修订：图片文件自动进入标注编辑器（编辑后发送或直接发送原图）
      if (isImageFilename(result.name)) {
        try {
          final bytes = await File(result.path).readAsBytes();
          await _sendImageWithEditor(bytes,
              filename: result.name, filePath: result.path);
        } catch (_) {
          widget.socketService.sendFile(current, result.path, result.name);
        }
      } else {
        widget.socketService.sendFile(current, result.path, result.name);
      }
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
  /// 阶段 O1 修订（2026-08-31 多公告并存）：选中群会话时拉取该群公告历史
  /// （横幅逐条显示；实时推送经 addGroupAnnouncement 追加）
  void _maybeFetchGroupAnnouncements(String chatKey) {
    if (chatKey == '服务器' || !chatKey.startsWith('group_')) return;
    final groupId = int.tryParse(chatKey.substring(6));
    if (groupId != null) {
      widget.socketService.fetchGroupAnnouncements(groupId);
    }
  }

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
    // 阶段 M（P-11 用户反馈）：群组搜索入口 + 申请制（输入群组 ID 也走审批）
    showGroupSearchDialog(
      context,
      onSearch: (keyword) => widget.socketService.searchGroups(keyword),
      onRequestJoin: (id, message) =>
          widget.socketService.requestJoinGroup(id, message: message),
    );
  }

  /// 阶段 M2：群邀请入口列表（接受/拒绝）
  void _showGroupInvites() {
    showGroupInvitesDialog(
      context,
      invites: _state.invitations.toList(),
      onRespond: (invite, accept) {
        if (accept) {
          widget.socketService.acceptGroupInvite(invite.groupId);
        } else {
          widget.socketService.declineGroupInvite(invite.groupId);
        }
        _state.removeInvitation(invite.groupId);
      },
    );
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
        },
        // 阶段 M1：群主可见"群管理"入口（踢人/转让/改名/头像/审批/邀请）
        onAdmin: _state.isGroupOwner(groupId)
            ? () => showGroupAdminDialog(context, group, widget.socketService)
            : null,
        // 阶段 O1：群主可见"群公告"编辑入口
        onAnnouncement: _state.isGroupOwner(groupId)
            ? () => _showGroupAnnouncementDialog(group)
            : null);
  }

  /// 阶段 O1/O2：当前选中会话对应的群组（私聊/系统会话为 null）
  Group? get _currentGroup {
    final key = _state.currentChat;
    if (key == null || !key.startsWith('group_')) return null;
    final groupId = int.tryParse(key.substring(6));
    if (groupId == null) return null;
    return _state.groups.where((g) => g.id == groupId).firstOrNull;
  }

  /// 阶段 O2：当前用户可置顶当前群会话的消息（群主 + 群会话）
  bool get _canPinCurrent {
    final group = _currentGroup;
    if (group == null) return false;
    return _state.isGroupOwner(group.id);
  }

  /// 阶段 O1（群公告）：群主公告管理（发布公告 / 清除公告）
  void _showGroupAnnouncementDialog(Group group) {
    showGroupAnnouncementDialog(
      context,
      initial: group.announcement,
      onConfirm: (text) {
        widget.socketService.setGroupAnnouncement(group.id, text);
      },
      onListAnnouncements: () {
        widget.socketService.fetchGroupAnnouncements(group.id);
      },
      onDelete: (messageId) {
        widget.socketService.deleteGroupAnnouncement(group.id, messageId);
        _state.removeGroupAnnouncement(messageId);
        widget.socketService.fetchGroupAnnouncements(group.id);
      },
    );
  }

  /// 阶段 O4（快捷回复）：常用语面板，点击即发送到当前会话
  void _showQuickReplyPanel() {
    final current = _state.currentChat;
    if (current == null || current == '服务器') return;
    showQuickReplyPanel(
      context,
      onSend: (phrase) => _sendTextTo(current, phrase),
    );
  }

  /// 阶段 O5（定时发送，2026-08-30 用户反馈 #7）：定时入口两选项——
  /// 「定时设定」（预约对话框）/「取消定时设定」（定时任务管理列表）
  void _showScheduleDialog() {
    final current = _state.currentChat;
    if (current == null || current == '服务器') return;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.schedule_rounded),
              title: const Text('定时设定'),
              onTap: () {
                Navigator.pop(ctx);
                _openScheduleMessageDialog(current);
              },
            ),
            ListTile(
              leading: const Icon(Icons.manage_history_rounded),
              title: const Text('取消定时设定'),
              onTap: () {
                Navigator.pop(ctx);
                showScheduledManageDialog(
                  context,
                  onList: () => widget.socketService.fetchScheduled(),
                  onDelete: (messageId) {
                    widget.socketService.cancelScheduled(messageId);
                    widget.socketService.fetchScheduled();
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 定时设定对话框：确定后预约到当前会话
  void _openScheduleMessageDialog(String current) {
    showScheduleMessageDialog(
      context,
      onSchedule: (at, text) async {
        if (current.startsWith('group_')) {
          final groupId = int.tryParse(current.substring(6));
          if (groupId != null) {
            await widget.socketService.scheduleGroupChat(groupId, text, at);
          }
        } else {
          await widget.socketService.scheduleChat(current, text, at);
        }
      },
    );
  }

  void _logout() {
    // 阶段 K2：退出前立即同步当前输入为草稿（防抖未触发时草稿不丢失）
    _flushDraft();
    widget.socketService.disconnect();
    // 阶段 O7（用户反馈 #9）：退出登录回退全局默认主题设置
    ThemeSettings.instance.bindUser(null);
    // R-P11：表情包清单键同步回退全局默认
    StickerStore.instance.bindUser(null);
    // 退出登录（阶段 O6 修订）：仅清除当前凭据，**保留账号列表**——
    // 回到登录页可从账号条目快速切换（不再用 clear() 全清）。
    // 当前凭据仍会清除：登录页不会自动回填/自动登录（H3 语义不变）
    SessionStore.clearCurrent();
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

  /// 阶段 N3 / R-P5（用户二轮反馈扩展）：粘贴/文件选择/拖拽图片 →
  /// 自动进入标注编辑器（仿微信）。用户可编辑（涂鸦/裁剪）后"发送"，
  /// 也可"直接发送"原图；取消则放弃。
  /// 未编辑且携带落盘路径时仍走 sendFile（保留 M8 大文件分流语义）。
  Future<void> _sendImageWithEditor(
    Uint8List bytes, {
    required String filename,
    String? filePath,
  }) async {
    final key = _state.currentChat;
    if (key == null || key == '服务器') return;
    await showImageAnnotationEditor(
      context,
      bytes,
      onConfirm: (annotated) {
        // compose 契约：无修改时原字节直通（同一实例）→ 走路径发送
        if (identical(annotated, bytes) && filePath != null) {
          widget.socketService.sendFile(key, filePath, filename);
        } else {
          widget.socketService.sendFileBytes(key, annotated, filename);
        }
      },
    );
  }

  /// 阶段 N3b（P2-4 扩展）：点击内联图片 → 黑底全屏查看（参考微信）。
  /// 字节优先 Image.memory，否则本地路径 Image.file；点击关闭，可缩放。
  void _openImageViewer(ChatMessage message) {
    final bytes = message.fileData;
    String? path = message.filePath;
    if (path == null && message.filename != null) {
      final base = message.filename!.split(RegExp(r'[/\\]')).last;
      path = '${AppConfig.receivedFilesDir}/$base';
    }
    if (bytes == null && (path == null || !File(path).existsSync())) return;
    showDialog<void>(
      context: context,
      barrierColor: Colors.black,
      barrierDismissible: true,
      builder: (ctx) => GestureDetector(
        onTap: () => Navigator.of(ctx).pop(),
        child: Center(
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 4,
            child:
                bytes != null ? Image.memory(bytes) : Image.file(File(path!)),
          ),
        ),
      ),
    );
  }

  // R-P14（微信式）：表情/表情包面板挂载状态（true = 显示在输入栏上方）
  bool _emojiPanelVisible = false;

  /// 阶段 P2（R-P3 修订）：表情面板开关——表情模块点击插入输入框（光标处），
  /// 表情包模块点击贴纸按图片消息通道发送到当前会话。
  /// R-P14：由模态弹层改为输入栏上方嵌入式面板（不遮挡输入框）。
  void _showStickerPicker() {
    final key = _state.currentChat;
    if (key == null || key == '服务器') return;
    setState(() => _emojiPanelVisible = !_emojiPanelVisible);
  }

  /// 构建嵌入式表情面板（输入栏上方挂载；无可用会话时不渲染）
  Widget? _buildEmojiPanel() {
    final key = _state.currentChat;
    if (!_emojiPanelVisible || key == null || key == '服务器') return null;
    return StickerPickerPanel(
      key: const ValueKey('sticker_panel'),
      onPick: (sticker) {
        final bytes = StickerStore.instance.stickerBytes(sticker.id);
        if (bytes != null) {
          widget.socketService.sendFileBytes(key, bytes, sticker.name);
        }
      },
      onEmojiPicked: _insertEmoji,
      onClose: () => setState(() => _emojiPanelVisible = false),
    );
  }

  /// 在输入框光标处插入表情（R-P3 表情模块），并同步会话草稿
  void _insertEmoji(String emoji) {
    final base = _inputCtrl.text;
    final sel = _inputCtrl.selection;
    final start = (sel.baseOffset < 0) ? base.length : sel.baseOffset;
    final end = (sel.extentOffset < 0) ? start : sel.extentOffset;
    final newText = base.replaceRange(start, end, emoji);
    _inputCtrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + emoji.length),
    );
    final key = _state.currentChat;
    if (key != null && key != '服务器') {
      _state.setConversationDraft(key, newText);
    }
  }

  /// R-P3：收藏图片消息到"我的表情包"（他人发送的表情据为己有）
  Future<void> _saveMessageSticker(ChatMessage message) async {
    Uint8List? bytes = message.fileData;
    if (bytes == null) {
      var path = message.filePath;
      if (path == null && message.filename != null) {
        final base = message.filename!.split(RegExp(r'[/\\]')).last;
        path = '${AppConfig.receivedFilesDir}/$base';
      }
      if (path != null && File(path).existsSync()) {
        bytes = await File(path).readAsBytes();
      }
    }
    if (bytes == null || !isSupportedImage(bytes)) {
      _state.showNotice('仅图片消息可添加到表情包');
      return;
    }
    final sticker = await StickerStore.instance.addSticker(bytes);
    if (sticker == null) {
      // R-P11：不再静默失败（未 init/写入异常时给用户明确反馈）
      _state.showNotice('添加失败（表情包目录不可用）');
      return;
    }
    _state.showNotice('已添加到表情包');
  }

  /// R-P2：文件卡片点击 → 文件预览（信息 + 文本预览 + 系统打开）
  void _openFilePreview(ChatMessage message) {
    var path = message.filePath;
    if (path == null && message.filename != null) {
      final base = message.filename!.split(RegExp(r'[/\\]')).last;
      path = '${AppConfig.receivedFilesDir}/$base';
    }
    showFilePreviewDialog(
      context,
      filename: message.filename ?? message.content,
      path: path,
      filesize: message.filesize,
      sender: message.sender,
      timestamp: message.timestamp,
    );
  }

  /// 阶段 P3：高级搜索（关键词/发送者/时间组合，按会话路由）。
  /// R-P28 修订：发送者改为选项式多选（私聊=会话双方、群聊=群成员，
  /// 打开时预取群成员列表），日期为单入口托盘式模糊日期。
  void _showAdvancedSearch() {
    final current = _state.currentChat;
    if (current == null || current == '服务器') return;
    final isGroup = current.startsWith('group_');
    final groupId = isGroup ? int.tryParse(current.substring(6)) : null;
    if (isGroup && groupId != null) {
      widget.socketService.fetchGroupMembers(groupId);
    }
    showAdvancedSearchDialog(
      context,
      senderCandidates: () {
        if (isGroup) {
          for (final g in _state.groups) {
            if (g.id == groupId) return g.members;
          }
          return const <String>[];
        }
        final myName = _state.username;
        return [
          current,
          if (myName != null && myName != current) myName,
        ];
      },
      onSearch: (filter) {
        if (isGroup) {
          if (groupId != null) {
            widget.socketService.searchHistory(
              filter.keyword,
              groupId: groupId,
              senders: filter.senders,
              timeFrom: filter.from,
              timeTo: filter.to,
            );
          }
        } else {
          widget.socketService.searchHistory(
            filter.keyword,
            to: current,
            senders: filter.senders,
            timeFrom: filter.from,
            timeTo: filter.to,
          );
        }
      },
    );
  }

  /// 阶段 P1（R-P1 修订）：视频气泡点击 → 全屏播放器。
  /// media_kit（mpv）内嵌播放；初始化失败（缺库/测试环境）回退为
  /// "使用系统播放器打开"。
  void _openVideoViewer(ChatMessage message) {
    var path = message.filePath;
    if (path == null && message.filename != null) {
      final base = message.filename!.split(RegExp(r'[/\\]')).last;
      path = '${AppConfig.receivedFilesDir}/$base';
    }
    showDialog<void>(
      context: context,
      barrierColor: Colors.black,
      barrierDismissible: false,
      builder: (ctx) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: _VideoViewerPage(
          filename: message.filename ?? message.content,
          path: path,
        ),
      ),
    );
  }

  /// 阶段 N2（P2-1 聊天记录导出）：当前会话导出 TXT/JSON
  /// （数据主权闭环：JSON 含完整元数据，TXT 人工可读；保存路径由用户选择）
  Future<void> _exportChat() async {
    final key = _state.currentChat;
    if (key == null || key == '服务器') return;
    final messages = _state.getMessages(key);
    // 阶段 N2 修订（用户反馈）：TXT 与 JSON 地位相同——
    // 两个并列按钮，避免主/次按钮暗示格式有主次之分
    final format = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导出聊天记录'),
        content: const Text('TXT：人工可读的纯文本\nJSON：含完整元数据（时间戳/状态/引用/表情）'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          OutlinedButton.icon(
            onPressed: () => Navigator.pop(ctx, 'txt'),
            icon: const Icon(Icons.description_outlined, size: 18),
            label: const Text('TXT'),
          ),
          OutlinedButton.icon(
            onPressed: () => Navigator.pop(ctx, 'json'),
            icon: const Icon(Icons.data_object_rounded, size: 18),
            label: const Text('JSON'),
          ),
        ],
      ),
    );
    if (format == null || !mounted) return;
    final safeName = key.replaceAll(RegExp(r'[^\w\-]'), '_');
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '导出聊天记录',
      fileName: 'chat_$safeName.$format',
    );
    if (path == null) return;
    final content = format == 'txt'
        ? ChatExporter.exportTxt(chatKey: key, messages: messages)
        : ChatExporter.exportJson(chatKey: key, messages: messages);
    try {
      File(path).writeAsStringSync(content);
      _state.showNotice('已导出 ${messages.length} 条消息到 $path');
    } catch (e) {
      _state.showNotice('导出失败: $e');
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
            title: Text('${t('appTitle')} - ${_state.username ?? ""}'),
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

              // 群邀请入口（阶段 M：P-11 用户反馈——邀请像好友申请一样
              // 保留入口，离线登录补发后同样在此显示）
              if (_state.invitations.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Badge(
                    label: Text('${_state.invitations.length}'),
                    child: IconButton(
                      icon: const Icon(Icons.group_add_rounded),
                      tooltip: '待处理群邀请',
                      onPressed: _showGroupInvites,
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
                tooltip: t('settings'),
                onPressed: () => showSettingsDialog(context),
              ),

              // 文件管理（阶段 M8：P1-7 文件收发管理页）
              IconButton(
                icon: const Icon(Icons.folder_open_rounded),
                tooltip: '文件管理',
                onPressed: () =>
                    showFileListDialog(context, widget.socketService),
              ),

              // 设备管理（阶段 N6：P2-6 登录设备管理——列表/远程下线）
              IconButton(
                icon: const Icon(Icons.devices_rounded),
                tooltip: '设备管理',
                onPressed: () =>
                    showDeviceManagementDialog(context, widget.socketService),
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
                tooltip: t('logout'),
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
                        _maybeFetchGroupAnnouncements(key);
                        // 阶段 K2：切换会话前同步保存旧会话草稿（本地 + 服务端），
                        // 再恢复新会话草稿到输入栏（先 selectChat，避免草稿回写
                        // 到旧会话）
                        // 系统消息会话（'服务器'）只读：不写本地草稿元数据（P-46 缺陷修复）
                        final previous = _state.currentChat;
                        if (previous != null &&
                            previous != key &&
                            previous != '服务器') {
                          _state.setConversationDraft(
                              previous, _inputCtrl.text);
                          _flushDraft();
                        }
                        _state.selectChat(key);
                        _inputCtrl.text = _state.draftOf(key);
                        _maybeLoadInitialHistory(key);
                        // R-P14：切换会话收起表情面板
                        if (_emojiPanelVisible) {
                          setState(() => _emojiPanelVisible = false);
                        }
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
                      child: Column(
                        children: [
                          Expanded(
                            child: _state.currentChat != null
                                ? ChatView(
                                    chatKey: _state.currentChat!,
                                    chatTitle: _state.displayNameForChat(
                                        _state.currentChat!),
                                    messages: _state
                                            .isSearchMode(_state.currentChat!)
                                        ? _state
                                            .searchResults(_state.currentChat!)
                                        : _state
                                            .getMessages(_state.currentChat!),
                                    username: _state.username!,
                                    inputCtrl: _inputCtrl,
                                    canSend: _state.currentChat != '服务器',
                                    onSend: _sendMessage,
                                    onSendFile: _sendFile,
                                    onRecall: _confirmRecall,
                                    onLoadHistory: (beforeId) => _loadHistory(
                                        _state.currentChat!, beforeId),
                                    hasMoreHistory: _state.hasMoreHistory,
                                    transferFraction: _state.transferFraction,
                                    isSearchMode: _state
                                        .isSearchMode(_state.currentChat!),
                                    searchQuery: _state
                                        .searchQueryOf(_state.currentChat!),
                                    onSearch: _runSearch,
                                    onSearchExit: _exitSearch,
                                    onRetrySend: (messageId) => widget
                                        .socketService
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
                                        _state.removeMessageLocally(
                                            key, messageId);
                                      }
                                    },
                                    // 阶段 N1（P2-2 永久删除）：本地缓存中彻底移除
                                    onDeletePermanently: (messageId) {
                                      final key = _state.currentChat;
                                      if (key != null) {
                                        widget.socketService
                                            .permanentlyDeleteMessage(
                                                key, messageId);
                                      }
                                    },
                                    // 阶段 N3（P2-4）/ R-P5 修订：剪贴板图片
                                    // → 自动进入标注编辑器（可编辑后发送，
                                    // 也可直接发送原图）
                                    onImagePasted: (bytes) {
                                      if (isSupportedImage(bytes)) {
                                        _sendImageWithEditor(bytes,
                                            filename: 'pasted_image.png');
                                      }
                                    },
                                    // 阶段 N3b：点击内联图片 → 全屏查看
                                    onImageTap: _openImageViewer,
                                    // 阶段 P1：点击视频气泡 → 全屏查看
                                    onVideoTap: _openVideoViewer,
                                    // R-P2：点击文件卡片 → 文件预览
                                    onFileTap: _openFilePreview,
                                    // R-P3：图片消息菜单"添加到表情包"
                                    onSaveSticker: _saveMessageSticker,
                                    // 阶段 P2：贴纸面板入口
                                    onShowStickerPicker: _showStickerPicker,
                                    // R-P14：嵌入式表情面板（输入栏上方）
                                    emojiPanel: _buildEmojiPanel(),
                                    // 阶段 P3：高级搜索入口
                                    onAdvancedSearch: _showAdvancedSearch,
                                    // 阶段 N2（P2-1）：聊天记录导出（TXT/JSON）
                                    onExportChat: _exportChat,
                                    // ---- 阶段 O 接线 ----
                                    // O1/O2：群公告横幅 + 群置顶横幅
                                    // （数据源 list_groups 推送的 Group 字段）
                                    // 多公告/多置顶并存（2026-08-31 修订）：
                                    // 公告横幅 = state.groupAnnouncements
                                    //（选中群时拉取 + 实时推送追加）；
                                    // 置顶横幅 = list_groups 的全量置顶列表
                                    announcements: _state.groupAnnouncements
                                        .map((a) => a.content)
                                        .toList(),
                                    // R-O12：公告横幅 ✕ 删除按钮（仅群主）
                                    announcementItems:
                                        _state.groupAnnouncements,
                                    onDeleteAnnouncement: _canPinCurrent
                                        ? (messageId) {
                                            final group = _currentGroup!;
                                            widget.socketService
                                                .deleteGroupAnnouncement(
                                                    group.id, messageId);
                                            _state.removeGroupAnnouncement(
                                                messageId);
                                            widget.socketService
                                                .fetchGroupAnnouncements(
                                                    group.id);
                                          }
                                        : null,
                                    pinnedItems: _currentGroup?.pinnedMessages,
                                    // O2：群主置顶群消息入口
                                    // （对已置顶消息菜单显示"取消置顶"）
                                    pinnedMessageId:
                                        _currentGroup?.pinnedMessageId,
                                    onPinMessage: _canPinCurrent
                                        ? (messageId) {
                                            final group = _currentGroup!;
                                            if (group.pinnedMessageId ==
                                                messageId) {
                                              widget.socketService
                                                  .unpinGroupMessage(group.id);
                                            } else {
                                              widget.socketService
                                                  .pinGroupMessage(
                                                      group.id, messageId);
                                            }
                                          }
                                        : null,
                                    // O2 修订（多置顶并存）：横幅快捷取消
                                    onUnpinMessage: _canPinCurrent
                                        ? (messageId) => widget.socketService
                                            .unpinGroupMessage(
                                                _currentGroup!.id,
                                                messageId: messageId)
                                        : null,
                                    // O4：快捷回复面板
                                    onQuickReply: _showQuickReplyPanel,
                                    // O5：定时发送对话框
                                    onScheduleMessage: _showScheduleDialog,
                                  )
                                : Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(Icons.chat_rounded,
                                            size: 64, color: Colors.grey),
                                        const SizedBox(height: 16),
                                        Text(
                                          t('selectChatToStart'),
                                          style: const TextStyle(
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

/// 全屏视频播放器（R-P1）：media_kit 内嵌播放；顶栏文件名（点击关闭）；
/// 播放器初始化失败时回退"使用系统播放器打开"（xdg-open）。
class _VideoViewerPage extends StatefulWidget {
  final String filename;
  final String? path;

  const _VideoViewerPage({required this.filename, this.path});

  @override
  State<_VideoViewerPage> createState() => _VideoViewerPageState();
}

class _VideoViewerPageState extends State<_VideoViewerPage> {
  Player? _player;
  VideoController? _controller;
  StreamSubscription<dynamic>? _errorSub;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    final path = widget.path;
    if (path == null || !File(path).existsSync()) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    // 测试环境无法初始化原生播放（FakeAsync 下原生回调不返回），恒走回退，
    // 保证查看器交互测试确定性（不引入 flutter_test 依赖，按绑定类型名判定）
    if (WidgetsBinding.instance.runtimeType.toString() ==
        'AutomatedTestWidgetsFlutterBinding') {
      if (mounted) setState(() => _failed = true);
      return;
    }
    try {
      MediaKit.ensureInitialized();
      final player = Player();
      // R-P8（用户实测：有声无画）：强制 S/W 渲染（像素缓冲 Texture），
      // 绕开 H/W 路径的 GL 上下文共享失败（虚拟机/llvmpipe/部分驱动下
      // mpv_render_context 建成功但帧不上屏，音频正常画面全黑）；
      // hwdec 同步关闭避免 VAAPI 初始化失败拖垮解码。
      final controller = VideoController(
        player,
        configuration: const VideoControllerConfiguration(
          enableHardwareAcceleration: false,
          hwdec: 'no',
        ),
      );
      // R-P21（用户实测：接收方点开视频"一直加载中"）：改为 media_kit
      // 标准用法——先挂载 Video 再 open，帧就绪即显示，不再以 open()
      // 完成作为显示前提（open 挂起时原实现永久停留在占位页）；
      // 错误流 + open 超时（10s）双兜底，失败释放播放器并给出
      // "使用系统播放器打开"出口。
      _errorSub = player.stream.error.listen((_) {
        if (!mounted) return;
        _disposePlayer();
        setState(() => _failed = true);
      });
      if (!mounted) {
        await player.dispose();
        return;
      }
      setState(() {
        _player = player;
        _controller = controller;
      });
      try {
        await player.open(Media(path)).timeout(const Duration(seconds: 10));
      } on TimeoutException {
        if (!mounted) return;
        _disposePlayer();
        setState(() => _failed = true);
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _disposePlayer() {
    _errorSub?.cancel();
    _errorSub = null;
    _player?.dispose();
    _player = null;
    _controller = null;
  }

  @override
  void dispose() {
    _disposePlayer();
    super.dispose();
  }

  void _openWithSystemPlayer() {
    final path = widget.path;
    if (path != null && File(path).existsSync()) {
      Process.run('xdg-open', [path]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // 顶栏：关闭 + 文件名（点击文件名同样关闭，兼容既有交互）
            Row(
              children: [
                IconButton(
                  tooltip: '关闭',
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                Expanded(
                  child: GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Text(
                      widget.filename,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ),
                ),
              ],
            ),
            Expanded(
              child: (player != null && controller != null)
                  ? Video(controller: controller)
                  : Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // R-P21：初始化中显示加载指示器；仅失败态显示
                          // 播放图标 + 系统播放器出口（不再"永久加载中"）
                          if (_failed)
                            const Icon(Icons.play_circle_rounded,
                                size: 72, color: Colors.white70)
                          else
                            const SizedBox(
                              width: 44,
                              height: 44,
                              child: CircularProgressIndicator(
                                  strokeWidth: 3, color: Colors.white70),
                            ),
                          const SizedBox(height: 12),
                          Text(
                            widget.filename,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 15),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),
                          if (_failed && widget.path != null)
                            TextButton.icon(
                              onPressed: _openWithSystemPlayer,
                              icon: const Icon(Icons.open_in_new_rounded,
                                  size: 18, color: Colors.white70),
                              label: const Text('使用系统播放器打开',
                                  style: TextStyle(color: Colors.white70)),
                            ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
