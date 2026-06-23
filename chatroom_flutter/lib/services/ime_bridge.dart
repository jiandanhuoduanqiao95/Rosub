/// IME 桥接管理器 —— 常驻 Python GTK 桥接进程
///
/// 启动 bridge/persistent_ime.py 并保持通信。
/// 通过 stdin 发送 focus/blur 命令，从 stdout 读取 IME 输出。
///
/// 协议：
///   READY  —— 桥接就绪
///   T:文本 —— 当前条目完整文本（每次变更）
///   S:     —— 用户按 Enter 提交
///   ESC:   —— 用户按 Esc 取消

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

typedef ImeTextListener = void Function(String text);
typedef ImeSubmitListener = void Function();
typedef ImeEscapeListener = void Function();

class ImeBridgeManager {
  ImeBridgeManager._();
  static final ImeBridgeManager instance = ImeBridgeManager._();

  Process? _process;
  final List<ImeTextListener> _textListeners = [];
  final List<ImeSubmitListener> _submitListeners = [];
  final List<ImeEscapeListener> _escapeListeners = [];
  bool _started = false;

  Future<void> ensureStarted() async {
    if (_started) return;
    _started = true;

    final script = 'bridge/persistent_ime.py';
    try {
      _process = await Process.start('python3', [script]);
      _process!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (line == 'READY') {
          debugPrint('[ime_bridge] 桥接已就绪');
          return;
        }
        if (line.startsWith('T:')) {
          final text = line.substring(2);
          for (final l in _textListeners) {
            l(text);
          }
        } else if (line == 'S:') {
          for (final l in _submitListeners) {
            l();
          }
        } else if (line == 'ESC:') {
          for (final l in _escapeListeners) {
            l();
          }
        }
      });
      _process!.stderr.transform(utf8.decoder).listen((e) {
        debugPrint('[ime_bridge] stderr: $e');
      });
      _process!.exitCode.then((code) {
        debugPrint('[ime_bridge] 退出 (code=$code)');
        _started = false;
        _process = null;
      });
    } catch (e) {
      debugPrint('[ime_bridge] 启动失败: $e');
      _started = false;
    }
  }

  void grabFocus() => _send('focus');
  void releaseFocus() => _send('blur');
  void shutdown() {
    if (_process == null) return;
    debugPrint('[ime_bridge] 关闭桥接进程...');
    final proc = _process;
    // 先发送 blur 释放 X11 焦点，再发送 quit 退出进程
    _send('blur');
    _send('quit');
    _started = false;
    _process = null;
    // 给进程 200ms 优雅退出，之后强制 kill
    Future.delayed(const Duration(milliseconds: 200), () {
      if (proc != null) {
        debugPrint('[ime_bridge] 强制终止桥接进程');
        proc.kill(ProcessSignal.sigterm);
      }
    });
  }

  void addTextListener(ImeTextListener fn) => _textListeners.add(fn);
  void removeTextListener(ImeTextListener fn) => _textListeners.remove(fn);

  void addSubmitListener(ImeSubmitListener fn) => _submitListeners.add(fn);
  void removeSubmitListener(ImeSubmitListener fn) =>
      _submitListeners.remove(fn);

  void addEscapeListener(ImeEscapeListener fn) => _escapeListeners.add(fn);
  void removeEscapeListener(ImeEscapeListener fn) =>
      _escapeListeners.remove(fn);

  void _send(String cmd) {
    if (_process == null) return;
    try {
      _process!.stdin.write('$cmd\n');
      _process!.stdin.flush();
    } catch (_) {}
  }
}
