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

  /// 通知权限当前是否已开启；null = 无法判定（非 Android/通道缺失——
  /// 运行环境自检以"确凿缺失(false)才弹"为语义，null 恒不弹）
  static Future<bool?> areNotificationsEnabled() async {
    if (!_isAndroid) return null;
    try {
      return await _channel.invokeMethod<bool>('areNotificationsEnabled');
    } catch (_) {
      return null;
    }
  }

  /// 直弹系统"忽略电池优化"确认框（一键允许；对端已白名单时不弹直接
  /// true）。 fire-and-forget 语义（结果以 isIgnoring 复查为准）。
  static Future<void> requestIgnoreBatteryOptimizations() async {
    if (!_isAndroid) return;
    try {
      await _channel
          .invokeMethod<bool>('requestIgnoreBatteryOptimizations');
    } catch (_) {}
  }

  /// 打开系统"应用信息"页（vivo 自启动/后台高耗电开关的可靠落点——
  /// 厂商无公开跳转接口，应用信息页含这些入口）
  static Future<void> openAppDetailsSettings() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('openAppDetailsSettings');
    } catch (_) {}
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

  // ============================================================
  // opt8 功能三：后台来电弹出（系统来电通知 + full-screen intent）
  // ============================================================

  /// 来电通知（振铃且 App 不在前台时调用；标题/正文由 CallPresentation
  /// 计算后传入，原生不重复拼文案）。锁屏 full-screen intent / 解锁
  /// heads-up；通知带"接听/拒绝"action（经 MainActivity 拉起 App 后由
  /// consumeCallIntent 消费）。Android 13+ 通知权限未授予时原生侧静默。
  static Future<void> showIncomingCallNotification({
    required String title,
    required String body,
  }) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('showIncomingCallNotification', {
        'title': title,
        'body': body,
      });
    } catch (_) {}
  }

  /// 撤除来电通知（接听/拒绝/超时/主叫取消/其他设备接听/回前台等收敛点）
  static Future<void> cancelIncomingCallNotification() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('cancelIncomingCallNotification');
    } catch (_) {}
  }

  /// 拉取并清除来电通知意图（open_call + action）。
  /// [CallIntentResult.action] = 'accept' | 'decline' | null（null=点通知
  /// 本体，仅回通话界面）。
  static Future<CallIntentResult> consumeCallIntent() async {
    if (!_isAndroid) return const CallIntentResult(open: false);
    try {
      final raw = await _channel
          .invokeMethod<Map<Object?, Object?>>('consumeCallIntent');
      return CallIntentResult(
        open: raw?['open'] == true,
        action: raw?['action'] is String ? raw!['action'] as String : null,
      );
    } catch (_) {
      return const CallIntentResult(open: false);
    }
  }

  /// Android 14+ 全屏通知权限是否已授予（低版本恒 true——无需授权）
  static Future<bool> hasFullScreenIntentPermission() async {
    if (!_isAndroid) return true;
    try {
      return await _channel
              .invokeMethod<bool>('hasFullScreenIntentPermission') ??
          true;
    } catch (_) {
      return true;
    }
  }

  /// 跳转系统"全屏通知"授权设置页（Android 14+；低版本/失败静默）
  static Future<void> requestFullScreenIntentPermission() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('requestFullScreenIntentPermission');
    } catch (_) {}
  }

  /// 清除锁屏显示标志（通话结束/非来电启动路径；避免普通启动覆盖锁屏）
  static Future<void> clearCallLockFlags() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('clearCallLockFlags');
    } catch (_) {}
  }

  // ============================================================
  // opt8 功能二：Android 通话悬浮球（CallForegroundService overlay）
  // ============================================================

  /// 是否已授予"显示在其他应用上层"（SYSTEM_ALERT_WINDOW 特殊权限，
  /// 只能跳系统设置授予）。null = 无法判定（非 Android/通道缺失）——
  /// 运行环境自检以"确凿缺失(false)才弹"为语义，null 恒不弹；
  /// 与 areNotificationsEnabled 同一可空语义（勿改回 ?? false 强转，
  /// 会把"查不到"当成"未授权"误弹引导）。
  static Future<bool?> hasOverlayPermission() async {
    if (!_isAndroid) return null;
    try {
      return await _channel.invokeMethod<bool>('hasOverlayPermission');
    } catch (_) {
      return null;
    }
  }

  /// 跳转系统悬浮窗授权设置页（无返回值语义；用户手动开启/关闭）
  static Future<void> requestOverlayPermission() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('requestOverlayPermission');
    } catch (_) {}
  }

  /// 显示通话悬浮球（仅 isInLiveCall 时调用；video 必传——气泡 action
  /// 不得把进行中的视频 FGS 降级成纯 microphone 类型）
  static Future<void> showCallBubble({required bool video}) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('showCallBubble', {'video': video});
    } catch (_) {}
  }

  /// 隐藏通话悬浮球（通话结束/回前台/dispose 时调用；video 语义同上）
  static Future<void> hideCallBubble({required bool video}) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('hideCallBubble', {'video': video});
    } catch (_) {}
  }
}

/// opt8 功能三：来电通知意图解析结果
class CallIntentResult {
  const CallIntentResult({required this.open, this.action});

  final bool open;

  /// 'accept' | 'decline' | null（null=点通知本体，仅回通话界面）
  final String? action;
}
