// 开源 README 截图生成（离线渲染 · flutter test，无需桌面窗口）
//
// 运行（显式 opt-in，需要三项前置）：
//   SHOTS_USER=<截图账号> SHOTS_PASS=<截图密码> SHOTS_OUT=../docs/screenshots \
//     flutter test test/screenshots/generate_shots_test.dart
//
// 前置与产物：
//   ① 凭据经环境变量传入（SHOTS_USER/SHOTS_PASS）——截图账号与密码
//      **不写入本 tracked 测试文件**；缺失即跳过（不尝试任何默认口令）；
//   ② 本地截图服务器（127.0.0.1:8090，账号与消息数据就绪——blue/group_1
//      会话必须有消息，空数据会在数据断言处失败）；
//   ③ 输出目录 = SHOTS_OUT（相对路径基于 flutter test 的 CWD=包根解析，
//      例：SHOTS_OUT=../docs/screenshots → 仓库根 docs/screenshots）。
//      **未设置时只写 ../build/screenshots_staging（ignored 构建目录），
//      绝不触碰 tracked 的 docs/screenshots**；解析后的绝对路径会打印，
//      写往 tracked 文档目录时额外打印"请人工审阅"提醒。
//
// 产物校验（两层，失败即删文件并让测试红——占位块/空帧不得流出）：
//   逐张：尺寸 1920x1200 + 文件 >50KB + 像素采样非纯色；
//   出库：01_login/02_main/03_group 三张固定文件必须齐备 + 三张字节互异
//   + 多余暂存文件清理。**出库在 testWidgets 回调内、三张全部生成之后
//   执行（finalizeShots）——勿移回顶层**（顶层同步代码跑在测试回调
//   之前：干净 staging 下永远空跑、残留 staging 下会把旧图拷出，
//   2026-11-01 复审实锤的时序缺陷）。
//
// 渲染走 AutomatedTestWidgetsFlutterBinding（确定性），网络数据经
// runAsync 真实异步等待；测试环境的 Ahem 占位字体用系统中文字体字节
// 覆盖注册。
//
// opt8 批次内的 test-infra 修复史（非 opt8 功能）：原"主目录/""项目根
// 目录/"占位符字面量致 PathNotFoundException 全量红（方案 A 修复）；后
// 经真机复核发现"开发服务器在跑 + 仓库自带 users.db 恰有截图账号"时
// 探测仍可能通过、半成品帧直接写坏 tracked 的 docs/screenshots（02/03
// 曾沦为 12,256 字节同 hash 占位块）——故收敛为本文件的凭据环境变量 +
// staging 逐张校验 + 固定三张出库 + 显式 opt-in 输出多层防线。
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

/// 生成暂存区：ignored 构建目录内（出库校验通过前所有帧只落这里，
/// tracked 的 docs 永远不接收未校验文件）。每次生成前整体清空重建。
const String _stageDir = '../build/screenshots_staging';

/// 出库的固定三张（多余暂存文件出库前清理）
const List<String> _requiredShots = [
  '01_login.png',
  '02_main.png',
  '03_group.png',
];

/// 显式 opt-in 的最终输出目录（SHOTS_OUT；未设置 = 只留暂存区）
String? get _finalOutDirRaw {
  final v = (Platform.environment['SHOTS_OUT'] ?? '').trim();
  return v.isEmpty ? null : v;
}

/// 输出绝对路径是否为 tracked 文档目录（基于解析后的绝对路径判断——
/// 勿用原始字符串 contains，避免包内 docs 被误报/漏报）
bool _writingDocs(String outAbs) =>
    outAbs.contains('${Platform.pathSeparator}docs'
        '${Platform.pathSeparator}screenshots');

/// Flutter SDK 内 MaterialIcons 字体：FLUTTER_ROOT 由 flutter 工具注入，
/// HOME/flutter 兜底（勿写死占位符字面量）
String get _materialIconsPath =>
    '${Platform.environment['FLUTTER_ROOT'] ??
        '${Platform.environment['HOME']}/flutter'}/bin/cache/artifacts/'
    'material_fonts/MaterialIcons-Regular.otf';

/// 单张产物最小合理体积：README 截图为 1920x1200 真实界面渲染，
/// 纯色占位块经验值 ~12KB；50KB 以下必属异常
const int _minShotBytes = 50 * 1024;

Future<void> _shoot(String name, WidgetTester tester) async {
  await tester.runAsync(() async {
    final boundary = _shotKey.currentContext!.findRenderObject()!
        as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$_stageDir/$name.png');
    await file.writeAsBytes(data!.buffer.asUint8List());
    await validateShot(file, name);
    // ignore: avoid_print
    print('[shots] $name -> ${await file.length()} bytes（已过逐张校验，'
        '暂存于 $_stageDir）');
  });
}

