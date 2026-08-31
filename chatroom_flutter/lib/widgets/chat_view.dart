/// 聊天视图
///
/// 显示消息列表 + 底部输入栏。
/// 支持文本发送、文件发送、消息撤回、上滑加载历史（阶段 E）。
/// 输入框使用 RawTextField + IME 桥接，避免 Flutter + fcitx GTK IM Context 死锁。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config.dart';
import '../models/chat_models.dart';
import '../services/theme_settings.dart';
import 'raw_text_field.dart';

class ChatView extends StatefulWidget {
  final String chatKey;
  final String chatTitle;
  final List<ChatMessage> messages;
  final String username;
  final TextEditingController inputCtrl;
  final bool canSend;
  final VoidCallback onSend;
  final VoidCallback onSendFile;
  final ValueChanged<String> onRecall;
  final Future<void> Function(String? beforeMessageId) onLoadHistory;
  final bool Function(String key) hasMoreHistory;
  final double? Function(String messageId)? transferFraction;
  final bool isSearchMode; // 是否处于搜索模式（阶段 H5）
  final String searchQuery; // 搜索关键字
  final ValueChanged<String> onSearch; // 提交搜索
  final VoidCallback onSearchExit; // 退出搜索模式
  final ValueChanged<String>? onRetrySend; // 发送失败重试回调（阶段 I1）

  // ---- 阶段 K2（P1-12 逐会话草稿）----
  final ValueChanged<String>? onInputChanged; // 输入文本变化回调（草稿数据源）

  // ---- 阶段 K5（P1-2/P1-3/P1-4 消息操作）----
  final ValueChanged<String>? onReplyMessage;
  final ValueChanged<String>? onForwardMessage;
  final void Function(String messageId, String emoji)? onAddReaction;
  final ValueChanged<String>? onDeleteMessage; // 仅我删除（本地）
  final ValueChanged<String>? onDeletePermanently; // 永久删除（本地缓存，阶段 N1）
  final ValueChanged<String>? onJumpToMessage; // 点击引用块跳转原消息

  // 阶段 N3（P2-4 图片粘贴直发）：剪贴板图片回调（输入框 Ctrl+V 触发）
  final ValueChanged<Uint8List>? onImagePasted;

  // 阶段 N3b（P2-4 扩展）：点击内联图片 → 全屏查看回调
  final ValueChanged<ChatMessage>? onImageTap;

  // 阶段 N2（P2-1 聊天记录导出）：工具栏导出按钮回调（非系统会话提供）
  final VoidCallback? onExportChat;

  // ---- 阶段 O —— 群组与消息增强 ----

  // 阶段 O1：群公告横幅（非空时显示；数据源 Group.announcement——最新一条，
  // 兼容单条传参；多条公告经 announcements 参数传入）
  final String? announcement;

  // 阶段 O1 修订（2026-08-31 多公告并存）：全量公告文本列表（横幅逐条显示）
  final List<String>? announcements;

  // 阶段 O1 修订（R-O12 公告横幅删除按钮）：全量公告条目（含 id——
  // 提供即公告横幅尾部显示 ✕ 删除按钮，仅群主传入；点击回调 onDeleteAnnouncement）
  final List<GroupAnnouncement>? announcementItems;
  final ValueChanged<String>? onDeleteAnnouncement;

  // 阶段 O2：群置顶横幅（非空时显示；数据源 Group.pinnedPreview——兼容快照）
  final String? pinnedPreview;

  // 阶段 O2 修订（2026-08-31 多置顶并存）：全量置顶列表（横幅逐条显示，
  // 点击条目定位到原消息；数据源 Group.pinnedMessages）
  final List<GroupPinnedItem>? pinnedItems;

  // 阶段 O2 修订：快捷取消单条置顶（提供即显示取消按钮；仅群主传入）
  final ValueChanged<String>? onUnpinMessage;

  // 阶段 O2：置顶群消息回调（提供即群消息菜单新增"置顶"入口；
  // ChatScreen 仅对"群主 + 群会话"传入）
  final ValueChanged<String>? onPinMessage;

  // 阶段 O2（2026-08-30 用户反馈 #3）：当前已置顶的消息 id——菜单据此把
  // 该消息的"置顶"显示为"取消置顶"
  final String? pinnedMessageId;

  // 阶段 O4：快捷回复入口（提供即输入行显示"快捷回复"按钮）
  final VoidCallback? onQuickReply;

  // 阶段 O5：定时发送入口（提供即输入行显示"定时发送"按钮）
  final VoidCallback? onScheduleMessage;

  // 阶段 O9：分享卡片入口（提供即输入行显示"分享卡片"按钮）
  final VoidCallback? onShareCard;

