#!/usr/bin/env python3
"""IME 桥接 v7 —— 全文本同步 + Enter/Esc 信号 + 完全透明窗口

与 v6 的核心区别：
  1. 使用 RGBA visual + 透明背景绘制，窗口完全不可见
  2. stdin 收到 EOF 时自动退出(Flutter 客户端关闭后不再残留)
  3. 窗口移动到屏幕外(-100,-100)作为额外保障

协议(stdout 每行一条消息)：
  READY        —— 桥接启动完成
  T:<text>     —— 当前条目完整文本(每次变更时发送)
  S:           —— 用户按 Enter 提交
  ESC:         —— 用户按 Esc 取消
"""

import sys, os
os.environ['GTK_IM_MODULE'] = 'fcitx'
os.environ['XMODIFIERS'] = '@im=fcitx'

import cairo
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GLib

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

        self.win.add(self.entry)
        self.win.show_all()

        self._last_text = ''

        GLib.io_add_watch(sys.stdin, GLib.IO_IN, self._on_stdin)

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
        if cmd == 'focus':
            # 清空上次残留文本再获取焦点
            self.entry.set_text('')
            self._last_text = ''
            self.win.show()
            self.win.present()
            gdk_win = self.win.get_window()
            if gdk_win:
                gdk_win.raise_()
                gdk_win.focus(Gdk.CURRENT_TIME)
            self.entry.grab_focus_without_selecting()
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
        self.entry.set_text('')
        self._last_text = ''
        self.win.hide()

    def _on_changed(self, entry):
        """文本变更 → 发送完整文本给 Flutter"""
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

    def run(self):
        sys.stdout.write('READY\n')
        sys.stdout.flush()
        Gtk.main()


if __name__ == '__main__':
    PersistentIme().run()
