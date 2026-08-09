/// 聊天视图
///
/// 显示消息列表 + 底部输入栏。
/// 支持文本发送、文件发送、消息撤回、上滑加载历史（阶段 E）。
/// 输入框使用 RawTextField + IME 桥接，避免 Flutter + fcitx GTK IM Context 死锁。

import 'package:flutter/material.dart';

import '../models/chat_models.dart';
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
  });

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final ScrollController _scrollCtrl = ScrollController();
  bool _isLoadingHistory = false;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    super.dispose();
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
                  widget.chatKey.startsWith('group_') ||
                          widget.chatKey == '服务器'
                      ? widget.chatTitle
                      : '与 ${widget.chatTitle} 的聊天',
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ),
            ],
          ),
        ),

        // 消息列表
        Expanded(
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
                        '暂无消息',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                          onRecall: msg.isRecalled ||
                                  msg.sender != widget.username
                              ? null
                              : () => widget.onRecall(msg.messageId),
                          transferFraction: msg.type == 'file'
                              ? widget.transferFraction?.call(msg.messageId)
                              : null,
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
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
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

        // 输入栏
        if (widget.canSend)
          _InputBar(
            inputCtrl: widget.inputCtrl,
            onSend: widget.onSend,
            onSendFile: widget.onSendFile,
          )
        else
          _ReadOnlyBar(chatTitle: widget.chatTitle),
      ],
    );
  }
}

class _InputBar extends StatelessWidget {
  final TextEditingController inputCtrl;
  final VoidCallback onSend;
  final VoidCallback onSendFile;

  const _InputBar({
    required this.inputCtrl,
    required this.onSend,
    required this.onSendFile,
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
          Expanded(
            child: RawTextField(
              controller: inputCtrl,
              hintText: '输入消息，Enter 发送...',
              showChineseInput: true,
              onSubmitted: (_) => onSend(),
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

  const _MessageBubble({
    required this.message,
    required this.isSelf,
    this.onRecall,
    this.transferFraction,
  });

  @override
  Widget build(BuildContext context) {
    if (message.type == 'system') {
      return _SystemMessage(message: message);
    }
    final isRecalled = message.isRecalled;
    final alignment =
        isSelf ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final color = isSelf
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.surfaceContainerHighest;

    return MouseRegion(
      cursor: onRecall == null ? MouseCursor.defer : SystemMouseCursors.click,
      child: GestureDetector(
        onLongPress: onRecall,
        onSecondaryTap: onRecall,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
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
                        '${message.sender}: [消息已撤回]',
                        style: TextStyle(
                          color: Colors.grey[500],
                          fontStyle: FontStyle.italic,
                        ),
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
                                        : Theme.of(context)
                                            .colorScheme
                                            .primary,
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
