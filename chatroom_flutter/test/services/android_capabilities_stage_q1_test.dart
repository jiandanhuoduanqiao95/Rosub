// ============================================================
// Android 平台适配器实现契约（阶段 Q1-2 —— TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 Q「Q1 Android」要点：
// 平台能力抽象（Q0-3）在 Android 端的落地——Q0 的 Mobile* 占位升级
// 为可用的 Android 实现。§13.9 分支纪律：按端一个文件的适配器实现
// （platform/capabilities_android.dart），共享工厂（capabilities.dart）
// 仅接线不直改实现。
//
// 契约：新增 lib/platform/capabilities_android.dart ——
//
//   class AndroidNotificationCapability implements NotificationCapability
//     · 应用内徽标语义（§36.3"提醒/通知"行：移动=应用内徽标+提示音；
//       系统级弹窗通知恒不做——排除清单）。flash/clearUrgency 为安全
//       no-op（徽标/提示音已由 AppState 未读计数 + TaskbarNotifier
//       通道驱动，能力层不再重复触发）。
//
//   class AndroidSoundCapability implements SoundCapability
//     · playNotifySound 复用生成式 chime WAV（阶段 K3 音色，不复制
//       生成代码）——TaskbarNotifier 新增公开静态 ensureChimeWav()
//       （原私有 _ensureChimeWav 收敛为公开），经媒体播放通道播放；
//       播放失败/无后端静默降级（fire-and-forget，不抛异常）。
//
//   class AndroidFileLauncherCapability implements FileLauncherCapability
//     · openFile 经 MethodChannel('chatroom/platform') 方法 'openFile'
//       （参数 {'path': ...}）由 MainActivity.kt Intent 打开（系统
//       播放器/查看器回退链路，R-P8/§13.9"移动端回退=系统播放器
//       Intent 打开"）；Q1 四轮（问题5 用户决策）：openDirectory 恒
//       false——Android 不做"打开所在目录"（接收目录位于应用内部存储，
//       文件管理器不可见），文件导出走"分享"（shareFile 通道）。
//     · 通道缺失（MissingPluginException）安全降级 false，不崩。
//
//   class AndroidFileDropStub implements FileDropCapability
//     · 拖拽桌面专属：isSupported == false（§36.3 矩阵 ❌ 语义不变）。
//
// capabilities.dart 的 android 分支改用上述实现；iOS/fuchsia 分支
// 保持 Mobile* 占位不变（Q4 处理）；*Override 注入优先于一切默认链
// （Q0-3 语义回归）。
//
// 接线收敛（源码扫描锁定）：chat_screen.dart 的拖拽监听从
// FileDrop.instance 直连改为经 PlatformCapabilities.fileDrop 能力
// （移动端不再注册 GTK 拖拽通道监听）。
//
// 实现前：capabilities_android.dart / ensureChimeWav 不存在，本文件
// 编译失败，属 TDD 红。实现后：全部转绿。
// ============================================================

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/platform/capabilities.dart';
import 'package:chatroom_flutter/platform/capabilities_android.dart';
import 'package:chatroom_flutter/services/taskbar_notifier.dart';

class FakeNotification implements NotificationCapability {
  int flashCount = 0;
  @override
  void flash() => flashCount++;
  @override
  void clearUrgency() {}
}

String srcOf(String relPath) => File('lib/$relPath').readAsStringSync();

int countOf(String source, String needle) => source.split(needle).length - 1;

