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
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/ime_bridge.dart';

class RawTextField extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final String? hintText;
  final bool obscureText;
  final bool showVisibilityToggle;
  final bool showChineseInput;
  final ValueChanged<String>? onSubmitted;

  const RawTextField({
    super.key,
    required this.controller,
    this.focusNode,
    this.hintText,
    this.obscureText = false,
    this.showVisibilityToggle = false,
    this.showChineseInput = false,
    this.onSubmitted,
  });

  @override
  State<RawTextField> createState() => _RawTextFieldState();
}

class _RawTextFieldState extends State<RawTextField> {
  late final FocusNode _focusNode;
  final Object _imeOwner = Object();
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

    // 回车 → 提交
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      widget.onSubmitted?.call(widget.controller.text);
      return KeyEventResult.handled;
    }

    // Tab
    if (key == LogicalKeyboardKey.tab) {
      _focusNode.nextFocus();
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
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
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
                    : Colors.grey.shade400,
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
                        color: Colors.grey.shade600,
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
        style: TextStyle(color: Colors.grey.shade500, fontSize: 16),
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
    final baseStyle = DefaultTextStyle.of(context).style.copyWith(fontSize: 16);

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
      if (i == cursor && !_hasSelection) {
        if (i < display.length) {
          spans.add(TextSpan(
            text: display[i],
            style: TextStyle(
              backgroundColor: _showCursor
                  ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.7)
                  : Colors.transparent,
              color:
                  _showCursor ? Theme.of(context).colorScheme.onPrimary : null,
            ),
          ));
          i++;
          continue;
        }
      }
      spans.add(TextSpan(text: display.substring(i)));
      break;
    }

    return RichText(text: TextSpan(style: baseStyle, children: spans));
  }
}
