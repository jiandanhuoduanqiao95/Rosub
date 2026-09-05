// ============================================================
// 阶段 L —— 客户端本地消息缓存（L3，P0-4）
// ============================================================
// 依据《软件开发文档4.1.0.md》§11 阶段 L / §13.2 P0-4：
//   "消息全驻内存 AppState._messages；服务端一停历史一条都看不到。
//    本地 SQLite 落盘 + 启动先渲染再增量同步；移动端离线可用性前置"
//   §13.5：本地缓存层优先 sqflite（跨端一致），消息表 schema 与服务端
//   message_history 对齐。
//
// 本文件为 TDD 契约（实现前预期编译红——引用尚未实现的新本地存储服务
// `MessageCacheStore`，见 TESTING_GUIDE_FLUTTER.md §16.4）：
//
// 契约：
//   class MessageCacheStore {
//     Future<void> init({String? dbPath});   // 初始化（dbPath 注入便于测试隔离）
//     Future<void> upsertMessage(String chatKey, ChatMessage msg);      // 按 messageId 去重写入
//     Future<void> upsertMessages(String chatKey, List<ChatMessage> msgs);
//     Future<List<ChatMessage>> loadMessages(String chatKey);           // 全部，按时间升序
//     Future<List<ChatMessage>> loadRecentMessages(String chatKey, {int limit = 50});
//     Future<List<ChatMessage>> loadMessagesBefore(String chatKey, String messageId,
//                                                  {int limit = 50});   // 游标分页（更旧）
//     Future<void> removeMessage(String chatKey, String messageId);     // 仅我删除/撤回落地
//     Future<void> clearConversation(String chatKey);
//     Future<void> clearAll();                                          // 退出登录
//     Future<List<String>> conversations();                             // 有消息的会话 key
//   }
//
// 覆盖场景：落盘往返 / 去重 / 会话隔离 / 时间排序 / 启动秒开（最近 N 条）/
// 历史游标分页 / 仅我删除 / 清空 / 退出清理 / 重启持久化。
// ============================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/message_cache_store.dart';

