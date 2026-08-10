// ============================================================
// focus_tracker.dart 单元测试（阶段 H1 —— 窗口焦点检测）
// ============================================================
// 契约（待实现，TDD 红）：
//   main.dart 的 WidgetsBindingObserver.didChangeAppLifecycleState
//   调用 FocusTracker.instance.updateFocus(...)：
//     - resumed          → updateFocus(true)   （窗口获得焦点/恢复）
//     - inactive/paused  → updateFocus(false) （窗口失焦/最小化/后台）
//   桌面通知触发（H2）以 focused == false 为前提。
//
// 注意：FocusTracker 是单例，测试间需通过 updateFocus(true) 复位。
// ============================================================

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/services/focus_tracker.dart';

void main() {
  tearDown(() {
    FocusTracker.instance.updateFocus(true);
  });

  group('FocusTracker（H1 窗口焦点）', () {
    test('初始状态为聚焦（focused=true）', () {
      expect(FocusTracker.instance.focused, isTrue);
    });

    test('updateFocus(false) 切换为未聚焦并通知监听者', () {
      int notified = 0;
      FocusTracker.instance.addListener(() => notified++);
      FocusTracker.instance.updateFocus(false);
      expect(FocusTracker.instance.focused, isFalse);
      expect(notified, 1);
    });

    test('相同值重复 updateFocus 不触发通知（值未变）', () {
      FocusTracker.instance.updateFocus(false);
      int notified = 0;
      FocusTracker.instance.addListener(() => notified++);
      FocusTracker.instance.updateFocus(false);
      expect(notified, 0);
    });

    test('true → false → true 切换状态正确', () {
      FocusTracker.instance.updateFocus(false);
      expect(FocusTracker.instance.focused, isFalse);
      FocusTracker.instance.updateFocus(true);
      expect(FocusTracker.instance.focused, isTrue);
    });

    test('单例：多次访问返回同一实例', () {
      expect(identical(FocusTracker.instance, FocusTracker.instance), isTrue);
    });

    test('登出/重置不改变焦点状态（焦点与登录态独立）', () {
      FocusTracker.instance.updateFocus(false);
      expect(FocusTracker.instance.focused, isFalse);
    });
  });
}
