/// 平台能力抽象（阶段 Q0-3 —— 各端差异收敛到统一接口；Q2 Windows 接入）
///
/// 通知闪烁 / 打开文件目录 / 文件拖拽 / 提示音 四类能力按平台分发：
///   - Linux：完整实现（FFI urgency / paplay-aplay / xdg-open /
///     GTK drag channel），行为与 Q0 之前完全一致（等价迁移）；
///   - Windows：完整实现（Q2 接入）——通知闪烁 = win32 FlashWindowEx
///     任务栏闪烁；提示音 = winmm PlaySoundW 复用生成式和弦 WAV；
///     打开文件 = DesktopFileLauncher（cmd /c start，Q0 已实现）；
///     拖拽 = runner 原生钩子（DragAcceptFiles/WM_DROPFILES →
///     chatroom/dnd 通道）与 Linux 同协议复用 FileDrop.instance；
///   - macOS：桌面语义占位（isSupported 分支已正确，Q3 接入
///     Dock bounce / afplay / desktop_drop 类方案）；
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
/// 兼容，行为不漂移）；Windows 提示音复用其生成式 chime WAV。

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
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

/// 独立成格纯 emoji 的主字体（R-P10 契约的平台分发）：COLRv1 内置字体
/// 仅 Linux 渲染可靠；Windows 文字引擎认领 COLRv1 字形但栅格化输出空白
/// （Q2 真机实测：网格空白带格轮廓、无 tofu 无异常），改用系统彩色
/// emoji 字体；macOS 同理（Q3 验证）。emojiTextFallback 为空栈的平台，
/// 缺字形时系统链自动兜底同款系统彩字。
String emojiPickerFontFamily() {
  switch (effectiveTargetPlatform()) {
    case TargetPlatform.windows:
      return 'Segoe UI Emoji';
    case TargetPlatform.macOS:
      return 'Apple Color Emoji';
    default:
      return 'NotoColorEmoji';
  }
}

/// 界面主字体（Q2 真机"中文字体渲染怪异"修复）：Flutter Windows 缺省
/// 主字体 Segoe UI 不含 CJK 字形，DirectWrite 兜底链会落到宋体等非预期
/// 字形（观感突兀）；显式指定微软雅黑 UI（zh-CN Windows 原生应用的
/// 标准 UI 字体，拉丁字形亦内置，全字体统一）。其余平台返回 null 维持
/// 引擎缺省（Linux fontconfig 链 / Android Roboto+系统 CJK 均为既有
/// 基线，勿顺手统一）。
String? uiFontFamily() {
  switch (effectiveTargetPlatform()) {
    case TargetPlatform.windows:
      return 'Microsoft YaHei UI';
    default:
      return null;
  }
}

/// 通知闪烁（未聚焦收新消息；替代系统弹窗通知）
abstract class NotificationCapability {
  void flash();
  void clearUrgency();
}

/// 新消息提示音 + 通话音效（gc8：来电铃声/挂断音——同一产品语言，
/// 音色由 TaskbarNotifier 生成式合成）
abstract class SoundCapability {
  Future<void> playNotifySound();

  /// 来电铃声单遍旋律（~1.5s；循环策略：Android 原生 looping /
  /// 桌面调用方 Timer 重播）
  Future<void> playCallRingtone();

  /// 挂断音（~0.7s 单次下行音）
  Future<void> playHangupSound();

  /// 停止来电铃声（Android 原生 MediaPlayer stop；桌面单次播放自然
  /// 结束，no-op）
  Future<void> stopCallRingtone();
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
        // 阶段 Q2 接入：
        //  · 通知/提示音 = win32 真实现（FlashWindowEx / PlaySoundW，见下）
        //  · 拖拽 = runner 原生钩子（flutter_window.cpp DragAcceptFiles /
        //    WM_DROPFILES → DragQueryFileW）经 'chatroom/dnd' 通道转发
        //    路径，Dart 侧与 Linux 同协议复用 FileDrop.instance 监听
        //  · 打开文件 = DesktopFileLauncher（cmd /c start，Q0 已实现）
        _notification = WindowsNotificationCapability();
        _sound = WindowsSoundCapability();
        _fileLauncher = DesktopFileLauncher(platform);
        _fileDrop = FileDrop.instance;
        break;
      case TargetPlatform.macOS:
        // Q3 接入 Dock bounce / afplay / desktop_drop 类方案
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

  @override
  Future<void> playCallRingtone() async =>
      _playCallWav(TaskbarNotifier.ensureCallRingtoneWav(), 'call ringtone');

  @override
  Future<void> playHangupSound() async =>
      _playCallWav(TaskbarNotifier.ensureHangupWav(), 'hangup');

  @override
  Future<void> stopCallRingtone() async {}

