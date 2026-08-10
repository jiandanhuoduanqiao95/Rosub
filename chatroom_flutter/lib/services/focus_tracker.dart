/// 窗口焦点跟踪（阶段 H1）
///
/// main.dart 的 WidgetsBindingObserver 在应用生命周期变化时调用
/// updateFocus：resumed → 聚焦，inactive/paused → 失焦。
/// 桌面通知触发（H2）以 focused == false 为前提。

import 'package:flutter/foundation.dart';

class FocusTracker extends ChangeNotifier {
  FocusTracker._();
  static final FocusTracker instance = FocusTracker._();

  bool _focused = true;

  /// 窗口是否聚焦
  bool get focused => _focused;

  /// 更新焦点状态（值变化时才通知监听者）
  void updateFocus(bool focused) {
    if (_focused != focused) {
      _focused = focused;
      notifyListeners();
    }
  }
}
