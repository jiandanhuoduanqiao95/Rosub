// 阶段 R1 真机二轮回归：通话界面结束态自动返回
//
// 根因锁定：idle 自动返回曾用 maybePop()——被本页 PopScope(canPop:false)
// 拦截并回调 onPopInvokedWithResult(didPop:false)，其 idle 分支再次
// maybePop 造成无限递归（Android 栈溢出闪退 / Linux 卡死）。
// 本测试锁定：取消通话后 2s（ended→idle）自动 pop 回上一页且仅一次。
import 'dart:convert';
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
}

class _FakeEngine implements CallEngine {
  @override
  Future<Map<String, Object?>> createAnswer() async =>
      {'sdp': 'a', 'type': 'answer'};

  @override
  Future<Map<String, Object?>> createOffer() async =>
      {'sdp': 'o', 'type': 'offer'};

  @override
  Future<void> addRemoteCandidate(Map<String, Object?> candidate) async {}

  @override
  Future<void> attachRenderers({
    RTCVideoRenderer? remote,
    RTCVideoRenderer? local,
  }) async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> open({required bool video}) async {}

  @override
  void setListener(CallEngineListener? listener) {}

  @override
  Future<void> setRemoteAnswer(Map<String, Object?> description) async {}

  @override
  Future<void> setRemoteOffer(Map<String, Object?> description) async {}

  @override
  bool get hasVideo => false;

  @override
  MediaStream? get localStream => null;

  @override
  Future<void> setMicMuted(bool muted) async {}

  @override
  Future<void> setCameraEnabled(bool enabled) async {}

  @override
  Future<void> setSpeakerphoneOn(bool on) async {}
}

void main() {
  testWidgets('通话中控制排：静音/挂断/最小化（语音通话无摄像头键；桌面无免提键）',
      (tester) async {
    final signaling = _FakeSignaling();
    final svc = CallService(signaling: signaling, engine: _FakeEngine());
    // testWidgets 跑在 FakeAsync zone：Future.delayed 永不完成，
    // 用 tester.pump 推进零时长定时器驱动状态机
    await svc.startCall('bob', CallType.audio);
    svc.handleSignal('call_accept',
        {'from': 'bob', 'call_id': svc.callId}, Uint8List(0));
    await tester.pump();
    svc.handleSignal(
        'call_answer',
        {'from': 'bob', 'call_id': svc.callId},
        Uint8List.fromList(utf8.encode('{"sdp":"a","type":"answer"}')));
    await tester.pump();
    expect(svc.phase, CallPhase.active);

    await tester.pumpWidget(MaterialApp(home: CallScreen(callService: svc)));
    await tester.pump();
    expect(find.byTooltip('最小化（不挂断）'), findsOneWidget);
    expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
    expect(find.byIcon(Icons.call_end), findsOneWidget);
    expect(find.byIcon(Icons.videocam_rounded), findsNothing,
        reason: '语音通话不显示摄像头开关');
    expect(find.byIcon(Icons.volume_up_rounded), findsNothing,
        reason: '桌面宿主不显示免提键（恒系统输出）');

    await svc.toggleMic();
    await tester.pump();
    expect(find.byIcon(Icons.mic_off_rounded), findsOneWidget);

    await tester.tap(find.byTooltip('最小化（不挂断）'));
    await tester.pump();
    expect(svc.minimized, isTrue);
    svc.cancelOutgoing();
  });

  testWidgets('取消通话后 2s 自动返回上一页（maybePop 递归回归锁）', (tester) async {
    final signaling = _FakeSignaling();
    final svc = CallService(signaling: signaling, engine: _FakeEngine());

    await tester.pumpWidget(const MaterialApp(home: Text('home')));
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .push(MaterialPageRoute(
          builder: (_) => CallScreen(callService: svc),
        ));
    await tester.pumpAndSettle();
    expect(find.byType(CallScreen), findsOneWidget);

    expect(await svc.startCall('bob', CallType.audio), isTrue);
    await tester.pump();
    expect(find.text('正在等待对方接听…'), findsOneWidget);

    svc.cancelOutgoing();
    await tester.pump();
    expect(find.text('已取消'), findsOneWidget);
    expect(find.byType(CallScreen), findsOneWidget,
        reason: 'ended 展示期（2s）内仍在通话页');

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(svc.phase, CallPhase.idle, reason: '3s 后服务应回到 idle');
    expect(find.byType(CallScreen), findsNothing,
        reason: 'ended→idle 后应自动返回上一页');
    expect(find.text('home'), findsOneWidget);
    expect(signaling.sentCount('call_cancel'), 1,
        reason: '取消信令恰好发送一次（递归会重复触发返回链）');
  });

  testWidgets('ended 态按系统返回直接退出通话页（不重入状态机）', (tester) async {
    final signaling = _FakeSignaling();
    final svc = CallService(signaling: signaling, engine: _FakeEngine());

    await tester.pumpWidget(const MaterialApp(home: Text('home')));
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .push(MaterialPageRoute(
          builder: (_) => CallScreen(callService: svc),
        ));
    await tester.pumpAndSettle();

    expect(await svc.startCall('bob', CallType.audio), isTrue);
    await tester.pump();
    svc.cancelOutgoing();
    await tester.pump();

    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    // 模拟 PopScope 拦截路径：maybePop（系统返回手势在 canPop:false 下的入口）
    await nav.maybePop();
    await tester.pumpAndSettle();
    expect(find.byType(CallScreen), findsNothing,
        reason: 'ended 态 maybePop 应经 onPopInvoked 分支直接退出，不得递归');
    // 等服务 ended→idle 定时器走完，测试结束时无挂起 Timer
    await tester.pump(const Duration(seconds: 3));
  });
}

extension on _FakeSignaling {
  int sentCount(String type) =>
      sends.where((s) => s == type).length;
}
