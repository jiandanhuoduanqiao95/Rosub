/// 聊天主界面
///
/// 布局：左侧边栏（好友/群组列表）+ 右侧聊天区域
/// 管理员可见额外"管理面板"按钮

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'dart:io';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../l10n/app_strings.dart';
import '../models/chat_models.dart';
import '../platform/android_system.dart';
import '../platform/battery_optimization.dart';
import '../platform/capabilities.dart';
import '../screens/call_screen.dart';
import '../services/call_service.dart';
import '../services/chat_exporter.dart';
import '../services/app_paths.dart';
import '../services/export_saver.dart';
import '../services/ime_bridge.dart';
import '../services/session_lifecycle.dart';
import '../services/session_store.dart';
import '../services/socket_service.dart';
import '../services/sticker_store.dart';
import '../services/theme_settings.dart';
import '../services/state_manager.dart';
import '../services/taskbar_notifier.dart';
import '../widgets/app_feedback.dart';
import '../widgets/chat_view.dart';
import '../widgets/dialogs.dart';
import '../widgets/image_annotation_editor.dart';
import '../widgets/adaptive_text_field.dart';
import '../widgets/responsive_layout.dart';
import '../widgets/sidebar.dart';

class ChatScreen extends StatefulWidget {
  final SocketService socketService;

  const ChatScreen({super.key, required this.socketService});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final _state = AppState.instance;
  final _inputCtrl = TextEditingController();

  /// 阶段 K2：草稿自动保存防抖（输入停顿后同步服务端）
  Timer? _draftDebounce;

  /// 阶段 K3（P-16 修订）：免打扰到期巡检（每 30s 检查一次，
  /// 到期自动关闭免打扰开关并 SnackBar 提醒——声音通道随即恢复）
  Timer? _dndExpiryTimer;

  /// 阶段 R1：通话界面路由占用标志（防重复 push；关闭后复位）
  bool _callRouteOpen = false;

