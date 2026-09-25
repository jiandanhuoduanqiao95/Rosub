// ============================================================
// 平台能力抽象契约（阶段 Q0-3 —— TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 Q「Q0-3 平台能力抽象」：
//
//   通知闪烁（Linux=FFI urgency / Windows=任务栏 / macOS=Dock /
//     移动=应用内徽标；系统级弹窗通知维持"不做"决策——§13.6 排除清单）；
//   打开文件/目录（替换 3 处 xdg-open：chat_screen.dart:1455、
//     dialogs.dart:3914/3921）；
//   文件拖拽（Linux=GTK channel / Windows/macOS=desktop_drop 类方案 /
//     移动不适用）；
//   提示音（paplay/aplay 仅 Linux，需按平台换实现）。
//
// 契约：新增 lib/platform/capabilities.dart ——
//
//   abstract class NotificationCapability {
//     void flash(); void clearUrgency(); }
//   abstract class SoundCapability {
//     Future<void> playNotifySound(); }
//   abstract class FileLauncherCapability {
//     Future<bool> openFile(String path);
//     Future<bool> openDirectory(String path); }
//   abstract class FileDropCapability {
//     bool get isSupported;
//     void ensureListening();
//     void setOnFilesDropped(void Function(List<String> files)? handler); }
//
//   class PlatformCapabilities {  // 按平台工厂 + 测试注入点
//     static NotificationCapability get notification;
//     static SoundCapability get sound;
//     static FileLauncherCapability get fileLauncher;
//     static FileDropCapability get fileDrop;
//     // 可注入 override（仿 TaskbarNotifier.playSoundImpl 惯例；
//     // 优先级高于一切默认链）
//     static NotificationCapability? notificationOverride;
//     static SoundCapability? soundOverride;
//     static FileLauncherCapability? fileLauncherOverride;
//     static FileDropCapability? fileDropOverride;
//     static void resetForTest(); // 清 override + 平台缓存
//   }
//
//   · 平台判定用 defaultTargetPlatform（§21.1 平台模拟规约）；平台
//     相关实现选择在 resetForTest() 后按当前平台重新解析
//   · android/ios：fileDrop.isSupported == false（拖拽桌面专属，§36.3
//     矩阵 ❌）；其余桌面平台 true
//   · 全部默认实现必须安全降级：FLUTTER_TEST / 无窗口环境调用不崩
//     （FFI lookup 失败 / 子进程缺失均 catch，沿用 TaskbarNotifier
//     既有异常隔离惯例）
//   · 既有注入点保留不破坏（阶段 K 语义回归锁定）：
//       TaskbarNotifier.setUrgencyImpl / playSoundImpl 仍是 Linux 默认
//     链的底层；PlatformCapabilities.*Override 优先于它
//   · 接线收敛：TaskbarNotifier.flash/clearUrgency → notification 能力；
//     TaskbarNotifier.playSound → sound 能力；3 处 xdg-open →
//     fileLauncher 能力（源码扫描锁定）；FileDrop.instance 为 Linux
//     默认 fileDrop 实现（GTK channel 逻辑原样保留）
//
// 实现前：capabilities.dart 不存在，本文件编译失败，属 TDD 红。
// 实现后：全部转绿。
// ============================================================

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/config.dart';
import 'package:chatroom_flutter/platform/capabilities.dart';
import 'package:chatroom_flutter/services/file_drop.dart';
import 'package:chatroom_flutter/services/taskbar_notifier.dart';

class FakeNotification implements NotificationCapability {
  int flashCount = 0;
  int clearCount = 0;
  @override
  void flash() => flashCount++;
  @override
  void clearUrgency() => clearCount++;
}

class FakeSound implements SoundCapability {
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

class FakeLauncher implements FileLauncherCapability {
  String? lastFile;
  String? lastDir;
  bool result = true;
  @override
  Future<bool> openFile(String path) async {
    lastFile = path;
    return result;
  }

