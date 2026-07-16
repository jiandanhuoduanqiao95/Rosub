#!/usr/bin/env python3
"""IME 桥接 v7 —— 全文本同步 + Enter/Esc 信号 + 完全透明窗口

与 v6 的核心区别：
  1. 使用 RGBA visual + 透明背景绘制，窗口完全不可见
  2. stdin 收到 EOF 时自动退出(Flutter 客户端关闭后不再残留)
  3. 窗口移动到屏幕外(-100,-100)作为额外保障

协议(stdout 每行一条消息)：
  READY        —— 桥接启动完成
  T:<text>     —— 当前条目完整文本(每次变更时发送)
  P:<pos>      —— 光标位置变化(方向键、点击等)
  S:           —— 用户按 Enter 提交
  ESC:         —— 用户按 Esc 取消
"""

import base64
import ctypes
import os
import signal
import sys
os.environ['GTK_IM_MODULE'] = 'fcitx'
os.environ['XMODIFIERS'] = '@im=fcitx'

import cairo
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GLib


def _enable_parent_death_signal():
    """让 OS 在父进程退出时自动向本进程发 SIGKILL。

    Flutter 桌面端关闭窗口时进程直接被 OS 终止，detached 回调不可靠，
    shutdown() 可能来不及执行。prctl 确保桥接进程不会成为孤儿残留。
    """
    try:
        libc = ctypes.CDLL('libc.so.6', use_errno=True)
        PR_SET_PDEATHSIG = 1
        SIGKILL = 9
        libc.prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0)
    except Exception:
        pass

CSS = b'''
window, entry {
  background: transparent;
  color: transparent;
  caret-color: transparent;
  border: none;
  box-shadow: none;
}
'''

class PersistentIme:
    def __init__(self):
        # 父进程退出时自动被 SIGKILL，避免成为孤儿进程残留烧 CPU
        _enable_parent_death_signal()

        self.win = Gtk.Window(type=Gtk.WindowType.TOPLEVEL)
        self.win.set_default_size(200, 20)
        self.win.set_decorated(False)
        self.win.set_skip_taskbar_hint(True)
        self.win.set_skip_pager_hint(True)
        self.win.set_accept_focus(True)
        self.win.set_focus_on_map(True)
        self.win.set_keep_above(True)
        # 移到屏幕外，作为视觉不可见的额外保障
        self.win.move(-100, -100)
        self.win.set_title('ime-bridge')

        # 使用 RGBA visual 实现真正的窗口透明
        screen = self.win.get_screen()
        visual = screen.get_rgba_visual()
        if visual:
            self.win.set_visual(visual)
        self.win.set_app_paintable(True)
        self.win.connect('draw', self._on_window_draw)

        sp = Gtk.CssProvider()
        sp.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(
            screen, sp, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        self.entry = Gtk.Entry()
        self.entry.set_can_focus(True)
        self.entry.set_has_frame(False)
        self.entry.set_width_chars(1)
        self.entry.connect('changed', self._on_changed)
        self.entry.connect('activate', self._on_activate)
        self.entry.connect('key-press-event', self._on_key)
        self.entry.connect('notify::cursor-position', self._on_cursor_pos)

        self.win.add(self.entry)
        self.win.show_all()

        self._last_text = ''
        self._suppress_changed = False

        GLib.io_add_watch(sys.stdin, GLib.IO_IN, self._on_stdin)

        # SIGTERM 兜底：Flutter 退出时可能直接发 SIGTERM，确保释放 X11 焦点后退出
        signal.signal(signal.SIGTERM, self._on_sigterm)

    def _on_sigterm(self, signum, frame):
        self._release_focus()
        while Gtk.events_pending():
            Gtk.main_iteration()
        Gtk.main_quit()

    def _on_window_draw(self, widget, cr):
        """绘制完全透明的窗口背景，防止默认黑色背景出现"""
        cr.set_source_rgba(0, 0, 0, 0)
        cr.set_operator(cairo.Operator.SOURCE)
        cr.paint()
        cr.set_operator(cairo.Operator.OVER)
        return False  # 继续传播给子控件

    def _on_stdin(self, source, condition):
        line = source.readline()
        if not line:
            # stdin EOF: Flutter 客户端已关闭 → 释放焦点并退出
            self._release_focus()
            while Gtk.events_pending():
                Gtk.main_iteration()
            Gtk.main_quit()
            return False
        cmd = line.strip()
        if cmd == 'focus' or cmd.startswith('focus:'):
            # 同步 Flutter 侧已有文本后获取焦点，避免重新聚焦后丢失草稿。
            self._sync_text(self._decode_payload(cmd, 'focus:'))
            self.win.show()
            self.win.present()
            gdk_win = self.win.get_window()
            if gdk_win:
                gdk_win.raise_()
                gdk_win.focus(Gdk.CURRENT_TIME)
            self.entry.grab_focus_without_selecting()
        elif cmd == 'clear':
            self._sync_text('')
        elif cmd.startswith('set:'):
            self._sync_text(self._decode_payload(cmd, 'set:'))
        elif cmd == 'blur':
            self._release_focus()
        elif cmd == 'quit':
            self._release_focus()
            # 处理待处理 GTK 事件，确保 X11 焦点已释放
            while Gtk.events_pending():
                Gtk.main_iteration()
            Gtk.main_quit()
            return False
        return True

    def _release_focus(self):
        """释放 X11 键盘焦点，避免残留焦点阻塞其他窗口输入"""
        self._sync_text('')
        self.win.hide()

    def _decode_payload(self, cmd, prefix):
        if not cmd.startswith(prefix):
            return ''
        payload = cmd[len(prefix):]
        if not payload:
            return ''
        try:
            return base64.b64decode(payload.encode('ascii')).decode('utf-8')
        except Exception:
            return ''

    def _sync_text(self, text):
        self._suppress_changed = True
        self.entry.set_text(text)
        self.entry.set_position(len(text))
        self._last_text = text
        self._suppress_changed = False

    def _on_changed(self, entry):
        """文本变更 → 发送完整文本给 Flutter"""
        if self._suppress_changed:
            return
        text = entry.get_text()
        if text == self._last_text:
            return
        self._last_text = text
        sys.stdout.write('T:' + text + '\n')
        sys.stdout.flush()

    def _on_activate(self, entry):
        """Enter 键 → 发送提交信号"""
        sys.stdout.write('S:\n')
        sys.stdout.flush()

    def _on_key(self, widget, event):
        """Esc 键 → 发送取消信号"""
        if event.keyval == Gdk.KEY_Escape:
            sys.stdout.write('ESC:\n')
            sys.stdout.flush()
            return True
        return False

    def _on_cursor_pos(self, entry, param):
        """光标位置变化 → 发送位置给 Flutter（方向键、点击等）"""
        if self._suppress_changed:
            return
        pos = entry.get_position()
        sys.stdout.write(f'P:{pos}\n')
        sys.stdout.flush()

    def run(self):
        sys.stdout.write('READY\n')
        sys.stdout.flush()
        Gtk.main()


if __name__ == '__main__':
    PersistentIme().run()
