"""
============================================================
阶段 G —— 安全加固 + 文件改进：服务端协议层 TDD 测试（G1 / G3 / G4 / G6）
============================================================

【目标】
  测试阶段 G 的服务端行为，先写测试（红），等待实现（绿）：
    G1  重复登录踢出             （server_client_handler.py）
    G3  change_password 协议      （server_message_handler.py）
    G4  文件大小限制              （config.py / config.yaml + server_message_handler.py）
    G6  登录速率限制              （server_client_handler.py）

【契约（实现方需严格遵守，本测试即据此验证）】
----- G1 重复登录踢出 -----
  同一用户名已在线时再次登录成功：
    - 服务端向旧 socket 发送 type=error, content="已在其他地方登录，您已被强制下线"
    - 随后关闭旧 socket，旧线程退出
    - 旧线程 finally 清理必须按 socket 对象身份弹出 client_map，
      不得移除新会话的映射（否则新会话收不到任何消息）
    - 新登录正常继续（client_map 指向新 socket，消息可送达）
  登录失败（密码错误等）不触发踢出。

----- G3 change_password -----
  C → S:
    type         = "change_password"
    old_password = <当前密码>
    new_password = <新密码>
  S → C 成功：
    type = "chat", content = "密码修改成功"
  S → C 失败：
    - new_password 未通过 validate_password（6-128 位、无控制字符）→ error（验证文案）
    - old_password 与存储哈希不匹配 → error 含 "原密码"
  服务端流程：validate_password(new_password) → db.get_user(username) 取存储哈希
    → bcrypt.checkpw(old_password, stored_hash)
    → bcrypt.hashpw(new_password) → db.update_password(username, stored_hash, new_hash)
  成功后：当前会话保持登录、旧密码失效、新密码可登录。

----- G4 文件大小限制 -----
  配置：config.yaml 新增 file.max_file_size（字节），默认 5368709120（5GB）；
        config.py _DEFAULTS 同步补充。
  服务端 file 处理器：
    effective_size = int(header.get("filesize", len(data)))
    effective_size > 限制 → error 含 "过大"，不保存文件请求；
    私聊与群组文件一视同仁；effective_size == 上限 → 允许。

----- G6 登录速率限制 -----
  按用户名计数连续登录失败（密码错误 / 用户不存在计入；格式非法不计入）：
    - 连续 5 次失败 → 锁定该用户名 300 秒（自第一次失败起算）
    - 锁定期内任何登录尝试（即使密码正确）→ error 含 "尝试次数过多"
    - 成功登录清零计数
    - 各用户名计数相互独立
  时间源：实现必须通过 time.time()（模块内 import time 后调用）获取当前时间，
  测试用 monkeypatch 注入假时钟推进验证 5 分钟解锁。

【运行】
  实现前：测试断言会失败或报 AttributeError，属 TDD 红。
  实现后：全部通过。

  .venv/bin/python -m pytest tests/test_stage_g_server.py -v
"""

import os
import sys
import time
import copy
import socket
import threading
import pytest
import bcrypt

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from protocol import recv_message


# ============================================================
# 共享工具：注入文件大小限制配置 / 假时钟
# ============================================================

def _set_max_file_size(monkeypatch, size):
    """把 config._data 替换为包含指定 file.max_file_size 的副本。

    无论 config.yaml 是否已含该键均可生效，测试结束后由 monkeypatch 还原。
    """
    from config import config
    data = copy.deepcopy(config._data) if isinstance(config._data, dict) else {}
    data.setdefault("file", {})["max_file_size"] = size
    monkeypatch.setattr(config, "_data", data)


def _set_large_file_threshold(monkeypatch, size):
    """注入 file.large_file_threshold（大文件直传阈值），测试结束后还原。"""
    from config import config
    data = copy.deepcopy(config._data) if isinstance(config._data, dict) else {}
    data.setdefault("file", {})["large_file_threshold"] = size
    monkeypatch.setattr(config, "_data", data)


class _FakeClock:
    """可推进的假时钟，用于验证 5 分钟锁定过期。"""

    def __init__(self):
        self._now = 1000000.0

    def time(self):
        return self._now

    def advance(self, seconds):
        self._now += seconds


