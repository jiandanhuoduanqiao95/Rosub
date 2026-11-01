// ============================================================
// opt8 功能三 —— 窗口唤起能力（WindowActivationCapability）
// ============================================================
// 覆盖：CallPresentation.shouldBringDesktopCallToFront 矩阵（策略测试在
// call_notification_policy_opt8_test，此处测能力接线）、
// PlatformCapabilities.window 工厂按平台选择、windowOverride 测试注入
// 优先、resetForTest 清理。Linux runner FFI（chatroom_bring_to_front）与
// Windows user32 FFI 不做 flutter test（宿主进程无符号），归源码契约
// （call_native_contract_opt8_test）+ 手动矩阵。
// ============================================================

import 'dart:io';

import 'package:chatroom_flutter/platform/capabilities.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeWindow implements WindowActivationCapability {
  int bringToFrontCalls = 0;

  @override
  bool get isSupported => true;

  @override
  Future<void> bringToFront() async {
    bringToFrontCalls++;
  }
}

void main() {
  setUp(() {
    debugDefaultTargetPlatformOverride = null;
    PlatformCapabilities.resetForTest();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    PlatformCapabilities.resetForTest();
  });

  group('opt8 F3 —— window 工厂按平台选择', () {
    test('Linux → LinuxWindowActivationCapability（supported）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final window = PlatformCapabilities.window;
      expect(window, isA<LinuxWindowActivationCapability>());
      expect(window.isSupported, isTrue);
    });

    test('Windows → WindowsWindowActivationCapability（supported）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final window = PlatformCapabilities.window;
      expect(window, isA<WindowsWindowActivationCapability>());
      expect(window.isSupported, isTrue);
    });

    test('Android/iOS/macOS → stub（isSupported=false，来电走系统通知）',
        () {
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        final window = PlatformCapabilities.window;
        expect(window.isSupported, isFalse, reason: '$platform 不做窗口唤起');
        // stub bringToFront 为安全 no-op
        expect(window.bringToFront(), completes);
        PlatformCapabilities.resetForTest();
      }
    });

    test('缓存命中条件须校验 _window（源码锁定 + 平台切换行为验证）', () {
      // 复审修订：私有静态无法在测试内构造"部分能力先行初始化"状态，
      // 守卫回归用源码契约锁定（缓存命中条件必须同时查 _window != null
      // ——否则只初始化过其他能力的调用点会让 window getter 撞 null）；
      // 行为层以"换平台必须重解析"验证缓存键含平台。
      final src = File('lib/platform/capabilities.dart').readAsStringSync();
      final hitStart = src.indexOf('if (_resolvedPlatform == platform');
      expect(hitStart, greaterThanOrEqualTo(0));
      final hitBlock = src.substring(hitStart, src.indexOf('}', hitStart));
      expect(hitBlock, contains('_notification != null'));
      expect(hitBlock, contains('_window != null'),
          reason: '缓存命中守卫必须包含 _window 非空检查');

      // 行为验证：先以 android 解析（stub window），再切 linux——
      // 缓存键含平台，换平台必须重建而非复用 android 的 stub
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(PlatformCapabilities.window.isSupported, isFalse);
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(PlatformCapabilities.window.isSupported, isTrue,
          reason: '换平台后 window 必须按新平台重解析');
    });
  });

  group('opt8 F3 —— windowOverride 测试注入', () {
    test('注入 fake 优先于默认链，调用可达', () async {
      final fake = _FakeWindow();
      PlatformCapabilities.windowOverride = fake;
      await PlatformCapabilities.window.bringToFront();
      expect(fake.bringToFrontCalls, 1);
      PlatformCapabilities.resetForTest();
    });

    test('resetForTest 清除注入与缓存', () {
      PlatformCapabilities.windowOverride = _FakeWindow();
      PlatformCapabilities.resetForTest();
      expect(PlatformCapabilities.windowOverride, isNull);
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(PlatformCapabilities.window,
          isA<LinuxWindowActivationCapability>(),
          reason: '清除注入后回默认工厂');
    });
  });
}
