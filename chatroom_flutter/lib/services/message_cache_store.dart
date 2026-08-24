/// 客户端本地消息缓存（阶段 L3，P0-4）
///
/// 依据《软件开发文档4.1.0.md》§13.2 P0-4 / §13.5：
///   - 消息本地 SQLite 落盘，服务端不可用时仍可读到历史（离线可读）
///   - 启动先渲染本地（loadRecentMessages），再与服务端增量同步合并
///   - 按 message_id 去重（主键），消息表 schema 与服务端 message_history 对齐
///
/// 桌面端（Linux/Windows/macOS）与测试环境使用 sqflite_common_ffi（FFI 后端，
/// 无需平台通道）；移动端走 sqflite 原生后端。

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/chat_models.dart';

/// 本地消息缓存（阶段 L3）
class MessageCacheStore {
  Database? _db;
  bool _closed = true;
  static bool _ffiReady = false;

  /// 是否已初始化（数据库已打开）
  bool get isOpen => !_closed && _db != null;

  /// 初始化本地缓存数据库。
  ///
  /// [dbPath] 可注入（测试用 ':memory:' 或临时文件）；缺省时使用
  /// 应用文档目录下的 `message_cache.db`。同一实例重复调用幂等（已打开则忽略）。
  Future<void> init({String? dbPath}) async {
    if (isOpen) return;
    if (!_ffiReady &&
        (Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
      // 桌面/测试：FFI 后端（无需平台通道）
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      _ffiReady = true;
    }
    final path = dbPath ?? await _defaultPath();
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE messages (
            message_id  TEXT PRIMARY KEY,
            chat_key    TEXT NOT NULL,
            sender      TEXT NOT NULL,
            content     TEXT NOT NULL,
            type        TEXT NOT NULL,
            timestamp   INTEGER NOT NULL,
            status      TEXT NOT NULL,
            filename    TEXT,
            group_id    INTEGER,
            reply_to    TEXT,
            reply_preview TEXT,
            reactions   TEXT
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_messages_chat ON messages(chat_key, timestamp)');
      },
    );
    _closed = false;
  }

  /// 关闭数据库（测试/退出时调用）；关闭后可重新 init
  Future<void> close() async {
    final db = _db;
    _db = null;
    _closed = true;
    if (db != null) {
      await db.close();
    }
  }

