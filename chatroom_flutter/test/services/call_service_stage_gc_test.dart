// 阶段 R2：群语音/群视频多方通话服务层契约测试（mocktail 隔离信令与引擎）
//
// 覆盖：群外呼/来电 ringing 变体/加入与逐对协商（新加入者发起 offer）/
// ICE 按对端缓冲冲刷/成员变更（joined/left/ended）/knownGroupCalls
// 进行中房间注册表与中途加入/group_call_media 静音·摄像头态/
// 占线自动回拒/45s 无人接听自取消/挂断收尾。1:1 回归由
// call_service_stage_r_test.dart 锁定，本文件只覆盖群路径。
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

class _FakeCallSound implements CallSound {
  final List<String> calls = [];
  @override
  Future<void> playRingtone() async => calls.add('ringtone');
  @override
  Future<void> stopRingtone() async => calls.add('stop');
  @override
  Future<void> playHangup() async => calls.add('hangup');
}

class _RecordedSend {
  final String type;
  final String? to;
  final String callId;
  final String? callType;
  final int? groupId;
  final String? mic;
  final String? cam;
  final String? body;
  _RecordedSend(this.type, this.to, this.callId, this.callType, this.groupId,
      this.mic, this.cam, this.body);
}

class _Harness {
  final signaling = _MockSignaling();
  final engine = _MockEngine();
  final sends = <_RecordedSend>[];
  final sessions = <String, List<_MockPeerSession>>{};
  final sound = _FakeCallSound();
  CallEngineListener? listener;

