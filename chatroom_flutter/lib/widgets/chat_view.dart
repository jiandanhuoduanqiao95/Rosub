/// 聊天视图
///
/// 显示消息列表 + 底部输入栏。
/// 支持文本发送、文件发送、消息撤回、上滑加载历史（阶段 E）。
/// 输入框经 AdaptiveTextField 适配层（Q0-2）：Linux 渲染 RawTextField +
/// IME 桥接（避免 Flutter + fcitx GTK IM Context 死锁），其余平台标准输入。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config.dart';
import '../services/app_paths.dart';
import '../models/chat_models.dart';
import '../platform/capabilities.dart';
import '../services/theme_settings.dart';
import 'adaptive_text_field.dart';
import 'responsive_layout.dart';

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

  // 阶段 P1（富媒体消息气泡）：点击视频气泡 → 全屏查看回调
  final ValueChanged<ChatMessage>? onVideoTap;

  // R-P2（文件预览）：点击文件卡片 → 预览回调
  final ValueChanged<ChatMessage>? onFileTap;

  // Q1 三轮（问题8 文件转发）：文件消息菜单"转发"回调
  // （已下载文件经 sendFile 本地重发；提供即显示入口）
  final ValueChanged<ChatMessage>? onForwardFile;

  // R-P3（收藏表情）：图片消息菜单"添加到表情包"回调（提供即显示入口）
  final ValueChanged<ChatMessage>? onSaveSticker;

  // 阶段 N2（P2-1 聊天记录导出）：工具栏导出按钮回调（非系统会话提供）
  final VoidCallback? onExportChat;

  // ---- 阶段 O —— 群组与消息增强 ----

  // gc9：群通话进行中横幅（非空时消息区上方显示"点击加入"条目——
  // knownGroupCalls 注册表驱动，挂断退出/中途加入的显眼入口）
  final String? ongoingGroupCallLabel;
  final VoidCallback? onJoinOngoingCall;

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

  // 阶段 P2（表情包体系）：表情包入口（提供即输入行显示"表情包"按钮）
  final VoidCallback? onShowStickerPicker;

  // R-P14（微信式嵌入式面板）：表情/表情包面板，非空时渲染在输入栏上方
  // （输入栏保持可见，用户能看到自己输入的内容）
  final Widget? emojiPanel;

  // 阶段 P3（复合条件消息搜索）：高级搜索入口（搜索栏展开时显示）
  final VoidCallback? onAdvancedSearch;

  // 阶段 O5：定时发送入口（提供即输入行显示"定时发送"按钮）
  final VoidCallback? onScheduleMessage;

  // 阶段 O9：分享卡片入口（提供即输入行显示"分享卡片"按钮）
  final VoidCallback? onShareCard;

  // Q1 真机反馈（顶栏遮挡聊天区）：false = 隐藏自带标题栏
  // （compact 聊天态标题移至 AppBar——居中用户名 + 搜索/导出/文件管理）
  final bool headerVisible;

  // Q1 真机反馈：搜索入口受控模式——onSearchVisibilityChanged 非空时
  // 搜索输入行显隐由 [searchInputVisible] 驱动（compact 下入口在 AppBar）；
  // 为空时保持内部状态自治（桌面既有行为不变）
  final bool searchInputVisible;
  final ValueChanged<bool>? onSearchVisibilityChanged;

  // 阶段 R1：通话入口（仅私聊会话由 ChatScreen 提供；null 不渲染）
  final VoidCallback? onVoiceCall;
  final VoidCallback? onVideoCall;

  const ChatView({
    super.key,
    required this.chatKey,
    required this.chatTitle,
    required this.messages,
    required this.username,
    required this.inputCtrl,
    this.ongoingGroupCallLabel,
    this.onJoinOngoingCall,
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
    this.onVideoTap,
    this.onFileTap,
    this.onForwardFile,
    this.onSaveSticker,
    this.onShowStickerPicker,
    this.onAdvancedSearch,
    this.emojiPanel,
    this.headerVisible = true,
    this.searchInputVisible = false,
    this.onSearchVisibilityChanged,
    this.onVoiceCall,
    this.onVideoCall,
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
  bool _showScrollToBottom = false;

  /// 搜索模式查询词同步标记（didUpdateWidget 预填输入行，避免 build 中改 controller）
  String _lastSyncedQuery = '';

  /// 阶段 K5（P1-2 修复）：引用跳转的目标消息高亮（点击后闪烁约 2s）
  String? _highlightMessageId;
  Timer? _highlightTimer;

  /// 搜索入口私聊/群聊会话提供（服务端 search_history 支持 to / group_id 范围）；
  /// 系统消息会话（'服务器'，只读）不提供搜索入口
  bool get _canSearch => widget.chatKey != '服务器';

  /// 搜索输入行显隐（受控模式：入口在 AppBar 的 compact；自治模式：桌面）
  bool get _searchVisible => widget.onSearchVisibilityChanged != null
      ? widget.searchInputVisible
      : _searchInputVisible;

  void _setSearchVisible(bool visible) {
    if (widget.onSearchVisibilityChanged != null) {
      widget.onSearchVisibilityChanged!(visible);
    } else {
      setState(() => _searchInputVisible = visible);
    }
  }

  /// 阶段 K5：是否启用消息菜单（任一 K5 回调非空；
  /// 阶段 N1：提供 onDeletePermanently 同样启用菜单模式；
  /// Q1 三轮：提供 onForwardFile（文件转发）同样启用）
  bool get _kMenuEnabled =>
      widget.onReplyMessage != null ||
      widget.onForwardMessage != null ||
      widget.onAddReaction != null ||
      widget.onDeleteMessage != null ||
      widget.onDeletePermanently != null ||
      widget.onForwardFile != null ||
      widget.onSaveSticker != null;

  /// 提交搜索（空关键字不触发回调）
  void _submitSearch(String keyword) {
    final kw = keyword.trim();
    if (kw.isEmpty) return;
    widget.onSearch(kw);
    _setSearchVisible(false);
  }

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    // 阶段 K2：监听输入文本变化 → onInputChanged（逐会话草稿数据源）
    widget.inputCtrl.addListener(_onInputTextChanged);
    _syncSearchQuery();
  }

  @override
  void didUpdateWidget(covariant ChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncSearchQuery();
  }

  /// 无头模式（compact）搜索行常驻于搜索结果态：查询词变化时同步预填
  /// （构造即处于搜索态的场景在 initState 覆盖）
  void _syncSearchQuery() {
    if (widget.isSearchMode && widget.searchQuery != _lastSyncedQuery) {
      _lastSyncedQuery = widget.searchQuery;
      if (_searchCtrl.text != widget.searchQuery) {
        _searchCtrl.text = widget.searchQuery;
      }
    }
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
    // 阶段 P5：离开底部（reverse 列表 pixels > 阈值）时显示"回到底部"按钮
    final away = _scrollCtrl.position.pixels > 240;
    if (away != _showScrollToBottom) {
      setState(() => _showScrollToBottom = away);
    }
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
    final header = _buildHeader(context);
    // 无头模式（compact 聊天态）：搜索结果态下搜索行常驻（含退出搜索出口）
    final showSearchRow =
        _searchVisible || (widget.isSearchMode && !widget.headerVisible);
    return Column(
      children: [
        // 标题栏（compact 聊天态隐藏——标题/搜索/导出移至 AppBar，Q1 真机反馈）
        if (widget.headerVisible) header,

        // 搜索输入栏（点击搜索按钮后展开，阶段 H5）
        if (showSearchRow)
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
                  child: AdaptiveTextField(
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
                // 阶段 P3：高级搜索（复合条件：发送者/时间/关键词组合）
                if (widget.onAdvancedSearch != null)
                  IconButton(
                    icon: const Icon(Icons.filter_list_rounded),
                    tooltip: '高级搜索',
                    onPressed: widget.onAdvancedSearch,
                  ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: '关闭搜索',
                  onPressed: () => _setSearchVisible(false),
                ),
                // 无头模式：搜索结果态的退出出口（原头部退出按钮迁移至此）
                if (widget.isSearchMode && !widget.headerVisible)
                  IconButton(
                    icon: const Icon(Icons.arrow_back_rounded),
                    tooltip: '退出搜索',
                    onPressed: widget.onSearchExit,
                  ),
              ],
            ),
          ),

        // 阶段 O1/O2：群公告 / 群置顶横幅（消息区上方）。
        // 2026-08-31 修订（多公告/多置顶并存）：逐条显示；置顶条目点击定位
        // 到原消息（复用引用跳转的滚动+高亮），并提供快捷取消置顶按钮。
        // R-P6 修订（用户实测溢出）：横幅整体限高 35% 视口并可滚动——
        // 横幅条数不定，无界铺开会撑爆主 Column（RenderFlex overflowed）。
        ..._buildNoticeBannersBounded(context),
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
                          // 阶段 P5：新消息（非历史）淡入 + 上移入场；
                          // 历史消息直接渲染（翻页/搜索结果不闪烁）
                          Widget bubble = _MessageBubble(
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
                            onVideoTap: widget.onVideoTap,
                            onFileTap: widget.onFileTap,
                            onForwardFile: widget.onForwardFile,
                            onSaveSticker: widget.onSaveSticker,
                            // 阶段 O2：群消息"置顶"入口（群主接线由上层控制）
                            onPinMessage: widget.onPinMessage,
                            pinnedMessageId: widget.pinnedMessageId,
                            // 跳转目标是被引用的原消息（P-30 修复）
                            onJump: () =>
                                _jumpToMessage(msg.replyTo ?? msg.messageId),
                            highlighted: msg.messageId == _highlightMessageId,
                          );
                          if (msg.isHistory) return bubble;
                          return TweenAnimationBuilder<double>(
                            tween: Tween(begin: 0.0, end: 1.0),
                            duration: const Duration(milliseconds: 250),
                            curve: Curves.easeOut,
                            builder: (context, opacity, child) =>
                                FadeTransition(
                              opacity: AlwaysStoppedAnimation(opacity),
                              child: child,
                            ),
                            child: TweenAnimationBuilder<Offset>(
                              tween: Tween(
                                  begin: const Offset(0, 0.08),
                                  end: Offset.zero),
                              duration: const Duration(milliseconds: 250),
                              curve: Curves.easeOut,
                              builder: (context, offset, child) =>
                                  SlideTransition(
                                position: AlwaysStoppedAnimation(offset),
                                child: child,
                              ),
                              child: bubble,
                            ),
                          );
                        },
                      ),
                      // 阶段 P5：滚动到底部悬浮按钮（离开底部时出现）
                      if (_showScrollToBottom)
                        Positioned(
                          bottom: 16,
                          right: 16,
                          child: Material(
                            color:
                                Theme.of(context).colorScheme.primaryContainer,
                            shape: const CircleBorder(),
                            elevation: 2,
                            child: IconButton(
                              tooltip: '回到底部',
                              icon: Icon(
                                Icons.arrow_downward_rounded,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onPrimaryContainer,
                              ),
                              onPressed: () async {
                                await _scrollCtrl.animateTo(
                                  0,
                                  duration: const Duration(milliseconds: 300),
                                  curve: Curves.easeOut,
                                );
                                if (mounted) {
                                  setState(() => _showScrollToBottom = false);
                                }
                              },
                            ),
                          ),
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

        // R-P14：表情/表情包面板（微信式）——渲染在输入栏上方，
        // 输入栏保持可见；搜索模式下不渲染（与输入栏一致）
        if (!widget.isSearchMode && widget.emojiPanel != null)
          widget.emojiPanel!,
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
            // 阶段 P2：表情包入口
            onShowStickerPicker: widget.onShowStickerPicker,
          )
        else
          _ReadOnlyBar(chatTitle: widget.chatTitle),
      ],
    );
  }

  /// 标题栏（宽屏/列表态渲染；compact 聊天态由 AppBar 承担，
  /// 搜索入口/导出回调语义不变）
  Widget _buildHeader(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border(
          bottom:
              BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
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
          // 阶段 R1：通话入口（私聊会话，ChatScreen 提供）
          if (widget.onVoiceCall != null)
            IconButton(
              icon: const Icon(Icons.call_rounded),
              tooltip: '语音通话',
              onPressed: widget.onVoiceCall,
            ),
          if (widget.onVideoCall != null)
            IconButton(
              icon: const Icon(Icons.videocam_rounded),
              tooltip: '视频通话',
              onPressed: widget.onVideoCall,
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
              onPressed: () => _setSearchVisible(true),
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
    );
  }

  /// R-P6：横幅限高 + 可滚动包装（防多横幅撑爆主布局）
  List<Widget> _buildNoticeBannersBounded(BuildContext context) {
    final banners = _buildNoticeBanners(context);
    if (banners.isEmpty) return const [];
    return [
      ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.35,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: banners,
          ),
        ),
      ),
    ];
  }

  /// 阶段 O1/O2（2026-08-31 多公告/多置顶并存）：构建横幅列表。
  /// 公告逐条展示；置顶逐条展示，条目点击定位原消息（_jumpToMessage：
  /// 未加载时翻页加载 + 高亮 2s），条目尾部快捷取消按钮直接解除该条置顶。
  List<Widget> _buildNoticeBanners(BuildContext context) {
    final banners = <Widget>[];
    // gc9/gc11：群通话进行中加入条目（置顶/公告之前，最显眼位置）。
    // marker 用 Material 矢量图标（📞 emoji 的颜色由平台 emoji 字体
    // 决定——Windows Segoe UI Emoji 为红色，与 Linux/Android 灰黑不
    // 一致；矢量图标颜色跟随横幅文字色，三端一致）
    if (widget.ongoingGroupCallLabel != null &&
        widget.onJoinOngoingCall != null) {
      banners.add(_NoticeBanner(
        marker: '📞',
        markerIcon: Icon(
          Icons.call_rounded,
          size: 15,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        text: widget.ongoingGroupCallLabel!,
        highlight: true,
        onTap: widget.onJoinOngoingCall,
      ));
    }
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

class _InputBar extends StatefulWidget {
  final TextEditingController inputCtrl;
  final VoidCallback onSend;
  final VoidCallback onSendFile;
  final bool canSend; // 阶段 N3：系统会话只读不接收图片粘贴
  final ValueChanged<Uint8List>? onImagePasted;

  // ---- 阶段 O：快捷回复（O4）/ 定时发送（O5）/ 分享卡片（O9）入口 ----
  final VoidCallback? onQuickReply;
  final VoidCallback? onScheduleMessage;
  final VoidCallback? onShareCard;

  // ---- 阶段 P2：表情包入口 ----
  final VoidCallback? onShowStickerPicker;

  const _InputBar({
    required this.inputCtrl,
    required this.onSend,
    required this.onSendFile,
    this.canSend = true,
    this.onImagePasted,
    this.onQuickReply,
    this.onScheduleMessage,
    this.onShareCard,
    this.onShowStickerPicker,
  });

  @override
  State<_InputBar> createState() => _InputBarState();
}

/// 输入栏左侧功能入口（文件/表情包/快捷回复/定时）。
/// Q1 真机反馈（输入框过小）：compact（手机窄屏）下收进单个「+」键，
/// 点击在输入行上方展开功能面板（微信式）；宽屏保持四键并列（桌面不变）。
class _InputBarState extends State<_InputBar> {
  bool _actionsExpanded = false;

  void _collapse() {
    if (_actionsExpanded) setState(() => _actionsExpanded = false);
  }

  @override
  Widget build(BuildContext context) {
    final compact = isCompactLayout(context);
    final actions = <(IconData, String, VoidCallback)>[
      (Icons.attach_file, '发送文件', widget.onSendFile),
      if (widget.onShowStickerPicker != null)
        (Icons.mood_rounded, '表情包', widget.onShowStickerPicker!),
      if (widget.onQuickReply != null)
        (Icons.bolt_rounded, '快捷回复', widget.onQuickReply!),
      if (widget.onScheduleMessage != null)
        (Icons.schedule_rounded, '定时发送', widget.onScheduleMessage!),
      if (widget.onShareCard != null)
        (Icons.style_rounded, '分享卡片', widget.onShareCard!),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      child: compact
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_actionsExpanded)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    key: const ValueKey('input_actions_panel'),
                    child: Row(
                      children: [
                        for (final (icon, label, onTap) in actions)
                          Expanded(
                            child: InkWell(
                              borderRadius: BorderRadius.circular(10),
                              onTap: () {
                                _collapse();
                                onTap();
                              },
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 8),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(icon, size: 26),
                                    const SizedBox(height: 4),
                                    Text(label,
                                        style: const TextStyle(fontSize: 12)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                _buildInputRow(context),
              ],
            )
          : _buildWideRow(context, actions),
    );
  }

  /// compact：单个「+」键 + 输入框 + 发送键
  Widget _buildInputRow(BuildContext context) {
    return Row(
      children: [
        IconButton(
          key: const ValueKey('input_actions_toggle'),
          tooltip: _actionsExpanded ? '收起' : '更多功能',
          icon: Icon(_actionsExpanded
              ? Icons.close_rounded
              : Icons.add_circle_outline_rounded),
          onPressed: () => setState(() => _actionsExpanded = !_actionsExpanded),
        ),
        Expanded(
          child: AdaptiveTextField(
            controller: widget.inputCtrl,
            hintText: '输入消息，Enter 发送...',
            showChineseInput: true,
            onSubmitted: (_) => widget.onSend(),
            // 阶段 N3（P2-4）：剪贴板图片 → 上层预览（仅非只读会话）
            onImagePasted: widget.canSend ? widget.onImagePasted : null,
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          icon: const Icon(Icons.send_rounded),
          tooltip: '发送',
          onPressed: widget.onSend,
        ),
      ],
    );
  }

  /// 宽屏（桌面）：四键并列 + 输入框 + 发送键（既有布局，Q0 前语义不变）
  Widget _buildWideRow(
      BuildContext context, List<(IconData, String, VoidCallback)> actions) {
    return Row(
      children: [
        for (final (icon, tooltip, onTap) in actions)
          IconButton(
            icon: Icon(icon),
            tooltip: tooltip,
            onPressed: onTap,
          ),
        Expanded(
          child: AdaptiveTextField(
            controller: widget.inputCtrl,
            hintText: '输入消息，Enter 发送...',
            showChineseInput: true,
            onSubmitted: (_) => widget.onSend(),
            // 阶段 N3（P2-4）：剪贴板图片 → 上层预览（仅非只读会话）
            onImagePasted: widget.canSend ? widget.onImagePasted : null,
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          icon: const Icon(Icons.send_rounded),
          tooltip: '发送',
          onPressed: widget.onSend,
        ),
      ],
    );
  }
}

class _NoticeBanner extends StatelessWidget {
  final String marker;
  final String text;
  final Widget? markerIcon; // gc11：矢量图标替代 emoji marker（emoji
  // 颜色随平台字体各异——Windows Segoe UI Emoji 电话为红色与另两端
  // 不一致；Material 图标跨端渲染一致）
  final VoidCallback? onTap; // 点击条目（置顶定位到原消息）
  final Widget? trailing; // 条目尾部控件（快捷取消置顶按钮）
  final bool highlight; // gc9：群通话加入条目高亮（品牌色更醒目）

  const _NoticeBanner({
    required this.marker,
    required this.text,
    this.markerIcon,
    this.onTap,
    this.trailing,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: highlight
            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.18)
            : Theme.of(context)
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
          if (markerIcon != null) ...[
            markerIcon!,
            const SizedBox(width: 6),
          ],
          Expanded(
            child: InkWell(
              onTap: onTap,
              child: Text(
                markerIcon == null ? '$marker $text' : text,
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
  final ValueChanged<ChatMessage>? onVideoTap; // 阶段 P1：点击视频气泡全屏
  final ValueChanged<ChatMessage>? onFileTap; // R-P2：点击文件卡片预览
  final ValueChanged<ChatMessage>? onForwardFile; // Q1 三轮：文件消息菜单转发
  final ValueChanged<ChatMessage>? onSaveSticker; // R-P3：图片添加到表情包

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
    this.onVideoTap,
    this.onFileTap,
    this.onForwardFile,
    this.onSaveSticker,
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
        onSaveSticker: _isInlineImage ? onSaveSticker : null,
        onForwardFile: onForwardFile,
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
    return '${AppPaths.receivedFilesDir}/$base';
  }

  /// 阶段 P1：是否为可内嵌展示的视频文件消息（未撤回 + 视频扩展名 +
  /// 传输完成——同 N3b 破图门控）
  bool get _isInlineVideo {
    if (message.type != 'file' || message.isRecalled) return false;
    if (!isVideoFilename(message.filename ?? '')) return false;
    if (transferFraction != null) return false;
    return true;
  }

  /// 阶段 P1：视频气泡（深色卡片 + 播放图标 + 文件名 + 可选大小行）
  Widget _buildVideoCard(BuildContext context) {
    final sizeLine =
        message.filesize != null ? formatFileSize(message.filesize!) : null;
    return Container(
      width: 240,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.play_arrow_rounded, size: 40, color: Colors.white),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message.filename ?? '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, color: Colors.white),
                ),
                if (sizeLine != null)
                  Text(
                    sizeLine,
                    style: TextStyle(
                        fontSize: 11,
                        color: Colors.white.withValues(alpha: 0.7)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 阶段 P1：非媒体文件卡片（通用文件图标 + 原文案 + 可选大小行）
  Widget _buildFileCard(BuildContext context) {
    final sizeLine =
        message.filesize != null ? formatFileSize(message.filesize!) : null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.insert_drive_file_rounded, size: 26),
        const SizedBox(width: 8),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                message.content,
                style: TextStyle(
                  color: isSelf
                      ? Colors.white
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              if (sizeLine != null)
                Text(
                  sizeLine,
                  style: TextStyle(
                    fontSize: 11,
                    color: isSelf
                        ? Colors.white.withValues(alpha: 0.8)
                        : Colors.grey[600],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// 构建内联缩略图（字节优先 Image.memory，否则 Image.file）。
  /// Q1 真机反馈二轮（问题8）：解码降采样（cacheWidth=400px）——缩略
  /// 展示无需全分辨率解码，防超大照片内存峰值触发 LMK 查杀
  Widget _buildInlineImage() {
    Widget image;
    if (message.fileData != null) {
      image = Image.memory(
        message.fileData!,
        fit: BoxFit.cover,
        cacheWidth: 400,
        errorBuilder: (_, __, ___) =>
            const Icon(Icons.broken_image_outlined, size: 40),
      );
    } else {
      image = Image.file(
        File(_resolvedImagePath!),
        fit: BoxFit.cover,
        cacheWidth: 400,
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
    // 阶段 P1：视频文件消息点击打开全屏查看器
    final videoTap = _isInlineVideo && onVideoTap != null
        ? () => onVideoTap!(message)
        : null;
    // R-P2：非媒体文件卡片点击打开预览（传输中/已撤回不响应）
    final fileTap = message.type == 'file' &&
            !_isInlineImage &&
            !_isInlineVideo &&
            !isRecalled &&
            transferFraction == null &&
            onFileTap != null
        ? () => onFileTap!(message)
        : null;
    // 阶段 K5：菜单启用时文字消息改用菜单；否则保持既有直接撤回交互（回归）
    final VoidCallback? menuOrRecall =
        _showMenu ? () => _openMenu(context) : onRecall;
    return MouseRegion(
      cursor: onRecall == null &&
              !_showMenu &&
              imageTap == null &&
              videoTap == null &&
              fileTap == null
          ? MouseCursor.defer
          : SystemMouseCursors.click,
      child: GestureDetector(
        onLongPress: menuOrRecall,
        onSecondaryTap: menuOrRecall,
        onTap: imageTap ??
            videoTap ??
            fileTap ??
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
                        // R-P10 契约补齐：引用预览 emoji 兜底（Q1 二轮
                        // 修订：按平台裁剪——Android 显式 emoji 兜底会让
                        // 混排数字命中键帽黑字形，系统链自带彩字）
                        fontFamilyFallback: emojiTextFallback(),
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
                    else if (_isInlineVideo)
                      // 阶段 P1：视频文件消息内嵌视频气泡
                      _buildVideoCard(context)
                    else if (message.type == 'file')
                      // 阶段 P1：非媒体文件卡片（保留原文案，N 系列回归）
                      _buildFileCard(context)
                    else
                      Text(
                        message.content,
                        style: TextStyle(
                          color: isSelf
                              ? Theme.of(context).colorScheme.onPrimary
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                          // Q1 真机反馈二轮（数字发黑根因修订）：显式
                          // fontFamily 压不住——引擎对带 Emoji 属性的码点
                          // （数字/#/*）会命中 fallback 链中的 emoji 字体
                          // 键帽基字形（黑色）。Android/iOS 不给混排文本
                          // 挂 emoji 兜底（系统链自带彩字），仅 Linux 保留
                          // R-P10/R-P26 显式栈（fontconfig 黑白字形问题）
                          fontFamily: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.fontFamily,
                          fontFamilyFallback: emojiTextFallback(),
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
                    // Q1 七轮（问题1）：文件传输失败标记——直传转发
                    // 中断等异常时明确提醒发送方；提供回调时点击重发
                    // （经 sendFile 走完整上传通道）
                    if (isSelf &&
                        message.isFailed &&
                        message.type == 'file' &&
                        transferFraction == null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: GestureDetector(
                          onTap: onRetrySend == null
                              ? null
                              : () => onRetrySend!(message.messageId),
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
                                onRetrySend == null
                                    ? '传输失败，建议重新发送'
                                    : '传输失败，点击重新发送',
                                style: TextStyle(
                                  fontSize: 11,
                                  decoration: onRetrySend == null
                                      ? TextDecoration.none
                                      : TextDecoration.underline,
                                  color: Colors.white.withValues(alpha: 0.9),
                                ),
                              ),
                            ],
                          ),
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
                              // Q1 二轮：chip 为"emoji + 计数"混排——主字体
                              // 缺省（计数数字走默认字体，emoji 经平台化
                              // 兜底；Android 显式 emoji 主字体会把计数
                              // 染成键帽黑字形）
                              style: TextStyle(
                                fontSize: 12,
                                fontFamilyFallback: emojiTextFallback(),
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
  final ValueChanged<ChatMessage>? onSaveSticker; // R-P3：添加到表情包（图片消息）
  final ValueChanged<ChatMessage>? onForwardFile; // Q1 三轮：文件消息转发

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
    this.onSaveSticker,
    this.onForwardFile,
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
    // 文件消息（P-33 修订 2026-08-18）：菜单以"撤回"为核心入口
    // （文件不支持引用/表情/仅我删除；阶段 N1 亦不新增复制/永久删除）。
    // Q1 三轮（问题8）：新增"转发"入口（上层提供 onForwardFile 时）——
    // 本地文件重发通道，与服务端 forward 协议无关
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
    // R-P3：图片消息"添加到表情包"（收藏他人表情）
    if (widget.onSaveSticker != null) {
      entries.add(_MenuTile(
        icon: Icons.favorite_border_rounded,
        title: '添加到表情包',
        onTap: () => _invoke(() => widget.onSaveSticker!(widget.message)),
      ));
    }
    // Q1 三轮（问题8）：文件消息"转发"——已下载文件经本地重发通道
    // 转给目标会话（服务端 forward 协议仍拒绝文件，不走该协议）
    if (isFile && widget.onForwardFile != null) {
      entries.add(_MenuTile(
        icon: Icons.forward_rounded,
        title: '转发',
        onTap: () => _invoke(() => widget.onForwardFile!(widget.message)),
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
                  // 阶段 P2：扩展常用表情集（按分类分组；'常用' 完整包含
                  // 阶段 K 默认盘）
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final (name, emojis) in emojiPickerCategories)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                name,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[600],
                                ),
                              ),
                              Wrap(
                                spacing: 8,
                                children: [
                                  for (final emoji in emojis)
                                    ActionChip(
                                      label: Text(emoji,
                                          style: TextStyle(
                                              fontFamily:
                                                  emojiPickerFontFamily(),
                                              fontFamilyFallback:
                                                  AppConfig.emojiFontStack)),
                                      onPressed: () => _invoke(() =>
                                          widget.onAddReaction!(
                                              widget.message.messageId, emoji)),
                                    ),
                                ],
                              ),
                            ],
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
