// ============================================================
// opt1 P5/P6 —— 后台通话保活：通话 FGS + 断线豁免 + 通知回通话
// ============================================================
// ① CallService.isInLiveCall：socket 断线豁免拆场与回前台探测跳过的
//    判定依据（calling/ringing/connecting/active 为真，ended/idle 为
//    假，minimized 仍为真）；
// ② socket_service 豁免分支 + chat_screen FGS/通知接线（源码扫描，
//    仿 lifecycle_stage_q_test 惯例——socket_service 私有链路无真
//    socket 环境不可达，真实重连由既有测试与 E2E 守门）；
// ③ 原生层契约（CallForegroundService.kt + AndroidManifest）。
// ============================================================

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:chatroom_flutter/services/call_engine.dart';
import 'package:chatroom_flutter/services/call_service.dart';

class _MockSignaling extends Mock implements CallSignaling {}

class _MockEngine extends Mock implements CallEngine {}

class _FakeListener extends Fake implements CallEngineListener {}

class _Harness {
  final signaling = _MockSignaling();
  final engine = _MockEngine();
  CallEngineListener? listener;

  CallService build() {
    when(() => engine.setListener(any())).thenAnswer((inv) {
      listener = inv.positionalArguments[0] as CallEngineListener;
    });
    when(() => signaling.sendCall(any(), any(), any(),
        callType: any(named: 'callType'),
        body: any(named: 'body'))).thenAnswer((_) async {});
    when(() => engine.open(video: any(named: 'video')))
        .thenAnswer((_) async {});
    when(() => engine.hasLocalMedia).thenReturn(true);
    when(() => engine.close()).thenAnswer((_) async {});
    when(() => engine.setMicMuted(any())).thenAnswer((_) async {});
    when(() => engine.setCameraEnabled(any())).thenAnswer((_) async {});
    when(() => engine.setSpeakerphoneOn(any())).thenAnswer((_) async {});
    when(() => engine.createOffer())
        .thenAnswer((_) async => {'sdp': 'offer-sdp', 'type': 'offer'});
    when(() => engine.createAnswer())
        .thenAnswer((_) async => {'sdp': 'answer-sdp', 'type': 'answer'});
    when(() => engine.setRemoteOffer(any())).thenAnswer((_) async {});
    when(() => engine.setRemoteAnswer(any())).thenAnswer((_) async {});
    when(() => engine.addRemoteCandidate(any())).thenAnswer((_) async {});
    return CallService(signaling: signaling, engine: engine);
  }

}