  _MockPeerSession sessionFor(String peer, {int index = 0}) =>
      sessions[peer]![index];

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
        null,
        null,
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
        inv.namedArguments[#callType] as String?,
        inv.positionalArguments[1] as int,
        inv.namedArguments[#mic] as String?,
        inv.namedArguments[#cam] as String?,
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
      sound: sound,
    );
  }

  bool sent(String type) => sends.any((s) => s.type == type);

  _RecordedSend last(String type) => sends.lastWhere((s) => s.type == type);

  List<_RecordedSend> all(String type) =>
      sends.where((s) => s.type == type).toList();
}

Map<String, dynamic> _header(String from, String callId,
    {int? groupId,
    String? callType,
    String? groupName,
    String? participants,
    String? ended,
    String? reason,
    String? mic,
    String? cam}) {
  final h = <String, dynamic>{'from': from, 'call_id': callId};
  if (groupId != null) h['group_id'] = groupId;
  if (callType != null) h['call_type'] = callType;
  if (groupName != null) h['group_name'] = groupName;
  if (participants != null) h['participants'] = participants;
  if (ended != null) h['ended'] = ended;
  if (reason != null) h['reason'] = reason;
  if (mic != null) h['mic'] = mic;
  if (cam != null) h['cam'] = cam;
  return h;
}

void main() {
  setUpAll(() {
    registerFallbackValue(_FakeListener());
    registerFallbackValue(<String, Object?>{});
  });

  group('群外呼', () {
    test('startGroupCall：invite 携带 group_id/call_type，参与者为自身', () async {
      final h = _Harness();
      final svc = h.build();
      final ok = await svc.startGroupCall(7, '研发群', CallType.video);
      expect(ok, isTrue);
      expect(svc.phase, CallPhase.calling);
      expect(svc.isGroupCall, isTrue);
      expect(svc.groupId, 7);
      expect(svc.groupName, '研发群');
      expect(svc.participants, ['alice']);
      final invite = h.last('group_call_invite');
      expect(invite.groupId, 7);
      expect(invite.callType, 'video');
      expect(invite.callId, isNotEmpty);
    });

    test('占线时 startGroupCall 拒绝', () async {
      final h = _Harness();
      final svc = h.build();
      await svc.startGroupCall(7, '研发群', CallType.audio);
      final ok = await svc.startGroupCall(8, '另一群', CallType.audio);
      expect(ok, isFalse);
      expect(svc.groupId, 7);
    });

    test('45s 无人加入自动取消（leave + ended）', () {
      fakeAsync((async) {
        final h = _Harness();
        final svc = h.build();
        svc.startGroupCall(7, '研发群', CallType.audio);
        async.elapse(const Duration(seconds: 46));
        expect(h.sent('group_call_leave'), isTrue);
        expect(h.last('group_call_leave').groupId, 7);
        expect(svc.phase, CallPhase.ended);
        expect(svc.endReason, '无人接听');
      });
    });
  });

  group('群来电（ringing 变体）', () {
    test('invite → ringing，展示群名与类型', () {
      final h = _Harness();
      final svc = h.build();
      svc.handleSignal(
          'group_call_invite',
          _header('bob', 'room-1',
              groupId: 7, callType: 'video', groupName: '研发群'),
          Uint8List(0));
      expect(svc.phase, CallPhase.ringing);
      expect(svc.isGroupCall, isTrue);
      expect(svc.groupId, 7);
      expect(svc.groupName, '研发群');
      expect(svc.type, CallType.video);
      expect(svc.participants, ['bob']);
      expect(svc.knownGroupCalls[7]?.callId, 'room-1');
    });

    test('占线时群来电自动回拒（leave=decline），不影响既有通话', () async {
      final h = _Harness();
      final svc = h.build();
      await svc.startGroupCall(7, '研发群', CallType.audio);
      svc.handleSignal(
          'group_call_invite',
          _header('bob', 'room-2',
              groupId: 8, callType: 'audio', groupName: '另一群'),
          Uint8List(0));
      expect(svc.phase, CallPhase.calling);
      expect(svc.groupId, 7);
      final leave = h.last('group_call_leave');
      expect(leave.groupId, 8);
      expect(leave.callId, 'room-2');
    });

    test('拒绝：振铃中 leave=decline + ended', () {
      final h = _Harness();
      final svc = h.build();
      svc.handleSignal(
          'group_call_invite',
          _header('bob', 'room-1',
              groupId: 7, callType: 'audio', groupName: '研发群'),
          Uint8List(0));
      svc.rejectIncoming();
      expect(h.sent('group_call_leave'), isTrue);
      expect(svc.phase, CallPhase.ended);
      expect(svc.endReason, '已拒绝');
    });

    test('多端收敛：同账号其他设备加入 → 本设备停止响铃', () {
      final h = _Harness();
      final svc = h.build();
      svc.handleSignal(
          'group_call_invite',
          _header('bob', 'room-1',
              groupId: 7, callType: 'audio', groupName: '研发群'),
          Uint8List(0));
      svc.handleSignal(
          'group_call_joined',
          _header('alice', 'room-1',
              groupId: 7, participants: 'alice,bob', callType: 'audio'),
          Uint8List(0));
      expect(svc.phase, CallPhase.ended);
      expect(svc.endReason, '已在其他设备接听');
      expect(h.sent('group_call_leave'), isFalse, reason: '其他设备已接听，本设备不应补发拒绝');
    });

    test('多端收敛：同账号其他设备拒绝/超时 → 本设备停止响铃', () {
      final h = _Harness();
      final svc = h.build();
      svc.handleSignal(
          'group_call_invite',
          _header('bob', 'room-1',
              groupId: 7, callType: 'audio', groupName: '研发群'),
          Uint8List(0));
      svc.handleSignal(
          'group_call_left',
          _header('alice', 'room-1',
              groupId: 7, participants: 'bob', ended: '0', reason: 'declined'),
          Uint8List(0));
      expect(svc.phase, CallPhase.ended);
      expect(svc.endReason, '已在其他设备处理');
    });
  });

  group('加入与逐对协商（新加入者发起 offer）', () {
    test('acceptIncoming：ensureMedia + group_call_join + connecting', () async {
      final h = _Harness();
      final svc = h.build();
      svc.handleSignal(
          'group_call_invite',
          _header('bob', 'room-1',
              groupId: 7, callType: 'video', groupName: '研发群'),
          Uint8List(0));
      await svc.acceptIncoming();
      expect(h.sent('group_call_join'), isTrue);
      expect(h.last('group_call_join').callId, 'room-1');
      verify(() => h.engine.ensureMedia(video: true)).called(1);
      expect(svc.phase, CallPhase.connecting);
    });

    test('joined(self)：向既有成员逐对创建会话并发 offer', () async {
      final h = _Harness();
      final svc = h.build();
      svc.handleSignal(
          'group_call_invite',
          _header('bob', 'room-1',
              groupId: 7, callType: 'audio', groupName: '研发群'),
          Uint8List(0));
      await svc.acceptIncoming();
      svc.handleSignal(
          'group_call_joined',
          _header('alice', 'room-1',
              groupId: 7, participants: 'alice,bob,carol', callType: 'audio'),
          Uint8List(0));
      await Future<void>.delayed(Duration.zero);
      expect(svc.participants, ['alice', 'bob', 'carol']);
      verify(() => h.engine.createPeerSession('bob')).called(1);
      verify(() => h.engine.createPeerSession('carol')).called(1);
      final offers = h.all('call_offer');
      expect(offers.map((o) => o.to).toSet(), {'bob', 'carol'});
      expect(jsonDecode(offers.firstWhere((o) => o.to == 'bob').body!),
          {'sdp': 'offer-bob', 'type': 'offer'});
      expect(svc.phase, CallPhase.connecting, reason: '首个对端连通前保持接通中');
    });

    test('gc2 加固：本地媒体轨道缺失时禁止发空 offer（leave + 显式错误）', () async {
      final h = _Harness();
      final svc = h.build();
      when(() => h.engine.hasLocalMedia).thenReturn(false);
      svc.handleSignal(
          'group_call_invite',
          _header('bob', 'room-1',
              groupId: 7, callType: 'video', groupName: '研发群'),
          Uint8List(0));
      await svc.acceptIncoming();
      svc.handleSignal(
          'group_call_joined',
          _header('alice', 'room-1',
              groupId: 7, participants: 'alice,bob', callType: 'video'),
          Uint8List(0));
      await Future<void>.delayed(Duration.zero);
      // 无轨道不得创建会话发空壳 offer
      verifyNever(() => h.engine.createPeerSession(any()));
      expect(h.sent('call_offer'), isFalse);
      expect(h.sent('group_call_leave'), isTrue);
      expect(svc.endReason, '无法访问麦克风或摄像头');
      expect(svc.phase, CallPhase.ended);
    });

    test('gc2 加固：ensureMedia 抛错（getUserMedia 空轨道）→ leave + 显式错误', () async {
      final h = _Harness();
      final svc = h.build();
      when(() => h.engine.ensureMedia(video: any(named: 'video')))
          .thenThrow(StateError('getUserMedia 返回空轨道 audio=0 video=0'));
      svc.handleSignal(
          'group_call_invite',
          _header('bob', 'room-1',
              groupId: 7, callType: 'video', groupName: '研发群'),
          Uint8List(0));
      await svc.acceptIncoming();
      await Future<void>.delayed(Duration.zero);
      expect(h.sent('group_call_join'), isTrue);
      expect(h.sent('group_call_leave'), isTrue);
      expect(svc.endReason, '无法访问麦克风或摄像头');
      expect(svc.phase, CallPhase.ended);
    });

    test('joined(other)：主叫转接通中并备媒体，不主动发 offer（等对方）', () async {
      final h = _Harness();
      final svc = h.build();
      await svc.startGroupCall(7, '研发群', CallType.audio);
      final roomId = h.last('group_call_invite').callId;
      svc.handleSignal(
          'group_call_joined',
          _header('bob', roomId,
              groupId: 7, participants: 'alice,bob', callType: 'audio'),
          Uint8List(0));
      await Future<void>.delayed(Duration.zero);
      expect(svc.participants, ['alice', 'bob']);
      expect(svc.phase, CallPhase.connecting, reason: '主叫在首个成员加入后转接通中');
      verify(() => h.engine.ensureMedia(video: false)).called(1);
      verifyNever(() => h.engine.createPeerSession(any()));
      expect(h.sent('call_offer'), isFalse);
      // carol 再加入：仍不主动发 offer，等她的 offer 到达
      svc.handleSignal(
          'group_call_joined',
          _header('carol', roomId,
              groupId: 7, participants: 'alice,bob,carol', callType: 'audio'),
          Uint8List(0));
      await Future<void>.delayed(Duration.zero);
      expect(svc.participants, ['alice', 'bob', 'carol']);
      verifyNever(() => h.engine.createPeerSession(any()));
    });

    test('call_offer（既有成员侧）：建会话 + answer 回发', () async {
      final h = _Harness();
      final svc = h.build();
      svc.handleSignal(
          'group_call_invite',
          _header('bob', 'room-1',
              groupId: 7, callType: 'audio', groupName: '研发群'),
          Uint8List(0));
      await svc.acceptIncoming();
      svc.handleSignal(
          'group_call_joined',
          _header('alice', 'room-1',
              groupId: 7, participants: 'alice,bob', callType: 'audio'),
          Uint8List(0));
      await Future<void>.delayed(Duration.zero);
      // carol 中途加入后向本机（alice）发 offer
      svc.handleSignal('call_offer', _header('carol', 'room-1'),
          Uint8List.fromList(utf8.encode('{"sdp":"o-carol","type":"offer"}')));
      await Future<void>.delayed(Duration.zero);
      verify(() => h.engine.createPeerSession('carol')).called(1);
      verify(() => h
          .sessionFor('carol')
          .setRemoteOffer({'sdp': 'o-carol', 'type': 'offer'})).called(1);
      final answer = h.last('call_answer');
      expect(answer.to, 'carol');
      expect(answer.callId, 'room-1');
      expect(
          jsonDecode(answer.body!), {'sdp': 'answer-carol', 'type': 'answer'});
    });

    test('call_answer + ICE 缓冲冲刷（joiner 侧按对端路由）', () async {
      final h = _Harness();
      final svc = h.build();
      svc.handleSignal(
          'group_call_invite',
          _header('bob', 'room-1',
              groupId: 7, callType: 'audio', groupName: '研发群'),
          Uint8List(0));
      await svc.acceptIncoming();
      svc.handleSignal(
          'group_call_joined',
          _header('alice', 'room-1',
              groupId: 7, participants: 'alice,bob', callType: 'audio'),
          Uint8List(0));
      await Future<void>.delayed(Duration.zero);
      // answer 未到时 bob 的 ICE 先到：缓冲
      final cand = {'candidate': 'c-1', 'sdpMid': '0', 'sdpMLineIndex': 0};
      svc.handleSignal('call_ice', _header('bob', 'room-1'),
          Uint8List.fromList(utf8.encode(jsonEncode(cand))));
      await Future<void>.delayed(Duration.zero);
      verifyNever(() => h.sessionFor('bob').addRemoteCandidate(any()));
      svc.handleSignal('call_answer', _header('bob', 'room-1'),
          Uint8List.fromList(utf8.encode('{"sdp":"a-bob","type":"answer"}')));
      await Future<void>.delayed(Duration.zero);
      verify(() => h
          .sessionFor('bob')
          .setRemoteAnswer({'sdp': 'a-bob', 'type': 'answer'})).called(1);
      verify(() => h.sessionFor('bob').addRemoteCandidate(cand)).called(1);
    });

    test('首个对端 connected → active', () async {
      final h = _Harness();
      final svc = h.build();
      svc.handleSignal(
          'group_call_invite',
          _header('bob', 'room-1',
              groupId: 7, callType: 'audio', groupName: '研发群'),
          Uint8List(0));
      await svc.acceptIncoming();
      svc.handleSignal(
          'group_call_joined',
          _header('alice', 'room-1',
              groupId: 7, participants: 'alice,bob', callType: 'audio'),
          Uint8List(0));
      await Future<void>.delayed(Duration.zero);
      h.listener!.onPeerConnectionState('bob', 'connected');
      expect(svc.phase, CallPhase.active);
      expect(svc.activeSince, isNotNull);
    });

    test('本地 ICE 候选带对端路由外发', () async {
      final h = _Harness();
      final svc = h.build();
      svc.handleSignal(
          'group_call_invite',
          _header('bob', 'room-1',
              groupId: 7, callType: 'audio', groupName: '研发群'),
          Uint8List(0));
      await svc.acceptIncoming();
      svc.handleSignal(
          'group_call_joined',
          _header('alice', 'room-1',
              groupId: 7, participants: 'alice,bob', callType: 'audio'),
          Uint8List(0));
      await Future<void>.delayed(Duration.zero);
      h.listener!.onPeerLocalCandidate('bob', {'candidate': 'x'});
      await Future<void>.delayed(Duration.zero);
      final ice = h.last('call_ice');
      expect(ice.to, 'bob');
      expect(ice.callId, 'room-1');
      expect(jsonDecode(ice.body!)['candidate'], 'x');
    });
  });

  group('离开与结束', () {
    test('hangup：leave + ended，会话随引擎关闭', () async {
      final h = _Harness();
      final svc = h.build();
      svc.handleSignal(
          'group_call_invite',
          _header('bob', 'room-1',
              groupId: 7, callType: 'audio', groupName: '研发群'),
          Uint8List(0));
      await svc.acceptIncoming();
      svc.handleSignal(
          'group_call_joined',
          _header('alice', 'room-1',
              groupId: 7, participants: 'alice,bob', callType: 'audio'),
          Uint8List(0));
      await Future<void>.delayed(Duration.zero);
      h.listener!.onPeerConnectionState('bob', 'connected');
      svc.hangup();
      expect(h.sent('group_call_leave'), isTrue);
      expect(svc.phase, CallPhase.ended);
      expect(svc.endReason, '通话已结束');
      verify(() => h.engine.close()).called(1);
    });

    test('成员离开（ended=0）：参与者收缩 + 对端会话关闭', () async {
      final h = _Harness();
      final svc = h.build();
      svc.handleSignal(
          'group_call_invite',
          _header('bob', 'room-1',
              groupId: 7, callType: 'audio', groupName: '研发群'),
          Uint8List(0));
      await svc.acceptIncoming();
      svc.handleSignal(
          'group_call_joined',
          _header('alice', 'room-1',
              groupId: 7, participants: 'alice,bob,carol', callType: 'audio'),
          Uint8List(0));
      await Future<void>.delayed(Duration.zero);
      svc.handleSignal(
          'group_call_left',
          _header('bob', 'room-1',
              groupId: 7,
              participants: 'alice,carol',
              ended: '0',
              reason: 'hangup'),
          Uint8List(0));
      expect(svc.participants, ['alice', 'carol']);
      verify(() => h.sessionFor('bob').close()).called(1);
      expect(svc.phase, CallPhase.connecting);
    });

    test('房间结束（ended=1）：全体收尾 + 注册表清除', () async {
      final h = _Harness();
      final svc = h.build();
      svc.handleSignal(
          'group_call_invite',
          _header('bob', 'room-1',
              groupId: 7, callType: 'audio', groupName: '研发群'),
          Uint8List(0));
      await svc.acceptIncoming();
      svc.handleSignal(
          'group_call_joined',
          _header('alice', 'room-1',
              groupId: 7, participants: 'alice,bob', callType: 'audio'),
          Uint8List(0));
      await Future<void>.delayed(Duration.zero);
      expect(svc.knownGroupCalls[7], isNotNull);
      svc.handleSignal(
          'group_call_left',
          _header('bob', 'room-1',
              groupId: 7, participants: '', ended: '1', reason: 'hangup'),
          Uint8List(0));
      expect(svc.phase, CallPhase.ended);
      expect(svc.endReason, '通话已结束');
      expect(svc.knownGroupCalls[7], isNull);
    });

    test('自己 leave 的回显不二次收尾', () async {
      final h = _Harness();
      final svc = h.build();
      svc.handleSignal(
          'group_call_invite',
          _header('bob', 'room-1',
              groupId: 7, callType: 'audio', groupName: '研发群'),
          Uint8List(0));
      await svc.acceptIncoming();
      svc.handleSignal(
          'group_call_joined',
          _header('alice', 'room-1',
              groupId: 7, participants: 'alice,bob', callType: 'audio'),
          Uint8List(0));
      await Future<void>.delayed(Duration.zero);
      svc.hangup();
      svc.handleSignal(
          'group_call_left',
          _header('alice', 'room-1',
              groupId: 7, participants: 'bob', ended: '0', reason: 'hangup'),
          Uint8List(0));
      expect(svc.endReason, '通话已结束');
    });
  });

  group('媒体态中继与注册表', () {
    test('toggleMic 群通话中发 group_call_media，远端静音态更新瓦片', () async {
      final h = _Harness();
      final svc = h.build();
      await svc.startGroupCall(7, '研发群', CallType.audio);
      await svc.toggleMic();
      final media = h.last('group_call_media');
      expect(media.mic, '1');
      expect(media.cam, '0');
      svc.handleSignal(
          'group_call_media',
          _header('bob', h.last('group_call_invite').callId, mic: '1'),
          Uint8List(0));
      expect(svc.peerMicMuted('bob'), isTrue);
      expect(svc.peerMicMuted('carol'), isFalse);
    });

    test('空闲时 joined/left 广播只更新注册表', () {
      final h = _Harness();
      final svc = h.build();
      svc.handleSignal(
          'group_call_joined',
          _header('bob', 'room-x',
              groupId: 9,
              callType: 'video',
              groupName: '另一群',
              participants: 'bob,carol'),
          Uint8List(0));
      expect(svc.phase, CallPhase.idle);
      expect(svc.knownGroupCalls[9]?.callId, 'room-x');
      expect(svc.knownGroupCalls[9]?.participants, ['bob', 'carol']);
      expect(svc.knownGroupCalls[9]?.groupName, '另一群');
      svc.handleSignal(
          'group_call_left',
          _header('carol', 'room-x',
              groupId: 9, participants: 'bob', ended: '0', reason: 'hangup'),
          Uint8List(0));
      expect(svc.knownGroupCalls[9]?.participants, ['bob']);
      svc.handleSignal(
          'group_call_left',
          _header('bob', 'room-x',
              groupId: 9, participants: '', ended: '1', reason: 'hangup'),
          Uint8List(0));
      expect(svc.knownGroupCalls[9], isNull);
    });

    test('joinGroupRoom：中途加入进行中的房间', () async {
      final h = _Harness();
      final svc = h.build();
      svc.handleSignal(
          'group_call_joined',
          _header('bob', 'room-x',
              groupId: 9,
              callType: 'video',
              groupName: '另一群',
              participants: 'bob,carol'),
          Uint8List(0));
      final ok = await svc.joinGroupRoom(9);
      expect(ok, isTrue);
      expect(svc.phase, CallPhase.connecting);
      expect(svc.participants, ['alice', 'bob', 'carol']);
      expect(h.sent('group_call_join'), isTrue);
      expect(h.last('group_call_join').callId, 'room-x');
      verify(() => h.engine.ensureMedia(video: true)).called(1);
      // joined(self) 确认后向 bob/carol 逐对发 offer
      svc.handleSignal(
          'group_call_joined',
          _header('alice', 'room-x',
              groupId: 9, participants: 'alice,bob,carol', callType: 'video'),
          Uint8List(0));
      await Future<void>.delayed(Duration.zero);
      expect(h.all('call_offer').map((o) => o.to).toSet(), {'bob', 'carol'});
    });

    test('joinGroupRoom：无进行中房间或占线时拒绝', () async {
      final h = _Harness();
      final svc = h.build();
      expect(await svc.joinGroupRoom(9), isFalse);
      await svc.startGroupCall(7, '研发群', CallType.audio);
      expect(await svc.joinGroupRoom(9), isFalse);
    });
  });

  group('gc8 通话音效', () {
    test('群来电播铃 / 接听停铃 / 挂断停铃+挂断音', () async {
      final h = _Harness();
      final svc = h.build();
      svc.handleSignal(
          'group_call_invite',
          _header('bob', 'room-1',
              groupId: 7, callType: 'video', groupName: '研发群'),
          Uint8List(0));
      expect(svc.phase, CallPhase.ringing);
      expect(h.sound.calls, ['ringtone'], reason: '来电即响铃');

      await svc.acceptIncoming();
      expect(h.sound.calls.last, 'stop', reason: '接听停铃');
      expect(h.sound.calls.contains('hangup'), isFalse, reason: '接听不播挂断音');

      svc.hangup();
      await Future<void>.delayed(Duration.zero);
      expect(h.sound.calls.last, 'hangup', reason: '曾接通后挂断播挂断音');
    });

    test('ringing 拒接只停铃不播挂断音', () async {
      final h = _Harness();
      final svc = h.build();
      svc.handleSignal(
          'group_call_invite',
          _header('bob', 'room-1',
              groupId: 7, callType: 'audio', groupName: '研发群'),
          Uint8List(0));
      expect(h.sound.calls, ['ringtone']);
      svc.rejectIncoming();
      expect(h.sound.calls, ['ringtone', 'stop'], reason: '未接通拒接只停铃');
    });
  });
}
