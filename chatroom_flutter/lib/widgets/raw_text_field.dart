/// 绕过系统 IME 的文本输入框（含 IME 桥接支持）
///
/// ASCII 输入直接捕获键盘事件；中文通过 Python GTK 桥接进程处理，
/// 完全避免 Flutter + fcitx 在 Linux 上的 GTK IM Context 死锁。
///
/// **焦点稳定性**：`onKeyEvent` 直接绑定到 `FocusNode` 上（而非通过
/// `Focus` widget 参数），避免 widget rebuild 时回调重建导致的焦点脱钩。
///
/// 桥接协议：
///   T:文本 —— 当前条目完整文本，直接替换显示内容
///   S:     —— 用户按 Enter 提交
///   ESC:   —— 用户按 Esc 取消

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/chat_models.dart';
import '../services/ime_bridge.dart';

class RawTextField extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final String? hintText;
  final bool obscureText;
  final bool showVisibilityToggle;
  final bool showChineseInput;
  final ValueChanged<String>? onSubmitted;
  // 阶段 N3（P2-4 图片粘贴直发）：剪贴板含图片时回调（经 GTK 桥接读取）
  final ValueChanged<Uint8List>? onImagePasted;

  const RawTextField({
    super.key,
    required this.controller,
    this.focusNode,
    this.hintText,
    this.obscureText = false,
    this.showVisibilityToggle = false,
    this.showChineseInput = false,
    this.onSubmitted,
    this.onImagePasted,
  });

  @override
  State<RawTextField> createState() => _RawTextFieldState();
}

class _RawTextFieldState extends State<RawTextField> {
  late final FocusNode _focusNode;
  final Object _imeOwner = Object();
  /// 阶段 N 补充（鼠标文字选择）：内容 RichText 的 key，用于
  /// 全局坐标 → 字符索引映射（TextPainter 测量）
  final GlobalKey _textKey = GlobalKey();
  int _cursorPos = 0;
  int _selStart = 0;
  int _selEnd = 0;
  bool _hasFocus = false;
  bool _bridgeActive = false;
  bool _stealingFocus = false;
  bool _submitting = false;
  bool _updatingController = false;
  Timer? _cursorTimer;
  bool _showCursor = true;
  late bool _obscured;

  bool get _hasSelection => _selStart != _selEnd;
  int get _selLow => _selStart < _selEnd ? _selStart : _selEnd;
  int get _selHigh => _selStart < _selEnd ? _selEnd : _selStart;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _obscured = widget.obscureText;
    _cursorPos = widget.controller.text.length;
    _selStart = _cursorPos;
    _selEnd = _cursorPos;

    // 将 onKeyEvent 直接绑定到 FocusNode，避免 rebuild 时回调重建导致焦点脱钩
    _focusNode.onKeyEvent = _onKey;

    widget.controller.addListener(_onControllerChanged);

    if (widget.showChineseInput) {
      ImeBridgeManager.instance.ensureStarted();
      ImeBridgeManager.instance.addTextListener(_onImeText);
      ImeBridgeManager.instance.addCursorListener(_onImeCursor);
      ImeBridgeManager.instance.addSubmitListener(_onImeSubmit);
      ImeBridgeManager.instance.addEscapeListener(_onImeEscape);
      // 阶段 N5（P2-14 键盘导航）：中文输入激活时方向键经桥接输出
      // NAV:UP/NAV:DOWN，此处注册监听执行焦点切换（客户端内部管道）
      ImeBridgeManager.instance.addNavUpListener(_onNavUp);
      ImeBridgeManager.instance.addNavDownListener(_onNavDown);
      // 阶段 N3 补充：桥接 Ctrl+V 拦截到剪贴板图片 → 主动推送
      ImeBridgeManager.instance.addImageListener(_onBridgeImage);
    }

    _focusNode.addListener(_onFocusChanged);

    _cursorTimer = Timer.periodic(
      const Duration(milliseconds: 530),
      (_) {
        if ((_hasFocus || _bridgeActive) && mounted) {
          setState(() => _showCursor = !_showCursor);
        }
      },
    );

