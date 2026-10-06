// 开源 README 截图生成（离线渲染 · flutter test，无需桌面窗口）
//
// 运行：cd chatroom_flutter && flutter test test/screenshots/generate_shots_test.dart
// 前提：本地截图服务器（127.0.0.1:8090，shino/blue 等账号与消息数据）
// 产物：docs/screenshots/*.png（1920x1200）
//
// 渲染走 AutomatedTestWidgetsFlutterBinding（确定性），网络数据经 runAsync
// 真实异步等待；测试环境的 Ahem 占位字体用系统中文字体字节覆盖注册，
// 保证截图文字正常显示。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/config.dart';
import 'package:chatroom_flutter/screens/chat_screen.dart';
import 'package:chatroom_flutter/screens/login_screen.dart';
import 'package:chatroom_flutter/services/socket_service.dart';
import 'package:chatroom_flutter/services/state_manager.dart';

final GlobalKey _shotKey = GlobalKey();
const String _outDir = '项目根目录/docs/screenshots';

Future<void> _shoot(String name, WidgetTester tester) async {
  await tester.runAsync(() async {
    final boundary = _shotKey.currentContext!.findRenderObject()!
        as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$_outDir/$name.png');
    await file.writeAsBytes(data!.buffer.asUint8List());
    // ignore: avoid_print
    print('[shots] $name -> ${await file.length()} bytes');
  });
}

Future<void> main() async {
  setUpAll(() async {
    // 覆盖注册测试默认字体 Ahem → 真实中文字体（golden 社区通行做法）
    final fontFile = File('/usr/share/fonts/wps-office/simhei.ttf');
    final emojiFile = File('assets/fonts/NotoColorEmoji.ttf');
    final loader = FontLoader('Microsoft YaHei UI')
      ..addFont(Future.value(ByteData.view(
          fontFile.readAsBytesSync().buffer)));
    await loader.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.view(File(
              '主目录/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')
          .readAsBytesSync().buffer)));
    await icons.load();
    final emojiBytes = emojiFile.readAsBytesSync();
    for (final family in const ['NotoColorEmoji', 'Noto Color Emoji']) {
      final l = FontLoader(family)
        ..addFont(Future.value(ByteData.view(emojiBytes.buffer)));
      await l.load();
    }
    final loader2 = FontLoader('NotoColorEmoji')
      ..addFont(Future.value(ByteData.view(
          emojiFile.readAsBytesSync().buffer)));
    await loader2.load();
    Directory(_outDir).createSync(recursive: true);
  });

  testWidgets('README 截图采集', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(1920, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    AppConfig.serverHost = '127.0.0.1';
    AppConfig.serverPort = 8090;

    Widget shotHost(Widget child) => RepaintBoundary(
          key: _shotKey,
          child: MaterialApp(
            title: 'Rosub',
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
                useMaterial3: true,
                colorSchemeSeed: Colors.indigo,
                fontFamily: 'Microsoft YaHei UI',),
            home: child,
          ),
        );

    // ── 场景 1：登录页 ──
    await tester.pumpWidget(shotHost(const LoginScreen()));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 600)));
    await tester.pump(const Duration(milliseconds: 400));
    await _shoot('01_login', tester);

    // ── 登录（真实服务器）──
    SocketService? svc;
    await tester.runAsync(() async {
      svc = SocketService();
      AppState.instance.setLoggedOut();
      expect(await svc!.connect(), isTrue, reason: '连接 127.0.0.1:8090');
      expect(await svc!.login('shino', 'Shot@2026'), isNull, reason: '登录 shino');
      await Future.delayed(const Duration(seconds: 2));
    });

    // ── 场景 2：主界面 · 选中私聊 ──
    await tester.pumpWidget(shotHost(ChatScreen(socketService: svc!)));
    await tester.pump();
    await tester.runAsync(() => Future.delayed(const Duration(seconds: 2)));
    await tester.pump();
    AppState.instance.selectChat('blue');
    await tester.pump();
    await tester.runAsync(() => Future.delayed(const Duration(seconds: 2)));
    await tester.pump(const Duration(milliseconds: 400));
    final msgs = AppState.instance.getMessages('blue');
    // ignore: avoid_print
    print('[shots] blue msgs=${msgs.length} last=${msgs.isNotEmpty ? msgs.last.displayText : 'NONE'}');
    await _shoot('02_main', tester);

    // ── 场景 3：群聊 ──
    AppState.instance.selectChat('group_1');
    await tester.pump();
    await tester.runAsync(() => Future.delayed(const Duration(seconds: 2)));
    await tester.pump(const Duration(milliseconds: 400));
    await _shoot('03_group', tester);

    await tester.runAsync(() async {
      svc!.disconnect();
    });
  });
}
