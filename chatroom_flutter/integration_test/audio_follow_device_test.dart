// ============================================================
// opt6 音频路由真机诊断驱动（2026-10-07，win/linux 双端通用）
// ============================================================
// 目标：以客观指标（出站 media-source audioLevel / 入站 inbound-rtp
// audioLevel）判定"麦克风真的采到非静音并送出 / 对端真的收到声音"，
// 并配合外部 pactl（Linux）/admprobe（Windows）翻默认设备验证采集
// 跟随。角色化运行：
//
//   flutter test integration_test/audio_follow_device_test.dart -d linux \
//     --dart-define=AF_ROLE=subject --dart-define=AF_USER=lin_a \
//     --dart-define=AF_PASS=lin123456 [--dart-define=AF_HOLD=120] \
//     [--dart-define=AF_SERVER=127.0.0.1] [--dart-define=AF_VIDEO=1]
//
// 角色：
//   subject  群通话发起方：发起 → active → 周期采样双方电平 → 保持
//            AF_HOLD 秒 → 挂断。电平经 [af] 前缀打印（编排侧断言）。
//   peer     受话方：等铃 → 接听 → active → 周期采样 → 等挂断收尾。
// 断言由编排脚本对输出做（电平阈值随场景），本驱动只采样打印。
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:chatroom_flutter/config.dart';
import 'package:chatroom_flutter/services/call_engine.dart';
import 'package:chatroom_flutter/services/call_service.dart';
import 'package:chatroom_flutter/services/socket_service.dart';

const _role = String.fromEnvironment('AF_ROLE');
const _user = String.fromEnvironment('AF_USER', defaultValue: 'lin_a');
const _pass = String.fromEnvironment('AF_PASS', defaultValue: 'lin123456');
const _hold = int.fromEnvironment('AF_HOLD', defaultValue: 60);
const _server = String.fromEnvironment('AF_SERVER', defaultValue: '127.0.0.1');
const _video = bool.fromEnvironment('AF_VIDEO', defaultValue: false);
const _groupId = int.fromEnvironment('AF_GROUP_ID', defaultValue: 2);

Future<void> _sample(SocketService svc, WebRtcCallEngine engine, String tag,
    WidgetTester tester) async {
  final now = DateTime.now();
  final clock =
      '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${(now.millisecond / 100).toStringAsFixed(1)}';
  final out = await engine.outboundAudioLevel();
  final ins = <String, double?>{};
  for (final p in svc.callService.remotePeers) {
    ins[p] = await engine.peerInboundAudioLevel(p);
  }
  // ignore: avoid_print
  print('[af] $clock $tag phase=${svc.callService.phase} '
      'outLevel=$out inLevels=$ins peers=${svc.callService.remotePeers}');
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _holdLoop(SocketService svc, WebRtcCallEngine engine,
    WidgetTester tester, Duration duration) async {
  final end = DateTime.now().add(duration);
  var i = 0;
  while (DateTime.now().isBefore(end) && svc.callService.phase != CallPhase.ended) {
    await _sample(svc, engine, 't${i++}', tester);
    await tester.pump(const Duration(seconds: 2));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('opt6 audio follow diag: $_role/$_user', (tester) async {
    final engine = WebRtcCallEngine();
    SocketService.callEngineOverride = engine;
    final svc = SocketService();
    AppConfig.serverHost = _server;
    AppConfig.serverPort = 8090;

    expect(await svc.connect(), isTrue, reason: '连接 $_server:8090');
    expect(await svc.login(_user, _pass), isNull, reason: '登录 $_user');
    // ignore: avoid_print
    print('[af] logged in as $_user role=$_role');

    switch (_role) {
      case 'subject':
        final ok = await svc.callService.startGroupCall(
            _groupId, 'R2群通话测试群', _video ? CallType.video : CallType.audio);
        expect(ok, isTrue, reason: '发起群通话');
        var waited = await _pumpUntil(tester,
            () => svc.callService.phase == CallPhase.active,
            const Duration(seconds: 90),);
        expect(waited, isTrue,
            reason: '应进入 active（phase=${svc.callService.phase}）');
        // ignore: avoid_print
        print('[af] subject ACTIVE');
        await _holdLoop(
            svc, engine, tester, const Duration(seconds: _hold));
        svc.callService.hangup();
        await _pumpUntil(tester, () => svc.callService.phase == CallPhase.ended,
            const Duration(seconds: 15));
        // ignore: avoid_print
        print('[af] subject ended');

      case 'peer':
        var waited = await _pumpUntil(tester,
            () => svc.callService.phase == CallPhase.ringing,
            const Duration(seconds: 180 + _hold));
        expect(waited, isTrue, reason: '应收到来电');
        // ignore: avoid_print
        print('[af] peer RINGING type=${svc.callService.type}');
        svc.callService.acceptIncoming();
        waited = await _pumpUntil(tester,
            () => svc.callService.phase == CallPhase.active,
            const Duration(seconds: 60));
        expect(waited, isTrue, reason: '接听后应 active');
        // ignore: avoid_print
        print('[af] peer ACTIVE');
        await _holdLoop(
            svc, engine, tester, const Duration(seconds: _hold + 30));
        await _pumpUntil(tester, () => svc.callService.phase == CallPhase.ended,
            const Duration(seconds: 60));
        // ignore: avoid_print
        print('[af] peer ended');

      default:
        fail('未知 AF_ROLE=$_role');
    }
    svc.disconnect();
    // ignore: avoid_print
    print('[af] PASS role=$_role user=$_user');
  });
}

Future<bool> _pumpUntil(WidgetTester tester, bool Function() cond,
    Duration timeout) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (cond()) return true;
    await tester.pump(const Duration(milliseconds: 200));
  }
  return cond();
}