def _failed_login(harness, username, password="wrongpass"):
    """发起一次必然失败的登录，返回 (header, data)，并关闭连接。"""
    c = harness.client()
    c.login(username, password, consume=False)
    h, d = c.expect("error", timeout=3)
    c.close()
    return h, d


# ============================================================
# G1 —— 重复登录踢出
# ============================================================

class TestDuplicateLoginKick:

    def test_second_login_kicks_first_session(self, harness):
        """G1 正向：第二次登录成功 → 旧会话收到强制下线通知，连接被关闭。"""
        c1 = harness.client()
        c1.login("alice", "password123", consume=False)
        c1.recv_initial()

        c2 = harness.client()
        c2.login("alice", "password123", consume=False)
        c2.recv_initial()

        # 旧会话应收到"已在其他地方登录"通知
        h, d = c1.expect("error", timeout=3)
        assert h is not None
        assert "已在其他地方登录" in d.decode(), f"实际内容: {d.decode()}"

        # 随后旧连接被服务端关闭
        h2, d2 = c1.recv(timeout=2)
        assert h2 is None, f"旧连接应被关闭，实际仍收到: {h2} {d2}"

    def test_new_session_mapping_survives_old_thread_cleanup(self, harness):
        """G1 关键不变式：旧线程退出清理不得移除新会话的 client_map 条目。"""
        c1 = harness.client()
        c1.login("alice", "password123", consume=False)
        c1.recv_initial()

        c2 = harness.client()
        c2.login("alice", "password123", consume=False)
        c2.recv_initial()

        # 旧会话被踢：消费通知并等待其线程完成清理
        h, d = c1.expect("error", timeout=3)
        assert "已在其他地方登录" in d.decode()
        h2, d2 = c1.recv(timeout=2)
        assert h2 is None
        time.sleep(0.3)

        # bob 给 alice 发消息 → 必须到达新会话 c2
        bob = harness.client()
        bob.login("bob", "password456", consume=False)
        bob.recv_initial()
        bob.send("chat", "hi alice", to="alice")

        h3, d3 = c2.expect("chat", timeout=3)
        assert h3.get("from") == "bob"
        assert d3.decode() == "hi alice"

    def test_no_kick_when_previous_session_already_closed(self, harness):
        """G1 无旧会话时登录不产生踢出通知。"""
        c1 = harness.client()
        c1.login("alice", "password123", consume=False)
        c1.recv_initial()
        c1.close()
        time.sleep(0.3)  # 等旧线程退出清理 client_map

        c2 = harness.client()
        initial = c2.login("alice", "password123")
        assert initial["login_response"][0]["type"] in ("chat", "admin_auth")
        # 初始数据中不应混入强制下线通知
        for h, d in initial["extra"]:
            text = d.decode() if d else ""
            assert "已在其他地方登录" not in text, f"不应收到踢出通知: {h} {text}"

    def test_failed_second_login_does_not_kick_first(self, harness):
        """G1 登录失败不触发踢出，旧会话保持可用。"""
        c1 = harness.client()
        c1.login("alice", "password123", consume=False)
        c1.recv_initial()

        c2 = harness.client()
        c2.login("alice", "wrongpass", consume=False)
        h, d = c2.expect("error", timeout=3)
        assert "密码错误" in d.decode()

        # 旧会话仍然在线：ping → pong
        c1.send("ping", "")
        h, d = c1.expect("pong", timeout=3)
        assert h["type"] == "pong"


# ============================================================
# G3 —— change_password 服务端处理
# ============================================================

