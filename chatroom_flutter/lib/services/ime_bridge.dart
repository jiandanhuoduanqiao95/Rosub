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
///   NAV:UP / NAV:DOWN —— 用户按 ↑/↓（阶段 N5 键盘导航：中文输入激活时
///     方向键走桥接，Flutter 侧收不到，由本管理器解析后派发给监听者执行
///     焦点切换——客户端内部管道，不触冻结协议 v1.0.0）
///   IMG:<base64> —— clip: 命令响应（阶段 N3 图片粘贴直发：剪贴板图片
///     PNG 字节；空为无图片）

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

typedef ImeTextListener = void Function(String text);
typedef ImeCursorListener = void Function(int position);
typedef ImeSubmitListener = void Function();
typedef ImeEscapeListener = void Function();
typedef ImeBridgeImageListener = void Function(Uint8List bytes);

class ImeBridgeManager {
  ImeBridgeManager._();
  static final ImeBridgeManager instance = ImeBridgeManager._();

  Process? _process;
  Future<void>? _starting;
  final List<ImeTextListener> _textListeners = [];
  final List<ImeCursorListener> _cursorListeners = [];
  final List<ImeSubmitListener> _submitListeners = [];
  final List<ImeEscapeListener> _escapeListeners = [];
  // 阶段 N5：键盘导航监听器（NAV:UP / NAV:DOWN）
  final List<VoidCallback> _navUpListeners = [];
  final List<VoidCallback> _navDownListeners = [];
  // 阶段 N3 补充：桥接主动推送的剪贴板图片（Ctrl+V 拦截，IMGP: 行）
  final List<ImeBridgeImageListener> _imageListeners = [];
  // 阶段 N3：剪贴板图片读取的待决响应
  Completer<Uint8List?>? _clipImageCompleter;
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
    // 测试环境（flutter test 设置 FLUTTER_TEST=true）：不启动真实子进程，
    // 避免 Process.run 的异步定时器在 FakeAsync 下遗留（teardown 报 pending timer），
    // 且测试中无需真实 GTK 输入法桥接。
    if (Platform.environment['FLUTTER_TEST'] == 'true') {
      _started = false;
      _starting = null;
      return;
    }
    final script = _resolveBridgeScript();
    if (script == null) {
      debugPrint('[ime_bridge] 未找到 bridge/persistent_ime.py');
      _started = false;
      _starting = null;
      return;
    }
    try {
      final python = await _resolvePython();
      if (python == null) {
        debugPrint('[ime_bridge] 未找到可用 python（需包含 cairo + gi 模块）');
        _started = false;
        _starting = null;
        return;
      }
      _process = await Process.start(python, [script.path]);
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
        } else if (line == 'NAV:UP') {
          // 阶段 N5 键盘导航：中文输入时方向键经桥接到达
          for (final l in _navUpListeners) {
            l();
          }
        } else if (line == 'NAV:DOWN') {
          for (final l in _navDownListeners) {
            l();
          }
        } else if (line.startsWith('IMGP:')) {
          // 阶段 N3 补充：桥接侧 Ctrl+V 拦截到剪贴板图片 → 主动推送，
          // 广播给监听者（当前桥接活跃的输入框触发 onImagePasted）
          final payload = line.substring(5);
          if (payload.isNotEmpty) {
            try {
              final bytes = base64Decode(payload);
              for (final l in _imageListeners) {
                l(bytes);
              }
            } catch (_) {}
          }
        } else if (line.startsWith('IMG:')) {
          // 阶段 N3：剪贴板图片读取响应（clip: 命令）
          final completer = _clipImageCompleter;
          _clipImageCompleter = null;
          if (completer != null) {
            final payload = line.substring(4);
            if (payload.isEmpty) {
              completer.complete(null);
            } else {
              try {
                completer.complete(base64Decode(payload));
              } catch (_) {
                completer.complete(null);
              }
            }
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

  /// 探测一个具备 cairo + gi(Gtk) 模块的 Python 解释器。
  ///
  /// persistent_ime.py 依赖 cairo 与 PyGObject(Gtk)，
  /// 而 PATH 中的 python3 可能是 miniconda 等缺失这些模块的环境，
  /// 直接启动会导致桥接进程崩溃（ModuleNotFoundError）。
  /// 依次尝试：项目 .venv → 系统 /usr/bin/python3 → PATH python3，
  /// 用 `-c` 探测实际可用性，避免仅凭路径猜测。
  Future<String?> _resolvePython() async {
    final candidates = <String>[
      '${Directory.current.path}/.venv/bin/python',
      '${File(Platform.resolvedExecutable).parent.path}/.venv/bin/python',
      '/usr/bin/python3',
      'python3',
    ];
    const probe =
        'import cairo, gi; gi.require_version("Gtk", "3.0"); from gi.repository import Gtk';
    for (final python in candidates) {
      try {
        final result = await Process.run(python, ['-c', probe]);
        if (result.exitCode == 0) {
          debugPrint('[ime_bridge] 使用 python: $python');
          return python;
        }
      } catch (_) {
        // 该解释器不存在或不可执行，尝试下一个
      }
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

  /// 阶段 N 补充（用户反馈）：把桥接 GTK 窗口移到屏幕全局坐标 (x, y)
  /// （x/y 为输入框底部在屏幕上的全局坐标——localToGlobal 已换算），
  /// 候选窗口跟随实际输入框而非屏幕左上角。
  /// 桥接进程尚未启动时先缓存，进程就绪后随 focus 命令一并发送
  /// （首次点击输入框即生效，不必二次点击）。
  String? _pendingMove;
  int? _pendingCursor;

  void moveWindow(int x, int y) {
    // 总是缓存而非直接发送：move/focus/cur 会并入同一条 stdin 写入。
    // Dart VM 的 IOSink add+flush 存在随机静默丢失竞态（AGENTS.md
    // 阶段 J 注，管道 stdin 同样受影响，实测第二条命令整体丢失）——
    // 每次激活只做一次写入即可规避。
    _pendingMove = 'move:$x,$y';
  }

  /// 阶段 N 补充：同步 Flutter 侧光标位置到桥接 GTK entry
  /// （鼠标点击/拖动选择后保证后续输入的插入点正确）。
  /// 缓存到 focus 命令一并发送（见 moveWindow 注释）。
  void setCursor(int position) => _pendingCursor = position;

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

  // ---- 阶段 N5：键盘导航监听器（NAV:UP / NAV:DOWN）----

  void addNavUpListener(VoidCallback fn) => _navUpListeners.add(fn);
  void removeNavUpListener(VoidCallback fn) => _navUpListeners.remove(fn);

  void addNavDownListener(VoidCallback fn) => _navDownListeners.add(fn);
  void removeNavDownListener(VoidCallback fn) => _navDownListeners.remove(fn);

  // ---- 阶段 N3 补充：桥接剪贴板图片推送监听 ----

  void addImageListener(ImeBridgeImageListener fn) => _imageListeners.add(fn);
  void removeImageListener(ImeBridgeImageListener fn) =>
      _imageListeners.remove(fn);

  /// 读取剪贴板图片（阶段 N3：P2-4 图片粘贴直发）。
  ///
  /// 向桥接进程发送 clip: 命令，等待 IMG:<base64> 响应并解码为 PNG 字节；
  /// 无图片 / 无进程 / 超时（2s）→ 返回 null。测试环境（FLUTTER_TEST）
  /// 无进程 → 立即返回 null，不影响既有文本粘贴路径。
  Future<Uint8List?> readClipboardImage() async {
    if (_process == null) return null;
    final completer = Completer<Uint8List?>();
    _clipImageCompleter = completer;
    _send('clip');
    try {
      return await completer.future
          .timeout(const Duration(seconds: 2), onTimeout: () => null);
    } finally {
      if (identical(_clipImageCompleter, completer)) {
        _clipImageCompleter = null;
      }
    }
  }

  void _sendFocus(String text) {
    // move/cursor/focus 合并为**一条** stdin 写入：
    // focus:<b64>@x,y#pos —— @x,y 为屏幕物理坐标（桥接窗口先就位，
    // 候选窗口跟随输入框），#pos 为光标位置。多条紧连写入会触发
    // Dart IOSink add+flush 静默丢失（focus 整体丢失 → 中文输入失灵，
    // 用户实测"无法按 Shift 切换输入法"）。
    var line = 'focus:${base64Encode(utf8.encode(text))}';
    final move = _pendingMove;
    if (move != null) {
      _pendingMove = null;
      line = '$line@${move.substring(5)}';
    }
    final cursor = _pendingCursor;
    if (cursor != null) {
      _pendingCursor = null;
      line = '$line#$cursor';
    }
    _send(line);
  }

  void _send(String cmd) {
    if (_process == null) return;
    try {
      _process!.stdin.write('$cmd\n');
      _process!.stdin.flush();
    } catch (_) {}
  }
}