  const ChatView({
    super.key,
    required this.chatKey,
    required this.chatTitle,
    required this.messages,
    required this.username,
    required this.inputCtrl,
    this.canSend = true,
    required this.onSend,
    required this.onSendFile,
    required this.onRecall,
    required this.onLoadHistory,
    required this.hasMoreHistory,
    this.transferFraction,
    this.isSearchMode = false,
    this.searchQuery = '',
    this.onSearch = _noopSearch,
    this.onSearchExit = _noopExit,
    this.onRetrySend,
    this.onInputChanged,
    this.onReplyMessage,
    this.onForwardMessage,
    this.onAddReaction,
    this.onDeleteMessage,
    this.onDeletePermanently,
    this.onJumpToMessage,
    this.onImagePasted,
    this.onImageTap,
    this.onExportChat,
    this.announcement,
    this.announcements,
    this.announcementItems,
    this.onDeleteAnnouncement,
    this.pinnedPreview,
    this.pinnedItems,
    this.onUnpinMessage,
    this.onPinMessage,
    this.pinnedMessageId,
    this.onQuickReply,
    this.onScheduleMessage,
    this.onShareCard,
  });

  static void _noopSearch(String _) {}
  static void _noopExit() {}

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final ScrollController _scrollCtrl = ScrollController();
  final TextEditingController _searchCtrl = TextEditingController();
  bool _isLoadingHistory = false;
  bool _searchInputVisible = false;

  /// 阶段 K5（P1-2 修复）：引用跳转的目标消息高亮（点击后闪烁约 2s）
  String? _highlightMessageId;
  Timer? _highlightTimer;

  /// 搜索入口私聊/群聊会话提供（服务端 search_history 支持 to / group_id 范围）；
  /// 系统消息会话（'服务器'，只读）不提供搜索入口
  bool get _canSearch => widget.chatKey != '服务器';

  /// 阶段 K5：是否启用消息菜单（任一 K5 回调非空；
  /// 阶段 N1：提供 onDeletePermanently 同样启用菜单模式）
  bool get _kMenuEnabled =>
      widget.onReplyMessage != null ||
      widget.onForwardMessage != null ||
      widget.onAddReaction != null ||
      widget.onDeleteMessage != null ||
      widget.onDeletePermanently != null;