class TestChangePasswordHandler:

    def _login_alice(self, harness):
        c = harness.client()
        c.login("alice", "password123", consume=False)
        c.recv_initial()
        return c

    def test_change_password_success_then_new_password_login(self, harness):
        """G3 正向：改密成功 → 旧密码失效、新密码可登录。"""
        alice = self._login_alice(harness)
        alice.send("change_password", "",
                   old_password="password123", new_password="newpass456")

        h, d = alice.expect("chat", timeout=3)
        assert "密码修改成功" in d.decode()

        # 旧密码登录失败
        c_old = harness.client()
        c_old.login("alice", "password123", consume=False)
        h, d = c_old.expect("error", timeout=3)
        assert "密码错误" in d.decode()

        # 新密码登录成功
        c_new = harness.client()
        initial = c_new.login("alice", "newpass456")
        assert initial["login_response"][0]["type"] in ("chat", "admin_auth")

    def test_change_password_wrong_old_password_rejected(self, harness):
        """G3 旧密码错误 → error 提示原密码不正确，密码不变。"""
        alice = self._login_alice(harness)
        alice.send("change_password", "",
                   old_password="wrongold1", new_password="newpass456")
        h, d = alice.expect("error", timeout=3)
        assert "原密码" in d.decode()

        # 存储哈希未被修改：旧密码仍可登录
        stored_hash, _ = harness.db.get_user("alice")
        assert bcrypt.checkpw("password123".encode(), stored_hash) is True

    @pytest.mark.parametrize("new_pw", ["123", "abc\tdef", "x" * 129])
    def test_change_password_invalid_new_password_rejected(self, harness, new_pw):
        """G3 新密码格式非法（过短/控制字符/过长）→ error 验证文案。"""
        alice = self._login_alice(harness)
        alice.send("change_password", "",
                   old_password="password123", new_password=new_pw)
        h, d = alice.expect("error", timeout=3)
        assert "密码" in d.decode(), f"应返回密码验证错误: {d.decode()}"

    def test_change_password_updates_stored_hash(self, harness):
        """G3 DB 层面：改密后存储哈希对应新密码。"""
        alice = self._login_alice(harness)
        alice.send("change_password", "",
                   old_password="password123", new_password="newpass456")
        h, d = alice.expect("chat", timeout=3)
        assert "密码修改成功" in d.decode()

        stored_hash, _ = harness.db.get_user("alice")
        assert bcrypt.checkpw("newpass456".encode(), stored_hash) is True
        assert bcrypt.checkpw("password123".encode(), stored_hash) is False

    def test_change_password_session_remains_active(self, harness):
        """G3 改密成功后当前会话保持登录，可继续聊天。"""
        alice = self._login_alice(harness)
        alice.send("change_password", "",
                   old_password="password123", new_password="newpass456")
        h, d = alice.expect("chat", timeout=3)
        assert "密码修改成功" in d.decode()

        bob = harness.client()
        bob.login("bob", "password456", consume=False)
        bob.recv_initial()
        alice.send("chat", "still alive", to="bob")
        h, d = bob.expect("chat", timeout=3)
        assert h.get("from") == "alice"
        assert d.decode() == "still alive"

    def test_change_password_missing_headers_rejected(self, harness):
        """G3 缺少密码头 → 返回错误而非崩溃。"""
        alice = self._login_alice(harness)
        alice.send("change_password", "")
        h, d = alice.expect("error", timeout=3)
        assert "密码" in d.decode()

        # 会话仍然可用
        alice.send("ping", "")
        h, d = alice.expect("pong", timeout=3)
        assert h["type"] == "pong"


# ============================================================
# G4 —— 文件大小限制
# ============================================================