  @override
  Future<bool> openDirectory(String path) async {
    lastDir = path;
    return result;
  }
}

class FakeDrop implements FileDropCapability {
  final bool supported;
  int listenCount = 0;
  List<String>? lastFiles;
  FakeDrop(this.supported);
  @override
  bool get isSupported => supported;
  @override
  void ensureListening() => listenCount++;
  @override
  void setOnFilesDropped(void Function(List<String> files)? handler) {
    lastFiles = null;
  }
}

String srcOf(String relPath) => File('lib/$relPath').readAsStringSync();

int countOf(String source, String needle) => source.split(needle).length - 1;

void main() {
  setUp(() {
    PlatformCapabilities.resetForTest();
    debugDefaultTargetPlatformOverride = null;
    TaskbarNotifier.enabled = true;
    TaskbarNotifier.soundEnabled = true;
    TaskbarNotifier.dndEnabled = false;
  });
  tearDown(() {
    PlatformCapabilities.resetForTest();
    debugDefaultTargetPlatformOverride = null;
    TaskbarNotifier.enabled = true;
    TaskbarNotifier.soundEnabled = true;
    TaskbarNotifier.dndEnabled = false;
  });

  group('Q0-3 —— 能力注入与默认获取（工厂契约）', () {
    test('notificationOverride 注入后 getter 返回同一实例', () {
      final fake = FakeNotification();
      PlatformCapabilities.notificationOverride = fake;
      expect(identical(PlatformCapabilities.notification, fake), isTrue);
    });

    test('soundOverride 注入后 getter 返回同一实例', () {
      final fake = FakeSound();
      PlatformCapabilities.soundOverride = fake;
      expect(identical(PlatformCapabilities.sound, fake), isTrue);
    });

    test('fileLauncherOverride 注入后 getter 返回同一实例', () {
      final fake = FakeLauncher();
      PlatformCapabilities.fileLauncherOverride = fake;
      expect(identical(PlatformCapabilities.fileLauncher, fake), isTrue);
    });

    test('fileDropOverride 注入后 getter 返回同一实例', () {
      final fake = FakeDrop(true);
      PlatformCapabilities.fileDropOverride = fake;
      expect(identical(PlatformCapabilities.fileDrop, fake), isTrue);
    });

    test('未注入时返回默认实现（非 null 且访问幂等）', () {
      final a = PlatformCapabilities.notification;
      final b = PlatformCapabilities.notification;
      expect(a, isNotNull);
      expect(identical(a, b), isTrue, reason: '同一平台内实现应缓存/单例');
      expect(PlatformCapabilities.sound, isNotNull);
      expect(PlatformCapabilities.fileLauncher, isNotNull);
      expect(PlatformCapabilities.fileDrop, isNotNull);
    });

    test('resetForTest 清除 override 与平台缓存（再次访问回到默认）', () {
      final fake = FakeNotification();
      PlatformCapabilities.notificationOverride = fake;
      PlatformCapabilities.resetForTest();
      expect(identical(PlatformCapabilities.notification, fake), isFalse);
    });
  });

  group('Q0-3 —— 通知闪烁/提示音接线（TaskbarNotifier 经能力抽象路由）', () {
    test('TaskbarNotifier.flash() → 注入的 notification.flash()（enabled）', () {
      final fake = FakeNotification();
      PlatformCapabilities.notificationOverride = fake;
      TaskbarNotifier.flash();
      expect(fake.flashCount, 1);
    });

    test('TaskbarNotifier.enabled=false → flash() 静默（既有语义保留）', () {
      final fake = FakeNotification();
      PlatformCapabilities.notificationOverride = fake;
      TaskbarNotifier.enabled = false;
      TaskbarNotifier.flash();
      expect(fake.flashCount, 0);
    });

    test('TaskbarNotifier.clearUrgency() → fake.clearUrgency()（不受 enabled 限制）',
        () {
      final fake = FakeNotification();
      PlatformCapabilities.notificationOverride = fake;
      TaskbarNotifier.enabled = false;
      TaskbarNotifier.clearUrgency();
      expect(fake.clearCount, 1, reason: '清除闪烁不受总开关限制（H1 语义）');
    });

    test('TaskbarNotifier.playSound() → 注入的 sound.playNotifySound()', () {
      final fake = FakeSound();
      PlatformCapabilities.soundOverride = fake;
      TaskbarNotifier.soundEnabled = true;
      TaskbarNotifier.playSound();
      expect(fake.playCount, 1);
    });

    test('Linux 默认链保留 setUrgencyImpl 注入点（阶段 K 测试兼容）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      PlatformCapabilities.resetForTest();
      var urgent = false;
      TaskbarNotifier.setUrgencyImpl = (v) => urgent = v;
      TaskbarNotifier.flash();
      expect(urgent, isTrue, reason: '未注入 override 时 Linux 默认实现走既有注入点');
      TaskbarNotifier.setUrgencyImpl = (_) {};
    });

    test('Linux 默认链保留 playSoundImpl 注入点（阶段 K 测试兼容）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      PlatformCapabilities.resetForTest();
      var played = false;
      TaskbarNotifier.playSoundImpl = () => played = true;
      TaskbarNotifier.soundEnabled = true;
      TaskbarNotifier.playSound();
      expect(played, isTrue);
      TaskbarNotifier.playSoundImpl = () {};
    });
  });

  group('Q0-3 —— 文件拖拽平台分支（桌面专属，移动不适用）', () {
    test('android → isSupported == false', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      PlatformCapabilities.resetForTest();
      expect(PlatformCapabilities.fileDrop.isSupported, isFalse);
    });

    test('ios → isSupported == false', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      PlatformCapabilities.resetForTest();
      expect(PlatformCapabilities.fileDrop.isSupported, isFalse);
    });

    test('linux → isSupported == true 且默认实现为 FileDrop.instance（GTK channel）',
        () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      PlatformCapabilities.resetForTest();
      expect(PlatformCapabilities.fileDrop.isSupported, isTrue);
      expect(
          identical(PlatformCapabilities.fileDrop, FileDrop.instance), isTrue,
          reason: 'Linux 拖拽逻辑原样保留（N3 契约），抽象只做分发');
    });

    test('windows → isSupported == true', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      PlatformCapabilities.resetForTest();
      expect(PlatformCapabilities.fileDrop.isSupported, isTrue);
    });

    test('macos → isSupported == true', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      PlatformCapabilities.resetForTest();
      expect(PlatformCapabilities.fileDrop.isSupported, isTrue);
    });

    test('注入 fake 后 ensureListening/setOnFilesDropped 透传', () {
      final fake = FakeDrop(true);
      PlatformCapabilities.fileDropOverride = fake;
      PlatformCapabilities.fileDrop.ensureListening();
      PlatformCapabilities.fileDrop
          .setOnFilesDropped((files) => fake.lastFiles = files);
      expect(fake.listenCount, 1);
    });
  });

  group('Q0-3 —— 默认实现安全降级（FLUTTER_TEST/无窗口环境不崩）', () {
    test(
        'android/ios：flash/clearUrgency/playNotifySound/openFile/openDirectory '
        '调用安全（应用内徽标语义，无 FFI/无子进程依赖崩溃）', () async {
      for (final platform in {TargetPlatform.android, TargetPlatform.iOS}) {
        debugDefaultTargetPlatformOverride = platform;
        PlatformCapabilities.resetForTest();
        expect(() => PlatformCapabilities.notification.flash(), returnsNormally,
            reason: '$platform 通知能力安全');
        expect(() => PlatformCapabilities.notification.clearUrgency(),
            returnsNormally,
            reason: '$platform 清除通知安全');
        await expectLater(
            PlatformCapabilities.sound.playNotifySound(), completes,
            reason: '$platform 提示音能力安全');
        await expectLater(
            PlatformCapabilities.fileLauncher.openFile('/nonexistent'),
            completes,
            reason: '$platform 打开文件安全降级');
        await expectLater(
            PlatformCapabilities.fileLauncher.openDirectory('/nonexistent'),
            completes);
      }
    });

    test('windows/macos：默认实现调用安全（子进程/通道缺失时静默降级）', () async {
      for (final platform in {TargetPlatform.windows, TargetPlatform.macOS}) {
        debugDefaultTargetPlatformOverride = platform;
        PlatformCapabilities.resetForTest();
        expect(() => PlatformCapabilities.notification.flash(), returnsNormally,
            reason: '$platform 通知能力安全');
        await expectLater(
            PlatformCapabilities.fileLauncher.openFile('/nonexistent'),
            completes,
            reason: '$platform 打开文件安全降级');
      }
    });

    test('linux：默认 flash/clearUrgency/playSound 调用安全（FFI 降级惯例）', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      PlatformCapabilities.resetForTest();
      expect(() => PlatformCapabilities.notification.flash(), returnsNormally);
      expect(() => PlatformCapabilities.notification.clearUrgency(),
          returnsNormally);
      await expectLater(
          PlatformCapabilities.sound.playNotifySound(), completes);
    });

    test('fileLauncher 契约：注入 fake 时路径透传与结果返回', () async {
      final fake = FakeLauncher()..result = true;
      PlatformCapabilities.fileLauncherOverride = fake;
      final ok = await PlatformCapabilities.fileLauncher.openFile('/tmp/a.txt');
      expect(ok, isTrue);
      expect(fake.lastFile, '/tmp/a.txt');
      final dirOk =
          await PlatformCapabilities.fileLauncher.openDirectory('/tmp/somedir');
      expect(dirOk, isTrue);
      expect(fake.lastDir, '/tmp/somedir');
    });
  });

  group('Q0-3 —— 打开文件 3 处 xdg-open 收敛（源码扫描锁定）', () {
    test('chat_screen.dart 不再直接调用 xdg-open（视频回退"使用系统播放器"）', () {
      final src = srcOf('screens/chat_screen.dart');
      expect(countOf(src, "Process.run('xdg-open'"), 0,
          reason: '原 chat_screen.dart:1455 迁入 fileLauncher 能力');
      expect(countOf(src, 'PlatformCapabilities.fileLauncher'),
          greaterThanOrEqualTo(1),
          reason: '打开文件走平台能力抽象');
    });

    test('dialogs.dart 不再直接调用 xdg-open（文件预览"打开文件/打开所在目录"）', () {
      final src = srcOf('widgets/dialogs.dart');
      expect(countOf(src, "Process.run('xdg-open'"), 0,
          reason: '原 dialogs.dart:3914/3921 迁入 fileLauncher 能力');
      expect(countOf(src, 'PlatformCapabilities.fileLauncher'),
          greaterThanOrEqualTo(1));
    });

    test('capabilities.dart 自身保留 Linux xdg-open 实现（行为等价迁移，非删除）', () {
      final src = srcOf('platform/capabilities.dart');
      expect(src.contains("xdg-open"), isTrue,
          reason: 'Linux 打开文件语义不变（仅收敛到能力层）');
    });
  });

  // ============================================================
  // Q1 真机反馈二轮 —— 混排 emoji 兜底按平台裁剪（"数字发黑"根因）
  //
  // Android 实测：气泡 fontFamilyFallback 含 emoji 字体时，ASCII
  // 数字/#/* 命中 emoji 字体内的键帽基字形（黑色）——显式 fontFamily
  // 也压不住（引擎对带 Emoji 属性码点优先尝试 fallback 链中的 emoji
  // 字体）。Android/iOS 系统链自带彩色 emoji，不挂显式兜底；Linux
  // 保留 R-P10/R-P26 显式栈（fontconfig 黑白字形问题）。
  // ============================================================
  group('Q1 二轮 —— emojiTextFallback 按平台裁剪', () {
    test('Linux：保留显式兜底栈（R-P10/R-P26 契约）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(emojiTextFallback(), AppConfig.emojiFontStack);
      debugDefaultTargetPlatformOverride = null;
    });

    test('Android/iOS：空栈（系统链自带彩字；防数字键帽黑字形）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(emojiTextFallback(), isEmpty);
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(emojiTextFallback(), isEmpty);
      debugDefaultTargetPlatformOverride = null;
    });

    test('Windows/macOS：空栈（系统链自带 Segoe UI Emoji / Apple Color Emoji）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(emojiTextFallback(), isEmpty);
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(emojiTextFallback(), isEmpty);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
