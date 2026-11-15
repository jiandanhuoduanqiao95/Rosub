// opt9 断线恢复：信令/状态机契约测试（mocktail 隔离信令与引擎）
//
// 覆盖：disconnected 提示与 35s 兜底超时 / connected 清除 / failed 恢复
// 重试上限 / 新信令 call_suspended·call_peer_back·call_resume_request /
// active 态重协商 offer/answer / 信令重连 caller(callee) 分流 / 群重入
// （重入 join + joined[self] 重建 mesh + 房间消失收场）/ 手动挂断不再恢复。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chatroom_flutter/services/call_engine.dart';
import 'package:chatroom_flutter/services/call_service.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockSignaling extends Mock implements CallSignaling {}

class _MockEngine extends Mock implements CallEngine {}

class _MockPeerSession extends Mock implements CallPeerSession {}

class _FakeListener extends Fake implements CallEngineListener {}

class _RecordedSend {
  final String type;
  final String? to;
  final String callId;
  final int? groupId;
  final String? body;
  _RecordedSend(this.type, this.to, this.callId, this.groupId, this.body);
}

class _Harness {
  final signaling = _MockSignaling();
  final engine = _MockEngine();
  final sends = <_RecordedSend>[];
  final sessions = <String, List<_MockPeerSession>>{};
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
        null,
        inv.namedArguments[#body] as String?,
      ));
    });
    when(() => signaling.sendGroupCall(any(), any(), any(),
        callType: any(named: 'callType'),
        mic: any(named: 'mic'),
        cam: any(named: 'cam'))).thenAnswer((inv) async {
      sends.add(_RecordedSend(
        inv.positionalArguments[0] as String,
        null,
        inv.positionalArguments[2] as String,
        inv.positionalArguments[1] as int,
        null,
      ));
    });
    when(() => engine.open(video: any(named: 'video')))
        .thenAnswer((_) async {});
    when(() => engine.ensureMedia(video: any(named: 'video')))
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
    when(() => engine.createPeerSession(any())).thenAnswer((inv) async {
      final peer = inv.positionalArguments[0] as String;
      final s = _MockPeerSession();
      sessions.putIfAbsent(peer, () => []).add(s);
      when(() => s.peerId).thenReturn(peer);
      when(() => s.remoteStream).thenReturn(null);
      when(() => s.createOffer())
          .thenAnswer((_) async => {'sdp': 'offer-$peer', 'type': 'offer'});
      when(() => s.createAnswer())
          .thenAnswer((_) async => {'sdp': 'answer-$peer', 'type': 'answer'});
      when(() => s.setRemoteOffer(any())).thenAnswer((_) async {});
      when(() => s.setRemoteAnswer(any())).thenAnswer((_) async {});
      when(() => s.addRemoteCandidate(any())).thenAnswer((_) async {});
      when(() => s.attachRenderer(any())).thenReturn(null);
      when(() => s.close()).thenAnswer((_) async {});
      return s;
    });
    return CallService(
      signaling: signaling,
      engine: engine,
      selfUsername: () => 'alice',
    );
  }

  bool sent(String type) => sends.any((s) => s.type == type);

  _RecordedSend last(String type) => sends.lastWhere((s) => s.type == type);

  List<_RecordedSend> all(String type) =>
      sends.where((s) => s.type == type).toList();
}

