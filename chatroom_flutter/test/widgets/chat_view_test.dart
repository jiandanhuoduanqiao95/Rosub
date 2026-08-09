// ============================================================
// chat_view.dart Widget 测试
// ============================================================
// 验证消息气泡渲染、撤回指示、系统消息样式、只读会话栏、
// 空消息占位与加载指示器。
// ChatView 接受纯参数（含消息列表与回调），便于直接 pump。
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/widgets/chat_view.dart';

Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: SizedBox(width: 600, child: child)));

ChatMessage msg(String sender, String content, String id,
    {String status = 'sent', String? type, String? filename}) =>
    ChatMessage(
      sender: sender,
      content: content,
      messageId: id,
      status: status,
      type: type ?? 'chat',
      filename: filename,
    );

void main() {
  group('空消息与只读栏', () {
    testWidgets('无消息时显示占位', (tester) async {
      await tester.pumpWidget(wrap(ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: const [],
        username: 'alice',
        inputCtrl: TextEditingController(),
        canSend: false,
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
      )));
      expect(find.text('暂无消息'), findsOneWidget);
    });

    testWidgets('系统会话（canSend=false）显示只读栏', (tester) async {
      await tester.pumpWidget(wrap(ChatView(
        chatKey: '服务器',
        chatTitle: '系统消息',
        messages: const [],
        username: 'alice',
        inputCtrl: TextEditingController(),
        canSend: false,
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
      )));
      expect(find.text('系统消息 为只读会话'), findsOneWidget);
    });
  });

  group('消息气泡渲染', () {
    testWidgets('自己消息不显示发送者名，对方消息显示', (tester) async {
      final messages = [
        msg('alice', '我自己发的', 'm1'),
        msg('bob', '对方发的', 'm2'),
      ];
      await tester.pumpWidget(wrap(ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: messages,
        username: 'alice',
        inputCtrl: TextEditingController(),
        canSend: false,
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
      )));
      expect(find.text('我自己发的'), findsOneWidget);
      expect(find.text('对方发的'), findsOneWidget);
      // 自己的气泡不显示发送者名称（仅对方气泡显示）
      expect(find.text('alice'), findsNothing);
      expect(find.text('bob'), findsWidgets);
    });

    testWidgets('已撤回消息显示灰色占位文本', (tester) async {
      final messages = [
        msg('alice', '会撤回的内容', 'm1', status: 'recalled'),
      ];
      await tester.pumpWidget(wrap(ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: messages,
        username: 'alice',
        inputCtrl: TextEditingController(),
        canSend: false,
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
      )));
      expect(find.textContaining('[消息已撤回]'), findsOneWidget);
    });

    testWidgets('系统消息居中胶囊样式（_SystemMessage）', (tester) async {
      final messages = [
        ChatMessage(
          sender: '服务器',
          content: '系统维护通知',
          messageId: 's1',
          type: 'system',
        ),
      ];
      await tester.pumpWidget(wrap(ChatView(
        chatKey: '服务器',
        chatTitle: '系统消息',
        messages: messages,
        username: 'alice',
        inputCtrl: TextEditingController(),
        canSend: false,
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
      )));
      expect(find.text('系统维护通知'), findsOneWidget);
    });

    testWidgets('群组聊天标题显示群名', (tester) async {
      await tester.pumpWidget(wrap(ChatView(
        chatKey: 'group_1',
        chatTitle: '开发组 (ID:1)',
        messages: const [],
        username: 'alice',
        inputCtrl: TextEditingController(),
        canSend: false,
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
      )));
      expect(find.text('开发组 (ID:1)'), findsOneWidget);
    });

    testWidgets('私聊标题为"与 X 的聊天"', (tester) async {
      await tester.pumpWidget(wrap(ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: const [],
        username: 'alice',
        inputCtrl: TextEditingController(),
        canSend: false,
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
      )));
      expect(find.text('与 bob 的聊天'), findsOneWidget);
    });
  });

  group('消息撤回交互', () {
    testWidgets('自己未撤回消息长按触发 onRecall', (tester) async {
      String? recalled;
      final messages = [msg('alice', '可撤回', 'm1')];
      await tester.pumpWidget(wrap(ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: messages,
        username: 'alice',
        inputCtrl: TextEditingController(),
        canSend: false,
        onSend: () {},
        onSendFile: () {},
        onRecall: (id) => recalled = id,
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
      )));
      await tester.longPress(find.text('可撤回'));
      await tester.pump();
      expect(recalled, 'm1');
    });

    testWidgets('对方消息不触发撤回（onRecall 为 null）', (tester) async {
      String? recalled;
      final messages = [msg('bob', '对方消息', 'm2')];
      await tester.pumpWidget(wrap(ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: messages,
        username: 'alice',
        inputCtrl: TextEditingController(),
        canSend: false,
        onSend: () {},
        onSendFile: () {},
        onRecall: (id) => recalled = id,
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
      )));
      await tester.longPress(find.text('对方消息'));
      await tester.pump(const Duration(milliseconds: 600));
      // 对方消息的 GestureDetector.onRecall 为 null，不触发回调
      expect(recalled, isNull);
    });
  });

  group('历史加载回调', () {
    testWidgets('hasMoreHistory=false 时不主动调用 onLoadHistory', (tester) async {
      int calls = 0;
      await tester.pumpWidget(wrap(ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: [msg('alice', 'first', 'm1')],
        username: 'alice',
        inputCtrl: TextEditingController(),
        canSend: false,
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {
          calls++;
        },
        hasMoreHistory: (_) => false,
      )));
      // 构建后等待一帧，scroll listener 不应触发加载
      await tester.pump();
      expect(calls, 0);
    });
  });
}