class TestMaxFileSize:

    def test_config_default_max_file_size(self):
        """G4 配置默认值：file.max_file_size == 5GB（字节）。"""
        from config import config
        assert config.get("file.max_file_size") == 5368709120

    def test_config_max_file_size_overridable(self, monkeypatch):
        """G4 配置可覆盖：注入后 config.get 返回新值。"""
        from config import config
        _set_max_file_size(monkeypatch, 1024)
        assert config.get("file.max_file_size") == 1024

    def test_private_file_over_limit_rejected(self, harness, monkeypatch):
        """G4 私聊文件超限 → error 含"过大"，不保存文件请求。"""
        _set_max_file_size(monkeypatch, 1024)
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        alice.send("file", b"x" * 2048, to="bob", filename="big.bin",
                   filesize="2048", message_id="g4-big-1")
        h, d = alice.expect("error", timeout=3)
        assert "过大" in d.decode(), f"应提示文件过大: {d.decode()}"
        assert harness.db.get_file_request("g4-big-1") is None

    def test_private_file_at_limit_accepted(self, harness, monkeypatch):
        """G4 边界：filesize == 上限 → 允许，接收方收到文件请求。"""
        _set_max_file_size(monkeypatch, 1024)
        bob = harness.client()
        bob.login("bob", "password456", consume=False)
        bob.recv_initial()
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        alice.send("file", b"x" * 1024, to="bob", filename="ok.bin",
                   filesize="1024", message_id="g4-ok-1")
        h, d = bob.expect("file_request", timeout=3)
        assert h.get("from") == "alice"
        assert harness.db.get_file_request("g4-ok-1") is not None

    def test_private_file_under_limit_accepted(self, harness, monkeypatch):
        """G4 正常小文件不受影响。"""
        _set_max_file_size(monkeypatch, 1024)
        bob = harness.client()
        bob.login("bob", "password456", consume=False)
        bob.recv_initial()
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        alice.send("file", b"hello", to="bob", filename="small.txt",
                   filesize="5", message_id="g4-small-1")
        h, d = bob.expect("file_request", timeout=3)
        assert h.get("filename") == "small.txt"

    def test_group_file_over_limit_rejected(self, harness, monkeypatch):
        """G4 群组文件同样受限。"""
        _set_max_file_size(monkeypatch, 1024)
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("create_group", "filedemo")
        alice.drain(timeout=0.8)
        gid = harness.db.get_user_groups("alice")[0][0]

        alice.send("file", b"x" * 2048, to=f"group_{gid}", filename="huge.bin",
                   filesize="2048", message_id="g4-group-big-1")
        h, d = alice.expect("error", timeout=3)
        assert "过大" in d.decode(), f"应提示文件过大: {d.decode()}"
        assert harness.db.get_group_file_request("g4-group-big-1") is None

    def test_missing_filesize_header_uses_body_length(self, harness, monkeypatch):
        """G4 无 filesize 头时以消息体实际长度判定。"""
        _set_max_file_size(monkeypatch, 1024)
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        alice.send("file", b"x" * 2048, to="bob", filename="nolen.bin",
                   message_id="g4-nolen-1")
        h, d = alice.expect("error", timeout=3)
        assert "过大" in d.decode(), f"应按下限拒绝: {d.decode()}"


# ============================================================
# G4 附加 —— 大文件流式落盘 + 磁盘存储（阶段 G 修复）
# ============================================================

