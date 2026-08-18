// ============================================================
// taskbar_notifier.dart 阶段 K —— 静音/免打扰/提示音（已实现，全部转绿）
// ============================================================
// 覆盖 P1-13/P1-14（《软件开发文档4.1.0.md》§11 阶段 K / §13.3）：
//   - 逐会话静音（conversations.muted，K3）：静音会话永不提醒（不闪、不响）
//   - 全局免打扰（K3，2026-08-18 用户决策修订）：绝对结束时刻
//     （dndEndTime，精确到日/时/分）；dndEnabled 且 当前 < 结束时刻 → 不提醒；
//     到期由 checkDndExpiry() 自动关闭开关（ChatScreen 定时器驱动）并提醒；
//     **置顶会话豁免免打扰**（置顶会话在免打扰时段内仍提醒）
//   - 新消息提示音（P1-14，可开关）：声音通道与视觉通道互补，
//     与窗口是否聚焦无关；soundEnabled=false 时静默
//
// 契约（TaskbarNotifier 静态扩展）：
//   soundEnabled        bool，默认 true          —— 提示音总开关
//   dndEnabled          bool，默认 false         —— 免打扰总开关
//   dndEndTime          DateTime，默认 now+1h    —— 免打扰结束时刻（绝对）
//   nowProvider         DateTime Function()，默认 DateTime.now —— 可注入时钟
//   playSoundImpl       void Function()，默认生成和弦提示音并播放 —— 测试可注入
//   playSound()         调用 playSoundImpl（异常隔离）
//   inDndWindow([now])  now 缺省用 nowProvider().toLocal()；
//                       当前时刻 < dndEndTime（免打扰区间含起点不含终点）
//   checkDndExpiry()    免打扰到期 → 自动关闭 dndEnabled 并返回 true（否则 false）
//   ensureDndEndInFuture() 开关开启时确保结束时刻在未来（今天 23:00，已过取次日）
//   maybeFlashForMessage 增强（在既有类型规则命中之后）：
//     - AppState.isMuted(chatKey) → 不闪烁、不响铃
//     - dndEnabled && inDndWindow() && !isPinned(chatKey) → 不闪烁、不响铃
//       （置顶会话豁免免打扰）
//     - 否则：soundEnabled → playSound()；窗口未聚焦且 enabled → flash()
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
  late List<bool> flashCalls;
  late List<bool> soundCalls;
  late void Function(bool) originalUrgencyImpl;
  late void Function() originalPlaySoundImpl;
  late bool originalEnabled;
  late bool originalSoundEnabled;
  late bool originalDndEnabled;
  late DateTime originalDndEnd;
  late DateTime Function() originalNowProvider;

  setUp(() {
    resetState();
    flashCalls = [];
    soundCalls = [];
    originalUrgencyImpl = TaskbarNotifier.setUrgencyImpl;
    originalPlaySoundImpl = TaskbarNotifier.playSoundImpl;
    originalEnabled = TaskbarNotifier.enabled;
    originalSoundEnabled = TaskbarNotifier.soundEnabled;
    originalDndEnabled = TaskbarNotifier.dndEnabled;
    originalDndEnd = TaskbarNotifier.dndEndTime;
    originalNowProvider = TaskbarNotifier.nowProvider;
    TaskbarNotifier.setUrgencyImpl = (urgent) => flashCalls.add(urgent);
    TaskbarNotifier.playSoundImpl = () => soundCalls.add(true);
    TaskbarNotifier.enabled = true;
    TaskbarNotifier.soundEnabled = false;
    TaskbarNotifier.dndEnabled = false;
    TaskbarNotifier.dndEndTime = DateTime(2026, 8, 18, 23, 0);
    TaskbarNotifier.nowProvider = () => DateTime(2026, 8, 18, 10, 0);
    FocusTracker.instance.updateFocus(false);
    state.setLoggedIn('alice', false);
  });

  tearDown(() {
    TaskbarNotifier.setUrgencyImpl = originalUrgencyImpl;
    TaskbarNotifier.playSoundImpl = originalPlaySoundImpl;
    TaskbarNotifier.enabled = originalEnabled;
    TaskbarNotifier.soundEnabled = originalSoundEnabled;
    TaskbarNotifier.dndEnabled = originalDndEnabled;
    TaskbarNotifier.dndEndTime = originalDndEnd;
    TaskbarNotifier.nowProvider = originalNowProvider;
    resetState();
  });

  ChatMessage msg({required String sender, String type = 'chat'}) =>
      ChatMessage(
        sender: sender,
        content: '内容',
        type: type,
        messageId: 'm-${flashCalls.length + soundCalls.length}',
        status: 'sent',
      );

  group('K3 —— 逐会话静音', () {
    test('静音好友会话：未聚焦收到消息不闪烁', () {
      state.setConversationMuted('bob', true);
      TaskbarNotifier.maybeFlashForMessage(msg(sender: 'bob'), 'bob');
      expect(flashCalls, isEmpty);
    });

    test('静音群组会话：不闪烁', () {
      state.setConversationMuted('group_1', true);
      TaskbarNotifier.maybeFlashForMessage(
          msg(sender: 'bob', type: 'group_chat'), 'group_1');
      expect(flashCalls, isEmpty);
    });

    test('静音系统会话：公告不闪烁（防御）', () {
      state.setConversationMuted('服务器', true);
      TaskbarNotifier.maybeFlashForMessage(
          ChatMessage(
              sender: '[系统公告]',
              content: '维护',
              type: 'system',
              messageId: 's1',
              status: 'sent'),
          '服务器');
      expect(flashCalls, isEmpty);
    });

    test('未静音会话正常闪烁（基线）', () {
      TaskbarNotifier.maybeFlashForMessage(msg(sender: 'bob'), 'bob');
      expect(flashCalls, [true]);
    });

    test('静音只作用于目标会话，不影响其他会话', () {
      state.setConversationMuted('bob', true);
      TaskbarNotifier.maybeFlashForMessage(msg(sender: 'bob'), 'bob');
      TaskbarNotifier.maybeFlashForMessage(msg(sender: 'carol'), 'carol');
      expect(flashCalls, [true], reason: 'carol 会话未静音应闪烁');
    });
  });

  group('K3 —— 全局免打扰（绝对结束时刻 + 置顶豁免，2026-08-18 修订）', () {
    test('结束时刻前（dndEnabled=true）不闪烁不响铃', () {
      TaskbarNotifier.dndEnabled = true;
      TaskbarNotifier.dndEndTime = DateTime(2026, 8, 18, 23, 0);
      TaskbarNotifier.nowProvider = () => DateTime(2026, 8, 18, 22, 30);
      TaskbarNotifier.soundEnabled = true;
      TaskbarNotifier.maybeFlashForMessage(msg(sender: 'bob'), 'bob');
      expect(flashCalls, isEmpty);
      expect(soundCalls, isEmpty);
    });

    test('结束时刻后不生效：恢复提醒', () {
      TaskbarNotifier.dndEnabled = true;
      TaskbarNotifier.dndEndTime = DateTime(2026, 8, 18, 23, 0);
      TaskbarNotifier.nowProvider = () => DateTime(2026, 8, 18, 23, 10);
      TaskbarNotifier.maybeFlashForMessage(msg(sender: 'bob'), 'bob');
      expect(flashCalls, [true], reason: '已过结束时刻应恢复提醒');
    });

    test('dndEnabled=false 时忽略结束时刻', () {
      TaskbarNotifier.dndEnabled = false;
      TaskbarNotifier.dndEndTime = DateTime(2026, 8, 18, 23, 0);
      TaskbarNotifier.nowProvider = () => DateTime(2026, 8, 18, 22, 30);
      TaskbarNotifier.maybeFlashForMessage(msg(sender: 'bob'), 'bob');
      expect(flashCalls, [true]);
    });

    test('免打扰时段内：未置顶会话不提醒、置顶会话豁免仍提醒', () {
      TaskbarNotifier.dndEnabled = true;
      TaskbarNotifier.dndEndTime = DateTime(2026, 8, 18, 23, 0);
      TaskbarNotifier.soundEnabled = true;
      TaskbarNotifier.nowProvider = () => DateTime(2026, 8, 18, 22, 30);

      // 未置顶 → 免打扰压制
      TaskbarNotifier.maybeFlashForMessage(msg(sender: 'bob'), 'bob');
      expect(flashCalls, isEmpty);
      expect(soundCalls, isEmpty);

      // 置顶会话 → 豁免免打扰（P-16 修订）
      state.setConversationPinned('carol', true);
      TaskbarNotifier.maybeFlashForMessage(msg(sender: 'carol'), 'carol');
      expect(soundCalls, [true], reason: '置顶会话在免打扰时段内仍响铃');
      expect(flashCalls, [true], reason: '置顶会话在免打扰时段内仍闪烁');
    });

    test('置顶群组会话同样豁免免打扰', () {
      TaskbarNotifier.dndEnabled = true;
      TaskbarNotifier.dndEndTime = DateTime(2026, 8, 18, 23, 0);
      TaskbarNotifier.soundEnabled = true;
      TaskbarNotifier.nowProvider = () => DateTime(2026, 8, 18, 22, 30);
      state.setConversationPinned('group_1', true);
      TaskbarNotifier.maybeFlashForMessage(
          msg(sender: 'bob', type: 'group_chat'), 'group_1');
      expect(soundCalls, [true], reason: '置顶群组会话豁免免打扰');
    });

    test('静音会话在免打扰时段内也不提醒（静音为会话级绝对规则，优先于豁免）', () {
      TaskbarNotifier.dndEnabled = true;
      TaskbarNotifier.soundEnabled = true;
      TaskbarNotifier.nowProvider = () => DateTime(2026, 8, 18, 22, 30);
      state.setConversationMuted('bob', true);
      state.setConversationPinned('bob', true);
      TaskbarNotifier.maybeFlashForMessage(msg(sender: 'bob'), 'bob');
      expect(flashCalls, isEmpty);
      expect(soundCalls, isEmpty, reason: '静音规则优先：置顶也不提醒');
    });

    test('inDndWindow 直接调用（注入时钟，绝对结束时刻）', () {
      TaskbarNotifier.dndEndTime = DateTime(2026, 8, 18, 18, 0);
      expect(TaskbarNotifier.inDndWindow(DateTime(2026, 8, 18, 9, 0)), isTrue);
      expect(TaskbarNotifier.inDndWindow(DateTime(2026, 8, 18, 17, 59)), isTrue);
      expect(TaskbarNotifier.inDndWindow(DateTime(2026, 8, 18, 18, 0)), isFalse,
          reason: '结束时刻不含');
      expect(TaskbarNotifier.inDndWindow(DateTime(2026, 8, 18, 23, 59)), isFalse);
      // 跨日：第二天仍在结束时刻内
      expect(TaskbarNotifier.inDndWindow(DateTime(2026, 8, 19, 0, 30)), isFalse,
          reason: '结束时刻固定到 8-18 18:00，次日已不在免打扰区间');
    });

    test('inDndWindow 精确到分钟', () {
      TaskbarNotifier.dndEndTime = DateTime(2026, 8, 18, 23, 30);
      expect(
          TaskbarNotifier.inDndWindow(DateTime(2026, 8, 18, 23, 29)), isTrue);
      expect(
          TaskbarNotifier.inDndWindow(DateTime(2026, 8, 18, 23, 30)), isFalse);
    });

    test('checkDndExpiry：到期自动关闭开关并返回 true', () {
      TaskbarNotifier.dndEnabled = true;
      TaskbarNotifier.dndEndTime = DateTime(2026, 8, 18, 23, 0);
      TaskbarNotifier.nowProvider = () => DateTime(2026, 8, 18, 23, 5);
      expect(TaskbarNotifier.checkDndExpiry(), isTrue,
          reason: '已过结束时刻应判定到期');
      expect(TaskbarNotifier.dndEnabled, isFalse, reason: '到期后自动关闭开关');
      expect(TaskbarNotifier.checkDndExpiry(), isFalse, reason: '再次调用无副作用');
    });

    test('checkDndExpiry：未到期返回 false 且开关保持开启', () {
      TaskbarNotifier.dndEnabled = true;
      TaskbarNotifier.dndEndTime = DateTime(2026, 8, 18, 23, 0);
      TaskbarNotifier.nowProvider = () => DateTime(2026, 8, 18, 22, 0);
      expect(TaskbarNotifier.checkDndExpiry(), isFalse);
      expect(TaskbarNotifier.dndEnabled, isTrue);
    });

    test('checkDndExpiry：开关关闭时无副作用', () {
      TaskbarNotifier.dndEnabled = false;
      expect(TaskbarNotifier.checkDndExpiry(), isFalse);
    });

    test('ensureDndEndInFuture：当前早于 23:00 → 今天 23:00', () {
      TaskbarNotifier.nowProvider = () => DateTime(2026, 8, 18, 10, 0);
      TaskbarNotifier.ensureDndEndInFuture();
      expect(TaskbarNotifier.dndEndTime,
          DateTime(2026, 8, 18, 23, 0));
    });

    test('ensureDndEndInFuture：已过 23:00 → 次日 23:00', () {
      TaskbarNotifier.nowProvider = () => DateTime(2026, 8, 18, 23, 30);
      TaskbarNotifier.ensureDndEndInFuture();
      expect(TaskbarNotifier.dndEndTime,
          DateTime(2026, 8, 19, 23, 0));
    });

    test('默认配置：soundEnabled=true / dndEnabled=false / 结束时刻在未来', () {
      expect(originalSoundEnabled, isTrue);
      expect(originalDndEnabled, isFalse);
      expect(originalDndEnd.isAfter(DateTime.now()), isTrue,
          reason: '默认结束时刻应为未来时刻');
    });
  });

  group('K3 —— 新消息提示音（P1-14，可开关）', () {
    test('声音开启时收到新消息播放提示音（窗口聚焦也响）', () {
      TaskbarNotifier.soundEnabled = true;
      FocusTracker.instance.updateFocus(true);
      TaskbarNotifier.maybeFlashForMessage(msg(sender: 'bob'), 'bob');
      expect(soundCalls, [true], reason: '声音通道与窗口聚焦无关');
      expect(flashCalls, isEmpty, reason: '聚焦时仅响铃不闪烁');
    });

    test('声音关闭时不响铃，未聚焦仍闪烁', () {
      TaskbarNotifier.soundEnabled = false;
      FocusTracker.instance.updateFocus(false);
      TaskbarNotifier.maybeFlashForMessage(msg(sender: 'bob'), 'bob');
      expect(soundCalls, isEmpty);
      expect(flashCalls, [true]);
    });

    test('静音会话不响铃', () {
      TaskbarNotifier.soundEnabled = true;
      state.setConversationMuted('bob', true);
      TaskbarNotifier.maybeFlashForMessage(msg(sender: 'bob'), 'bob');
      expect(soundCalls, isEmpty);
    });

    test('免打扰时段内不响铃（未置顶会话）', () {
      TaskbarNotifier.soundEnabled = true;
      TaskbarNotifier.dndEnabled = true;
      TaskbarNotifier.dndEndTime = DateTime(2026, 8, 18, 23, 0);
      TaskbarNotifier.nowProvider = () => DateTime(2026, 8, 18, 22, 30);
      TaskbarNotifier.maybeFlashForMessage(msg(sender: 'bob'), 'bob');
      expect(soundCalls, isEmpty);
    });

    test('免打扰时段内置顶会话仍响铃（置顶豁免）', () {
      TaskbarNotifier.soundEnabled = true;
      TaskbarNotifier.dndEnabled = true;
      TaskbarNotifier.dndEndTime = DateTime(2026, 8, 18, 23, 0);
      TaskbarNotifier.nowProvider = () => DateTime(2026, 8, 18, 22, 30);
      state.setConversationPinned('bob', true);
      TaskbarNotifier.maybeFlashForMessage(msg(sender: 'bob'), 'bob');
      expect(soundCalls, [true]);
    });

    test('enabled=false 总开关同时关闭闪烁与提示音', () {
      TaskbarNotifier.soundEnabled = true;
      TaskbarNotifier.enabled = false;
      FocusTracker.instance.updateFocus(false);
      TaskbarNotifier.maybeFlashForMessage(msg(sender: 'bob'), 'bob');
      expect(flashCalls, isEmpty);
      expect(soundCalls, isEmpty);
    });

    test('playSound 异常被隔离（不中断消息处理）', () {
      TaskbarNotifier.soundEnabled = true;
      TaskbarNotifier.playSoundImpl = () => throw StateError('no-audio');
      expect(
          () => TaskbarNotifier.maybeFlashForMessage(msg(sender: 'bob'), 'bob'),
          returnsNormally);
      expect(flashCalls, [true], reason: '响铃失败不影响闪烁');
    });
  });
}
