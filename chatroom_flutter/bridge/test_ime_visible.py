#!/usr/bin/env python3
"""IME 桥接 v3 —— 测试版：100x30 可见窗口，诊断 fcitx XIM 连接"""

import sys, os
os.environ['GTK_IM_MODULE'] = 'fcitx'
os.environ['XMODIFIERS'] = '@im=fcitx'

import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GLib

class TestIme:
    def __init__(self):
        self.win = Gtk.Window(type=Gtk.WindowType.TOPLEVEL)
        self.win.set_default_size(300, 36)
        self.win.set_title('IME Test - 在此输入中文')
        self.win.move(100, 100)

        self.entry = Gtk.Entry()
        self.entry.set_placeholder_text('切换输入法后在此输入中文...')
        self.entry.connect('changed', self._on_changed)

        self.win.add(self.entry)
        self.win.show_all()
        self.entry.grab_focus()

        self._last = ''

        GLib.io_add_watch(sys.stdin, GLib.IO_IN, lambda s, c: Gtk.main_quit())

    def _on_changed(self, entry):
        text = entry.get_text()
        if text == self._last: return
        if text.startswith(self._last) and len(text) > len(self._last):
            added = text[len(self._last):]
        else:
            added = text
        self._last = text
        if added:
            sys.stdout.write('T:' + added + '\n')
            sys.stdout.flush()

    def run(self):
        sys.stdout.write('READY\n')
        sys.stdout.flush()
        Gtk.main()

TestIme().run()
