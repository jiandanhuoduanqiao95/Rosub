// ============================================================
// 平台能力 Windows 实现契约（阶段 Q2-3 —— TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 Q「Q2 Windows」要点
// 「拖拽/通知/打开文件/提示音按 Q0-3 平台实现」——Q0-3 在 Windows 端
// 留下三处占位（capabilities.dart 注释与 §13.9 Q0-3 行均明确 Q2 接入）：
//
//   1. 通知闪烁：DesktopNotificationStub → **Windows 任务栏闪烁真实现**
//      （win32 FlashWindowEx 链路；窗口重新聚焦清除——main.dart
//      FocusTracker → TaskbarNotifier.clearUrgency → notification 能力
//      分发语义不变，H1 开关/静音/免打扰上层规则不变）；
//   2. 提示音：DesktopSoundStub → **Windows 播放真实现**（PlaySound/
//      winmm 或 PowerShell SoundPlayer 等任一通道；生成式科技感和弦
//      WAV 语义不变；无播放后端静默降级惯例不变）；
//   3. 文件拖拽：DesktopFileDropStub → **desktop_drop 类方案真实现**
//      （§13.9 Q0-3 行"Windows/macOS=占位待 Q2/Q3 接 desktop_drop 类
//      方案"；拖入文件路径经既有 N3 发送通道——sendFile 依据大小自动
//      M8 分流、图片进标注编辑器）。
//   打开文件（DesktopFileLauncher，cmd /c start）Q0 已是真实现——锁定
//   不回退。
//
// 接线契约（关键）：ChatScreen 当前直接引用 FileDrop.instance（GTK
// channel，Linux 专属实现）——Windows 的拖拽实现将永远收不到注册。
// Q2 必须把 ChatScreen 的注册/注销改走 PlatformCapabilities.fileDrop
// 能力层（Linux 默认链 == FileDrop.instance，Q0-3 已锁 identical，
// Linux 行为不漂移；Windows 才能接到 Windows 实现）。
//
// 全部默认实现保持 Q0-3 安全降级惯例：DLL/子进程/通道缺失时静默
// （Linux 开发机上模拟 Windows 调用不崩），FFI lookup 失败 catch。
//
// 实现前：本文件"真实现"断言与接线扫描为断言红（无编译错误——引用
// 均为 Q0-3 已存在 API）；实现后全部转绿。
// ============================================================

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/platform/capabilities.dart';
import 'package:chatroom_flutter/screens/chat_screen.dart';
import 'package:chatroom_flutter/services/socket_service.dart';
import 'package:chatroom_flutter/services/state_manager.dart';
import 'package:chatroom_flutter/services/taskbar_notifier.dart';

class MockSocketService extends Mock implements SocketService {}

/// 记录 handler 注册链的 fake（验证 ChatScreen 接线经能力层）
class RecordingDrop implements FileDropCapability {
  int listenCount = 0;
  void Function(List<String> files)? handler;
  List<String>? lastDelivered;

  @override
  bool get isSupported => true;

  @override
  void ensureListening() => listenCount++;

  @override
  void setOnFilesDropped(void Function(List<String> files)? h) => handler = h;

  void deliver(List<String> files) {
    handler?.call(files);
    lastDelivered = files;
  }
}

class CountingNotification implements NotificationCapability {
  int flashCount = 0;
  int clearCount = 0;
  @override
  void flash() => flashCount++;
  @override
  void clearUrgency() => clearCount++;
}

class CountingSound implements SoundCapability {
  int playCount = 0;
  @override
  Future<void> playNotifySound() async => playCount++;

  @override
  Future<void> playCallRingtone() async {}

  @override
  Future<void> playHangupSound() async {}

  @override
  Future<void> stopCallRingtone() async {}
}

/// lib/platform/ 目录全部 dart 源码拼接（Windows 实现无论落在
/// capabilities.dart 还是按端拆分文件——如 windows_capabilities.dart——
/// 扫描均覆盖，适配 §13.9 分支纪律"按端一个文件的适配器实现"）
String platformSource() {
  final dir = Directory('lib/platform');
  final buf = StringBuffer();
  for (final e in dir.listSync(recursive: true)) {
    if (e is File && e.path.endsWith('.dart')) {
      buf.writeln(e.readAsStringSync());
    }
  }
  return buf.toString();
}

