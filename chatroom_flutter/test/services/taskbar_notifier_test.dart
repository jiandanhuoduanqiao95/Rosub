// ============================================================
// taskbar_notifier.dart 单元测试（阶段 H1/H2 —— 任务栏图标闪烁，类微信）
// ============================================================
// 契约（已实现）：
//   - flash()：调用注入的 setUrgencyImpl(true)；enabled=false 时静默；
//     impl 抛异常被隔离（不中断消息处理管线）
//   - clearUrgency()：调用 setUrgencyImpl(false)，不受 enabled 限制
//   - maybeFlashForMessage(msg, chatKey) 触发规则（窗口未聚焦才闪烁）：
//       chat / group_chat / file / file_request / group_file_request → flash()
//       system 且 sender='[系统公告]' → flash()
//       其余（自己发送 / 已读历史 / 撤回 / 普通系统消息 / 未知类型）→ 不闪烁
// ============================================================

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/focus_tracker.dart';
import 'package:chatroom_flutter/services/state_manager.dart';
import 'package:chatroom_flutter/services/taskbar_notifier.dart';

AppState get state => AppState.instance;

void resetState() {
  state
    ..setLoggedOut()
    ..setConnectionStatus(ConnectionStatus.disconnected);
  FocusTracker.instance.updateFocus(true);
}

