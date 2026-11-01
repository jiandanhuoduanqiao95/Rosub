// ============================================================
// opt8 设备端最小集成（Android 真机 integration_test）
// ============================================================
// 覆盖：
//   ① 功能一：假引擎驱动 1:1 语音 active 通话页，真机触摸验证上下栏
//      收起/展开（call_stage 手势在真机触摸/鼠标下的行为与自动化
//      Widget 测试一致，此文件做设备端冒烟）；
//   ② 功能二：悬浮球通道无权限也不崩溃（hasOverlayPermission 返回
//      false 或 true；show/hideCallBubble 调用不抛异常——真机上的
//      实际显示/拖动/点击表现归手动矩阵 TESTING_GUIDE §37.3）。
//
// 运行（Android 设备连接后）：
//   flutter test integration_test/call_ui_device_test.dart -d <device>
// ============================================================

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';

import 'package:chatroom_flutter/platform/android_system.dart';
import 'package:chatroom_flutter/screens/call_screen.dart';
import 'package:chatroom_flutter/services/call_engine.dart';
import 'package:chatroom_flutter/services/call_service.dart';

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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('opt8 F1 设备端：active 通话页点舞台收起/再点展开',
      (tester) async {
    final svc = CallService(
        signaling: _FakeSignaling(),
        engine: _FakeEngine(),
        selfUsername: () => 'alice');
    await svc.startCall('bob', CallType.audio);
    svc.handleSignal(
        'call_accept', {'from': 'bob', 'call_id': svc.callId}, Uint8List(0));
    await tester.pump();
    svc.handleSignal('call_answer', {'from': 'bob', 'call_id': svc.callId},
        Uint8List.fromList(utf8.encode('{"sdp":"a","type":"answer"}')));
    await tester.pump();
    expect(svc.phase, CallPhase.active);

    await tester.pumpWidget(MaterialApp(home: CallScreen(callService: svc)));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byKey(const Key('call_stage')));
    await tester.pump(const Duration(milliseconds: 300));
    double headerOpacity(WidgetTester t) => t
        .widget<AnimatedOpacity>(
            find.byKey(const Key('call_stage_header')))
        .opacity;
    expect(headerOpacity(tester), 0, reason: '点舞台收起上下栏');

    await tester.tap(find.byKey(const Key('call_stage')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(headerOpacity(tester), 1, reason: '再点恢复上下栏');

    svc.hangup();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('opt8 F2 设备端：悬浮球通道无权限也不崩溃', (tester) async {
    // 权限未授予时 hasOverlayPermission 返回 false（或已授予 true），
    // show/hideCallBubble 调用不抛异常（权限缺失时原生侧静默降级）。
    // 注意：show 会以 FGS 语义拉起服务（ensureForeground）——测试收尾
    // 必须 stopCallForeground 撤场，勿给设备留下"通话中"幽灵通知
    final granted = await AndroidSystem.hasOverlayPermission();
    expect(granted, anyOf(isNull, isA<bool>()),
        reason: '真机上为 true/false；通道异常时 null（可空语义）');
    await AndroidSystem.showCallBubble(video: false);
    await tester.pump(const Duration(milliseconds: 200));
    await AndroidSystem.hideCallBubble(video: false);
    await tester.pump(const Duration(milliseconds: 200));
    // P1 复审：hide 已不再拉起 FGS（服务非前台时直接撤场）；若 show
    // 已把服务带到前台，这里显式停止——双重保证测试后零残留
    await AndroidSystem.stopCallForeground();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
  });
}
