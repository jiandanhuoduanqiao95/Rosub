// ============================================================
// chat_screen.dart 退出登录回归测试（阶段 H3 —— 记住我语义）
// ============================================================
// 回归缺陷：点击"退出"后登录页读取残留 session 立即自动登录，把用户拉回
// 聊天页（无法退出）。自动登录功能已移除（2026-08-10），本文件锁定
// 退出登录的"忘记我"语义：
//   - 退出登录 → SessionStore.clear()（session 键全部清除）
//   - 退出后回到登录页 → 字段为空（session 已清，不再回填）
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/screens/chat_screen.dart';
import 'package:chatroom_flutter/screens/login_screen.dart';
import 'package:chatroom_flutter/services/socket_service.dart';
import 'package:chatroom_flutter/services/state_manager.dart';
import 'package:chatroom_flutter/widgets/adaptive_text_field.dart';

class MockSocketService extends Mock implements SocketService {}

AppState get state => AppState.instance;

void resetState() {
  state
    ..setLoggedOut()
    ..setConnectionStatus(ConnectionStatus.disconnected);
}

MockSocketService buildService() {
  final s = MockSocketService();
  when(() => s.disconnect()).thenAnswer((_) {});
  return s;
}

Future<void> pumpChat(WidgetTester tester, MockSocketService socket) async {
  await tester.pumpWidget(MaterialApp(
    home: ChatScreen(socketService: socket),
    routes: {'/login': (_) => const LoginScreen()},
  ));
  await tester.pump();
}

void main() {
  setUp(() {
    resetState();
    // 阶段 L2：SessionStore.clear() 先删钥匙串再清旧明文，注入内存 mock
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('退出登录清除 session（H3 记住我语义）', () {
    testWidgets('点击退出 → disconnect + session 全部清除', (tester) async {
      SharedPreferences.setMockInitialValues({
        'session_username': 'alice',
        'session_password': 'password123',
        'session_admin_secret': 'sec',
      });
      final socket = buildService();
      state.setLoggedIn('alice', false);
      await pumpChat(tester, socket);

      await tester.tap(find.byTooltip('退出'));
      await tester.pumpAndSettle();

      verify(() => socket.disconnect()).called(1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('session_username'), isNull);
      expect(prefs.getString('session_password'), isNull);
      expect(prefs.getString('session_admin_secret'), isNull);
    });

    testWidgets('退出后登录页无回填（session 已清除）', (tester) async {
      SharedPreferences.setMockInitialValues({
        'session_username': 'alice',
        'session_password': 'password123',
      });
      final socket = buildService();
      state.setLoggedIn('alice', false);
      await pumpChat(tester, socket);

      await tester.tap(find.byTooltip('退出'));
      await tester.pumpAndSettle();

      // 已回到登录页，session 已清除 → 字段为空
      expect(find.text('登录'), findsWidgets);
      expect(find.textContaining('自动登录'), findsNothing);
      final usernameField = tester
          .widget<AdaptiveTextField>(find.byKey(const ValueKey('username_field')));
      expect(usernameField.controller.text, '');
    });

    testWidgets('重连横幅的"退出"同样清除 session', (tester) async {
      SharedPreferences.setMockInitialValues({
        'session_username': 'alice',
        'session_password': 'password123',
      });
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setReconnecting();
      await pumpChat(tester, socket);

      await tester.tap(find.text('退出'));
      await tester.pumpAndSettle();

      verify(() => socket.disconnect()).called(1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('session_username'), isNull);
    });
  });
}