class TestLargeFileDiskStorage:

    def test_file_body_lands_on_disk_not_sqlite(self, harness, monkeypatch):
        """大文件消息体应落盘（file_path 非空），SQLite content 为空占位。"""
        _set_max_file_size(monkeypatch, 8 * 1024 * 1024)
        bob = harness.client()
        bob.login("bob", "password456", consume=False)
        bob.recv_initial()
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        payload = os.urandom(3 * 1024 * 1024)  # 3MB，超过 SQLite BLOB 上限的测试不现实，验证落盘路径
        alice.send("file", payload, to="bob", filename="big.bin",
                   filesize=str(len(payload)), message_id="g4-disk-1")
        h, d = bob.expect("file_request", timeout=5)
        assert h.get("from") == "alice"
        assert h.get("filesize") == str(len(payload))

        # DB 行存在且 file_path 指向磁盘文件，content 为空占位
        row = harness.db.get_file_request("g4-disk-1")
        assert row is not None
        sender, receiver, filename, filesize, content, file_path, status = row
        assert filename == "big.bin"
        assert file_path and os.path.exists(file_path), "文件应落盘"
        assert os.path.getsize(file_path) == len(payload)
        assert content == b""
        assert status == "pending"
        assert file_path.startswith(os.path.join("files", "file_store")) or "file_store" in file_path

        # 接受后：接收方收到完整内容，文件转入历史区（offline/history 引用同一路径）
        bob.send("file_response", "", response="accept",
                 message_id="g4-disk-1", to="alice")
        h, d = bob.expect("file", timeout=5)
        assert h.get("from") == "alice"
        assert d == payload, "接收到的文件内容应完整一致"
        deadline = time.time() + 3
        while time.time() < deadline and harness.db.get_file_request("g4-disk-1") is not None:
            time.sleep(0.05)
        assert harness.db.get_file_request("g4-disk-1") is None
        # 历史区文件保留（offline + history 引用）
        offline = harness.db.get_offline_messages("bob")
        file_msgs = [m for m in offline if m[4] == "g4-disk-1"]
        assert file_msgs, "离线消息应保留文件记录"
        assert file_msgs[0][8] and os.path.exists(file_msgs[0][8]), "历史文件应存在"

    def test_reject_cleans_disk_file(self, harness, monkeypatch):
        """拒绝文件请求后，待处理磁盘文件一并清理。"""
        _set_max_file_size(monkeypatch, 8 * 1024 * 1024)
        bob = harness.client()
        bob.login("bob", "password456", consume=False)
        bob.recv_initial()
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        payload = b"y" * 100000
        alice.send("file", payload, to="bob", filename="rej.bin",
                   filesize=str(len(payload)), message_id="g4-rej-1")
        h, d = bob.expect("file_request", timeout=5)

        row = harness.db.get_file_request("g4-rej-1")
        file_path = row[5]
        assert os.path.exists(file_path)

        bob.send("file_response", "", response="reject",
                 message_id="g4-rej-1", to="alice")
        deadline = time.time() + 3
        while time.time() < deadline and harness.db.get_file_request("g4-rej-1") is not None:
            time.sleep(0.05)
        assert harness.db.get_file_request("g4-rej-1") is None
        assert not os.path.exists(file_path), "拒绝后磁盘文件应被清理"

    def test_offline_file_redelivery_streams_from_disk(self, harness, monkeypatch):
        """接收方离线时接受文件 → 登录后文件从磁盘流式补发。"""
        _set_max_file_size(monkeypatch, 8 * 1024 * 1024)
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        payload = b"z" * 200000
        alice.send("file", payload, to="bob", filename="off.bin",
                   filesize=str(len(payload)), message_id="g4-off-1")
        h, d = alice.expect("chat", timeout=5)  # bob 离线 → "文件请求已保存"
        assert "已保存" in d.decode()

        # bob 登录收到 file_request 并接受
        bob = harness.client()
        bob.login("bob", "password456", consume=False)
        initial = bob.recv_initial()
        assert any(h2.get("type") == "file_request" and h2.get("message_id") == "g4-off-1"
                   for h2, _ in initial["file_requests"]), "bob 应收到离线文件请求"
        bob.send("file_response", "", response="accept",
                 message_id="g4-off-1", to="alice")
        h, d = bob.expect("file", timeout=5)
        assert d == payload, "bob 接受后应收到完整文件内容"
        deadline = time.time() + 3
        while time.time() < deadline and harness.db.get_file_request("g4-off-1") is not None:
            time.sleep(0.05)
        assert harness.db.get_file_request("g4-off-1") is None

        # 重启会话：bob 重新登录，离线 file 消息（history=true）流式补发
        bob.close()
        time.sleep(0.3)
        bob2 = harness.client()
        bob2.login("bob", "password456", consume=False)
        initial2 = bob2.recv_initial()
        file_msgs = [h for h, d2 in initial2["offline"]
                     if h.get("type") == "file" and h.get("message_id") == "g4-off-1"]
        assert file_msgs, "重新登录应收到离线文件消息"
        # 内容通过与 payload 相同的 file 消息体到达（recv_initial 未消费时按顺序读取）
        for h, d2 in initial2["offline"]:
            if h.get("type") == "file" and h.get("message_id") == "g4-off-1":
                assert d2 == payload, "离线补发的文件内容应完整"
                break


# ============================================================
# G6 —— 登录速率限制
# ============================================================

