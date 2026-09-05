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
import 'package:chatroom_flutter/widgets/raw_text_field.dart';

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

  group('N3/R-P5 —— 图片粘贴 → 自动进入标注编辑器（编辑后发送/直接发送）', () {
    testWidgets('粘贴图片 → 自动进入标注编辑器（不再显示预览条）', (tester) async {
      final socket = MockSocketService();
      when(() => socket.sendFileBytes(any(), any(), any()))
          .thenAnswer((_) async => true);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');

      await pumpScreen(tester, socket);

      final input =
          tester.widget<RawTextField>(find.byType(RawTextField).first);
      input.onImagePasted?.call(pngBytes);
      await tester.pumpAndSettle();

      expect(find.text('pasted_image.png'), findsNothing, reason: 'R-P5：预览条移除');
      expect(find.byKey(const ValueKey('annotation_canvas')), findsOneWidget,
          reason: '自动进入标注编辑器');
    });

    testWidgets('不编辑直接"发送" → sendFileBytes（直通原字节）', (tester) async {
      final socket = MockSocketService();
      when(() => socket.sendFileBytes(any(), any(), any()))
          .thenAnswer((_) async => true);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');

      await pumpScreen(tester, socket);

      final input =
          tester.widget<RawTextField>(find.byType(RawTextField).first);
      input.onImagePasted?.call(pngBytes);
      await tester.pumpAndSettle();
      await tester.tap(find.text('发送'));
      await tester.pumpAndSettle();

      verify(() => socket.sendFileBytes('bob', pngBytes, 'pasted_image.png'))
          .called(1);
    });

    testWidgets('"取消" → 不发送', (tester) async {
      final socket = MockSocketService();
      when(() => socket.sendFileBytes(any(), any(), any()))
          .thenAnswer((_) async => true);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');

      await pumpScreen(tester, socket);

      final input =
          tester.widget<RawTextField>(find.byType(RawTextField).first);
      input.onImagePasted?.call(pngBytes);
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      verifyNever(() => socket.sendFileBytes(any(), any(), any()));
    });

    testWidgets('系统会话（服务器）粘贴不打开编辑器（只读会话不注入回调）', (tester) async {
      final socket = MockSocketService();
      state.setLoggedIn('alice', false);
      state.selectChat('服务器');

      await pumpScreen(tester, socket);

      expect(find.byType(RawTextField), findsNothing,
          reason: '只读会话无输入框（无粘贴入口）');
      expect(find.byKey(const ValueKey('annotation_canvas')), findsNothing,
          reason: '不打开编辑器');
    });

    testWidgets('N3 回归（用户实测崩溃）：应用主题下编辑器不抛布局异常', (tester) async {
      final socket = MockSocketService();
      when(() => socket.sendFileBytes(any(), any(), any()))
          .thenAnswer((_) async => true);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');

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
      await tester.pumpAndSettle();

      final input =
          tester.widget<RawTextField>(find.byType(RawTextField).first);
      input.onImagePasted?.call(pngBytes);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull, reason: '应用主题下编辑器不抛布局异常');
      expect(find.byKey(const ValueKey('annotation_canvas')), findsOneWidget);
    });
  });
}
