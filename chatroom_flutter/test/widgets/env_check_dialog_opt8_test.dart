// ============================================================
// opt8 —— 运行环境自检引导（进聊天页一次性；Android）
// ============================================================
// 契约：
//   1) 仅 Android 触发；三项状态"无法判定"(null) 恒不弹（桌面/通道缺失/
//      测试环境安全默认——既有 ChatScreen 测试零扰动的前提）；
//   2) 任一项"确凿缺失"(false) → 弹自检对话框，逐行展示
//      通知权限 / 电池优化白名单 / 通话悬浮球 + vivo 指引（应用信息页）；
//   3) 各"去开启"按钮分别调用 requestNotificationPermission /
//      requestIgnoreBatteryOptimizations / requestOverlayPermission /
//      openAppDetailsSettings；
//   4) 全部就绪 → 不弹；"稍后再说"/"完成"关闭 → dismissed 持久化
//      （env_check_dismissed，本次安装不再弹）。
// ============================================================

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chatroom_flutter/platform/battery_optimization.dart';
import 'package:chatroom_flutter/widgets/dialogs.dart';

const MethodChannel _channel = MethodChannel('chatroom/platform');

class _FakeBattery implements BatteryOptimizationCapability {
  bool? ignoring;
  @override
  Future<bool?> isIgnoring() async => ignoring;
  @override
  Future<bool> openSettings() async => true;
  @override
  Future<bool> requestIgnore() async => true;
}

Future<void> pumpTrigger(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (ctx) => Center(
          child: TextButton(
            onPressed: () => maybeShowEnvironmentCheckDialog(ctx),
            child: const Text('TRIGGER'),
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];

  void useAndroid() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    BatteryOptimization.resetForTest();
  }

  /// 通道 mock：三项状态可配置；未显式配置的方法返回 null（无法判定）
  void installChannelMock({
    bool? notifications,
    bool? overlay,
  }) {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'areNotificationsEnabled':
          return notifications;
        case 'hasOverlayPermission':
          return overlay;
        case 'isIgnoringBatteryOptimizations':
          return null; // 电池态走 BatteryOptimization.override
        case 'requestNotificationPermission':
        case 'requestIgnoreBatteryOptimizations':
        case 'openAppDetailsSettings':
        case 'requestOverlayPermission':
          return true;
      }
      return null;
    });
  }

  setUp(() {
    debugDefaultTargetPlatformOverride = null;
    BatteryOptimization.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    debugDefaultTargetPlatformOverride = null;
    BatteryOptimization.resetForTest();
  });

  testWidgets('全部就绪 → 不弹', (tester) async {
    useAndroid();
    BatteryOptimization.override = _FakeBattery()..ignoring = true;
    installChannelMock(notifications: true, overlay: true);
    await pumpTrigger(tester);
    await tester.tap(find.text('TRIGGER'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('运行环境自检'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('任一确凿缺失(false) → 弹自检（缺什么行有什么）', (tester) async {
    useAndroid();
    BatteryOptimization.override = _FakeBattery()..ignoring = false;
    installChannelMock(notifications: true, overlay: false);
    await pumpTrigger(tester);
    await tester.tap(find.text('TRIGGER'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('运行环境自检'), findsOneWidget);
    expect(find.text('通知权限'), findsOneWidget, reason: '已开启的行也展示（状态可见）');
    expect(find.text('电池优化白名单'), findsOneWidget);
    expect(find.text('通话悬浮球'), findsOneWidget);
    expect(find.textContaining('自启动'), findsWidgets, reason: 'vivo 指引文案');
    expect(find.byKey(const Key('env_check_notification')), findsNothing,
        reason: '已开启行无按钮');
    expect(find.byKey(const Key('env_check_battery')), findsOneWidget);
    expect(find.byKey(const Key('env_check_overlay')), findsOneWidget);
    expect(find.byKey(const Key('env_check_app_info')), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('各项"去开启"调用对应通道方法', (tester) async {
    useAndroid();
    BatteryOptimization.override = _FakeBattery()..ignoring = false;
    installChannelMock(notifications: false, overlay: false);
    await pumpTrigger(tester);
    await tester.tap(find.text('TRIGGER'));
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('env_check_notification')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('env_check_battery')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('env_check_overlay')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('env_check_app_info')));
    // 各按钮 600ms 兜底刷新（真实 Timer）——泵过防 pending
    await tester.pump(const Duration(milliseconds: 700));

    expect(calls.map((c) => c.method), containsAll(<String>[
      'requestNotificationPermission',
      'requestIgnoreBatteryOptimizations',
      'requestOverlayPermission',
      'openAppDetailsSettings',
    ]));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('"稍后再说"关闭 → dismissed 持久化（本次安装不再弹）', (tester) async {
    useAndroid();
    BatteryOptimization.override = _FakeBattery()..ignoring = false;
    installChannelMock(notifications: false, overlay: true);
    await pumpTrigger(tester);
    await tester.tap(find.text('TRIGGER'));
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.text('稍后再说'));
    await tester.pumpAndSettle();
    expect(
        (await SharedPreferences.getInstance()).getBool('env_check_dismissed'),
        isTrue);

    // 再次触发（TRIGGER 按钮仍在）→ 不弹
    await tester.tap(find.text('TRIGGER'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('运行环境自检'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('状态"无法判定"(null) 恒不弹（安全默认）', (tester) async {
    useAndroid();
    BatteryOptimization.override = _FakeBattery()..ignoring = null;
    installChannelMock(notifications: null, overlay: null);
    await pumpTrigger(tester);
    await tester.tap(find.text('TRIGGER'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('运行环境自检'), findsNothing,
        reason: '桌面/通道缺失/测试环境的安全默认——既有 ChatScreen 测试零扰动');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('非 Android（linux）→ 永不弹', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    BatteryOptimization.resetForTest();
    await pumpTrigger(tester);
    await tester.tap(find.text('TRIGGER'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('运行环境自检'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}
