// ============================================================
// ime_bridge.dart 阶段 N —— 键盘导航 NAV 监听契约（N5，TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 N（N5 P2-14 键盘导航体系）：
//
//   中文输入（showChineseInput）激活时方向键走 GTK 桥接进程，
//   Flutter 侧收不到方向键——persistent_ime.py 拦截 ↑/↓ 输出
//   NAV:UP / NAV:DOWN，ime_bridge.dart 解析后派发给当前激活输入框
//   执行焦点切换（客户端内部管道，不触冻结协议 v1.0.0）。
//
//   契约：ImeBridgeManager 新增
//     addNavUpListener / removeNavUpListener
//     addNavDownListener / removeNavDownListener
//   stdout 行解析分支：'NAV:UP' → 上移焦点监听器；'NAV:DOWN' → 下移。
//
// 与既有 ime_bridge_manager_test.dart 一致：本文件不启动真实子进程
// （FLUTTER_TEST 下 ensureStarted 为 no-op），只验证监听器注册表
// 契约与"无进程时安全降级"（解析派发在进程 stdout 流内，由 Python
// 侧契约测试 tests/test_stage_n_ime.py + E2E 覆盖）。
//
// 实现前：本文件引用尚未实现的方法，编译失败或用例红，属 TDD 红。
// 实现后：全部转绿。
// ============================================================

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/services/ime_bridge.dart';

void main() {
  group('N5 —— NAV 监听器注册表契约', () {
    test('add/remove 上移监听器安全（含重复注册/移除）', () {
      final mgr = ImeBridgeManager.instance;
      var upCount = 0;
      void listener() => upCount++;
      mgr.addNavUpListener(listener);
      mgr.addNavUpListener(listener);
      mgr.removeNavUpListener(listener);
      mgr.removeNavUpListener(listener);
      expect(upCount, 0, reason: '未触发前不应有回调');
    });

    test('add/remove 下移监听器安全（含重复注册/移除）', () {
      final mgr = ImeBridgeManager.instance;
      var downCount = 0;
      void listener() => downCount++;
      mgr.addNavDownListener(listener);
      mgr.addNavDownListener(listener);
      mgr.removeNavDownListener(listener);
      mgr.removeNavDownListener(listener);
      expect(downCount, 0);
    });

    test('无进程时 NAV 监听器注册/移除不崩溃', () {
      final mgr = ImeBridgeManager.instance;
      void up() {}
      void down() {}
      expect(() {
        mgr.addNavUpListener(up);
        mgr.addNavDownListener(down);
        mgr.removeNavUpListener(up);
        mgr.removeNavDownListener(down);
      }, returnsNormally);
    });

    test('NAV 监听器与既有文本/光标/提交/取消监听器共存', () {
      final mgr = ImeBridgeManager.instance;
      void t(String s) {}
      void c(int p) {}
      void s() {}
      void e() {}
      void up() {}
      void down() {}
      mgr.addTextListener(t);
      mgr.addCursorListener(c);
      mgr.addSubmitListener(s);
      mgr.addEscapeListener(e);
      mgr.addNavUpListener(up);
      mgr.addNavDownListener(down);
      // 全部注销后再次注销仍安全（清理不留残余）
      mgr.removeTextListener(t);
      mgr.removeCursorListener(c);
      mgr.removeSubmitListener(s);
      mgr.removeEscapeListener(e);
      mgr.removeNavUpListener(up);
      mgr.removeNavDownListener(down);
      expect(() {
        mgr.removeNavUpListener(up);
        mgr.removeNavDownListener(down);
      }, returnsNormally);
    });

    test('重复添加/移除同一 NAV 监听器安全（不崩溃、不残留）', () {
      final mgr = ImeBridgeManager.instance;
      var upCount = 0;
      void listener() => upCount++;
      mgr.addNavUpListener(listener);
      mgr.addNavUpListener(listener);
      // 契约：同一回调重复注册不崩溃；remove 幂等
      mgr.removeNavUpListener(listener);
      mgr.removeNavUpListener(listener);
      expect(upCount, 0);
    });
  });

  group('N5 —— 无进程时的安全降级（回归锁定）', () {
    test('shutdown / releaseFocus 后 NAV 监听器注册仍安全', () {
      final mgr = ImeBridgeManager.instance;
      mgr.shutdown();
      void up() {}
      mgr.addNavUpListener(up);
      mgr.removeNavUpListener(up);
      expect(() => mgr.shutdown(), returnsNormally);
    });

    test('grabFocus/releaseFocus 流程不影响 NAV 注册表', () {
      final mgr = ImeBridgeManager.instance;
      mgr.grabFocus('initial');
      mgr.releaseFocus();
      void down() {}
      mgr.addNavDownListener(down);
      mgr.removeNavDownListener(down);
      mgr.shutdown();
    });
  });
}