void main() {
  late List<bool> calls;
  late void Function(bool) originalImpl;
  late bool originalEnabled;
  late void Function() originalPlaySoundImpl;

  setUp(() {
    resetState();
    calls = [];
    originalImpl = TaskbarNotifier.setUrgencyImpl;
    originalEnabled = TaskbarNotifier.enabled;
    originalPlaySoundImpl = TaskbarNotifier.playSoundImpl;
    TaskbarNotifier.setUrgencyImpl = (urgent) => calls.add(urgent);
    // 阶段 K3：测试环境注入空提示音，避免默认实现 spawn paplay/aplay
    TaskbarNotifier.playSoundImpl = () {};
    TaskbarNotifier.enabled = true;
    state.setLoggedIn('alice', false);
  });

  tearDown(() {
    TaskbarNotifier.setUrgencyImpl = originalImpl;
    TaskbarNotifier.enabled = originalEnabled;
    TaskbarNotifier.playSoundImpl = originalPlaySoundImpl;
    resetState();
  });

  group('flash / clearUrgency 基础行为（H1）', () {
    test('flash 调用注入的实现（urgent=true）', () {
      TaskbarNotifier.flash();
      expect(calls, [true]);
    });

    test('enabled=false 时 flash 静默', () {
      TaskbarNotifier.enabled = false;
      TaskbarNotifier.flash();
      expect(calls, isEmpty);
    });

    test('enabled 恢复 true 后恢复闪烁', () {
      TaskbarNotifier.enabled = false;
      TaskbarNotifier.flash();
      TaskbarNotifier.enabled = true;
      TaskbarNotifier.flash();
      expect(calls, [true]);
    });

    test('impl 抛异常被隔离，flash 不抛出', () {
      TaskbarNotifier.setUrgencyImpl = (_) => throw StateError('boom');
      expect(() => TaskbarNotifier.flash(), returnsNormally);
      expect(calls, isEmpty);
    });

    test('clearUrgency 调用实现（urgent=false），不受 enabled 限制', () {
      TaskbarNotifier.enabled = false;
      TaskbarNotifier.clearUrgency();
      expect(calls, [false]);
    });

    test('clearUrgency 的 impl 异常同样被隔离', () {
      TaskbarNotifier.setUrgencyImpl = (_) => throw StateError('boom');
      expect(() => TaskbarNotifier.clearUrgency(), returnsNormally);
    });
  });

  group('maybeFlashForMessage（H2 触发规则）', () {
    ChatMessage msg({
      required String sender,
      String? content,
      String type = 'chat',
      String status = 'sent',
      String? filename,
    }) =>
        ChatMessage(
          sender: sender,
          content: content ?? '',
          type: type,
          messageId: 'm-${calls.length + 1}',
          status: status,
          filename: filename,
        );

    test('窗口聚焦时收到消息 → 不闪烁', () {
      FocusTracker.instance.updateFocus(true);
      TaskbarNotifier.maybeFlashForMessage(
          msg(sender: 'bob', content: '你好'), 'bob');
      expect(calls, isEmpty);
    });

    test('未聚焦 + 私聊消息 → 闪烁', () {
      FocusTracker.instance.updateFocus(false);
      TaskbarNotifier.maybeFlashForMessage(
          msg(sender: 'bob', content: '周末爬山吗'), 'bob');
      expect(calls, [true]);
    });

    test('未聚焦 + 群聊消息 → 闪烁', () {
      FocusTracker.instance.updateFocus(false);
      TaskbarNotifier.maybeFlashForMessage(
          msg(sender: 'bob', content: '下班了', type: 'group_chat'), 'group_1');
      expect(calls, [true]);
    });

    test('未聚焦 + 文件消息 → 闪烁', () {
      FocusTracker.instance.updateFocus(false);
      TaskbarNotifier.maybeFlashForMessage(
          msg(sender: 'bob', type: 'file', filename: 'report.pdf'), 'bob');
      expect(calls, [true]);
    });

    test('未聚焦 + 文件请求 → 闪烁（NT-03）', () {
      FocusTracker.instance.updateFocus(false);
      TaskbarNotifier.maybeFlashForMessage(
          msg(sender: 'bob', type: 'file_request', filename: 'report.pdf'),
          'bob');
      expect(calls, [true]);
    });

    test('未聚焦 + 群文件请求 → 闪烁（NT-03）', () {
      FocusTracker.instance.updateFocus(false);
      TaskbarNotifier.maybeFlashForMessage(
          msg(sender: 'bob', type: 'group_file_request', filename: 'a.zip'),
          'group_1');
      expect(calls, [true]);
    });

    test('未聚焦 + 自己发送的消息 → 不闪烁', () {
      FocusTracker.instance.updateFocus(false);
      TaskbarNotifier.maybeFlashForMessage(
          msg(sender: 'alice', content: '自己发的'), 'bob');
      expect(calls, isEmpty);
    });

    test('未聚焦 + 已读历史（delivered）→ 不闪烁', () {
      FocusTracker.instance.updateFocus(false);
      TaskbarNotifier.maybeFlashForMessage(
          msg(sender: 'bob', content: '旧消息', status: 'delivered'), 'bob');
      expect(calls, isEmpty);
    });

    test('未聚焦 + 撤回消息（recalled）→ 不闪烁', () {
      FocusTracker.instance.updateFocus(false);
      TaskbarNotifier.maybeFlashForMessage(
          msg(sender: 'bob', content: '已撤回', status: 'recalled'), 'bob');
      expect(calls, isEmpty);
    });

    test('未聚焦 + 系统公告 → 闪烁', () {
      FocusTracker.instance.updateFocus(false);
      TaskbarNotifier.maybeFlashForMessage(
          msg(sender: '[系统公告]', content: '今晚维护', type: 'system'),
          '服务器');
      expect(calls, [true]);
    });

    test('未聚焦 + 普通系统消息（操作确认）→ 不闪烁', () {
      FocusTracker.instance.updateFocus(false);
      TaskbarNotifier.maybeFlashForMessage(
          msg(sender: '系统', content: '好友请求已发送', type: 'system'),
          '服务器');
      expect(calls, isEmpty);
    });

    test('未聚焦 + 未知消息类型 → 不闪烁', () {
      FocusTracker.instance.updateFocus(false);
      TaskbarNotifier.maybeFlashForMessage(
          msg(sender: 'bob', content: 'x', type: 'unknown_type'), 'bob');
      expect(calls, isEmpty);
    });

    test('enabled=false 时即使未聚焦也不闪烁', () {
      FocusTracker.instance.updateFocus(false);
      TaskbarNotifier.enabled = false;
      TaskbarNotifier.maybeFlashForMessage(
          msg(sender: 'bob', content: '你好'), 'bob');
      expect(calls, isEmpty);
    });
  });
}
