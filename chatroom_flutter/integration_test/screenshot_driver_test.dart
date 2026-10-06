// 开源 README 截图驱动（本地 127.0.0.1:8090 截图专用服务器）
//
// 运行：cd chatroom_flutter && flutter test integration_test/screenshot_driver_test.dart -d linux
// 产物：docs/screenshots/*.png（1920x1200）
//
// 借鉴 group_call_device_test 的服务方法登录路径（绕过 GUI 文本注入），
// 场景渲染真实 LoginScreen / ChatScreen，RepaintBoundary 高保真出图。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:chatroom_flutter/config.dart';
import 'package:chatroom_flutter/screens/chat_screen.dart';
import 'package:chatroom_flutter/screens/login_screen.dart';
import 'package:chatroom_flutter/services/socket_service.dart';
import 'package:chatroom_flutter/services/state_manager.dart';

final GlobalKey _shotKey = GlobalKey();
const String _outDir = '项目根目录/docs/screenshots';

Future<void> _shoot(String name) async {
  final boundary = _shotKey.currentContext!.findRenderObject()!
      as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 1.0);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('$_outDir/$name.png');
  await file.writeAsBytes(data!.buffer.asUint8List());
  // ignore: avoid_print
  print('[shots] $name -> ${await file.length()} bytes');
}

Future<void> _waitUntil(bool Function() cond, WidgetTester tester,
    {Duration timeout = const Duration(seconds: 15)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (cond()) return;
    await tester.pump(const Duration(milliseconds: 200));
  }
  fail('waitUntil 超时');
}

Future<bool> _waitUntilSoft(bool Function() cond, WidgetTester tester,
    {Duration timeout = const Duration(seconds: 15)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (cond()) return true;
    await tester.pump(const Duration(milliseconds: 200));
  }
  return false;
}

Future<void> main() async {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  AppConfig.serverHost = '127.0.0.1';
  AppConfig.serverPort = 8090;
  Directory(_outDir).createSync(recursive: true);

  testWidgets('README 截图采集', (tester) async {
    tester.view.physicalSize = const Size(1920, 1200);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = FakeViewPadding.zero;
    addTearDown(tester.view.reset);

    // ── 场景 1：登录页（宽屏布局，含品牌区与标语）──
    await tester.pumpWidget(RepaintBoundary(
      key: _shotKey,
      child: MaterialApp(
        title: 'Rosub',
        debugShowCheckedModeBanner: false,
        home: const LoginScreen(),
      ),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await _shoot('01_login');

    // ── 登录（服务方法路径，绕过 GUI 文本注入）──
    final svc = SocketService();
    AppState.instance.setLoggedOut();
    expect(await svc.connect(), isTrue, reason: '连接 127.0.0.1:8090');
    expect(await svc.login('shino', 'Shot@2026'), isNull, reason: '登录 shino');

    // ── 场景 2：主界面 · 选中私聊（宽屏双栏 + 消息气泡）──
    await tester.pumpWidget(RepaintBoundary(
      key: _shotKey,
      child: MaterialApp(
        title: 'Rosub',
        debugShowCheckedModeBanner: false,
        home: ChatScreen(socketService: svc),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await _waitUntil(
        () => find.textContaining('blue').evaluate().isNotEmpty, tester,
        timeout: const Duration(seconds: 8));

    // ── 场景 2：主界面 · 选中私聊（宽屏双栏 + 消息气泡）──
    // 直接走 AppState 公开 API 选中会话（tap 命中受 LiveViewBinding 影响）
    AppState.instance.selectChat('blue');
    await tester.pump(const Duration(milliseconds: 400));
    await _waitUntil(
        () => find.textContaining('打球').evaluate().isNotEmpty, tester);
    await tester.pumpAndSettle(const Duration(milliseconds: 800));
    await _shoot('02_main');

    // ── 场景 3：群聊会话 ──
    AppState.instance.selectChat('group_1');
    await tester.pump(const Duration(milliseconds: 400));
    await _waitUntil(
        () => find.textContaining('组队').evaluate().isNotEmpty, tester);
    await tester.pumpAndSettle(const Duration(milliseconds: 800));
    await _shoot('03_group');
  });
}