/// 平台模拟 helper（§21.1，与 Q0-2 相同约定）：override 必须在 body 内恢复
void testWidgetsOnPlatform(String description, TargetPlatform? platform,
    Future<void> Function(WidgetTester tester) body) {
  testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

String srcOf(String relPath) => File(relPath).readAsStringSync();

int countOf(String source, String needle) => source.split(needle).length - 1;

void windowsMode() {
  debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  PlatformCapabilities.resetForTest();
}

void main() {
  setUp(() {
    PlatformCapabilities.resetForTest();
    debugDefaultTargetPlatformOverride = null;
    TaskbarNotifier.enabled = true;
    TaskbarNotifier.soundEnabled = true;
    TaskbarNotifier.dndEnabled = false;
    AppState.instance
      ..setLoggedOut()
      ..setConnectionStatus(ConnectionStatus.disconnected);
  });
  tearDown(() {
    PlatformCapabilities.resetForTest();
    debugDefaultTargetPlatformOverride = null;
    TaskbarNotifier.enabled = true;
    TaskbarNotifier.soundEnabled = true;
    TaskbarNotifier.dndEnabled = false;
  });

  group('Q2-3 —— Windows 能力分发（占位退役）', () {
    test('notification 非 DesktopNotificationStub（任务栏闪烁真实现接位）', () {
      windowsMode();
      expect(PlatformCapabilities.notification,
          isNot(isA<DesktopNotificationStub>()),
          reason: 'Q0-3 占位退役：Windows 端 flash/clearUrgency 走真实现');
    });

    test('sound 非 DesktopSoundStub（Windows 播放真实现接位）', () {
      windowsMode();
      expect(PlatformCapabilities.sound, isNot(isA<DesktopSoundStub>()),
          reason: 'Q0-3 占位退役：Windows 端 playNotifySound 走真实现');
    });

    test('fileDrop 非 DesktopFileDropStub（desktop_drop 类真实现接位）', () {
      windowsMode();
      expect(PlatformCapabilities.fileDrop, isNot(isA<DesktopFileDropStub>()),
          reason: 'Q0-3 占位退役：Windows 端拖拽走真实现');
    });

    test('fileLauncher 保持 DesktopFileLauncher（Q0 真实现不回退）', () {
      windowsMode();
      expect(PlatformCapabilities.fileLauncher, isA<DesktopFileLauncher>(),
          reason: 'cmd /c start 打开文件（Q0-3 已实现），Q2 重构不得丢失');
    });
  });

  group('Q2-3 —— 真实现技术特征（源码扫描）', () {
    test('通知实现含 win32 任务栏闪烁特征（FlashWindowEx / user32.dll）', () {
      final src = platformSource();
      final hasWin32Flash =
          src.contains('FlashWindowEx') || src.contains('user32.dll');
      expect(hasWin32Flash, isTrue,
          reason: 'Windows 任务栏闪烁经 win32 API 实现（FFI 或 runner 通道）');
    });

    test('提示音实现含 Windows 播放通道特征（PlaySound/winmm/SoundPlayer）', () {
      final src = platformSource();
      final hasWinSound = src.contains('PlaySound') ||
          src.contains('winmm') ||
          src.contains('SoundPlayer');
      expect(hasWinSound, isTrue,
          reason: '生成式 WAV 经 Windows 播放通道（实现细节自由，通道必须存在）');
    });

    test('拖拽实现接入 desktop_drop 类方案（pubspec 依赖或 runner 原生钩子）', () {
      final pubspec = srcOf('pubspec.yaml');
      final runner = srcOf('windows/runner/main.cpp') +
          srcOf('windows/runner/flutter_window.cpp');
      final pubspecHasDrop = pubspec.contains('desktop_drop');
      final runnerHasDrop =
          runner.contains('DragAcceptFiles') || runner.contains('WM_DROPFILES');
      expect(pubspecHasDrop || runnerHasDrop, isTrue,
          reason: '§13.9 Q0-3 行：desktop_drop 类方案（插件）或 runner 原生拖拽钩子');
      final platformSrc = platformSource();
      final platformHasDrop = platformSrc.contains('desktop_drop') ||
          platformSrc.contains('DropTarget') ||
          platformSrc.contains('WM_DROPFILES') ||
          platformSrc.contains('DragAcceptFiles');
      expect(platformHasDrop, isTrue,
          reason: 'Windows fileDrop 实现必须引用真实拖拽源（channel/widget/原生）');
    });
  });

  group('Q2-3 —— 安全降级（Linux 开发机模拟 Windows 调用不崩）', () {
    test('flash/clearUrgency：DLL 缺失静默（FFI 降级惯例）', () {
      windowsMode();
      expect(() => PlatformCapabilities.notification.flash(), returnsNormally);
      expect(() => PlatformCapabilities.notification.clearUrgency(),
          returnsNormally);
    });

    test('playNotifySound：无 winmm 静默完成', () async {
      windowsMode();
      await expectLater(
          PlatformCapabilities.sound.playNotifySound(), completes);
    });

    test('openFile/openDirectory：cmd 缺失静默返回 false（Linux 宿主前提）', () async {
      windowsMode();
      // "cmd 缺失"前提仅在 Linux 开发机宿主成立。真 Windows 宿主 cmd 必然
      // 存在，且 start 对不存在文件会弹系统模态对话框并阻塞 Process.run
      // （2026-09-19 真机实证）——安全降级契约的本意是"完成且不抛"，
      // false 断言与调用路径均限定 Linux 宿主。
      if (!Platform.isLinux) {
        markTestSkipped('真 Windows 宿主：cmd /c start 对不存在文件弹模态对话框阻塞，'
            '跳过调用（安全降级语义由 Linux 宿主轮次锁定）');
        return;
      }
      expect(
          await PlatformCapabilities.fileLauncher.openFile(r'C:\tmp\nope.txt'),
          isFalse);
      expect(
          await PlatformCapabilities.fileLauncher.openDirectory(r'C:\tmp\nope'),
          isFalse);
    });

    test('fileDrop 注册链安全：ensureListening/setOnFilesDropped(null) 不崩', () {
      windowsMode();
      PlatformCapabilities.fileDrop.ensureListening();
      PlatformCapabilities.fileDrop.setOnFilesDropped((files) {});
      PlatformCapabilities.fileDrop.setOnFilesDropped(null);
    });
  });

  group('Q2-3 —— Windows 端上层提醒语义（H1/K3 规则不因实现替换漂移）', () {
    test('TaskbarNotifier.enabled=false → flash 静默；enabled=true → 经能力分发', () {
      windowsMode();
      final fake = CountingNotification();
      PlatformCapabilities.notificationOverride = fake;
      TaskbarNotifier.enabled = false;
      TaskbarNotifier.flash();
      expect(fake.flashCount, 0, reason: 'H1 总开关语义 Windows 端一致');
      TaskbarNotifier.enabled = true;
      TaskbarNotifier.flash();
      expect(fake.flashCount, 1, reason: '闪烁经能力抽象分发到 Windows 实现');
    });

    test('TaskbarNotifier.playSound() → Windows sound 能力（soundEnabled 语义）',
        () async {
      windowsMode();
      final fake = CountingSound();
      PlatformCapabilities.soundOverride = fake;
      TaskbarNotifier.soundEnabled = false;
      TaskbarNotifier.maybeFlashForMessage(
        ChatMessage(
          sender: 'bob',
          content: 'hello',
          messageId: 'q2cap-1',
          status: 'sent',
          type: 'chat',
        ),
        'bob',
      );
      expect(fake.playCount, 0);
      TaskbarNotifier.soundEnabled = true;
      TaskbarNotifier.playSound();
      await Future<void>.delayed(Duration.zero);
      expect(fake.playCount, 1, reason: '提示音经能力抽象分发到 Windows 实现');
    });
  });

  group('Q2-3 —— ChatScreen 拖拽接线迁入能力层（关键集成契约）', () {
    test('chat_screen.dart 不再直接引用 FileDrop.instance（Linux 专属实现）', () {
      final src = srcOf('lib/screens/chat_screen.dart');
      expect(countOf(src, 'FileDrop.instance'), 0,
          reason: 'FileDrop.instance 是 GTK channel（Linux 专属）——'
              '直接引用会让 Windows 拖拽实现永远收不到注册');
      expect(countOf(src, 'PlatformCapabilities.fileDrop'),
          greaterThanOrEqualTo(2),
          reason: '注册（initState）与注销（dispose）均走能力抽象');
    });

    testWidgetsOnPlatform(
        'Windows 模拟挂载：经能力层注册监听与 handler', TargetPlatform.windows,
        (tester) async {
      final drop = RecordingDrop();
      PlatformCapabilities.fileDropOverride = drop;
      final socket = MockSocketService();
      AppState.instance.setLoggedIn('alice', false);

      await tester.pumpWidget(MaterialApp(
        home: ChatScreen(socketService: socket),
        routes: {'/login': (_) => const Scaffold(body: Text('LOGIN'))},
      ));
      await tester.pump();

      expect(find.text('聊天室 - alice'), findsOneWidget,
          reason: 'Windows 模拟下 ChatScreen 正常挂载（综合冒烟）');
      expect(drop.listenCount, 1,
          reason:
              'initState 经 PlatformCapabilities.fileDrop.ensureListening()');
      expect(drop.handler, isNotNull,
          reason: '拖入文件 handler 已注册（_onFilesDropped）');
    });

    testWidgetsOnPlatform(
        'Windows 模拟卸载：handler 置 null（防跨界面串扰惯例）', TargetPlatform.windows,
        (tester) async {
      final drop = RecordingDrop();
      PlatformCapabilities.fileDropOverride = drop;
      final socket = MockSocketService();
      AppState.instance.setLoggedIn('alice', false);

      await tester.pumpWidget(MaterialApp(
        home: ChatScreen(socketService: socket),
        routes: {'/login': (_) => const Scaffold(body: Text('LOGIN'))},
      ));
      await tester.pump();
      expect(drop.handler, isNotNull);

      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump();
      expect(drop.handler, isNull, reason: 'dispose → setOnFilesDropped(null)');
    });

    testWidgetsOnPlatform(
        '拖入文件走既有 N3 发送通道（sendFile / M8 分流入口）', TargetPlatform.windows,
        (tester) async {
      final drop = RecordingDrop();
      PlatformCapabilities.fileDropOverride = drop;
      final socket = MockSocketService();
      when(() => socket.sendFile(any(), any(), any()))
          .thenAnswer((_) async => true);
      AppState.instance
        ..setLoggedIn('alice', false)
        ..selectChat('bob');

      await tester.pumpWidget(MaterialApp(
        home: ChatScreen(socketService: socket),
        routes: {'/login': (_) => const Scaffold(body: Text('LOGIN'))},
      ));
      await tester.pump();

      drop.deliver([r'C:\Users\tester\Desktop\a.txt']);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      verify(() =>
              socket.sendFile('bob', r'C:\Users\tester\Desktop\a.txt', 'a.txt'))
          .called(1);
    });
  });

  group('Q2-J —— Windows 字体平台分发（表情网格空白/中文字体怪异修复）', () {
    test('emojiPickerFontFamily：Windows → Segoe UI Emoji（COLRv1 网格空白修复）', () {
      windowsMode();
      expect(emojiPickerFontFamily(), 'Segoe UI Emoji');
    });

    test('emojiPickerFontFamily：Linux → NotoColorEmoji（既有基线不漂移）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      PlatformCapabilities.resetForTest();
      expect(emojiPickerFontFamily(), 'NotoColorEmoji');
    });

    test('uiFontFamily：Windows → Microsoft YaHei UI；Linux → null', () {
      windowsMode();
      expect(uiFontFamily(), 'Microsoft YaHei UI');
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      PlatformCapabilities.resetForTest();
      expect(uiFontFamily(), isNull);
    });

    test('网格/回应盘字体引用改走平台分发（源码扫描无硬编码主字体）', () {
      final dialogs = srcOf('lib/widgets/dialogs.dart');
      final chatView = srcOf('lib/widgets/chat_view.dart');
      expect(dialogs.contains("fontFamily: 'NotoColorEmoji'"), isFalse,
          reason: '表情网格主字体硬编码会在 Windows 渲染空白（Q2 真机）');
      expect(chatView.contains("fontFamily: 'NotoColorEmoji'"), isFalse,
          reason: '回应盘 ActionChip 同类缺陷（chat_view 网格）');
      expect(dialogs.contains('emojiPickerFontFamily()'), isTrue,
          reason: '表情网格主字体走平台分发');
      expect(chatView.contains('emojiPickerFontFamily()'), isTrue,
          reason: '回应盘主字体走平台分发（format 折行不破坏契约）');
    });

    test('主题接入 uiFontFamily（Windows 中文字体主字体）', () {
      expect(
          srcOf('lib/main.dart').contains('fontFamily: uiFontFamily()'), isTrue,
          reason: 'ThemeData 主字体经平台分发（Windows 微软雅黑 UI）');
    });
  });
}
