// ============================================================
// opt8 功能三 —— AndroidSystem 来电通道契约（call_intent 语义）
// ============================================================
// 覆盖 consumeCallIntent 的 open/action 映射、来电通知方法参数透传、
// 全屏权限查询、锁屏标志清除，以及非 Android 平台安全 no-op（零通道
// 调用）。对端 Kotlin：MainActivity.consumeCallIntent 返回
// {open: bool, action: 'accept'|'decline'|null}。
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
        case 'consumeCallIntent':
          return {'open': true, 'action': 'accept'};
        case 'hasFullScreenIntentPermission':
          return false;
        case 'showIncomingCallNotification':
        case 'cancelIncomingCallNotification':
        case 'clearCallLockFlags':
        case 'requestFullScreenIntentPermission':
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

  group('opt8 F3 —— consumeCallIntent 映射（Android）', () {
    test('open+action=accept → CallIntentResult(open, accept)', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final intent = await AndroidSystem.consumeCallIntent();
      expect(intent.open, isTrue);
      expect(intent.action, 'accept');
      expect(calls.map((c) => c.method), contains('consumeCallIntent'));
      debugDefaultTargetPlatformOverride = null;
    });

    test('action=decline / null 映射', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
        if (call.method == 'consumeCallIntent') {
          return {'open': true, 'action': 'decline'};
        }
        return null;
      });
      expect((await AndroidSystem.consumeCallIntent()).action, 'decline');

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
        if (call.method == 'consumeCallIntent') {
          return {'open': true, 'action': null};
        }
        return null;
      });
      final plain = await AndroidSystem.consumeCallIntent();
      expect(plain.open, isTrue);
      expect(plain.action, isNull, reason: '点通知本体=无 action，仅回通话界面');
      debugDefaultTargetPlatformOverride = null;
    });

    test('open=false / 通道返回异常 → open false 不抛', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
        if (call.method == 'consumeCallIntent') return null;
        return null;
      });
      final intent = await AndroidSystem.consumeCallIntent();
      expect(intent.open, isFalse);
      expect(intent.action, isNull);
      debugDefaultTargetPlatformOverride = null;
    });

    test('非 Android 平台：no-op 且零通道调用', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final intent = await AndroidSystem.consumeCallIntent();
      expect(intent.open, isFalse);
      expect(calls, isEmpty, reason: '非 Android 不得触达通道');
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('opt8 F3 —— 来电通知/全屏权限/锁屏标志（Android）', () {
    test('showIncomingCallNotification 透传 title/body', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await AndroidSystem.showIncomingCallNotification(
          title: 'bob', body: '邀请你语音通话');
      await Future<void>.delayed(Duration.zero);
      final call =
          calls.firstWhere((c) => c.method == 'showIncomingCallNotification');
      expect(call.arguments, {'title': 'bob', 'body': '邀请你语音通话'});
      debugDefaultTargetPlatformOverride = null;
    });

    test('cancelIncomingCallNotification / clearCallLockFlags 经通道调用',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await AndroidSystem.cancelIncomingCallNotification();
      await AndroidSystem.clearCallLockFlags();
      await Future<void>.delayed(Duration.zero);
      expect(calls.map((c) => c.method),
          containsAll(['cancelIncomingCallNotification', 'clearCallLockFlags']));
      debugDefaultTargetPlatformOverride = null;
    });

    test('hasFullScreenIntentPermission 透传（false=Android 14+ 未授权）',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(await AndroidSystem.hasFullScreenIntentPermission(), isFalse);
      await AndroidSystem.requestFullScreenIntentPermission();
      await Future<void>.delayed(Duration.zero);
      expect(calls.map((c) => c.method),
          contains('requestFullScreenIntentPermission'));
      debugDefaultTargetPlatformOverride = null;
    });

    test('非 Android：通知/权限/锁屏方法全部 no-op 零通道调用', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await AndroidSystem.showIncomingCallNotification(title: 'a', body: 'b');
      await AndroidSystem.cancelIncomingCallNotification();
      await AndroidSystem.clearCallLockFlags();
      expect(await AndroidSystem.hasFullScreenIntentPermission(), isTrue,
          reason: '桌面/非 Android 恒 true（无需授权）');
      await AndroidSystem.requestFullScreenIntentPermission();
      expect(calls, isEmpty);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
