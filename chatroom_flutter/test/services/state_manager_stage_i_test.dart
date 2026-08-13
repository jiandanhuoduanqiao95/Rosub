// ============================================================
// state_manager.dart 阶段 I —— 发送队列 + 会话元数据（TDD 契约，待实现）
// ============================================================
// 覆盖 P0-1 / P0-8（《软件开发文档4.1.0.md》§13.2）：
//   - 本地 pending 发送队列：入队/去重/发送成功出队/失败保留/重试复位
//   - 队列与消息状态联动：updateMessageStatus(delivered/recalled) 自动出队
//   - 登出清空队列与全部会话元数据
//   - conversations 元数据状态：pinned/muted/draft/clearedAt 读写与隔离
//
// 注意：AppState 是单例，测试间需通过 setLoggedOut() 复位。
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/state_manager.dart';

AppState get state => AppState.instance;

void resetState() {
  state
    ..setLoggedOut()
    ..setConnectionStatus(ConnectionStatus.disconnected);
}

ChatMessage _selfMsg(String id, String content,
    {String status = 'sending', int? groupId, String type = 'chat'}) {
  return ChatMessage(
    sender: 'alice',
    content: content,
    messageId: id,
    status: status,
    type: type,
    groupId: groupId,
  );
}

void main() {
  setUp(resetState);

  group('I1 —— pending 发送队列', () {
    test('入队后 pendingCount 增加且保持 FIFO 顺序', () {
      state.enqueuePendingMessage('bob', _selfMsg('m1', '一'));
      state.enqueuePendingMessage('bob', _selfMsg('m2', '二'));
      state.enqueuePendingMessage('group_1', _selfMsg('m3', '三', groupId: 1));
      expect(state.pendingCount, 3);
      final ids =
          state.pendingMessages.map((e) => e.message.messageId).toList();
      expect(ids, ['m1', 'm2', 'm3']);
      expect(state.pendingMessages[0].chatKey, 'bob');
      expect(state.pendingMessages[2].chatKey, 'group_1');
    });

    test('入队条目消息状态为 sending', () {
      state.enqueuePendingMessage('bob', _selfMsg('m1', 'hi'));
      expect(state.pendingMessages.single.message.status, 'sending');
    });

    test('同 messageId 重复入队去重（保留原顺序）', () {
      state.enqueuePendingMessage('bob', _selfMsg('m1', '一'));
      state.enqueuePendingMessage('carol', _selfMsg('m2', '二'));
      state.enqueuePendingMessage('bob', _selfMsg('m1', '一(重发)'));
      expect(state.pendingCount, 2);
      final ids =
          state.pendingMessages.map((e) => e.message.messageId).toList();
      expect(ids, ['m1', 'm2']);
      expect(state.pendingMessages.first.message.content, '一(重发)');
    });

    test('markPendingSent 出队并将消息状态置为 sent', () {
      state.setLoggedIn('alice', false);
      state.addMessage('bob', _selfMsg('m1', 'hi'));
      state.enqueuePendingMessage('bob', _selfMsg('m1', 'hi'));
      expect(state.pendingCount, 1);
      final removed = state.markPendingSent('m1');
      expect(removed, isTrue);
      expect(state.pendingCount, 0);
      expect(state.getMessages('bob').single.status, 'sent');
    });

    test('markPendingSent 对不在队列的消息返回 false 且不抛异常', () {
      expect(state.markPendingSent('ghost'), isFalse);
      expect(state.pendingCount, 0);
    });

    test('markPendingFailed 保留队列条目并将状态置为 failed', () {
      state.setLoggedIn('alice', false);
      state.addMessage('bob', _selfMsg('m1', 'hi'));
      state.enqueuePendingMessage('bob', _selfMsg('m1', 'hi'));
      final kept = state.markPendingFailed('m1');
      expect(kept, isTrue);
      expect(state.pendingCount, 1, reason: '失败消息保留在队列待重试');
      expect(state.pendingMessages.single.message.status, 'failed');
      expect(state.getMessages('bob').single.isFailed, isTrue);
    });

    test('markPendingSending 复位为发送中（重试在途）', () {
      state.setLoggedIn('alice', false);
      state.addMessage('bob', _selfMsg('m1', 'hi'));
      state.enqueuePendingMessage('bob', _selfMsg('m1', 'hi'));
      state.markPendingFailed('m1');
      final reset = state.markPendingSending('m1');
      expect(reset, isTrue);
      expect(state.pendingMessages.single.message.status, 'sending');
      expect(state.getMessages('bob').single.isSending, isTrue);
    });

    test('updateMessageStatus(delivered) 自动出队（服务端回执路径）', () {
      state.setLoggedIn('alice', false);
      state.addMessage('bob', _selfMsg('m1', 'hi'));
      state.enqueuePendingMessage('bob', _selfMsg('m1', 'hi'));
      expect(state.pendingCount, 1);
      state.updateMessageStatus('m1', 'delivered');
      expect(state.pendingCount, 0, reason: '收到 delivered 回执后无需再补发');
      expect(state.getMessages('bob').single.status, 'delivered');
    });

    test('updateMessageStatus(recalled) 自动出队（撤回路径）', () {
      state.setLoggedIn('alice', false);
      state.addMessage('bob', _selfMsg('m1', 'hi'));
      state.enqueuePendingMessage('bob', _selfMsg('m1', 'hi'));
      state.updateMessageStatus('m1', 'recalled');
      expect(state.pendingCount, 0);
      expect(state.getMessages('bob').single.isRecalled, isTrue);
    });

    test('updateMessageStatus(failed) 不触发自动出队（避免误删）', () {
      state.setLoggedIn('alice', false);
      state.addMessage('bob', _selfMsg('m1', 'hi'));
      state.enqueuePendingMessage('bob', _selfMsg('m1', 'hi'));
      state.updateMessageStatus('m1', 'failed');
      expect(state.pendingCount, 1, reason: 'failed 由队列标记管理');
    });

    test('setLoggedOut 清空发送队列', () {
      state.setLoggedIn('alice', false);
      state.enqueuePendingMessage('bob', _selfMsg('m1', '一'));
      state.enqueuePendingMessage('group_1', _selfMsg('m2', '二', groupId: 1));
      expect(state.pendingCount, 2);
      state.setLoggedOut();
      expect(state.pendingCount, 0);
      expect(state.pendingMessages, isEmpty);
    });

    test('队列与未读计数相互独立（自己发送不产生未读）', () {
      state.setLoggedIn('alice', false);
      state.enqueuePendingMessage('bob', _selfMsg('m1', 'hi'));
      expect(state.totalUnread, 0);
    });

    test('入队/出队触发监听通知', () {
      var notified = 0;
      state.addListener(() => notified++);
      state.enqueuePendingMessage('bob', _selfMsg('m1', 'x'));
      expect(notified, greaterThan(0));
      notified = 0;
      state.markPendingSent('m1');
      expect(notified, greaterThan(0));
    });

    test('服务端回显（离线历史推送同 messageId）→ 队列自动出队（Q-02 修复）', () {
      // 场景：在线发送"通信正常"时 write 异常，误入队列（failed）；
      // 重连后服务端在离线历史中回显同 messageId → 证明已入库 → 出队，不再补发
      state.setLoggedIn('alice', false);
      state.addMessage('bob', _selfMsg('m1', '通信正常'));
      state.enqueuePendingMessage('bob', _selfMsg('m1', '通信正常'));
      state.markPendingFailed('m1');
      expect(state.pendingCount, 1);

      // 模拟重连 relogin 的离线历史回显（history=true，status=sent，同 messageId）
      state.addMessage(
        'bob',
        ChatMessage(
          sender: 'alice',
          content: '通信正常',
          messageId: 'm1',
          status: 'sent',
          isHistory: true,
        ),
      );

      expect(state.pendingCount, 0, reason: '已入库消息不得留在补发队列');
      expect(state.getMessages('bob').single.status, 'sent');
    });

    test('服务端回显不误删未匹配的队列条目', () {
      state.setLoggedIn('alice', false);
      state.enqueuePendingMessage('bob', _selfMsg('m1', '一'));
      state.enqueuePendingMessage('bob', _selfMsg('m2', '二'));
      state.addMessage('bob', _selfMsg('m1', '一', status: 'sent'));
      expect(state.pendingCount, 1, reason: '仅 m1 出队，m2 保留');
      expect(state.pendingMessages.single.message.messageId, 'm2');
    });

    test('每次重连全量补发：sending 与 failed 条目都保留到送达（Q-02 二次修复）', () {
      // 设计：重连 flush 覆盖全部队列条目（服务端按 message_id 幂等去重，
      // 已送达的重发被丢弃）；failed 条目不得被 echo 误删，等待下次重连补发
      state.setLoggedIn('alice', false);
      state.enqueuePendingMessage('bob', _selfMsg('m1', '断线测试'));
      state.enqueuePendingMessage('bob', _selfMsg('m2', '通信正常'));
      state.markPendingFailed('m2'); // 上次补发失败，交付状态未知

      expect(state.pendingCount, 2, reason: 'failed 条目保留，等待下次重连全量补发');
      final ids =
          state.pendingMessages.map((e) => e.message.messageId).toList();
      expect(ids, ['m1', 'm2']);

      // 服务端回显（已入库）→ 仅该条目出队，其余保留
      state.addMessage('bob', _selfMsg('m2', '通信正常', status: 'sent'));
      expect(state.pendingCount, 1);
      expect(state.pendingMessages.single.message.messageId, 'm1');
    });

    test('removePendingMessage 幂等：不存在返回 false', () {
      state.setLoggedIn('alice', false);
      expect(state.removePendingMessage('ghost'), isFalse);
      expect(state.pendingCount, 0);
    });

    test('removeFriend 后队列中该会话条目保留（待补发由上层决策）', () {
      // 契约说明：删除好友不隐式丢弃 pending 条目，行为由 socket 层决定；
      // 此处仅锁定"状态层不崩溃、条目不被误清理"
      state.setLoggedIn('alice', false);
      state.addFriend('bob');
      state.enqueuePendingMessage('bob', _selfMsg('m1', 'x'));
      state.removeFriend('bob');
      expect(state.pendingCount, 1);
    });
  });

  group('I2 —— conversations 会话元数据状态', () {
    test('未设置时默认值：未置顶/未静音/无草稿/无清空标记', () {
      expect(state.isPinned('bob'), isFalse);
      expect(state.isMuted('bob'), isFalse);
      expect(state.draftOf('bob'), '');
      expect(state.clearedAtOf('bob'), isNull);
      expect(state.conversationMetaOf('bob'), isNull);
    });

    test('置顶/取消置顶', () {
      state.setConversationPinned('bob', true);
      expect(state.isPinned('bob'), isTrue);
      expect(state.conversationMetaOf('bob')!.pinned, isTrue);
      state.setConversationPinned('bob', false);
      expect(state.isPinned('bob'), isFalse);
    });

    test('静音/取消静音', () {
      state.setConversationMuted('bob', true);
      expect(state.isMuted('bob'), isTrue);
      state.setConversationMuted('bob', false);
      expect(state.isMuted('bob'), isFalse);
    });

    test('草稿保存/更新/清空', () {
      state.setConversationDraft('bob', '第一版');
      state.setConversationDraft('bob', '第二版');
      expect(state.draftOf('bob'), '第二版');
      state.setConversationDraft('bob', '');
      expect(state.draftOf('bob'), '');
    });

    test('清空标记设置/清除', () {
      final t = DateTime(2026, 8, 12, 10, 0);
      state.setConversationClearedAt('bob', t);
      expect(state.clearedAtOf('bob'), t);
      state.setConversationClearedAt('bob', null);
      expect(state.clearedAtOf('bob'), isNull);
    });

    test('多字段并存互不覆盖', () {
      state.setConversationPinned('bob', true);
      state.setConversationMuted('bob', true);
      state.setConversationDraft('bob', 'd');
      final t = DateTime(2026, 8, 12);
      state.setConversationClearedAt('bob', t);
      final meta = state.conversationMetaOf('bob')!;
      expect(meta.pinned, isTrue);
      expect(meta.muted, isTrue);
      expect(meta.draft, 'd');
      expect(meta.clearedAt, t);
    });

    test('会话隔离：不同会话互不影响', () {
      state.setConversationPinned('bob', true);
      state.setConversationDraft('carol', 'c 的草稿');
      expect(state.isPinned('carol'), isFalse);
      expect(state.draftOf('bob'), '');
      expect(state.draftOf('carol'), 'c 的草稿');
    });

    test('群聊会话与私聊同表存储（group_N key）', () {
      state.setConversationMuted('group_1', true);
      expect(state.isMuted('group_1'), isTrue);
      expect(state.isMuted('bob'), isFalse);
    });

    test('系统消息会话同样可存元数据（防御）', () {
      state.setConversationPinned('服务器', true);
      expect(state.isPinned('服务器'), isTrue);
    });

    test('setLoggedOut 清空全部会话元数据', () {
      state.setLoggedIn('alice', false);
      state.setConversationPinned('bob', true);
      state.setConversationDraft('carol', 'd');
      state.setConversationClearedAt('group_1', DateTime(2026, 8, 12));
      expect(state.isPinned('bob'), isTrue);
      state.setLoggedOut();
      expect(state.isPinned('bob'), isFalse);
      expect(state.draftOf('carol'), '');
      expect(state.clearedAtOf('group_1'), isNull);
      expect(state.conversationMetaOf('bob'), isNull);
    });

    test('元数据写入触发监听通知', () {
      var notified = 0;
      state.addListener(() => notified++);
      state.setConversationPinned('bob', true);
      expect(notified, greaterThan(0));
    });

    test('ConversationMeta.copyWith 部分复制', () {
      const base = ConversationMeta(pinned: true, muted: false, draft: 'd');
      final next = base.copyWith(muted: true);
      expect(next.pinned, isTrue);
      expect(next.muted, isTrue);
      expect(next.draft, 'd');
      expect(next.clearedAt, isNull);
    });
  });
}
