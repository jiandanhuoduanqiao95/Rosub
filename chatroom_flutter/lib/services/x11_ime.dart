/// X11 IME 桥接 —— 通过 C 共享库调用 X11 输入法
///
/// bridge/libx11ime.so 包装了 XOpenDisplay / XCreateIC / Xutf8LookupString 等变参函数，
/// 提供非变参接口供 dart:ffi 调用。

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

typedef _InitNative = Pointer<Void> Function(Int);
typedef _InitDart = Pointer<Void> Function(int);

typedef _ProcessNative = Int Function(
    Pointer<Void>, Int, Uint32, Pointer<Uint8>, Int);
typedef _ProcessDart = int Function(
    Pointer<Void>, int, int, Pointer<Uint8>, int);

typedef _SetFocusNative = Void Function(Pointer<Void>, Int);
typedef _SetFocusDart = void Function(Pointer<Void>, int);

typedef _DestroyNative = Void Function(Pointer<Void>);
typedef _DestroyDart = void Function(Pointer<Void>);

class X11ImeManager {
  X11ImeManager._();
  static final X11ImeManager instance = X11ImeManager._();

  DynamicLibrary? _lib;
  Pointer<Void>? _ctx; // {Display*, XIM, XIC}
  bool _ready = false;

  // USB HID usage → X11 keysym
  static final Map<int, int> _usbToKeysym = {
    0x04: 0x0061, 0x05: 0x0062, 0x06: 0x0063, 0x07: 0x0064,
    0x08: 0x0065, 0x09: 0x0066, 0x0A: 0x0067, 0x0B: 0x0068,
    0x0C: 0x0069, 0x0D: 0x006A, 0x0E: 0x006B, 0x0F: 0x006C,
    0x10: 0x006D, 0x11: 0x006E, 0x12: 0x006F, 0x13: 0x0070,
    0x14: 0x0071, 0x15: 0x0072, 0x16: 0x0073, 0x17: 0x0074,
    0x18: 0x0075, 0x19: 0x0076, 0x1A: 0x0077, 0x1B: 0x0078,
    0x1C: 0x0079, 0x1D: 0x007A,
    0x1E: 0x0031, 0x1F: 0x0032, 0x20: 0x0033, 0x21: 0x0034,
    0x22: 0x0035, 0x23: 0x0036, 0x24: 0x0037, 0x25: 0x0038,
    0x26: 0x0039, 0x27: 0x0030,
    0x2C: 0x0020, 0x28: 0xFF0D, 0x2A: 0xFF08, 0x2B: 0xFF09,
    0x2D: 0x002D, 0x2E: 0x003D, 0x2F: 0x005B, 0x30: 0x005D,
    0x31: 0x005C, 0x33: 0x003B, 0x34: 0x0027,
    0x35: 0x0060, 0x36: 0x002C, 0x37: 0x002E, 0x38: 0x002F,
  };

  bool init() {
    if (_ready) return true;
    try {
      _lib = DynamicLibrary.open('bridge/libx11ime.so');
    } catch (e) {
      debugPrint('[X11Ime] 无法加载 libx11ime.so: $e');
      return false;
    }

    final initFn = _lib!.lookupFunction<_InitNative, _InitDart>('x11_ime_init');
    _ctx = initFn(0); // window=0 uses root window
    if (_ctx == nullptr) {
      debugPrint('[X11Ime] x11_ime_init 失败 (XIM 不可用)');
      return false;
    }
    _ready = true;
    debugPrint('[X11Ime] 初始化完成');
    return true;
  }

  void setFocus(bool focused) {
    if (!_ready) return;
    final fn = _lib!.lookupFunction<_SetFocusNative, _SetFocusDart>(
        'x11_ime_set_focus');
    fn(_ctx!, focused ? 1 : 0);
  }

  String? processKey(
    PhysicalKeyboardKey physicalKey,
    String? character, {
    bool shift = false,
    bool ctrl = false,
    bool alt = false,
  }) {
    if (!_ready) return null;

    final usage = physicalKey.usbHidUsage;
    final keysym = _usbToKeysym[usage];
    if (keysym == null) return null;

    // Get keycode via X11 (need the Display* from ctx)
    // Get Display* from first element of ctx array
    final display = _ctx!.cast<Pointer<Void>>()[0];
    final keySymToKeycode = DynamicLibrary.open('libX11.so.6')
        .lookupFunction<_XKeysymNative, _XKeysymDart>('XKeysymToKeycode');
    final keycode = keySymToKeycode(display, keysym);
    if (keycode == 0) return null;

    int state = 0;
    if (shift) state |= 1;
    if (ctrl) state |= 4;
    if (alt) state |= 8;

    final processFn =
        _lib!.lookupFunction<_ProcessNative, _ProcessDart>('x11_ime_process');

    final outBuf = calloc.allocate<Uint8>(64);
    final len = processFn(_ctx!, state, keycode, outBuf, 63);
    String? result;
    if (len > 0) {
      result = String.fromCharCodes(outBuf.asTypedList(len));
    }
    calloc.free(outBuf);
    return result;
  }

  void dispose() {
    if (_ctx != null && _lib != null) {
      _lib!.lookupFunction<_DestroyNative, _DestroyDart>('x11_ime_destroy')(
          _ctx!);
    }
    _ctx = null;
    _ready = false;
  }
}

typedef _XKeysymNative = Int Function(Pointer<Void>, Int);
typedef _XKeysymDart = int Function(Pointer<Void>, int);
