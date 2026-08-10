/// 任务栏图标闪烁（阶段 H1/H2 —— 类微信未读提醒）
///
/// 新消息到达且窗口未聚焦时，通过 GTK urgency hint 让任务栏图标闪烁
/// （GNOME / KDE 等常见桌面环境均支持），替代系统弹窗通知。
/// - flash()：开始闪烁（enabled=false 时静默；impl 异常隔离）
/// - clearUrgency()：清除闪烁（窗口重新聚焦时由 main.dart 调用，不受 enabled 限制）
/// - maybeFlashForMessage()：未聚焦窗口时收到新消息才闪烁：
///     chat / group_chat / file / file_request / group_file_request → 闪烁
///     system 且 sender='[系统公告]' → 闪烁
///     其余（自己发送 / 已读历史 / 撤回 / 普通系统消息 / 未知类型）不闪烁。
/// 调用点（接入）：SocketService._handleMessage 收到新消息后调用。

import 'dart:ffi';

import '../models/chat_models.dart';
import 'focus_tracker.dart';
import 'state_manager.dart';

class TaskbarNotifier {
  TaskbarNotifier._();

  /// 总开关
  static bool enabled = true;

  /// 紧急提示实现（测试可注入 fake；默认调用 runner 的 GTK urgency 桥接）
  static void Function(bool urgent) setUrgencyImpl = _defaultSetUrgency;

  static void _defaultSetUrgency(bool urgent) {
    try {
      final lib = DynamicLibrary.process();
      final fn =
          lib.lookupFunction<_SetUrgencyNative, _SetUrgencyDart>(
              'chatroom_set_urgency');
      fn(urgent ? 1 : 0);
    } catch (_) {
      // 非桌面环境（测试 / 无窗口管理器）静默降级
    }
  }

  /// 任务栏图标开始闪烁（未聚焦收到新消息时）
  static void flash() {
    if (!enabled) return;
    try {
      setUrgencyImpl(true);
    } catch (_) {
      // 闪烁失败不影响消息处理管线
    }
  }

  /// 清除紧急提示（窗口重新聚焦后调用；不受 enabled 限制）
  static void clearUrgency() {
    try {
      setUrgencyImpl(false);
    } catch (_) {}
  }

  /// 触发规则：未聚焦窗口时收到新消息才闪烁
  static void maybeFlashForMessage(ChatMessage msg, String chatKey) {
    if (FocusTracker.instance.focused) return;
    if (!enabled) return;
    if (msg.status != 'sent') return;
    if (msg.sender == AppState.instance.username) return;
    switch (msg.type) {
      case 'chat':
      case 'group_chat':
      case 'file':
      case 'file_request':
      case 'group_file_request':
        flash();
        break;
      case 'system':
        if (msg.sender == '[系统公告]') {
          flash();
        }
        break;
    }
  }
}

typedef _SetUrgencyNative = Void Function(Int);
typedef _SetUrgencyDart = void Function(int);