const MethodChannel platformChannel = MethodChannel('chatroom/platform');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PlatformCapabilities.resetForTest();
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platformChannel, null);
  });
  tearDown(() {
    PlatformCapabilities.resetForTest();
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platformChannel, null);
  });

  /// 切到 Android 平台模拟并重建默认链
  void useAndroid() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    PlatformCapabilities.resetForTest();
  }

  group('Q1 四轮 —— openDirectory 不做（问题5 用户决策）+ 提示音通知音量', () {
    test('capabilities_android 保留恒 false 占位（Android 无目录语义，锁定勿回退）',
        () {
      final src = srcOf('platform/capabilities_android.dart');
      expect(src.contains("openDirectory(String path) async => false"),
          isTrue,
          reason: 'Q1 四轮问题5：接收目录位于应用内部存储，目录功能无意义'
              '（导出走"分享"）——勿重新接通目录通道');
    });

    test('Q1 六轮问题3：通知渠道应用提示音 + 客户端内震动（原生源码扫描）',
        () {
      final kt = File(
              'android/app/src/main/kotlin/com/example/chatroom_flutter/MainActivity.kt')
          .readAsStringSync();
      expect(kt.contains('setupMessageChannel'), isTrue,
          reason: '消息渠道初始化通道（应用 chime 挂载到渠道）');
      expect(kt.contains('raw/notify_chime'), isTrue,
          reason: '渠道提示音 = 打包内置资源（Q1 八轮：file:// 外部目录 '
              'Uri 在 OneUI 上 SystemUI 读不到，只有震动无声）');
      expect(
          File('android/app/src/main/res/raw/notify_chime.wav').existsSync(),
          isTrue,
          reason: '与应用内 TaskbarNotifier 生成式 chime 同算法固化');
      expect(kt.contains('VibrationEffect.createWaveform'), isTrue,
          reason: '客户端内提示音伴随同款节奏震动');
    });

    test('Q1 七轮问题1：后台传输进度系统通知（原生源码扫描）', () {
      final kt = File(
              'android/app/src/main/kotlin/com/example/chatroom_flutter/MainActivity.kt')
          .readAsStringSync();
      expect(kt.contains('showTransferNotification'), isTrue);
      expect(kt.contains('chatroom_transfer'), isTrue,
          reason: '独立低优先级渠道（静默、不弹横幅）');
      expect(kt.contains('setProgress(100'), isTrue);
    });

    test('提示音经 playNotifySound 通道（通知音量流；不再走媒体流）', () {
      final src = srcOf('platform/capabilities_android.dart');
      expect(src.contains("'playNotifySound'"), isTrue,
          reason: 'Q1 四轮问题6：原生通知用途播放（通知音量）');
      expect(src.contains("import 'package:media_kit"), isFalse,
          reason: 'media_kit 走媒体音量——媒体音量归零即静音，不合语义');
    });
  });

  group('Q1-2 —— 按端适配器文件与工厂接线（分支纪律：按端拆文件）', () {
    test('lib/platform/capabilities_android.dart 存在', () {
      expect(
          File('lib/platform/capabilities_android.dart').existsSync(), isTrue);
    });

    test('capabilities.dart 引用 capabilities_android（工厂接线，源码扫描）', () {
      final src = srcOf('platform/capabilities.dart');
      expect(src.contains("capabilities_android"), isTrue,
          reason: 'android 分支接入按端适配器实现文件');
    });

    test('android → notification is AndroidNotificationCapability', () {
      useAndroid();
      expect(PlatformCapabilities.notification,
          isA<AndroidNotificationCapability>());
    });

    test('android → sound is AndroidSoundCapability', () {
      useAndroid();
      expect(PlatformCapabilities.sound, isA<AndroidSoundCapability>());
    });

    test('android → fileLauncher is AndroidFileLauncherCapability', () {
      useAndroid();
      expect(PlatformCapabilities.fileLauncher,
          isA<AndroidFileLauncherCapability>());
    });

    test('android → fileDrop.isSupported == false（拖拽桌面专属，语义不变）', () {
      useAndroid();
      expect(PlatformCapabilities.fileDrop.isSupported, isFalse);
    });

    test('iOS 分支保持 Mobile* 占位（Q4 之前不变）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      PlatformCapabilities.resetForTest();
      expect(PlatformCapabilities.notification,
          isA<MobileNotificationCapability>());
      expect(PlatformCapabilities.sound, isA<MobileSoundCapability>());
      expect(PlatformCapabilities.fileLauncher, isA<MobileFileLauncher>());
    });

    test('override 仍优先于 Android 默认链（Q0-3 注入语义回归）', () {
      useAndroid();
      final fake = FakeNotification();
      PlatformCapabilities.notificationOverride = fake;
      expect(identical(PlatformCapabilities.notification, fake), isTrue);
    });
  });

  group('Q1-2 —— 文件打开通道契约（Intent 打开，系统播放器回退链路）', () {
    test("openFile 经 'chatroom/platform'/'openFile' 通道，参数 path 透传", () async {
      useAndroid();
      MethodCall? received;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platformChannel, (call) async {
        received = call;
        return true;
      });
      final ok = await PlatformCapabilities.fileLauncher.openFile('/tmp/v.mp4');
      expect(ok, isTrue);
      expect(received, isNotNull);
      expect(received!.method, 'openFile');
      expect(received!.arguments['path'], '/tmp/v.mp4');
    });

    test('通道返回 false → openFile false（打开失败/无处理方语义）', () async {
      useAndroid();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platformChannel, (call) async => false);
      expect(await PlatformCapabilities.fileLauncher.openFile('/tmp/v.mp4'),
          isFalse);
    });

    test('通道缺失（无原生对端）→ 安全降级 false，不崩', () async {
      useAndroid();
      expect(await PlatformCapabilities.fileLauncher.openFile('/tmp/v.mp4'),
          isFalse,
          reason: 'MissingPluginException 须被吞掉（FLUTTER_TEST/通道未注册）');
    });

    test('openDirectory 恒 false（Q1 四轮问题5：Android 不做目录语义）', () async {
      useAndroid();
      // 即便通道对端存在并返回 true，能力层也必须恒 false（用户决策锁定）
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platformChannel, (call) async => true);
      expect(await PlatformCapabilities.fileLauncher.openDirectory('/tmp'),
          isFalse);
    });
  });

  group('Q1-2 —— 提示音复用（生成式 chime WAV 不复制）', () {
    test('TaskbarNotifier.ensureChimeWav() 公开且产出合法 WAV 文件', () {
      final path = TaskbarNotifier.ensureChimeWav();
      expect(path, isNotNull, reason: '阶段 K3 生成式音色收敛为公开可复用');
      final file = File(path!);
      expect(file.existsSync(), isTrue);
      final header = file.readAsBytesSync().sublist(0, 4);
      expect(String.fromCharCodes(header), 'RIFF', reason: 'WAV 文件头合法');
    });

    test('capabilities_android.dart 复用 chime（源码扫描：引用而非复制音色）', () {
      final src = srcOf('platform/capabilities_android.dart');
      expect(src.contains('ensureChimeWav'), isTrue,
          reason: 'AndroidSoundCapability 复用 TaskbarNotifier 生成式 WAV');
      expect(src.contains('_generateChimeWav'), isFalse,
          reason: '不得复制生成代码（双份音色漂移风险）');
    });

    test('AndroidSoundCapability().playNotifySound() 测试环境安全完成', () async {
      useAndroid();
      await expectLater(PlatformCapabilities.sound.playNotifySound(), completes,
          reason: '无音频后端/无媒体引擎环境静默降级（fire-and-forget）');
    });
  });

  group('Q1-2 —— 通知徽标语义与拖拽接线收敛', () {
    test(
        'AndroidNotificationCapability flash/clearUrgency 调用安全'
        '（应用内徽标语义：徽标/提示音已由既有通道驱动，能力层不重复触发）', () {
      useAndroid();
      expect(() => PlatformCapabilities.notification.flash(), returnsNormally);
      expect(() => PlatformCapabilities.notification.clearUrgency(),
          returnsNormally);
    });

    test('chat_screen.dart 拖拽监听改走能力层（源码扫描：FileDrop.instance 直连消失）', () {
      final src = srcOf('screens/chat_screen.dart');
      expect(countOf(src, 'FileDrop.instance'), 0,
          reason: '移动端不应注册 GTK 拖拽通道（isSupported=false 语义）');
      expect(countOf(src, 'PlatformCapabilities.fileDrop'),
          greaterThanOrEqualTo(2),
          reason: 'initState 监听注册与 dispose 解除均经能力层');
    });

    test('taskbar_notifier.dart 公开 ensureChimeWav（源码扫描）', () {
      final src = srcOf('services/taskbar_notifier.dart');
      expect(src.contains('ensureChimeWav'), isTrue,
          reason: '私有 _ensureChimeWav 收敛为公开静态（Q1 复用入口）');
    });
  });

  group('Q1-2 —— Android 全链安全降级（Q0-3 #19 经新实现回归）', () {
    test('五能力默认实现调用全部安全（无崩溃、Future 全部完成）', () async {
      useAndroid();
      expect(() => PlatformCapabilities.notification.flash(), returnsNormally);
      expect(() => PlatformCapabilities.notification.clearUrgency(),
          returnsNormally);
      await expectLater(
          PlatformCapabilities.sound.playNotifySound(), completes);
      await expectLater(
          PlatformCapabilities.fileLauncher.openFile('/nonexistent'),
          completes);
      await expectLater(
          PlatformCapabilities.fileLauncher.openDirectory('/nonexistent'),
          completes);
      expect(PlatformCapabilities.fileDrop.isSupported, isFalse);
    });
  });
}