  Future<void> _playCallWav(String? path, String tag) async {
    if (path == null) return;
    try {
      final paplay = await Process.run('paplay', [path]);
      if (paplay.exitCode != 0) {
        await Process.run('aplay', ['-q', path]);
      }
    } catch (_) {}
  }
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
// Windows —— 完整实现（阶段 Q2 接入，替代 Q0 占位）
// ============================================================

/// Win32 FLASHWINFO（FlashWindowEx 参数结构；hwnd 按 C 对齐规则在 x64
/// 上 8 字节对齐，sizeOf 即 cbSize 应传值）
final class _Flashwinfo extends Struct {
  @Uint32()
  external int cbSize;
  @IntPtr()
  external int hwnd;
  @Uint32()
  external int dwFlags;
  @Uint32()
  external int uCount;
  @Uint32()
  external int dwTimeout;
}

typedef _FlashWindowExNative = Int32 Function(Pointer<_Flashwinfo>);
typedef _FlashWindowExDart = int Function(Pointer<_Flashwinfo>);
typedef _FindWindowNative = IntPtr Function(Pointer<Utf16>, Pointer<Utf16>);
typedef _FindWindowDart = int Function(Pointer<Utf16>, Pointer<Utf16>);
typedef _PlaySoundNative = Int32 Function(Pointer<Utf16>, IntPtr, Uint32);
typedef _PlaySoundDart = int Function(Pointer<Utf16>, int, int);

/// Windows 任务栏闪烁（win32 FlashWindowEx）。
///
/// 未聚焦收新消息时 FLASHW_ALL|FLASHW_TIMERNOFG 持续闪烁直至窗口回到
/// 前台（与 Linux urgency-hint 同语义）；窗口聚焦侧由 main.dart 的
/// FocusTracker → TaskbarNotifier.clearUrgency → 本实现 FLASHW_STOP
/// 双保险停止。窗口句柄经标准 runner 注册类名解析（win32_window.cpp
/// kWindowClassName，flutter create 默认不变）；user32.dll 缺失（非
/// Windows 宿主）或句柄不可得时静默降级（Q0-3 FFI 降级惯例）。
class WindowsNotificationCapability implements NotificationCapability {
  static const int _flashwStop = 0x0;
  static const int _flashwAll = 0x3;
  static const int _flashwTimerNofg = 0xC;

  static DynamicLibrary? _user32;

  DynamicLibrary? get _lib => _user32 ??= _open();

  static DynamicLibrary? _open() {
    try {
      return DynamicLibrary.open('user32.dll');
    } catch (_) {
      return null;
    }
  }

  int _resolveWindowHandle() {
    final lib = _lib;
    if (lib == null) return 0;
    try {
      final findWindow =
          lib.lookupFunction<_FindWindowNative, _FindWindowDart>('FindWindowW');
      final className = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
      final hwnd = findWindow(className, nullptr);
      calloc.free(className);
      return hwnd;
    } catch (_) {
      return 0;
    }
  }

  void _flash(int flags) {
    final lib = _lib;
    if (lib == null) return;
    try {
      final hwnd = _resolveWindowHandle();
      if (hwnd == 0) return;
      final flashWindowEx =
          lib.lookupFunction<_FlashWindowExNative, _FlashWindowExDart>(
              'FlashWindowEx');
      final info = calloc<_Flashwinfo>();
      info.ref
        ..cbSize = sizeOf<_Flashwinfo>()
        ..hwnd = hwnd
        ..dwFlags = flags
        ..uCount = 0
        ..dwTimeout = 0;
      flashWindowEx(info);
      calloc.free(info);
    } catch (_) {
      // 闪烁失败不影响消息处理管线
    }
  }

  @override
  void flash() => _flash(_flashwAll | _flashwTimerNofg);

  @override
  void clearUrgency() => _flash(_flashwStop);
}

/// Windows 提示音（winmm PlaySoundW）。
///
/// 复用生成式科技感和弦 WAV（TaskbarNotifier.ensureChimeWav——与 Linux
/// paplay 同一音色契约，勿替换为二进制资产）；SND_FILENAME|SND_ASYNC
/// fire-and-forget，重复提醒自然打断上一响；SND_NODEFAULT 防止系统
/// 默认提示音误响。winmm.dll 缺失或 WAV 生成失败时静默降级。
class WindowsSoundCapability implements SoundCapability {
  static const int _sndAsync = 0x0001;
  static const int _sndNodefault = 0x0002;
  static const int _sndFilename = 0x00020000;

  @override
  Future<void> playNotifySound() async =>
      _playWav(TaskbarNotifier.ensureChimeWav());

  @override
  Future<void> playCallRingtone() async =>
      _playWav(TaskbarNotifier.ensureCallRingtoneWav());

  @override
  Future<void> playHangupSound() async =>
      _playWav(TaskbarNotifier.ensureHangupWav());

  @override
  Future<void> stopCallRingtone() async {
    // PlaySoundW 单次播放自然结束；置 null 停掉可能进行的异步播放
    try {
      final lib = DynamicLibrary.open('winmm.dll');
      final playSound =
          lib.lookupFunction<_PlaySoundNative, _PlaySoundDart>('PlaySoundW');
      playSound(nullptr, 0, _sndNodefault);
    } catch (_) {}
  }

  Future<void> _playWav(String? wav) async {
    if (wav == null) return;
    DynamicLibrary? lib;
    try {
      lib = DynamicLibrary.open('winmm.dll');
    } catch (_) {
      return;
    }
    try {
      final playSound =
          lib.lookupFunction<_PlaySoundNative, _PlaySoundDart>('PlaySoundW');
      final path = wav.toNativeUtf16();
      playSound(path, 0, _sndFilename | _sndAsync | _sndNodefault);
      calloc.free(path);
    } catch (_) {
      // 播放失败不影响消息处理管线
    }
  }
}

// ============================================================
// macOS —— 桌面语义占位（Q3 接入 Dock bounce / afplay /
// desktop_drop 类方案）
// ============================================================

class DesktopNotificationStub implements NotificationCapability {
  @override
  void flash() {
    // Q3 macOS Dock bounce 接入后替换
  }

  @override
  void clearUrgency() {}
}

class DesktopSoundStub implements SoundCapability {
  @override
  Future<void> playNotifySound() async {
    // Q3：afplay 接入
  }

  @override
  Future<void> playCallRingtone() async {}

  @override
  Future<void> playHangupSound() async {}

  @override
  Future<void> stopCallRingtone() async {}
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
    // Q3：desktop_drop 类方案接入（MethodChannel 语义与 Linux/Windows 一致）
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

  @override
  Future<void> playCallRingtone() async {}

  @override
  Future<void> playHangupSound() async {}

  @override
  Future<void> stopCallRingtone() async {}
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
