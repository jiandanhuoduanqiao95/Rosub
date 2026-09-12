// ============================================================
// 电池优化白名单引导契约（阶段 Q1-4 —— TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 Q「Q1 Android」要点：
// "电池优化白名单引导（OneUI/OriginOS 深度休眠杀后台）"。产品语义
// （§13.9 风险清单）：引导用户把应用加入电池优化白名单；未加白名单
// 时后台仅离线可读（本地缓存，阶段 L3）+ 前台连接收消息（Q0-5 生命
// 周期接线负责回前台重连）。
//
// 契约：新增 lib/platform/battery_optimization.dart ——
//
//   abstract class BatteryOptimizationCapability {
//     Future<bool?> isIgnoring();   // 是否已在电池优化白名单；null = 无法判定
//     Future<bool> openSettings();  // 跳转电池优化设置页；false = 失败/不适用
//   }
//
//   class AndroidBatteryOptimization          // MethodChannel('chatroom/platform')
//     · 'isIgnoringBatteryOptimizations' → bool；通道缺失 → null（安全降级）
//     · 'openBatteryOptimizationSettings' → bool；通道缺失 → false
//
//   class UnsupportedBatteryOptimization      // 桌面/非 Android
//     · isIgnoring() → null；openSettings() → false（桌面不适用语义）
//
//   class BatteryOptimization {
//     static BatteryOptimizationCapability? override; // 测试注入（仿 *Override 惯例）
//     static BatteryOptimizationCapability get instance; // 按 effectiveTargetPlatform 分发
//     static void resetForTest();
//   }
//
//   Future<void> maybeShowBatteryOptimizationGuide(BuildContext context)
//     · 仅 Android 且 isIgnoring() == false 且本次安装未提醒过 → 弹引导
//       对话框（文案含"电池优化"；动作"去设置"/"暂不"）；
//     · "去设置" → openSettings()；"暂不" → 仅关闭；两个出口均持久化
//       dismissed（SharedPreferences 布尔键 'battery_guide_dismissed'，
//       本次安装不再提醒）；
//     · isIgnoring() == true（已白名单）或 null（无法判定/桌面/通道
//       缺失）→ 不弹；
//     · SharedPreferences 访问异常按"未提醒过"处理（不崩）。
//
//   接线（源码扫描锁定）：chat_screen.dart 进入聊天页时调用
//   maybeShowBatteryOptimizationGuide（桌面天然不弹）。
//
//   MainActivity.kt 通道对端（openBatteryOptimizationSettings 等）的
//   存在性归 android_build_stage_q1_test.dart；Kotlin 行为不做单测
//   （§21.1 原生层），真机效果归手动矩阵 §36.3。
//
// 实现前：battery_optimization.dart 不存在，本文件编译失败，属 TDD 红。
// 实现后：全部转绿。
// ============================================================

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chatroom_flutter/platform/battery_optimization.dart';

class FakeBattery implements BatteryOptimizationCapability {
  bool? ignoring;
  int openCount = 0;
  @override
  Future<bool?> isIgnoring() async => ignoring;
  @override
  Future<bool> openSettings() async {
    openCount++;
    return true;
  }
}

String srcOf(String relPath) => File('lib/$relPath').readAsStringSync();

int countOf(String source, String needle) => source.split(needle).length - 1;

