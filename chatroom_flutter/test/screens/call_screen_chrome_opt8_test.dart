// ============================================================
// opt8 功能一 —— 通话页上下栏收起/展开
// ============================================================
// 契约：
//   1) connecting/active 舞台点击 = 顶部信息条 + 底部控制排同时收起；
//      再点恢复（AnimatedOpacity 淡入淡出 + IgnorePointer 防透明层吃点击）；
//   2) 栏背景点击也收起；栏内按钮功能不受影响（InkWell 优先）；
//   3) 隐藏后点原挂断键位置 = 只恢复栏，绝不挂断（最重要安全用例）；
//   4) 自己悬浮小窗：拖动不触发切换，点击触发；
//   5) ringing/calling 不允许隐藏（接听/拒绝/取消键恒可见）；
//   6) ended 强制恢复可见（结束原因不被遮挡）；restore 新页面默认可见。
// 注意：active 态有 1s ticker，禁用 pumpAndSettle，一律 pump(Duration)。
// ============================================================

import 'dart:convert';
import 'dart:typed_data';

import 'package:chatroom_flutter/screens/call_screen.dart';
import 'package:chatroom_flutter/services/call_engine.dart';
import 'package:chatroom_flutter/services/call_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

const _stageKey = Key('call_stage');
const _headerKey = Key('call_stage_header');
const _controlsKey = Key('call_stage_controls');
const _pipKey = Key('call_stage_self_pip');

class _FakeSignaling implements CallSignaling {
  final sends = <String>[];

  int sentCount(String type) => sends.where((t) => t == type).length;

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
  RTCPeerConnection? get peerConnection => null;

  @override
  Future<double?> inboundAudioLevel() async => null;

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

double _headerOpacity(WidgetTester tester) =>
    tester.widget<AnimatedOpacity>(find.byKey(_headerKey)).opacity;

double _controlsOpacity(WidgetTester tester) =>
    tester.widget<AnimatedOpacity>(find.byKey(_controlsKey)).opacity;

/// 注意：ModalRoute 自带一层 IgnorePointer（转场期忽略指针），祖先查找
/// 会命中多个——必须取最近的一个（.first = 命中序即由近及远）
bool _headerIgnored(WidgetTester tester) => tester
    .widget<IgnorePointer>(find.ancestor(
            of: find.byKey(_headerKey), matching: find.byType(IgnorePointer))
        .first)
    .ignoring;

bool _controlsIgnored(WidgetTester tester) => tester
    .widget<IgnorePointer>(find.ancestor(
            of: find.byKey(_controlsKey), matching: find.byType(IgnorePointer))
        .first)
    .ignoring;

/// 1:1 去电 → active（call_accept + call_answer 驱动）
Future<CallService> pumpActiveAudio(WidgetTester tester) async {
  final signaling = _FakeSignaling();
  final svc = CallService(
      signaling: signaling, engine: _FakeEngine(), selfUsername: () => 'alice');
  await svc.startCall('bob', CallType.audio);
  svc.handleSignal(
      'call_accept', {'from': 'bob', 'call_id': svc.callId}, Uint8List(0));
  await tester.pump();
  svc.handleSignal('call_answer', {'from': 'bob', 'call_id': svc.callId},
      Uint8List.fromList(utf8.encode('{"sdp":"a","type":"answer"}')));
  await tester.pump();
  expect(svc.phase, CallPhase.active);
  await tester.pumpWidget(MaterialApp(home: CallScreen(callService: svc)));
  await tester.pump();
  return svc;
}

/// 1:1 去电视频 → active（PIP 存在）
Future<CallService> pumpActiveVideo(WidgetTester tester) async {
  final signaling = _FakeSignaling();
  final svc = CallService(
      signaling: signaling, engine: _FakeEngine(), selfUsername: () => 'alice');
  await svc.startCall('bob', CallType.video);
  svc.handleSignal(
      'call_accept', {'from': 'bob', 'call_id': svc.callId}, Uint8List(0));
  await tester.pump();
  svc.handleSignal('call_answer', {'from': 'bob', 'call_id': svc.callId},
      Uint8List.fromList(utf8.encode('{"sdp":"a","type":"answer"}')));
  await tester.pump();
  expect(svc.phase, CallPhase.active);
  await tester.pumpWidget(MaterialApp(home: CallScreen(callService: svc)));
  await tester.pump();
  return svc;
}

/// 群通话 → active（joined + 对端 connected 驱动）
Future<(CallService, _FakeSignaling)> pumpActiveGroup(
    WidgetTester tester,
    CallType type) async {
  final engine = _FakeEngine();
  final signaling = _FakeSignaling();
  final svc = CallService(
      signaling: signaling, engine: engine, selfUsername: () => 'alice');
  await svc.startGroupCall(7, '研发群', type);
  final roomId = svc.callId!;
  svc.handleSignal(
      'group_call_joined',
      {
        'from': 'bob',
        'call_id': roomId,
        'group_id': 7,
        'participants': 'alice,bob',
        'call_type': type.name,
      },
      Uint8List(0));
  await tester.pump();
  engine.listener!.onPeerConnectionState('bob', 'connected');
  await tester.pump();
  expect(svc.phase, CallPhase.active);
  await tester.pumpWidget(MaterialApp(home: CallScreen(callService: svc)));
  await tester.pump();
  return (svc, signaling);
}

/// 收尾：挂断推进 fake 时钟（ended→idle 2s 定时器），卸载组件取消 ticker
Future<void> teardownCall(WidgetTester tester, CallService svc) async {
  svc.hangup();
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 10));
}