  /// 提交搜索（空关键字不触发回调）
  void _submitSearch(String keyword) {
    final kw = keyword.trim();
    if (kw.isEmpty) return;
    widget.onSearch(kw);
    setState(() => _searchInputVisible = false);
  }

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    // 阶段 K2：监听输入文本变化 → onInputChanged（逐会话草稿数据源）
    widget.inputCtrl.addListener(_onInputTextChanged);
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    _highlightTimer?.cancel();
    widget.inputCtrl.removeListener(_onInputTextChanged);
    super.dispose();
  }

  void _onInputTextChanged() {
    widget.onInputChanged?.call(widget.inputCtrl.text);
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients || _isLoadingHistory) return;
    if (!widget.hasMoreHistory(widget.chatKey)) return;
    // reverse: true 的 ListView：
    //   pixels = 0 → 底部（最新消息）
    //   pixels = maxScrollExtent → 顶部（最旧消息，上滑看历史方向）
    // 用户上滑接近顶部时预加载（距顶 200px 触发，避免滑到顶才加载）
    final pos = _scrollCtrl.position;
    if (pos.maxScrollExtent - pos.pixels < 200) {
      _loadMoreHistory();
    }
  }

  Future<void> _loadMoreHistory() async {
    if (widget.messages.isEmpty) return;
    // 必须 setState：滚动事件本身不会触发 rebuild，
    // 否则"加载中…"指示器分支永远不会出现在树上
    setState(() {
      _isLoadingHistory = true;
    });
    // 当前最旧消息的 messageId 作为游标
    final beforeId = widget.messages.first.messageId;
    await widget.onLoadHistory(beforeId);
    // reverse: true 的 ListView：新消息插入到列表头部（视觉顶部/旧消息方向），
    // Flutter 自动保持当前可见消息的滚动位置，无需手动调整
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() {
          _isLoadingHistory = false;
        });
      }
    });
  }

  /// 阶段 K5（P1-2 修复）：点击引用块跳转到被引用的原消息
  ///
  /// 修复内容（2026-08-18，P-30 手动测试发现）：
  /// ① 跳转目标应为 message.replyTo（原实现误跳当前消息自身，点击无效果）；
  /// ② 长会话分页后目标消息可能未加载：先按最旧游标翻页加载历史，
  ///    直到找到目标或没有更早消息（上限 30 页防死循环）；
  /// ③ 跳转后目标气泡高亮闪烁约 2s，便于在长列表中定位。
  /// 滚动定位为 reverse 列表按序号比例的近似定位（无逐项测量依赖）。
  Future<void> _jumpToMessage(String messageId) async {
    var idx = widget.messages.indexWhere((m) => m.messageId == messageId);
    // 目标未加载 → 循环加载更早历史直到找到或没有更早消息
    var pages = 0;
    while (idx < 0 &&
        !widget.isSearchMode &&
        widget.hasMoreHistory(widget.chatKey) &&
        widget.messages.isNotEmpty &&
        pages < 30) {
      final oldestId = widget.messages.first.messageId;
      await widget.onLoadHistory(oldestId);
      pages++;
      idx = widget.messages.indexWhere((m) => m.messageId == messageId);
    }
    if (idx < 0 || !_scrollCtrl.hasClients) return;
    final total = widget.messages.length;
    final visualIndex = total - 1 - idx; // reverse 列表的视觉序号
    final max = _scrollCtrl.position.maxScrollExtent;
    if (total <= 1 || max <= 0) return;
    final target = (max * visualIndex / (total - 1)).clamp(0.0, max);
    await _scrollCtrl.animateTo(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
    if (mounted) _flashHighlight(messageId);
  }

  /// 目标消息高亮闪烁（约 2s 后自动清除）
  void _flashHighlight(String messageId) {
    _highlightTimer?.cancel();
    setState(() => _highlightMessageId = messageId);
    _highlightTimer = Timer(const Duration(milliseconds: 2000), () {
      if (mounted) setState(() => _highlightMessageId = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 标题栏
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            border: Border(
              bottom: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant),
            ),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                child: Icon(
                  widget.chatKey.startsWith('group_')
                      ? Icons.groups_rounded
                      : widget.chatKey == '服务器'
                          ? Icons.notifications_rounded
                          : Icons.person_rounded,
                  size: 20,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.isSearchMode
                      ? '搜索：${widget.searchQuery}'
                      : (widget.chatKey.startsWith('group_') ||
                              widget.chatKey == '服务器'
                          ? widget.chatTitle
                          : '与 ${widget.chatTitle} 的聊天'),
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ),
              // 搜索模式：返回按钮；非搜索模式：搜索入口（仅私聊会话）
              if (widget.isSearchMode)
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  tooltip: '退出搜索',
                  onPressed: widget.onSearchExit,
                )
              else if (_canSearch)
                IconButton(
                  icon: const Icon(Icons.search_rounded),
                  tooltip: '搜索消息',
                  onPressed: () => setState(() => _searchInputVisible = true),
                ),
              // 阶段 N2（P2-1 聊天记录导出）：按会话导出 TXT/JSON
              if (widget.chatKey != '服务器' && widget.onExportChat != null)
                IconButton(
                  icon: const Icon(Icons.ios_share_rounded),
                  tooltip: '导出聊天记录',
                  onPressed: widget.onExportChat,
                ),
            ],
          ),
        ),

        // 搜索输入栏（点击搜索按钮后展开，阶段 H5）
        if (_searchInputVisible)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              border: Border(
                bottom: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: RawTextField(
                    key: const ValueKey('search_field'),
                    controller: _searchCtrl,
                    hintText: '搜索历史消息...',
                    showChineseInput: true,
                    onSubmitted: _submitSearch,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.search_rounded),
                  tooltip: '搜索',
                  onPressed: () => _submitSearch(_searchCtrl.text),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: '关闭搜索',
                  onPressed: () => setState(() => _searchInputVisible = false),
                ),
              ],
            ),
          ),

        // 阶段 O1/O2：群公告 / 群置顶横幅（消息区上方）。
        // 2026-08-31 修订（多公告/多置顶并存）：逐条显示；置顶条目点击定位
        // 到原消息（复用引用跳转的滚动+高亮），并提供快捷取消置顶按钮。
        ..._buildNoticeBanners(context),
        Expanded(
          // 阶段 O7（2026-08-30 用户反馈 #8）：聊天背景色应用于消息区域
          child: ColoredBox(
            color: ThemeSettings.instance.chatBackground == null
                ? Theme.of(context).colorScheme.surface
                : Color(ThemeSettings.instance.chatBackground!),
            child: widget.messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.forum_outlined,
                          size: 56,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          widget.isSearchMode ? '无搜索结果' : '暂无消息',
                          style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  )
                : Stack(
                    children: [
                      ListView.builder(
                        controller: _scrollCtrl,
                        reverse: true,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        itemCount: widget.messages.length,
                        itemBuilder: (context, index) {
                          final msgIndex = widget.messages.length - 1 - index;
                          final msg = widget.messages[msgIndex];
                          return _MessageBubble(
                            message: msg,
                            isSelf: msg.sender == widget.username,
                            onRecall:
                                msg.isRecalled || msg.sender != widget.username
                                    ? null
                                    : () => widget.onRecall(msg.messageId),
                            transferFraction: msg.type == 'file'
                                ? widget.transferFraction?.call(msg.messageId)
                                : null,
                            onRetrySend: msg.sender == widget.username
                                ? widget.onRetrySend
                                : null,
                            kMenuEnabled: _kMenuEnabled,
                            onReplyMessage: widget.onReplyMessage,
                            onForwardMessage: widget.onForwardMessage,
                            onAddReaction: widget.onAddReaction,
                            onDeleteMessage: widget.onDeleteMessage,
                            onDeletePermanently: widget.onDeletePermanently,
                            onJumpToMessage: widget.onJumpToMessage,
                            onImageTap: widget.onImageTap,
                            // 阶段 O2：群消息"置顶"入口（群主接线由上层控制）
                            onPinMessage: widget.onPinMessage,
                            pinnedMessageId: widget.pinnedMessageId,
                            // 跳转目标是被引用的原消息（P-30 修复）
                            onJump: () =>
                                _jumpToMessage(msg.replyTo ?? msg.messageId),
                            highlighted: msg.messageId == _highlightMessageId,
                          );
                        },
                      ),
                      // 加载指示器
                      if (_isLoadingHistory)
                        Positioned(
                          top: 8,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 8),
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '加载中…',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ),

        // 输入栏（搜索模式下隐藏，阶段 H5）
        if (widget.isSearchMode)
          const SizedBox.shrink()
        else if (widget.canSend)
          _InputBar(
            inputCtrl: widget.inputCtrl,
            onSend: widget.onSend,
            onSendFile: widget.onSendFile,
            canSend: widget.canSend,
            onImagePasted: widget.onImagePasted,
            // 阶段 O：快捷回复 / 定时发送 / 分享卡片入口（提供即渲染）
            onQuickReply: widget.onQuickReply,
            onScheduleMessage: widget.onScheduleMessage,
            onShareCard: widget.onShareCard,
          )
        else
          _ReadOnlyBar(chatTitle: widget.chatTitle),
      ],
    );
  }

  /// 阶段 O1/O2（2026-08-31 多公告/多置顶并存）：构建横幅列表。
  /// 公告逐条展示；置顶逐条展示，条目点击定位原消息（_jumpToMessage：
  /// 未加载时翻页加载 + 高亮 2s），条目尾部快捷取消按钮直接解除该条置顶。
  List<Widget> _buildNoticeBanners(BuildContext context) {
    final banners = <Widget>[];
    // R-O12：announcementItems 提供时横幅带 ✕ 删除按钮（仅群主）
    final hasDelete = widget.onDeleteAnnouncement != null;
    if (widget.announcementItems != null) {
      for (final a in widget.announcementItems!) {
        if (a.content.isEmpty) continue;
        banners.add(_NoticeBanner(
          marker: '📢',
          text: a.content,
          trailing: hasDelete
              ? IconButton(
                  key: ValueKey('announcement_delete_${a.messageId}'),
                  icon: const Icon(Icons.close_rounded, size: 16),
                  tooltip: '删除公告',
                  onPressed: () => widget.onDeleteAnnouncement!(a.messageId),
                )
              : null,
        ));
      }
    } else {
      final announcements = <String>[
        if (widget.announcement != null && widget.announcement!.isNotEmpty)
          widget.announcement!,
        ...(widget.announcements ?? const <String>[]),
      ];
      for (final text in announcements) {
        if (text.isEmpty) continue;
        banners.add(_NoticeBanner(
          marker: '📢',
          text: text,
        ));
      }
    }
    // 兼容快照（pinnedPreview）：无 id 仅展示，不可定位/取消
    final compatPreview = widget.pinnedPreview;
    final pins = <GroupPinnedItem>[
      if (compatPreview != null && compatPreview.isNotEmpty)
        GroupPinnedItem(messageId: '', preview: compatPreview),
      ...(widget.pinnedItems ?? const <GroupPinnedItem>[]),
    ];
    for (final pin in pins) {
      if (pin.preview.isEmpty) continue;
      banners.add(_NoticeBanner(
        marker: '📌',
        text: pin.preview,
        onTap:
            pin.messageId.isEmpty ? null : () => _jumpToMessage(pin.messageId),
        trailing: widget.onUnpinMessage == null || pin.messageId.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close_rounded, size: 16),
                tooltip: '取消置顶',
                onPressed: () => widget.onUnpinMessage!(pin.messageId),
              ),
      ));
    }
    return banners;
  }
}