/// 单张产物校验：尺寸 + 体积 + 像素采样非纯色。失败 → 删除文件并抛错
/// （测试红，占位块/空帧不得流出——曾写坏 tracked 文档的教训）。
Future<void> validateShot(File file, String name) async {
  if (!file.existsSync()) {
    throw StateError('[shots] 产物不存在：$name');
  }
  final bytes = await file.readAsBytes();
  if (bytes.lengthInBytes < _minShotBytes) {
    await _rejectShot(file, '$name 体积 ${bytes.lengthInBytes}B < 50KB'
        '（占位块特征——写坏文档的 12,256B 同源）');
  }
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final w = frame.image.width;
  final h = frame.image.height;
  frame.image.dispose();
  codec.dispose();
  if (w != 1920 || h != 1200) {
    await _rejectShot(file, '$name 尺寸 ${w}x$h ≠ 1920x1200');
  }
  if (await isSolidColor(file)) {
    await _rejectShot(file, '$name 像素采样为纯色（占位块特征）');
  }
}

/// 像素采样：等距网格取点，全部同色即判定纯色占位块
Future<bool> isSolidColor(File file) async {
  final bytes = await file.readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  var first = 0;
  var allSame = true;
  if (data != null) {
    final pixels = data.buffer.asUint8List();
    const step = 64; // 网格采样步长（像素）
    var sampled = 0;
    for (var y = 0; y < image.height && allSame; y += step) {
      for (var x = 0; x < image.width; x += step) {
        final offset = (y * image.width + x) * 4;
        final pixel = (pixels[offset] << 24) |
            (pixels[offset + 1] << 16) |
            (pixels[offset + 2] << 8) |
            pixels[offset + 3];
        if (sampled == 0) {
          first = pixel;
        } else if (pixel != first) {
          allSame = false;
          break;
        }
        sampled++;
      }
    }
    if (sampled <= 1) allSame = false; // 采样异常时不误判
  }
  image.dispose();
  codec.dispose();
  return allSame;
}

Future<void> _rejectShot(File file, String reason) async {
  try {
    if (file.existsSync()) file.deleteSync();
  } catch (_) {}
  throw StateError('[shots] 产物校验失败：$reason（文件已删除，不流出）');
}

bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 出库（可测试；在 testWidgets 回调内、三张全部生成后调用）：
/// ① 固定三张必须齐备（缺一即抛，勿以"≥3 张"放行）；② 逐张复检；
/// ③ 多余暂存文件清理；④ 三张字节互异（同屏渲染异常不出库）；
/// ⑤ 按 finalOutDir 决定拷贝目标（null = 仅暂存区；写往 tracked docs
/// 时打印人工审阅提醒）。
Future<void> finalizeShots({
  required Directory stageDir,
  String? finalOutDir,
  void Function(String message) log = print,
}) async {
  final files = <File>[];
  for (final name in _requiredShots) {
    final f = File('${stageDir.path}${Platform.pathSeparator}$name');
    if (!f.existsSync()) {
      throw StateError('[shots] 缺少 $name——三张固定产物必须齐备才出库'
          '（缺什么补什么，勿以"≥3 张"放行）');
    }
    await validateShot(f, name);
    files.add(f);
  }
  // 多余暂存文件清理（staging 只应有固定三张）
  for (final entity in stageDir.listSync()) {
    if (entity is File &&
        !_requiredShots.contains(entity.uri.pathSegments.last)) {
      try {
        entity.deleteSync();
        log('[shots] 清理多余暂存文件 ${entity.path}');
      } catch (_) {}
    }
  }
  for (var i = 0; i < files.length; i++) {
    for (var j = i + 1; j < files.length; j++) {
      final a = files[i].readAsBytesSync();
      final b = files[j].readAsBytesSync();
      if (bytesEqual(a, b)) {
        throw StateError('[shots] ${files[i].uri.pathSegments.last} 与 '
            '${files[j].uri.pathSegments.last} 字节雷同（同屏渲染异常），'
            '不出库');
      }
    }
  }
  final out = (finalOutDir ?? '').trim();
  if (out.isEmpty) {
    log('[shots] 未设置 SHOTS_OUT——产物保留在暂存区 ${stageDir.path}'
        '（ignored，不触碰 tracked 文档）');
    return;
  }
  final outAbs = Directory(out).absolute.path;
  final docs = _writingDocs(outAbs);
  Directory(outAbs).createSync(recursive: true);
  for (final f in files) {
    f.copySync('$outAbs${Platform.pathSeparator}${f.uri.pathSegments.last}');
  }
  log('[shots] 已写入 $outAbs（共 ${files.length} 张）——'
      '${docs ? "⚠ 这是 tracked 文档目录，请人工审阅后再提交" : "请人工审阅"}');
}

