/// IME 桥接管理器 —— 常驻 Python GTK 桥接进程
///
/// 启动 bridge/persistent_ime.py 并保持通信。
/// 通过 stdin 发送 focus/blur 命令，从 stdout 读取 IME 输出。
///
/// 协议：
///   READY  —— 桥接就绪
///   T:文本 —— 当前条目完整文本（每次变更）
///   P:数字 —— 光标位置变化（方向键、点击等）
///   S:     —— 用户按 Enter 提交
///   ESC:   —— 用户按 Esc 取消

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

typedef ImeTextListener = void Function(String text);
typedef ImeCursorListener = void Function(int position);
typedef ImeSubmitListener = void Function();
typedef ImeEscapeListener = void Function();

class ImeBridgeManager {
  ImeBridgeManager._();
  static final ImeBridgeManager instance = ImeBridgeManager._();

  Process? _process;
  Future<void>? _starting;
  final List<ImeTextListener> _textListeners = [];
  final List<ImeCursorListener> _cursorListeners = [];
  final List<ImeSubmitListener> _submitListeners = [];
  final List<ImeEscapeListener> _escapeListeners = [];
  bool _started = false;
  bool _wantFocus = false;
  String _pendingFocusText = '';
  Object? _activeOwner;

  Future<void> ensureStarted() async {
    if (_started && _process != null) return;
    if (_starting != null) return _starting!;
    _started = true;

    _starting = _startProcess();
    return _starting!;
  }

  Future<void> _startProcess() async {
    final script = _resolveBridgeScript();
    if (script == null) {
      debugPrint('[ime_bridge] 未找到 bridge/persistent_ime.py');
      _started = false;
      _starting = null;
      return;
    }
    try {
      _process = await Process.start('python3', [script.path]);
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
        } else if (line.startsWith('P:')) {
          final pos = int.tryParse(line.substring(2)) ?? 0;
          for (final l in _cursorListeners) {
            l(pos);
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
        _starting = null;
        _process = null;
      });
    } catch (e) {
      debugPrint('[ime_bridge] 启动失败: $e');
      _started = false;
      _starting = null;
    }
  }

  File? _resolveBridgeScript() {
    final candidates = <String>[
      '${Directory.current.path}/bridge/persistent_ime.py',
      '${Directory.current.path}/chatroom_flutter/bridge/persistent_ime.py',
      '${File(Platform.resolvedExecutable).parent.path}/bridge/persistent_ime.py',
    ];
    for (final path in candidates) {
      final file = File(path);
      if (file.existsSync()) return file;
    }
    return null;
  }

  void setActiveOwner(Object owner) {
    _activeOwner = owner;
  }

  bool isActiveOwner(Object owner) => identical(_activeOwner, owner);

  void releaseOwner(Object owner) {
    if (identical(_activeOwner, owner)) {
      _activeOwner = null;
      releaseFocus();
    }
  }

  void grabFocus([String initialText = '']) {
    _wantFocus = true;
    _pendingFocusText = initialText;
    ensureStarted().then((_) {
      if (_wantFocus) _sendFocus(_pendingFocusText);
    });
  }

  void releaseFocus() {
    _wantFocus = false;
    _pendingFocusText = '';
    _send('blur');
  }

  void setText(String text) => _send('set:${base64Encode(utf8.encode(text))}');
  void clearText() => _send('clear');

  void shutdown() {
    final proc = _process;
    if (proc == null) return;
    debugPrint('[ime_bridge] 关闭桥接进程...');
    // 先发送 blur 释放 X11 焦点，再发送 quit 让进程优雅退出
    _send('blur');
    _send('quit');
    _wantFocus = false;
    _activeOwner = null;
    _started = false;
    _starting = null;
    _process = null;
    // 同步等待 50ms 让 Python 处理 quit 命令（优雅退出 + 释放 X11 焦点）
    // 不用 Future.delayed —— 应用退出时事件循环可能已停止，异步回调不会执行
    sleep(const Duration(milliseconds: 50));
    // SIGTERM 兜底：确保进程被终止（即使 quit 命令丢失或 GTK 主循环卡住）
    try {
      proc.kill(ProcessSignal.sigterm);
    } catch (_) {}
  }

  void addTextListener(ImeTextListener fn) => _textListeners.add(fn);
  void removeTextListener(ImeTextListener fn) => _textListeners.remove(fn);

  void addCursorListener(ImeCursorListener fn) => _cursorListeners.add(fn);
  void removeCursorListener(ImeCursorListener fn) =>
      _cursorListeners.remove(fn);

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

  void _sendFocus(String text) {
    _send('focus:${base64Encode(utf8.encode(text))}');
  }
}