/// 平台模拟 wrapper：override 在 testWidgets body 内恢复（§21.8 规约，
/// foundation invariant 检查先于 tearDown）
void testWidgetsOnPlatform(String description, TargetPlatform? platform,
    Future<void> Function(WidgetTester tester) body) {
  testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

const MethodChannel platformChannel = MethodChannel('chatroom/platform');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    BatteryOptimization.resetForTest();
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platformChannel, null);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });
  tearDown(() {
    BatteryOptimization.resetForTest();
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platformChannel, null);
  });

  void useAndroid() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    BatteryOptimization.resetForTest();
  }

  group('Q1-4 —— 能力契约（通道 + 平台分发 + 注入）', () {
    test('lib/platform/battery_optimization.dart 存在', () {
      expect(
          File('lib/platform/battery_optimization.dart').existsSync(), isTrue);
    });

    test('override 注入后 instance 返回同一实例', () {
      final fake = FakeBattery();
      BatteryOptimization.override = fake;
      expect(identical(BatteryOptimization.instance, fake), isTrue);
    });

    test('resetForTest 清除注入（回到按平台默认链）', () {
      final fake = FakeBattery();
      BatteryOptimization.override = fake;
      BatteryOptimization.resetForTest();
      expect(identical(BatteryOptimization.instance, fake), isFalse);
    });

    test('android → instance is AndroidBatteryOptimization', () {
      useAndroid();
      expect(BatteryOptimization.instance, isA<AndroidBatteryOptimization>());
    });

    test(
        '桌面平台（linux/windows/macOS）→ 不适用语义：isIgnoring null、'
        'openSettings false', () async {
      for (final platform in {
        TargetPlatform.linux,
        TargetPlatform.windows,
        TargetPlatform.macOS,
      }) {
        debugDefaultTargetPlatformOverride = platform;
        BatteryOptimization.resetForTest();
        expect(await BatteryOptimization.instance.isIgnoring(), isNull,
            reason: '$platform 无法判定=不弹引导的前提');
        expect(await BatteryOptimization.instance.openSettings(), isFalse,
            reason: '$platform 无电池优化设置可跳');
      }
    });

    test("通道 'isIgnoringBatteryOptimizations' 返回 true → isIgnoring true",
        () async {
      useAndroid();
      MethodCall? received;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platformChannel, (call) async {
        received = call;
        return true;
      });
      expect(await BatteryOptimization.instance.isIgnoring(), isTrue);
      expect(received!.method, 'isIgnoringBatteryOptimizations');
    });

    test("通道 'isIgnoringBatteryOptimizations' 返回 false → isIgnoring false",
        () async {
      useAndroid();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platformChannel, (call) async => false);
      expect(await BatteryOptimization.instance.isIgnoring(), isFalse);
    });

    test('通道缺失（无原生对端）→ isIgnoring null（安全降级，不得崩）', () async {
      useAndroid();
      expect(await BatteryOptimization.instance.isIgnoring(), isNull);
    });

    test("openSettings：通道 'openBatteryOptimizationSettings' true → true",
        () async {
      useAndroid();
      MethodCall? received;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platformChannel, (call) async {
        received = call;
        return true;
      });
      expect(await BatteryOptimization.instance.openSettings(), isTrue);
      expect(received!.method, 'openBatteryOptimizationSettings');
    });

    test('openSettings：通道 false / 缺失 → false（失败不崩）', () async {
      useAndroid();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platformChannel, (call) async => false);
      expect(await BatteryOptimization.instance.openSettings(), isFalse);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platformChannel, null);
      expect(await BatteryOptimization.instance.openSettings(), isFalse);
    });
  });

  group('Q1-4 —— 引导 UI（一次性提醒 + 双出口持久化）', () {
    Future<void> pumpTrigger(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () => maybeShowBatteryOptimizationGuide(ctx),
                child: const Text('TRIGGER'),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgetsOnPlatform(
        '未白名单 + 未提醒过 → 弹出引导对话框（含"电池优化"文案与两出口）', TargetPlatform.android,
        (tester) async {
      BatteryOptimization.resetForTest();
      final fake = FakeBattery()..ignoring = false;
      BatteryOptimization.override = fake;
      await pumpTrigger(tester);

      await tester.tap(find.text('TRIGGER'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.textContaining('电池优化'), findsWidgets,
          reason: '引导文案出现（OneUI/OriginOS 深度休眠杀后台背景说明）');
      expect(find.text('去设置'), findsOneWidget);
      expect(find.text('暂不'), findsOneWidget);
    });

    testWidgetsOnPlatform('"去设置" → openSettings 恰 1 次 + dismissed 持久化 + 弹窗关闭',
        TargetPlatform.android, (tester) async {
      BatteryOptimization.resetForTest();
      final fake = FakeBattery()..ignoring = false;
      BatteryOptimization.override = fake;
      await pumpTrigger(tester);
      await tester.tap(find.text('TRIGGER'));
      await tester.pump();
      await tester.pumpAndSettle();

      await tester.tap(find.text('去设置'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(fake.openCount, 1, reason: '跳转电池优化设置恰一次');
      expect(find.textContaining('电池优化'), findsNothing, reason: '弹窗已关闭');
      expect(
          (await SharedPreferences.getInstance())
              .getBool('battery_guide_dismissed'),
          isTrue,
          reason: '提醒过即持久化（本次安装不再弹）');
    });

    testWidgetsOnPlatform(
        '"暂不" → 不调 openSettings + dismissed 持久化', TargetPlatform.android,
        (tester) async {
      BatteryOptimization.resetForTest();
      final fake = FakeBattery()..ignoring = false;
      BatteryOptimization.override = fake;
      await pumpTrigger(tester);
      await tester.tap(find.text('TRIGGER'));
      await tester.pump();
      await tester.pumpAndSettle();

      await tester.tap(find.text('暂不'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(fake.openCount, 0, reason: '"暂不"不跳设置');
      expect(
          (await SharedPreferences.getInstance())
              .getBool('battery_guide_dismissed'),
          isTrue);
      expect(find.textContaining('电池优化'), findsNothing);
    });

    testWidgetsOnPlatform(
        '已提醒过（dismissed=true）→ 不再弹（即使仍未白名单）', TargetPlatform.android,
        (tester) async {
      BatteryOptimization.resetForTest();
      SharedPreferences.setMockInitialValues(
          <String, Object>{'battery_guide_dismissed': true});
      final fake = FakeBattery()..ignoring = false;
      BatteryOptimization.override = fake;
      await pumpTrigger(tester);

      await tester.tap(find.text('TRIGGER'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.textContaining('电池优化'), findsNothing);
      expect(find.text('去设置'), findsNothing);
    });

    testWidgetsOnPlatform('已白名单（isIgnoring=true）→ 不弹', TargetPlatform.android,
        (tester) async {
      BatteryOptimization.resetForTest();
      final fake = FakeBattery()..ignoring = true;
      BatteryOptimization.override = fake;
      await pumpTrigger(tester);

      await tester.tap(find.text('TRIGGER'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.textContaining('电池优化'), findsNothing);
    });

    testWidgetsOnPlatform(
        '无法判定（isIgnoring=null，通道缺失等）→ 不弹（安全默认）', TargetPlatform.android,
        (tester) async {
      BatteryOptimization.resetForTest();
      final fake = FakeBattery()..ignoring = null;
      BatteryOptimization.override = fake;
      await pumpTrigger(tester);

      await tester.tap(find.text('TRIGGER'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.textContaining('电池优化'), findsNothing,
          reason: 'null 恒不弹——桌面/通道缺失环境的安全默认');
    });

    testWidgetsOnPlatform(
        'linux 桌面 → 永不弹（Unsupported 链路）', TargetPlatform.linux, (tester) async {
      BatteryOptimization.resetForTest();
      await pumpTrigger(tester);

      await tester.tap(find.text('TRIGGER'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.textContaining('电池优化'), findsNothing,
          reason: '桌面无电池优化语义（Q0-D 手动清单回归）');
    });
  });

  group('Q1-4 —— ChatScreen 接线（源码扫描）', () {
    test('chat_screen.dart 进入聊天页时接线引导（maybeShowBatteryOptimizationGuide）', () {
      final src = srcOf('screens/chat_screen.dart');
      expect(countOf(src, 'maybeShowBatteryOptimizationGuide'),
          greaterThanOrEqualTo(1),
          reason: 'ChatScreen initState（postFrame）触发引导检查；桌面天然不弹');
    });
  });
}
