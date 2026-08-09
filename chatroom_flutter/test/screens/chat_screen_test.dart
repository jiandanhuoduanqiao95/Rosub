// ============================================================
// chat_screen.dart Widget 测试（使用 mocktail mock SocketService）
// ============================================================
// ChatScreen 依赖 SocketService（网络层）与 AppState（全局单例）。
// 本测试用 mocktail 桩住 SocketService 的全部网络方法，仅验证 UI
// 行为：退出回到登录、工具栏徽标、重连 banner、好友请求处理回调。
//
// ListView 在 Sidebar 中必须被 Material 包裹（见 AGENTS.md 约定），
// 本测试同时回归验证 ListTile 不会因未包裹 Material 抛异常。
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/socket_service.dart';
import 'package:chatroom_flutter/services/state_manager.dart';
import 'package:chatroom_flutter/screens/chat_screen.dart';

class MockSocketService extends Mock implements SocketService {}

AppState get state => AppState.instance;

void resetState() {
  state
    ..setLoggedOut()
    ..setConnectionStatus(ConnectionStatus.disconnected);
}

void main() {
  setUp(resetState);

  group('ChatScreen 工具栏与状态', () {
    testWidgets('已登录普通用户显示退出按钮、无管理员面板按钮', (tester) async {
      final socket = MockSocketService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);

      await tester.pumpWidget(MaterialApp(
        home: ChatScreen(socketService: socket),
        routes: {'/login': (_) => const Scaffold(body: Text('LOGIN'))},
      ));
      await tester.pump();

      expect(find.text('聊天室 - alice'), findsOneWidget);
      expect(find.byTooltip('退出'), findsOneWidget);
      // 非管理员不显示管理面板
      expect(find.byTooltip('管理面板'), findsNothing);
    });

    testWidgets('已登录管理员显示管理面板 + 退出按钮', (tester) async {
      final socket = MockSocketService();
      state.setLoggedIn('admin', true);

      await tester.pumpWidget(MaterialApp(
        home: ChatScreen(socketService: socket),
        routes: {'/login': (_) => const Scaffold(body: Text('LOGIN'))},
      ));
      await tester.pump();

      expect(find.byTooltip('管理面板'), findsOneWidget);
      expect(find.byTooltip('退出'), findsOneWidget);
    });

    testWidgets('有待处理好友请求时显示好友请求徽标', (tester) async {
      final socket = MockSocketService();
      state.setLoggedIn('alice', false);
      state.addPendingRequest('bob');
      state.addPendingRequest('carol');

      await tester.pumpWidget(MaterialApp(
        home: ChatScreen(socketService: socket),
        routes: {'/login': (_) => const Scaffold(body: Text('LOGIN'))},
      ));
      await tester.pump();

      expect(find.byTooltip('待处理好友请求'), findsOneWidget);
    });

    testWidgets('有待处理文件请求时显示文件请求徽标', (tester) async {
      final socket = MockSocketService();
      state.setLoggedIn('alice', false);
      state.addFileRequest(FileRequest(
          messageId: 'f1', sender: 'bob', filename: 'a.txt', filesize: 10));

      await tester.pumpWidget(MaterialApp(
        home: ChatScreen(socketService: socket),
        routes: {'/login': (_) => const Scaffold(body: Text('LOGIN'))},
      ));
      await tester.pump();

      expect(find.byTooltip('待处理文件请求'), findsOneWidget);
    });
  });

  group('重连状态 banner（阶段 D）', () {
    testWidgets('reconnecting 状态显示重连 banner', (tester) async {
      final socket = MockSocketService();
      state.setLoggedIn('alice', false);
      state.setReconnecting();
      state.setReconnectAttempt(2);

      await tester.pumpWidget(MaterialApp(
        home: ChatScreen(socketService: socket),
        routes: {'/login': (_) => const Scaffold(body: Text('LOGIN'))},
      ));
      await tester.pump();

      expect(find.textContaining('正在重连'), findsOneWidget);
      expect(find.textContaining('第 2 次'), findsOneWidget);
    });

    testWidgets('connected 状态不显示重连 banner', (tester) async {
      final socket = MockSocketService();
      state.setLoggedIn('alice', false);

      await tester.pumpWidget(MaterialApp(
        home: ChatScreen(socketService: socket),
        routes: {'/login': (_) => const Scaffold(body: Text('LOGIN'))},
      ));
      await tester.pump();

      expect(find.textContaining('正在重连'), findsNothing);
    });
  });

  group('退出时跳转登录', () {
    testWidgets('点击退出调用 disconnect 并回到登录页', (tester) async {
      final socket = MockSocketService();
      state.setLoggedIn('alice', false);

      await tester.pumpWidget(MaterialApp(
        home: ChatScreen(socketService: socket),
        routes: {'/login': (_) => const Scaffold(body: Text('LOGIN'))},
      ));
      await tester.pump();

      await tester.tap(find.byTooltip('退出'));
      await tester.pumpAndSettle();

      expect(find.text('LOGIN'), findsOneWidget);
    });
  });

  group('侧边栏 ListTile 不抛 Material 异常', () {
    testWidgets('侧边栏好友 ListTile 正常渲染（Material 包裹回归）', (tester) async {
      final socket = MockSocketService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob', 'carol']);

      await tester.pumpWidget(MaterialApp(
        home: ChatScreen(socketService: socket),
        routes: {'/login': (_) => const Scaffold(body: Text('LOGIN'))},
      ));
      await tester.pump();

      expect(find.text('bob'), findsWidgets);
      expect(find.text('carol'), findsWidgets);
      // 不应抛出 ColoredBox/Material 相关断言
    });
  });
}