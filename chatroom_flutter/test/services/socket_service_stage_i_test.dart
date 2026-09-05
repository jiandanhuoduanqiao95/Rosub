// ============================================================
// socket_service.dart 阶段 I1 —— 发送队列契约（TDD 契约，待实现）
// ============================================================
// 覆盖 P0-1（《软件开发文档4.1.0.md》§13.2）断线场景的发送可靠性：
//   - 已登录 + 未连接：sendChat/sendGroupChat 入队 pending（消息不丢），
//     会话立即出现"发送中"气泡，返回 true（已受理）
//   - 未登录 / 空内容：不入队、返回 false
//   - retryPendingMessage：未连接时复位为发送中（交给重连补发）
//   - flushPendingQueue：未连接时无操作（重连成功后自动补发）
//
// 注意：本文件所有测试绝不触发真实网络连接（_socket 恒为 null）。
// ============================================================

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/socket_service.dart';
import 'package:chatroom_flutter/services/state_manager.dart';

AppState get state => AppState.instance;

void resetState() {
  state
    ..setLoggedOut()
    ..setConnectionStatus(ConnectionStatus.disconnected);
}

void main() {
  setUp(resetState);

  group('I1 —— 断线入队（已登录 + 未连接）', () {
    final service = SocketService();

    test('sendChat 未连接：消息入队 + 气泡出现 + 返回 true', () async {
      state.setLoggedIn('alice', false);
      final ok = await service.sendChat('bob', '断线时的消息');
      expect(ok, isTrue, reason: '消息已受理进入本地队列');
      expect(state.pendingCount, 1);
      final entry = state.pendingMessages.single;
      expect(entry.chatKey, 'bob');
      expect(entry.message.messageId, isNotEmpty);
      expect(entry.message.content, '断线时的消息');
      expect(entry.message.sender, 'alice');
      expect(entry.message.isSending, isTrue);
      // 会话立即显示气泡（发送中），用户可见
      final bubble = state.getMessages('bob').single;
      expect(bubble.content, '断线时的消息');
      expect(bubble.isSending, isTrue);
    });

    test('sendGroupChat 未连接：入队 + 气泡 + 群组信息保留', () async {
      state.setLoggedIn('alice', false);
      final ok = await service.sendGroupChat(7, '断线的群消息');
      expect(ok, isTrue);
      expect(state.pendingCount, 1);
      final entry = state.pendingMessages.single;
      expect(entry.chatKey, 'group_7');
      expect(entry.message.type, 'group_chat');
      expect(entry.message.groupId, 7);
      expect(entry.message.content, '断线的群消息');
      final bubble = state.getMessages('group_7').single;
      expect(bubble.isSending, isTrue);
    });

    test('连续断线发送保持 FIFO 顺序', () async {
      state.setLoggedIn('alice', false);
      await service.sendChat('bob', '第一条');
      await service.sendChat('bob', '第二条');
      await service.sendGroupChat(1, '群消息');
      final ids = state.pendingMessages.map((e) => e.message.content).toList();
      expect(ids, ['第一条', '第二条', '群消息']);
    });

    test('断线发送不产生未读计数（自己的消息）', () async {
      state.setLoggedIn('alice', false);
      await service.sendChat('bob', 'hi');
      expect(state.totalUnread, 0);
    });

    test('未登录时 sendChat 不入队、返回 false', () async {
      // state 未 setLoggedIn（resetState 已登出）
      final ok = await service.sendChat('bob', 'hi');
      expect(ok, isFalse);
      expect(state.pendingCount, 0);
      expect(state.getMessages('bob'), isEmpty);
    });

    test('空内容（仅空白）不入队、返回 false', () async {
      state.setLoggedIn('alice', false);
      expect(await service.sendChat('bob', ''), isFalse);
      expect(await service.sendChat('bob', '   '), isFalse);
      expect(state.pendingCount, 0);
      expect(state.getMessages('bob'), isEmpty);
    });

    test('sendChat 断线入队不触发通知/错误提示（静默受理）', () async {
      state.setLoggedIn('alice', false);
      await service.sendChat('bob', 'hi');
      expect(state.noticeQueue, isEmpty);
    });

    test('disconnect（退出登录）后队列被清空', () async {
      state.setLoggedIn('alice', false);
      await service.sendChat('bob', '一');
      await service.sendChat('bob', '二');
      expect(state.pendingCount, 2);
      service.disconnect();
      expect(state.pendingCount, 0);
      expect(state.pendingMessages, isEmpty);
    });
  });

  group('I1 —— 失败重试契约', () {
    final service = SocketService();

    test('retryPendingMessage 未连接：复位为发送中、返回 false、条目保留', () async {
      state.setLoggedIn('alice', false);
      await service.sendChat('bob', '待补发');
      state.markPendingFailed(state.pendingMessages.single.message.messageId);
      expect(state.pendingMessages.single.message.isFailed, isTrue);

      final messageId = state.pendingMessages.single.message.messageId;
      final ok = await service.retryPendingMessage(messageId);
      expect(ok, isFalse, reason: '未连接时本次未能发出');
      expect(state.pendingCount, 1, reason: '条目保留等待重连补发');
      expect(state.pendingMessages.single.message.isSending, isTrue,
          reason: '重试在途状态复位');
    });

    test('retryPendingMessage 对不存在的消息返回 false 且不崩溃', () async {
      state.setLoggedIn('alice', false);
      expect(await service.retryPendingMessage('ghost'), isFalse);
      expect(state.pendingCount, 0);
    });

    test('flushPendingQueue 未连接：返回 0、队列原样保留', () async {
      state.setLoggedIn('alice', false);
      await service.sendChat('bob', '一');
      await service.sendChat('bob', '二');
      final sent = await service.flushPendingQueue();
      expect(sent, 0, reason: '未连接无法补发');
      expect(state.pendingCount, 2, reason: '补发失败不丢消息');
    });

    test('重试成功后从队列出队并标记 sent（状态层验证）', () async {
      state.setLoggedIn('alice', false);
      await service.sendChat('bob', 'hi');
      final messageId = state.pendingMessages.single.message.messageId;
      // 模拟发送成功路径：实现中 retryPendingMessage 成功时调用 markPendingSent
      state.markPendingSent(messageId);
      expect(state.pendingCount, 0);
      expect(state.getMessages('bob').single.status, 'sent');
    });
  });
}
