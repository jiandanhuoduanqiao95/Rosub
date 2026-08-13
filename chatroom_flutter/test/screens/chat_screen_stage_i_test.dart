// ============================================================
// chat_screen.dart 阶段 I1 —— 失败重试 + 断线可输入接线（已实现，全部转绿）
// ============================================================
// 覆盖 P0-1（《软件开发文档4.1.0.md》§13.2）：
//   - ChatView 的 onRetrySend 由 ChatScreen 绑定到
//     socketService.retryPendingMessage(messageId)
//   - 失败气泡在真实 ChatScreen 中渲染并响应点击
//   - 发送中气泡在真实 ChatScreen 中渲染
//   - 重连（断线）期间输入栏保持可用（消息走本地队列，重连自动补发）；
//     系统消息会话在任何状态下仍为只读
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/screens/chat_screen.dart';
import 'package:chatroom_flutter/services/socket_service.dart';
import 'package:chatroom_flutter/services/state_manager.dart';
import 'package:chatroom_flutter/widgets/raw_text_field.dart';

class MockSocketService extends Mock implements SocketService {}

AppState get state => AppState.instance;

void resetState() {
  state
    ..setLoggedOut()
    ..setConnectionStatus(ConnectionStatus.disconnected);
}

MockSocketService buildService() {
  final s = MockSocketService();
  when(() => s.sendChat(any(), any())).thenAnswer((_) async => true);
  when(() => s.sendGroupChat(any(), any())).thenAnswer((_) async => true);
  when(() => s.retryPendingMessage(any())).thenAnswer((_) async => false);
  when(() => s.fetchHistory(
      to: any(named: 'to'),
      groupId: any(named: 'groupId'),
      beforeMessageId: any(named: 'beforeMessageId'),
      limit: any(named: 'limit'))).thenAnswer((_) async {});
  when(() => s.adminCommand(any())).thenAnswer((_) async {});
  return s;
}

Future<void> pumpScreen(WidgetTester tester, MockSocketService socket) async {
  await tester.pumpWidget(MaterialApp(
    home: ChatScreen(socketService: socket),
    routes: {'/login': (_) => const Scaffold(body: Text('LOGIN'))},
  ));
  await tester.pump();
}

void main() {
  setUp(resetState);

  group('I1 —— 失败重试接线', () {
    testWidgets('点击失败气泡 → socketService.retryPendingMessage(messageId)',
        (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.addMessage(
        'bob',
        ChatMessage(
          sender: 'alice',
          content: '发送失败的内容',
          messageId: 'm-fail-1',
          status: 'failed',
        ),
      );
      state.selectChat('bob');
      await pumpScreen(tester, socket);

      expect(find.textContaining('发送失败'), findsOneWidget);
      await tester.tap(find.text('发送失败的内容'));
      verify(() => socket.retryPendingMessage('m-fail-1')).called(1);
    });

    testWidgets('已发送消息点击不触发重试', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.addMessage(
        'bob',
        ChatMessage(
          sender: 'alice',
          content: '正常消息',
          messageId: 'm-ok-1',
          status: 'sent',
        ),
      );
      state.selectChat('bob');
      await pumpScreen(tester, socket);

      await tester.tap(find.text('正常消息'));
      verifyNever(() => socket.retryPendingMessage(any()));
    });

    testWidgets('发送中气泡在聊天窗口渲染', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.addMessage(
        'bob',
        ChatMessage(
          sender: 'alice',
          content: '补发中的内容',
          messageId: 'm-sending-1',
          status: 'sending',
        ),
      );
      state.selectChat('bob');
      await pumpScreen(tester, socket);

      expect(find.text('补发中的内容'), findsOneWidget);
      expect(find.textContaining('发送中'), findsOneWidget);
    });

    testWidgets('重连中（断线）输入栏可用：可输入并触发发送（本地队列）', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');
      state.setReconnecting(); // 断线状态：输入栏不得被只读栏封死
      await pumpScreen(tester, socket);

      // 输入栏可用（非"为只读会话"）
      expect(find.textContaining('为只读会话'), findsNothing);
      expect(find.byTooltip('发送'), findsOneWidget);
      expect(find.byTooltip('发送文件'), findsOneWidget);

      // 断线状态下输入并发送 → 走 socket 层（sendChat 断线入队路径）
      await tester.tap(find.byType(RawTextField));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.pump();
      await tester.tap(find.byTooltip('发送'));
      await tester.pump();

      verify(() => socket.sendChat('bob', 'hi')).called(1);
      await tester.pump(const Duration(seconds: 3)); // 冲刷 IME 遗留 Timer
    });

    testWidgets('系统消息会话在重连中仍为只读（回归）', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setReconnecting();
      state.addMessage(
        '服务器',
        ChatMessage(
          sender: '[系统公告]',
          content: '公告内容',
          messageId: 's1',
          type: 'system',
        ),
      );
      state.selectChat('服务器');
      await pumpScreen(tester, socket);

      expect(find.textContaining('为只读会话'), findsOneWidget);
      verifyNever(() => socket.sendChat(any(), any()));
    });
  });
}
