/// 聊天记录导出（阶段 N2：P2-1 聊天记录导出，数据主权闭环）
///
/// 按会话导出：TXT 人工可读，JSON 含完整元数据（时间戳/状态/引用/表情/文件）。
/// 纯函数、无 IO：调用方负责按时间排序消息、选择保存路径。
/// [exportedAt] 可注入保证导出时间确定性（测试/批量导出）。
///
/// TXT 格式：
///   ============ 聊天记录 ============
///   会话: {chatKey}
///   导出时间: YYYY-MM-DD HH:mm:ss
///   消息数: N
///   ------------------------------------
///   [HH:mm:ss] 发送者: 内容（发送中/发送失败）
///     ↳ 回复: 引用缩略
///   ====================================
///
/// JSON 格式：{"exported_at", "chat_key", "message_count", "messages": [
///   {sender, content, type, message_id, timestamp, status, filename,
///    group_id, reply_to, reply_preview, reactions}
/// ]}

import 'dart:convert';

import '../models/chat_models.dart';

class ChatExporter {
  ChatExporter._();

  static String _pad(int n) => n.toString().padLeft(2, '0');

  /// 本地时间完整格式：YYYY-MM-DD HH:mm:ss
  static String _formatDateTime(DateTime dt) {
    return '${dt.year}-${_pad(dt.month)}-${_pad(dt.day)} '
        '${_pad(dt.hour)}:${_pad(dt.minute)}:${_pad(dt.second)}';
  }

  /// 本地时间 HH:mm:ss
  static String _formatTime(DateTime dt) {
    return '${_pad(dt.hour)}:${_pad(dt.minute)}:${_pad(dt.second)}';
  }

  /// 消息正文（导出用）：文件/撤回/普通文本
  static String _bodyOf(ChatMessage m) {
    if (m.isRecalled) {
      if (m.type == 'file') return '[文件] ${m.filename} [已撤回]';
      return '[消息已撤回]';
    }
    if (m.filename != null) return '[文件] ${m.filename}';
    return m.content;
  }

  /// TXT 导出（人工可读）
  static String exportTxt({
    required String chatKey,
    required List<ChatMessage> messages,
    DateTime? exportedAt,
  }) {
    final at = exportedAt ?? DateTime.now();
    final buffer = StringBuffer()
      ..writeln('============ 聊天记录 ============')
      ..writeln('会话: $chatKey')
      ..writeln('导出时间: ${_formatDateTime(at)}')
      ..writeln('消息数: ${messages.length}')
      ..writeln('------------------------------------');
    for (final m in messages) {
      var line = '[${_formatTime(m.timestamp)}] ${m.sender}: ${_bodyOf(m)}';
      if (!m.isRecalled) {
        if (m.isSending) line += '（发送中）';
        if (m.isFailed) line += '（发送失败）';
      }
      buffer.writeln(line);
      if (m.hasQuote) {
        buffer.writeln('  ↳ 回复: ${m.replyPreview ?? ''}');
      }
    }
    buffer.writeln('====================================');
    return buffer.toString();
  }

  /// JSON 导出（完整元数据：时间戳/状态/引用/表情/文件）
  static String exportJson({
    required String chatKey,
    required List<ChatMessage> messages,
    DateTime? exportedAt,
  }) {
    final at = exportedAt ?? DateTime.now();
    return jsonEncode({
      'exported_at': _formatDateTime(at),
      'chat_key': chatKey,
      'message_count': messages.length,
      'messages': [
        for (final m in messages)
          {
            'sender': m.sender,
            'content': m.content,
            'type': m.type,
            'message_id': m.messageId,
            'timestamp': _formatDateTime(m.timestamp),
            'status': m.status,
            'filename': m.filename,
            'group_id': m.groupId,
            'reply_to': m.replyTo,
            'reply_preview': m.replyPreview,
            'reactions': m.reactions,
          },
      ],
    });
  }
}