class TestLoginRateLimit:

    def test_lockout_blocks_and_expires_after_300_seconds(self, harness, monkeypatch):
        """G6 核心：5 次失败锁定 → 正确密码也被拒 → 5 分钟后解锁。"""
        clock = _FakeClock()
        monkeypatch.setattr(time, "time", clock.time)

        # 连续 5 次密码错误
        for _ in range(5):
            h, d = _failed_login(harness, "alice")
            assert "密码错误" in d.decode()

        # 第 6 次：即使密码正确也被锁定拒绝
        c = harness.client()
        c.login("alice", "password123", consume=False)
        h, d = c.expect("error", timeout=3)
        assert "尝试次数过多" in d.decode(), f"锁定期间应拒绝: {d.decode()}"
        c.close()

        # 5 分钟（300 秒）后解锁
        clock.advance(301)
        c2 = harness.client()
        initial = c2.login("alice", "password123")
        assert initial["login_response"][0]["type"] in ("chat", "admin_auth")

    def test_successful_login_resets_failure_count(self, harness, monkeypatch):
        """G6 成功登录清零失败计数。"""
        clock = _FakeClock()
        monkeypatch.setattr(time, "time", clock.time)

        for _ in range(3):
            _failed_login(harness, "alice")

        # 成功登录 → 计数清零
        c = harness.client()
        c.login("alice", "password123", consume=True)
        c.close()
        time.sleep(0.2)

        # 再失败 3 次后正确密码仍可登录（未锁定）
        for _ in range(3):
            _failed_login(harness, "alice")
        c2 = harness.client()
        initial = c2.login("alice", "password123")
        assert initial["login_response"][0]["type"] in ("chat", "admin_auth")

    def test_failures_independent_per_username(self, harness):
        """G6 各用户名计数独立，一个锁定不影响另一个。"""
        for _ in range(5):
            _failed_login(harness, "alice")

        # bob 仅失败 1 次 → 提示"密码错误"而非锁定
        h, d = _failed_login(harness, "bob")
        assert "密码错误" in d.decode(), f"bob 不应被 alice 的锁定影响: {d.decode()}"

        # bob 正确密码正常登录
        c = harness.client()
        initial = c.login("bob", "password456")
        assert initial["login_response"][0]["type"] in ("chat", "admin_auth")

    def test_nonexistent_user_failures_counted(self, harness):
        """G6 用户不存在的失败也计入，防止用户名枚举。"""
        for _ in range(5):
            h, d = _failed_login(harness, "ghost")
            assert "不存在" in d.decode()

        # 第 6 次尝试 → 被锁定拒绝
        h, d = _failed_login(harness, "ghost")
        assert "尝试次数过多" in d.decode(), f"不存在用户也应被锁定: {d.decode()}"


# ============================================================
# G4b —— 大文件直传（阈值分流：>300MB 在线直传，<=300MB 服务器暂存）
# ============================================================