class _InputBar extends StatelessWidget {
  final TextEditingController inputCtrl;
  final VoidCallback onSend;
  final VoidCallback onSendFile;
  final bool canSend; // 阶段 N3：系统会话只读不接收图片粘贴
  final ValueChanged<Uint8List>? onImagePasted;

  // ---- 阶段 O：快捷回复（O4）/ 定时发送（O5）/ 分享卡片（O9）入口 ----
  final VoidCallback? onQuickReply;
  final VoidCallback? onScheduleMessage;
  final VoidCallback? onShareCard;

  const _InputBar({
    required this.inputCtrl,
    required this.onSend,
    required this.onSendFile,
    this.canSend = true,
    this.onImagePasted,
    this.onQuickReply,
    this.onScheduleMessage,
    this.onShareCard,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.attach_file),
            tooltip: '发送文件',
            onPressed: onSendFile,
          ),
          // 阶段 O4：快捷回复（常用语一键发送）
          if (onQuickReply != null)
            IconButton(
              icon: const Icon(Icons.bolt_rounded),
              tooltip: '快捷回复',
              onPressed: onQuickReply,
            ),
          // 阶段 O5：定时发送（预约发送）
          if (onScheduleMessage != null)
            IconButton(
              icon: const Icon(Icons.schedule_rounded),
              tooltip: '定时发送',
              onPressed: onScheduleMessage,
            ),
          // 阶段 O9：分享卡片（名片/位置/日程）
          if (onShareCard != null)
            IconButton(
              icon: const Icon(Icons.style_rounded),
              tooltip: '分享卡片',
              onPressed: onShareCard,
            ),
          Expanded(
            child: RawTextField(
              controller: inputCtrl,
              hintText: '输入消息，Enter 发送...',
              showChineseInput: true,
              onSubmitted: (_) => onSend(),
              // 阶段 N3（P2-4）：剪贴板图片 → 上层预览（仅非只读会话）
              onImagePasted: canSend ? onImagePasted : null,
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            icon: const Icon(Icons.send_rounded),
            tooltip: '发送',
            onPressed: onSend,
          ),
        ],
      ),
    );
  }
}

