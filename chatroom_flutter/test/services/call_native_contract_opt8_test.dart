// ============================================================
// opt8 —— 原生层源码契约（来电通知 / 桌面唤起 / 悬浮球）
// ============================================================
// 原生通知/悬浮窗/全屏 Intent/窗口唤起不做 flutter test（宿主进程无
// 符号与系统服务），以源码扫描锁定关键实现点（TESTING_GUIDE_FLUTTER
// §21 惯例；flutter test CWD 即包根，直接 File 读取）。
// ============================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String srcOf(String relPath) => File(relPath).readAsStringSync();

int countOf(String source, String needle) => source.split(needle).length - 1;

void main() {
  group('opt8 F3 —— AndroidManifest 权限契约', () {
    test('含 USE_FULL_SCREEN_INTENT（锁屏全屏来电页）', () {
      expect(srcOf('android/app/src/main/AndroidManifest.xml'),
          contains('android.permission.USE_FULL_SCREEN_INTENT'));
    });

    test('含 SYSTEM_ALERT_WINDOW（功能二悬浮球 overlay）', () {
      expect(srcOf('android/app/src/main/AndroidManifest.xml'),
          contains('android.permission.SYSTEM_ALERT_WINDOW'));
    });

    test('opt8 自检：REQUEST_IGNORE_BATTERY_OPTIMIZATIONS（电池直弹框前置）',
        () {
      expect(srcOf('android/app/src/main/AndroidManifest.xml'),
          contains('android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS'));
    });

    test('既有红线权限仍在（ACCESS_NETWORK_STATE / FGS 类型）', () {
      final manifest = srcOf('android/app/src/main/AndroidManifest.xml');
      expect(manifest, contains('android.permission.ACCESS_NETWORK_STATE'),
          reason: 'R1 接听闪退真根因权限，勿移除');
      expect(manifest, contains('FOREGROUND_SERVICE_MICROPHONE'));
      expect(manifest, contains('FOREGROUND_SERVICE_CAMERA'));
    });
  });

  group('opt8 F3 —— IncomingCallNotifier.kt 来电通知契约', () {
    test('独立渠道 chatroom_incoming_call_v1 + 通知 id 1004', () {
      final src = srcOf(
          'android/app/src/main/kotlin/com/example/chatroom_flutter/'
          'IncomingCallNotifier.kt');
      expect(src, contains('chatroom_incoming_call_v1'));
      expect(src, contains('NOTIF_ID = 1004'));
    });

    test('heads-up 必需项：IMPORTANCE_HIGH + CATEGORY_CALL + PRIORITY_MAX',
        () {
      final src = srcOf(
          'android/app/src/main/kotlin/com/example/chatroom_flutter/'
          'IncomingCallNotifier.kt');
      expect(src, contains('IMPORTANCE_HIGH'));
      expect(src, contains('CATEGORY_CALL'));
      expect(src, contains('PRIORITY_MAX'));
      expect(src, contains('setFullScreenIntent'));
    });

    test('铃声不挂通知渠道（Dart 循环播放防双响）+ 无震动（用户决策）', () {
      final src = srcOf(
          'android/app/src/main/kotlin/com/example/chatroom_flutter/'
          'IncomingCallNotifier.kt');
      expect(src, contains('setSound(null, null)'));
      expect(src, contains('enableVibration(false)'));
    });

    test('接听/拒绝 action（PendingIntent 携 call_action）+ 全屏 intent',
        () {
      final src = srcOf(
          'android/app/src/main/kotlin/com/example/chatroom_flutter/'
          'IncomingCallNotifier.kt');
      expect(src, contains('EXTRA_CALL_ACTION'));
      expect(src, contains('"accept"'));
      expect(src, contains('"decline"'));
      expect(src, contains('EXTRA_CALL_LOCKSCREEN'));
      expect(src, contains('VISIBILITY_PUBLIC'));
      expect(src, contains('setTimeoutAfter'),
          reason: '原生 45s 兜底（Dart 30s 先撤）');
    });

    test('勿设 largeIcon（gc17 vivo 重复徽标）', () {
      final src = srcOf(
          'android/app/src/main/kotlin/com/example/chatroom_flutter/'
          'IncomingCallNotifier.kt');
      expect(src.contains('setLargeIcon'), isFalse,
          reason: 'gc17 结论：vivo 通知模板 largeIcon 重复徽标');
    });

    test('Android 13+ 通知权限未授予静默返回（不崩溃）', () {
      final src = srcOf(
          'android/app/src/main/kotlin/com/example/chatroom_flutter/'
          'IncomingCallNotifier.kt');
      expect(src, contains('POST_NOTIFICATIONS'));
      expect(src, contains('ensureChannel'),
          reason: 'create-if-absent 兜底（FGS 运行中禁 delete 渠道）');
      expect(src.contains('deleteNotificationChannel('), isFalse,
          reason: '来电通知辅助类禁止删渠道（opt1 SecurityException 教训）');
    });
  });

  group('opt8 F3 —— MainActivity.kt 意图处理契约', () {
    final src = srcOf(
        'android/app/src/main/kotlin/com/example/chatroom_flutter/'
        'MainActivity.kt');

    test('onCreate 与 onNewIntent 都走统一 handleCallIntent（分体断言）', () {
      // 复审修订：同一句 contains 写两遍证明不了两处都接了——
      // 分别截取两个函数体断言
      final onCreateStart = src.indexOf('override fun onCreate');
      final onNewIntentStart = src.indexOf('override fun onNewIntent');
      final handleStart = src.indexOf('private fun handleCallIntent');
      expect(onCreateStart, greaterThanOrEqualTo(0));
      expect(onNewIntentStart, greaterThan(onCreateStart),
          reason: 'onNewIntent 紧随 onCreate（函数体切片边界）');
      expect(handleStart, greaterThan(onNewIntentStart));
      expect(
        src.substring(onCreateStart, onNewIntentStart),
        contains('handleCallIntent(intent)'),
        reason: 'onCreate（冷启动）处理来电意图',
      );
      expect(
        src.substring(onNewIntentStart, handleStart),
        contains('handleCallIntent(intent)'),
        reason: 'onNewIntent（进程存活）处理来电意图',
      );
    });

    test('pendingCallAction 消费 + open_call + 锁屏 extra', () {
      expect(src, contains('pendingCallAction'));
      expect(src, contains('consumeCallIntent'));
      expect(src, contains('EXTRA_CALL_ACTION = "call_action"'));
      expect(src, contains('EXTRA_CALL_LOCKSCREEN = "call_lockscreen"'));
    });

    test('锁屏显示：setShowWhenLocked + setTurnScreenOn + 清除通道方法', () {
      expect(src, contains('setShowWhenLocked'));
      expect(src, contains('setTurnScreenOn'));
      expect(src, contains('clearCallLockFlags'));
    });

    test('opt8 自检通道方法（通知态/电池直弹/应用信息页）', () {
      expect(src, contains('areNotificationsEnabled'));
      expect(src, contains('requestIgnoreBatteryOptimizations'));
      expect(src, contains('ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS'));
      expect(src, contains('openAppDetailsSettings'));
      expect(src, contains('ACTION_APPLICATION_DETAILS_SETTINGS'));
    });

    test('全屏权限查询/跳转通道方法（API 34 判定，勿降回 Q）', () {
      expect(src, contains('canUseFullScreenIntent'));
      expect(src, contains('hasFullScreenIntentPermission'));
      expect(src, contains('ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT'));
      // 复审修订：ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT 为 API 34 才
      // 存在——Q(API 29) 判定在 Android 10~13 抛 ActivityNotFoundException
      // 被吞成 false，按钮看似可点实则无跳转
      expect(src, contains('Build.VERSION_CODES.UPSIDE_DOWN_CAKE'));
      expect(src.contains('VERSION_CODES.Q'), isFalse,
          reason: '全屏 intent 授权跳转必须按 API 34 判定');
    });

    test('来电渠道启动路径创建（setupCallChannel 内 ensureChannel）', () {
      expect(src, contains('IncomingCallNotifier.ensureChannel(this)'));
      expect(src.contains('"setupIncomingCallChannel"'), isFalse,
          reason: '复审清理：无 Dart 调用点的死通道方法已删除');
    });

    test('既有 consumeOpenCallIntent 通道保留且同步清 action（opt1 兼容）',
        () {
      expect(src, contains('consumeOpenCallIntent'));
      final consumeStart = src.indexOf('"consumeOpenCallIntent"');
      final nextHandler = src.indexOf('showMessageNotification', consumeStart);
      final consumeBody = src.substring(consumeStart, nextHandler);
      expect(consumeBody, contains('pendingCallAction = null'),
          reason: '兼容通道须与 consumeCallIntent 同步清 action——'
              '残留过期 action 会误触发后续 accept/decline');
    });
  });

  group('opt8 F3 —— Linux runner 桌面唤起契约', () {
    test('chatroom_bring_to_front 导出（deiconify + present + urgency 兜底）',
        () {
      final src = srcOf('linux/runner/my_application.cc');
      expect(src, contains('chatroom_bring_to_front'));
      expect(src, contains('gtk_window_present'));
      expect(src, contains('gtk_window_deiconify'));
      expect(src, contains('g_idle_add'));
      expect(src, contains('gtk_window_set_urgency_hint'));
    });

    test('-Wl,--export-dynamic 不可删（H2 约定：Dart FFI 查找符号）', () {
      expect(srcOf('linux/runner/CMakeLists.txt'),
          contains('--export-dynamic'));
    });
  });

  group('opt8 F3 —— Windows 窗口唤起 FFI 契约', () {
    test('user32 唤起链：FindWindowW/IsIconic/ShowWindow/SetWindowPos/'
        'SetForegroundWindow/FlashWindowEx 兜底', () {
      final src = srcOf('lib/platform/capabilities.dart');
      expect(src, contains('WindowActivationCapability'));
      expect(src, contains("'FindWindowW'"));
      expect(src, contains("'IsIconic'"));
      expect(src, contains("'ShowWindow'"));
      expect(src, contains("'SetWindowPos'"));
      expect(src, contains("'SetForegroundWindow'"));
      expect(src, contains('FlashWindowEx'),
          reason: '前台锁拒绝时任务栏闪烁兜底');
      expect(src, contains('_swRestore'),
          reason: '最小化先 SW_RESTORE(9) 恢复');
      expect(src.contains("'AttachThreadInput'"), isFalse,
          reason: '禁用侵入式抢焦点手段（系统行为尊重）');
    });
  });

  group('opt8 F2 —— 悬浮球原生契约（CallForegroundService）', () {
    final svcSrc = srcOf(
        'android/app/src/main/kotlin/com/example/chatroom_flutter/'
        'CallForegroundService.kt');

    test('overlay 窗口类型与 flags（TYPE_APPLICATION_OVERLAY / NOT_FOCUSABLE）',
        () {
      expect(svcSrc, contains('TYPE_APPLICATION_OVERLAY'));
      expect(svcSrc, contains('FLAG_NOT_FOCUSABLE'));
      expect(svcSrc, contains('FLAG_NOT_TOUCH_MODAL'));
      expect(svcSrc, contains('Settings.canDrawOverlays'),
          reason: '权限未授予时不显示球、不崩溃');
    });

    test('显隐 action + startForegroundService/startService 分流', () {
      expect(svcSrc, contains('ACTION_SHOW_BUBBLE'));
      expect(svcSrc, contains('ACTION_HIDE_BUBBLE'));
      expect(svcSrc, contains('startForegroundService(intent)'),
          reason: 'show 服务不在时以 FGS 语义拉起');
      expect(svcSrc, contains('context.startService(intent)'),
          reason: 'hide 用 startService（勿无意义 FGS 启动）');
    });

    test('FGS 升级语义（P0 复审）：普通启动恒 startAsForeground，'
        'ensureForeground 仅限 SHOW_BUBBLE', () {
      expect(svcSrc, contains('foregroundStarted'));
      // onStartCommand 函数体切片（到 ensureForeground 定义为止）
      final cmdStart = svcSrc.indexOf('override fun onStartCommand');
      final ensureStart = svcSrc.indexOf('private fun ensureForeground');
      expect(cmdStart, greaterThanOrEqualTo(0));
      expect(ensureStart, greaterThan(cmdStart));
      final onStart = svcSrc.substring(cmdStart, ensureStart);

      // 普通启动路径必须每次 startAsForeground(video)——允许 specialUse
      // 降级态在 RECORD_AUDIO 授权后升级回 microphone|camera（opt5 语义；
      // ensureForeground 单次门控会让首次授权后的 FGS 永停 specialUse，
      // 熄屏/退后台采集被切断）
      final normalStart = onStart.indexOf('// 普通启动');
      expect(normalStart, greaterThan(0));
      expect(onStart.substring(normalStart), contains('startAsForeground(video)'));
      expect(onStart.substring(normalStart), isNot(contains('ensureForeground')),
          reason: '普通路径不得走单次门控');

      // SHOW 分支允许 ensureForeground（免重复 startForeground）
      final showStart = onStart.indexOf('ACTION_SHOW_BUBBLE');
      final hideStart = onStart.indexOf('ACTION_HIDE_BUBBLE');
      expect(showStart, greaterThanOrEqualTo(0));
      expect(hideStart, greaterThan(showStart));
      expect(onStart.substring(showStart, hideStart),
          contains('ensureForeground(video)'));

      // HIDE 分支禁 ensureForeground/startForeground（P1：隐藏一个可能
      // 不存在的球不得拉起"通话中"幽灵 FGS），服务非前台时撤场
      final hideBranch = onStart.substring(hideStart, normalStart);
      expect(hideBranch.contains('ensureForeground'), isFalse);
      expect(hideBranch.contains('startForeground'), isFalse);
      expect(hideBranch, contains('stopSelf()'));
      expect(hideBranch, contains('START_NOT_STICKY'));
    });

    test('startAsForeground 三条成功路径置位 foregroundStarted（SecurityException 不崩）',
        () {
      // API<34 与 API34+ 两条 startForeground 路径均收敛在
      // startAsForeground 内且成功后置位 foregroundStarted
      expect(countOf(svcSrc, 'startForeground(NOTIF_ID'), 2);
      expect(countOf(svcSrc, 'foregroundStarted = true'), 3,
          reason: '三条成功路径（<34 / 34+ 权限型 / 34+ specialUse）都置位');
      expect(svcSrc, contains('foregroundStarted = false'),
          reason: 'onDestroy 复位（服务重建后可再次就位）');
    });

    test('拖动 touch slop 点击判定 + open_call 回通话 + 边界 clamp', () {
      expect(svcSrc, contains('scaledTouchSlop'));
      expect(svcSrc, contains('EXTRA_OPEN_CALL'),
          reason: '球点击经 open_call 链路回通话（P6 同一恢复语义）');
      expect(svcSrc, contains('coerceIn'), reason: '边界 clamp 不跑出屏幕');
      expect(svcSrc, contains('updateViewLayout'));
      expect(svcSrc, contains('onConfigurationChanged'),
          reason: '旋转/分屏重新 clamp');
    });

    test('清理：onDestroy 移除球 + onTaskRemoved 隐藏球并撤场 + 撤来电通知',
        () {
      expect(svcSrc, contains('onDestroy'));
      expect(svcSrc, contains('onTaskRemoved'));
      expect(svcSrc, contains('hideBubble()'));
      expect(svcSrc, contains('IncomingCallNotifier.cancel(this)'),
          reason: '任务划掉时撤除来电通知（防进程存活期的幽灵通知窗口）');
      expect(svcSrc, contains('stopSelf()'));
    });

    test('悬浮球图标矢量资源存在（勿用自适应图标位图——gc16 教训）', () {
      final icon = srcOf(
          'android/app/src/main/res/drawable/ic_call_bubble.xml');
      expect(icon, contains('<vector'));
      expect(icon, contains('#FFFFFFFF'));
    });

    test('位置 clamp 感知系统栏（status_bar_height/navigation_bar_height）', () {
      expect(svcSrc, contains('status_bar_height'),
          reason: '避开状态栏（F2-04 不遮挡系统栏关键区域）');
      expect(svcSrc, contains('navigation_bar_height'),
          reason: '避开手势导航区');
      expect(svcSrc, contains('clampBubble'),
          reason: '初始位/拖动/旋转三处共用同一 clamp（勿散落三份实现）');
      expect(countOf(svcSrc, 'clampBubble('), greaterThanOrEqualTo(4),
          reason: '1 处定义 + 初始位/拖动/旋转 3 处调用');
    });

    test('设置页两个权限瓦片（悬浮球 + 锁屏全屏来电，仅 Android 渲染）', () {
      final dialogs = srcOf('lib/widgets/dialogs.dart');
      expect(dialogs, contains('_CallPermissionTile'),
          reason: 'opt8 打磨：通用权限瓦片（悬浮球/全屏来电共用）');
      expect(dialogs, contains('hasOverlayPermission'));
      expect(dialogs, contains('requestOverlayPermission'));
      expect(dialogs, contains('hasFullScreenIntentPermission'),
          reason: 'F3-13"设置页可跳转授权"的 UI 入口');
      expect(dialogs, contains('requestFullScreenIntentPermission'));
      expect(dialogs, contains("TargetPlatform.android"),
          reason: '入口仅 Android 渲染');
      expect(dialogs, contains('fullscreen_call_permission_entry'));
      expect(dialogs, contains('call_bubble_permission_entry'));
    });
  });

  group('opt8 —— Dart 侧契约', () {
    test('ChatScreen 接线：来电通知/意图消费/悬浮球/桌面唤起', () {
      final src = srcOf('lib/screens/chat_screen.dart');
      expect(src, contains('_syncIncomingNotification'));
      expect(src, contains('_handleCallIntent'));
      expect(src, contains('_syncSystemBubble'));
      expect(src, contains('bringToFront'));
      expect(src, contains('clearCallLockFlags'));
      expect(src, contains('shouldBringDesktopCallToFront'));
    });

    test('AndroidSystem 暴露 opt8 新通道方法', () {
      final src = srcOf('lib/platform/android_system.dart');
      for (final method in [
        'areNotificationsEnabled',
        'requestIgnoreBatteryOptimizations',
        'openAppDetailsSettings',
        'showIncomingCallNotification',
        'cancelIncomingCallNotification',
        'consumeCallIntent',
        'hasFullScreenIntentPermission',
        'requestFullScreenIntentPermission',
        'clearCallLockFlags',
        'hasOverlayPermission',
        'requestOverlayPermission',
        'showCallBubble',
        'hideCallBubble',
      ]) {
        expect(src, contains(method), reason: 'AndroidSystem 缺少 $method');
      }
      expect(src, contains('class CallIntentResult'));
    });

    test('统一接听入口（通话页与通知 action 共用文案）', () {
      final callScreen = srcOf('lib/screens/call_screen.dart');
      expect(callScreen, contains('acceptIncomingCallFlow'));
      expect(callScreen, contains('需要麦克风/摄像头权限才能接听'));
      expect(srcOf('lib/screens/chat_screen.dart'),
          contains('acceptIncomingCallFlow'));
    });
  });
}
