#!/usr/bin/env python3
"""IME 桥接 v8 —— 全文本同步 + Enter/Esc 信号 + 键盘导航 + 剪贴板图片 + 完全透明窗口

与 v7 的核心区别（阶段 N5/N3，2026-08-26）：
  1. 拦截 ↑/↓ 方向键输出 NAV:UP / NAV:DOWN（键盘导航体系：Flutter 侧
     收不到方向键，由本进程拦截后经客户端内部管道派发焦点切换）
  2. 新增 clip: 命令：读取 GTK 剪贴板图片，输出 IMG:<base64>（图片粘贴
     直发；无图片输出 IMG: 空行）
  3. 其余协议不变（T:/P:/S:/ESC:）

协议(stdout 每行一条消息)：
  READY        —— 桥接启动完成
  T:<text>     —— 当前条目完整文本(每次变更时发送)
  P:<pos>      —— 光标位置变化(方向键、点击等)
  S:           —— 用户按 Enter 提交
  ESC:         —— 用户按 Esc 取消
  NAV:UP       —— 用户按 ↑（Flutter 侧执行焦点上移）
  NAV:DOWN     —— 用户按 ↓（Flutter 侧执行焦点下移）
  IMG:<base64> —— clip: 命令响应：剪贴板图片 PNG 字节（无图片为空行）
  IMGP:<base64>—— Ctrl+V 拦截：剪贴板含图片时主动推送 PNG 字节
  focus:<b64>@x,y#pos —— 聚焦合并命令：@x,y 为屏幕物理坐标（先移动窗口，
                 候选窗口跟随输入框），#pos 为光标位置（各段可选）。
                 move/cur 不再单独发送——多条紧连 stdin 写入会触发
                 Dart IOSink add+flush 静默丢失（focus 整体丢失，
                 "无法切换中文输入法"根因），每次激活只写一条命令。
  move:x,y     —— 兼容保留（物理屏幕坐标，直接 win.move）
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
        self._suppress_cursor = False
        # stdin 行缓冲（os.read 原始读取）：Python TextIOWrapper.readline
        # 存在读前缓冲——move+focus 等紧连两行落在同一 chunk 时，第二行
        # 被缓冲吞掉且 fd 已读空、GLib 不再触发监听，focus 命令永远不执行
        # （用户实测"无法切换中文输入法"的根因）
        self._stdin_buf = b''

        GLib.io_add_watch(0, GLib.IO_IN, self._on_stdin)

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
        try:
            data = os.read(0, 65536)
        except (BlockingIOError, InterruptedError, OSError):
            return True
        if not data:
            # stdin EOF: Flutter 客户端已关闭 → 释放焦点并退出
            self._release_focus()
            while Gtk.events_pending():
                Gtk.main_iteration()
            Gtk.main_quit()
            return False
        self._stdin_buf += data
        while b'\n' in self._stdin_buf:
            line, self._stdin_buf = self._stdin_buf.split(b'\n', 1)
            self._handle_command(
                line.decode('utf-8', errors='replace').strip())
        return True

    def _handle_command(self, cmd):
        if not cmd:
            return
        if cmd == 'focus' or cmd.startswith('focus:'):
            # 合并协议（Dart IOSink 静默丢失规避）：focus:<b64>@x,y#pos
            # —— @x,y 为屏幕物理坐标（先移动窗口，候选窗跟随输入框），
            # #pos 为光标位置。各段可选。
            payload = cmd[len('focus:'):] if cmd.startswith('focus:') else ''
            cursor_part = None
            if '#' in payload:
                payload, cursor_part = payload.split('#', 1)
            move_part = None
            if '@' in payload:
                payload, move_part = payload.split('@', 1)
            if move_part:
                try:
                    x, y = move_part.split(',', 1)
                    self._move_near_active_window(int(x), int(y))
                except Exception:
                    pass
            # 同步 Flutter 侧已有文本后获取焦点，避免重新聚焦后丢失草稿。
            self._sync_text(self._decode_payload('focus:' + payload, 'focus:'))
            if cursor_part is not None:
                try:
                    self._suppress_cursor = True
                    self.entry.set_position(int(cursor_part))
                except Exception:
                    pass
                finally:
                    self._suppress_cursor = False
            self.win.show()
            # 用当前事件时间戳请求激活：Gdk.CURRENT_TIME(=0) 会被窗口
            # 管理器视为过期时间戳而拒绝焦点窃取（用户点击 Flutter 输入框
            # 后桥接抢焦失败 → 按键全部落回 Flutter → 中文输入失灵）
            present_time = Gtk.get_current_event_time()
            if present_time > 0:
                self.win.present_with_time(present_time)
            else:
                self.win.present()
            gdk_win = self.win.get_window()
            if gdk_win:
                gdk_win.raise_()
                if present_time > 0:
                    gdk_win.focus(present_time)
                else:
                    gdk_win.focus(Gdk.CURRENT_TIME)
            self.entry.grab_focus_without_selecting()
        elif cmd == 'clear':
            self._sync_text('')
        elif cmd.startswith('set:'):
            self._sync_text(self._decode_payload(cmd, 'set:'))
        elif cmd == 'blur':
            self._release_focus()
        elif cmd == 'clip':
            self._emit_clipboard_image()
        elif cmd.startswith('move:'):
            try:
                x, y = cmd[5:].split(',', 1)
                self._move_near_active_window(int(x), int(y))
            except Exception:
                pass
        elif cmd.startswith('cur:'):
            try:
                self._suppress_cursor = True
                self.entry.set_position(int(cmd[4:]))
            except Exception:
                pass
            finally:
                self._suppress_cursor = False
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
        # 同步文本时抑制光标回显：Flutter 侧已按同步文本自置光标，
        # 多余的 P: 会触发 _onImeCursor 清掉正在构建的鼠标选区
        self._suppress_cursor = True
        self.entry.set_text(text)
        self.entry.set_position(len(text))
        self._suppress_cursor = False
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
        """键盘拦截：Esc 取消；↑/↓ 输出导航信号（键盘导航体系 N5）；
        Ctrl+V 时剪贴板有图片则输出 IMGP:（图片粘贴直发优先）。"""
        if event.keyval == Gdk.KEY_Escape:
            sys.stdout.write('ESC:\n')
            sys.stdout.flush()
            return True
        # 阶段 N3 补充（用户反馈）：文件管理器复制图片文件时剪贴板含
        # 路径文本——若剪贴板有图片数据则优先输出图片，不粘贴路径文本
        if event.keyval == Gdk.KEY_v and event.state & Gdk.ModifierType.CONTROL_MASK:
            try:
                clipboard = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
                pixbuf = clipboard.wait_for_image()
                if pixbuf is not None:
                    png_bytes = pixbuf.save_to_bufferv('png', [], [])[1]
                    sys.stdout.write('IMGP:' + base64.b64encode(png_bytes).decode('ascii') + '\n')
                    sys.stdout.flush()
                    return True
                # 无图片数据：剪贴板文本若是图片文件路径（文件管理器
                # "复制文件"），读文件字节直发（Dart 侧 isSupportedImage
                # 校验），不把路径当文字粘贴进输入框
                text = clipboard.wait_for_text()
                if text is not None:
                    path = text.strip().splitlines()[0].strip()
                    if path.startswith('file://'):
                        path = path[7:]
                    if path.lower().endswith(('.png', '.jpg', '.jpeg', '.gif')):
                        try:
                            with open(path, 'rb') as f:
                                data = f.read()
                            sys.stdout.write('IMGP:' + base64.b64encode(data).decode('ascii') + '\n')
                            sys.stdout.flush()
                            return True
                        except Exception:
                            pass
            except Exception:
                pass
        if event.keyval in (Gdk.KEY_Up, Gdk.KEY_Down):
            # 先交给 IM 上下文过滤：输入法候选窗打开时 ↑/↓ 用于候选选择，
            # 由 fcitx 消费（返回 True → 不再输出导航信号，候选选择不失效）；
            # 输入法未消费（无候选/输入法未激活）→ 输出 NAV 执行焦点切换。
            try:
                if self.entry.im_context.filter_keypress(event):
                    return True
            except Exception:
                pass
            sys.stdout.write('NAV:UP\n' if event.keyval == Gdk.KEY_Up
                             else 'NAV:DOWN\n')
            sys.stdout.flush()
            return True
        return False

    def _move_near_active_window(self, x, y):
        """把桥接窗口移到屏幕全局坐标 (x, y)。

        阶段 N 修订（用户实测修复）：Flutter 侧经 localToGlobal 发送的
        x/y 已是**屏幕全局坐标**，直接 move 即可。原实现按"窗口内坐标"
        处理并叠加活动窗口原点，且 GdkX11.X11Window 无 property_get
        方法（每次均抛 AttributeError 被静默吞掉）——桥接窗口从未移动过，
        fcitx 候选窗口一直停留在屏幕左上角。
        """
        try:
            self.win.move(int(x), int(y))
        except Exception:
            pass

    def _emit_clipboard_image(self):
        """读取剪贴板图片并输出 IMG:<base64>（无图片输出 IMG: 空行）。

        阶段 N3（P2-4 图片粘贴直发）：GTK 剪贴板 wait_for_image 拿
        GdkPixbuf → 编码为 PNG 字节 → base64 输出；读取失败/无图片
        输出空响应，Flutter 侧回退为无操作。
        """
        try:
            clipboard = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
            pixbuf = clipboard.wait_for_image()
            if pixbuf is not None:
                png_bytes = pixbuf.save_to_bufferv('png', [], [])[1]
                sys.stdout.write('IMG:' + base64.b64encode(png_bytes).decode('ascii') + '\n')
                sys.stdout.flush()
                return
        except Exception:
            pass
        sys.stdout.write('IMG:\n')
        sys.stdout.flush()

    def _on_cursor_pos(self, entry, param):
        """光标位置变化 → 发送位置给 Flutter（方向键、点击等）"""
        if self._suppress_changed or self._suppress_cursor:
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
