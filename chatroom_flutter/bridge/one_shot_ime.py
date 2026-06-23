#!/usr/bin/env python3
"""一行式 IME 输入窗 —— 贴在屏幕底部的窄条，输入中文后 Enter 提交"""

import sys
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk


class OneShotIME(Gtk.Window):
    def __init__(self):
        Gtk.Window.__init__(self, type=Gtk.WindowType.POPUP)
        self.set_default_size(500, 36)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_keep_above(True)
        self.set_decorated(False)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)

        # 半透明深色背景
        self.override_background_color(
            Gtk.StateFlags.NORMAL, Gdk.RGBA(0.1, 0.1, 0.1, 0.85))

        self.entry = Gtk.Entry()
        self.entry.set_placeholder_text('输入中文，Enter 提交 · Esc 取消')
        self.entry.set_has_frame(False)
        self.entry.set_name('ime-entry')
        self.entry.connect('activate', self._commit)
        self.entry.connect('key-press-event', self._on_key)

        css = b'#ime-entry { font-size: 16px; color: #fff; background: transparent; padding: 6px 12px; }'
        style_provider = Gtk.CssProvider()
        style_provider.load_from_data(css)
        self.entry.get_style_context().add_provider(
            style_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        self.add(self.entry)
        self.show_all()
        self.entry.grab_focus_without_selecting()

        # 移到屏幕底部中央
        screen = self.get_screen()
        monitor = screen.get_primary_monitor()
        geo = screen.get_monitor_geometry(monitor)
        self.move(geo.x + (geo.width - 500) // 2, geo.y + geo.height - 80)

    def _on_key(self, widget, event):
        if event.keyval == Gdk.KEY_Escape:
            self._cancel()
            return True
        return False

    def _commit(self, entry):
        text = entry.get_text()
        if text:
            clipboard = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
            clipboard.set_text(text, -1)
            sys.stdout.write(text + '\n')
            sys.stdout.flush()
        else:
            sys.stdout.write('\n')
            sys.stdout.flush()
        Gtk.main_quit()

    def _cancel(self):
        sys.stdout.write('\n')
        sys.stdout.flush()
        Gtk.main_quit()


OneShotIME()
Gtk.main()