class _NoticeBanner extends StatelessWidget {
  final String marker;
  final String text;
  final VoidCallback? onTap; // 点击条目（置顶定位到原消息）
  final Widget? trailing; // 条目尾部控件（快捷取消置顶按钮）

  const _NoticeBanner({
    required this.marker,
    required this.text,
    this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .primaryContainer
            .withValues(alpha: 0.45),
        border: Border(
          bottom:
              BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: onTap,
              child: Text(
                '$marker $text',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _ReadOnlyBar extends StatelessWidget {
  final String chatTitle;

  const _ReadOnlyBar({required this.chatTitle});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      child: Text(
        '$chatTitle 为只读会话',
        textAlign: TextAlign.center,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}

/// 单条消息气泡
class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isSelf;
  final VoidCallback? onRecall; // null 表示不可撤回
  final double? transferFraction; // 传输进度 0~1；null 表示无传输（阶段 G 可视化）
  final ValueChanged<String>? onRetrySend; // 发送失败重试（阶段 I1）

  // ---- 阶段 K5：消息菜单与操作回调 ----
  final bool kMenuEnabled;
  final ValueChanged<String>? onReplyMessage;
  final ValueChanged<String>? onForwardMessage;
  final void Function(String messageId, String emoji)? onAddReaction;
  final ValueChanged<String>? onDeleteMessage; // 仅我删除（本地）
  final ValueChanged<String>? onDeletePermanently; // 永久删除（阶段 N1）
  final ValueChanged<String>? onJumpToMessage;
  final VoidCallback onJump; // 内部跳转（引用块点击）
  final bool highlighted; // 引用跳转高亮（P-30）
  final ValueChanged<ChatMessage>? onImageTap; // 阶段 N3b：点击内联图片全屏

  // 阶段 O2：置顶群消息回调（提供且为群聊消息时菜单出现"置顶"入口）
  final ValueChanged<String>? onPinMessage;

  // 当前已置顶消息 id（该消息菜单显示"取消置顶"）
  final String? pinnedMessageId;

  const _MessageBubble({
    required this.message,
    required this.isSelf,
    this.onRecall,
    this.transferFraction,
    this.onRetrySend,
    this.kMenuEnabled = false,
    this.onReplyMessage,
    this.onForwardMessage,
    this.onAddReaction,
    this.onDeleteMessage,
    this.onDeletePermanently,
    this.onJumpToMessage,
    required this.onJump,
    this.highlighted = false,
    this.onImageTap,
    this.onPinMessage,
    this.pinnedMessageId,
  });

  /// 阶段 K5：文字/文件消息且提供 K5 回调时启用消息菜单
  /// （P-33 修订 2026-08-18：文件消息改用新菜单交互——长按弹菜单，
  /// 菜单内仅"撤回"入口；系统/已撤回消息仍不弹菜单）
  bool get _showMenu =>
      kMenuEnabled && message.type != 'system' && !message.isRecalled;

  void _openMenu(BuildContext context) {
    if (!_showMenu) return;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => _MessageMenuSheet(
        message: message,
        isSelf: isSelf,
        onRecall: onRecall,
        onReplyMessage: onReplyMessage,
        onForwardMessage: onForwardMessage,
        onAddReaction: onAddReaction,
        onDeleteMessage: onDeleteMessage,
        onDeletePermanently: onDeletePermanently,
        onPinMessage: onPinMessage,
        pinnedMessageId: pinnedMessageId,
      ),
    );
  }

  // ---- 阶段 O1：群公告 / O9：卡片消息渲染 ----

  // ---- 阶段 N3b：小图片内联展示 ----

  /// 是否为可内联展示的图片文件消息（未撤回 + 图片扩展名 + 有可用字节/路径）。
  /// 阶段 N3b 修复（用户实测破图）：传输进行中（transferFraction 非空）
  /// 不内联——文件尚未完整落盘时 Image.file 加载失败即显示破图且不重试；
  /// 传输完成后 removeTransfer 触发重建，此时文件完整再渲染。
  bool get _isInlineImage {
    if (message.type != 'file' || message.isRecalled) return false;
    if (!isImageFilename(message.filename ?? '')) return false;
    if (transferFraction != null) return false;
    if (message.fileData != null) return true;
    final path = _resolvedImagePath;
    return path != null && File(path).existsSync();
  }

  /// 解析图片的本地磁盘路径（filePath 优先，否则按文件名回推 received_files）
  String? get _resolvedImagePath {
    final fp = message.filePath;
    if (fp != null) return fp;
    final name = message.filename;
    if (name == null) return null;
    final base = name.split(RegExp(r'[/\\]')).last;
    return '${AppConfig.receivedFilesDir}/$base';
  }

  /// 构建内联缩略图（字节优先 Image.memory，否则 Image.file）
  Widget _buildInlineImage() {
    Widget image;
    if (message.fileData != null) {
      image = Image.memory(
        message.fileData!,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) =>
            const Icon(Icons.broken_image_outlined, size: 40),
      );
    } else {
      image = Image.file(
        File(_resolvedImagePath!),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) =>
            const Icon(Icons.broken_image_outlined, size: 40),
      );
    }
    return SizedBox(width: 200, height: 180, child: image);
  }

  @override
  Widget build(BuildContext context) {
    if (message.type == 'system') {
      return _SystemMessage(message: message);
    }
    // 阶段 O1：群公告以居中胶囊样式渲染（📢 + 公告文本）
    if (message.type == 'group_announcement') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 18),
        child: Align(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            constraints: const BoxConstraints(maxWidth: 420),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              '📢 ${message.content}',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }
    final isRecalled = message.isRecalled;
    final alignment =
        isSelf ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final color = isSelf
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.surfaceContainerHighest;

    // 阶段 I1：自己发送失败的消息可点击重试（与长按撤回共存）。
    // 文件消息不走文字发送队列（传输进度条承载状态），不提供重试交互。
    final retryable = isSelf && message.isFailed && message.type != 'file';
    // 阶段 N3b：图片文件消息点击打开全屏查看器
    final imageTap = _isInlineImage && onImageTap != null
        ? () => onImageTap!(message)
        : null;
    // 阶段 K5：菜单启用时文字消息改用菜单；否则保持既有直接撤回交互（回归）
    final VoidCallback? menuOrRecall =
        _showMenu ? () => _openMenu(context) : onRecall;
    return MouseRegion(
      cursor: onRecall == null && !_showMenu && imageTap == null
          ? MouseCursor.defer
          : SystemMouseCursors.click,
      child: GestureDetector(
        onLongPress: menuOrRecall,
        onSecondaryTap: menuOrRecall,
        onTap: imageTap ??
            (retryable ? () => onRetrySend?.call(message.messageId) : null),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
          decoration: highlighted
              ? BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.25),
                )
              : null,
          child: Column(
            crossAxisAlignment: alignment,
            children: [
              // 发送者名称 + 时间
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!isSelf)
                    Text(
                      message.sender,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[600],
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  if (!isSelf) const SizedBox(width: 8),
                  Text(
                    _formatTime(message.timestamp),
                    style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              // 阶段 K5：引用块（原文缩略 + 点击跳转）
              if (message.hasQuote)
                GestureDetector(
                  onTap: () {
                    onJumpToMessage?.call(message.replyTo!);
                    onJump();
                  },
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 4),
                    constraints: const BoxConstraints(maxWidth: 320),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(8),
                      border: const Border(
                        left: BorderSide(color: Colors.grey, width: 3),
                      ),
                    ),
                    child: Text(
                      message.replyPreview ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                        color: Colors.grey[600],
                      ),
                    ),
                  ),
                ),
              // 消息内容气泡
              Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.58,
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: isRecalled ? Colors.grey.shade200 : color,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(18),
                    topRight: const Radius.circular(18),
                    bottomLeft: isSelf
                        ? const Radius.circular(18)
                        : const Radius.circular(4),
                    bottomRight: isSelf
                        ? const Radius.circular(4)
                        : const Radius.circular(18),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (isRecalled)
                      Text(
                        // 文件撤回：保留消息体并附加"已撤回"标志（不替换为"[消息已撤回]"）
                        message.type == 'file'
                            ? '${message.content} [已撤回]'
                            : '${message.sender}: [消息已撤回]',
                        style: TextStyle(
                          color: Colors.grey[500],
                          fontStyle: FontStyle.italic,
                        ),
                      )
                    else if (_isInlineImage)
                      // 阶段 N3b：图片文件消息内联展示（缩略图）
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: _buildInlineImage(),
                      )
                    else
                      Text(
                        message.type == 'system'
                            ? message.content
                            : message.content,
                        style: TextStyle(
                          color: isSelf
                              ? Theme.of(context).colorScheme.onPrimary
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    // 阶段 I1：发送中/发送失败状态标记（仅自己的文字消息；
                    // 文件消息由传输进度条承载，不显示）
                    if (isSelf && message.isSending && message.type != 'file')
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 10,
                              height: 10,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '发送中…',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.white.withValues(alpha: 0.85),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (isSelf &&
                        message.isFailed &&
                        message.type != 'file' &&
                        onRetrySend == null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.error_outline_rounded,
                              size: 13,
                              color: Colors.white.withValues(alpha: 0.9),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '发送失败，点击重试',
                              style: TextStyle(
                                fontSize: 11,
                                decoration: TextDecoration.underline,
                                color: Colors.white.withValues(alpha: 0.9),
                              ),
                            ),
                          ],
                        ),
                      ),
                    // 文件传输进度条（阶段 G：传输可视化，非模态局部刷新）
                    // 进度条颜色与气泡底色刻意区分：
                    //   自己的气泡（primary 底）→ 白色进度条
                    //   对方的气泡（浅色底）→ primary 色进度条
                    if (transferFraction != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: SizedBox(
                          width: 160,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(3),
                                child: LinearProgressIndicator(
                                  value: transferFraction,
                                  minHeight: 5,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    isSelf
                                        ? Colors.white
                                        : Theme.of(context).colorScheme.primary,
                                  ),
                                  backgroundColor: isSelf
                                      ? Colors.white.withValues(alpha: 0.35)
                                      : Theme.of(context)
                                          .colorScheme
                                          .outlineVariant,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '${(transferFraction! * 100).round()}%',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: isSelf
                                      ? Colors.white.withValues(alpha: 0.9)
                                      : Colors.grey[600],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // 阶段 K5：表情回应 chips（emoji 计数 + 点击触发 onAddReaction；
              // NotoColorEmoji 字体保证彩色渲染）
              if (message.reactions.isNotEmpty && !isRecalled)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(
                    spacing: 6,
                    children: [
                      for (final entry in message.reactions.entries)
                        GestureDetector(
                          onTap: () =>
                              onAddReaction?.call(message.messageId, entry.key),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              '${entry.key} ${entry.value.length}',
                              style: const TextStyle(
                                fontSize: 12,
                                fontFamily: 'NotoColorEmoji',
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    // 当天消息：仅显示 HH:MM
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '$h:$m';
    }
    // 隔天消息：显示 MM-DD HH:MM
    final mo = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$mo-$d $h:$m';
  }
}

class _SystemMessage extends StatelessWidget {
  final ChatMessage message;

  const _SystemMessage({required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Center(
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.62,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            message.content,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSecondaryContainer,
            ),
          ),
        ),
      ),
    );
  }
}

