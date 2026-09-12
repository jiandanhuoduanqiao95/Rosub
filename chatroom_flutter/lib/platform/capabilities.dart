/// 平台能力抽象（阶段 Q0-3 —— 各端差异收敛到统一接口）
///
/// 通知闪烁 / 打开文件目录 / 文件拖拽 / 提示音 四类能力按平台分发：
///   - Linux：完整实现（FFI urgency / paplay-aplay / xdg-open /
///     GTK drag channel），行为与 Q0 之前完全一致（等价迁移）；
///   - Windows / macOS：桌面语义占位（isSupported 分支已正确，
///     具体实现按 §13.9 分期表在 Q2/Q3 接入 runner / desktop_drop
///     类方案 / afplay 等）；
///   - Android / iOS：应用内语义（系统级弹窗通知维持"不做"决策，
///     §13.6 排除清单；拖拽不适用 → isSupported=false）。
///
/// 测试注入：各 getter 优先返回 *Override 注入实例（仿
/// TaskbarNotifier.playSoundImpl 惯例）；默认实现按
/// [defaultTargetPlatform] 解析并缓存，resetForTest() 清除注入与
/// 缓存（平台模拟测试先 override 再 resetForTest）。
/// 平台判定用 Flutter 层 defaultTargetPlatform（widget 测试可驱动）。
///
/// 本文件与 taskbar_notifier.dart 存在受控循环引用：Linux 默认链
/// 复用其 setUrgencyImpl / playSoundImpl 既有注入点（阶段 K 测试
/// 兼容，行为不漂移）。

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../config.dart';
import '../services/file_drop.dart';
import '../services/taskbar_notifier.dart';
import 'capabilities_android.dart';

/// 生效平台判定（Q0 平台分发的统一入口）：
/// 显式 [debugDefaultTargetPlatformOverride] 优先——widget 测试经它模拟
/// 目标平台断言分支接线（TESTING_GUIDE_FLUTTER.md §21.1）；无 override
/// 时回退 dart:io Platform 真实判定——生产语义正确，且 Linux 开发机的
/// flutter test 环境（defaultTargetPlatform 恒被 flutter_test 置为
/// android）与既有 Linux 测试基线行为一致（与 SocketService.deviceId
/// 同模式）。
TargetPlatform effectiveTargetPlatform() {
  final override = debugDefaultTargetPlatformOverride;
  if (override != null) return override;
  if (Platform.isAndroid) return TargetPlatform.android;
  if (Platform.isIOS) return TargetPlatform.iOS;
  if (Platform.isWindows) return TargetPlatform.windows;
  if (Platform.isMacOS) return TargetPlatform.macOS;
  return TargetPlatform.linux;
}

/// media_kit 视频渲染策略（阶段 Q1-3）：R-P8 软件渲染契约仅限 Linux
/// （虚拟机/llvmpipe/部分驱动下默认 H/W 路径"建成功但帧不上屏"，
/// 有声无画）；其余平台恢复默认硬解（真机硬件正常且省电）。
/// 判定与 [effectiveTargetPlatform] 同源——widget 测试可经
/// debugDefaultTargetPlatformOverride 模拟平台分支（§21.1 规约）。
bool videoSoftwareRendering() =>
    effectiveTargetPlatform() == TargetPlatform.linux;

