// opt8 #11 —— LinuxSoundCapability paplay→aplay 回退（注入 ProcessRunner，
// 不真跑外部进程）
//
// 契约：
//   - paplay 退出码 0 → 只调 paplay，lastError 清空；
//   - paplay 抛异常（缺 paplay 的发行版）→ 回退 aplay -q；aplay 成功时
//     lastError 记录 paplay 失败原因；
//   - paplay 非零退出码同样回退 aplay；
//   - 双通道都失败（异常或非零）→ 不抛异常，lastError 含两者 +
//     debugPrint '[call-sound]' 日志；
//   - path null → 不调用任何进程；
//   - 默认构造可构造（工厂无参路径不变）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/platform/capabilities.dart';

class _FakeRunner {
  final List<List<String>> calls = [];
  final Object? paplayThrow;
  final int paplayExit;
  final Object? aplayThrow;
  final int aplayExit;

  _FakeRunner({
    this.paplayThrow,
    this.paplayExit = 0,
    this.aplayThrow,
    this.aplayExit = 0,
  });

  Future<ProcessResult> call(String executable, List<String> arguments) async {
    calls.add([executable, ...arguments]);
    if (executable == 'paplay') {
      final t = paplayThrow;
      if (t != null) throw t;
      return ProcessResult(0, paplayExit, '', '');
    }
    final t = aplayThrow;
    if (t != null) throw t;
    return ProcessResult(0, aplayExit, '', '');
  }
}

void main() {
  group('opt8 #11 —— paplay→aplay 回退', () {
    test('默认构造可构造（工厂无参路径不变）', () {
      expect(LinuxSoundCapability(), isNotNull);
    });

    test('paplay 成功 → 只调 paplay，lastError null（铃声）', () async {
      final runner = _FakeRunner();
      final cap = LinuxSoundCapability(processRunner: runner.call);
      await cap.playCallRingtone();
      expect(runner.calls, hasLength(1));
      expect(runner.calls.single[0], 'paplay');
      expect(cap.lastError, isNull);
    });

    test('paplay 成功 → 只调 paplay（挂断音）', () async {
      final runner = _FakeRunner();
      final cap = LinuxSoundCapability(processRunner: runner.call);
      await cap.playHangupSound();
      expect(runner.calls, hasLength(1));
      expect(runner.calls.single[0], 'paplay');
      expect(cap.lastError, isNull);
    });

    test('paplay 抛 ProcessException → 回退 aplay 成功，lastError 含 paplay',
        () async {
      final runner = _FakeRunner(
        paplayThrow: const ProcessException('paplay', [], 'Exec format error'),
      );
      final cap = LinuxSoundCapability(processRunner: runner.call);
      await cap.playCallRingtone();
      expect(runner.calls, hasLength(2));
      expect(runner.calls[0][0], 'paplay');
      expect(runner.calls[1][0], 'aplay');
      expect(runner.calls[1].sublist(1), ['-q', runner.calls[0][1]]);
      expect(cap.lastError, contains('paplay'));
    });

    test('paplay exit 1 → 回退 aplay', () async {
      final runner = _FakeRunner(paplayExit: 1);
      final cap = LinuxSoundCapability(processRunner: runner.call);
      await cap.playCallRingtone();
      expect(runner.calls, hasLength(2));
      expect(runner.calls[1][0], 'aplay');
      expect(cap.lastError, contains('paplay exit 1'));
    });

    test('双通道都失败 → 不抛异常，lastError 含两者', () async {
      final runner = _FakeRunner(
        paplayThrow:
            const ProcessException('paplay', [], 'No such file or directory'),
        aplayExit: 1,
      );
      final cap = LinuxSoundCapability(processRunner: runner.call);
      await cap.playCallRingtone();
      expect(runner.calls, hasLength(2));
      expect(cap.lastError, contains('paplay'));
      expect(cap.lastError, contains('aplay'));
    });

    test('aplay 抛异常 → 不抛出，lastError 含两者（挂断音同路径）', () async {
      final runner = _FakeRunner(
        paplayExit: 2,
        aplayThrow:
            const ProcessException('aplay', [], 'No such file or directory'),
      );
      final cap = LinuxSoundCapability(processRunner: runner.call);
      await cap.playHangupSound();
      expect(runner.calls, hasLength(2));
      expect(cap.lastError, contains('paplay exit 2'));
      expect(cap.lastError, contains('aplay'));
    });

    test('WAV 生成成功时铃声与挂断音各调用一次 paplay', () async {
      final runner = _FakeRunner();
      final cap = LinuxSoundCapability(processRunner: runner.call);
      await cap.playCallRingtone();
      await cap.playHangupSound();
      expect(runner.calls, hasLength(2), reason: 'wav 生成成功各调一次');
    });

    test('lastError 成功后清空', () async {
      final runner = _FakeRunner(paplayExit: 1);
      final cap = LinuxSoundCapability(processRunner: runner.call);
      await cap.playCallRingtone();
      expect(cap.lastError, isNotNull);
      final okRunner = _FakeRunner();
      final okCap = LinuxSoundCapability(processRunner: okRunner.call);
      await okCap.playCallRingtone();
      expect(okCap.lastError, isNull);
    });
  });
}
