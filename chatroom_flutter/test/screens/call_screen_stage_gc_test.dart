// 阶段 R2：群通话界面宫格契约测试
//
// 覆盖：群来电 ringing 变体（群名 + 加入/拒绝）、群语音宫格
// （全员头像瓦片 + 昵称 + 远端静音态）、控制排/最小化契约复用、
// 挂断经 group_call_leave、成员离开瓦片收缩。
// 视频瓦片渲染依赖平台渲染器（测试环境不可用），媒体区瓦片契约
// 以语音类型验证；一对一布局由 call_screen_stage_r_test.dart 锁定。
import 'dart:typed_data';

import 'package:chatroom_flutter/screens/call_screen.dart';
import 'package:chatroom_flutter/services/call_engine.dart';
import 'package:chatroom_flutter/services/call_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class _FakeSignaling implements CallSignaling {
  final sends = <String>[];

  @override
  Future<void> sendCall(String type, String to, String callId,
      {String? callType, String? body}) async {
    sends.add(type);
  }

  @override
  Future<void> sendGroupCall(String type, int groupId, String callId,
      {String? callType, String? mic, String? cam}) async {
    sends.add(type);
  }
}

class _FakePeerSession implements CallPeerSession {
  _FakePeerSession(this.peerId);

  @override
  final String peerId;

  @override
  MediaStream? get remoteStream => null;

  @override
  Future<Map<String, Object?>> createAnswer() async =>
      {'sdp': 'pa', 'type': 'answer'};

  @override
  Future<Map<String, Object?>> createOffer() async =>
      {'sdp': 'po', 'type': 'offer'};

  @override
  Future<void> addRemoteCandidate(Map<String, Object?> candidate) async {}

  @override
  void attachRenderer(RTCVideoRenderer? renderer) {}

  @override
  Future<void> close() async {}

  @override
  Future<void> setRemoteAnswer(Map<String, Object?> description) async {}

  @override
  Future<void> setRemoteOffer(Map<String, Object?> description) async {}
}

class _FakeEngine implements CallEngine {
  CallEngineListener? listener;

  @override
  void setListener(CallEngineListener? listener) {
    this.listener = listener;
  }

  @override
  Future<CallPeerSession> createPeerSession(String peerId) async =>
      _FakePeerSession(peerId);

  @override
  CallPeerSession? peerSession(String peerId) => null;

  @override
  Future<void> open({required bool video}) async {}

  @override
  Future<void> ensureMedia({required bool video}) async {}

  @override
  Future<Map<String, Object?>> createAnswer() async =>
      {'sdp': 'a', 'type': 'answer'};

  @override
  Future<Map<String, Object?>> createOffer() async =>
      {'sdp': 'o', 'type': 'offer'};

  @override
  Future<void> addRemoteCandidate(Map<String, Object?> candidate) async {}

  @override
  Future<void> setRemoteAnswer(Map<String, Object?> description) async {}

  @override
  Future<void> setRemoteOffer(Map<String, Object?> description) async {}

  @override
  Future<void> attachRenderers({
    RTCVideoRenderer? remote,
    RTCVideoRenderer? local,
  }) async {}

  @override
  Future<void> close() async {}

  @override
  bool get hasVideo => false;

  @override
  bool get hasLocalMedia => true;

  @override
  Future<int> videoInputCount() async => 0;

  @override
  Future<void> switchCamera() async {}

  @override
  MediaStream? get localStream => null;

  @override
  Future<void> setMicMuted(bool muted) async {}

  @override
  Future<void> setCameraEnabled(bool enabled) async {}

  @override
  Future<void> setSpeakerphoneOn(bool on) async {}
}

