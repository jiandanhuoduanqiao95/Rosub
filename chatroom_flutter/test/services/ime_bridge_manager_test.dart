// ============================================================
// ime_bridge.dart 纯逻辑安全测试（测试强化新增）
// ============================================================
// ImeBridgeManager 依赖真实子进程（Python GTK），本文件只验证
// 不触发的纯逻辑路径与"无进程"下的安全行为：
//   - owner 状态机：setActiveOwner / isActiveOwner / releaseOwner
//   - 监听器注册/注销（含重复注册）
//   - 无进程时的 grabFocus / releaseFocus / shutdown / setText 空操作
//
// 注意：本文件刻意不调用 ensureStarted 的等待路径（会探测 python3），
// 只验证进程不存在（_process == null）时的安全降级行为。
// ============================================================

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/services/ime_bridge.dart';

void main() {
  group('owner 状态机', () {
    test('初始无 owner', () {
      expect(ImeBridgeManager.instance.isActiveOwner(Object()), isFalse);
    });

    test('setActiveOwner 后同 owner 判定为真，其它为假', () {
      final owner = Object();
      ImeBridgeManager.instance.setActiveOwner(owner);
      expect(ImeBridgeManager.instance.isActiveOwner(owner), isTrue);
      expect(ImeBridgeManager.instance.isActiveOwner(Object()), isFalse);
      // 清理
      ImeBridgeManager.instance.releaseOwner(owner);
    });

    test('releaseOwner 清除 owner（仅同 owner 生效）', () {
      final ownerA = Object();
      final ownerB = Object();
      ImeBridgeManager.instance.setActiveOwner(ownerA);
      // 错误 owner 释放无效
      ImeBridgeManager.instance.releaseOwner(ownerB);
      expect(ImeBridgeManager.instance.isActiveOwner(ownerA), isTrue);
      ImeBridgeManager.instance.releaseOwner(ownerA);
      expect(ImeBridgeManager.instance.isActiveOwner(ownerA), isFalse);
    });

    test('owner 切换：后 set 覆盖先 set', () {
      final a = Object();
      final b = Object();
      ImeBridgeManager.instance.setActiveOwner(a);
      ImeBridgeManager.instance.setActiveOwner(b);
      expect(ImeBridgeManager.instance.isActiveOwner(a), isFalse);
      expect(ImeBridgeManager.instance.isActiveOwner(b), isTrue);
      ImeBridgeManager.instance.releaseOwner(b);
    });

    test('releaseOwner 空 owner 不崩溃', () {
      expect(() => ImeBridgeManager.instance.releaseOwner(Object()),
          returnsNormally);
    });
  });

  group('监听器注册与注销', () {
    test('add/remove 文本监听器', () {
      final texts = <String>[];
      void listener(String t) => texts.add(t);
      final mgr = ImeBridgeManager.instance;
      mgr.addTextListener(listener);
      mgr.addTextListener(listener); // 重复注册不崩溃
      mgr.removeTextListener(listener);
      mgr.removeTextListener(listener); // 重复移除不崩溃
      expect(texts, isEmpty);
    });

    test('cursor/submit/escape 监听器增删安全', () {
      final mgr = ImeBridgeManager.instance;
      void c(int p) {}
      void s() {}
      void e() {}
      mgr.addCursorListener(c);
      mgr.addSubmitListener(s);
      mgr.addEscapeListener(e);
      mgr.removeCursorListener(c);
      mgr.removeSubmitListener(s);
      mgr.removeEscapeListener(e);
      expect(() {
        mgr.removeCursorListener(c);
        mgr.removeSubmitListener(s);
        mgr.removeEscapeListener(e);
      }, returnsNormally);
    });
  });

  group('无进程时的安全降级', () {
    test('releaseFocus / shutdown / setText / clearText 空操作不崩溃', () {
      final mgr = ImeBridgeManager.instance;
      expect(() {
        mgr.releaseFocus();
        mgr.setText('任意文本');
        mgr.clearText();
      }, returnsNormally);
      // shutdown 无进程时立即返回
      mgr.shutdown();
    });

    test('grabFocus 无进程时启动流程安全（异步不等待）', () {
      final mgr = ImeBridgeManager.instance;
      // 调用后释放 focus 复位内部状态，防止影响其它测试
      mgr.grabFocus('initial');
      mgr.releaseFocus();
      mgr.shutdown();
    });

    test('重复 shutdown 幂等', () {
      final mgr = ImeBridgeManager.instance;
      expect(() {
        mgr.shutdown();
        mgr.shutdown();
      }, returnsNormally);
    });
  });
}
