import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String srcOf(String relPath) => File(relPath).readAsStringSync();

String functionBodyOf(String src, String signature) {
  final start = src.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: '缺少函数: $signature');
  final braceStart = src.indexOf('{', start);
  var depth = 0;
  for (var i = braceStart; i < src.length; i++) {
    if (src[i] == '{') depth++;
    if (src[i] == '}') {
      depth--;
      if (depth == 0) return src.substring(start, i + 1);
    }
  }
  fail('函数体未闭合: $signature');
}

void main() {
  String src() => srcOf('lib/platform/capabilities.dart');
  String body() =>
      functionBodyOf(srcOf('lib/platform/capabilities.dart'),
          'int _resolveRunnerWindowHwnd(');

  group('Windows HWND PID 过滤（缺陷修复：FindWindowW 无 PID 校验）', () {
    test('FFI 入口为 FindWindowExW + GetWindowThreadProcessId + '
        'GetCurrentProcessId', () {
      expect(src(), contains("'FindWindowExW'"));
      expect(src(), contains("'GetWindowThreadProcessId'"));
      expect(src(), contains("'GetCurrentProcessId'"));
      expect(body(), contains("DynamicLibrary.process()"),
          reason: 'GetCurrentProcessId 在 kernel32——经 process() 解析'
              '（user32 句柄查不到，Windows 真机 integration_test 实锤）');
    });

    test('_resolveRunnerWindowHwnd 函数体使用三者并按 PID 过滤', () {
      expect(body(), contains("'FindWindowExW'"));
      expect(body(), contains("'GetWindowThreadProcessId'"));
      expect(body(), contains("'GetCurrentProcessId'"));
      expect(body(), contains('pid.value == currentPid'),
          reason: '同类名窗口逐一比对 PID，只命中本进程');
      expect(body(), contains('findWindowEx(0, hwnd, className, nullptr)'),
          reason: '从上一个同类窗口继续枚举');
    });

    test('不再使用 FindWindowW', () {
      expect(src().contains("'FindWindowW'"), isFalse);
      expect(src().contains('FindWindowW('), isFalse);
    });

    test('闪烁与唤起两个调用方都经 _resolveRunnerWindowHwnd', () {
      final notificationClass = functionBodyOf(
          src(), 'class WindowsNotificationCapability implements');
      final activationClass = functionBodyOf(
          src(), 'class WindowsWindowActivationCapability implements');
      expect(notificationClass, contains('_resolveRunnerWindowHwnd'));
      expect(activationClass, contains('_resolveRunnerWindowHwnd'));
      expect('_resolveRunnerWindowHwnd'.allMatches(src()).length,
          greaterThanOrEqualTo(2));
    });

    test('runner 类名契约不变（win32_window.cpp kWindowClassName）', () {
      expect(srcOf('windows/runner/win32_window.cpp'),
          contains('FLUTTER_RUNNER_WIN32_WINDOW'));
      expect(body(), contains('FLUTTER_RUNNER_WIN32_WINDOW'));
    });

    test('不缓存 HWND（每次解析现取，窗口重建后旧句柄不失效误用）', () {
      expect(src().contains('_cachedHwnd'), isFalse);
      expect(src().contains('_hwndCache'), isFalse);
    });
  });
}
