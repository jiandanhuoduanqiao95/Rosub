// 阶段 R2：群会话通话入口契约测试
//
// R1 时群聊无通话入口（_isPrivateChat 门控）；R2 起群聊提供：
//   宽屏头部语音/视频键 → 群通话弹层（加入进行中的群通话 /
//   发起语音·视频群通话）；系统会话仍无入口；中途加入驱动
//   joinGroupRoom。私聊弹层（语音通话/视频通话）由 R1 既有行为锁定。
import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/screens/chat_screen.dart';
import 'package:chatroom_flutter/services/call_engine.dart';
import 'package:chatroom_flutter/services/call_service.dart';
import 'package:chatroom_flutter/services/socket_service.dart';
import 'package:chatroom_flutter/services/state_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mocktail/mocktail.dart';

class MockSocketService extends Mock implements SocketService {}

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
  @override
  void setListener(CallEngineListener? listener) {}

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

AppState get state => AppState.instance;

_FakeSignaling? _pumpedSignaling;

Future<CallService> _pumpGroupChat(
    WidgetTester tester, MockSocketService socket) async {
  final signaling = _FakeSignaling();
  _pumpedSignaling = signaling;
  final svc = CallService(
      signaling: signaling, engine: _FakeEngine(), selfUsername: () => 'alice');
  when(() => socket.callService).thenReturn(svc);
  when(() => socket.fetchGroupAnnouncements(any())).thenAnswer((_) async {});
  state
    ..setLoggedOut()
    ..setLoggedIn('alice', false)
    ..setGroups([
      Group(id: 7, name: '研发群', members: ['alice', 'bob', 'carol']),
    ])
    ..selectChat('group_7');
  await tester.pumpWidget(MaterialApp(home: ChatScreen(socketService: socket)));
  await tester.pump();
  return svc;
}

void main() {
  setUp(() {
    state.setLoggedOut();
    state.setConnectionStatus(ConnectionStatus.disconnected);
  });

  testWidgets('群会话宽屏头部有通话入口，弹出群通话层', (tester) async {
    final socket = MockSocketService();
    await _pumpGroupChat(tester, socket);

    await tester.tap(find.byTooltip('语音通话'));
    await tester.pumpAndSettle();
    expect(find.text('发起语音群通话'), findsOneWidget);
    expect(find.text('发起视频群通话'), findsOneWidget);
    expect(find.text('语音通话'), findsNothing, reason: '群会话不再复用一对一弹层');
  });

  testWidgets('gc9：群会话页"通话进行中"加入横幅——注册表驱动显示，点击加入', (tester) async {
    final socket = MockSocketService();
    final svc = await _pumpGroupChat(tester, socket);
    svc.knownGroupCalls[7] = const GroupCallRoomInfo(
      groupId: 7,
      groupName: '研发群',
      callId: 'room-x',
      callType: CallType.video,
      participants: ['bob', 'carol'],
    );
    // 直读 callService 的横幅在下次 build 生效——AppState 触发重建
    // （Mock 上 onCallPhaseChanged 字段存不住，ChatScreen 回调未挂）
    state.setConnectionStatus(ConnectionStatus.connected);
    await tester.pump();
    // 横幅文本带 📞 marker 前缀（$marker $text 拼接），用 textContaining
    expect(find.textContaining('群通话进行中（2人）'), findsOneWidget);

    await tester.tap(find.textContaining('群通话进行中（2人）'));
    await tester.pump();
    expect(_pumpedSignaling!.sends, contains('group_call_join'),
        reason: '点击横幅即请求加入');
  });

  testWidgets('gc9：自己在该群通话中时不显示加入横幅', (tester) async {
    final socket = MockSocketService();
    final svc = await _pumpGroupChat(tester, socket);
    svc.knownGroupCalls[7] = const GroupCallRoomInfo(
      groupId: 7,
      groupName: '研发群',
      callId: 'room-x',
      callType: CallType.audio,
      participants: ['alice', 'bob'],
    );
    await svc.startGroupCall(7, '研发群', CallType.audio);
    svc.notifyListeners();
    await tester.pump();
    expect(find.textContaining('群通话进行中'), findsNothing,
        reason: '自己已在通话中（主叫）不显示加入横幅');
    // 收尾：取消 → ended（CallScreen 经 _onPhaseChanged 自动 pop 卸载，
    // ticker 取消）→ 推进 2s endedTimer 防 pending
    svc.cancelOutgoing();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('群会话有进行中房间：弹层提供加入入口，点击后 joinGroupRoom', (tester) async {
    final socket = MockSocketService();
    final svc = await _pumpGroupChat(tester, socket);
    svc.knownGroupCalls[7] = const GroupCallRoomInfo(
      groupId: 7,
      groupName: '研发群',
      callId: 'room-x',
      callType: CallType.audio,
      participants: ['bob', 'carol'],
    );

    await tester.tap(find.byTooltip('视频通话'));
    await tester.pumpAndSettle();
    expect(find.text('加入进行中的群通话（2人）'), findsOneWidget);

    await tester.tap(find.text('加入进行中的群通话（2人）'));
    await tester.pumpAndSettle();
    expect(svc.phase, CallPhase.connecting);
    expect(svc.groupId, 7);
    expect(svc.knownGroupCalls[7]?.callId, 'room-x');
  });

  testWidgets('系统会话宽屏头部无通话入口', (tester) async {
    final socket = MockSocketService();
    final svc = CallService(
        signaling: _FakeSignaling(),
        engine: _FakeEngine(),
        selfUsername: () => 'alice');
    when(() => socket.callService).thenReturn(svc);
    state
      ..setLoggedIn('alice', false)
      ..selectChat('服务器');
    await tester
        .pumpWidget(MaterialApp(home: ChatScreen(socketService: socket)));
    await tester.pump();
    expect(find.byTooltip('语音通话'), findsNothing);
    expect(find.byTooltip('视频通话'), findsNothing);
  });
}