    // controller listener 只处理外部 clear/set；内部编辑用 _updatingController
    // 屏蔽回调，避免删除键和 IME 同步产生竞态。
  }

  @override
  void dispose() {
    _cursorTimer?.cancel();
    _focusNode.onKeyEvent = null;
    _focusNode.removeListener(_onFocusChanged);
    widget.controller.removeListener(_onControllerChanged);
    if (widget.showChineseInput) {
      // 确保桥接释放焦点，避免残留焦点阻塞其他界面输入
      _bridgeActive = false;
      ImeBridgeManager.instance.releaseOwner(_imeOwner);
      ImeBridgeManager.instance.removeTextListener(_onImeText);
      ImeBridgeManager.instance.removeCursorListener(_onImeCursor);
      ImeBridgeManager.instance.removeSubmitListener(_onImeSubmit);
      ImeBridgeManager.instance.removeEscapeListener(_onImeEscape);
      ImeBridgeManager.instance.removeNavUpListener(_onNavUp);
      ImeBridgeManager.instance.removeNavDownListener(_onNavDown);
      ImeBridgeManager.instance.removeImageListener(_onBridgeImage);
    }
    // 仅自行创建的 FocusNode 才 dispose，外部传入的不管理
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    super.dispose();
  }

  // ---- 焦点管理 ----

  void _onFocusChanged() {
    setState(() {
      _hasFocus = _focusNode.hasFocus;
      _showCursor = true;
    });

    if (!widget.showChineseInput) return;

    if (_hasFocus) {
      // 获得焦点时始终调用 _activateBridge，确保桥接的 GTK 窗口
      // 重新获取 X11 焦点（解决从侧边栏等其它区域切回后 IME 切换失效）
      _activateBridge();
    } else if (!_hasFocus && _bridgeActive && !_stealingFocus) {
      // 用户点击了其他地方 → 释放桥接
      _deactivateBridge();
    }
  }

  void _activateBridge() {
    _stealingFocus = true;
    _bridgeActive = true;
    // 阶段 N 补充（用户反馈）：把桥接 GTK 窗口移到输入框下方，候选窗口
    // 跟随输入框显示（原先固定在屏幕外 → 候选窗口出现在屏幕左上角）。
    // 须在 grabFocus（夺焦）之前发送：X11 活动窗口此时仍是 Flutter 窗口。
    // localToGlobal 返回 Flutter 逻辑坐标，桥接 GTK 的 win.move 按
    // 物理像素定位（HiDPI 下实测 2 倍缩放）——乘 devicePixelRatio 换算。
    final box = context.findRenderObject() as RenderBox?;
    if (box != null && box.attached) {
      final offset = box.localToGlobal(Offset.zero);
      final dpr = MediaQuery.of(context).devicePixelRatio;
      ImeBridgeManager.instance.moveWindow(
          (offset.dx * dpr).round(),
          ((offset.dy + box.size.height + 2) * dpr).round());
    }
    ImeBridgeManager.instance.setActiveOwner(_imeOwner);
    ImeBridgeManager.instance.grabFocus(widget.controller.text);

    Future.delayed(const Duration(milliseconds: 120), () {
      if (mounted) _stealingFocus = false;
    });
  }

  void _deactivateBridge() {
    _bridgeActive = false;
    ImeBridgeManager.instance.releaseOwner(_imeOwner);
    if (_hasSelection) _clearSelection();
  }

  void _onControllerChanged() {
    if (_updatingController) return;
    final len = widget.controller.text.length;
    final nextCursor = _clampIndex(_cursorPos, len);
    setState(() {
      _cursorPos = nextCursor;
      _clearSelection();
    });
    if (widget.showChineseInput &&
        _bridgeActive &&
        ImeBridgeManager.instance.isActiveOwner(_imeOwner)) {
      if (widget.controller.text.isEmpty) {
        ImeBridgeManager.instance.clearText();
      } else {
        ImeBridgeManager.instance.setText(widget.controller.text);
      }
    }
  }

  void _setControllerText(String text, int cursor) {
    _updatingController = true;
    widget.controller.text = text;
    _updatingController = false;
    _cursorPos = _clampIndex(cursor, text.length);
    _clearSelection();
  }

  int _clampIndex(int value, int length) => value.clamp(0, length).toInt();

  // ---- IME 桥接回调 ----

  /// 收到桥接的完整文本 → 直接替换显示内容
  void _onImeText(String text) {
    if (_submitting ||
        !mounted ||
        !_bridgeActive ||
        !ImeBridgeManager.instance.isActiveOwner(_imeOwner)) {
      return;
    }
    setState(() {
      _setControllerText(text, text.length);
    });
  }

  /// 收到桥接的光标位置变化 → 更新视觉光标（方向键、点击等）
  void _onImeCursor(int position) {
    if (!mounted ||
        !_bridgeActive ||
        !ImeBridgeManager.instance.isActiveOwner(_imeOwner)) {
      return;
    }
    setState(() {
      _cursorPos = _clampIndex(position, widget.controller.text.length);
      _clearSelection();
    });
  }

  /// 收到桥接的提交信号 → 触发 onSubmitted
  void _onImeSubmit() {
    if (!_bridgeActive || !ImeBridgeManager.instance.isActiveOwner(_imeOwner)) {
      return;
    }
    _submitting = true;
    final text = widget.controller.text;
    _bridgeActive = false;
    ImeBridgeManager.instance.releaseOwner(_imeOwner);
    if (text.isNotEmpty) {
      widget.onSubmitted?.call(text);
    }
    _submitting = false;
  }

  /// 收到桥接的取消信号 → 放弃输入
  void _onImeEscape() {
    if (!_bridgeActive || !ImeBridgeManager.instance.isActiveOwner(_imeOwner)) {
      return;
    }
    _bridgeActive = false;
    ImeBridgeManager.instance.releaseOwner(_imeOwner);
    setState(() {
      _setControllerText('', 0);
    });
  }

  /// 阶段 N5：无 onSubmitted 的输入框回车 → 跳到下一个输入框
  /// （末框不循环回第一个；与 Tab 的环绕语义区分）
  void _moveFocusForward() {
    if (_focusNode.context == null) return;
    try {
      _focusNode.focusInDirection(TraversalDirection.down);
    } catch (_) {}
  }

  // ---- 阶段 N5（P2-14 键盘导航）：桥接 NAV 信号 → 焦点切换 ----
  // 中文输入（showChineseInput）激活时方向键走 GTK 桥接进程，Flutter
  // 侧收不到 ↑/↓；桥接拦截后输出 NAV:UP/NAV:DOWN，此处执行与 ASCII
  // 路径一致的焦点切换（上 = 前一个，下 = 下一个，边界不越界）。
  // 仅当前激活输入框响应（isActiveOwner 守门，避免多输入框串扰）。

  void _onNavUp() {
    if (!_bridgeActive || !ImeBridgeManager.instance.isActiveOwner(_imeOwner)) {
      return;
    }
    // P-69 修复（用户实测崩溃）：输入框已从树卸载（context null）时
    // focusInDirection 内部 null check 会抛未处理异常（桥接 stdout 的
    // NAV 行在 dispose 竞态窗口内到达）。防御：未挂载/异常均静默忽略。
    if (_focusNode.context == null) return;
    try {
      _focusNode.focusInDirection(TraversalDirection.up);
    } catch (_) {}
  }

  void _onNavDown() {
    if (!_bridgeActive || !ImeBridgeManager.instance.isActiveOwner(_imeOwner)) {
      return;
    }
    if (_focusNode.context == null) return;
    try {
      _focusNode.focusInDirection(TraversalDirection.down);
    } catch (_) {}
  }

  /// 阶段 N3 补充：桥接推送的剪贴板图片（仅当前激活输入框响应）
  void _onBridgeImage(Uint8List bytes) {
    if (!mounted ||
        !_bridgeActive ||
        !ImeBridgeManager.instance.isActiveOwner(_imeOwner)) {
      return;
    }
    widget.onImagePasted?.call(bytes);
  }

  // ---- 选择操作 ----

  String _selectedText() {
    final t = widget.controller.text;
    if (!_hasSelection) return '';
    return t.substring(_selLow, _selHigh);
  }

  void _clearSelection() {
    _selStart = _cursorPos;
    _selEnd = _cursorPos;
  }

  // ---- 阶段 N 补充（鼠标文字选择）----

  /// 把全局坐标映射为字符索引（TextPainter 测量，与 _buildContent 同字体）。
  int _charIndexAtGlobal(Offset global) {
    final box = _textKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return _cursorPos;
    final local = box.globalToLocal(global);
    final text = widget.controller.text;
    final display = _obscured ? '●' * text.length : text;
    if (display.isEmpty) return 0;
    final baseStyle = DefaultTextStyle.of(context).style.copyWith(
          fontSize: 16,
          fontFamilyFallback: const ['NotoColorEmoji'],
        );
    final tp = TextPainter(
      text: TextSpan(style: baseStyle, text: display),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return tp
        .getPositionForOffset(local)
        .offset
        .clamp(0, text.length);
  }

  /// 光标/选区变化后同步到桥接 GTK entry（保证中文输入插入点正确）。
  /// 缓存经 focus 命令一并发送（合并单写规避 IOSink 丢失），
  /// 首次激活（tapdown 时桥接尚未激活）同样生效。
  void _syncCursorToBridge(int position) {
    if (widget.showChineseInput) {
      ImeBridgeManager.instance.setCursor(position);
    }
  }

  void _onTapDownAt(TapDownDetails details) {
    final idx = _charIndexAtGlobal(details.globalPosition);
    setState(() {
      _cursorPos = idx;
      _clearSelection();
    });
    _syncCursorToBridge(idx);
  }

  void _onPanStartAt(DragStartDetails details) {
    final idx = _charIndexAtGlobal(details.globalPosition);
    setState(() {
      _cursorPos = idx;
      _selStart = idx;
      _selEnd = idx;
    });
    _syncCursorToBridge(idx);
  }

  void _onPanUpdateAt(DragUpdateDetails details) {
    final idx = _charIndexAtGlobal(details.globalPosition);
    if (idx == _cursorPos) return;
    setState(() {
      _cursorPos = idx;
      _selEnd = idx;
    });
    _syncCursorToBridge(idx);
  }

  void _deleteSelection() {
    if (!_hasSelection) return;
    final t = widget.controller.text;
    setState(() {
      _setControllerText(
        t.substring(0, _selLow) + t.substring(_selHigh),
        _selLow,
      );
    });
  }

  // ---- 键盘事件处理 ----

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;

    // Ctrl 快捷键
    if (ctrl) {
      if (key == LogicalKeyboardKey.keyA) {
        _selectAll();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyC) {
        _copy();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyV) {
        _paste();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyX) {
        _cut();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // 转义（仅在桥接不活跃时，桥接活跃时桥接处理 Esc）
    if (key == LogicalKeyboardKey.escape) {
      _focusNode.unfocus();
      return KeyEventResult.handled;
    }

    // 回车 → 提交（阶段 N5：有 onSubmitted 触发提交/发送；
    // 无回调的输入框（对话框中间输入框等）回车自动跳到下一个输入框）
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (widget.onSubmitted != null) {
        widget.onSubmitted!(widget.controller.text);
      } else {
        _moveFocusForward();
      }
      return KeyEventResult.handled;
    }

    // Tab
    if (key == LogicalKeyboardKey.tab) {
      _focusNode.nextFocus();
      return KeyEventResult.handled;
    }

    // 阶段 N5（P2-14 键盘导航）：↑/↓ 切换同一界面输入框焦点
    // （上 = 前一个，下 = 下一个；首/末不越界——
    // focusInDirection 与 Flutter 默认方向导航一致，边界不环绕）
    if (key == LogicalKeyboardKey.arrowUp) {
      if (_focusNode.context != null) {
        try {
          _focusNode.focusInDirection(TraversalDirection.up);
        } catch (_) {}
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      if (_focusNode.context != null) {
        try {
          _focusNode.focusInDirection(TraversalDirection.down);
        } catch (_) {}
      }
      return KeyEventResult.handled;
    }

    // 退格/删除
    if (key == LogicalKeyboardKey.backspace) {
      if (_hasSelection) {
        _deleteSelection();
      } else {
        _deleteBefore();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete) {
      if (_hasSelection) {
        _deleteSelection();
      } else {
        _deleteAfter();
      }
      return KeyEventResult.handled;
    }

    // 方向键
    if (key == LogicalKeyboardKey.arrowLeft) {
      _moveLeft(shift);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _moveRight(shift);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      setState(() {
        if (shift && !_hasSelection) _selStart = _cursorPos;
        _cursorPos = 0;
        if (shift) {
          _selEnd = _cursorPos;
        } else {
          _clearSelection();
        }
      });
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      setState(() {
        if (shift && !_hasSelection) _selStart = _cursorPos;
        _cursorPos = widget.controller.text.length;
        if (shift) {
          _selEnd = _cursorPos;
        } else {
          _clearSelection();
        }
      });
      return KeyEventResult.handled;
    }

    // ---- 字符输入（ASCII 直接输入，中文由桥接处理）----
    final char = event.character;
    if (char != null && char.isNotEmpty) {
      for (int i = 0; i < char.length; i++) {
        final code = char.codeUnitAt(i);
        if (code >= 0x20 && code != 0x7F) {
          if (_hasSelection) _deleteSelection();
          _insert(String.fromCharCode(code));
        }
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _moveLeft(bool shift) {
    setState(() {
      if (shift) {
        // 选区模型：_selStart 为固定锚点，_selEnd 为跟随光标的移动端
        // 无选区时以当前光标位置建立锚点
        if (!_hasSelection) _selStart = _cursorPos;
        if (_cursorPos > 0) _cursorPos--;
        _selEnd = _cursorPos;
      } else {
        if (_cursorPos > 0) _cursorPos--;
        _clearSelection();
      }
    });
  }

  void _moveRight(bool shift) {
    setState(() {
      if (shift) {
        if (!_hasSelection) _selStart = _cursorPos;
        if (_cursorPos < widget.controller.text.length) _cursorPos++;
        _selEnd = _cursorPos;
      } else {
        if (_cursorPos < widget.controller.text.length) _cursorPos++;
        _clearSelection();
      }
    });
  }

  void _selectAll() {
    setState(() {
      _selStart = 0;
      _selEnd = widget.controller.text.length;
      _cursorPos = _selEnd;
    });
  }

  void _copy() {
    if (!_hasSelection) return;
    Clipboard.setData(ClipboardData(text: _selectedText()));
  }

  void _cut() {
    if (!_hasSelection) return;
    Clipboard.setData(ClipboardData(text: _selectedText()));
    _deleteSelection();
  }

  void _paste() async {
    // 阶段 N3 修订（用户反馈）：图片优先——文件管理器复制图片文件时
    // 剪贴板同时含路径文本与文件数据，先查图片避免把路径当文字粘贴
    if (widget.onImagePasted != null) {
      final image = await ImeBridgeManager.instance.readClipboardImage();
      if (image != null && image.isNotEmpty) {
        widget.onImagePasted!(image);
        return;
      }
    }
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      // 文本像图片文件路径（file:// 或本地路径）且文件为支持的图片 →
      // 读取文件走图片发送，不把路径当文字插入
      final imagePath = _imagePathFromText(text);
      if (imagePath != null && widget.onImagePasted != null) {
        try {
          final bytes = File(imagePath).readAsBytesSync();
          if (isSupportedImage(bytes)) {
            widget.onImagePasted!(bytes);
            return;
          }
        } catch (_) {
          // 读取失败回退为文本粘贴
        }
      }
      if (_hasSelection) _deleteSelection();
      for (int i = 0; i < text.length; i++) {
        final ch = text[i];
        final code = ch.codeUnitAt(0);
        if (code >= 0x20 && ch != '\n') {
          _insert(ch);
        } else if (ch == '\n') {
          widget.onSubmitted?.call(widget.controller.text);
        }
      }
    }
  }

  /// 文本是否为指向图片文件的路径（单行、图片扩展名、文件存在）
  String? _imagePathFromText(String text) {
    var t = text.trim();
    if (t.isEmpty || t.contains('\n')) return null;
    if (t.startsWith('file://')) t = t.substring(7);
    if (!RegExp(r'\.(png|jpe?g|gif)\s*$', caseSensitive: false)
        .hasMatch(t)) {
      return null;
    }
    if (!File(t).existsSync()) return null;
    return t;
  }

  void _insert(String ch) {
    final t = widget.controller.text;
    final pos = _clampIndex(_cursorPos, t.length);
    setState(() {
      _setControllerText(t.substring(0, pos) + ch + t.substring(pos), pos + 1);
    });
  }

  void _deleteBefore() {
    if (_cursorPos <= 0) return;
    final t = widget.controller.text;
    final newPos = _clampIndex(_cursorPos - 1, t.length);
    setState(() {
      _setControllerText(
        t.substring(0, newPos) + t.substring(_clampIndex(_cursorPos, t.length)),
        newPos,
      );
    });
  }

  void _deleteAfter() {
    final t = widget.controller.text;
    final pos = _clampIndex(_cursorPos, t.length);
    if (pos >= t.length) return;
    setState(() {
      _setControllerText(t.substring(0, pos) + t.substring(pos + 1), pos);
    });
  }

  // ---- UI ----

  bool get _visuallyFocused => _bridgeActive || _hasFocus;

  @override
  Widget build(BuildContext context) {
    final text = widget.controller.text;
    final display = _obscured ? '●' * text.length : text;

    return TapRegion(
      onTapOutside: (_) {
        if (_bridgeActive) _deactivateBridge();
        _focusNode.unfocus();
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // 阶段 N 补充：鼠标点击定位光标 + 拖动选择文字
        // （配合既有 Ctrl+C/X/V 快捷键，补齐文本选择操作）
        onTapDown: _onTapDownAt,
        onPanStart: _onPanStartAt,
        onPanUpdate: _onPanUpdateAt,
        onTap: () {
          _focusNode.requestFocus();
          // 如果桥接活跃但用户点击了输入框，重新抢占焦点
          // （处理用户点击别处后返回输入框的场景）
          if (_bridgeActive) {
            ImeBridgeManager.instance.setActiveOwner(_imeOwner);
            ImeBridgeManager.instance.grabFocus(widget.controller.text);
          }
          if (_hasSelection) setState(() => _clearSelection());
        },
        child: Focus(
          focusNode: _focusNode,
          // onKeyEvent 已在 initState 中直接绑定到 _focusNode，
          // 不通过 widget 参数传递，避免 rebuild 时脱钩
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              color: _visuallyFocused
                  ? Theme.of(context).colorScheme.surfaceContainerHighest
                  : Theme.of(context).colorScheme.surfaceContainerLow,
              border: Border.all(
                color: _visuallyFocused
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.outline,
                width: _visuallyFocused ? 2.0 : 1.0,
              ),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              children: [
                Expanded(child: _buildContent(text, display)),
                if (widget.showVisibilityToggle)
                  SizedBox(
                    width: 36,
                    height: 36,
                    child: IconButton(
                      icon: Icon(
                        _obscured
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded,
                        size: 20,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      padding: EdgeInsets.zero,
                      onPressed: () => setState(() => _obscured = !_obscured),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(String text, String display) {
    if (text.isEmpty && !_visuallyFocused) {
      return Text(
        widget.hintText ?? '',
        style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 16),
      );
    }
    if (text.isEmpty && _visuallyFocused) {
      return Text(
        _showCursor ? '|' : ' ',
        style: TextStyle(
            fontSize: 16, color: Theme.of(context).colorScheme.primary),
      );
    }

    final low = _clampIndex(_selLow, display.length);
    final high = _clampIndex(_selHigh, display.length);
    final cursor = _clampIndex(_cursorPos, display.length);
    final spans = <InlineSpan>[];
    // R-P10：emoji 兜底内置 COLRv1 彩色字体（与 _charIndexAtGlobal 测量样式一致）
    final baseStyle = DefaultTextStyle.of(context).style.copyWith(
          fontSize: 16,
          fontFamilyFallback: const ['NotoColorEmoji'],
        );

    // P-68（缺陷修复）：光标在任意位置均渲染细条 '|'（与末尾光标同样式：
    // primary 色 + w100 字重），字符本身正常渲染——不再把光标处字符反色
    // 渲染成覆盖整个字符的块状光标（中文/全角字符下像"覆盖一个字"）。
    // 选区高亮与 530ms 闪烁逻辑不变。
    var cursorBarEmitted = false;
    int i = 0;
    while (i < display.length || (i == cursor && i == display.length)) {
      if (i >= display.length) {
        spans.add(TextSpan(
          text: _showCursor ? '|' : ' ',
          style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w100),
        ));
        break;
      }
      if (i < low) {
        final end = low < display.length ? low : display.length;
        spans.add(TextSpan(text: display.substring(i, end)));
        i = end;
        continue;
      }
      if (i >= low && i < high) {
        spans.add(TextSpan(
          text: display.substring(i, high),
          style: TextStyle(
            backgroundColor:
                Theme.of(context).colorScheme.primary.withValues(alpha: 0.35),
          ),
        ));
        i = high;
        continue;
      }
      if (i == cursor && !_hasSelection && !cursorBarEmitted) {
        if (i < display.length) {
          spans.add(TextSpan(
            text: _showCursor ? '|' : ' ',
            style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w100),
          ));
          cursorBarEmitted = true;
          continue;
        }
      }
      spans.add(TextSpan(text: display.substring(i)));
      break;
    }

    return RichText(
      key: _textKey,
      text: TextSpan(style: baseStyle, children: spans),
    );
  }
}
