/// 聊天视图
///
/// 显示消息列表 + 底部输入栏。
/// 支持文本发送、文件发送、消息撤回。
/// 输入框使用 RawTextField + IME 桥接，避免 Flutter + fcitx GTK IM Context 死锁。

import 'package:flutter/material.dart';

import '../models/chat_models.dart';
import 'raw_text_field.dart';

class ChatView extends StatelessWidget {
  final String chatKey;
  final String chatTitle;
  final List<ChatMessage> messages;
  final String username;
  final TextEditingController inputCtrl;
  final bool canSend;
  final VoidCallback onSend;
  final VoidCallback onSendFile;
  final ValueChanged<String> onRecall;

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
  });

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
                  chatKey.startsWith('group_')
                      ? Icons.groups_rounded
                      : chatKey == '服务器'
                          ? Icons.notifications_rounded
                          : Icons.person_rounded,
                  size: 20,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  chatKey.startsWith('group_') || chatKey == '服务器'
                      ? chatTitle
                      : '与 $chatTitle 的聊天',
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
          child: messages.isEmpty
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
              : ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final msgIndex = messages.length - 1 - index;
                    final msg = messages[msgIndex];
                    return _MessageBubble(
                      message: msg,
                      isSelf: msg.sender == username,
                      onRecall: msg.isRecalled || msg.sender != username
                          ? null
                          : () => onRecall(msg.messageId),
                    );
                  },
                ),
        ),

        // 输入栏
        if (canSend)
          _InputBar(
            inputCtrl: inputCtrl,
            onSend: onSend,
            onSendFile: onSendFile,
          )
        else
          _ReadOnlyBar(chatTitle: chatTitle),
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
        '$chatTitle 为只读会话，操作结果和错误会显示在这里。',
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

  const _MessageBubble({
    required this.message,
    required this.isSelf,
    this.onRecall,
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
                child: isRecalled
                    ? Text(
                        '${message.sender}: [消息已撤回]',
                        style: TextStyle(
                          color: Colors.grey[500],
                          fontStyle: FontStyle.italic,
                        ),
                      )
                    : Text(
                        message.type == 'system'
                            ? message.content
                            : message.content,
                        style: TextStyle(
                          color: isSelf
                              ? Theme.of(context).colorScheme.onPrimary
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
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
