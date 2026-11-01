/// opt8 通话呈现策略（纯 Dart，不依赖 BuildContext/平台通道）
///
/// 三个功能共享的"什么时候发通知/显示悬浮球/唤起桌面窗口"判定与
/// 来电通知文案，收敛于此以便单测（call_notification_policy_opt8_test /
/// call_bubble_policy_opt8_test / window_activation_opt8_test 直接测本
/// 文件，不依赖 Widget 树）。平台门控由调用方（ChatScreen）负责——
/// 本模块只表达策略，不做平台判定（除桌面唤起的平台白名单，因其本身
/// 就是策略的一部分）。
import 'package:flutter/foundation.dart' show TargetPlatform;

import 'call_service.dart';

class CallPresentation {
  CallPresentation._();

  /// 振铃且 App 不在前台 → 显示系统来电通知（Android）。
  /// 前台振铃不发高优先级来电通知（CallScreen 已直接弹出）；
  /// FGS 静默"通话中"通知（P5）与此无关，勿混淆。
  static bool shouldShowIncomingNotification({
    required CallPhase phase,
    required bool appResumed,
  }) =>
      phase == CallPhase.ringing && !appResumed;

  /// 通话进行中且 App 不在前台 → 显示系统悬浮球（Android）。
  /// ringing 不显示（来电通知接管）；ended/idle 不显示。
  static bool shouldShowCallBubble({
    required CallPhase phase,
    required bool appResumed,
  }) {
    if (appResumed) return false;
    return phase == CallPhase.calling ||
        phase == CallPhase.connecting ||
        phase == CallPhase.active;
  }

  /// 来电通知标题：1:1 用对方用户名；群聊仅群名（不显示邀请人——
  /// v1 不额外保存 groupInviter，用户决策）。
  static String displayName({
    required bool isGroup,
    String? peer,
    String? groupName,
  }) =>
      isGroup ? (groupName ?? '群聊') : (peer ?? '');

  /// 来电通知正文四种文案（1:1/群 × 语音/视频）。
  static String incomingBody({
    required bool isGroup,
    required bool video,
  }) =>
      isGroup
          ? '邀请你加入群${video ? '视频' : '语音'}通话'
          : '邀请你${video ? '视频' : '语音'}通话';

  /// 桌面来电唤起：仅来电 ringing + Linux/Windows 调用
  /// WindowActivationCapability.bringToFront（恢复窗口/置前/任务栏提醒）。
  /// 去电 calling 不抢焦点；Android 走系统通知/full-screen intent。
  static bool shouldBringDesktopCallToFront({
    required CallPhase phase,
    required TargetPlatform platform,
  }) =>
      phase == CallPhase.ringing &&
      (platform == TargetPlatform.linux ||
          platform == TargetPlatform.windows);
}