/// 阶段 K5：消息操作菜单（编辑/引用回复/转发/表情回应/撤回）
class _MessageMenuSheet extends StatefulWidget {
  final ChatMessage message;
  final bool isSelf;
  final VoidCallback? onRecall;
  final ValueChanged<String>? onReplyMessage;
  final ValueChanged<String>? onForwardMessage;
  final void Function(String messageId, String emoji)? onAddReaction;
  final ValueChanged<String>? onDeleteMessage; // 仅我删除（本地）
  final ValueChanged<String>? onDeletePermanently; // 永久删除（阶段 N1）
  final ValueChanged<String>? onPinMessage; // 置顶群消息（阶段 O2，群主）
  final String? pinnedMessageId; // 当前已置顶消息 id（文案切换"取消置顶"）

  const _MessageMenuSheet({
    required this.message,
    required this.isSelf,
    this.onRecall,
    this.onReplyMessage,
    this.onForwardMessage,
    this.onAddReaction,
    this.onDeleteMessage,
    this.onDeletePermanently,
    this.onPinMessage,
    this.pinnedMessageId,
  });

  @override
  State<_MessageMenuSheet> createState() => _MessageMenuSheetState();
}

class _MessageMenuSheetState extends State<_MessageMenuSheet> {
  bool _showEmojiPalette = false;

