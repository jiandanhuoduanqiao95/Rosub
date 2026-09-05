"""
============================================================
阶段 N —— 日常使用便利性：IME 桥接键盘导航契约测试（N5，规划中，全部红）
============================================================

【目标】
  按《软件开发文档4.1.0.md》§13.9 阶段 N（N5 P2-14 键盘导航体系）编写
  GTK 桥接进程 persistent_ime.py 的契约测试：

    中文输入（showChineseInput）激活时方向键走 GTK 桥接：
    persistent_ime.py 拦截 ↑/↓ 输出 NAV:UP / NAV:DOWN，
    ime_bridge.dart 解析后派发给当前激活输入框执行焦点切换
    （客户端内部管道，不触冻结协议 v1.0.0）。

【契约（实现方需严格遵守，本测试即据此验证）】
  chatroom_flutter/bridge/persistent_ime.py 必须存在，且：
    1. `_on_key` 处理器在按键为 Gdk.KEY_Up 时向 stdout 输出一行
       "NAV:UP"（随后 flush）并返回 True 消费该按键（GTK 条目光标
       不再被 Up 移动，焦点切换由 Flutter 侧执行）
    2. 按键为 Gdk.KEY_Down 时输出 "NAV:DOWN" 并返回 True
    3. 既有 Esc 处理保留：Gdk.KEY_Escape → 输出 "ESC:"（回归锁定）
    4. 既有 Enter 提交保留：_on_activate → 输出 "S:"（回归锁定）
    5. 既有点击/方向键光标位置协议保留：_on_cursor_pos → 输出 "P:<pos>"
       （回归锁定，N5 只拦截 Up/Down，Left/Right 光标移动不受影响）

  说明：persistent_ime.py 依赖 cairo + PyGObject(Gtk)，测试环境无法
  import 实例化，故采用与 test_stage_m_deploy.py 一致的**源码静态契约**
  检查（存在性 + 关键实现形态），防止实现遗漏/回退。

【运行】
  实现前：本文件全部红（脚本未实现 NAV），属 TDD 红。
  实现后：全部通过。

  .venv/bin/python -m pytest tests/test_stage_n_ime.py -v
"""

import os
import sys

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRIDGE_PATH = os.path.join(PROJECT_ROOT, "chatroom_flutter", "bridge",
                           "persistent_ime.py")


def _bridge_source():
    with open(BRIDGE_PATH, "r", encoding="utf-8") as f:
        return f.read()


class TestImeBridgeNavContract:

    def test_bridge_script_exists(self):
        """persistent_ime.py 存在。"""
        assert os.path.exists(BRIDGE_PATH), f"缺少桥接脚本: {BRIDGE_PATH}"

    def test_bridge_intercepts_up_key(self):
        """↑ 键拦截并输出 NAV:UP（N5 键盘导航契约）。"""
        src = _bridge_source()
        assert "Gdk.KEY_Up" in src, "应拦截 Gdk.KEY_Up"
        assert "NAV:UP" in src, "应输出 NAV:UP"

    def test_bridge_intercepts_down_key(self):
        """↓ 键拦截并输出 NAV:DOWN。"""
        src = _bridge_source()
        assert "Gdk.KEY_Down" in src, "应拦截 Gdk.KEY_Down"
        assert "NAV:DOWN" in src, "应输出 NAV:DOWN"

    def test_bridge_nav_outputs_flush_after_write(self):
        """NAV 输出与既有协议一致：写 stdout 后 flush（行缓冲不被吞）。"""
        src = _bridge_source()
        # 契约：NAV 行紧跟 flush（与 T:/P:/S:/ESC: 同款模式）
        assert "stdout.flush()" in src
        assert "sys.stdout.write" in src

    def test_bridge_keeps_escape_signal(self):
        """Esc 处理保留（回归锁定：'ESC:' 不得因新增方向键分支被删）。"""
        src = _bridge_source()
        assert "Gdk.KEY_Escape" in src
        assert "ESC:" in src

    def test_bridge_keeps_submit_signal(self):
        """Enter 提交保留（回归锁定：'S:' 提交信号不得被删）。"""
        src = _bridge_source()
        assert "S:" in src

    def test_bridge_keeps_cursor_position_signal(self):
        """光标位置协议保留（回归锁定：'P:' 输出；N5 只拦截 Up/Down，
        Left/Right 仍经 P: 同步光标位置）。"""
        src = _bridge_source()
        assert "P:" in src


class TestImeBridgeStageNFixes:
    """阶段 N 用户实测缺陷修复契约（2026-08-29，问题 1/2 定位结论锁定）。"""

    def test_move_uses_global_coordinates_directly(self):
        """move: 命令按屏幕全局坐标直接移动窗口。

        旧实现叠加活动窗口原点且依赖 GdkX11.X11Window.property_get
        （该 PyGObject 版本无此方法，每次均抛 AttributeError 被吞）——
        桥接窗口从未移动，候选窗一直停留在屏幕左上角。
        """
        src = _bridge_source()
        assert "self.win.move(int(x), int(y))" in src
        assert "root.property_get" not in src, \
            "不得再依赖不存在的 root.property_get（注释中允许提及）"

    def test_focus_uses_current_event_time(self):
        """focus 命令用当前事件时间戳抢焦点。

        Gdk.CURRENT_TIME(=0) 会被窗口管理器视为过期而拒绝焦点窃取，
        导致按键全部落回 Flutter 窗口（无 IM 上下文）→ 中文输入失灵。
        """
        src = _bridge_source()
        assert "Gtk.get_current_event_time()" in src

    def test_nav_respects_im_filter(self):
        """↑/↓ 先经 IM 上下文过滤：候选窗打开时用于候选选择，不输出 NAV。

        旧实现无条件拦截 ↑/↓——fcitx 候选选择（方向键选词）失效，
        中文输入体验断裂（用户实测反馈"输入法切换失灵"的一部分）。
        """
        src = _bridge_source()
        assert "filter_keypress" in src

    def test_cursor_sync_suppresses_echo(self):
        """cur:/set_text 的程序化光标同步抑制 P: 回显。

        回显的 P: 会触发 Flutter 侧 _onImeCursor 清除正在构建的
        鼠标选区——用户实测"无法用鼠标选择文字"的根因。
        """
        src = _bridge_source()
        assert "_suppress_cursor" in src

    def test_ctrl_v_loads_image_file_path(self):
        """Ctrl+V 剪贴板无图片数据但文本为图片文件路径时读文件直发。

        文件管理器"复制文件"场景剪贴板只有路径文本，旧实现落入默认
        粘贴把路径当文字贴进输入框（用户实测"粘贴 PNG 无反应"）。
        """
        src = _bridge_source()
        assert "wait_for_text" in src
        assert "IMGP:" in src
