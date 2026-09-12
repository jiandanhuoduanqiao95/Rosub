// ============================================================
// android_system.dart 阶段 Q1 —— 真机反馈二轮系统集成契约
// ============================================================
// 覆盖 Q1 二轮问题4/5/5b/8 的 Dart 通道胶水（对端 MainActivity.kt）：
//
//   - startKeepAlive / stopKeepAlive（前台服务保活，问题4）；
//   - showMessageNotification（应用外通知横幅+震动+提示音，问题5）
//     / cancelMessageNotifications（回前台已读清除）；
//   - moveToBackground（返回键/侧滑根路由转后台，问题5b）；
//   - requestNotificationPermission（Android 13+ POST_NOTIFICATIONS）；
//   - getLastCrashLog / clearCrashLog（首开闪退排障面包屑，问题8）。
//
// 契约要点：非 Android 平台全部方法安全 no-op（零通道调用）；
// Android 平台经 MethodChannel('chatroom/platform') 调用且参数/返回
// 透传正确；通道异常静默降级（false/null）不阻塞调用方。
// ============================================================

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/platform/android_system.dart';

const MethodChannel _channel = MethodChannel('chatroom/platform');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'requestNotificationPermission':
          return true;
        case 'startKeepAlive':
          return true;
        case 'stopKeepAlive':
          return true;
        case 'getLastCrashLog':
          return 'time=1700000000000\njava.lang.RuntimeException: fake';
        case 'showMessageNotification':
          return true;
        case 'cancelMessageNotifications':
          return true;
        case 'moveToBackground':
          return true;
        case 'clearCrashLog':
          return true;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  group('Q1 二轮 —— Android 平台（通道调用与参数透传）', () {
    test('startKeepAlive / stopKeepAlive 经通道调用且透传结果', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(await AndroidSystem.startKeepAlive(), isTrue);
      expect(await AndroidSystem.stopKeepAlive(), isTrue);
      expect(calls.map((c) => c.method),
          containsAll(['startKeepAlive', 'stopKeepAlive']));
      debugDefaultTargetPlatformOverride = null;
    });

    test('showMessageNotification 透传 title/body（fire-and-forget）', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidSystem.showMessageNotification(title: 'bob', body: '在吗');
      await Future<void>.delayed(Duration.zero);
      final call =
          calls.firstWhere((c) => c.method == 'showMessageNotification');
      expect(call.arguments, {'title': 'bob', 'body': '在吗'});
      debugDefaultTargetPlatformOverride = null;
    });

    test('cancelMessageNotifications / moveToBackground 经通道调用', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidSystem.cancelMessageNotifications();
      AndroidSystem.moveToBackground();
      await Future<void>.delayed(Duration.zero);
      expect(calls.map((c) => c.method),
          containsAll(['cancelMessageNotifications', 'moveToBackground']));
      debugDefaultTargetPlatformOverride = null;
    });

    test('requestNotificationPermission 透传授权结果', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(await AndroidSystem.requestNotificationPermission(), isTrue);
      expect(calls.map((c) => c.method),
          contains('requestNotificationPermission'));
      debugDefaultTargetPlatformOverride = null;
    });

    test('getLastCrashLog / clearCrashLog（闪退排障面包屑）', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(await AndroidSystem.getLastCrashLog(),
          contains('java.lang.RuntimeException'));
      await AndroidSystem.clearCrashLog();
      expect(calls.map((c) => c.method), contains('clearCrashLog'));
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('Q1 二轮 —— 非 Android 平台（安全 no-op，零通道调用）', () {
    test('全部方法 no-op 且不触达通道', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(await AndroidSystem.startKeepAlive(), isFalse);
      expect(await AndroidSystem.stopKeepAlive(), isFalse);
      expect(await AndroidSystem.requestNotificationPermission(), isFalse);
      expect(await AndroidSystem.getLastCrashLog(), isNull);
      AndroidSystem.showMessageNotification(title: 'a', body: 'b');
      AndroidSystem.cancelMessageNotifications();
      AndroidSystem.moveToBackground();
      await Future<void>.delayed(Duration.zero);
      await AndroidSystem.clearCrashLog();
      expect(calls, isEmpty, reason: '平台门控在通道调用之前');
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('Q1 二轮 —— 通道异常静默降级', () {
    test('通道抛异常不传播（保活/权限/崩溃日志返回安全值）', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
        throw PlatformException(code: 'unavailable');
      });
      expect(await AndroidSystem.startKeepAlive(), isFalse);
      expect(await AndroidSystem.requestNotificationPermission(), isFalse);
      expect(await AndroidSystem.getLastCrashLog(), isNull);
      AndroidSystem.showMessageNotification(title: 'a', body: 'b');
      await Future<void>.delayed(Duration.zero);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
