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
  final List<ChatMessage> messages;
  final String username;
  final TextEditingController inputCtrl;
  final VoidCallback onSend;
  final VoidCallback onSendFile;
  final ValueChanged<String> onRecall;

  const ChatView({
    super.key,
    required this.chatKey,
    required this.messages,
    required this.username,
    required this.inputCtrl,
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
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            border: const Border(bottom: BorderSide(color: Color(0xFFE0E0E0))),
          ),
          child: Text(
            _chatTitle,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
        ),

        // 消息列表
        Expanded(
          child: messages.isEmpty
              ? const Center(
                  child: Text(
                    '暂无消息',
                    style: TextStyle(color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  reverse: true,
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
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            border: const Border(top: BorderSide(color: Color(0xFFE0E0E0))),
          ),
          child: Row(
            children: [
              // 文件按钮
              IconButton(
                icon: const Icon(Icons.attach_file),
                tooltip: '发送文件',
                onPressed: onSendFile,
              ),
              // 输入框（中文通过 IME 桥接支持，无死锁风险）
              Expanded(
                child: RawTextField(
                  controller: inputCtrl,
                  hintText: '输入消息...',
                  showChineseInput: true,
                  onSubmitted: (_) => onSend(),
                ),
              ),
              const SizedBox(width: 8),
              // 发送按钮
              IconButton.filled(
                icon: const Icon(Icons.send_rounded),
                tooltip: '发送',
                onPressed: onSend,
              ),
            ],
          ),
        ),
      ],
    );
  }

  String get _chatTitle {
    if (chatKey.startsWith('group_')) {
      final id = chatKey.substring(6);
      return '群组 $id 的聊天';
    }
    return '与 $chatKey 的聊天';
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
    final isRecalled = message.isRecalled;
    final alignment = isSelf ? CrossAxisAlignment.start : CrossAxisAlignment.end;
    final color = isSelf
        ? Theme.of(context).colorScheme.primaryContainer
        : Theme.of(context).colorScheme.surfaceContainerHighest;

    return GestureDetector(
      onTap: onRecall,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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
                if (message.isHistory)
                  Container(
                    margin: const EdgeInsets.only(left: 4),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade100,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '历史',
                      style: TextStyle(
                          fontSize: 10, color: Colors.orange.shade800),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            // 消息内容气泡
            Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.5,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: isRecalled ? Colors.grey.shade200 : color,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(12),
                  topRight: const Radius.circular(12),
                  bottomLeft:
                      isSelf ? Radius.zero : const Radius.circular(12),
                  bottomRight:
                      isSelf ? const Radius.circular(12) : Radius.zero,
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
                            ? Theme.of(context).colorScheme.onPrimaryContainer
                            : Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                      ),
                    ),
            ),
          ],
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