Uint8List _body(Map<String, dynamic> json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

void _signal(CallService svc, String type, Map<String, dynamic> header,
    {Map<String, dynamic>? body}) {
  svc.handleSignal(type, header, body == null ? Uint8List(0) : _body(body));
}

Future<CallService> _inGroupCall(_Harness h) async {
  final svc = h.build();
  _signal(svc, 'group_call_invite', {
    'from': 'bob',
    'call_id': 'room-1',
    'group_id': 7,
    'group_name': '研发群',
    'call_type': 'audio',
  });
  expect(svc.phase, CallPhase.ringing);
  await svc.acceptIncoming();
  await _drain();
  _signal(svc, 'group_call_joined', {
    'from': 'alice',
    'call_id': 'room-1',
    'group_id': 7,
    'participants': 'alice,bob',
    'call_type': 'audio',
  });
  await _drain();
  expect(h.sent('call_offer'), isTrue);
  return svc;
}

Future<void> _drain() => Future<void>.delayed(Duration.zero);

Future<CallService> _activeCallerCall(_Harness h) async {
  final svc = h.build();
  await svc.startCall('bob', CallType.audio);
  final id = h.last('call_invite').callId;
  _signal(svc, 'call_accept', {'from': 'bob', 'call_id': id});
  await _drain();
  _signal(svc, 'call_answer', {'from': 'bob', 'call_id': id},
      body: {'sdp': 'answer-sdp', 'type': 'answer'});
  await _drain();
  return svc;
}

Future<CallService> _activeCalleeCall(_Harness h, String callId) async {
  final svc = h.build();
  _signal(svc, 'call_invite', {
    'from': 'carl',
    'call_id': callId,
    'call_type': 'audio',
  });
  expect(svc.phase, CallPhase.ringing);
  await svc.acceptIncoming();
  _signal(svc, 'call_offer', {'from': 'carl', 'call_id': callId},
      body: {'sdp': 'offer-sdp', 'type': 'offer'});
  await _drain();
  h.listener!.onConnectionState('connected');
  expect(svc.phase, CallPhase.active);
  return svc;
}

void main() {
  setUpAll(() {
    registerFallbackValue(_FakeListener());
    registerFallbackValue(<String, Object?>{});
  });

  group('1:1 ICE 断连状态机', () {
    test('disconnected → 提示 + reconnecting，不挂断', () async {
      final h = _Harness();
      final svc = await _activeCallerCall(h);
      h.listener!.onConnectionState('disconnected');
      expect(svc.phase, CallPhase.active);
      expect(svc.reconnecting, isTrue);
      expect(svc.hint, isNotNull);
      expect(h.sent('call_hangup'), isFalse);
    });

    test('disconnected → connected → 恢复态清除', () async {
      final h = _Harness();
      final svc = await _activeCallerCall(h);
      h.listener!.onConnectionState('disconnected');
      h.listener!.onConnectionState('connected');
      expect(svc.reconnecting, isFalse);
      expect(svc.hint, isNull);
      expect(svc.reconnectTimer, isNull);
      expect(svc.phase, CallPhase.active);
    });

    test('failed 超限后 hangup 收场', () async {
      final h = _Harness();
      final svc = await _activeCallerCall(h);
      h.listener!.onConnectionState('failed');
      await _drain();
      h.listener!.onConnectionState('failed');
      await _drain();
      expect(svc.phase, CallPhase.active);
      h.listener!.onConnectionState('failed');
      await _drain();
      expect(h.sent('call_hangup'), isTrue);
      expect(svc.phase, CallPhase.ended);
      expect(svc.endReason, '连接失败');
    });

    test('failed（callee）→ 发 resume 请求而非挂断', () async {
      final h = _Harness();
      final svc = await _activeCalleeCall(h, 'call-c1');
      h.listener!.onConnectionState('failed');
      await _drain();
      expect(h.sent('call_resume_request'), isTrue);
      expect(h.last('call_resume_request').to, 'carl');
      expect(h.sent('call_hangup'), isFalse);
      expect(svc.phase, CallPhase.active);
    });

    test('35s 恢复兜底超时 → hangup + teardown（fakeAsync）', () {
      fakeAsync((async) {
        final h = _Harness();
        final svc = h.build();
        unawaited(svc.startCall('bob', CallType.audio));
        async.flushMicrotasks();
        final id = h.last('call_invite').callId;
        _signal(svc, 'call_accept', {'from': 'bob', 'call_id': id});
        async.flushMicrotasks();
        _signal(svc, 'call_answer', {'from': 'bob', 'call_id': id},
            body: {'sdp': 'a', 'type': 'answer'});
        async.flushMicrotasks();
        h.listener!.onConnectionState('disconnected');
        expect(svc.reconnecting, isTrue);
        async.elapse(const Duration(seconds: 35));
        expect(h.sent('call_hangup'), isTrue);
        expect(svc.phase, CallPhase.ended);
        expect(svc.endReason, '重连超时，通话结束');
        expect(svc.reconnectTimer, isNull);
      });
    });
  });

  group('恢复信令', () {
    test('call_suspended（对端断线）→ 提示不拆场', () async {
      final h = _Harness();
      final svc = await _activeCallerCall(h);
      _signal(svc, 'call_suspended',
          {'from': 'bob', 'call_id': h.last('call_invite').callId});
      expect(svc.reconnecting, isTrue);
      expect(svc.phase, CallPhase.active);
      expect(h.sent('call_hangup'), isFalse);
    });

    test('call_peer_back（caller 视角）→ 发起重协商 offer', () async {
      final h = _Harness();
      final svc = await _activeCallerCall(h);
      final id = h.last('call_invite').callId;
      h.listener!.onConnectionState('disconnected');
      _signal(svc, 'call_peer_back', {'from': 'bob', 'call_id': id});
      await _drain();
      expect(h.sent('call_offer'), isTrue);
      expect(svc.renegotiating, isTrue);
    });

    test('call_peer_back（callee 视角）→ 更新提示等待 offer', () async {
      final h = _Harness();
      final svc = await _activeCalleeCall(h, 'call-c2');
      h.listener!.onConnectionState('disconnected');
      _signal(svc, 'call_peer_back', {'from': 'carl', 'call_id': 'call-c2'});
      await _drain();
      expect(h.sent('call_offer'), isFalse);
      expect(h.sent('call_hangup'), isFalse);
      expect(svc.reconnecting, isTrue);
    });

    test('call_resume_request（caller 收）→ 发起新 offer', () async {
      final h = _Harness();
      final svc = await _activeCallerCall(h);
      final id = h.last('call_invite').callId;
      _signal(svc, 'call_resume_request', {'from': 'bob', 'call_id': id});
      await _drain();
      expect(h.sent('call_offer'), isTrue);
      expect(h.last('call_offer').to, 'bob');
    });

    test('active 态收到重协商 offer → answer（缓冲重置）', () async {
      final h = _Harness();
      final svc = await _activeCallerCall(h);
      final id = h.last('call_invite').callId;
      h.listener!.onConnectionState('failed');
      await _drain();
      _signal(svc, 'call_offer', {'from': 'bob', 'call_id': id},
          body: {'sdp': 're-offer', 'type': 'offer'});
      await _drain();
      verify(() => h.engine
              .setRemoteOffer({'sdp': 're-offer', 'type': 'offer'}))
          .called(1);
      expect(h.sent('call_answer'), isTrue);
      expect(svc.phase, CallPhase.active);
    });
  });

  group('信令断线重连', () {
    test('caller：媒体已死 → 恢复 offer；媒体存活 → 跳过', () async {
      final h = _Harness();
      final svc = await _activeCallerCall(h);
      expect(h.all('call_offer').length, 1);
      h.listener!.onConnectionState('failed');
      await _drain();
      svc.onSignalingReconnected();
      await _drain();
      expect(h.all('call_offer').length, 3,
          reason: '初次协商 + failed 恢复 + 信令重连恢复各一次 offer');

      final h2 = _Harness();
      final svc2 = await _activeCallerCall(h2);
      expect(h2.all('call_offer').length, 1);
      h2.listener!.onConnectionState('connected');
      svc2.onSignalingReconnected();
      await _drain();
      expect(h2.all('call_offer').length, 1,
          reason: '媒体存活（connected）不重协商');
    });

    test('callee：发 resume 请求', () async {
      final h = _Harness();
      final svc = await _activeCalleeCall(h, 'call-c3');
      h.listener!.onConnectionState('disconnected');
      svc.onSignalingReconnected();
      await _drain();
      expect(h.sent('call_resume_request'), isTrue);
    });

    test('重连后恢复预算重置（outage 期间的 failed 不计入）', () async {
      final h = _Harness();
      final svc = await _activeCallerCall(h);
      h.listener!.onConnectionState('failed');
      await _drain();
      h.listener!.onConnectionState('failed');
      await _drain();
      expect(svc.iceRestartAttempts, 2);
      svc.onSignalingReconnected();
      await _drain();
      expect(svc.iceRestartAttempts, 1,
          reason: '信令恢复重置预算并立即重新恢复一次');
    });

    test('idle 不触发恢复', () async {
      final h = _Harness();
      final svc = h.build();
      svc.onSignalingReconnected();
      expect(h.sent('call_offer'), isFalse);
      expect(h.sent('call_resume_request'), isFalse);
    });
  });

  group('群通话重入', () {
    test('信令重连 → 重新 join + joined[self] 后重建 mesh', () async {
      final h = _Harness();
      final svc = await _inGroupCall(h);
      expect(h.all('call_offer').length, 1);
      svc.onSignalingReconnected();
      await _drain();
      expect(h.sent('group_call_join'), isTrue);
      expect(svc.phase, CallPhase.connecting);
      expect(svc.reconnecting, isTrue);
      _signal(svc, 'group_call_joined', {
        'from': 'alice',
        'call_id': 'room-1',
        'group_id': 7,
        'participants': 'alice,bob',
        'call_type': 'audio',
      });
      await _drain();
      expect(h.all('call_offer').length, 2,
          reason: 'joined[self] 后对 bob 重新发 offer 重建 mesh 边');
    });

    test('2s fallback：joined 未到直接对无会话远端发 offer（fakeAsync）', () {
      fakeAsync((async) {
        final h = _Harness();
        final svc = h.build();
        _signal(svc, 'group_call_invite', {
          'from': 'bob',
          'call_id': 'room-1',
          'group_id': 7,
          'group_name': '研发群',
          'call_type': 'audio',
        });
        svc.acceptIncoming();
        async.flushMicrotasks();
        _signal(svc, 'group_call_joined', {
          'from': 'alice',
          'call_id': 'room-1',
          'group_id': 7,
          'participants': 'alice,bob',
          'call_type': 'audio',
        });
        async.flushMicrotasks();
        expect(h.sent('call_offer'), isTrue);
        svc.onSignalingReconnected();
        async.flushMicrotasks();
        expect(h.sent('group_call_join'), isTrue);
        async.elapse(const Duration(seconds: 3));
        expect(h.all('call_offer').length, greaterThanOrEqualTo(2));
      });
    });

    test('房间已结束（注册表无房间）→ teardown', () async {
      final h = _Harness();
      final svc = await _inGroupCall(h);
      _signal(svc, 'group_call_left', {
        'from': 'alice',
        'call_id': 'room-1',
        'group_id': 7,
        'participants': '',
        'ended': '1',
        'reason': 'cancel',
      });
      await _drain();
      expect(svc.phase, CallPhase.ended);
      final h2 = _Harness();
      final svc2 = h2.build();
      svc2.onSignalingReconnected();
      expect(h2.sent('group_call_join'), isFalse);
    });
  });

  group('手动收尾', () {
    test('重连等待中手动挂断 → teardown 且不再恢复', () async {
      final h = _Harness();
      final svc = await _activeCallerCall(h);
      h.listener!.onConnectionState('disconnected');
      expect(svc.reconnecting, isTrue);
      svc.hangup();
      expect(h.sent('call_hangup'), isTrue);
      expect(svc.phase, CallPhase.ended);
      expect(svc.reconnectTimer, isNull);
      expect(svc.hint, isNull);
      expect(svc.reconnecting, isFalse);
    });

    test('teardown 清理全部恢复状态', () async {
      final h = _Harness();
      final svc = await _activeCallerCall(h);
      final id = h.last('call_invite').callId;
      h.listener!.onConnectionState('failed');
      await _drain();
      _signal(svc, 'call_failed', {'from': 'bob', 'call_id': id,
          'reason': 'expired'});
      expect(svc.phase, CallPhase.ended);
      expect(svc.iceRestartAttempts, 0);
      expect(svc.renegotiating, isFalse);
      expect(svc.reconnectTimer, isNull);
    });
  });

  group('复核回归（opt9 修订轮）', () {
    test('R1 caller 恢复 answer 到达后清理定时器与提示', () async {
      final h = _Harness();
      final svc = await _activeCallerCall(h);
      final id = h.last('call_invite').callId;
      h.listener!.onConnectionState('disconnected');
      _signal(svc, 'call_resume_request', {'from': 'bob', 'call_id': id});
      await _drain();
      expect(svc.reconnectTimer, isNotNull);
      expect(svc.renegotiating, isTrue);
      _signal(svc, 'call_answer', {'from': 'bob', 'call_id': id},
          body: {'sdp': 're-answer', 'type': 'answer'});
      await _drain();
      expect(svc.phase, CallPhase.active);
      expect(svc.reconnectTimer, isNull,
          reason: '恢复成功必须取消 35s 兜底定时器（否则误挂断）');
      expect(svc.reconnecting, isFalse);
      expect(svc.hint, isNull);
    });

    test('R2 callee 恢复 offer 处理后清理定时器与提示', () async {
      final h = _Harness();
      final svc = await _activeCalleeCall(h, 'call-r2');
      h.listener!.onConnectionState('disconnected');
      _signal(svc, 'call_peer_back', {'from': 'carl', 'call_id': 'call-r2'});
      await _drain();
      _signal(svc, 'call_offer', {'from': 'carl', 'call_id': 'call-r2'},
          body: {'sdp': 're-offer', 'type': 'offer'});
      await _drain();
      expect(h.sent('call_answer'), isTrue);
      expect(svc.phase, CallPhase.active);
      expect(svc.reconnectTimer, isNull,
          reason: '恢复成功（answer 已发）必须取消 35s 兜底定时器');
      expect(svc.hint, isNull);
      expect(svc.reconnecting, isFalse);
    });

    test('R3 群来电 ringing：信令重连不自动加入房间', () async {
      final h = _Harness();
      final svc = h.build();
      _signal(svc, 'group_call_invite', {
        'from': 'bob',
        'call_id': 'room-r3',
        'group_id': 7,
        'group_name': '研发群',
        'call_type': 'audio',
      });
      expect(svc.phase, CallPhase.ringing);
      svc.onSignalingReconnected();
      await _drain();
      expect(svc.phase, CallPhase.ringing,
          reason: '信令重连不得把来电自动接听');
      expect(h.sent('group_call_join'), isFalse);
    });

    test('R4 群外呼 calling：信令重连不重入不收场', () async {
      final h = _Harness();
      final svc = h.build();
      final ok = await svc.startGroupCall(7, '研发群', CallType.audio);
      expect(ok, isTrue);
      expect(svc.phase, CallPhase.calling);
      svc.onSignalingReconnected();
      await _drain();
      expect(svc.phase, CallPhase.calling,
          reason: '外呼等待接听阶段不得重入/不得 teardown');
      expect(h.sent('group_call_join'), isFalse);
      expect(svc.endReason, isNull);
    });

    test('R5 群重入成功后提示与恢复态清理', () async {
      final h = _Harness();
      final svc = await _inGroupCall(h);
      svc.onSignalingReconnected();
      await _drain();
      expect(svc.phase, CallPhase.connecting);
      expect(svc.hint, isNotNull);
      expect(svc.rejoinInProgress, isTrue,
          reason: 'join 已发、mesh 重建未完成期间 guard 保持');
      _signal(svc, 'group_call_joined', {
        'from': 'alice',
        'call_id': 'room-1',
        'group_id': 7,
        'participants': 'alice,bob',
        'call_type': 'audio',
      });
      await _drain();
      expect(h.all('call_offer').length, 2);
      expect(svc.rejoinInProgress, isFalse,
          reason: 'joined[self] 触发的 mesh 重建完成后复位 guard');
      h.listener!.onPeerConnectionState('bob', 'connected');
      expect(svc.phase, CallPhase.active);
      expect(svc.reconnecting, isFalse);
      expect(svc.hint, isNull, reason: '群重入成功提示条必须消失');
      expect(svc.reconnectTimer, isNull);
      expect(svc.groupFallbackTimer, isNull,
          reason: 'peer 连通即恢复成功，2s fallback 定时器必须取消');
    });

    test('R6 群重入 35s 超时收场（join 后无 peer 连上）', () {
      fakeAsync((async) {
        final h = _Harness();
        final svc = h.build();
        _signal(svc, 'group_call_invite', {
          'from': 'bob',
          'call_id': 'room-r6',
          'group_id': 7,
          'group_name': '研发群',
          'call_type': 'audio',
        });
        svc.acceptIncoming();
        async.flushMicrotasks();
        _signal(svc, 'group_call_joined', {
          'from': 'alice',
          'call_id': 'room-r6',
          'group_id': 7,
          'participants': 'alice,bob',
          'call_type': 'audio',
        });
        async.flushMicrotasks();
        svc.onSignalingReconnected();
        async.flushMicrotasks();
        expect(svc.phase, CallPhase.connecting);
        async.elapse(const Duration(seconds: 36));
        async.flushMicrotasks();
        expect(svc.phase, CallPhase.ended,
            reason: 'join 后无人连上时 35s 兜底必须收场，不得永久 connecting');
        expect(h.sent('group_call_leave'), isTrue);
        expect(svc.endReason, '重连超时，通话结束');
      });
    });

    test('R7 媒体存活时 peer_back 不重协商且不残留提示', () async {
      final h = _Harness();
      final svc = await _activeCallerCall(h);
      expect(h.all('call_offer').length, 1);
      h.listener!.onConnectionState('connected');
      _signal(svc, 'call_peer_back',
          {'from': 'bob', 'call_id': h.last('call_invite').callId});
      await _drain();
      expect(h.all('call_offer').length, 1,
          reason: '媒体存活（connected）时 caller 不发无谓 offer');
      expect(svc.reconnecting, isFalse);
      expect(svc.hint, isNull);

      final h2 = _Harness();
      final svc2 = await _activeCalleeCall(h2, 'call-r7');
      h2.listener!.onConnectionState('connected');
      _signal(svc2, 'call_peer_back', {'from': 'carl', 'call_id': 'call-r7'});
      await _drain();
      expect(svc2.reconnecting, isFalse);
      expect(svc2.hint, isNull, reason: '媒体存活时 callee 提示不得残留');
    });

    test('R8 caller 恢复 offer 后 answer 前的新候选应缓冲', () async {
      final h = _Harness();
      final svc = await _activeCallerCall(h);
      final id = h.last('call_invite').callId;
      h.listener!.onConnectionState('failed');
      await _drain();
      expect(h.sent('call_offer'), isTrue);
      _signal(svc, 'call_ice', {'from': 'bob', 'call_id': id},
          body: {'candidate': 'c-recovery', 'sdpMid': '0'});
      await _drain();
      verifyNever(() => h.engine.addRemoteCandidate(any()));
      _signal(svc, 'call_answer', {'from': 'bob', 'call_id': id},
          body: {'sdp': 're-answer', 'type': 'answer'});
      await _drain();
      verify(() => h.engine.addRemoteCandidate(any())).called(1);
      expect(svc.phase, CallPhase.active);
    });
  });

  group('复核回归二轮（P2/P3 残差）', () {
    Map<String, dynamic> joinedHeader(String roomId) => {
          'from': 'alice',
          'call_id': roomId,
          'group_id': 7,
          'participants': 'alice,bob',
          'call_type': 'audio',
        };

    Map<String, dynamic> inviteHeader(String roomId) => {
          'from': 'bob',
          'call_id': roomId,
          'group_id': 7,
          'group_name': '研发群',
          'call_type': 'audio',
        };

    test('P2 joined[self] 取消 fallback：mesh 重建期间不重复建会话', () {
      fakeAsync((async) {
        final h = _Harness();
        final svc = h.build();
        _signal(svc, 'group_call_invite', inviteHeader('room-p2'));
        svc.acceptIncoming();
        async.flushMicrotasks();
        _signal(svc, 'group_call_joined', joinedHeader('room-p2'));
        async.flushMicrotasks();
        expect(h.all('call_offer').length, 1);
        svc.onSignalingReconnected();
        async.flushMicrotasks();
        expect(h.sent('group_call_join'), isTrue);
        final gate = Completer<CallPeerSession>();
        when(() => h.engine.createPeerSession('bob'))
            .thenAnswer((_) => gate.future);
        _signal(svc, 'group_call_joined', joinedHeader('room-p2'));
        async.flushMicrotasks();
        expect(svc.groupFallbackTimer, isNull,
            reason: 'joined[self] 启动 mesh 重建后 fallback 定时器必须取消');
        async.elapse(const Duration(seconds: 3));
        final s = _MockPeerSession();
        when(() => s.peerId).thenReturn('bob');
        when(() => s.createOffer())
            .thenAnswer((_) async => {'sdp': 'offer-bob-2', 'type': 'offer'});
        when(() => s.close()).thenAnswer((_) async {});
        when(() => s.attachRenderer(any())).thenReturn(null);
        gate.complete(s);
        async.flushMicrotasks();
        verify(() => h.engine.createPeerSession('bob')).called(2);
        expect(h.all('call_offer').length, 2,
            reason: '每个远端在重入后只应收到 1 个新 offer（初始 + 重入重建）');
      });
    });

    test('P3 重入等待旧 session 关闭完成后再发送 join', () {
      fakeAsync((async) {
        final h = _Harness();
        final svc = h.build();
        _signal(svc, 'group_call_invite', inviteHeader('room-p3'));
        svc.acceptIncoming();
        async.flushMicrotasks();
        _signal(svc, 'group_call_joined', joinedHeader('room-p3'));
        async.flushMicrotasks();
        final oldSession = h.sessions['bob']!.first;
        final closeGate = Completer<void>();
        when(() => oldSession.close()).thenAnswer((_) => closeGate.future);
        svc.onSignalingReconnected();
        async.flushMicrotasks();
        expect(h.all('group_call_join').length, 1,
            reason: '旧 session close 完成前不得发送重入 join');
        closeGate.complete();
        async.flushMicrotasks();
        expect(h.all('group_call_join').length, 2);
      });
    });

    test('P3 超限后 call_peer_back 仍重置预算并恢复', () async {
      final h = _Harness();
      final svc = await _activeCallerCall(h);
      final id = h.last('call_invite').callId;
      h.listener!.onConnectionState('failed');
      await _drain();
      h.listener!.onConnectionState('failed');
      await _drain();
      expect(svc.iceRestartAttempts, 2);
      _signal(svc, 'call_peer_back', {'from': 'bob', 'call_id': id});
      await _drain();
      expect(h.sent('call_hangup'), isFalse,
          reason: '对端回线触发的新恢复不得因旧预算直接挂断');
      expect(svc.phase, CallPhase.active);
      expect(h.all('call_offer').length, 4,
          reason: '初始 + 2 次 failed 恢复 + peer_back 恢复');
    });

    test('P3 超限后 call_resume_request 仍重置预算并恢复', () async {
      final h = _Harness();
      final svc = await _activeCallerCall(h);
      final id = h.last('call_invite').callId;
      h.listener!.onConnectionState('failed');
      await _drain();
      h.listener!.onConnectionState('failed');
      await _drain();
      _signal(svc, 'call_resume_request', {'from': 'bob', 'call_id': id});
      await _drain();
      expect(h.sent('call_hangup'), isFalse);
      expect(svc.phase, CallPhase.active);
      expect(h.all('call_offer').length, 4);
    });

    test('P3 active 重协商 answer 不重置通话起始时刻', () async {
      final h = _Harness();
      final svc = await _activeCallerCall(h);
      final startedAt = svc.activeSince;
      await Future<void>.delayed(const Duration(milliseconds: 15));
      final id = h.last('call_invite').callId;
      h.listener!.onConnectionState('failed');
      await _drain();
      _signal(svc, 'call_answer', {'from': 'bob', 'call_id': id},
          body: {'sdp': 're-answer', 'type': 'answer'});
      await _drain();
      expect(svc.phase, CallPhase.active);
      expect(svc.activeSince, same(startedAt),
          reason: 'active 态恢复成功不得把通话时长归零');
    });
  });
}