/// 混排文本的 emoji 兜底字体栈（Q1 真机反馈二轮"数字发黑"修订）：
///
/// - Linux：必须显式兜底 [AppConfig.emojiFontStack]（R-P10/R-P26 契约——
///   fontconfig 默认兜底会命中 DejaVu/Noto Symbols 黑白字形）；
/// - Android / iOS：**空栈**——系统字体链自带彩色 emoji（Skia 自动
///   系统兜底）；显式把 emoji 字体放进 fontFamilyFallback 反而会让
///   ASCII 数字/#/* 命中 emoji 字体内的键帽基字形（黑色）——"蓝气泡
///   数字发黑"两轮实测根因（显式 fontFamily 也压不住，引擎对带
///   Emoji 属性的码点优先尝试 fallback 链中的 emoji 字体）；
/// - Windows / macOS：空栈（系统链自带 Segoe UI Emoji / Apple Color
///   Emoji；Q2/Q3 若实测缺字再补显式栈）。
///
/// 独立成格的纯 emoji 文本（表情网格/回应盘）仍用 fontFamily 打头
/// （R-P10 原契约，纯 emoji 无数字混排问题）。
List<String> emojiTextFallback() {
  switch (effectiveTargetPlatform()) {
    case TargetPlatform.linux:
      return AppConfig.emojiFontStack;
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.windows:
    case TargetPlatform.macOS:
    case TargetPlatform.fuchsia:
      return const [];
  }
}

/// 通知闪烁（未聚焦收新消息；替代系统弹窗通知）
abstract class NotificationCapability {
  void flash();
  void clearUrgency();
}

/// 新消息提示音
abstract class SoundCapability {
  Future<void> playNotifySound();
}

/// 用系统默认程序打开文件 / 所在目录
abstract class FileLauncherCapability {
  Future<bool> openFile(String path);
  Future<bool> openDirectory(String path);
}

/// 文件拖拽接收（桌面专属；移动端不适用）
abstract class FileDropCapability {
  bool get isSupported;
  void ensureListening();
  void setOnFilesDropped(void Function(List<String> files)? handler);
}

class PlatformCapabilities {
  PlatformCapabilities._();

  // ---- 测试注入点（优先级高于一切默认链） ----

  static NotificationCapability? notificationOverride;
  static SoundCapability? soundOverride;
  static FileLauncherCapability? fileLauncherOverride;
  static FileDropCapability? fileDropOverride;

  static TargetPlatform? _resolvedPlatform;
  static NotificationCapability? _notification;
  static SoundCapability? _sound;
  static FileLauncherCapability? _fileLauncher;
  static FileDropCapability? _fileDrop;

  static NotificationCapability get notification {
    if (notificationOverride != null) return notificationOverride!;
    _resolve();
    return _notification!;
  }

  static SoundCapability get sound {
    if (soundOverride != null) return soundOverride!;
    _resolve();
    return _sound!;
  }

  static FileLauncherCapability get fileLauncher {
    if (fileLauncherOverride != null) return fileLauncherOverride!;
    _resolve();
    return _fileLauncher!;
  }

  static FileDropCapability get fileDrop {
    if (fileDropOverride != null) return fileDropOverride!;
    _resolve();
    return _fileDrop!;
  }

  static PlatformCapabilities _resolve() {
    final platform = effectiveTargetPlatform();
    if (_resolvedPlatform == platform && _notification != null) {
      return _instance;
    }
    _resolvedPlatform = platform;
    switch (platform) {
      case TargetPlatform.linux:
        _notification = LinuxNotificationCapability();
        _sound = LinuxSoundCapability();
        _fileLauncher = LinuxFileLauncherCapability();
        _fileDrop = FileDrop.instance;
        break;
      case TargetPlatform.windows:
      case TargetPlatform.macOS:
        _notification = DesktopNotificationStub();
        _sound = DesktopSoundStub();
        _fileLauncher = DesktopFileLauncher(platform);
        _fileDrop = DesktopFileDropStub();
        break;
      case TargetPlatform.android:
        // 阶段 Q1-2：Android 端接入按端适配器实现
        // （capabilities_android.dart，按端拆文件的分支纪律）
        _notification = AndroidNotificationCapability();
        _sound = AndroidSoundCapability();
        _fileLauncher = AndroidFileLauncherCapability();
        _fileDrop = AndroidFileDropStub();
        break;
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        _notification = MobileNotificationCapability();
        _sound = MobileSoundCapability();
        _fileLauncher = MobileFileLauncher();
        _fileDrop = MobileFileDropStub();
        break;
    }
    return _instance;
  }

