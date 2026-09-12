// 阶段 R1：通话服务层状态机契约测试（mocktail 隔离信令与引擎）
//
// 覆盖：双类型外呼/来电全流程、取消/拒绝/挂断/超时/失败映射、
// ICE 先到缓冲后冲、占线自动拒绝、多端接听收敛、引擎连接失败、
// 断线收尾、ended → idle 复位。
import 'dart:convert';
import 'dart:typed_data';

import 'package:chatroom_flutter/services/call_engine.dart';
import 'package:chatroom_flutter/services/call_service.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockSignaling extends Mock implements CallSignaling {}

class _MockEngine extends Mock implements CallEngine {}

class _FakeListener extends Fake implements CallEngineListener {}

class _RecordedSend {
  final String type;
  final String to;
  final String callId;
  final String? callType;
  final String? body;
  _RecordedSend(this.type, this.to, this.callId, this.callType, this.body);
}

class _Harness {
  final signaling = _MockSignaling();
  final engine = _MockEngine();
  final sends = <_RecordedSend>[];
  CallEngineListener? listener;

  CallService build() {
    when(() => engine.setListener(any())).thenAnswer((inv) {
      listener = inv.positionalArguments[0] as CallEngineListener;
    });
    when(() => signaling.sendCall(any(), any(), any(),
        callType: any(named: 'callType'),
        body: any(named: 'body'))).thenAnswer((inv) async {
      sends.add(_RecordedSend(
        inv.positionalArguments[0] as String,
        inv.positionalArguments[1] as String,
        inv.positionalArguments[2] as String,
        inv.namedArguments[#callType] as String?,
        inv.namedArguments[#body] as String?,
      ));
    });
    when(() => engine.open(video: any(named: 'video')))
        .thenAnswer((_) async {});
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

  bool sent(String type) => sends.any((s) => s.type == type);
  _RecordedSend last(String type) => sends.lastWhere((s) => s.type == type);
}

Uint8List _body(Map<String, dynamic> json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

void _signal(CallService svc, String type, String from, String callId,
    {String? callType, Map<String, dynamic>? body}) {
  final header = <String, dynamic>{'from': from, 'call_id': callId};
  if (callType != null) header['call_type'] = callType;
  svc.handleSignal(type, header, body == null ? Uint8List(0) : _body(body));
}

void main() {
  setUpAll(() {
    registerFallbackValue(_FakeListener());
    registerFallbackValue(<String, Object?>{});
  });

  group('外呼全流程', () {
    test('audio：invite→accept→offer→answer→active→hangup', () async {
      final h = _Harness();
      final svc = h.build();
      final ok = await svc.startCall('bob', CallType.audio);
      expect(ok, isTrue);
      expect(svc.phase, CallPhase.calling);
      expect(svc.peer, 'bob');
      expect(svc.type, CallType.audio);
      final invite = h.last('call_invite');
      expect(invite.to, 'bob');
      expect(invite.callType, 'audio');
      expect(invite.callId, isNotEmpty);

      _signal(svc, 'call_accept', 'bob', invite.callId);
      await Future<void>.delayed(Duration.zero);
      verify(() => h.engine.open(video: false)).called(1);
      expect(h.sent('call_offer'), isTrue);
      expect(h.last('call_offer').callId, invite.callId);
      expect(jsonDecode(h.last('call_offer').body!),
          {'sdp': 'offer-sdp', 'type': 'offer'});

      _signal(svc, 'call_answer', 'bob', invite.callId,
          body: {'sdp': 'answer-sdp', 'type': 'answer'});
      await Future<void>.delayed(Duration.zero);
      verify(() =>
              h.engine.setRemoteAnswer({'sdp': 'answer-sdp', 'type': 'answer'}))
          .called(1);
      expect(svc.phase, CallPhase.active);
      expect(svc.activeSince, isNotNull);

      svc.hangup();
      expect(h.sent('call_hangup'), isTrue);
      expect(svc.phase, CallPhase.ended);
      expect(svc.endReason, '通话已结束');
      verify(() => h.engine.close()).called(1);
    });

    test('video：invite 携带 call_type=video 且引擎开视频', () async {
      final h = _Harness();
      final svc = h.build();
      await svc.startCall('bob', CallType.video);
      expect(h.last('call_invite').callType, 'video');
      _signal(svc, 'call_accept', 'bob', h.last('call_invite').callId);
      await Future<void>.delayed(Duration.zero);
      verify(() => h.engine.open(video: true)).called(1);
    });

    test('主叫取消：call_cancel + ended', () async {
      final h = _Harness();
      final svc = h.build();
      await svc.startCall('bob', CallType.audio);
      svc.cancelOutgoing();
      expect(h.sent('call_cancel'), isTrue);
      expect(svc.phase, CallPhase.ended);
      expect(svc.endReason, '已取消');
    });

    test('45s 无应答自动取消（fakeAsync）', () {
      fakeAsync((async) {
        final h = _Harness();
        final svc = h.build();
        svc.startCall('bob', CallType.audio);
        async.elapse(const Duration(seconds: 46));
        expect(h.sent('call_cancel'), isTrue);
        expect(svc.phase, CallPhase.ended);
        expect(svc.endReason, '对方无应答');
      });
    });
  });

  group('来电全流程', () {
    test('invite→accept→offer→answer→hangup（ICE 先到缓冲后冲）', () async {
      final h = _Harness();
      final svc = h.build();
      _signal(svc, 'call_invite', 'alice', 'c-1', callType: 'video');
      expect(svc.phase, CallPhase.ringing);
      expect(svc.peer, 'alice');
      expect(svc.type, CallType.video);

      await svc.acceptIncoming();
      expect(h.sent('call_accept'), isTrue);
      verify(() => h.engine.open(video: true)).called(1);

      // offer 未到时 ICE 先到：缓冲（不进引擎）
      final cand = {
        'candidate': 'candidate:1 udp',
        'sdpMid': '0',
        'sdpMLineIndex': 0,
      };
      _signal(svc, 'call_ice', 'alice', 'c-1', body: cand);
      await Future<void>.delayed(Duration.zero);
      verifyNever(() => h.engine.addRemoteCandidate(any()));

      _signal(svc, 'call_offer', 'alice', 'c-1',
          body: {'sdp': 'offer-sdp', 'type': 'offer'});
      await Future<void>.delayed(Duration.zero);
      verify(() =>
              h.engine.setRemoteOffer({'sdp': 'offer-sdp', 'type': 'offer'}))
          .called(1);
      expect(h.sent('call_answer'), isTrue);
      expect(jsonDecode(h.last('call_answer').body!),
          {'sdp': 'answer-sdp', 'type': 'answer'});
      // answer 发出后缓冲候选冲入引擎
      verify(() => h.engine.addRemoteCandidate(cand)).called(1);

      _signal(svc, 'call_hangup', 'alice', 'c-1');
      expect(svc.phase, CallPhase.ended);
      expect(svc.endReason, '通话已结束');
    });

    test('拒绝：call_reject + ended', () async {
      final h = _Harness();
      final svc = h.build();
      _signal(svc, 'call_invite', 'alice', 'c-2');
      svc.rejectIncoming();
      expect(h.sent('call_reject'), isTrue);
      expect(svc.phase, CallPhase.ended);
      expect(svc.endReason, '已拒绝');
    });

    test('对方取消：ringing → ended', () {
      final h = _Harness();
      final svc = h.build();
      _signal(svc, 'call_invite', 'alice', 'c-3');
      _signal(svc, 'call_cancel', 'alice', 'c-3');
      expect(svc.phase, CallPhase.ended);
      expect(svc.endReason, '对方已取消');
    });

    test('占线时新邀请自动拒绝且不影响既有通话', () async {
      final h = _Harness();
      final svc = h.build();
      _signal(svc, 'call_invite', 'alice', 'c-4');
      _signal(svc, 'call_invite', 'carol', 'c-5');
      await Future<void>.delayed(Duration.zero);
      final reject = h.last('call_reject');
      expect(reject.to, 'carol');
      expect(reject.callId, 'c-5');
      expect(svc.phase, CallPhase.ringing);
      expect(svc.peer, 'alice');
    });

    test('多端接听收敛：call_active 结束本机响铃', () {
      final h = _Harness();
      final svc = h.build();
      _signal(svc, 'call_invite', 'alice', 'c-6');
      _signal(svc, 'call_active', 'bob', 'c-6');
      expect(svc.phase, CallPhase.ended);
      expect(svc.endReason, '已在其他设备接听');
    });
  });

  group('失败与收尾', () {
    test('call_failed offline → 对方不在线', () {
      fakeAsync((async) {
        final h = _Harness();
        final svc = h.build();
        svc.startCall('bob', CallType.audio);
        final id = h.last('call_invite').callId;
        svc.handleSignal(
            'call_failed', {'call_id': id, 'reason': 'offline'}, Uint8List(0));
        expect(svc.phase, CallPhase.ended);
        expect(svc.endReason, '对方不在线');
        async.elapse(const Duration(seconds: 3));
        expect(svc.phase, CallPhase.idle);
      });
    });

    test('引擎连接失败：hangup 信令 + ended', () async {
      final h = _Harness();
      final svc = h.build();
      await svc.startCall('bob', CallType.audio);
      final id = h.last('call_invite').callId;
      _signal(svc, 'call_accept', 'bob', id);
      await Future<void>.delayed(Duration.zero);
      _signal(svc, 'call_answer', 'bob', id,
          body: {'sdp': 'a', 'type': 'answer'});
      await Future<void>.delayed(Duration.zero);
      h.listener!.onConnectionState('failed');
      expect(h.sent('call_hangup'), isTrue);
      expect(svc.phase, CallPhase.ended);
      expect(svc.endReason, '连接失败');
    });

    test('本地 ICE 候选经信令外发（connecting 态）', () async {
      final h = _Harness();
      final svc = h.build();
      await svc.startCall('bob', CallType.audio);
      final id = h.last('call_invite').callId;
      _signal(svc, 'call_accept', 'bob', id);
      await Future<void>.delayed(Duration.zero);
      h.listener!.onLocalCandidate({'candidate': 'x', 'sdpMid': '0'});
      await Future<void>.delayed(Duration.zero);
      expect(h.sent('call_ice'), isTrue);
      expect(jsonDecode(h.last('call_ice').body!)['candidate'], 'x');
    });

    test('连接断开：通话收尾', () async {
      final h = _Harness();
      final svc = h.build();
      await svc.startCall('bob', CallType.audio);
      svc.handleDisconnected();
      expect(svc.phase, CallPhase.ended);
      expect(svc.endReason, '连接已断开');
    });

    test('ended 2s 后复位 idle（fakeAsync）', () {
      fakeAsync((async) {
        final h = _Harness();
        final svc = h.build();
        svc.startCall('bob', CallType.audio);
        svc.cancelOutgoing();
        expect(svc.phase, CallPhase.ended);
        async.elapse(const Duration(seconds: 3));
        expect(svc.phase, CallPhase.idle);
        expect(svc.peer, isNull);
      });
    });

    test('占线时 startCall 拒绝', () async {
      final h = _Harness();
      final svc = h.build();
      _signal(svc, 'call_invite', 'alice', 'c-9');
      final ok = await svc.startCall('bob', CallType.audio);
      expect(ok, isFalse);
      expect(svc.peer, 'alice');
      expect(h.sent('call_invite'), isFalse);
    });
  });

  group('真机十轮：最小化与通话中开关（微信式交互）', () {
    test('minimize：通话中置位、ended 保持、idle 复位', () {
      fakeAsync((async) {
        final h = _Harness();
        final svc = h.build();
        svc.startCall('bob', CallType.audio);
        svc.minimize();
        expect(svc.minimized, isTrue);
        expect(svc.phase, CallPhase.calling);
        svc.cancelOutgoing();
        expect(svc.phase, CallPhase.ended);
        // ended 期间保持最小化（悬浮条显示结束原因）
        expect(svc.minimized, isTrue);
        async.elapse(const Duration(seconds: 3));
        expect(svc.phase, CallPhase.idle);
        expect(svc.minimized, isFalse);
      });
    });

    test('restore 复位最小化标志', () async {
      final h = _Harness();
      final svc = h.build();
      await svc.startCall('bob', CallType.audio);
      svc.minimize();
      expect(svc.minimized, isTrue);
      svc.restore();
      expect(svc.minimized, isFalse);
      svc.cancelOutgoing();
    });

    test('ended/idle 态 minimize 不生效', () async {
      final h = _Harness();
      final svc = h.build();
      await svc.startCall('bob', CallType.audio);
      svc.cancelOutgoing();
      expect(svc.phase, CallPhase.ended);
      svc.minimize();
      expect(svc.minimized, isFalse);
    });

    test('toggleMic 切换并驱动引擎，teardown 复位', () async {
      final h = _Harness();
      final svc = h.build();
      await svc.startCall('bob', CallType.audio);
      expect(svc.micMuted, isFalse);
      await svc.toggleMic();
      expect(svc.micMuted, isTrue);
      verify(() => h.engine.setMicMuted(true)).called(1);
      await svc.toggleMic();
      expect(svc.micMuted, isFalse);
      verify(() => h.engine.setMicMuted(false)).called(1);
      svc.cancelOutgoing();
      expect(svc.micMuted, isFalse);
    });

    test('toggleCamera 仅视频通话生效', () async {
      final h = _Harness();
      final svc = h.build();
      await svc.startCall('bob', CallType.audio);
      await svc.toggleCamera();
      expect(svc.cameraOff, isFalse);
      verifyNever(() => h.engine.setCameraEnabled(any()));
      svc.cancelOutgoing();

      final h2 = _Harness();
      final svc2 = h2.build();
      await svc2.startCall('bob', CallType.video);
      await svc2.toggleCamera();
      expect(svc2.cameraOff, isTrue);
      verify(() => h2.engine.setCameraEnabled(false)).called(1);
      svc2.cancelOutgoing();
      expect(svc2.cameraOff, isFalse);
    });

    test('免提默认路由：语音=听筒 关、视频=外放 开，媒体建立后应用', () async {
      final h = _Harness();
      final svc = h.build();
      await svc.startCall('bob', CallType.audio);
      expect(svc.speakerOn, isFalse);
      _signal(svc, 'call_accept', 'bob', h.last('call_invite').callId);
      await Future<void>.delayed(Duration.zero);
      verify(() => h.engine.setSpeakerphoneOn(false)).called(1);
      svc.cancelOutgoing();

      final h2 = _Harness();
      final svc2 = h2.build();
      await svc2.startCall('bob', CallType.video);
      expect(svc2.speakerOn, isTrue);
      _signal(svc2, 'call_accept', 'bob', h2.last('call_invite').callId);
      await Future<void>.delayed(Duration.zero);
      verify(() => h2.engine.setSpeakerphoneOn(true)).called(1);
      svc2.cancelOutgoing();
    });

    test('toggleSpeaker 切换并驱动引擎', () async {
      final h = _Harness();
      final svc = h.build();
      await svc.startCall('bob', CallType.audio);
      await svc.toggleSpeaker();
      expect(svc.speakerOn, isTrue);
      verify(() => h.engine.setSpeakerphoneOn(true)).called(1);
      svc.cancelOutgoing();
    });

    test('最小化通话中收到新邀请：自动拒绝且不影响最小化状态', () async {
      final h = _Harness();
      final svc = h.build();
      await svc.startCall('bob', CallType.video);
      await svc.toggleCamera();
      svc.minimize();
      _signal(svc, 'call_invite', 'alice', 'c-new', callType: 'audio');
      expect(svc.phase, CallPhase.calling, reason: '占线中，新邀请被自动拒绝');
      expect(svc.minimized, isTrue);
      expect(svc.cameraOff, isTrue, reason: '开关属于当前通话，不受新邀请影响');
      expect(h.sent('call_reject'), isTrue);
      svc.cancelOutgoing();
    });
  });
}
