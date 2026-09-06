/// 会话生命周期守护（阶段 Q0-5 —— 移动生命周期接线）
///
/// 移动端 paused（退后台）下 socket 断开属预期；回前台（resumed）
/// 校验 socket 存活，已断开则触发既有重连链路（重连 + 重登录 +
/// 离线补发，阶段 D/I 语义复用）。桌面语义不变：Linux 窗口最小化
/// 恢复同样触发 resumed，此时 socket 存活 → 无操作（接线天然无害）。
///
/// SocketService 无全局单例（LoginScreen 持有并传给 ChatScreen），
/// 由 ChatScreen 在 initState/dispose bind/unbind（isSocketAlive =
/// socket != null，防跨界面串扰——FileDrop 惯例）；main.dart 的
/// WidgetsBindingObserver 在 resumed 分支调用 handleResumed。
/// 透传语义：guard 不做防抖，重连幂等由 reconnect 回调
/// （SocketService._reconnecting 检查）保证。

import 'package:flutter/foundation.dart';

class SessionLifecycleGuard {
  SessionLifecycleGuard._();

  static final SessionLifecycleGuard instance = SessionLifecycleGuard._();

  bool Function()? _isSocketAlive;
  VoidCallback? _reconnect;

  /// 绑定当前会话的存活检查与重连回调（ChatScreen 登录后调用；
  /// 重复 bind 覆盖旧回调）
  void bind({
    required bool Function() isSocketAlive,
    required VoidCallback reconnect,
  }) {
    _isSocketAlive = isSocketAlive;
    _reconnect = reconnect;
  }

  /// 解绑（ChatScreen 退出时调用；未 bind 时 handleResumed 无操作）
  void unbind() {
    _isSocketAlive = null;
    _reconnect = null;
  }

  /// AppLifecycleState.resumed 专用：socket 已死则触发重连回调
  void handleResumed() {
    final alive = _isSocketAlive?.call() ?? true;
    if (alive) return;
    _reconnect?.call();
  }
}