Uint8List _body(Map<String, dynamic> json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

String srcOf(String relPath) => File(relPath).readAsStringSync();

int countOf(String source, String needle) => source.split(needle).length - 1;

void main() {
  setUpAll(() {
    registerFallbackValue(_FakeListener());
    registerFallbackValue(<String, Object?>{});
  });

  group('opt1 P5 —— CallService.isInLiveCall', () {
    test('idle：false', () {
      final svc = _Harness().build();
      expect(svc.isInLiveCall, isFalse);
      expect(svc.isBusy, isFalse);
    });

    test('calling（外呼振铃中）：true；minimized 后仍 true', () async {
      final svc = _Harness().build();
      await svc.startCall('bob', CallType.audio);
      expect(svc.phase, CallPhase.calling);
      expect(svc.isInLiveCall, isTrue);

      svc.minimize();
      expect(svc.minimized, isTrue);
      expect(svc.isInLiveCall, isTrue, reason: '最小化是进行中通话的 UI 形态');
      svc.cancelOutgoing();
      expect(svc.phase, CallPhase.ended);
      expect(svc.isInLiveCall, isFalse, reason: 'ended 展示期不算进行中');
    });

    test('active（接通后）：true', () async {
      final h = _Harness();
      final svc = h.build();
      await svc.startCall('bob', CallType.audio);
      final id = svc.callId;
      svc.handleSignal('call_accept', {'from': 'bob', 'call_id': id},
          Uint8List(0));
      await Future<void>.delayed(Duration.zero);
      svc.handleSignal(
          'call_answer',
          {'from': 'bob', 'call_id': id},
          _body({'sdp': 'answer-sdp', 'type': 'answer'}));
      await Future<void>.delayed(Duration.zero);
      expect(svc.phase, CallPhase.active);
      expect(svc.isInLiveCall, isTrue);
      svc.hangup();
      expect(svc.isInLiveCall, isFalse);
    });
  });

  group('opt1 P5 —— socket_service 豁免分支（源码扫描锁定）', () {
    test('_onConnectionLost 通话中不拆场', () {
      final src = srcOf('lib/services/socket_service.dart');
      // 豁免分支存在且在 _onConnectionLost 内
      expect(src, contains("if (!callService.isInLiveCall) {"),
          reason: '断线路径必须豁免进行中通话（handleDisconnected 不调用）');
      expect(countOf(src, 'callService.isInLiveCall'), greaterThanOrEqualTo(2),
          reason: '_onConnectionLost 与 ensureConnectedOnResume 两处豁免');
    });

    test('disconnect() 主动退出仍无条件拆场（豁免不扩大）', () {
      final src = srcOf('lib/services/socket_service.dart');
      final disconnectIdx = src.indexOf('void disconnect()');
      final connLostIdx = src.indexOf('void _onConnectionLost()');
      expect(disconnectIdx, greaterThan(0));
      expect(connLostIdx, greaterThan(disconnectIdx));
      final disconnectBody = src.substring(disconnectIdx, connLostIdx);
      expect(disconnectBody, contains('callService.handleDisconnected()'),
          reason: '用户退出登录必须照常拆场（豁免仅限断线路径）');
    });
  });

  group('opt1 P5/P6 —— chat_screen 接线（源码扫描锁定）', () {
    test('FGS 同步：通话中启动 / 结束停止（Android 门控）', () {
      final src = srcOf('lib/screens/chat_screen.dart');
      expect(src, contains('_syncCallForegroundService'),
          reason: '通话 FGS 启停接线必须存在');
      expect(src, contains('startCallForeground'),
          reason: '通话开始启动 microphone|camera 型 FGS');
      expect(src, contains('stopCallForeground'),
          reason: '通话结束停止 FGS');
      // dispose 双保险撤除
      expect(countOf(src, 'stopCallForeground'), greaterThanOrEqualTo(2));
    });

    test('通知点击回通话：resumed 消费 open_call 意图', () {
      final src = srcOf('lib/screens/chat_screen.dart');
      expect(src, contains('consumeOpenCallIntent'),
          reason: 'resumed 时拉取通话通知点击标志');
      expect(src, contains('_handleOpenCallIntent'));
    });
  });

  group('opt1 P5/P6 —— 原生层契约', () {
    test('AndroidSystem 暴露三个新通道方法', () {
      final src = srcOf('lib/platform/android_system.dart');
      expect(src, contains("'startCallForeground'"));
      expect(src, contains("'stopCallForeground'"));
      expect(src, contains("'consumeOpenCallIntent'"));
    });

    test('CallForegroundService.kt 存在且关键契约齐备', () {
      final src = srcOf(
          'android/app/src/main/kotlin/com/example/chatroom_flutter/'
          'CallForegroundService.kt');
      expect(src, contains('microphone'));
      expect(src, contains('FOREGROUND_SERVICE_TYPE_MICROPHONE'));
      expect(src, contains('FOREGROUND_SERVICE_TYPE_CAMERA'),
          reason: '视频通话需要 camera 类型');
      expect(src, contains('chatroom_call_v2'),
          reason: '通知渠道沿用 v2 命名体系（vivo 渠道级渲染缓存）');
      expect(src, contains('EXTRA_OPEN_CALL'),
          reason: '通知 contentIntent 携带 open_call extra（P6）');
      expect(src, contains('MainActivity::class.java'));
    });

    test('AndroidManifest 声明 FGS 权限与服务', () {
      final src =
          srcOf('android/app/src/main/AndroidManifest.xml');
      expect(src, contains('android.permission.FOREGROUND_SERVICE_MICROPHONE'));
      expect(src, contains('android.permission.FOREGROUND_SERVICE_CAMERA'));
      expect(
          src,
          contains(
              'android:foregroundServiceType="microphone|camera|specialUse"'),
          reason: 'Android 14+ 要求 FGS 类型与实际采集匹配；opt5 扩'
              ' specialUse（权限回收时降级保活，勿缩回）');
      expect(src, contains('.CallForegroundService'));
      // 消息保活 FGS 不受影响（Q1 定稿只能增强）
      expect(src, contains('.KeepAliveService'));
      expect(src, contains('specialUse'));
    });

    test('MainActivity 置位/消费 open_call 标志', () {
      final src = srcOf(
          'android/app/src/main/kotlin/com/example/chatroom_flutter/'
          'MainActivity.kt');
      expect(src, contains('openCallIntentPending'));
      expect(src, contains('onNewIntent'));
      expect(src, contains('consumeOpenCallIntent'));
    });
  });
}