class TestLargeFileDirectTransfer:
    """大文件（filesize > file.large_file_threshold）不再由服务器存储：

    - 发送方先发探测 file_transfer_check（to/filesize/filename/message_id）
    - 目标在线 → S→C file_check_response, ok=1 → 发送方再发送 file 消息，
      服务器边收边转发（不落盘、不存 DB、不产生 file_request）
    - 目标离线 → S→C error 含"离线"，发送方不传输
    - 目标不存在 → error 含"不存在"；群组目标 → error 含"群组"（大文件仅支持私聊）
    - 大文件直传不产生 file_requests / offline_messages / message_history 记录
    - filesize <= 阈值 → 保持小文件暂存逻辑（file_request + 磁盘落盘）
    """

    def _send_check(self, client, to, filesize, message_id, filename="big.bin"):
        client.send("file_transfer_check", "", to=to, filesize=str(filesize),
                    filename=filename, message_id=message_id)

    def _set_threshold(self, monkeypatch, size):
        _set_large_file_threshold(monkeypatch, size)

    def test_transfer_check_online_returns_ok(self, harness, monkeypatch):
        """G4b 探测：目标在线 → file_check_response ok=1。"""
        self._set_threshold(monkeypatch, 1024 * 1024)
        bob = harness.client()
        bob.login("bob", "password456", consume=False)
        bob.recv_initial()
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        self._send_check(alice, "bob", 2 * 1024 * 1024, "chk-1")
        h, d = alice.expect("file_check_response", timeout=3)
        assert h.get("ok") == "1"
        assert h.get("message_id") == "chk-1"
        # 探测本身不产生任何存储
        assert harness.db.get_file_request("chk-1") is None

    def test_transfer_check_offline_rejected(self, harness, monkeypatch):
        """G4b 探测：目标离线 → error 含"离线"，无任何存储。"""
        self._set_threshold(monkeypatch, 1024 * 1024)
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        self._send_check(alice, "bob", 2 * 1024 * 1024, "chk-2")
        h, d = alice.expect("error", timeout=3)
        assert "离线" in d.decode(), f"应提示对方离线: {d.decode()}"
        assert harness.db.get_file_request("chk-2") is None

    def test_transfer_check_nonexistent_user_rejected(self, harness, monkeypatch):
        """G4b 探测：目标不存在 → error 含"不存在"。"""
        self._set_threshold(monkeypatch, 1024 * 1024)
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        self._send_check(alice, "ghost_user", 2 * 1024 * 1024, "chk-3")
        h, d = alice.expect("error", timeout=3)
        assert "不存在" in d.decode()

    def test_transfer_check_group_target_rejected(self, harness, monkeypatch):
        """G4b 探测：群组目标 → error 含"群组"（大文件仅支持私聊直传）。"""
        self._set_threshold(monkeypatch, 1024 * 1024)
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("create_group", "filedemo")
        alice.drain(timeout=0.8)
        gid = harness.db.get_user_groups("alice")[0][0]

        self._send_check(alice, f"group_{gid}", 2 * 1024 * 1024, "chk-4")
        h, d = alice.expect("error", timeout=3)
        assert "群组" in d.decode(), f"群组大文件应被拒绝: {d.decode()}"

    def test_large_file_online_forwarded_directly(self, harness, monkeypatch):
        """G4b 核心：在线目标 → 服务器边收边转发，接收方直接收到 file（非 file_request）。"""
        self._set_threshold(monkeypatch, 1024 * 1024)
        bob = harness.client()
        bob.login("bob", "password456", consume=False)
        bob.recv_initial()
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        payload = os.urandom(2 * 1024 * 1024)
        # 探测在线
        self._send_check(alice, "bob", len(payload), "big-1")
        h, d = alice.expect("file_check_response", timeout=3)
        assert h.get("ok") == "1"
        # 发送大文件 → bob 直接收到 file 消息
        alice.send("file", payload, to="bob", filename="big.bin",
                   filesize=str(len(payload)), message_id="big-1")
        h, d = bob.expect("file", timeout=5)
        assert h.get("from") == "alice"
        assert h.get("message_id") == "big-1"
        assert h.get("filename") == "big.bin"
        assert d == payload, "直传内容应完整一致"

    def test_large_file_not_persisted_anywhere(self, harness, monkeypatch):
        """G4b 直传后不产生任何存储记录（DB 与磁盘）。"""
        self._set_threshold(monkeypatch, 1024 * 1024)
        bob = harness.client()
        bob.login("bob", "password456", consume=False)
        bob.recv_initial()
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        payload = os.urandom(2 * 1024 * 1024)
        self._send_check(alice, "bob", len(payload), "big-2")
        alice.drain(timeout=0.5)
        alice.send("file", payload, to="bob", filename="big.bin",
                   filesize=str(len(payload)), message_id="big-2")
        h, d = bob.expect("file", timeout=5)
        assert d == payload

        deadline = time.time() + 3
        while time.time() < deadline and harness.db.get_file_request("big-2") is not None:
            time.sleep(0.05)
        assert harness.db.get_file_request("big-2") is None, "不应产生文件请求"
        offline = harness.db.get_offline_messages("bob")
        assert not any(m[4] == "big-2" for m in offline), "不应产生离线消息"
        # 磁盘 file_store 无该文件
        store_dir = harness.db._file_store_dir()
        for root, _, files in os.walk(store_dir):
            assert "big-2" not in files, "大文件不应落盘"

    def test_small_file_below_threshold_still_stored(self, harness, monkeypatch):
        """G4b 阈值以下仍走小文件暂存（file_request + 落盘）。"""
        self._set_threshold(monkeypatch, 1024 * 1024)
        bob = harness.client()
        bob.login("bob", "password456", consume=False)
        bob.recv_initial()
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        payload = os.urandom(512 * 1024)  # 512KB < 1MB 阈值
        alice.send("file", payload, to="bob", filename="small.bin",
                   filesize=str(len(payload)), message_id="small-1")
        h, d = bob.expect("file_request", timeout=5)
        assert h.get("message_id") == "small-1"
        row = harness.db.get_file_request("small-1")
        assert row is not None and row[5], "小文件应落盘暂存"

    def test_threshold_boundary_equal_still_stored(self, harness, monkeypatch):
        """G4b 边界：filesize == 阈值 → 按小文件暂存处理。"""
        self._set_threshold(monkeypatch, 1024 * 1024)
        bob = harness.client()
        bob.login("bob", "password456", consume=False)
        bob.recv_initial()
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        payload = os.urandom(1024 * 1024)  # == 阈值
        alice.send("file", payload, to="bob", filename="edge.bin",
                   filesize=str(len(payload)), message_id="edge-1")
        h, d = bob.expect("file_request", timeout=5)
        assert harness.db.get_file_request("edge-1") is not None

    def test_forwarding_socket_suppresses_other_sends(self, harness, monkeypatch):
        """大文件转发期间，服务器抑制对接收方连接的一切写入（chat 走离线）。

        直接标记 active_forward_socks 模拟转发中：此时发给 bob 的 chat 不应
        写入 bob 的 socket（会污染文件字节流），而是落入 offline_messages。
        """
        self._set_threshold(monkeypatch, 1024 * 1024)
        harness.add_user("carol")
        bob = harness.client()
        bob.login("bob", "password456", consume=False)
        bob.recv_initial()
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        carol = harness.client()
        carol.login("carol", "pass123", consume=False)
        carol.recv_initial()
        # carol 与 bob 建立好友关系（用于发 chat）
        harness.db.add_friend_request("carol", "bob")
        harness.db.accept_friend_request("carol", "bob")

        # 模拟：bob 的连接正在被大文件转发占用
        bob_sock = harness.server.client_map["bob"]
        with harness.server.client_map_lock:
            harness.server.active_forward_socks.add(bob_sock)

        # carol 给 bob 发 chat → 服务器应抑制写入 bob socket（chat 已入库，无回执）
        carol.send("chat", "hello during transfer", to="bob")
        time.sleep(0.5)

        # bob 不应在连接上收到该 chat（流未被污染）
        bob_sock.settimeout(0.6)
        try:
            header, data = recv_message(bob_sock)
            assert header is None or header.get("type") != "chat", \
                f"转发中的连接不应收到 chat: {header}"
        except socket.timeout:
            pass  # 无数据到达 = 抑制生效

        # 该 chat 已落入 offline_messages（转发完成后补推）
        offline = harness.db.get_offline_messages("bob")
        assert any("hello during transfer" in (m[2].decode() if m[2] else "")
                   for m in offline), "被抑制的 chat 应保存为离线消息"

        # 解除转发标记 → 后续发送恢复正常
        with harness.server.client_map_lock:
            harness.server.active_forward_socks.discard(bob_sock)
        carol.send("chat", "after transfer", to="bob")
        h, d = bob.expect("chat", timeout=3)
        assert "after transfer" in d.decode()

    def test_forward_completion_repushes_suppressed_messages(self, harness, monkeypatch):
        """转发完成后服务器补推被抑制的离线消息（load_offline_data 补推）。"""
        self._set_threshold(monkeypatch, 1024 * 1024)
        harness.add_user("carol")
        bob = harness.client()
        bob.login("bob", "password456", consume=False)
        bob.recv_initial()
        carol = harness.client()
        carol.login("carol", "pass123", consume=False)
        carol.recv_initial()
        harness.db.add_friend_request("carol", "bob")
        harness.db.accept_friend_request("carol", "bob")

        # 转发中：carol 的 chat 被抑制入离线
        bob_sock = harness.server.client_map["bob"]
        with harness.server.client_map_lock:
            harness.server.active_forward_socks.add(bob_sock)
        carol.send("chat", "suppressed during fwd", to="bob")
        time.sleep(0.5)

        # 转发结束：解除抑制 + 补推（模拟 _handle_file_message 的 finally 逻辑）
        with harness.server.client_map_lock:
            harness.server.active_forward_socks.discard(bob_sock)
        handler = harness.server.client_handler.server  # 触发加载
        from server.server_message_handler import MessageHandler
        MessageHandler(harness.server).load_offline_data("bob", bob_sock)

        # bob 收到补推的 chat（messageId 去重，仅新增）
        h, d = bob.expect("chat", timeout=3)
        assert "suppressed during fwd" in d.decode(), f"应补推被抑制消息: {d.decode()}"
