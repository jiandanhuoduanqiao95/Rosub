// ============================================================
// opt9 批次 #2：Windows 设备端 HWND PID 过滤运行时集成验证
// ============================================================
// 场景：桌面上可能有多个 Flutter Windows 应用共用 runner 类名
// FLUTTER_RUNNER_WIN32_WINDOW（FindWindowW 按类名只取首个 → 闪烁/
// 唤起到别的应用）。运行时验证：
//   ① 枚举全部同类名窗口（FindWindowExW 链），收集各自 PID；
//   ② 真实解析路径（runnerWindowHwndForTest → _resolveRunnerWindowHwnd）
//      返回的窗口 PID == 本进程 PID；
//   ③ 自有 PID 的同类名窗口恰好一个（多实例场景下过滤语义成立）。
// 手动矩阵建议：先经 PowerShell 启动另一个 Rosub Release 实例再运行
// 本测试（flutter test integration_test/win32_hwnd_pid_opt9_test.dart
// -d windows），使类名窗口 ≥ 2。
// ============================================================

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:chatroom_flutter/platform/capabilities.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('runner 窗口解析按 PID 过滤只命中本进程', (tester) async {
    final lib = DynamicLibrary.open('user32.dll');
    final findWindowEx = lib.lookupFunction<
        IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
        int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)>(
        'FindWindowExW');
    final getPid = lib.lookupFunction<
        Uint32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)>('GetWindowThreadProcessId');
    // GetCurrentProcessId 在 kernel32（user32 句柄查不到——本测试
    // 首轮实锤并同步修正 capabilities.dart）
    final currentPid = DynamicLibrary.process()
        .lookupFunction<Uint32 Function(), int Function()>(
            'GetCurrentProcessId')();

    final className = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    final pidBuf = calloc<Uint32>();
    try {
      final pids = <int, int>{};
      var hwnd = findWindowEx(0, 0, className, nullptr);
      while (hwnd != 0) {
        getPid(hwnd, pidBuf);
        pids[hwnd] = pidBuf.value;
        hwnd = findWindowEx(0, hwnd, className, nullptr);
      }
      // 场景存在性：至少本进程一个窗口；多实例手动矩阵下 ≥2 且 PID 互异
      expect(pids, isNotEmpty, reason: '本进程 runner 窗口应存在');
      final ownPidWindows =
          pids.values.where((p) => p == currentPid).length;
      expect(ownPidWindows, 1,
          reason: '自有 PID 的同类名窗口应恰好一个（当前窗口数=${pids.length}，'
              'PID 集合=${pids.values.toSet()}，本进程=$currentPid）');

      final resolved = runnerWindowHwndForTest();
      expect(resolved, isNot(0), reason: '解析应命中本进程窗口');
      getPid(resolved, pidBuf);
      expect(pidBuf.value, currentPid,
          reason: '真实解析路径只返回本进程窗口（多实例下不得取到别的应用）');
    } finally {
      calloc.free(className);
      calloc.free(pidBuf);
    }
  });
}
