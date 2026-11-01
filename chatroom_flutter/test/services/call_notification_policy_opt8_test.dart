// ============================================================
// opt8 功能三 —— 来电通知策略（CallPresentation 纯策略模块）
// ============================================================
// 通知何时显示（振铃+后台）、标题/正文文案矩阵，直接测纯 Dart 策略
// 文件（不依赖 Widget 树/平台通道）。悬浮球策略在
// call_bubble_policy_opt8_test.dart，桌面唤起策略在
// window_activation_opt8_test.dart。
// ============================================================

import 'package:chatroom_flutter/services/call_presentation.dart';
import 'package:chatroom_flutter/services/call_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('opt8 F3 —— shouldShowIncomingNotification（振铃+后台才通知）', () {
    test('ringing + 后台 → true（核心场景）', () {
      expect(
        CallPresentation.shouldShowIncomingNotification(
            phase: CallPhase.ringing, appResumed: false),
        isTrue,
      );
    });

    test('ringing + 前台 → false（前台 CallScreen 已弹出，不发高优先级通知）',
        () {
      expect(
        CallPresentation.shouldShowIncomingNotification(
            phase: CallPhase.ringing, appResumed: true),
        isFalse,
      );
    });

    test('非 ringing 阶段（calling/connecting/active/ended/idle）→ false',
        () {
      for (final phase in [
        CallPhase.calling,
        CallPhase.connecting,
        CallPhase.active,
        CallPhase.ended,
        CallPhase.idle,
      ]) {
        expect(
          CallPresentation.shouldShowIncomingNotification(
              phase: phase, appResumed: false),
          isFalse,
          reason: '$phase 后台也不发来电通知',
        );
      }
    });
  });

  group('opt8 F3 —— displayName（标题矩阵）', () {
    test('1:1 用对方用户名', () {
      expect(
        CallPresentation.displayName(isGroup: false, peer: 'bob'),
        'bob',
      );
    });

    test('群聊仅群名（不显示邀请人——用户决策）', () {
      expect(
        CallPresentation.displayName(
            isGroup: true, groupName: '研发群', peer: 'bob'),
        '研发群',
      );
    });

    test('空值兜底：群名缺失→群聊，peer 缺失→空串', () {
      expect(CallPresentation.displayName(isGroup: true), '群聊');
      expect(CallPresentation.displayName(isGroup: false), '');
    });
  });

  group('opt8 F3 —— incomingBody（正文四种文案）', () {
    test('1:1 语音', () {
      expect(
        CallPresentation.incomingBody(isGroup: false, video: false),
        '邀请你语音通话',
      );
    });

    test('1:1 视频', () {
      expect(
        CallPresentation.incomingBody(isGroup: false, video: true),
        '邀请你视频通话',
      );
    });

    test('群语音', () {
      expect(
        CallPresentation.incomingBody(isGroup: true, video: false),
        '邀请你加入群语音通话',
      );
    });

    test('群视频', () {
      expect(
        CallPresentation.incomingBody(isGroup: true, video: true),
        '邀请你加入群视频通话',
      );
    });
  });

  group('opt8 F3 —— shouldBringDesktopCallToFront（桌面唤起白名单）', () {
    test('ringing + Linux/Windows → true', () {
      expect(
        CallPresentation.shouldBringDesktopCallToFront(
            phase: CallPhase.ringing, platform: TargetPlatform.linux),
        isTrue,
      );
      expect(
        CallPresentation.shouldBringDesktopCallToFront(
            phase: CallPhase.ringing, platform: TargetPlatform.windows),
        isTrue,
      );
    });

    test('去电 calling / 其他阶段 → false（不抢焦点）', () {
      for (final phase in [
        CallPhase.calling,
        CallPhase.connecting,
        CallPhase.active,
        CallPhase.ended,
        CallPhase.idle,
      ]) {
        expect(
          CallPresentation.shouldBringDesktopCallToFront(
              phase: phase, platform: TargetPlatform.linux),
          isFalse,
          reason: '$phase 不做桌面唤起',
        );
      }
    });

    test('非桌面平台 → false（Android 走系统通知）', () {
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      ]) {
        expect(
          CallPresentation.shouldBringDesktopCallToFront(
              phase: CallPhase.ringing, platform: platform),
          isFalse,
        );
      }
    });
  });
}
