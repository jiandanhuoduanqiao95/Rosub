/// 附件本机路径统一解析器（opt8 #1/#13）
///
/// 所有 UI/功能层的"消息附件在哪"收敛到此处，替代散落的
/// `received_files/<文件名>` 回推：
///   - 接收附件唯一落盘键 [receivedAttachmentPath]：messageId 净化组件
///     （形变时追加 FNV-1a 短哈希防碰撞）+ 安全文件名，同名文件跨消息/
///     会话不再互相覆盖；
///   - [resolveMessageAttachmentPath]：气泡路径裁决（消息 filePath →
///     SentFileStore 发送记录 → 唯一接收路径 → [isFileMeta] 终止 →
///     旧版按文件名路径，自己发送的消息不走旧接收目录避免误判）；
///   - [resolveFileRecordPath]：文件管理页 FileRecord 裁决（唯一接收
///     路径 → 旧路径[仅接收方] → SentFileStore）。
/// 返回值保证文件当下存在；全部 miss 返回 null（气泡回退文本态）。

import 'dart:convert';
import 'dart:io';

import '../models/chat_models.dart';
import 'app_paths.dart';
import 'file_names.dart';
import 'sent_file_store.dart';

/// FNV-1a 32 位，8 位十六进制（messageId 净化形变时的防碰撞后缀）
String _shortHash(String input) {
  const fnvOffset = 0x811C9DC5;
  const fnvPrime = 0x01000193;
  var h = fnvOffset;
  for (final byte in utf8.encode(input)) {
    h ^= byte;
    h = (h * fnvPrime) & 0xFFFFFFFF;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

/// 接收附件唯一落盘路径（messageId 前缀防同名覆盖；普通安全 messageId
/// 路径格式不变，形变/空值追加短哈希防碰撞）
String receivedAttachmentPath(String messageId, String filename) {
  final safeName = sanitizeFilename(filename);
  final cleaned = sanitizeStorageComponent(messageId);
  String key;
  if (cleaned.isEmpty) {
    key = 'unknown_${_shortHash(messageId)}';
  } else if (cleaned != messageId) {
    key = '${cleaned}_${_shortHash(messageId)}';
  } else {
    key = cleaned;
  }
  return '${AppPaths.receivedFilesDir}/${key}_$safeName';
}

/// 气泡附件本机路径解析（存在才返回，全部 miss → null）
String? resolveMessageAttachmentPath(ChatMessage message,
    {bool isSelf = false}) {
  final fp = message.filePath;
  if (fp != null && fp.isNotEmpty && File(fp).existsSync()) {
    return fp;
  }
  final sent = SentFileStore.pathOf(message.messageId);
  if (sent != null && sent.isNotEmpty && File(sent).existsSync()) {
    return sent;
  }
  final derived =
      receivedAttachmentPath(message.messageId, message.filename ?? '');
  if (File(derived).existsSync()) {
    return derived;
  }
  if (message.isFileMeta) {
    return null;
  }
  if (isSelf) {
    return null;
  }
  final name = message.filename ?? '';
  if (name.isEmpty) {
    return null;
  }
  final legacy = '${AppPaths.receivedFilesDir}/${sanitizeFilename(name)}';
  if (File(legacy).existsSync()) {
    return legacy;
  }
  return null;
}

/// 文件管理页 FileRecord 本机路径解析（存在才返回，全部 miss → null）
String? resolveFileRecordPath(FileRecord record, {String? currentUser}) {
  final unique = receivedAttachmentPath(record.messageId, record.filename);
  if (File(unique).existsSync()) {
    return unique;
  }
  final isSelf = currentUser != null && record.sender == currentUser;
  if (!isSelf && record.filename.isNotEmpty) {
    final legacy =
        '${AppPaths.receivedFilesDir}/${sanitizeFilename(record.filename)}';
    if (File(legacy).existsSync()) {
      return legacy;
    }
  }
  final sent = SentFileStore.pathOf(record.messageId);
  if (sent != null && sent.isNotEmpty && File(sent).existsSync()) {
    return sent;
  }
  return null;
}
