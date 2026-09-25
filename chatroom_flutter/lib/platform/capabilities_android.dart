/// Android 平台适配器实现（阶段 Q1-2 —— Q0-3 能力抽象的 Android 落地）
///
/// §13.9 分支纪律"按端一个文件的适配器实现"：Android 端四能力与
/// 通道接入收敛在本文件，共享工厂（capabilities.dart）android 分支
/// 仅接线。iOS/fuchsia 分支保持 capabilities.dart 中的 Mobile* 占位
/// （Q4 处理）。
///
/// 能力语义：
///   - 通知：应用内徽标（未读计数/提示音已由 AppState + TaskbarNotifier
///     通道驱动，能力层不重复触发；系统级弹窗通知恒不做——排除清单）；
///   - 提示音：复用 TaskbarNotifier 生成式 chime（ensureChimeWav），
///     经 'playNotifySound' 原生通道以**通知用途**播放——走通知音量
///     （Q1 四轮问题6：media_kit 媒体流随媒体音量归零静音，不合语义）；
///     测试环境（AutomatedTestWidgetsFlutterBinding）恒静默；
///   - 文件打开：MethodChannel('chatroom/platform') 'openFile' 经
///     MainActivity.kt Intent（FileProvider）打开——视频"使用系统
///     播放器"回退的移动端实现；openDirectory 在 Android 不做（Q1
///     四轮问题5 用户决策，导出走'分享'）；通道缺失安全降级 false；
///   - 拖拽：桌面专属，isSupported=false（§36.3 矩阵 ❌）。

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../services/taskbar_notifier.dart';
import 'capabilities.dart';

/// Dart 侧平台通道（对端：android/app/src/main/kotlin/.../MainActivity.kt；
/// 电池优化方法见 battery_optimization.dart，同一通道）
const MethodChannel platformChannel = MethodChannel('chatroom/platform');

/// 应用内徽标语义：未读徽标/提示音已由 AppState + TaskbarNotifier
/// 通道驱动，能力层不重复触发（系统级弹窗通知恒不做——排除清单）
class AndroidNotificationCapability implements NotificationCapability {
  @override
  void flash() {}

  @override
  void clearUrgency() {}
}

class AndroidSoundCapability implements SoundCapability {
  bool get _isTestEnv =>
      WidgetsBinding.instance.runtimeType.toString() ==
      'AutomatedTestWidgetsFlutterBinding';

  @override
  Future<void> playNotifySound() async {
    try {
      // 测试环境无原生媒体引擎（R-P21 按绑定类型判定的既有惯例），
      // 恒静默返回，保证单元/Widget 测试确定性
      if (_isTestEnv) {
        return;
      }
      final wav = TaskbarNotifier.ensureChimeWav();
      if (wav == null) return;
      // Q1 四轮（问题6）：经原生通道以通知用途播放（通知音量流）；
      // 通道失败静默降级（不回退媒体流播放）
      await platformChannel.invokeMethod<bool>(
        'playNotifySound',
        {'path': wav},
      );
    } catch (_) {}
  }

  @override
  Future<void> playCallRingtone() async {
    try {
      if (_isTestEnv) return;
      final wav = TaskbarNotifier.ensureCallRingtoneWav();
      if (wav == null) return;
      // gc8：来电铃声经原生通道循环播放（铃声用量流）；通道失败静默
      await platformChannel.invokeMethod<bool>(
        'playCallRingtone',
        {'path': wav},
      );
    } catch (_) {}
  }

  @override
  Future<void> playHangupSound() async {
    try {
      if (_isTestEnv) return;
      final wav = TaskbarNotifier.ensureHangupWav();
      if (wav == null) return;
      await platformChannel.invokeMethod<bool>(
        'playHangupSound',
        {'path': wav},
      );
    } catch (_) {}
  }

  @override
  Future<void> stopCallRingtone() async {
    try {
      if (_isTestEnv) return;
      await platformChannel.invokeMethod<bool>('stopCallSound');
    } catch (_) {}
  }
}

class AndroidFileLauncherCapability implements FileLauncherCapability {
  @override
  Future<bool> openFile(String path) async {
    try {
      return await platformChannel
              .invokeMethod<bool>('openFile', {'path': path}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Q1 四轮（问题5，用户决策）：Android 不做"打开所在目录"——接收
  /// 目录位于应用内部存储，文件管理器不可见，目录语义在移动端无意义；
  /// 文件导出统一走"分享"（shareFile 通道/预览弹层分享按钮）。
  @override
  Future<bool> openDirectory(String path) async => false;
}

class AndroidFileDropStub implements FileDropCapability {
  @override
  bool get isSupported => false;

  @override
  void ensureListening() {}

  @override
  void setOnFilesDropped(void Function(List<String> files)? handler) {}
}
