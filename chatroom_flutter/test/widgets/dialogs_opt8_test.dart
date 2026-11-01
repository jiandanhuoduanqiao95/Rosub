// ============================================================
// opt8 功能二/三 —— 设置对话框通话权限入口（仅 Android 渲染）
// ============================================================
// 契约：
//   1) Android：设置对话框含"通话悬浮球"与"锁屏全屏来电"两个权限
//      瓦片（_CallPermissionTile），状态异步查询（授权→已开启 /
//      未授权→未开启+hint）；
//   2) 点"去开启"分别调用 requestOverlayPermission /
//      requestFullScreenIntentPermission（跳系统授权页）；
//   3) 非 Android（默认 Linux 宿主）：两个瓦片不渲染（dialogs_stage_k
//      既有设置对话框契约零回归的前提）。
// 驱动：dialog 通道 mock + debugDefaultTargetPlatformOverride（body 内
// 恢复——foundation invariant 在 tearDown 前检查）。
// ============================================================

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/widgets/dialogs.dart';

const MethodChannel _channel = MethodChannel('chatroom/platform');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];
  bool overlayGranted = false;
  bool fullscreenGranted = false;

  Future<void> installChannelMock() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'hasOverlayPermission':
          return overlayGranted;
        case 'hasFullScreenIntentPermission':
          return fullscreenGranted;
        case 'requestOverlayPermission':
        case 'requestFullScreenIntentPermission':
          return true;
        case 'isIgnoringBatteryOptimizations':
          return true;
      }
      return null;
    });
  }

  void uninstallChannelMock() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showSettingsDialog(context),
            child: const Text('OPEN'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 10));
  }

  setUp(() {
    calls.clear();
    overlayGranted = false;
    fullscreenGranted = false;
    debugDefaultTargetPlatformOverride = null;
  });

  tearDown(() {
    uninstallChannelMock();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android：两个权限瓦片渲染并显示未授权状态', (tester) async {
    await installChannelMock();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pumpSettings(tester);

    expect(find.text('通话悬浮球'), findsOneWidget);
    expect(find.text('锁屏全屏来电'), findsOneWidget);
    expect(find.textContaining('未开启——需要"显示在其他应用上层"'), findsOneWidget);
    expect(find.textContaining('未开启——锁屏来电仅显示横幅'), findsOneWidget,
        reason: '未授权态显示降级后果说明');
    expect(find.byKey(const Key('call_bubble_permission_entry')), findsOneWidget);
    expect(find.byKey(const Key('fullscreen_call_permission_entry')),
        findsOneWidget);

    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Android：授权后状态显示已开启（全屏瓦片无死按钮）', (tester) async {
    await installChannelMock();
    overlayGranted = true;
    fullscreenGranted = true;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pumpSettings(tester);

    expect(find.text('已开启'), findsNWidgets(2));
    // 复审修订：全屏通知权限在 Android 10~13 恒已授权且无对应系统页
    //（API 34 才有该 action）——授权态不显示入口按钮，避免"可点但无反应"
    expect(find.text('查看'), findsOneWidget,
        reason: '仅悬浮窗瓦片保留授权后"查看"入口（跳转全版本可用）');
    expect(find.byKey(const Key('fullscreen_call_permission_entry')),
        findsNothing);

    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('点"去开启"分别跳转对应系统授权页', (tester) async {
    await installChannelMock();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pumpSettings(tester);

    await tester.tap(find.byKey(const Key('call_bubble_permission_entry')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('fullscreen_call_permission_entry')));
    await tester.pump();
    // 瓦片点击后 600ms 延迟刷新（真实 Timer）——泵过防 pending
    await tester.pump(const Duration(milliseconds: 700));

    expect(calls.map((c) => c.method), containsAll(<String>[
      'requestOverlayPermission',
      'requestFullScreenIntentPermission',
    ]));

    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets('跳系统设置授权后返回 App（resumed）→ 状态自动刷新', (tester) async {
    await installChannelMock();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pumpSettings(tester);
    expect(find.textContaining('未开启'), findsNWidgets(2),
        reason: '初始两瓦片均未授权');

    // 用户在系统设置页完成两项授权（mock 状态翻转），返回 App
    overlayGranted = true;
    fullscreenGranted = true;
    WidgetsBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    WidgetsBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(find.textContaining('未开启'), findsNothing,
        reason: 'resumed 刷新是主机制（600ms 固定延迟查到的还是旧值）');
    expect(find.text('已开启'), findsNWidgets(2));

    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets('非 Android（Linux 宿主默认）：权限瓦片不渲染', (tester) async {
    await installChannelMock();
    await pumpSettings(tester);

    expect(find.text('通话悬浮球'), findsNothing);
    expect(find.text('锁屏全屏来电'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
