// ============================================================
// chat_view.dart 阶段 I1 —— "发送中/发送失败" 气泡 UI（TDD 契约，待实现）
// ============================================================
// 覆盖 P0-1（《软件开发文档4.1.0.md》§13.2）"发送中/失败" UI：
//   - 自己发送中的消息：气泡内显示"发送中…"标记
//   - 自己发送失败的消息：气泡内显示"发送失败"标记 + 点击重试
//   - 点击失败气泡触发 onRetrySend(messageId)
//   - sent / delivered / recalled / 对方消息不显示发送标记
//   - onRetrySend 为空时点击不崩溃（防御）
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/widgets/chat_view.dart';

Widget wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: SizedBox(width: 600, child: child)));

ChatMessage msg(String sender, String content, String id,
        {String status = 'sent', String? type, int? groupId}) =>
    ChatMessage(
      sender: sender,
      content: content,
      messageId: id,
      status: status,
      type: type ?? 'chat',
      groupId: groupId,
    );

ChatView view(List<ChatMessage> messages,
    {String username = 'alice',
    String chatKey = 'bob',
    void Function(String messageId)? onRetrySend}) {
  return ChatView(
    chatKey: chatKey,
    chatTitle: chatKey,
    messages: messages,
    username: username,
    inputCtrl: TextEditingController(),
    canSend: true,
    onSend: () {},
    onSendFile: () {},
    onRecall: (_) {},
    onLoadHistory: (_) async {},
    hasMoreHistory: (_) => false,
    onRetrySend: onRetrySend,
  );
}

void main() {
  group('I1 —— 发送中气泡', () {
    testWidgets('自己发送中的消息显示"发送中…"标记', (tester) async {
      await tester.pumpWidget(wrap(view([
        msg('alice', '在途内容', 'm1', status: 'sending'),
      ])));
      expect(find.text('在途内容'), findsOneWidget);
      expect(find.textContaining('发送中'), findsOneWidget);
    });

    testWidgets('已送达（sent/delivered）不显示发送中标记', (tester) async {
      await tester.pumpWidget(wrap(view([
        msg('alice', 'a', 'm1', status: 'sent'),
        msg('alice', 'b', 'm2', status: 'delivered'),
      ])));
      expect(find.textContaining('发送中'), findsNothing);
    });

    testWidgets('对方发送中的消息不显示标记（防御：仅自己消息有发送语义）', (tester) async {
      await tester.pumpWidget(wrap(view([
        msg('bob', '对方内容', 'm1', status: 'sending'),
      ])));
      expect(find.textContaining('发送中'), findsNothing);
    });
  });

  group('I1 —— 发送失败气泡与重试', () {
    testWidgets('自己发送失败的消息显示"发送失败"标记', (tester) async {
      await tester.pumpWidget(wrap(view([
        msg('alice', '失败内容', 'm1', status: 'failed'),
      ])));
      expect(find.text('失败内容'), findsOneWidget);
      expect(find.textContaining('发送失败'), findsOneWidget);
    });

    testWidgets('点击失败气泡触发 onRetrySend(messageId)', (tester) async {
      final retried = <String>[];
      await tester.pumpWidget(wrap(view(
        [
          msg('alice', '失败内容', 'm-fail-1', status: 'failed'),
          msg('alice', '正常内容', 'm-ok-2', status: 'sent'),
        ],
        onRetrySend: retried.add,
      )));
      await tester.tap(find.text('失败内容'));
      expect(retried, ['m-fail-1']);
    });

    testWidgets('点击已发送/对方消息不触发重试', (tester) async {
      final retried = <String>[];
      await tester.pumpWidget(wrap(view(
        [
          msg('alice', '已发送', 'm1', status: 'sent'),
          msg('bob', '对方消息', 'm2'),
        ],
        onRetrySend: retried.add,
      )));
      await tester.tap(find.text('已发送'));
      await tester.tap(find.text('对方消息'));
      expect(retried, isEmpty);
    });

    testWidgets('对方 failed 消息不提供重试入口（防御）', (tester) async {
      final retried = <String>[];
      await tester.pumpWidget(wrap(view(
        [msg('bob', '对方失败', 'm1', status: 'failed')],
        onRetrySend: retried.add,
      )));
      await tester.tap(find.text('对方失败'));
      expect(retried, isEmpty);
    });

    testWidgets('onRetrySend 为空时点击失败气泡不崩溃', (tester) async {
      await tester.pumpWidget(wrap(view(
        [msg('alice', '失败内容', 'm1', status: 'failed')],
        onRetrySend: null,
      )));
      await tester.tap(find.text('失败内容'), warnIfMissed: false);
      expect(tester.takeException(), isNull);
    });

    testWidgets('群聊失败消息同样可重试', (tester) async {
      final retried = <String>[];
      await tester.pumpWidget(wrap(view(
        [
          msg('alice', '群失败', 'g1', status: 'failed', type: 'group_chat'),
        ],
        chatKey: 'group_1',
        onRetrySend: retried.add,
      )));
      await tester.tap(find.text('群失败'));
      expect(retried, ['g1']);
    });
  });

  group('I1 —— 与既有状态共存', () {
    testWidgets('撤回优先：recalled 显示已撤回而非发送标记', (tester) async {
      await tester.pumpWidget(wrap(view([
        msg('alice', '内容', 'm1', status: 'recalled'),
        msg('alice', '失败内容', 'm2', status: 'failed'),
      ])));
      expect(find.textContaining('已撤回'), findsOneWidget);
      expect(find.textContaining('发送失败'), findsOneWidget);
    });

    testWidgets('系统消息不显示发送标记', (tester) async {
      await tester.pumpWidget(wrap(view(
        [
          ChatMessage(
            sender: '服务器',
            content: '公告',
            messageId: 's1',
            type: 'system',
            status: 'failed',
          ),
        ],
        chatKey: '服务器',
      )));
      expect(find.textContaining('发送失败'), findsNothing);
    });

    testWidgets('文件消息（file）不显示发送中/失败标记', (tester) async {
      await tester.pumpWidget(wrap(view([
        ChatMessage(
          sender: 'alice',
          content: '[发送文件] a.pdf',
          messageId: 'f1',
          type: 'file',
          filename: 'a.pdf',
          status: 'sending',
        ),
      ])));
      expect(find.textContaining('发送中'), findsNothing);
    });
  });
}