void main() {
  group('opt8 F1 —— 1:1 语音 active', () {
    testWidgets('初始态：上下栏可见（opacity 1，IgnorePointer 关）', (tester) async {
      final svc = await pumpActiveAudio(tester);
      expect(_headerOpacity(tester), 1);
      expect(_controlsOpacity(tester), 1);
      expect(_headerIgnored(tester), isFalse);
      expect(_controlsIgnored(tester), isFalse);
      await teardownCall(tester, svc);
    });

    testWidgets('点舞台：两栏同时收起（opacity 0 + IgnorePointer 置位）',
        (tester) async {
      final svc = await pumpActiveAudio(tester);
      await tester.tap(find.byKey(_stageKey));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_headerOpacity(tester), 0);
      expect(_controlsOpacity(tester), 0);
      expect(_headerIgnored(tester), isTrue);
      expect(_controlsIgnored(tester), isTrue);
      expect(svc.phase, CallPhase.active);
      await teardownCall(tester, svc);
    });

    testWidgets('再点舞台：两栏恢复', (tester) async {
      final svc = await pumpActiveAudio(tester);
      await tester.tap(find.byKey(_stageKey));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(_stageKey));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_headerOpacity(tester), 1);
      expect(_controlsOpacity(tester), 1);
      expect(_headerIgnored(tester), isFalse);
      expect(_controlsIgnored(tester), isFalse);
      await teardownCall(tester, svc);
    });

    testWidgets('点顶部栏背景：收起', (tester) async {
      final svc = await pumpActiveAudio(tester);
      await tester.tapAt(const Offset(500, 28));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_headerOpacity(tester), 0);
      expect(_controlsOpacity(tester), 0);
      await teardownCall(tester, svc);
    });

    testWidgets('点底部栏背景：收起且不挂断', (tester) async {
      final svc = await pumpActiveAudio(tester);
      // 底部渐变容器 padding 区（按钮行下方），非按钮
      await tester.tapAt(const Offset(20, 592));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_headerOpacity(tester), 0);
      expect(_controlsOpacity(tester), 0);
      expect(svc.phase, CallPhase.active, reason: '点背景不触发挂断');
      await teardownCall(tester, svc);
    });

    testWidgets('点静音键：功能生效且栏不收起', (tester) async {
      final svc = await pumpActiveAudio(tester);
      expect(svc.micMuted, isFalse);
      await tester.tap(find.byIcon(Icons.mic_rounded));
      await tester.pump();
      expect(svc.micMuted, isTrue);
      expect(_headerOpacity(tester), 1);
      expect(_controlsOpacity(tester), 1);
      await teardownCall(tester, svc);
    });

    testWidgets('隐藏后点原挂断键位置：只恢复栏，不挂断', (tester) async {
      final svc = await pumpActiveAudio(tester);
      await tester.tap(find.byKey(_stageKey));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_headerOpacity(tester), 0);
      final hangupCenter = tester.getCenter(find.byIcon(Icons.call_end));
      await tester.tapAt(hangupCenter);
      await tester.pump(const Duration(milliseconds: 200));
      expect(_headerOpacity(tester), 1, reason: '点击恢复上下栏');
      expect(_controlsOpacity(tester), 1);
      expect(svc.phase, CallPhase.active, reason: '绝不误触挂断');
      await teardownCall(tester, svc);
    });

    testWidgets('ended 时强制恢复可见（不卡隐藏态，结束原因可见）', (tester) async {
      final svc = await pumpActiveAudio(tester);
      await tester.tap(find.byKey(_stageKey));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_headerOpacity(tester), 0);
      svc.hangup();
      await tester.pump();
      // ended 走非舞台布局：舞台/上下栏整体替换为结束页——结束原因必须
      // 可见，不得因隐藏态丢失（chrome 状态同步复位为可见）
      expect(find.byKey(_stageKey), findsNothing);
      expect(find.text('通话已结束'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('opt8 F1 —— 1:1 视频 active（悬浮小窗）', () {
    testWidgets('拖动 PIP：位置变化且不触发收起', (tester) async {
      final svc = await pumpActiveVideo(tester);
      final before = tester.getRect(find.byKey(_pipKey));
      await tester.drag(find.byKey(_pipKey), const Offset(-100, 60));
      await tester.pump();
      final after = tester.getRect(find.byKey(_pipKey));
      expect(after.left, lessThan(before.left), reason: '小窗跟手移动');
      expect(_headerOpacity(tester), 1, reason: '拖动不触发上下栏切换');
      expect(_controlsOpacity(tester), 1);
      await teardownCall(tester, svc);
    });

    testWidgets('点 PIP：触发收起/恢复', (tester) async {
      final svc = await pumpActiveVideo(tester);
      await tester.tap(find.byKey(_pipKey));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_headerOpacity(tester), 0);
      expect(_controlsOpacity(tester), 0);
      await tester.tap(find.byKey(_pipKey));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_headerOpacity(tester), 1);
      await teardownCall(tester, svc);
    });
  });

  group('opt8 F1 —— 群通话', () {
    testWidgets('群视频 active：点舞台收起/恢复', (tester) async {
      final (svc, _) = await pumpActiveGroup(tester, CallType.video);
      expect(find.byKey(_pipKey), findsOneWidget, reason: '视频群通话自己走小窗');
      await tester.tap(find.byKey(_stageKey));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_headerOpacity(tester), 0);
      expect(_controlsOpacity(tester), 0);
      await tester.tap(find.byKey(_stageKey));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_headerOpacity(tester), 1);
      expect(_controlsOpacity(tester), 1);
      await teardownCall(tester, svc);
    });

    testWidgets('群语音 active：点舞台收起/恢复', (tester) async {
      final (svc, _) = await pumpActiveGroup(tester, CallType.audio);
      expect(find.byKey(_pipKey), findsNothing);
      await tester.tap(find.byKey(_stageKey));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_headerOpacity(tester), 0);
      expect(_controlsOpacity(tester), 0);
      expect(svc.participants, containsAll(['alice', 'bob']),
          reason: '隐藏不影响宫格数据');
      await tester.tap(find.byKey(_stageKey));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_headerOpacity(tester), 1);
      expect(_controlsOpacity(tester), 1);
      await teardownCall(tester, svc);
    });

    testWidgets('隐藏态下成员离开：宫格照常更新', (tester) async {
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
            'participants': 'alice,bob,carol',
            'call_type': 'audio',
          },
          Uint8List(0));
      await tester.pump();
      engine.listener!.onPeerConnectionState('bob', 'connected');
      await tester.pump();
      await tester.pumpWidget(MaterialApp(home: CallScreen(callService: svc)));
      await tester.pump();
      await tester.tap(find.byKey(_stageKey));
      await tester.pump(const Duration(milliseconds: 200));
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
      expect(find.text('carol'), findsNothing, reason: '隐藏态宫格仍实时增减');
      expect(_headerOpacity(tester), 0, reason: '栏保持隐藏');
      await teardownCall(tester, svc);
    });
  });

  group('opt8 F1 —— ringing / calling 不允许隐藏', () {
    testWidgets('connecting（接通中）：点舞台可收起/恢复（spec 允许隐藏）',
        (tester) async {
      final signaling = _FakeSignaling();
      final svc = CallService(
          signaling: signaling,
          engine: _FakeEngine(),
          selfUsername: () => 'alice');
      await svc.startCall('bob', CallType.audio);
      svc.handleSignal(
          'call_accept', {'from': 'bob', 'call_id': svc.callId}, Uint8List(0));
      await tester.pump();
      expect(svc.phase, CallPhase.connecting);
      await tester.pumpWidget(MaterialApp(home: CallScreen(callService: svc)));
      await tester.pump();
      expect(find.byKey(_stageKey), findsOneWidget, reason: 'connecting 有舞台');
      await tester.tap(find.byKey(_stageKey));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_headerOpacity(tester), 0, reason: 'connecting 允许收起');
      expect(_controlsOpacity(tester), 0);
      await tester.tap(find.byKey(_stageKey));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_headerOpacity(tester), 1);
      // 收尾：connecting 挂断 → ended 2s → idle
      svc.hangup();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('去电 calling：点画面不隐藏，取消键恒可见', (tester) async {
      final signaling = _FakeSignaling();
      final svc = CallService(
          signaling: signaling, engine: _FakeEngine(), selfUsername: () => 'alice');
      await svc.startCall('bob', CallType.audio);
      await tester.pumpWidget(MaterialApp(home: CallScreen(callService: svc)));
      await tester.pump();
      expect(find.byKey(_stageKey), findsNothing);
      expect(find.byKey(_headerKey), findsNothing);
      expect(find.byIcon(Icons.call_end), findsOneWidget, reason: '取消键可见');
      await tester.tapAt(const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 200));
      expect(svc.phase, CallPhase.calling);
      expect(find.byIcon(Icons.call_end), findsOneWidget);
      svc.cancelOutgoing();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('来电 ringing：无舞台手势，接听/拒绝键恒可见', (tester) async {
      final svc = CallService(
          signaling: _FakeSignaling(),
          engine: _FakeEngine(),
          selfUsername: () => 'alice');
      svc.handleSignal(
          'call_invite',
          {'from': 'bob', 'call_id': 'r1', 'call_type': 'audio'},
          Uint8List(0));
      await tester.pumpWidget(MaterialApp(home: CallScreen(callService: svc)));
      await tester.pump();
      expect(svc.phase, CallPhase.ringing);
      expect(find.byKey(_stageKey), findsNothing);
      expect(find.byIcon(Icons.call), findsOneWidget, reason: '接听键可见');
      expect(find.byIcon(Icons.call_end), findsOneWidget, reason: '拒绝键可见');
      await tester.tapAt(const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 200));
      expect(svc.phase, CallPhase.ringing);
      expect(find.byIcon(Icons.call), findsOneWidget);
      svc.rejectIncoming();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('opt8 F1 —— 最小化/恢复', () {
    testWidgets('restore 新建的通话页默认上下栏可见', (tester) async {
      final signaling = _FakeSignaling();
      final svc = CallService(
          signaling: signaling, engine: _FakeEngine(), selfUsername: () => 'alice');
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: Text('CHAT'))));
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      nav.push(MaterialPageRoute(
          builder: (_) => CallScreen(callService: svc)));
      // 泵足 400ms：路由转场（约 300ms）完成后再断言，避免转场期间
      // 新旧两页短暂并存导致同 key 重复命中
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      await svc.startCall('bob', CallType.audio);
      svc.handleSignal(
          'call_accept', {'from': 'bob', 'call_id': svc.callId}, Uint8List(0));
      await tester.pump();
      svc.handleSignal('call_answer', {'from': 'bob', 'call_id': svc.callId},
          Uint8List.fromList(utf8.encode('{"sdp":"a","type":"answer"}')));
      await tester.pump();
      expect(svc.phase, CallPhase.active);

      await tester.tap(find.byKey(_stageKey));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_headerOpacity(tester), 0);

      svc.minimize();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('CHAT'), findsOneWidget, reason: '最小化关闭通话页');

      nav.push(MaterialPageRoute(
          builder: (_) => CallScreen(callService: svc)));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(_headerOpacity(tester), 1, reason: '新页面默认栏可见');
      expect(_controlsOpacity(tester), 1);
      await teardownCall(tester, svc);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
