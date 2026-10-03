// ============================================================
// opt1 P7 —— 无听筒设备（平板）语音通话默认外放 + 音量提示
// ============================================================
// 现象：平板通话声音小（通话音量滑条从未调过 + 无听筒设备语音通话
// 默认"听筒"实际走扬声器，UI 状态与路由不一致）。
// 契约：
//   ① CallService.noEarpieceDevice（UI 层经 AndroidSystem.hasEarpiece
//      预取注入）为 true 时语音通话默认 speakerOn=true（外放）；
//   ② false 时维持微信式默认（语音听筒/视频外放）——桌面零回归；
//   ③ 接通提示与通道接线源码扫描锁定。
// ============================================================

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

  CallService build() {
    when(() => engine.setListener(any())).thenAnswer((_) {});
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
        .thenAnswer((_) async => {'sdp': 'o', 'type': 'offer'});
    when(() => engine.createAnswer())
        .thenAnswer((_) async => {'sdp': 'a', 'type': 'answer'});
    when(() => engine.setRemoteOffer(any())).thenAnswer((_) async {});
    when(() => engine.setRemoteAnswer(any())).thenAnswer((_) async {});
    when(() => engine.addRemoteCandidate(any())).thenAnswer((_) async {});
    return CallService(signaling: signaling, engine: engine);
  }
}

String srcOf(String relPath) => File(relPath).readAsStringSync();

void main() {
  setUpAll(() {
    registerFallbackValue(_FakeListener());
    registerFallbackValue(<String, Object?>{});
  });

  group('opt1 P7 —— 无听筒默认路由', () {
    test('noEarpieceDevice=true：语音通话默认外放（speakerOn=true）',
        () async {
      final svc = _Harness().build();
      svc.noEarpieceDevice = true;
      await svc.startCall('bob', CallType.audio);
      expect(svc.speakerOn, isTrue,
          reason: '平板无听筒可切——语音通话默认外放，消除路由状态不一致');
    });

    test('noEarpieceDevice=false：语音听筒（基线不变）', () async {
      final svc = _Harness().build();
      await svc.startCall('bob', CallType.audio);
      expect(svc.speakerOn, isFalse);
    });

    test('noEarpieceDevice=true：视频通话仍外放', () async {
      final svc = _Harness().build();
      svc.noEarpieceDevice = true;
      await svc.startCall('bob', CallType.video);
      expect(svc.speakerOn, isTrue);
    });

    test('新通话复位后判定仍生效（被叫接听路径）', () async {
      final svc = _Harness().build();
      svc.noEarpieceDevice = true;
      // 来电：ringing → accept
      svc.handleSignal('call_invite', {'from': 'bob', 'call_id': 'c1'},
          Uint8List(0));
      expect(svc.phase, CallPhase.ringing);
      expect(svc.speakerOn, isTrue, reason: '_resetToggles 在来电进入即应用');
      await svc.acceptIncoming();
      expect(svc.speakerOn, isTrue);
    });
  });

  group('opt1 P7 —— 接线（源码扫描锁定）', () {
    test('hasEarpiece 通道两端', () {
      final kt = srcOf(
          'android/app/src/main/kotlin/com/example/chatroom_flutter/'
          'MainActivity.kt');
      expect(kt, contains('"hasEarpiece"'));
      expect(kt, contains('hasEarpiece()'));
      final dart = srcOf('lib/platform/android_system.dart');
      expect(dart, contains("invokeMethod<bool>('hasEarpiece')"));
    });

    test('ChatScreen 进入时预取注入', () {
      final src = srcOf('lib/screens/chat_screen.dart');
      expect(src, contains('noEarpieceDevice'));
      expect(src, contains('hasEarpiece'));
    });

    test('CallScreen 接通提示（每进程一次）', () {
      final src = srcOf('lib/screens/call_screen.dart');
      expect(src, contains('调高通话音量'));
      expect(src, contains('_volumeHintShown'));
    });
  });
}