ChatMessage _msg(String id, String sender, String content,
    {DateTime? ts, String status = 'delivered', String type = 'chat'}) {
  return ChatMessage(
    sender: sender,
    content: content,
    type: type,
    messageId: id,
    timestamp: ts ?? DateTime(2026, 1, 1, 12),
    status: status,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('L3 —— MessageCacheStore 本地消息缓存（P0-4）', () {
    late MessageCacheStore store;

    setUp(() async {
      store = MessageCacheStore();
      await store.init(dbPath: ':memory:');
    });

    // sqflite 按 path 缓存单例：tearDown 关闭释放 ':memory:'，保证用例间隔离
    tearDown(() async {
      await store.close();
    });

    test('往返：保存后 loadMessages 读取一致（字段完整）', () async {
      final msg = _msg('m1', 'bob', '你好');
      await store.upsertMessage('bob', msg);

      final list = await store.loadMessages('bob');
      expect(list.length, 1);
      expect(list.first.messageId, 'm1');
      expect(list.first.sender, 'bob');
      expect(list.first.content, '你好');
      expect(list.first.status, 'delivered');
    });

    test('按 messageId 去重：同 id 再保存 → 不重复，更新内容/状态', () async {
      await store.upsertMessage('bob', _msg('m1', 'bob', 'v1', status: 'sent'));
      await store.upsertMessage(
          'bob', _msg('m1', 'bob', 'v1', status: 'delivered'));

      final list = await store.loadMessages('bob');
      expect(list.length, 1, reason: '同 messageId 只落一条（服务端回显/多设备推送去重）');
      expect(list.first.status, 'delivered');
    });

    test('会话隔离：不同 chatKey 互不影响', () async {
      await store.upsertMessage('bob', _msg('m1', 'bob', '给alice'));
      await store.upsertMessage('carol', _msg('m2', 'carol', '给alice'));

      expect((await store.loadMessages('bob')).length, 1);
      expect((await store.loadMessages('carol')).length, 1);
    });

    test('时间升序排序：乱序写入按 timestamp 升序返回', () async {
      await store.upsertMessage(
          'bob', _msg('m3', 'bob', 'c', ts: DateTime(2026, 1, 1, 13)));
      await store.upsertMessage(
          'bob', _msg('m1', 'bob', 'a', ts: DateTime(2026, 1, 1, 11)));
      await store.upsertMessage(
          'bob', _msg('m2', 'bob', 'b', ts: DateTime(2026, 1, 1, 12)));

      final ids =
          (await store.loadMessages('bob')).map((m) => m.messageId).toList();
      expect(ids, ['m1', 'm2', 'm3']);
    });

    test('启动秒开：loadRecentMessages 取最近 N 条（按时间）', () async {
      for (var i = 1; i <= 10; i++) {
        await store.upsertMessage(
            'bob', _msg('m$i', 'bob', 't$i', ts: DateTime(2026, 1, 1, 10 + i)));
      }
      final recent = await store.loadRecentMessages('bob', limit: 3);
      expect(recent.length, 3);
      expect(recent.map((m) => m.messageId).toList(), ['m8', 'm9', 'm10'],
          reason: '取最近 3 条且按时间升序');
    });

    test('历史游标：loadMessagesBefore 取某 id 之前（更旧）N 条', () async {
      for (var i = 1; i <= 6; i++) {
        await store.upsertMessage(
            'bob', _msg('m$i', 'bob', 't$i', ts: DateTime(2026, 1, 1, 10 + i)));
      }
      // 以 m5 为游标，取更旧的 2 条 → m3, m4
      final before = await store.loadMessagesBefore('bob', 'm5', limit: 2);
      expect(before.map((m) => m.messageId).toList(), ['m3', 'm4']);
    });

    test('仅我删除：removeMessage 后消息不再返回', () async {
      await store.upsertMessage('bob', _msg('m1', 'bob', 'a'));
      await store.upsertMessage('bob', _msg('m2', 'bob', 'b'));
      await store.removeMessage('bob', 'm1');

      final list = await store.loadMessages('bob');
      expect(list.map((m) => m.messageId).toList(), ['m2']);
    });

    test('clearConversation 仅清空该会话', () async {
      await store.upsertMessage('bob', _msg('m1', 'bob', 'a'));
      await store.upsertMessage('carol', _msg('m2', 'carol', 'b'));
      await store.clearConversation('bob');

      expect(await store.loadMessages('bob'), isEmpty);
      expect((await store.loadMessages('carol')).length, 1);
    });

    test('退出登录：clearAll 清空全部会话', () async {
      await store.upsertMessage('bob', _msg('m1', 'bob', 'a'));
      await store.upsertMessage('carol', _msg('m2', 'carol', 'b'));
      await store.clearAll();

      expect(await store.conversations(), isEmpty);
    });

    test('conversations 返回有消息的会话 key（按最新活动排序）', () async {
      await store.upsertMessage('bob', _msg('m1', 'bob', 'a'));
      await store.upsertMessage('carol', _msg('m2', 'carol', 'b'));
      final convs = await store.conversations();
      expect(convs.toSet(), {'bob', 'carol'});
    });

    test('重启持久化：同 dbPath 重新 init 后数据仍在（离线可读）', () async {
      // 落盘（非 :memory:），模拟应用重启：close 后新建实例同 dbPath 重开
      final dir =
          '${Directory.systemTemp.path}/l3_cache_${DateTime.now().microsecondsSinceEpoch}.db';
      final first = MessageCacheStore();
      await first.init(dbPath: dir);
      await first.upsertMessage('bob', _msg('m1', 'bob', '离线可读'));
      await first.close();
      final reopened = MessageCacheStore();
      await reopened.init(dbPath: dir);

      final list = await reopened.loadMessages('bob');
      expect(list.length, 1, reason: '服务端不可用时仍可读到本地历史（离线可读）');
      expect(list.first.content, '离线可读');
    });
  });
}
