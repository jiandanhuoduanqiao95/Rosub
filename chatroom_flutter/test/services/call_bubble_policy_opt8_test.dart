// ============================================================
// opt8 功能二 —— 通话悬浮球显示策略（CallPresentation）
// ============================================================
// 直接测纯 Dart 策略：前台恒不显示（应用内悬浮条接管）；后台
// calling/connecting/active 显示；后台 ringing 不显示（来电通知接管）、
// ended/idle 不显示。平台门控（仅 Android 调用）由 ChatScreen 负责，
// 不在本策略内（chat_screen_call_lifecycle_opt8_test 已锁平台接线）。
// ============================================================

import 'package:chatroom_flutter/services/call_presentation.dart';
import 'package:chatroom_flutter/services/call_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('opt8 F2 —— shouldShowCallBubble', () {
    test('前台（appResumed）恒 false——应用内悬浮条/通话页接管', () {
      for (final phase in CallPhase.values) {
        expect(
          CallPresentation.shouldShowCallBubble(
              phase: phase, appResumed: true),
          isFalse,
          reason: '$phase 前台不显示悬浮球',
        );
      }
    });

    test('后台 + calling/connecting/active → true（去电未接也要能回）', () {
      for (final phase in [
        CallPhase.calling,
        CallPhase.connecting,
        CallPhase.active,
      ]) {
        expect(
          CallPresentation.shouldShowCallBubble(
              phase: phase, appResumed: false),
          isTrue,
          reason: '$phase 后台显示悬浮球',
        );
      }
    });

    test('后台 + ringing → false（来电通知接管，避免双重提醒）', () {
      expect(
        CallPresentation.shouldShowCallBubble(
            phase: CallPhase.ringing, appResumed: false),
        isFalse,
      );
    });

    test('后台 + ended/idle → false', () {
      expect(
        CallPresentation.shouldShowCallBubble(
            phase: CallPhase.ended, appResumed: false),
        isFalse,
      );
      expect(
        CallPresentation.shouldShowCallBubble(
            phase: CallPhase.idle, appResumed: false),
        isFalse,
      );
    });
  });
}