  static final PlatformCapabilities _instance = PlatformCapabilities._();

  static void resetForTest() {
    notificationOverride = null;
    soundOverride = null;
    fileLauncherOverride = null;
    fileDropOverride = null;
    _resolvedPlatform = null;
    _notification = null;
    _sound = null;
    _fileLauncher = null;
    _fileDrop = null;
  }
}

// ============================================================
// Linux —— 完整实现（现状等价迁移）
// ============================================================

class LinuxNotificationCapability implements NotificationCapability {
  @override
  void flash() => TaskbarNotifier.setUrgencyImpl(true);

  @override
  void clearUrgency() => TaskbarNotifier.setUrgencyImpl(false);
}

class LinuxSoundCapability implements SoundCapability {
  @override
  Future<void> playNotifySound() async => TaskbarNotifier.playSoundImpl();
}

class LinuxFileLauncherCapability implements FileLauncherCapability {
  @override
  Future<bool> openFile(String path) => _open(path);

  @override
  Future<bool> openDirectory(String path) => _open(path);

  Future<bool> _open(String path) async {
    try {
      final result = await Process.run('xdg-open', [path]);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}

// FileDrop（GTK drag channel）直接 implements FileDropCapability，
// 工厂在 Linux 返回 FileDrop.instance——既有逻辑零改动。

// ============================================================
// Windows / macOS —— 桌面语义占位（Q2/Q3 接入具体实现）
// ============================================================

class DesktopNotificationStub implements NotificationCapability {
  @override
  void flash() {
    // Q2 Windows 任务栏闪烁 / Q3 macOS Dock bounce 接入 runner 后替换
  }

  @override
  void clearUrgency() {}
}

class DesktopSoundStub implements SoundCapability {
  @override
  Future<void> playNotifySound() async {
    // Q2/Q3：afplay（macOS）/ PowerShell 播放（Windows）接入
  }
}

class DesktopFileLauncher implements FileLauncherCapability {
  DesktopFileLauncher(this.platform);
  final TargetPlatform platform;

  @override
  Future<bool> openFile(String path) => _open(path);

  @override
  Future<bool> openDirectory(String path) => _open(path);

  Future<bool> _open(String path) async {
    try {
      final result = platform == TargetPlatform.macOS
          ? await Process.run('open', [path])
          : await Process.run('cmd', ['/c', 'start', '', path]);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}

class DesktopFileDropStub implements FileDropCapability {
  @override
  bool get isSupported => true;

  @override
  void ensureListening() {
    // Q2/Q3：desktop_drop 类方案接入（MethodChannel 语义与 Linux 一致）
  }

  @override
  void setOnFilesDropped(void Function(List<String> files)? handler) {}
}

// ============================================================
// Android / iOS —— 应用内语义（Q1/Q4 深度适配）
// ============================================================

class MobileNotificationCapability implements NotificationCapability {
  @override
  void flash() {
    // 应用内徽标语义：未读计数/提示音已由 AppState + TaskbarNotifier
    // 通道覆盖；系统级弹窗通知恒不做（排除清单）
  }

  @override
  void clearUrgency() {}
}

class MobileSoundCapability implements SoundCapability {
  @override
  Future<void> playNotifySound() async {
    // Q1：平台播放器接入（生成式 WAV 复用，media/audioplayer 通道）
  }
}

class MobileFileLauncher implements FileLauncherCapability {
  @override
  Future<bool> openFile(String path) async {
    // Q1：open_file 类 platform channel 接入
    return false;
  }

  @override
  Future<bool> openDirectory(String path) async => false;
}

class MobileFileDropStub implements FileDropCapability {
  @override
  bool get isSupported => false;

  @override
  void ensureListening() {}

  @override
  void setOnFilesDropped(void Function(List<String> files)? handler) {}
}
