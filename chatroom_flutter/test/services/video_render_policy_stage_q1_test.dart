// ============================================================
// media_kit 渲染策略契约（阶段 Q1-3 —— TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 Q「Q1 Android」要点：
// "media_kit 移动端验证——软件渲染契约 R-P8 仅限 Linux，移动端恢复
// 默认硬解"；§36.3 矩阵"视频播放"行：软渲染契约 R-P8 仅限 Linux，
// 其余端默认硬解，失败回退系统播放器；§21.5 已知平台差异注记。
//
// 背景（R-P8，勿回退）：Linux 虚拟机/llvmpipe/部分驱动下 media_kit
// 默认 H/W 路径"创建成功但帧不上屏"（有声无画），故 Linux 强制
// enableHardwareAcceleration: false + hwdec: 'no'。该契约是 Linux
// 环境缺陷的规避，不应外溢到 Android（真机硬解正常且省电）。
//
// 契约：capabilities.dart 新增顶层策略函数（与 effectiveTargetPlatform
// 同源平台判定，override 可模拟）——
//
//   bool videoSoftwareRendering();
//     · TargetPlatform.linux     → true （R-P8 契约保留）
//     · 其余平台（android/ios/windows/macos/fuchsia）→ false（默认硬解）
//
// chat_screen.dart _VideoViewerPage 接线（源码扫描锁定）：
//   · 引用 videoSoftwareRendering（策略驱动，硬编码解除）；
//   · 'enableHardwareAcceleration: false' 与 "hwdec: 'no'" 字面量消失
//     （改经策略表达式，Linux 行为等价、Android 恢复默认）。
//
// 移动端回退路径（widget，平台模拟）：视频查看器在测试环境恒走
// "使用系统播放器打开"回退（AutomatedTestWidgetsFlutterBinding 判定，
// R-P21 惯例）；Android 模拟下点击回退经 fileLauncher 能力打开视频
// 落盘路径（Q1-2 通道实现后即 Intent 打开）。
//
// 实现前：videoSoftwareRendering 不存在，本文件编译失败，属 TDD 红。
// 实现后：全部转绿。
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

class MockSocketService extends Mock implements SocketService {}

class FakeLauncher implements FileLauncherCapability {
  String? lastFile;
  @override
  Future<bool> openFile(String path) async {
    lastFile = path;
    return true;
  }

  @override
  Future<bool> openDirectory(String path) async => false;
}

String srcOf(String relPath) => File('lib/$relPath').readAsStringSync();

int countOf(String source, String needle) => source.split(needle).length - 1;

/// 平台模拟 wrapper：override 在 testWidgets body 内恢复（§21.8 规约，
/// foundation invariant 检查先于 tearDown）
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

AppState get state => AppState.instance;

/// 视频气泡渲染用字节（触发卡片渲染，非真 MP4——测试环境恒走回退）
final Uint8List bubbleBytes = Uint8List.fromList(
    [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02]);

void resetState() {
  state
    ..setLoggedOut()
    ..setConnectionStatus(ConnectionStatus.disconnected);
}

