#!/usr/bin/env python3
"""fcitx IME 桥接 —— 为 Flutter RawTextField 提供系统输入法支持

原理：
  GTK 原生控件 + fcitx 完全兼容。本脚本创建一个透明 GTK 窗口，
  接收焦点后 fcitx 正常工作，文本实时通过 stdout 传回 Flutter。

协议（stdout 每行一条消息）：
  READY        —— 桥接启动完成
  T:<text>     —— 输入框文本变更（实时同步到 Flutter）
  C:<text>     —— 用户按 Enter 提交（Flutter 也应触发 submit）
"""

import sys
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GLib


class ImeBridge:
    def __init__(self):
        self._last_text = ''

        # 透明窗口 —— 接受焦点和 IME 但不显示
        self.win = Gtk.Window(type=Gtk.WindowType.POPUP)
        self.win.set_default_size(1, 1)
        self.win.set_opacity(0.0)
        self.win.set_decorated(False)
        self.win.set_skip_taskbar_hint(True)
        self.win.set_skip_pager_hint(True)
        self.win.set_accept_focus(True)
        self.win.set_keep_above(True)

        self.entry = Gtk.Entry()
        self.entry.set_can_focus(True)
        self.entry.set_has_frame(False)
        self.entry.connect('changed', self._on_changed)
        self.entry.connect('activate', self._on_activate)

        self.win.add(self.entry)
        self.win.show_all()

        GLib.io_add_watch(sys.stdin, GLib.IO_IN, self._on_stdin)

    def _on_stdin(self, source, condition):
        line = source.readline()
        if not line:
            Gtk.main_quit()
            return False
        cmd = line.strip()
        if cmd == 'focus':
            self.entry.grab_focus_without_selecting()
        elif cmd == 'blur':
            self.entry.set_text('')
            self._last_text = ''
        elif cmd == 'quit':
            Gtk.main_quit()
            return False
        return True

    def _on_changed(self, entry):
        text = entry.get_text()
        if text != self._last_text:
            self._last_text = text
            sys.stdout.write('T:' + text + '\n')
            sys.stdout.flush()

    def _on_activate(self, entry):
        text = entry.get_text()
        if text:
            sys.stdout.write('C:' + text + '\n')
            sys.stdout.flush()
            entry.set_text('')
            self._last_text = ''

    def run(self):
        sys.stdout.write('READY\n')
        sys.stdout.flush()
        Gtk.main()


if __name__ == '__main__':
    ImeBridge().run()
