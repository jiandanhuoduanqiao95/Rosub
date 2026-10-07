/// Android 系统集成（阶段 Q1 真机反馈二轮）
///
/// 按 §13.9 分支纪律的"按端适配器实现文件"：Android 专属系统集成
/// 收敛于此，经 MethodChannel('chatroom/platform')（对端 MainActivity.kt）：
///   - 前台服务保活（KeepAliveService，问题4）；
///   - 应用外新消息通知（横幅+震动+提示音，问题5）；
///   - 返回键/侧滑转后台（moveTaskToBack，问题5b）；
///   - 通知权限请求（Android 13+ POST_NOTIFICATIONS）；
///   - Java 层崩溃日志面包屑读取/清除（问题8 排障）。
///
/// 非 Android 平台全部方法为安全 no-op / false / null（调用点无需逐处
/// 平台判定，也可显式判定减少无谓通道调用）；平台判定走
/// [effectiveTargetPlatform]（§21.1 规约——测试可经 override 模拟）。
/// 通道缺失/异常一律静默降级，不阻塞消息处理管线。

import 'package:flutter/services.dart';

import 'capabilities.dart';

class AndroidSystem {
  AndroidSystem._();

  static const MethodChannel _channel = MethodChannel('chatroom/platform');

  static bool get _isAndroid =>
      effectiveTargetPlatform() == TargetPlatform.android;

  /// 请求通知权限（Android 13+ 系统弹窗；已授权/低版本直接 true）。
  /// 返回是否已获授权（用户当场选择的结果经 onRequestPermissionsResult
  /// 回传；拒绝后后续调用仍会再次弹系统窗，由系统管理"不再询问"）。
  static Future<bool> requestNotificationPermission() async {
    if (!_isAndroid) return false;
    try {
      return await _channel
              .invokeMethod<bool>('requestNotificationPermission') ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 阶段 R1：通话运行时权限——语音=RECORD_AUDIO，视频追加 CAMERA
  /// （全部授予才 true；拒绝时不发起通话）。非 Android 平台恒 true。
  static Future<bool> requestCallPermissions({required bool video}) async {
    if (!_isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('requestCallPermissions', {
            'video': video,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 启动前台服务保活（登录成功进入聊天页时调用；重复调用幂等）
  static Future<bool> startKeepAlive() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('startKeepAlive') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 停止前台服务（退出登录/离开聊天页时调用）
  static Future<bool> stopKeepAlive() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('stopKeepAlive') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// opt1 P5：启动通话专属前台服务（microphone|camera 型——Android 14+
  /// 熄屏/后台采集媒体的类型要求；通知"通话中"可点击回通话，P6）。
  /// 通话开始时调用（语音=video:false、视频=video:true），重复调用幂等。
  static Future<bool> startCallForeground({required bool video}) async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('startCallForeground', {
            'video': video,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// opt1 P5：停止通话前台服务（通话结束/teardown 时调用；未运行时 no-op）
  static Future<bool> stopCallForeground() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('stopCallForeground') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// opt1 P6：拉取并清除"通话通知点击"标志（MainActivity 通知
  /// contentIntent 携带 open_call=1，onCreate/onNewIntent 置位）。
  /// true = 用户点了"通话中"通知希望回到通话界面。
  static Future<bool> consumeOpenCallIntent() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('consumeOpenCallIntent') ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 应用外新消息通知（横幅 + 震动 + 提示音——通知渠道承载，
  /// 权限未授予时原生侧静默忽略）。fire-and-forget。
  static void showMessageNotification({
    required String title,
    required String body,
  }) {
    if (!_isAndroid) return;
    _channel.invokeMethod<bool>('showMessageNotification', {
      'title': title,
      'body': body,
    }).then((_) {}, onError: (_) {});
  }

  /// 消息通知渠道初始化（Q1 六轮问题3）：渠道提示音改用应用提示音
  /// ——客户端内外统一。Q1 八轮（问题2）：提示音固化为打包资源
  /// res/raw/notify_chime.wav（七轮 file:// 外部目录 Uri 在 OneUI 上
  /// SystemUI 读不到，只有震动无声）；渠道设置创建后不可变，原生侧
  /// 每次启动删除重建（幂等）。
  static Future<bool> setupMessageChannel() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('setupMessageChannel') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// opt1 P6：通话通知渠道初始化——删除重建为 IMPORTANCE_DEFAULT
  /// （LOW 在 vivo OriginOS 不展示通知卡片，"点通知回通话"入口失效）。
  /// **必须在应用启动路径（FGS 之外）调用**——FGS 运行中删除自己的
  /// 渠道被系统拒绝（SecurityException 进程崩溃，真机实锤）。
  static Future<bool> setupCallChannel() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('setupCallChannel') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 后台文件传输进度系统通知（Q1 七轮问题1：锁屏/后台传输对用户
  /// 可见）。进行中同 id 反复 notify 即原地更新进度条。fire-and-forget。
  static void showTransferNotification({
    required String title,
    required int progress,
  }) {
    if (!_isAndroid) return;
    _channel.invokeMethod<bool>('showTransferNotification', {
      'title': title,
      'progress': progress,
    }).then((_) {}, onError: (_) {});
  }

  /// 撤除后台传输进度通知（传输完成/失败后调用）
  static void cancelTransferNotification() {
    if (!_isAndroid) return;
    _channel
        .invokeMethod<bool>('cancelTransferNotification')
        .then((_) {}, onError: (_) {});
  }

  /// 系统分享面板导出文件（Q1 三轮问题6：Android 接收目录位于应用
  /// 内部存储，文件管理器不可见——分享是把文件交给其他应用/保存到
  /// 可见位置的唯一可靠通道；经 FileProvider 只读 URI）。fire-and-forget。
  static void shareFile(String path) {
    if (!_isAndroid) return;
    _channel.invokeMethod<bool>('shareFile', {'path': path}).then((_) {},
        onError: (_) {});
  }

  /// 清除应用外消息通知（回前台已读语义）
  static void cancelMessageNotifications() {
    if (!_isAndroid) return;
    _channel
        .invokeMethod<bool>('cancelMessageNotifications')
        .then((_) {}, onError: (_) {});
  }

  /// 返回键/侧滑在根路由时转后台（不 finish Activity——冷启动代价）
  static void moveToBackground() {
    if (!_isAndroid) return;
    _channel
        .invokeMethod<bool>('moveToBackground')
        .then((_) {}, onError: (_) {});
  }

  /// 上次 Java 层未捕获异常日志（无则 null）——"首开闪退"排障面包屑
  static Future<String?> getLastCrashLog() async {
    if (!_isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('getLastCrashLog');
    } catch (_) {
      return null;
    }
  }

  /// 清除崩溃日志（展示后调用）
  static Future<void> clearCrashLog() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('clearCrashLog');
    } catch (_) {}
  }
}
