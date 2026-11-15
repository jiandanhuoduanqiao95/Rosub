// opt8 #6 —— 撤回/送达状态持久化 + 服务端回显/历史合并不降级
//
// 契约：
//   - updateMessageStatus / recallMessage 状态变化即落盘（经写队列）；
//   - addMessage 同 ID 去重走服务端合并（recalled 不降级、delivered 不被
//     迟到 sent 回显降级），落盘的是合并后的对象；
//   - prependHistoryMessages 对已有 ID 允许 sent→delivered / sent→recalled
//     升级，不允许 recalled 降级，更新后落盘；
//   - 重登恢复（setLoggedOut 清内存 + restoreAll 缓存重建）后撤回态保留；
//   - 显式 setter 语义不变（recall 后再 delivered 仍允许，state_manager_test
//     既有契约）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/message_cache.dart';
import 'package:chatroom_flutter/services/state_manager.dart';

AppState get state => AppState.instance;

ChatMessage _msg(String id, String sender, String content,
    {String status = 'sent', DateTime? ts}) {
  return ChatMessage(
    sender: sender,
    content: content,
    type: 'chat',
    messageId: id,
    timestamp: ts ?? DateTime(2026, 1, 1, 12),
    status: status,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Directory? tmpDir;
  String? dbPath;

  Future<String> initCache() async {
    tmpDir = await Directory.systemTemp.createTemp('chatroom_cache_test');
    dbPath = '${tmpDir!.path}/cache.db';
    await MessageCache.init(dbPath: dbPath);
    return dbPath!;
  }

  setUp(() async {
    state.setLoggedOut();
    await MessageCache.resetForTest();
  });

  tearDown(() async {
    await MessageCache.resetForTest();
    final dir = tmpDir;
    if (dir != null && dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    tmpDir = null;
    dbPath = null;
  });

  group('#6 —— 状态落盘与合并（opt8）', () {
    test('updateMessageStatus / recallMessage 后 flush，缓存 status 正确',
        () async {
      await initCache();
      state.setLoggedIn('alice', false);
      state.addMessage('bob', _msg('m1', 'bob', '你好', status: 'sent'));
      state.addMessage('bob', _msg('m2', 'bob', '撤回我', status: 'sent'));
      state.updateMessageStatus('m1', 'delivered');
      state.recallMessage('m2');
      await MessageCache.flush();

      final rows = await MessageCache.store!.loadMessages('bob');
      final byId = {for (final m in rows) m.messageId: m};
      expect(byId['m1']!.status, 'delivered');
      expect(byId['m2']!.status, 'recalled');
    });

    test('updateMessageStatus 显式 setter：recall 后再 delivered 仍允许', () async {
      state.setLoggedIn('alice', false);
      state.addMessage('bob', _msg('m1', 'bob', '你好'));
      state.recallMessage('m1');
      expect(state.messageById('m1')!.isRecalled, isTrue);
      state.updateMessageStatus('m1', 'delivered');
      expect(state.messageById('m1')!.status, 'delivered');
    });

    test('迟到旧回显 status sent 不覆盖 recalled（内存 + 缓存）', () async {
      await initCache();
      state.setLoggedIn('alice', false);
      state.addMessage('bob', _msg('m1', 'bob', '你好', status: 'sent'));
      state.recallMessage('m1');

      state.addMessage('bob', _msg('m1', 'bob', '你好', status: 'sent'));
      expect(state.messageById('m1')!.isRecalled, isTrue);
      expect(state.getMessages('bob').length, 1);
      await MessageCache.flush();
      final rows = await MessageCache.store!.loadMessages('bob');
      expect(rows.single.status, 'recalled');
    });

    test('迟到旧回显 sent 不把 delivered 降级（内存 + 缓存）', () async {
      await initCache();
      state.setLoggedIn('alice', false);
      state.addMessage('bob', _msg('m1', 'bob', '你好', status: 'sent'));
      state.updateMessageStatus('m1', 'delivered');

      state.addMessage('bob', _msg('m1', 'bob', '你好', status: 'sent'));
      expect(state.messageById('m1')!.status, 'delivered');
      await MessageCache.flush();
      final rows = await MessageCache.store!.loadMessages('bob');
      expect(rows.single.status, 'delivered');
    });

    test('历史 recalled 升级内存（sent→recalled），再次 sent 历史不降级',
        () async {
      await initCache();
      state.setLoggedIn('alice', false);
      state.prependHistoryMessages('bob', [
        _msg('m1', 'bob', '你好', status: 'sent'),
      ]);
      expect(state.messageById('m1')!.status, 'sent');

      state.prependHistoryMessages('bob', [
        _msg('m1', 'bob', '你好', status: 'recalled'),
      ]);
      expect(state.messageById('m1')!.isRecalled, isTrue);
      expect(state.getMessages('bob').length, 1);
      await MessageCache.flush();
      var rows = await MessageCache.store!.loadMessages('bob');
      expect(rows.single.status, 'recalled');

      state.prependHistoryMessages('bob', [
        _msg('m1', 'bob', '你好', status: 'sent'),
      ]);
      expect(state.messageById('m1')!.isRecalled, isTrue);
      await MessageCache.flush();
      rows = await MessageCache.store!.loadMessages('bob');
      expect(rows.single.status, 'recalled');
    });

    test('prepend 允许 sent→delivered 升级并落盘', () async {
      await initCache();
      state.setLoggedIn('alice', false);
      state.prependHistoryMessages('bob', [
        _msg('m1', 'bob', '你好', status: 'sent'),
      ]);
      state.prependHistoryMessages('bob', [
        _msg('m1', 'bob', '你好', status: 'delivered'),
      ]);
      expect(state.messageById('m1')!.status, 'delivered');
      await MessageCache.flush();
      final rows = await MessageCache.store!.loadMessages('bob');
      expect(rows.single.status, 'delivered');
    });

    test('setLoggedOut 清内存 + 重开缓存 restoreAll 后仍 isRecalled', () async {
      final path = await initCache();
      state.setLoggedIn('alice', false);
      state.addMessage('bob', _msg('m1', 'bob', '撤回测试', status: 'sent'));
      state.recallMessage('m1');
      await MessageCache.flush();

      await MessageCache.resetForTest();
      state.setLoggedOut();
      expect(state.getMessages('bob'), isEmpty);
      expect(state.messageById('m1'), isNull);

      await MessageCache.init(dbPath: path);
      await MessageCache.restoreAll();
      final restored = state.getMessages('bob');
      expect(restored.length, 1);
      expect(restored.first.isRecalled, isTrue);
      expect(state.messageById('m1')!.isRecalled, isTrue);
    });

    test('applyServerStatus：recall 后迟到的 delivered 不降级（内存+缓存）',
        () async {
      await initCache();
      state.setLoggedIn('alice', false);
      state.addMessage('bob', _msg('m1', 'bob', '撤回态', status: 'sent'));
      state.recallMessage('m1');
      state.applyServerStatus('m1', 'delivered');
      expect(state.messageById('m1')!.isRecalled, isTrue,
          reason: '服务端状态路径 recalled 终态，不被迟到 delivered 覆盖');
      await MessageCache.flush();
      final rows = await MessageCache.store!.loadMessages('bob');
      expect(rows.single.status, 'recalled');
    });

    test('applyServerStatus：delivered 之后迟到的 sent 不降级', () async {
      await initCache();
      state.setLoggedIn('alice', false);
      state.addMessage('bob', _msg('m1', 'bob', '已送达', status: 'sent'));
      state.applyServerStatus('m1', 'delivered');
      state.applyServerStatus('m1', 'sent');
      expect(state.messageById('m1')!.status, 'delivered');
      await MessageCache.flush();
      final rows = await MessageCache.store!.loadMessages('bob');
      expect(rows.single.status, 'delivered');
    });

    test('applyServerStatus recalled 清 pending 队列', () {
      state.setLoggedIn('alice', false);
      state.addMessage('bob', _msg('m1', 'alice', '断线在途',
          status: 'sending'));
      state.enqueuePendingMessage(
          'bob', _msg('m1', 'alice', '断线在途', status: 'sending'));
      expect(state.pendingCount, 1);
      state.applyServerStatus('m1', 'recalled');
      expect(state.pendingCount, 0);
      expect(state.messageById('m1')!.isRecalled, isTrue);
    });

    test('applyServerStatus sent→delivered 升级并落盘；miss 静默 no-op',
        () async {
      await initCache();
      state.setLoggedIn('alice', false);
      state.addMessage('bob', _msg('m1', 'bob', '在途', status: 'sending'));
      state.applyServerStatus('m1', 'delivered');
      expect(state.messageById('m1')!.status, 'delivered');
      await MessageCache.flush();
      final rows = await MessageCache.store!.loadMessages('bob');
      expect(rows.single.status, 'delivered');
      state.applyServerStatus('ghost-id', 'delivered');
      expect(state.messageById('ghost-id'), isNull);
    });

    test('直接 persist sent 再 recalled，flush 后缓存为 recalled', () async {
      await initCache();
      await MessageCache.persist('bob', _msg('m1', 'bob', '你好',
          status: 'sent'));
      await MessageCache.persist('bob', _msg('m1', 'bob', '你好',
          status: 'recalled'));
      await MessageCache.flush();
      final rows = await MessageCache.store!.loadMessages('bob');
      expect(rows.length, 1);
      expect(rows.single.status, 'recalled');
    });

    test('写队列串行：persist 与 removeMessage 按序执行不复活', () async {
      await initCache();
      await MessageCache.persist('bob', _msg('m1', 'bob', '你好'));
      await MessageCache.flush();
      final f = MessageCache.persist(
          'bob', _msg('m1', 'bob', '你好', status: 'sent'));
      await MessageCache.removeMessage('bob', 'm1');
      await f;
      await MessageCache.flush();
      final rows = await MessageCache.store!.loadMessages('bob');
      expect(rows, isEmpty, reason: '删除晚于写入入队，最终不应复活');
    });
  });
}
