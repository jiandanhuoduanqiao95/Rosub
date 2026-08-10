// ============================================================
// chat_screen.dart 消息搜索接线测试（阶段 H5，mocktail mock 网络层）
// ============================================================
// 契约（已实现）：
//   - 私聊会话搜索：ChatView 搜索输入 → Enter →
//     socket.searchHistory(keyword, to: 当前会话) 精确参数
//   - 群聊会话搜索：searchHistory(keyword, groupId: 群组ID)
//   - 系统会话（只读）不显示搜索入口
//   - 收到 search_response（经 state.setSearchResults 注入模拟）→
//     ChatScreen 进入搜索模式展示结果；点击返回 →
//     state.clearSearchResults 恢复普通消息列表
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/screens/chat_screen.dart';
import 'package:chatroom_flutter/services/socket_service.dart';
import 'package:chatroom_flutter/services/state_manager.dart';

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
  when(() => s.sendFile(any(), any(), any())).thenAnswer((_) async => true);
  when(() => s.searchHistory(any(),
      to: any(named: 'to'),
      groupId: any(named: 'groupId'),
      limit: any(named: 'limit'))).thenAnswer((_) async {});
  when(() => s.fetchHistory(
      to: any(named: 'to'),
      groupId: any(named: 'groupId'),
      beforeMessageId: any(named: 'beforeMessageId'),
      limit: any(named: 'limit'))).thenAnswer((_) async {});
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

  group('H5 搜索接线', () {
    testWidgets('私聊会话：搜索输入 → Enter → searchHistory(keyword, to)', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      await pumpScreen(tester, socket);

      await tester.tap(find.text('bob'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('搜索消息'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.byKey(const ValueKey('search_field')));
      await tester.pump();
      for (final ch in ['f', 'l', 'u', 't', 't', 'e', 'r']) {
        await tester.sendKeyEvent(switch (ch) {
          'f' => LogicalKeyboardKey.keyF,
          'l' => LogicalKeyboardKey.keyL,
          'u' => LogicalKeyboardKey.keyU,
          't' => LogicalKeyboardKey.keyT,
          'e' => LogicalKeyboardKey.keyE,
          'r' => LogicalKeyboardKey.keyR,
          _ => LogicalKeyboardKey.keyF,
        });
        await tester.pump();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      verify(() => socket.searchHistory('flutter',
          to: 'bob', groupId: null, limit: 50)).called(1);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('群聊会话：搜索 → searchHistory(keyword, groupId)', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setGroups([Group(id: 1, name: '开发组')]);
      await pumpScreen(tester, socket);

      await tester.tap(find.text('开发组 (ID:1)'));
      await tester.pumpAndSettle();

      // 群聊会话有搜索入口
      expect(find.byTooltip('搜索消息'), findsOneWidget);
      await tester.tap(find.byTooltip('搜索消息'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.byKey(const ValueKey('search_field')));
      await tester.pump();
      for (final ch in ['f', 'l', 'u', 't', 't', 'e', 'r']) {
        await tester.sendKeyEvent(switch (ch) {
          'f' => LogicalKeyboardKey.keyF,
          'l' => LogicalKeyboardKey.keyL,
          'u' => LogicalKeyboardKey.keyU,
          't' => LogicalKeyboardKey.keyT,
          'e' => LogicalKeyboardKey.keyE,
          'r' => LogicalKeyboardKey.keyR,
          _ => LogicalKeyboardKey.keyF,
        });
        await tester.pump();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      verify(() => socket.searchHistory('flutter',
          to: null, groupId: 1, limit: 50)).called(1);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('系统会话不显示搜索入口（只读会话）', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.addMessage('服务器',
          ChatMessage(sender: '服务器', content: '公告', messageId: 's1',
              type: 'system'));
      await pumpScreen(tester, socket);

      await tester.tap(find.text('系统消息'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('搜索消息'), findsNothing);
      verifyNever(() => socket.searchHistory(any(),
          to: any(named: 'to'),
          groupId: any(named: 'groupId'),
          limit: any(named: 'limit')));
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('搜索响应注入 → 进入搜索模式展示结果与关键字', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      await pumpScreen(tester, socket);

      await tester.tap(find.text('bob'));
      await tester.pumpAndSettle();

      // 模拟 search_response（真实响应由 SocketService._handleMessage 解析）
      state.setSearchResults('bob', [
        ChatMessage(sender: 'bob', content: 'flutter 教程', messageId: 's1',
            isHistory: true, status: 'delivered'),
      ], query: 'flutter');
      await tester.pump();

      expect(find.text('搜索：flutter'), findsOneWidget);
      expect(find.text('flutter 教程'), findsOneWidget);
      expect(find.byTooltip('发送'), findsNothing);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('搜索模式点击返回 → 退出搜索并恢复普通消息列表', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.addMessage('bob',
          ChatMessage(sender: 'bob', content: '普通消息', messageId: 'm1'));
      await pumpScreen(tester, socket);

      await tester.tap(find.text('bob'));
      await tester.pumpAndSettle();

      state.setSearchResults('bob', [
        ChatMessage(sender: 'bob', content: '搜索结果', messageId: 's1',
            isHistory: true, status: 'delivered'),
      ], query: 'flutter');
      await tester.pump();
      expect(find.text('搜索：flutter'), findsOneWidget);

      await tester.tap(find.byTooltip('退出搜索'));
      await tester.pump();

      expect(state.isSearchMode('bob'), isFalse);
      expect(find.text('普通消息'), findsOneWidget);
      expect(find.text('搜索结果'), findsNothing);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('搜索模式切换会话后恢复普通显示', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob', 'carol']);
      await pumpScreen(tester, socket);

      await tester.tap(find.text('bob'));
      await tester.pumpAndSettle();
      state.setSearchResults('bob', [
        ChatMessage(sender: 'bob', content: '结果', messageId: 's1',
            isHistory: true, status: 'delivered'),
      ], query: 'flutter');
      await tester.pump();
      expect(find.text('搜索：flutter'), findsOneWidget);

      await tester.tap(find.text('carol'));
      await tester.pumpAndSettle();

      expect(find.text('搜索：flutter'), findsNothing);
      expect(find.byTooltip('发送'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