void _phoneScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(550, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('群来电 ringing 变体：群名 + 加入/拒绝按钮', (tester) async {
    final signaling = _FakeSignaling();
    final svc = CallService(
        signaling: signaling,
        engine: _FakeEngine(),
        selfUsername: () => 'alice');
    svc.handleSignal(
        'group_call_invite',
        {
          'from': 'bob',
          'call_id': 'room-1',
          'group_id': 7,
          'call_type': 'audio',
          'group_name': '研发群',
        },
        Uint8List(0));

    await tester.pumpWidget(MaterialApp(home: CallScreen(callService: svc)));
    await tester.pump();
    expect(find.text('研发群'), findsOneWidget);
    expect(find.text('群语音通话'), findsOneWidget);
    expect(find.text('邀请你加入群语音通话'), findsOneWidget);
    expect(find.byIcon(Icons.call), findsOneWidget, reason: '绿色加入键');
    expect(find.byIcon(Icons.call_end), findsOneWidget, reason: '红色拒绝键');

    await tester.tap(find.byIcon(Icons.call));
    await tester.pump();
    expect(svc.phase, CallPhase.connecting);
    expect(signaling.sentCount('group_call_join'), 1);
  });

  testWidgets('群语音通话宫格：全员瓦片带昵称 + 远端静音态 + 控制排', (tester) async {
    final engine = _FakeEngine();
    final signaling = _FakeSignaling();
    _phoneScreen(tester);
    final svc = CallService(
        signaling: signaling, engine: engine, selfUsername: () => 'alice');
    expect(await svc.startGroupCall(7, '研发群', CallType.audio), isTrue);
    final roomId = svc.callId!;
    svc.handleSignal(
        'group_call_joined',
        {
          'from': 'bob',
          'call_id': roomId,
          'group_id': 7,
          'participants': 'alice,bob,carol',
          'call_type': 'audio',
        },
        Uint8List(0));
    await tester.pump();
    svc.handleSignal('group_call_media',
        {'from': 'bob', 'call_id': roomId, 'mic': '1'}, Uint8List(0));
    engine.listener!.onPeerConnectionState('bob', 'connected');
    await tester.pump();

    await tester.pumpWidget(MaterialApp(home: CallScreen(callService: svc)));
    await tester.pump();
    expect(find.text('研发群'), findsOneWidget);
    expect(find.text('我'), findsOneWidget, reason: '自己占首格');
    expect(find.text('bob'), findsOneWidget);
    expect(find.text('carol'), findsOneWidget);
    expect(find.byIcon(Icons.mic_off_rounded), findsOneWidget,
        reason: '远端静音态图标');
    expect(find.textContaining('3人'), findsOneWidget, reason: '状态行显示参与人数');
    expect(find.byTooltip('最小化（不挂断）'), findsOneWidget);
    expect(find.byIcon(Icons.call_end), findsOneWidget);
    expect(find.byIcon(Icons.videocam_rounded), findsNothing,
        reason: '语音群通话无摄像头键');
    expect(find.byIcon(Icons.volume_up_rounded), findsNothing,
        reason: '桌面宿主不显示免提键');

    await tester.tap(find.byTooltip('最小化（不挂断）'));
    await tester.pump();
    expect(svc.minimized, isTrue);
    svc.cancelOutgoing();
  });

  testWidgets('成员离开：瓦片收缩（participants 刷新驱动重建）', (tester) async {
    final engine = _FakeEngine();
    final signaling = _FakeSignaling();
    _phoneScreen(tester);
    final svc = CallService(
        signaling: signaling, engine: engine, selfUsername: () => 'alice');
    await svc.startGroupCall(7, '研发群', CallType.audio);
    final roomId = svc.callId!;
    svc.handleSignal(
        'group_call_joined',
        {
          'from': 'bob',
          'call_id': roomId,
          'group_id': 7,
          'participants': 'alice,bob,carol',
          'call_type': 'audio',
        },
        Uint8List(0));
    await tester.pump();
    engine.listener!.onPeerConnectionState('bob', 'connected');

    await tester.pumpWidget(MaterialApp(home: CallScreen(callService: svc)));
    await tester.pump();
    expect(find.text('carol'), findsOneWidget);

    svc.handleSignal(
        'group_call_left',
        {
          'from': 'carol',
          'call_id': roomId,
          'group_id': 7,
          'participants': 'alice,bob',
          'ended': '0',
          'reason': 'hangup',
        },
        Uint8List(0));
    await tester.pump();
    expect(find.text('carol'), findsNothing);
    expect(find.text('bob'), findsOneWidget);
    svc.cancelOutgoing();
  });

  testWidgets('群通话挂断经 group_call_leave + ended 自动返回', (tester) async {
    final engine = _FakeEngine();
    final signaling = _FakeSignaling();
    final svc = CallService(
        signaling: signaling, engine: engine, selfUsername: () => 'alice');
    await svc.startGroupCall(7, '研发群', CallType.audio);
    final roomId = svc.callId!;
    svc.handleSignal(
        'group_call_joined',
        {
          'from': 'bob',
          'call_id': roomId,
          'group_id': 7,
          'participants': 'alice,bob',
          'call_type': 'audio',
        },
        Uint8List(0));
    await tester.pump();
    engine.listener!.onPeerConnectionState('bob', 'connected');

    await tester.pumpWidget(const MaterialApp(home: Text('home')));
    tester.state<NavigatorState>(find.byType(Navigator)).push(MaterialPageRoute(
          builder: (_) => CallScreen(callService: svc),
        ));
    await tester.pumpAndSettle();
    expect(find.byType(CallScreen), findsOneWidget);

    await tester.tap(find.byIcon(Icons.call_end));
    await tester.pump();
    expect(svc.phase, CallPhase.ended);
    expect(signaling.sentCount('group_call_leave'), 1,
        reason: '挂断即 leave（个人挂断只移除自己）');

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.byType(CallScreen), findsNothing, reason: 'ended→idle 后自动返回');
  });
}

extension on _FakeSignaling {
  int sentCount(String type) => sends.where((s) => s == type).length;
}