  /// 阶段 M2：群邀请以入口保留（AppBar badge + 列表对话框），无即时弹窗

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _state.addListener(_onStateChanged);
    // 阶段 R1：来电/去电进入通话界面（idle→活跃即 push，通话界面自回）。
    // 经回调字段接线（见 SocketService.onCallPhaseChanged 注释）——
    // 直接读 callService getter 会在 MockSocketService 上抛 TypeError
    widget.socketService.onCallPhaseChanged = _onCallChanged;
    _dndExpiryTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => _checkDndExpiry());
    // 阶段 N3（P2-4 文件拖拽发送）/ Q1-2：经平台能力抽象接收拖入的
    // 文件路径（Linux=GTK channel 原样；移动端 isSupported=false 不注册）
    PlatformCapabilities.fileDrop.ensureListening();
    PlatformCapabilities.fileDrop.setOnFilesDropped(_onFilesDropped);
    // 阶段 Q0-5：会话生命周期守护——回前台校验 socket 存活并重连。
    // Q1 五轮（问题1 重大回归修复）：isSocketAlive 改为恒 false——
    // 原 `socket != null` 判定把"僵尸 socket"（服务端看门狗踢线/系统
    // 冻结后连接单侧死亡，但 Dart 侧对象仍在）当作存活，resumed 时
    // guard 直接短路返回，ensureConnectedOnResume 的僵死探测
    // （ping + 10s 看门狗）永远走不到 → 前台也不重连，只能重新登录。
    // 恒 false = resume 恒走 ensureConnectedOnResume：真正的存活判定
    // 由其内部完成（僵尸 → 重连链路；健康连接 → 一次探测 ping，幂等
    // 无害），幂等保护（_reconnecting/_intentionalDisconnect/凭据）均在其中。
    SessionLifecycleGuard.instance.bind(
      isSocketAlive: () => false,
      reconnect: () => widget.socketService.ensureConnectedOnResume(),
      onPause: () => widget.socketService.markAppPaused(),
    );
    // Q1 五轮（问题1 重大回归修复）：恢复"生命周期门控前台服务"——
    // 四轮的普通服务方案被国产 ROM 深度休眠冻结/回收，后台彻底收不到
    // 新消息（无前台状态不被 Android 12+ 冻结机制豁免；侧载应用无厂商
    // 推送通道）。前台使用期间服务不运行（零通知）；退后台（paused）
    // 启动 FGS 维持进程与消息连接，回前台（resumed）立即停止——通知
    // 仅在后台期间存在，为后台收消息的系统强制代价
    // 阶段 Q1-4：电池优化白名单引导（仅 Android 且未白名单时弹一次；
    // 桌面/已白名单天然不弹）。
    // Q1 真机反馈二轮：前置通知权限请求（问题5——应用外通知需
    // Android 13+ POST_NOTIFICATIONS），后置上次崩溃日志展示（问题8 排障）
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // Q1 六轮（问题3）：消息通知渠道改用应用提示音（客户端内外
      // 统一；Q1 八轮起提示音为打包内置资源，原生侧自取）
      await AndroidSystem.setupMessageChannel();
      if (!mounted) return;
      // opt1 P6：通话通知渠道（FGS 之外删除重建，DEFAULT 才在 vivo
      // 通知中心展示卡片）
      await AndroidSystem.setupCallChannel();
      if (!mounted) return;
      await AndroidSystem.requestNotificationPermission();
      if (!mounted) return;
      await maybeShowBatteryOptimizationGuide(context);
      if (!mounted) return;
      await _maybeShowLastCrashDialog();
      // opt1 P7：无听筒设备预取（平板）——语音通话默认外放 + 接通提示
      try {
        widget.socketService.callService.noEarpieceDevice =
            !await AndroidSystem.hasEarpiece();
      } catch (_) {}
    });
    // 阶段 O1 修订（2026-08-31 多公告并存）：进入聊天页时对当前会话
    // （重连恢复场景）拉取群公告历史
    final initial = _state.currentChat;
    if (initial != null) {
      _maybeFetchGroupAnnouncements(initial);
    }
  }

  /// Q1 五轮（问题1）：生命周期门控保活——退后台（paused）启动前台
  /// 服务维持进程与消息连接（后台通知为系统强制项）；回前台（resumed）
  /// 立即停止（前台期间零通知）。仅 Android 生效（内部有平台门控）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      unawaited(AndroidSystem.startKeepAlive());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(AndroidSystem.stopKeepAlive());
      // opt1 P6：用户可能刚点了通知栏"通话中"通知——拉取回通话意图
      unawaited(_handleOpenCallIntent());
    }
  }

  /// opt1 P6：通话通知点击 → 回到通话界面。MainActivity 经通知
  /// contentIntent（extra open_call=1）置位标志，此处拉取后 restore
  /// （notifyListeners → onCallPhaseChanged → _onCallChanged push，
  /// pop 职责契约不动）；通话已结束（冷启动残留标志）则忽略——
  /// 不承诺恢复已死的媒体会话。
  Future<void> _handleOpenCallIntent() async {
    final pending = await AndroidSystem.consumeOpenCallIntent();
    if (!pending || !mounted) return;
    try {
      final svc = widget.socketService.callService;
      if (svc.isInLiveCall && svc.minimized) {
        svc.restore();
      }
    } catch (_) {
      // Mock 测试未 stub callService getter——纯增益通道静默降级
    }
  }

  /// opt1 P5：通话进行中启动 microphone|camera 型前台服务（Android 14+
  /// 熄屏/后台采集媒体的类型要求），结束停止。与消息 KeepAliveService
  /// 并存（渠道不同、生命周期不同），消息保活门控不受影响。
  void _syncCallForegroundService(CallService svc) {
    if (effectiveTargetPlatform() != TargetPlatform.android) return;
    if (svc.isInLiveCall) {
      unawaited(
          AndroidSystem.startCallForeground(video: svc.type == CallType.video));
    } else {
      unawaited(AndroidSystem.stopCallForeground());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SessionLifecycleGuard.instance.unbind();
    widget.socketService.onCallPhaseChanged = null;
    // Q1 五轮（问题1）：离开聊天页/退出登录停止前台服务（防退后台
    // 启动后残留）；未启动时 stopService 为无害 no-op
    if (effectiveTargetPlatform() == TargetPlatform.android) {
      unawaited(AndroidSystem.stopKeepAlive());
      // opt1 P5：通话 FGS 双保险撤除（正常路径经 _onCallChanged 已停）
      unawaited(AndroidSystem.stopCallForeground());
    }
    PlatformCapabilities.fileDrop.setOnFilesDropped(null);
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

  /// Q1 真机反馈二轮（问题8"首开闪退"排障）：上次 Java 层未捕获
  /// 异常的面包屑展示——存在则弹对话框（可复制），关闭即清除。
  /// 仅 Android；无日志/非 Android 静默。
  Future<void> _maybeShowLastCrashDialog() async {
    if (effectiveTargetPlatform() != TargetPlatform.android) return;
    final log = await AndroidSystem.getLastCrashLog();
    if (log == null || log.isEmpty || !mounted) return;
    await showResponsiveDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('检测到上次异常退出'),
        content: SizedBox(
          width: double.infinity,
          height: 320,
          child: SingleChildScrollView(
            child: SelectableText(
              log,
              style: const TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                height: 1.3,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: log));
              showNoticeBar(ctx, '已复制崩溃日志');
            },
            child: const Text('复制日志'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
    await AndroidSystem.clearCrashLog();
  }

  /// Q1 真机反馈二轮（问题5b）：Android 返回键/侧滑逐级返回——
  /// 表情面板 → 搜索行 → compact 聊天区回列表 → 转后台（不退出进程）
  void _handleAndroidBack() {
    if (_emojiPanelVisible) {
      setState(() => _emojiPanelVisible = false);
      return;
    }
    if (_chatSearchVisible) {
      setState(() => _chatSearchVisible = false);
      return;
    }
    if (_inCompactChat) {
      setState(() => _compactShowChat = false);
      return;
    }
    AndroidSystem.moveToBackground();
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
        showNoticeBar(context, notice);
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
    showResponsiveDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑资料'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AdaptiveTextField(
              controller: nicknameCtrl,
              hintText: '昵称',
              showChineseInput: true,
            ),
            const SizedBox(height: 8),
            AdaptiveTextField(
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
    final confirmed = await showResponsiveDialog<bool>(
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
  /// Q1 真机反馈二轮（问题8）：解码降采样到屏幕宽度像素——超大照片
  /// （如 50MP）全分辨率解码常驻数百 MB，低端机易被 LMK 查杀（闪退）。
  void _openImageViewer(ChatMessage message) {
    final bytes = message.fileData;
    String? path = message.filePath;
    if (path == null && message.filename != null) {
      final base = message.filename!.split(RegExp(r'[/\\]')).last;
      path = '${AppPaths.receivedFilesDir}/$base';
    }
    if (bytes == null && (path == null || !File(path).existsSync())) return;
    showResponsiveDialog<void>(
      context: context,
      barrierColor: Colors.black,
      barrierDismissible: true,
      builder: (ctx) {
        final dpr = MediaQuery.devicePixelRatioOf(ctx);
        final cacheWidth =
            (MediaQuery.sizeOf(ctx).width * dpr).ceil().clamp(720, 4096);
        return GestureDetector(
          onTap: () => Navigator.of(ctx).pop(),
          child: Center(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 4,
              child: bytes != null
                  ? Image.memory(bytes, cacheWidth: cacheWidth)
                  : Image.file(File(path!), cacheWidth: cacheWidth),
            ),
          ),
        );
      },
    );
  }

  // R-P14（微信式）：表情/表情包面板挂载状态（true = 显示在输入栏上方）
  bool _emojiPanelVisible = false;

  /// 阶段 Q1-1：compact（手机窄屏）单屏状态——true = 显示聊天区，
  /// false = 显示会话列表；宽屏（≥600）忽略此状态（双栏恒可见）
  bool _compactShowChat = false;

  /// Q1 真机反馈 #3：compact 聊天态 AppBar 的搜索入口（受控驱动
  /// ChatView 搜索输入行显隐；切换会话时复位）
  bool _chatSearchVisible = false;

  /// 当前是否处于"compact 聊天态"（AppBar 最简化：返回+居中标题+
  /// 搜索/导出/文件管理；工具栏图标收进会话列表态）
  bool get _inCompactChat => _compactShowChat && _state.currentChat != null;

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
        path = '${AppPaths.receivedFilesDir}/$base';
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
      path = '${AppPaths.receivedFilesDir}/$base';
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
      path = '${AppPaths.receivedFilesDir}/$base';
    }
    showResponsiveDialog<void>(
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
  /// （数据主权闭环：JSON 含完整元数据，TXT 人工可读）。
  /// Q1 真机反馈 #8 修订：落盘改经 ExportSaver 平台分流——移动端
  /// 直接写 AppPaths.exportsDir（FilePicker.saveFile 移动端无路径，
  /// 原实现点击 TXT/JSON 无反应），桌面保持系统"另存为"对话框。
  Future<void> _exportChat() async {
    final key = _state.currentChat;
    if (key == null || key == '服务器') return;
    final messages = _state.getMessages(key);
    // 阶段 N2 修订（用户反馈）：TXT 与 JSON 地位相同——
    // 两个并列按钮，避免主/次按钮暗示格式有主次之分
    final format = await showResponsiveDialog<String>(
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
    final content = format == 'txt'
        ? ChatExporter.exportTxt(chatKey: key, messages: messages)
        : ChatExporter.exportJson(chatKey: key, messages: messages);
    try {
      final path = await ExportSaver.saveExportFile(
        baseName: 'chat_${key.replaceAll(RegExp(r'[^\w\-]'), '_')}',
        format: format,
        content: content,
      );
      if (path == null) return;
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
    final confirmed = await showResponsiveDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('引用回复'),
        content: AdaptiveTextField(
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

  /// 阶段 K5（P1-3）：转发目标选择对话框（好友 + 群组）。
  /// Q1 三轮（问题8）：文件转发经 onTarget 回调走"本地文件重发"通道，
  /// 文字消息仍走服务端 forward 协议（默认路径）。
  Future<void> _showForwardTargetDialog(
    String messageId, {
    void Function(String targetChatKey)? onTarget,
  }) async {
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
    final target = await showResponsiveDialog<ChatTarget>(
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
    if (target == null) return;
    if (onTarget != null) {
      onTarget(target.key);
    } else {
      widget.socketService.forwardMessage(messageId, target.key);
    }
  }

  /// Q1 三轮（问题8）：文件转发（纯客户端实现，服务端/协议零改动）。
  /// 服务端 forward 协议对文件消息恒拒绝（"文件消息暂不支持转发"），
  /// 故对已下载到本机的文件改走既有 sendFile 上传通道重新发送——
  /// 服务端视为一次普通文件发送（以转发人为第一手，语义一致）。
  /// 未下载（file_meta 元数据气泡/已清缓存）时提示并中止。
  void _forwardFile(ChatMessage message) {
    var path = message.filePath;
    if (path == null && message.filename != null) {
      final base = message.filename!.split(RegExp(r'[/\\]')).last;
      path = '${AppPaths.receivedFilesDir}/$base';
    }
    if (path == null || !File(path).existsSync()) {
      _state.showNotice('文件尚未下载到本机，无法转发');
      return;
    }
    final filename = message.filename ?? path.split(RegExp(r'[/\\]')).last;
    final resolved = path;
    _showForwardTargetDialog(
      message.messageId,
      onTarget: (key) {
        if (key == '服务器') return;
        widget.socketService.sendFile(key, resolved, filename);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // 阶段 Q1-1：手机窄屏（<600）单屏布局，桌面/平板（≥600）双栏不变
    final compact = isCompactLayout(context);
    final inCompactChat = compact && _inCompactChat;
    // Q1 四轮（问题3）：Android 会话列表态 AppBar 不再显示
    // "聊天室 - 用户名"字样（聊天态会话名保留）；桌面基线不变
    final hideListTitle = effectiveTargetPlatform() == TargetPlatform.android;
    final page = ListenableBuilder(
      listenable: _state,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            // 阶段 Q1-1：compact 单屏聊天区显示返回控件（回会话列表）
            leading: inCompactChat
                ? IconButton(
                    tooltip: '返回',
                    icon: const Icon(Icons.arrow_back_rounded),
                    onPressed: () => setState(() => _compactShowChat = false),
                  )
                : null,
            // Q1 真机反馈 #3：compact 聊天态只居中显示会话名（用户名/群名），
            // 设置/文件/设备/资料/密码/退出工具栏收进会话列表态。
            // Q1 六轮（问题2）：Android 宽屏（平板/横屏/大屏缩放）选中
            // 会话时 AppBar 也显示会话名（此前宽屏选中会话时标题为空）。
            // Q1 八轮（问题1 回归修复）：**紧凑列表态（返回主界面）不得
            // 残留会话名**——currentChat 常驻（selectChat 语义），六轮
            // 条件 `currentChat != null` 未排除"已返回列表"状态，导致
            // 左上角显示对方名称。
            // 桌面（Linux）宽屏双栏保持"聊天室 - 用户名"基线不变
            // （ChatView 内部自带"与 xx 的聊天"标题栏）。
            centerTitle: inCompactChat,
            title: _state.currentChat != null &&
                    (inCompactChat || (hideListTitle && !compact))
                ? Text(
                    _state.displayNameForChat(_state.currentChat!),
                    overflow: TextOverflow.ellipsis,
                  )
                : (hideListTitle
                    ? null
                    : Text('${t('appTitle')} - ${_state.username ?? ""}')),
            actions: inCompactChat
                ? _buildCompactChatActions()
                : _buildToolbarActions(),
          ),
          // opt1 P3：targetSdk 35+ 强制 edge-to-edge，窗口延伸到系统
          // 任务栏（平板 Dock/手机手势条）之下——主体内容统一消费底部
          // inset；通话悬浮条留在 SafeArea 外（clamp 依赖全屏 padding 坐标）
          body: Stack(
            children: [
              SafeArea(
                top: false,
                child: Column(
                  children: [
                    // === 重连中横幅 ===
                    if (_state.connectionStatus ==
                        ConnectionStatus.reconnecting)
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
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
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
                    // Q1 七轮（问题1）：全局传输指示条——任何界面（列表态/
                    // 聊天态/宽屏）恒可见，点击跳转到传输所属会话
                    if (_state.activeTransfers.isNotEmpty)
                      _TransferBanner(
                        transfers: _state.activeTransfers,
                        filenameOf: (id) => _state.messageById(id)?.filename,
                        onTapTransfer: _jumpToTransferChat,
                      ),
                    Expanded(
                      child: compact ? _buildCompactBody() : _buildWideBody(),
                    ),
                  ],
                ),
              ),
              // R1 真机十轮：最小化通话的悬浮返回条（微信式，通话中恒显示，
              // 点击恢复通话界面；ended 期间显示结束原因，idle 自动消失）
              // opt1：可拖动 + 两态（胶囊 ⇄ 圆点）+ 默认位底部避开头部功能行
              if (_callSnapshotMinimized &&
                  _callSnapshotPhase != CallPhase.idle)
                _buildCallPillLayer(),
            ],
          ),
        );
      },
    );
    // Q1 真机反馈二轮（问题5b）：仅 Android 拦截根路由返回——逐级返回
    // /转后台而非退出应用；桌面关闭按钮不经 Navigator pop，语义不变
    if (effectiveTargetPlatform() == TargetPlatform.android) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          _handleAndroidBack();
        },
        child: page,
      );
    }
    return page;
  }

  /// 阶段 R1：通话状态变化——来电/去电时全屏进入通话界面。
  /// R1 真机十轮（微信式最小化）：minimized 置位时通话页自己 pop（本处
  /// 不 pop——与通话页 idle 自返叠加会双 pop 弹空导航栈→黑屏闪退），
  /// 本页仅显示悬浮返回条；restore() 时重新 push。
  ///
  /// 本回调仅经 onCallPhaseChanged 触发（SocketService 转发 CallService
  /// 的全部 notifyListeners，含最小化/恢复），MockSocketService 从不
  /// 触发——因此此处读取 callService getter 安全；build 里一律使用
  /// 下方快照字段（直读 getter 会在 Mock 上抛 TypeError，见 initState 注释）。
  void _onCallChanged() {
    if (!mounted) return;
    final svc = widget.socketService.callService;
    _callSnapshotSvc = svc;
    _callSnapshotPhase = svc.phase;
    _callSnapshotPeer = svc.peer;
    _callSnapshotActiveSince = svc.activeSince;
    _callSnapshotEndReason = svc.endReason;
    _callSnapshotMinimized = svc.minimized;
    _syncCallForegroundService(svc);
    if (svc.phase == CallPhase.idle) {
      _callPillPos = null;
      _callPillCollapsed = false;
    }
    if (mounted) setState(() {});
    if (!svc.minimized && svc.phase != CallPhase.idle && !_callRouteOpen) {
      _callRouteOpen = true;
      Navigator.of(context, rootNavigator: true)
          .push(MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => CallScreen(callService: svc),
          ))
          .then((_) => _callRouteOpen = false);
    }
    setState(() {});
  }

  // 通话悬浮条快照（build 不得直读 callService getter——Mock 安全）
  CallService? _callSnapshotSvc;
  CallPhase _callSnapshotPhase = CallPhase.idle;
  String? _callSnapshotPeer;
  DateTime? _callSnapshotActiveSince;
  String? _callSnapshotEndReason;
  bool _callSnapshotMinimized = false;

  // opt1：悬浮条拖动位置（null = 默认位左下角，避开列表头部功能行）
  // 与两态开关（false = 胶囊展开态，true = 圆点收起态）
  Offset? _callPillPos;
  bool _callPillCollapsed = false;
  final GlobalKey _callPillKey = GlobalKey();

  /// opt1：最小化通话悬浮条容器层——可拖动、clamp 在屏幕内。
  /// 定位坐标系 = Scaffold body（Stack）自身：外层 Positioned.fill +
  /// LayoutBuilder 取 body 实际宽高（opt1 真机修订：此前用
  /// MediaQuery.sizeOf 的屏幕坐标套进 body 相对的 Positioned，整体被
  /// AppBar 高度下推，默认位落进系统手势导航区，拖动误触"回桌面"）
  Widget _buildCallPillLayer() {
    return Positioned.fill(
      child: LayoutBuilder(builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final bottomInset = MediaQuery.paddingOf(context).bottom;
        final fallback = Offset(16, h - bottomInset - 120);
        final pos = _clampCallPill(_callPillPos ?? fallback, w, h, bottomInset);
        return Stack(
          children: [
            Positioned(
              left: pos.dx,
              top: pos.dy,
              child: GestureDetector(
                onPanUpdate: (details) => setState(() {
                  _callPillPos = _clampCallPill(
                      (_callPillPos ?? fallback) + details.delta, w, h,
                      bottomInset,
                      measure: true);
                }),
                child: _callPillCollapsed
                    ? _buildCallPillDot()
                    : _buildCallMinimizePill(),
              ),
            ),
          ],
        );
      }),
    );
  }

  Offset _clampCallPill(Offset o, double w, double h, double bottomInset,
      {bool measure = false}) {
    final Size size;
    if (_callPillCollapsed) {
      size = const Size(44, 44);
    } else if (measure) {
      // 仅交互回调可读实测尺寸；render tree 未定型时回退估算
      size = _callPillKey.currentContext?.size ?? const Size(200, 36);
    } else {
      size = const Size(200, 36);
    }
    final maxX = (w - size.width - 8).clamp(8.0, double.infinity);
    final maxY =
        (h - size.height - bottomInset - 8).clamp(8.0, double.infinity);
    return Offset(o.dx.clamp(8.0, maxX), o.dy.clamp(8.0, maxY));
  }

  /// R1 真机十轮：最小化通话的悬浮返回条（微信式）——通话中恒显示，
  /// 点击恢复通话界面；opt1 右端新增收缩钮（缩为圆点态）
  Widget _buildCallMinimizePill() {
    final label = switch (_callSnapshotPhase) {
      CallPhase.calling => '正在呼叫…',
      CallPhase.connecting => '接通中…',
      CallPhase.ended => _callSnapshotEndReason ?? '通话已结束',
      _ => '通话中 ${_callDurationText(_callSnapshotActiveSince)}',
    };
    return Material(
      key: _callPillKey,
      color: Colors.black87,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => _callSnapshotSvc?.restore(),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _callSnapshotPhase == CallPhase.ended
                    ? Icons.call_end_rounded
                    : Icons.phone_in_talk_rounded,
                color: Colors.white70,
                size: 18,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '${_callSnapshotPeer ?? ''} $label',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
              const SizedBox(width: 2),
              IconButton(
                key: const Key('call_pill_collapse'),
                tooltip: '收起',
                icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
                color: Colors.white70,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onPressed: () => setState(() => _callPillCollapsed = true),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// opt1：悬浮条收起态——小圆点，点击重新展开为胶囊
  Widget _buildCallPillDot() {
    final ended = _callSnapshotPhase == CallPhase.ended;
    return Material(
      key: _callPillKey,
      color: Colors.black87,
      shape: const CircleBorder(),
      child: InkWell(
        key: const Key('call_pill_dot'),
        customBorder: const CircleBorder(),
        onTap: () => setState(() => _callPillCollapsed = false),
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(
            ended ? Icons.call_end_rounded : Icons.phone_in_talk_rounded,
            color: Colors.white,
            size: 22,
          ),
        ),
      ),
    );
  }

  String _callDurationText(DateTime? since) {
    if (since == null) return '00:00';
    final secs = DateTime.now().difference(since).inSeconds;
    final m = (secs ~/ 60).toString().padLeft(2, '0');
    final s = (secs % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// 阶段 R1：通话类型选择（微信式底部弹层；compact 单入口）
  /// R2 修订：群会话弹群通话层（加入进行中 / 发起语音·视频群通话）
  void _showCallTypePicker() {
    final chat = _state.currentChat;
    if (chat != null && chat.startsWith('group_')) {
      _showGroupCallSheet();
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.call_rounded),
              title: const Text('语音通话'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _startCall(CallType.audio);
              },
            ),
            ListTile(
              leading: const Icon(Icons.videocam_rounded),
              title: const Text('视频通话'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _startCall(CallType.video);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 阶段 R2：群通话弹层——房间存续期可中途加入（knownGroupCalls 注册表）
  void _showGroupCallSheet() {
    final chat = _state.currentChat!;
    final gid = int.tryParse(chat.substring('group_'.length));
    if (gid == null) return;
    var groupName = '群聊';
    for (final g in _state.groups) {
      if (g.id == gid) {
        groupName = g.name;
        break;
      }
    }
    final svc = widget.socketService.callService;
    final ongoing = svc.knownGroupCalls[gid];
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (ongoing != null)
              ListTile(
                leading: const Icon(Icons.groups_rounded),
                title: Text('加入进行中的群通话（${ongoing.participants.length}人）'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _joinGroupCall(gid);
                },
              ),
            ListTile(
              leading: const Icon(Icons.call_rounded),
              title: const Text('发起语音群通话'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                startOutgoingGroupCall(
                    context, svc, gid, groupName, CallType.audio);
              },
            ),
            ListTile(
              leading: const Icon(Icons.videocam_rounded),
              title: const Text('发起视频群通话'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                startOutgoingGroupCall(
                    context, svc, gid, groupName, CallType.video);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 阶段 R2：中途加入进行中的群通话（按房间类型请求权限）
  Future<void> _joinGroupCall(int gid) async {
    final info = widget.socketService.callService.knownGroupCalls[gid];
    if (info == null) return;
    final granted = await AndroidSystem.requestCallPermissions(
        video: info.callType == CallType.video);
    if (!granted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('需要麦克风/摄像头权限才能通话')),
        );
      }
      return;
    }
    final ok = await widget.socketService.callService.joinGroupRoom(gid);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前正在通话中')),
      );
    }
  }

  /// 阶段 R1：发起通话（R2 起：私聊直呼，群聊弹群通话层）
  Future<void> _startCall(CallType type) async {
    final chat = _state.currentChat;
    if (chat == null || chat == '服务器') return;
    if (!_isPrivateChat(chat)) {
      _showGroupCallSheet();
      return;
    }
    await startOutgoingCall(
        context, widget.socketService.callService, chat, type);
  }

  /// 阶段 R1：私聊会话判定（系统会话/群聊不支持通话）
  bool _isPrivateChat(String chatKey) =>
      chatKey != '服务器' && !chatKey.startsWith('group_');

  /// Q1 真机反馈 #3：compact 聊天态 AppBar 动作——搜索 + 导出
  /// （系统会话不提供）+ 固定文件管理入口（Q1 四轮问题4 恢复）。
  /// Q1 真机反馈二轮（收到文件请求无感知）：聊天态同置待处理文件
  /// 请求徽标入口（与列表态工具栏一致）。
  List<Widget> _buildCompactChatActions() {
    final current = _state.currentChat!;
    final isSystem = current == '服务器';
    return [
      if (_state.hasPendingFileRequests)
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Badge(
            label: Text('${_state.pendingFileRequests.length}'),
            child: IconButton(
              icon: const Icon(Icons.folder_rounded),
              tooltip: '待处理文件请求',
              onPressed: _showFileRequests,
            ),
          ),
        ),
      // 阶段 R1/R2：通话入口（单按钮收敛——compact AppBar 图标预算紧张，
      // 私聊经底部弹层选择语音/视频，群聊弹群通话层；系统会话不提供）
      if (!isSystem)
        IconButton(
          tooltip: '通话',
          icon: const Icon(Icons.call_rounded),
          onPressed: _showCallTypePicker,
        ),
      if (!isSystem)
        IconButton(
          tooltip: '搜索消息',
          icon: const Icon(Icons.search_rounded),
          onPressed: () =>
              setState(() => _chatSearchVisible = !_chatSearchVisible),
        ),
      if (!isSystem)
        IconButton(
          tooltip: '导出聊天记录',
          icon: const Icon(Icons.ios_share_rounded),
          onPressed: _exportChat,
        ),
      // 文件管理（阶段 M8 文件收发管理页；Q1 真机反馈 #3：聊天内外均
      // 可管理文件；Q1 四轮问题4：固定按键恢复）
      IconButton(
        tooltip: '文件管理',
        icon: const Icon(Icons.folder_open_rounded),
        onPressed: () => showFileListDialog(context, widget.socketService),
      ),
    ];
  }

  /// 会话列表态 / 宽屏双栏态 AppBar 动作（既有工具栏，Q0 前语义不变）
  List<Widget> _buildToolbarActions() {
    return [
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

      // 文件管理（阶段 M8：P1-7 文件收发管理页；Q1 四轮问题4：固定按键恢复）
      IconButton(
        icon: const Icon(Icons.folder_open_rounded),
        tooltip: '文件管理',
        onPressed: () => showFileListDialog(context, widget.socketService),
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
    ];
  }

  /// 选择会话（侧栏点击与全局传输条跳转共用；原 inline 闭包提取）
  void _selectChat(String key) {
    _maybeFetchGroupAnnouncements(key);
    // 阶段 K2：切换会话前同步保存旧会话草稿（本地 + 服务端），
    // 再恢复新会话草稿到输入栏（先 selectChat，避免草稿回写
    // 到旧会话）
    // 系统消息会话（'服务器'）只读：不写本地草稿元数据（P-46 缺陷修复）
    final previous = _state.currentChat;
    if (previous != null && previous != key && previous != '服务器') {
      _state.setConversationDraft(previous, _inputCtrl.text);
      _flushDraft();
    }
    _state.selectChat(key);
    _inputCtrl.text = _state.draftOf(key);
    _maybeLoadInitialHistory(key);
    // R-P14：切换会话收起表情面板
    if (_emojiPanelVisible) {
      setState(() => _emojiPanelVisible = false);
    }
    // Q1 真机反馈 #3：切换会话复位 AppBar 搜索入口
    if (_chatSearchVisible) {
      setState(() => _chatSearchVisible = false);
    }
    // 阶段 Q1-1：compact 单屏切换到聊天区
    if (isCompactLayout(context)) {
      setState(() => _compactShowChat = true);
    }
  }

  /// Q1 七轮（问题1）：点击全局传输条跳转到传输所属会话
  void _jumpToTransferChat(String messageId) {
    final key = _state.chatKeyOfMessage(messageId);
    if (key == null || key == _state.currentChat) return;
    _selectChat(key);
  }

  /// Q1 七轮（问题1）：发送失败重试——文字消息走既有 pending 队列；
  /// 文件消息经 sendFile 重新走完整上传通道（源文件必须仍在本机）
  void _retrySendMessage(String messageId) {
    final msg = _state.messageById(messageId);
    if (msg == null) return;
    if (msg.type != 'file') {
      widget.socketService.retryPendingMessage(messageId);
      return;
    }
    final key = _state.currentChat;
    if (key == null || key == '服务器') return;
    var path = msg.filePath;
    if (path == null && msg.filename != null) {
      final base = msg.filename!.split(RegExp(r'[/\\]')).last;
      path = '${AppPaths.receivedFilesDir}/$base';
    }
    if (path == null || !File(path).existsSync() || msg.filename == null) {
      _state.showNotice('源文件不在本机，无法重新发送');
      return;
    }
    widget.socketService.sendFile(key, path, msg.filename!);
  }

  /// 阶段 Q1-1：compact（手机窄屏 <600）单屏布局——会话列表 ↔ 聊天区
  /// 切换（列表铺满屏宽；选中会话进聊天区，AppBar 返回控件回列表）
  Widget _buildCompactBody() {
    if (_compactShowChat && _state.currentChat != null) {
      return _buildChatArea();
    }
    return _buildSidebar(expanded: true);
  }

  /// 宽屏（桌面/平板 ≥600）：既有双栏布局（会话列表 + 聊天区同现）
  Widget _buildWideBody() {
    return Row(
      children: [
        _buildSidebar(),
        const VerticalDivider(width: 1),
        Expanded(
          child: Column(
            children: [
              Expanded(child: _buildChatArea()),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSidebar({bool expanded = false}) {
    return Sidebar(
      chatTargets: _state.chatTargets,
      currentChat: _state.currentChat,
      onSelectChat: _selectChat,
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
      expanded: expanded,
    );
  }

  /// 聊天区域（选中会话 → ChatView；未选 → 占位提示）。
  /// 宽屏由 _buildWideBody 的 Expanded 包裹；compact 聊天区直接铺满。
  Widget _buildChatArea() {
    // Q1 真机反馈 #3：compact 聊天态隐藏 ChatView 自带标题栏
    // （标题/搜索/导出移至 AppBar），搜索输入行由 AppBar 入口受控
    final compactChat = isCompactLayout(context) && _inCompactChat;
    // gc9：群会话"通话进行中"横幅（注册表快照驱动；自己在该通话中不显示）
    String? ongoingCallLabel;
    VoidCallback? onJoinOngoingCall;
    final current = _state.currentChat;
    if (current != null && current.startsWith('group_')) {
      // try 包裹：部分 Mock 测试未 stub callService getter（返回 null
      // 强转抛 TypeError）——横幅是纯增益组件，取不到即不显示
      try {
        final callSvc = widget.socketService.callService;
        final gid = int.tryParse(current.substring('group_'.length));
        final info = gid == null ? null : callSvc.knownGroupCalls[gid];
        final inThisCall = callSvc.isGroupCall &&
            callSvc.groupId == gid &&
            (callSvc.phase == CallPhase.connecting ||
                callSvc.phase == CallPhase.active ||
                callSvc.phase == CallPhase.calling);
        if (info != null && !inThisCall && gid != null) {
          ongoingCallLabel = '群通话进行中（${info.participants.length}人）· 点击加入';
          onJoinOngoingCall = () => _joinGroupCall(gid);
        }
      } catch (_) {}
    }
    return _state.currentChat != null
        ? ChatView(
            chatKey: _state.currentChat!,
            chatTitle: _state.displayNameForChat(_state.currentChat!),
            ongoingGroupCallLabel: ongoingCallLabel,
            onJoinOngoingCall: onJoinOngoingCall,
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
            isSearchMode: _state.isSearchMode(_state.currentChat!),
            searchQuery: _state.searchQueryOf(_state.currentChat!),
            onSearch: _runSearch,
            onSearchExit: _exitSearch,
            headerVisible: !compactChat,
            searchInputVisible: _chatSearchVisible,
            onSearchVisibilityChanged: compactChat
                ? (v) => setState(() => _chatSearchVisible = v)
                : null,
            // 阶段 R1/R2：宽屏头部通话入口（系统会话不提供；群聊弹群通话层）
            onVoiceCall: _state.currentChat == '服务器'
                ? null
                : () => _startCall(CallType.audio),
            onVideoCall: _state.currentChat == '服务器'
                ? null
                : () => _startCall(CallType.video),
            onRetrySend: _retrySendMessage,
            // 阶段 K2：输入变化 → 本地草稿状态 + 防抖自动保存
            onInputChanged: _onInputChanged,
            // 阶段 K5：消息操作（引用/转发/表情/仅我删除）
            onReplyMessage: _showReplyMessageDialog,
            onForwardMessage: _showForwardTargetDialog,
            onAddReaction: (messageId, emoji) {
              final key = _state.currentChat;
              if (key != null) {
                widget.socketService.addReaction(messageId, emoji, key);
              }
            },
            onDeleteMessage: (messageId) {
              final key = _state.currentChat;
              if (key != null) {
                _state.removeMessageLocally(key, messageId);
              }
            },
            // 阶段 N1（P2-2 永久删除）：本地缓存中彻底移除
            onDeletePermanently: (messageId) {
              final key = _state.currentChat;
              if (key != null) {
                widget.socketService.permanentlyDeleteMessage(key, messageId);
              }
            },
            // 阶段 N3（P2-4）/ R-P5 修订：剪贴板图片
            // → 自动进入标注编辑器（可编辑后发送，
            // 也可直接发送原图）
            onImagePasted: (bytes) {
              if (isSupportedImage(bytes)) {
                _sendImageWithEditor(bytes, filename: 'pasted_image.png');
              }
            },
            // 阶段 N3b：点击内联图片 → 全屏查看
            onImageTap: _openImageViewer,
            // 阶段 P1：点击视频气泡 → 全屏查看
            onVideoTap: _openVideoViewer,
            // R-P2：点击文件卡片 → 文件预览
            onFileTap: _openFilePreview,
            // Q1 三轮（问题8）：文件消息菜单"转发"（已下载文件重发通道）
            onForwardFile: _forwardFile,
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
            announcements:
                _state.groupAnnouncements.map((a) => a.content).toList(),
            // R-O12：公告横幅 ✕ 删除按钮（仅群主）
            announcementItems: _state.groupAnnouncements,
            onDeleteAnnouncement: _canPinCurrent
                ? (messageId) {
                    final group = _currentGroup!;
                    widget.socketService
                        .deleteGroupAnnouncement(group.id, messageId);
                    _state.removeGroupAnnouncement(messageId);
                    widget.socketService.fetchGroupAnnouncements(group.id);
                  }
                : null,
            pinnedItems: _currentGroup?.pinnedMessages,
            // O2：群主置顶群消息入口
            // （对已置顶消息菜单显示"取消置顶"）
            pinnedMessageId: _currentGroup?.pinnedMessageId,
            onPinMessage: _canPinCurrent
                ? (messageId) {
                    final group = _currentGroup!;
                    if (group.pinnedMessageId == messageId) {
                      widget.socketService.unpinGroupMessage(group.id);
                    } else {
                      widget.socketService.pinGroupMessage(group.id, messageId);
                    }
                  }
                : null,
            // O2 修订（多置顶并存）：横幅快捷取消
            onUnpinMessage: _canPinCurrent
                ? (messageId) => widget.socketService
                    .unpinGroupMessage(_currentGroup!.id, messageId: messageId)
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
                const Icon(Icons.chat_rounded, size: 64, color: Colors.grey),
                const SizedBox(height: 16),
                Text(
                  t('selectChatToStart'),
                  style: const TextStyle(color: Colors.grey, fontSize: 16),
                ),
              ],
            ),
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

  /// Q1 真机反馈 #5（沉浸式观看）：点击视频画面切换顶栏显隐
  bool _topBarVisible = true;

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
      // R-P8 软渲染契约由渲染策略驱动（Q1-3）：仅 Linux 强制软渲染
      // （虚拟机/llvmpipe/部分驱动下 H/W 路径帧不上屏），其余平台
      // （Q1 Android 真机等）恢复默认硬解。
      final software = videoSoftwareRendering();
      final controller = VideoController(
        player,
        configuration: VideoControllerConfiguration(
          enableHardwareAcceleration: !software,
          hwdec: software ? 'no' : null,
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
      // Q0-3：经平台能力抽象打开（Linux=xdg-open；其他端按平台实现）
      PlatformCapabilities.fileLauncher.openFile(path);
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
            // 顶栏：关闭 + 文件名（点击文件名同样关闭，兼容既有交互）；
            // Q1 真机反馈 #5：点击画面区域切换顶栏显隐（沉浸式观看）
            if (_topBarVisible)
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
                        style:
                            const TextStyle(color: Colors.white, fontSize: 14),
                      ),
                    ),
                  ),
                ],
              ),
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _topBarVisible = !_topBarVisible),
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
            ),
          ],
        ),
      ),
    );
  }

  /// Q1 七轮（问题1）：全局传输指示条——任何界面（列表态/聊天态/宽屏）
  /// 恒可见；逐传输显示方向/文件名/百分比 + 细进度线，点击跳转到传输
}

class _TransferBanner extends StatelessWidget {
  final List<TransferProgress> transfers;
  final String? Function(String messageId) filenameOf;
  final void Function(String messageId) onTapTransfer;

  const _TransferBanner({
    required this.transfers,
    required this.filenameOf,
    required this.onTapTransfer,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final t in transfers.take(3))
            InkWell(
              onTap: () => onTapTransfer(t.messageId),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    child: Row(
                      children: [
                        Icon(
                          t.isSend
                              ? Icons.upload_rounded
                              : Icons.download_rounded,
                          size: 16,
                          color: scheme.onSecondaryContainer,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${t.isSend ? "发送" : "接收"} '
                            '${filenameOf(t.messageId) ?? "文件"}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSecondaryContainer,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${(t.fraction * 100).round()}%',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSecondaryContainer,
                          ),
                        ),
                      ],
                    ),
                  ),
                  LinearProgressIndicator(
                    value: t.fraction,
                    minHeight: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      scheme.onSecondaryContainer,
                    ),
                    backgroundColor:
                        scheme.onSecondaryContainer.withValues(alpha: 0.2),
                  ),
                ],
              ),
            ),
          if (transfers.length > 3)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                '共 ${transfers.length} 个传输任务',
                style:
                    TextStyle(fontSize: 11, color: scheme.onSecondaryContainer),
              ),
            ),
        ],
      ),
    );
  }
}
