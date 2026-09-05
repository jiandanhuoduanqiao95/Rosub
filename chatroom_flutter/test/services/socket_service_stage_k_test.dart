// ============================================================
// socket_service.dart 阶段 K —— 新协议方法契约（已实现，全部转绿）
// ============================================================
// 覆盖 P1-11~P1-14 / P1-2 / P1-3 / P1-4（《软件开发文档4.1.0.md》§11 阶段 K / §13.3）：
//   - K1 pinConversation / unpinConversation（协议 pin / unpin）
//   - K2 saveConversationDraft（协议 set_draft）
//   - K3 muteConversation（协议 mute）
//   - K5 replyMessage / forwardMessage / addReaction / removeReaction
//     （协议 reply / forward / reaction；P1-1 编辑已移除）
// 未连接（_socket == null）时全部方法：静默无副作用、不崩溃。
// 连接态实现约定（阶段 J 惯例）：先乐观更新本地状态再发送；
// ChatScreen 接线层调用前同步本地状态（幂等，与 socket 层乐观更新一致，
// 保证 mock 场景下状态断言成立——见 chat_screen_stage_k_test.dart）。
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

  group('K —— 未连接时的公开 API 契约', () {
    final service = SocketService();

    test('pinConversation 未连接不崩溃、无副作用', () async {
      await service.pinConversation('bob');
      expect(state.isPinned('bob'), isFalse);
    });

    test('unpinConversation 未连接不崩溃、无副作用', () async {
      state.setConversationPinned('bob', true);
      await service.unpinConversation('bob');
      expect(state.isPinned('bob'), isTrue, reason: '未连接时不得乐观更新（与服务端不一致）');
    });

    test('muteConversation 未连接不崩溃、无副作用', () async {
      await service.muteConversation('bob', true);
      expect(state.isMuted('bob'), isFalse);
    });

    test('saveConversationDraft 未连接不崩溃、无副作用', () async {
      await service.saveConversationDraft('bob', '草稿');
      expect(state.draftOf('bob'), '');
    });

    test('replyMessage 未连接不崩溃、无副作用', () async {
      state.setLoggedIn('alice', false);
      await service.replyMessage('m1', '回复', 'bob');
      expect(state.getMessages('bob'), isEmpty);
    });

    test('forwardMessage 未连接不崩溃、无副作用', () async {
      state.setLoggedIn('alice', false);
      await service.forwardMessage('m1', 'carol');
      expect(state.getMessages('carol'), isEmpty);
    });

    test('addReaction 未连接不崩溃、无副作用', () async {
      state.setLoggedIn('alice', false);
      final msg = ChatMessage(sender: 'bob', content: '内容', messageId: 'm1');
      state.addMessage('bob', msg);
      await service.addReaction('m1', '👍', 'bob');
      expect(state.messageById('m1')?.reactions, isEmpty);
    });

    test('removeReaction 未连接不崩溃、无副作用', () async {
      state.setLoggedIn('alice', false);
      final msg = ChatMessage(
        sender: 'bob',
        content: '内容',
        messageId: 'm1',
        reactions: const {
          '👍': ['alice']
        },
      );
      state.addMessage('bob', msg);
      await service.removeReaction('m1', '👍', 'bob');
      expect(state.messageById('m1')?.reactions, {
        '👍': ['alice']
      });
    });

    test('全部新方法在未登录未连接时均静默失败', () async {
      final beforeLog = state.statusLog.length;
      await service.pinConversation('bob');
      await service.unpinConversation('bob');
      await service.muteConversation('bob', true);
      await service.saveConversationDraft('bob', 'x');
      await service.replyMessage('m1', 'x', 'bob');
      await service.forwardMessage('m1', 'carol');
      await service.addReaction('m1', '👍', 'bob');
      await service.removeReaction('m1', '👍', 'bob');
      expect(state.statusLog.length, beforeLog, reason: '不应产生错误日志');
      expect(state.noticeQueue, isEmpty);
    });
  });
}
