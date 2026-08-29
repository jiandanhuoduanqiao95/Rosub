// ============================================================
// chat_screen.dart 阶段 N —— N3 图片粘贴预览接线（TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 N：
//
//   N3（P2-4 图片粘贴直发）：剪贴板图片 → 输入框预览（AppState
//     pendingImagePreview）→ 发送（复用既有上传通道 sendFileBytes，
//     大文件走 M8 分流）/ 取消。
//
// 实现前：本文件引用尚未实现的 AppState 状态与 SocketService 方法，
// 编译失败或用例红，属 TDD 红。实现后：全部转绿。
// ===========================================================

import 'dart:typed_data';

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

final pngBytes = Uint8List.fromList(
    [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03]);

Future<void> pumpScreen(WidgetTester tester, MockSocketService socket) async {
  await tester.pumpWidget(MaterialApp(
    home: ChatScreen(socketService: socket),
    routes: {'/login': (_) => const Scaffold(body: Text('LOGIN'))},
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    // mocktail：Uint8List 参数使用 any() 需注册 fallback 值
    registerFallbackValue(Uint8List(0));
  });

  setUp(resetState);

  group('N3 —— 图片粘贴预览（pendingImagePreview）', () {
    testWidgets('有预览 → 输入栏上方显示预览条（文件名 + 发送图片/取消）', (tester) async {
      final socket = MockSocketService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');
      state.setPendingImagePreview(pngBytes);

      await pumpScreen(tester, socket);

      expect(find.text('pasted_image.png'), findsOneWidget,
          reason: '预览条显示图片文件名');
      expect(find.text('发送图片'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
    });

    testWidgets('点击"发送图片" → sendFileBytes(会话, 字节, 文件名) 并清除预览', (tester) async {
      final socket = MockSocketService();
      when(() => socket.sendFileBytes(any(), any(), any()))
          .thenAnswer((_) async => true);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');
      state.setPendingImagePreview(pngBytes);

      await pumpScreen(tester, socket);
      await tester.tap(find.text('发送图片'));
      await tester.pumpAndSettle();

      verify(() => socket.sendFileBytes('bob', pngBytes, 'pasted_image.png'))
          .called(1);
      expect(state.pendingImagePreview, isNull, reason: '发送后清除预览');
    });

    testWidgets('点击"取消" → 清除预览且不发送', (tester) async {
      final socket = MockSocketService();
      when(() => socket.sendFileBytes(any(), any(), any()))
          .thenAnswer((_) async => true);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');
      state.setPendingImagePreview(pngBytes);

      await pumpScreen(tester, socket);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      verifyNever(() => socket.sendFileBytes(any(), any(), any()));
      expect(state.pendingImagePreview, isNull);
    });

    testWidgets('无当前会话时"发送图片"不可用（不调用 sendFileBytes）', (tester) async {
      final socket = MockSocketService();
      when(() => socket.sendFileBytes(any(), any(), any()))
          .thenAnswer((_) async => true);
      state.setLoggedIn('alice', false);
      state.setPendingImagePreview(pngBytes);

      await pumpScreen(tester, socket);

      final sendBtn = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('发送图片'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(sendBtn.onPressed, isNull, reason: '未选会话时发送按钮禁用');
      expect(state.pendingImagePreview, isNotNull, reason: '预览保留');
    });

    testWidgets('系统会话（服务器）不显示图片预览条', (tester) async {
      final socket = MockSocketService();
      state.setLoggedIn('alice', false);
      state.selectChat('服务器');
      state.setPendingImagePreview(pngBytes);

      await pumpScreen(tester, socket);

      expect(find.text('pasted_image.png'), findsNothing,
          reason: '系统会话只读，无图片预览');
    });

    testWidgets('N3 回归（用户实测崩溃）：应用主题下预览条不抛布局异常', (tester) async {
      // 真实应用主题（main.dart _buildTheme）的 filledButtonTheme
      // minimumSize = Size.fromHeight(46)（宽度 infinity）——默认主题
      // 测试下不崩溃，应用主题下 FilledButton 在 Row 中拿到无界主轴
      // 约束产生 w=Infinity 抛异常。此处用同款主题复现并锁定修复。
      final socket = MockSocketService();
      when(() => socket.sendFileBytes(any(), any(), any()))
          .thenAnswer((_) async => true);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');
      state.setPendingImagePreview(pngBytes);

      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF2563EB), brightness: Brightness.light),
          useMaterial3: true,
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ),
        home: ChatScreen(socketService: socket),
        routes: {'/login': (_) => const Scaffold(body: Text('LOGIN'))},
      ));
      // 无异常即通过；预览条正常渲染
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull,
          reason: '应用主题（FilledButton minWidth=infinity）下预览条不得抛布局异常');
      expect(find.text('pasted_image.png'), findsOneWidget);
    });
  });
}
