// ============================================================
// taskbar_notifier.dart 阶段 Q1 —— 应用外新消息通知契约（真机反馈二轮）
// ============================================================
// Q1 二轮问题5（参考微信）：App 在后台（未聚焦）收到新消息 →
// Android 系统通知（横幅+震动+提示音，经通知渠道承载）；App 在前台 →
// 保持既有生成式提示音（不双响）。静音/免打扰/置顶豁免语义（阶段 K3）
// 不变——通知与提示音共用同一判定链。
// 文件请求类型通知正文为 "[文件] 文件名"（问题2 聊天中感知的背景侧）。
// ============================================================

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/platform/capabilities.dart';
import 'package:chatroom_flutter/services/focus_tracker.dart';
import 'package:chatroom_flutter/services/state_manager.dart';
import 'package:chatroom_flutter/services/taskbar_notifier.dart';

const MethodChannel _channel = MethodChannel('chatroom/platform');

/// 提示音计数桩（经 PlatformCapabilities.soundOverride 注入——playSound
/// 走能力层而非 playSoundImpl，playSoundImpl 仅 Linux 默认链）
class CountingSound implements SoundCapability {
  final List<String> soundCalls = [];
  int calls = 0;

  @override
  Future<void> playNotifySound() async {
    calls++;
    soundCalls.add('notify');
  }

  @override
  Future<void> playCallRingtone() async {}

  @override
  Future<void> playHangupSound() async {}

  @override
  Future<void> stopCallRingtone() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];
  late CountingSound sound;

  setUp(() {
    calls.clear();
    debugDefaultTargetPlatformOverride = null;
    AppState.instance
      ..setLoggedOut()
      ..setConnectionStatus(ConnectionStatus.disconnected);
    TaskbarNotifier.enabled = true;
    TaskbarNotifier.soundEnabled = true;
    TaskbarNotifier.dndEnabled = false;
    PlatformCapabilities.resetForTest();
    PlatformCapabilities.soundOverride = sound = CountingSound();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return true;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    PlatformCapabilities.soundOverride = null;
    PlatformCapabilities.resetForTest();
    FocusTracker.instance.updateFocus(true);
    debugDefaultTargetPlatformOverride = null;
  });

  ChatMessage chatMsg() => ChatMessage(
        sender: 'bob',
        content: '在吗',
        type: 'chat',
        messageId: 'm1',
        status: 'sent',
      );

  test('Android 后台：发系统通知且不播应用内提示音（防双响）', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    FocusTracker.instance.updateFocus(false);
    TaskbarNotifier.maybeFlashForMessage(chatMsg(), 'bob');
    await Future<void>.delayed(Duration.zero);
    expect(sound.calls, 0, reason: '后台提示音由通知渠道承载，不双响');
    final call = calls.firstWhere((c) => c.method == 'showMessageNotification');
    expect((call.arguments as Map)['title'], 'bob');
    expect((call.arguments as Map)['body'], '在吗');
    debugDefaultTargetPlatformOverride = null;
  });

  test('Android 前台：播应用内提示音且不发系统通知', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    FocusTracker.instance.updateFocus(true);
    TaskbarNotifier.maybeFlashForMessage(chatMsg(), 'bob');
    await Future<void>.delayed(Duration.zero);
    expect(sound.calls, 1, reason: '前台保持生成式提示音');
    expect(calls.where((c) => c.method == 'showMessageNotification'), isEmpty,
        reason: '前台无横幅');
    debugDefaultTargetPlatformOverride = null;
  });

  test('Linux 后台：不发系统通知（平台门控）', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    FocusTracker.instance.updateFocus(false);
    TaskbarNotifier.maybeFlashForMessage(chatMsg(), 'bob');
    await Future<void>.delayed(Duration.zero);
    expect(sound.calls, 1, reason: 'Linux 声音语义不变');
    expect(calls.where((c) => c.method == 'showMessageNotification'), isEmpty,
        reason: '系统通知为 Android 专属');
    debugDefaultTargetPlatformOverride = null;
  });

  test('群聊消息：通知标题为群名，正文带发送者前缀', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    FocusTracker.instance.updateFocus(false);
    AppState.instance.setLoggedIn('alice', false);
    AppState.instance.setGroups([
      Group(id: 7, name: '项目组', owner: 'alice'),
    ]);
    TaskbarNotifier.maybeFlashForMessage(
      ChatMessage(
        sender: 'bob',
        content: '收到',
        type: 'group_chat',
        messageId: 'm2',
        status: 'sent',
      ),
      'group_7',
    );
    await Future<void>.delayed(Duration.zero);
    final call = calls.firstWhere((c) => c.method == 'showMessageNotification');
    expect((call.arguments as Map)['title'], '项目组');
    expect((call.arguments as Map)['body'], 'bob: 收到');
    debugDefaultTargetPlatformOverride = null;
  });

  test('文件请求：通知正文为 [文件] 文件名', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    FocusTracker.instance.updateFocus(false);
    TaskbarNotifier.maybeFlashForMessage(
      ChatMessage(
        sender: 'bob',
        content: '[文件请求] report.pdf',
        type: 'file_request',
        messageId: 'm3',
        status: 'sent',
        filename: 'report.pdf',
      ),
      'bob',
    );
    await Future<void>.delayed(Duration.zero);
    final call = calls.firstWhere((c) => c.method == 'showMessageNotification');
    expect((call.arguments as Map)['body'], '[文件] report.pdf');
    debugDefaultTargetPlatformOverride = null;
  });

  test('静音会话：既不提示音也不通知（K3 语义不变）', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    FocusTracker.instance.updateFocus(false);
    AppState.instance.setConversationMuted('bob', true);
    TaskbarNotifier.maybeFlashForMessage(chatMsg(), 'bob');
    await Future<void>.delayed(Duration.zero);
    expect(sound.calls, 0);
    expect(calls.where((c) => c.method == 'showMessageNotification'), isEmpty);
    debugDefaultTargetPlatformOverride = null;
  });
}