/// 出库封装（**仅在 testWidgets 回调内调用**）：finalizeShots 内部的
/// validateShot 有图像解码与异步文件 IO——必须在 runAsync 真实异步上下文
/// 执行（fake async 区裸 await 会不完成/挂起；单测均包 runAsync，真实
/// 生成路径曾漏包，复审实锤）；随断开截图服务器连接一并收尾。
Future<void> _finalizeInsideTest(WidgetTester tester, SocketService? svc) async {
  await tester.runAsync(() async {
    try {
      svc?.disconnect();
    } catch (_) {}
    await finalizeShots(
      stageDir: Directory(_stageDir),
      finalOutDir: _finalOutDirRaw,
    );
  });
}

Future<void> main() async {
  // 前置一：截图凭据经环境变量传入（勿把账号口令写进 tracked 测试）；
  // 缺失即跳过——全量 flutter test 永不尝试任何默认口令
  final shotsUser = (Platform.environment['SHOTS_USER'] ?? '').trim();
  final shotsPass = Platform.environment['SHOTS_PASS'] ?? '';
  if (shotsUser.isEmpty || shotsPass.isEmpty) {
    // ignore: avoid_print
    print('[shots] 未提供 SHOTS_USER/SHOTS_PASS（截图账号凭据），跳过截图'
        '生成——全量 flutter test 不依赖截图环境；生成方法见文件头注释');
    return;
  }
  // 前置二：截图服务器 TCP 可达
  try {
    final probe = await Socket.connect('127.0.0.1', 8090,
        timeout: const Duration(seconds: 1));
    probe.destroy();
  } catch (_) {
    // ignore: avoid_print
    print('[shots] 截图服务器 127.0.0.1:8090 未运行，跳过截图生成');
    return;
  }
  // 前置三：凭据可登录（区分"数据就绪的截图服务器"与普通开发服务器；
  // 探测连接 try/finally 必断开，不留测试进程遗留 socket）
  var loginOk = false;
  SocketService? probeSvc;
  try {
    probeSvc = SocketService();
    if (await probeSvc.connect()) {
      loginOk = await probeSvc.login(shotsUser, shotsPass) == null;
    }
  } catch (_) {
    loginOk = false;
  } finally {
    try {
      probeSvc?.disconnect();
    } catch (_) {}
  }
  if (!loginOk) {
    // ignore: avoid_print
    print('[shots] 截图账号登录失败（服务器无该账号或口令不符），跳过截图'
        '生成');
    return;
  }
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
    switch (call.method) {
      case 'read':
      case 'readAll':
        return null;
      case 'containsKey':
        return false;
    }
    return null;
  });
  setUpAll(() async {
    // 覆盖注册测试默认字体 Ahem → 真实中文字体（golden 社区通行做法）
    final fontFile = File('/usr/share/fonts/wps-office/simhei.ttf');
    final emojiFile = File('assets/fonts/NotoColorEmoji.ttf');
    final loader = FontLoader('Microsoft YaHei UI')
      ..addFont(Future.value(ByteData.view(
          fontFile.readAsBytesSync().buffer)));
    await loader.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.view(
          File(_materialIconsPath).readAsBytesSync().buffer)));
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
    // staging 清空重建（勿复用上一次运行的残留文件——出库会把旧图带进
    // SHOTS_OUT 重新写坏文档的教训）
    final stage = Directory(_stageDir);
    if (stage.existsSync()) {
      stage.deleteSync(recursive: true);
    }
    stage.createSync(recursive: true);
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
      expect(await svc!.login(shotsUser, shotsPass), isNull,
          reason: '登录 $shotsUser');
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
    // 数据断言：空页面会被出库校验拒绝，这里提前把"截图数据环境不完整"
    // 显式暴露（复审要求——防空页面被当有效图）
    expect(msgs, isNotEmpty, reason: 'blue 会话无消息——截图数据环境不完整，'
        '请先在截图服务器上为该会话补消息数据');
    expect(msgs.last.displayText, isNotEmpty, reason: '消息文本不得为空');
    // ignore: avoid_print
    print('[shots] blue msgs=${msgs.length} last=${msgs.last.displayText}');
    await _shoot('02_main', tester);

    // ── 场景 3：群聊 ──
    AppState.instance.selectChat('group_1');
    await tester.pump();
    await tester.runAsync(() => Future.delayed(const Duration(seconds: 2)));
    await tester.pump(const Duration(milliseconds: 400));
    final groupMsgs = AppState.instance.getMessages('group_1');
    expect(groupMsgs, isNotEmpty, reason: 'group_1 无消息——截图数据环境'
        '不完整，请先补群消息数据');
    await _shoot('03_group', tester);

    // ── 出库：必须在回调内、三张全部生成之后，经 _finalizeInsideTest
    //（runAsync 真实异步上下文）执行——勿移回顶层（顶层同步代码跑在
    // 测试回调之前：干净 staging 永远空跑、残留 staging 会把旧图拷进
    // SHOTS_OUT 写坏文档），也勿裸 await finalizeShots（fake async 区
    // 图像解码/异步 IO 不完成，复审实锤）──
    await _finalizeInsideTest(tester, svc);
  });
}
