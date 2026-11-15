// opt8 #1/#13 —— 本地缓存 schema v2：file_path 列
//
// 契约：
//   - openDatabase version 2；新库 messages 表含 file_path TEXT；
//   - v1 旧库（user_version=1）打开 → onUpgrade ALTER 补列，旧数据保留；
//   - user_version=0 但已有旧表（CREATE TABLE IF NOT EXISTS 幂等跳过）→
//     打开后 _ensureFileColumn 兜底补列；
//   - upsertMessage 持久化 msg.filePath，loadMessages/loadRecentMessages
//     恢复 filePath；既有 L3 契约（往返/去重/排序）不回归。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/message_cache_store.dart';

ChatMessage _msg(String id,
    {String status = 'delivered',
    DateTime? ts,
    String? filePath,
    String filename = 'photo.png',
    bool isFileMeta = false}) {
  return ChatMessage(
    sender: 'bob',
    content: '[文件] $filename',
    type: 'file',
    messageId: id,
    timestamp: ts ?? DateTime(2026, 1, 1, 12),
    status: status,
    filename: filename,
    filePath: filePath,
    isFileMeta: isFileMeta,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  Directory? tmpDir;
  String dbPath(String name) => '${tmpDir!.path}/$name';

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('store_v2_test');
  });

  tearDown(() async {
    final dir = tmpDir;
    if (dir != null && dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    tmpDir = null;
  });

  group('schema v2 —— file_path 列（opt8）', () {
    test('新库：filePath 往返（upsert → load → close → reopen 仍在）', () async {
      final store = MessageCacheStore();
      await store.init(dbPath: dbPath('v2.db'));
      const path = '/tmp/sent_files/12345_shot.png';
      await store.upsertMessage('bob', _msg('m1', filePath: path));
      var rows = await store.loadMessages('bob');
      expect(rows.single.filePath, path);

      await store.close();
      final reopened = MessageCacheStore();
      await reopened.init(dbPath: dbPath('v2.db'));
      rows = await reopened.loadMessages('bob');
      expect(rows.single.filePath, path);
      expect(rows.single.status, 'delivered');
      await reopened.close();
    });

    test('isFileMeta 往返（file_meta 气泡重启后不回退旧图的数据源）',
        () async {
      final store = MessageCacheStore();
      await store.init(dbPath: dbPath('meta_v3.db'));
      await store
          .upsertMessage('bob', _msg('meta-1', isFileMeta: true));
      var rows = await store.loadMessages('bob');
      expect(rows.single.isFileMeta, isTrue);

      await store.close();
      final reopened = MessageCacheStore();
      await reopened.init(dbPath: dbPath('meta_v3.db'));
      rows = await reopened.loadMessages('bob');
      expect(rows.single.isFileMeta, isTrue);
      expect(rows.single.filePath, isNull);
      await reopened.close();
    });

    test('普通消息 isFileMeta 默认 false 往返', () async {
      final store = MessageCacheStore();
      await store.init(dbPath: dbPath('normal_v3.db'));
      await store.upsertMessage('bob', _msg('plain-1', filePath: '/tmp/x.png'));
      final rows = await store.loadMessages('bob');
      expect(rows.single.isFileMeta, isFalse);
      await store.close();
    });

    test('v2 旧库（version 2，有 file_path 无 is_file_meta）→ 补列且旧数据保留',
        () async {
      final legacy = await openDatabase(dbPath('legacy_v2.db'), version: 2,
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
            reactions   TEXT,
            file_path   TEXT
          )
        ''');
      });
      await legacy.insert('messages', {
        'message_id': 'old-v2-1',
        'chat_key': 'bob',
        'sender': 'bob',
        'content': '[文件] old.png',
        'type': 'file',
        'timestamp': 1767225600000,
        'status': 'delivered',
        'filename': 'old.png',
        'file_path': '/tmp/old.png',
      });
      await legacy.close();

      final store = MessageCacheStore();
      await store.init(dbPath: dbPath('legacy_v2.db'));
      final rows = await store.loadMessages('bob');
      expect(rows.single.messageId, 'old-v2-1');
      expect(rows.single.filePath, '/tmp/old.png');
      expect(rows.single.isFileMeta, isFalse);
      await store.upsertMessage('bob',
          _msg('old-v2-1', filePath: '/tmp/old.png', isFileMeta: true));
      final after = await store.loadMessages('bob');
      expect(after.single.isFileMeta, isTrue);
      expect(after.single.filePath, '/tmp/old.png');
      await store.close();
    });

    test('filePath 为 null 的消息往返不受影响', () async {
      final store = MessageCacheStore();
      await store.init(dbPath: dbPath('null_fp.db'));
      await store.upsertMessage('bob', _msg('m2'));
      final rows = await store.loadMessages('bob');
      expect(rows.single.filePath, isNull);
      await store.close();
    });

    test('v1 旧库（user_version=1，无 file_path 列）→ 迁移补列且旧数据保留',
        () async {
      final legacy = await openDatabase(dbPath('legacy_v1.db'), version: 1,
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
      });
      await legacy.insert('messages', {
        'message_id': 'old-1',
        'chat_key': 'bob',
        'sender': 'bob',
        'content': '[文件] old.png',
        'type': 'file',
        'timestamp': 1767225600000,
        'status': 'delivered',
        'filename': 'old.png',
      });
      final userVersion =
          (await legacy.rawQuery('PRAGMA user_version')).first['user_version'];
      expect(userVersion, 1);
      await legacy.close();

      final store = MessageCacheStore();
      await store.init(dbPath: dbPath('legacy_v1.db'));
      final rows = await store.loadMessages('bob');
      expect(rows.single.messageId, 'old-1');
      expect(rows.single.filename, 'old.png');
      expect(rows.single.filePath, isNull);
      await store.upsertMessage(
          'bob', _msg('old-1', filePath: '/tmp/old.png'));
      final after = await store.loadMessages('bob');
      expect(after.single.filePath, '/tmp/old.png');
      await store.close();
    });

    test('user_version=0 但已有旧表 → 打开后兜底补列', () async {
      final raw = await openDatabase(dbPath('bare_v0.db'));
      await raw.execute('''
        CREATE TABLE IF NOT EXISTS messages (
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
      await raw.insert('messages', {
        'message_id': 'bare-1',
        'chat_key': 'carol',
        'sender': 'carol',
        'content': '[文件] bare.png',
        'type': 'file',
        'timestamp': 1767225600000,
        'status': 'delivered',
        'filename': 'bare.png',
      });
      await raw.close();

      final store = MessageCacheStore();
      await store.init(dbPath: dbPath('bare_v0.db'));
      final rows = await store.loadMessages('carol');
      expect(rows.single.messageId, 'bare-1');
      expect(rows.single.filePath, isNull);
      await store.upsertMessage('carol',
          _msg('bare-1', filename: 'bare.png', filePath: '/tmp/bare.png'));
      final after = await store.loadMessages('carol');
      expect(after.single.filePath, isNotNull);
      await store.close();
    });
  });
}