  static Future<String> _defaultPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/message_cache.db';
  }

  Database get _database {
    final db = _db;
    if (db == null) {
      throw StateError('MessageCacheStore 未初始化，请先调用 init()');
    }
    return db;
  }

  // ============================================================
  // 写入
  // ============================================================

  /// 保存/更新一条消息（按 message_id 主键去重：服务端回显/多设备推送幂等）
  Future<void> upsertMessage(String chatKey, ChatMessage msg) async {
    final db = _database;
    await db.insert(
      'messages',
      _toRow(chatKey, msg),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 批量保存（历史分页/初始数据）
  Future<void> upsertMessages(String chatKey, List<ChatMessage> msgs) async {
    final db = _database;
    await db.transaction((txn) async {
      for (final msg in msgs) {
        await txn.insert(
          'messages',
          _toRow(chatKey, msg),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  Map<String, Object?> _toRow(String chatKey, ChatMessage msg) {
    final reactions = msg.reactions.isEmpty
        ? null
        : jsonEncode({
            for (final e in msg.reactions.entries) e.key: e.value,
          });
    return {
      'message_id': msg.messageId,
      'chat_key': chatKey,
      'sender': msg.sender,
      'content': msg.content,
      'type': msg.type,
      'timestamp': msg.timestamp.millisecondsSinceEpoch,
      'status': msg.status,
      'filename': msg.filename,
      'group_id': msg.groupId,
      'reply_to': msg.replyTo,
      'reply_preview': msg.replyPreview,
      'reactions': reactions,
    };
  }

  // ============================================================
  // 读取
  // ============================================================

  /// 读取某会话全部缓存消息（按时间升序）
  Future<List<ChatMessage>> loadMessages(String chatKey) async {
    final db = _database;
    final rows = await db.query(
      'messages',
      where: 'chat_key = ?',
      whereArgs: [chatKey],
      orderBy: 'timestamp ASC, message_id ASC',
    );
    return rows.map(_fromRow).toList();
  }

  /// 读取某会话最近 [limit] 条消息（启动秒开：先渲染最近消息再增量同步）
  Future<List<ChatMessage>> loadRecentMessages(String chatKey,
      {int limit = 50}) async {
    final db = _database;
    final rows = await db.query(
      'messages',
      where: 'chat_key = ?',
      whereArgs: [chatKey],
      orderBy: 'timestamp DESC, message_id DESC',
      limit: limit,
    );
    return rows.reversed.map(_fromRow).toList();
  }

  /// 游标分页：读取某 message_id 之前（更旧）的 [limit] 条（按时间升序）
  Future<List<ChatMessage>> loadMessagesBefore(String chatKey, String messageId,
      {int limit = 50}) async {
    final db = _database;
    final anchor = await db.query(
      'messages',
      columns: ['timestamp'],
      where: 'message_id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    if (anchor.isEmpty) return const [];
    final anchorTs = anchor.first['timestamp'] as int;
    final rows = await db.query(
      'messages',
      where: 'chat_key = ? AND timestamp < ?',
      whereArgs: [chatKey, anchorTs],
      orderBy: 'timestamp DESC, message_id DESC',
      limit: limit,
    );
    return rows.reversed.map(_fromRow).toList();
  }

  /// 有消息的会话 key 列表（按最新活动降序）
  Future<List<String>> conversations() async {
    final db = _database;
    final rows = await db.rawQuery('''
      SELECT chat_key, MAX(timestamp) AS last_ts
      FROM messages
      GROUP BY chat_key
      ORDER BY last_ts DESC
    ''');
    return [for (final r in rows) r['chat_key']! as String];
  }

  ChatMessage _fromRow(Map<String, Object?> row) {
    Map<String, List<String>> reactions = const {};
    final rawReactions = row['reactions'] as String?;
    if (rawReactions != null && rawReactions.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawReactions);
        if (decoded is Map<String, dynamic>) {
          reactions = {
            for (final e in decoded.entries)
              e.key: (e.value as List<dynamic>? ?? const [])
                  .map((u) => u.toString())
                  .toList(),
          };
        }
      } catch (_) {
        // 防御：损坏的 reactions JSON 忽略
      }
    }
    return ChatMessage(
      sender: (row['sender'] as String?) ?? '',
      content: (row['content'] as String?) ?? '',
      type: (row['type'] as String?) ?? 'chat',
      messageId: (row['message_id'] as String?) ?? '',
      timestamp:
          DateTime.fromMillisecondsSinceEpoch((row['timestamp'] as int?) ?? 0),
      status: (row['status'] as String?) ?? 'delivered',
      filename: row['filename'] as String?,
      groupId: row['group_id'] as int?,
      replyTo: row['reply_to'] as String?,
      replyPreview: row['reply_preview'] as String?,
      reactions: reactions,
    );
  }

  // ============================================================
  // 删除 / 清空
  // ============================================================

  /// 移除一条消息（仅我删除/撤回落地）
  Future<void> removeMessage(String chatKey, String messageId) async {
    final db = _database;
    await db.delete(
      'messages',
      where: 'chat_key = ? AND message_id = ?',
      whereArgs: [chatKey, messageId],
    );
  }

  /// 清空某会话全部缓存消息
  Future<void> clearConversation(String chatKey) async {
    final db = _database;
    await db.delete('messages', where: 'chat_key = ?', whereArgs: [chatKey]);
  }

  /// 清空全部缓存（退出登录时调用，避免跨账号数据泄漏）
  Future<void> clearAll() async {
    final db = _database;
    await db.delete('messages');
  }
}