  void _close() => Navigator.pop(context);

  void _invoke(VoidCallback action) {
    _close();
    action();
  }

  /// 阶段 N1（P2-2）：复制消息内容文本到剪贴板
  /// （复制 content 本体，非引用缩略 replyPreview）
  void _copyMessage() {
    Clipboard.setData(ClipboardData(text: widget.message.content));
  }

  @override
  Widget build(BuildContext context) {
    final canEditOrRecall = widget.isSelf;
    // 文件消息（P-33 修订 2026-08-18）：菜单仅提供"撤回"入口
    // （文件不支持引用/转发/表情/仅我删除；阶段 N1 亦不新增复制/永久删除）
    final isFile = widget.message.type == 'file';
    final entries = <Widget>[];
    // 阶段 N1（P2-2）：复制——文字消息可复制内容文本（复制与归属无关）
    if (!isFile) {
      entries.add(_MenuTile(
        icon: Icons.copy_rounded,
        title: '复制',
        onTap: () => _invoke(_copyMessage),
      ));
    }
    // 阶段 O2：置顶群消息（仅群聊消息且提供回调时——群主接线由上层控制）
    if (!isFile &&
        widget.onPinMessage != null &&
        widget.message.type == 'group_chat') {
      final isPinned = widget.pinnedMessageId == widget.message.messageId;
      entries.add(_MenuTile(
        icon: Icons.push_pin_outlined,
        title: isPinned ? '取消置顶' : '置顶',
        onTap: () =>
            _invoke(() => widget.onPinMessage!(widget.message.messageId)),
      ));
    }
    if (!isFile && widget.onReplyMessage != null) {
      entries.add(_MenuTile(
        icon: Icons.reply_rounded,
        title: '引用回复',
        onTap: () =>
            _invoke(() => widget.onReplyMessage!(widget.message.messageId)),
      ));
    }
    if (!isFile && widget.onForwardMessage != null) {
      entries.add(_MenuTile(
        icon: Icons.forward_rounded,
        title: '转发',
        onTap: () =>
            _invoke(() => widget.onForwardMessage!(widget.message.messageId)),
      ));
    }
    if (!isFile && widget.onAddReaction != null) {
      entries.add(_MenuTile(
        icon: Icons.add_reaction_outlined,
        title: '表情回应',
        onTap: () => setState(() => _showEmojiPalette = !_showEmojiPalette),
      ));
    }
    if (canEditOrRecall && widget.onRecall != null) {
      entries.add(_MenuTile(
        icon: Icons.undo_rounded,
        title: '撤回',
        onTap: () => _invoke(widget.onRecall!),
      ));
    }
    // 仅我删除（本地，微信式）：仅自己的文字消息，从自己界面移除
    if (!isFile && canEditOrRecall && widget.onDeleteMessage != null) {
      entries.add(_MenuTile(
        icon: Icons.delete_outline_rounded,
        title: '仅我删除',
        onTap: () =>
            _invoke(() => widget.onDeleteMessage!(widget.message.messageId)),
      ));
    }
    // 阶段 N1（P2-2）：永久删除——本地缓存中彻底移除（内存 + MessageCache，
    // 重登后不恢复；与"仅我删除"的内存语义区分）。文字消息均可，
    // 与归属无关（本地缓存语义，非权限操作）。
    if (!isFile && widget.onDeletePermanently != null) {
      entries.add(_MenuTile(
        icon: Icons.delete_forever_outlined,
        title: '永久删除',
        onTap: () => _invoke(
            () => widget.onDeletePermanently!(widget.message.messageId)),
      ));
    }

    return SafeArea(
      // 阶段 N1：菜单条目增多（复制/永久删除）后小视口可能放不下，
      // 改为可滚动，保证全部入口可达
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ...entries,
              if (_showEmojiPalette)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      for (final emoji in defaultReactionEmojis)
                        ActionChip(
                          label: Text(emoji,
                              style: const TextStyle(
                                  fontFamily: 'NotoColorEmoji')),
                          onPressed: () => _invoke(() => widget.onAddReaction!(
                              widget.message.messageId, emoji)),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MenuTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;

  const _MenuTile({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // 阶段 N1：菜单条目增多（复制/永久删除）后压缩纵向占位
    // （visualDensity 紧凑 + 字号 14），保证小视口下全部条目可见
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: Icon(icon, size: 20),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      onTap: onTap,
    );
  }
}