Future<void> pumpScreen(WidgetTester tester, MockSocketService socket) async {
  await tester.pumpWidget(MaterialApp(
    home: ChatScreen(socketService: socket),
    routes: {'/login': (_) => const Scaffold(body: Text('LOGIN'))},
  ));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(resetState);
  tearDown(resetState);

  group('Q1-3 —— 渲染策略矩阵（R-P8 仅限 Linux）', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('linux → true（R-P8 软件渲染契约保留，勿回退）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(videoSoftwareRendering(), isTrue);
    });

    test('android → false（移动端恢复默认硬解）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(videoSoftwareRendering(), isFalse);
    });

    test('ios → false', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(videoSoftwareRendering(), isFalse);
    });

    test('windows → false（Q2 复用同一策略）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(videoSoftwareRendering(), isFalse);
    });

    test('macos → false（Q3 复用同一策略）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(videoSoftwareRendering(), isFalse);
    });

    test('override 切换即时生效（与 effectiveTargetPlatform 同源判定）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(videoSoftwareRendering(), isTrue);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(videoSoftwareRendering(), isFalse);
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(videoSoftwareRendering(), isTrue);
    });
  });

  group('Q1-3 —— chat_screen 接线（源码扫描：策略驱动，硬编码解除）', () {
    test('chat_screen.dart 引用 videoSoftwareRendering（策略接线）', () {
      final src = srcOf('screens/chat_screen.dart');
      expect(countOf(src, 'videoSoftwareRendering'), greaterThanOrEqualTo(1),
          reason: '_VideoViewerPage 经策略函数取渲染配置');
    });

    test(
        "R-P8 硬编码字面量消失（'enableHardwareAcceleration: false' 与 "
        '"hwdec: \'no\'" 均改由策略表达式驱动；Linux 行为等价、Android 默认硬解）', () {
      final src = srcOf('screens/chat_screen.dart');
      expect(countOf(src, 'enableHardwareAcceleration: false'), 0,
          reason: '实现注意：注释中也不要出现该字面量（用策略命名表述）');
      expect(countOf(src, "hwdec: 'no'"), 0);
    });
  });

  group('Q1-3 —— Android 回退路径（移动端回退 = 系统播放器 Intent）', () {
    testWidgetsOnPlatform(
        'android 模拟：视频查看器打开 → 测试环境恒回退"使用系统播放器打开"', TargetPlatform.android,
        (tester) async {
      final socket = MockSocketService();
      when(() => socket.saveConversationDraft(any(), any()))
          .thenAnswer((_) async {});
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');
      state.addMessage(
        'bob',
        ChatMessage(
          sender: 'bob',
          content: '[收到文件] movie.mp4',
          messageId: 'v-q1',
          type: 'file',
          filename: 'movie.mp4',
          filesize: 2048,
          fileData: bubbleBytes,
        ),
      );

      await pumpScreen(tester, socket);
      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pumpAndSettle();

      expect(find.textContaining('使用系统播放器'), findsOneWidget,
          reason: 'AutomatedTestWidgetsFlutterBinding 恒走回退（R-P21 惯例）——'
              'Android 模拟同样适用');
      expect(tester.takeException(), isNull);
    });

    testWidgetsOnPlatform(
        'android 模拟：点击回退 → 经 fileLauncher 能力打开视频落盘路径', TargetPlatform.android,
        (tester) async {
      final video = File(
          '${Directory.systemTemp.path}/q1_video_${DateTime.now().microsecondsSinceEpoch}.mp4');
      video.writeAsBytesSync(List.filled(32, 1));
      addTearDown(() {
        if (video.existsSync()) video.deleteSync();
      });

      final fake = FakeLauncher();
      PlatformCapabilities.fileLauncherOverride = fake;
      addTearDown(PlatformCapabilities.resetForTest);

      final socket = MockSocketService();
      when(() => socket.saveConversationDraft(any(), any()))
          .thenAnswer((_) async {});
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');
      state.addMessage(
        'bob',
        ChatMessage(
          sender: 'bob',
          content: '[收到文件] movie.mp4',
          messageId: 'v-q1b',
          type: 'file',
          filename: 'movie.mp4',
          filesize: 32,
          fileData: bubbleBytes,
          filePath: video.path,
        ),
      );

      await pumpScreen(tester, socket);
      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pumpAndSettle();

      await tester.tap(find.text('使用系统播放器打开'));
      await tester.pumpAndSettle();

      expect(fake.lastFile, video.path,
          reason: '回退链路经能力层（Q1-2 通道实现后即系统播放器 Intent 打开）');
      expect(tester.takeException(), isNull);
    });

    testWidgetsOnPlatform('android 模拟：回退页关闭按钮可用（关闭无异常）', TargetPlatform.android,
        (tester) async {
      final socket = MockSocketService();
      when(() => socket.saveConversationDraft(any(), any()))
          .thenAnswer((_) async {});
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');
      state.addMessage(
        'bob',
        ChatMessage(
          sender: 'bob',
          content: '[收到文件] movie.mp4',
          messageId: 'v-q1c',
          type: 'file',
          filename: 'movie.mp4',
          filesize: 2048,
          fileData: bubbleBytes,
        ),
      );

      await pumpScreen(tester, socket);
      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();

      expect(find.textContaining('使用系统播放器'), findsNothing,
          reason: '查看器已关闭回到聊天页');
      expect(tester.takeException(), isNull);
    });
  });
}
