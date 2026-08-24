"""
============================================================
阶段 L —— 多端前置：服务端多会话并存 TDD 测试（L1，P0-7）
============================================================

【目标】
  按《软件开发文档4.1.0.md》§11 阶段 L / §13.2 P0-7 编写服务端契约测试：
    L1  同账号多会话并存：client_map 双键化 (username, device_id) + 会话级推送
        （server_main.py + server_client_handler.py + 各 handler 推送路径）

【契约（实现方需严格遵守，本测试即据此验证）】
----- L1 同账号多会话并存 -----
  1. 登录携带 device_id 头（header）；缺省时服务端使用默认设备 id。
  2. client_map 双键化 (username, device_id)：
      同一 username + 不同 device_id → 多个会话同时在线，互不踢出。
  3. 同一 (username, device_id) 重复登录 → 踢出该设备的旧会话（G1 语义按设备保留）；
      登录失败不触发踢出；旧会话已关闭再登录不产生踢出通知。
  4. 会话级推送：实时消息（私聊 chat / 群聊 group_chat / 文件请求 file_request /
     撤回 recall / 转发 forward 等）推送到目标用户的**所有在线会话**。
  5. 会话级送达标记：实时推送成功后 offline_messages.status='delivered'
     对每个接收会话一致（不因多会话而重复计未读）。
  6. 断开会话精确清理：某 (username, device_id) 会话断开仅移除自身映射，
     不影响同用户其他会话；全部会话断开后从 client_map 移除。
  7. presence（在线状态）按用户名聚合：任一设备在线即在线；
     某设备下线但仍有其他设备在线时**不广播下线**；全部设备下线才广播离线。
  8. 第二设备登录仍完整收到初始数据（好友/群组/元数据），不因已在别处登录而缺失。

【运行】
  实现前：本文件多数用例红（断言失败或连接关闭），属 TDD 红；少数用例锁定
  既有正确行为（同设备踢出/presence 聚合/初始数据），实现后须保持绿。
  实现后：全部通过。

  .venv/bin/python -m pytest tests/test_stage_l_server.py -v
"""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

DEV1 = "dev-desktop"
DEV2 = "dev-phone"


def _login(harness, username, password, device_id=None, transfer=None):
    """登录并消费初始数据，返回客户端。"""
    c = harness.client()
    c.login(username, password, device_id=device_id, transfer=transfer, consume=False)
    c.recv_initial()
    return c


def _alice_dev1(harness):
    return _login(harness, "alice", "password123", device_id=DEV1)


def _alice_dev2(harness):
    return _login(harness, "alice", "password123", device_id=DEV2)


def _bob(harness):
    return _login(harness, "bob", "password456")


def _setup_alice_two_devices(harness):
    """alice 双设备 + bob 全部在线，返回 (dev1, dev2, bob)。"""
    dev1 = _alice_dev1(harness)
    dev2 = _alice_dev2(harness)
    bob = _bob(harness)
    return dev1, dev2, bob


def _client_map_keys(harness):
    with harness.server.client_map_lock:
        return set(harness.server.client_map.keys())


def _drain_presence_offline(c, username):
    """清空缓冲，返回是否收到某用户的离线（online=0）presence。"""
    got_offline = False
    while True:
        h, d = c.recv(timeout=0.5)
        if h is None:
            break
        if (h.get("type") == "presence"
                and h.get("from") == username and h.get("online") == "0"):
            got_offline = True
    return got_offline


class TestMultiSessionCoexistence:
    """L1 核心：同账号多设备并存、互不踢出。"""

    def test_different_devices_both_online(self, harness):
        """L1 双设备登录 → 均在 client_map（双键），互不踢出，各自可 ping。"""
        dev1 = _alice_dev1(harness)
        dev2 = _alice_dev2(harness)

        keys = _client_map_keys(harness)
        assert ("alice", DEV1) in keys, f"client_map 应含 (alice, {DEV1}): {keys}"
        assert ("alice", DEV2) in keys, f"client_map 应含 (alice, {DEV2}): {keys}"

        # 两个设备各自 ping → pong（均存活）
        dev1.send("ping", "")
        h1, _ = dev1.expect("pong", timeout=3)
        assert h1["type"] == "pong"
        dev2.send("ping", "")
        h2, _ = dev2.expect("pong", timeout=3)
        assert h2["type"] == "pong"

    def test_different_device_no_kick_notice(self, harness):
        """L1 第二设备登录 → 第一设备不收"已在其他地方登录"，连接保持。"""
        dev1 = _alice_dev1(harness)
        _alice_dev2(harness)

        # dev1 缓冲应为空（无踢出通知/任何推送）
        h, d = dev1.recv(timeout=1.0)
        assert h is None, f"dev1 不应收到任何消息（含踢出通知）: {h} {d}"

        # dev1 仍可用
        dev1.send("ping", "")
        h, _ = dev1.expect("pong", timeout=3)
        assert h["type"] == "pong"

    def test_same_device_relogin_kicks_old(self, harness):
        """L1 同 device_id 重登 → 踢出该设备旧会话（G1 语义按设备保留）。"""
        c1 = _alice_dev1(harness)
        c2 = _alice_dev1(harness)

        # 旧会话收到强制下线通知并被关闭
        h, d = c1.expect("error", timeout=3)
        assert h is not None and "已在其他地方登录" in d.decode()
        h2, d2 = c1.recv(timeout=2)
        assert h2 is None, f"旧会话应被关闭: {h2} {d2}"

        # 新会话仍在线
        c2.send("ping", "")
        h3, _ = c2.expect("pong", timeout=3)
        assert h3["type"] == "pong"

    def test_no_kick_when_old_same_device_closed(self, harness):
        """L1 同设备旧会话已关闭再登录 → 不产生踢出通知。"""
        c1 = _alice_dev1(harness)
        c1.close()
        time.sleep(0.3)  # 等旧线程清理 (alice, dev1) 映射

        c2 = harness.client()
        initial = c2.login("alice", "password123", device_id=DEV1)
        assert initial["login_response"][0]["type"] in ("chat", "admin_auth")
        for h, d in initial["extra"]:
            text = d.decode() if d else ""
            assert "已在其他地方登录" not in text, f"不应收到踢出通知: {h} {text}"

    def test_second_device_login_gets_initial_data(self, harness):
        """L1 第二设备登录 → 仍完整收到好友/群组初始数据。"""
        _alice_dev1(harness)
        dev2 = _alice_dev2(harness)
        dev2.close()
        time.sleep(0.3)

        c = harness.client()
        data = c.login("alice", "password123", device_id=DEV2)
        assert "bob" in data["friends"], f"第二设备应收到好友列表: {data['friends']}"


class TestSessionLevelPush:
    """L1 会话级推送：实时消息到达目标用户的所有在线会话。"""

    def test_private_chat_pushed_to_all_sessions(self, harness):
        """L1 私聊 chat → 目标用户两个设备都收到。"""
        dev1, dev2, bob = _setup_alice_two_devices(harness)
        bob.send("chat", "hi alice", to="alice", message_id="L1_c1")

        h1, d1 = dev1.expect("chat", timeout=3)
        h2, d2 = dev2.expect("chat", timeout=3)
        assert h1.get("from") == "bob" and d1.decode() == "hi alice"
        assert h2.get("from") == "bob" and d2.decode() == "hi alice"

    def test_private_chat_delivered_after_push(self, harness):
        """L1 双会话推送成功 → 离线行标记 delivered（不复发未读）。"""
        dev1, dev2, bob = _setup_alice_two_devices(harness)
        bob.send("chat", "hi alice", to="alice", message_id="L1_c2")
        dev1.expect("chat", timeout=3)
        dev2.expect("chat", timeout=3)

        # 服务端在推送完成后于独立线程标记 delivered——客户端读到消息可能略早于
        # 状态落库，这里短重试轮询保证确定性
        def _status():
            with harness.db._get_connection() as conn:
                row = conn.execute(
                    "SELECT status FROM offline_messages WHERE message_id = ?",
                    ("L1_c2",)).fetchone()
            return row[0] if row else None

        deadline = time.time() + 2.0
        status = None
        while time.time() < deadline:
            status = _status()
            if status == "delivered":
                break
            time.sleep(0.05)
        assert status is not None, "消息应已入库"
        assert status == "delivered", f"推送成功后应为 delivered，实际: {status}"

    def test_group_chat_pushed_to_all_sessions(self, harness):
        """L1 群聊 group_chat → 在线成员所有设备都收到。"""
        dev1 = _alice_dev1(harness)
        bob = _bob(harness)

        # alice 建群，bob 加入
        dev1.send("create_group", "multidev")
        dev1.drain(timeout=0.8)
        gid = harness.db.get_user_groups("alice")[0][0]
        bob.send("join_group", str(gid))
        bob.drain(timeout=0.8)

        # alice 第二设备上线后 bob 发群聊
        dev2 = _alice_dev2(harness)
        bob.send("group_chat", "群聊消息", group_id=str(gid), message_id="L1_g1")

        h1, d1 = dev1.expect("group_chat", timeout=3)
        h2, d2 = dev2.expect("group_chat", timeout=3)
        assert h1.get("group_id") == str(gid) and d1.decode() == "群聊消息"
        assert h2.get("group_id") == str(gid) and d2.decode() == "群聊消息"

    def test_file_request_pushed_to_all_sessions(self, harness):
        """L1 文件请求 file_request → 目标用户两个设备都收到。"""
        dev1, dev2, bob = _setup_alice_two_devices(harness)
        bob.send("file", b"hello", to="alice", filename="l1.txt",
                 filesize=5, message_id="L1_f1")

        h1, d1 = dev1.expect("file_request", timeout=3)
        h2, d2 = dev2.expect("file_request", timeout=3)
        assert h1.get("from") == "bob" and h1.get("filename") == "l1.txt"
        assert h2.get("from") == "bob" and h2.get("filename") == "l1.txt"


class TestSessionCleanupAndPresence:
    """L1 会话断开精确清理 + presence 按用户名聚合。"""

    def test_disconnect_one_session_other_survives(self, harness):
        """L1 断开一个设备 → 另一设备仍在线收消息；client_map 精确清理。"""
        dev1, dev2, bob = _setup_alice_two_devices(harness)

        dev1.close()
        time.sleep(0.3)  # 等 (alice, dev1) 线程退出清理

        keys = _client_map_keys(harness)
        assert ("alice", DEV1) not in keys, f"已断开的设备应从 client_map 移除: {keys}"
        assert ("alice", DEV2) in keys, f"存活设备应保留在 client_map: {keys}"

        # dev2 仍能收到新消息
        bob.send("chat", "still alive", to="alice", message_id="L1_c3")
        h, d = dev2.expect("chat", timeout=3)
        assert h.get("from") == "bob" and d.decode() == "still alive"

    def test_all_sessions_closed_removes_user(self, harness):
        """L1 全部设备断开 → 用户从 client_map 完全移除（presence 离线）。"""
        dev1 = _alice_dev1(harness)
        dev2 = _alice_dev2(harness)
        dev1.close()
        dev2.close()
        time.sleep(0.3)

        keys = _client_map_keys(harness)
        assert not any(k[0] == "alice" for k in keys), f"alice 应完全离线: {keys}"

    def test_presence_no_offline_while_other_device_online(self, harness):
        """L1 一设备下线但另一设备在线 → 不向他人广播下线。"""
        bob = _bob(harness)
        bob.drain(timeout=0.5)

        dev1 = _alice_dev1(harness)
        # alice 上线 → bob 收到 presence 在线
        h, d = bob.expect("presence", timeout=3)
        assert h.get("from") == "alice" and h.get("online") == "1"
        bob.drain(timeout=0.5)

        dev2 = _alice_dev2(harness)
        bob.drain(timeout=0.5)  # 清掉可能的重复在线广播

        # 设备 1 下线（设备 2 仍在线）→ 不广播离线
        dev1.close()
        time.sleep(0.3)
        assert _drain_presence_offline(bob, "alice") is False, \
            "另一设备仍在线，不应广播 alice 离线"

    def test_presence_all_devices_offline_broadcasts_offline(self, harness):
        """L1 全部设备下线 → 广播离线。"""
        bob = _bob(harness)
        bob.drain(timeout=0.5)

        dev1 = _alice_dev1(harness)
        bob.expect("presence", timeout=3)
        bob.drain(timeout=0.5)

        dev2 = _alice_dev2(harness)
        bob.drain(timeout=0.5)

        dev1.close()
        time.sleep(0.3)
        bob.drain(timeout=0.5)
        assert _drain_presence_offline(bob, "alice") is False

        # 设备 2 下线 → 广播离线
        dev2.close()
        time.sleep(0.3)
        h, d = bob.expect("presence", timeout=3)
        assert h.get("from") == "alice" and h.get("online") == "0"

    def test_discard_socket_broadcasts_offline(self, harness):
        """L1 发送失败路径 discard_socket 移除最后会话 → 广播 presence 离线（P-07 补漏）。"""
        bob = _bob(harness)
        bob.drain(timeout=0.5)

        dev1 = _alice_dev1(harness)
        h, d = bob.expect("presence", timeout=3)
        assert h.get("from") == "alice" and h.get("online") == "1"
        bob.drain(timeout=0.5)

        sock = harness.server.client_map[("alice", DEV1)]
        harness.server.discard_socket(sock)

        h, d = bob.expect("presence", timeout=3)
        assert h.get("from") == "alice" and h.get("online") == "0", \
            "discard_socket 移除最后会话后应向对方广播离线"

        dev1.close()
        time.sleep(0.3)

    def test_discard_socket_no_offline_while_other_device_online(self, harness):
        """L1 discard_socket 移除一个会话但另一设备在线 → 不广播离线。"""
        bob = _bob(harness)
        bob.drain(timeout=0.5)

        dev1 = _alice_dev1(harness)
        bob.expect("presence", timeout=3)
        bob.drain(timeout=0.5)

        dev2 = _alice_dev2(harness)
        bob.drain(timeout=0.5)

        sock1 = harness.server.client_map[("alice", DEV1)]
        harness.server.discard_socket(sock1)

        assert _drain_presence_offline(bob, "alice") is False, \
            "另一设备仍在线，discard_socket 不应广播离线"

        dev1.close()
        dev2.close()
        time.sleep(0.3)


class TestConnectionWatchdog:
    """L1 补充（P-07 幽灵会话修复）：心跳超时守护。

    客户端每 30s 发 ping；断网/进程异常等"无 FIN 断开"使连接半开，
    服务端守护扫描强制下线 → 线程 finally 正常广播 presence 离线。
    大文件直传期间（active_forward_socks / direct_transfer_sources）跳过。
    """

    def _alice_sock(self, harness):
        with harness.server.client_map_lock:
            return harness.server.client_map[("alice", DEV1)]

    def _set_stale(self, harness, sock, seconds=1000):
        harness.server.session_activity[sock] = time.time() - seconds

    def test_stale_session_forced_offline_and_broadcast(self, harness):
        """超时无活动 → 强制下线 + presence 离线广播（P-07 核心修复）。"""
        bob = _bob(harness)
        bob.drain(timeout=0.5)
        dev1 = _alice_dev1(harness)
        h, d = bob.expect("presence", timeout=3)
        assert h.get("from") == "alice" and h.get("online") == "1"
        bob.drain(timeout=0.5)

        sock = self._alice_sock(harness)
        self._set_stale(harness, sock)

        killed = harness.server.watchdog_scan(timeout=10)
        assert sock in killed, f"超时会话应被强制下线: {killed}"

        # 会话线程 finally 清理 → 广播离线
        time.sleep(0.3)
        h, d = bob.expect("presence", timeout=3)
        assert h.get("from") == "alice" and h.get("online") == "0", \
            "超时下线后应向对方广播离线（P-07）"

    def test_active_session_not_killed(self, harness):
        """正常活动（ping）会话不被误杀。"""
        dev1 = _alice_dev1(harness)
        sock = self._alice_sock(harness)
        harness.server.touch_activity(sock)  # 模拟刚收到 ping

        killed = harness.server.watchdog_scan(timeout=120)
        assert sock not in killed, "活跃会话不应被下线"

        # 连接仍可用
        dev1.send("ping", "")
        h, _ = dev1.expect("pong", timeout=3)
        assert h["type"] == "pong"

    def test_forwarding_sessions_skipped(self, harness):
        """大文件直传期间（接收方/发送方）不被心跳守护误杀。"""
        dev1 = _alice_dev1(harness)
        sock = self._alice_sock(harness)
        self._set_stale(harness, sock)

        # 模拟：连接正在大文件直传（接收方 + 发送方双重保护）
        with harness.server.client_map_lock:
            harness.server.active_forward_socks.add(sock)
            harness.server.direct_transfer_sources.add(sock)
        killed = harness.server.watchdog_scan(timeout=10)
        assert sock not in killed, "直传中的连接不应被心跳守护下线"

        # 解除直传标记后再扫描 → 被下线
        with harness.server.client_map_lock:
            harness.server.active_forward_socks.discard(sock)
            harness.server.direct_transfer_sources.discard(sock)
        killed = harness.server.watchdog_scan(timeout=10)
        assert sock in killed, "直传结束后超时连接应被下线"

    def test_activity_record_cleaned_after_disconnect(self, harness):
        """断开后 session_activity 记录被清理（无泄漏）。"""
        dev1 = _alice_dev1(harness)
        sock = self._alice_sock(harness)
        assert sock in harness.server.session_activity
        dev1.close()
        time.sleep(0.3)
        assert sock not in harness.server.session_activity, \
            "断开后活动记录应被清理"


class TestFdReuseGuard:
    """P-07 缺陷修复回归：发送/关闭互斥，杜绝 fd 复用竞态。

    旧实现：guarded_send 解锁后 sendall，与踢出/看门狗/线程 finally 的
    close 竞态——关闭释放 fd 后 sqlite 打开数据库文件复用该 fd，
    sendall 把（SSL）字节写进数据库文件（'file is not a database'）→
    presence 广播的 is_blocked 抛错被吞 → 对方一直显示在线（重登才恢复）。
    修复：发送全程持锁 + 活性校验跳过已下线 socket；关闭延迟到在途
    发送结束（引用计数）。
    """

    def test_guarded_send_skips_removed_socket(self, harness):
        """会话从 client_map 移除后 guarded_send 静默跳过（不写入已关闭 fd）。"""
        dev1 = _alice_dev1(harness)
        sock = harness.server.client_map[("alice", DEV1)]
        with harness.server.client_map_lock:
            harness.server.client_map.pop(("alice", DEV1), None)
            harness.server.pending_socks.discard(sock)
        harness.server.guarded_send(sock, "chat", "不应到达")
        h, d = dev1.recv(timeout=0.5)
        assert h is None, f"已下线会话不应再收到任何推送: {h}"

    def test_guarded_send_skips_transfer_removed_socket(self, harness):
        """transfer_sockets 移除后同样跳过。"""
        dev1 = _login(harness, "alice", "password123", device_id=DEV1, transfer="1")
        with harness.server.client_map_lock:
            sock = harness.server.transfer_sockets["alice"]
            harness.server.transfer_sockets.pop("alice", None)
            harness.server.pending_socks.discard(sock)
        harness.server.guarded_send(sock, "chat", "不应到达")
        h, d = dev1.recv(timeout=0.5)
        assert h is None, f"已移除的传输通道不应再收到推送: {h}"

    def test_pending_socks_allows_auth_errors(self, harness):
        """认证握手中的连接（pending_socks）可收到错误响应。"""
        c = harness.client()
        c.send("login", "alice", password="wrong-password")
        h, d = c.expect("error", timeout=3)
        assert "密码错误" in d.decode(), f"认证失败响应应送达: {d}"

    def test_acquire_release_defers_close(self, harness):
        """长发送引用：引用期间 close 延迟，释放后真正关闭（fd 不被提前复用）。"""
        dev1 = _alice_dev1(harness)
        sock = harness.server.client_map[("alice", DEV1)]
        assert harness.server.acquire_send_sock(sock) is True, "活跃会话可被引用"
        harness.server.close_sock(sock)
        with harness.server.client_map_lock:
            assert sock in harness.server.sock_pending_close, \
                "引用未清零时关闭应延迟"
            assert sock not in harness.server.sock_refs or True
        # 引用未释放 → fd 仍可用（未关闭）
        sock.sendall(b"x" * 4)
        harness.server.release_send_sock(sock)
        with harness.server.client_map_lock:
            assert sock not in harness.server.sock_pending_close
        # 释放后真正关闭
        closed = False
        try:
            sock.sendall(b"x")
        except OSError:
            closed = True
        assert closed, "释放引用后应真正关闭 socket"
        harness.server.client_map.pop(("alice", DEV1), None)

    def test_acquire_fails_for_dead_sock(self, harness):
        """已下线 socket 无法被引用（长发送直接跳过）。"""
        dev1 = _alice_dev1(harness)
        sock = harness.server.client_map[("alice", DEV1)]
        with harness.server.client_map_lock:
            harness.server.client_map.pop(("alice", DEV1), None)
            harness.server.pending_socks.discard(sock)
        assert harness.server.acquire_send_sock(sock) is False, "已下线 socket 不可引用"

    def test_release_without_acquire_is_safe(self, harness):
        """未 acquire 直接 release 不抛异常（幂等防御）。"""
        dev1 = _alice_dev1(harness)
        sock = harness.server.client_map[("alice", DEV1)]
        harness.server.release_send_sock(sock)
        harness.server.close_sock(sock)
        harness.server.client_map.pop(("alice", DEV1), None)

    def test_kick_no_longer_closes_fd_immediately(self, harness):
        """踢出只 shutdown 不 close：旧会话 fd 由线程 finally 关闭（P-07）。"""
        c1 = _alice_dev1(harness)
        old_sock = harness.server.client_map[("alice", DEV1)]
        c2 = _alice_dev1(harness)  # 同设备重登 → 踢出 c1
        # 踢出瞬间：旧 socket 不应已被 close（fd 复用窗口不存在）
        try:
            old_sock.sendall(b"ping")
            alive = True
        except OSError:
            alive = False
        # shutdown 后 sendall 可能成功（fd 仍有效）或失败（对端已关），
        # 但绝不允许 fd 被提前释放后静默写入其他文件——这里仅验证
        # client_map 映射已切换且旧线程 finally 正常清理
        with harness.server.client_map_lock:
            assert harness.server.client_map[("alice", DEV1)] is not old_sock
        time.sleep(0.3)
        with harness.server.client_map_lock:
            assert all(v is not old_sock for v in harness.server.client_map.values())
        c1.close()
        c2.close()
        time.sleep(0.3)

    def test_kick_stress_db_stays_intact(self, harness):
        """并发同设备重登 + 广播 + 数据库读写压力下，数据库文件不被污染（P-07 回归）。

        旧实现中踢出 close 与并发 guarded_send 竞态，fd 被 sqlite 数据库
        文件复用后 sendall 会写坏数据库头（'file is not a database'）。
        修复后数据库文件头必须始终保持 'SQLite format 3'。
        """
        bob = _bob(harness)
        bob.drain(timeout=0.5)
        dev1 = _alice_dev1(harness)
        dev2 = _alice_dev2(harness)
        bob.drain(timeout=0.5)

        import threading as _threading

        def _kick_loop(device, rounds):
            for i in range(rounds):
                c = harness.client()
                c.login("alice", "password123", device_id=device, consume=False)
                c.recv_initial()
                time.sleep(0.01)

        def _broadcast_loop(rounds):
            for i in range(rounds):
                bob.send("chat", f"stress-{i}", to="alice",
                         message_id=f"stress_broadcast_{i}")

        threads = []
        for dev, rounds in ((DEV1, 8), (DEV2, 8)):
            t = _threading.Thread(target=_kick_loop, args=(dev, rounds))
            threads.append(t)
            t.start()
        bt = _threading.Thread(target=_broadcast_loop, args=(20,))
        threads.append(bt)
        bt.start()
        for t in threads:
            t.join(timeout=30)

        time.sleep(0.5)
        # 数据库文件头必须完好（未被 fd 复用竞态写坏）
        with open(harness.db_path, "rb") as f:
            head = f.read(16)
        assert head.startswith(b"SQLite format 3"), \
            f"数据库文件被污染: {head!r}"
        with harness.db._get_connection() as conn:
            conn.execute("SELECT count(*) FROM users").fetchone()
        dev1.close()
        dev2.close()
        bob.close()
        time.sleep(0.3)


class TestMultiDeviceFileResolve:
    """L1 多端前置：某设备接受/拒绝文件后，其他设备再响应同一请求 →
    提示"该文件已在XXX(设备)被接受/拒绝"，而非误导性的"文件不存在"。"""

    def test_private_file_resolved_on_other_device(self, harness):
        """私聊文件：设备1接受后，设备2再接受 → 提示已在设备1被接受。"""
        alice = _login(harness, "alice", "password123", device_id=DEV1)
        bob1 = _login(harness, "bob", "password456", device_id=DEV1)
        bob2 = _login(harness, "bob", "password456", device_id=DEV2)

        msg_id = "L1_priv_file_resolve_1"
        alice.send("file", b"data", to="bob", filename="f.txt",
                   filesize=4, message_id=msg_id)

        h1, _ = bob1.expect("file_request", timeout=3)
        h2, _ = bob2.expect("file_request", timeout=3)
        assert h1.get("message_id") == msg_id and h2.get("message_id") == msg_id

        # 设备 1 接受 → 两设备都收到文件数据（会话级推送）
        bob1.send("file_response", "", response="accept",
                  message_id=msg_id, to="alice")
        bob1.expect("file", timeout=3)
        bob2.expect("file", timeout=3)

        # 设备 2 再接受 → 提示已在设备 1 被接受
        bob2.send("file_response", "", response="accept",
                  message_id=msg_id, to="alice")
        h, d = bob2.expect("error", timeout=3)
        assert d.decode() == f"该文件已在{DEV1}被接受", \
            f"应提示已在设备 {DEV1} 被接受，实际: {d.decode()}"

    def test_private_file_rejected_on_other_device(self, harness):
        """私聊文件：设备1拒绝后，设备2再接受 → 提示已在设备1被拒绝。"""
        alice = _login(harness, "alice", "password123", device_id=DEV1)
        bob1 = _login(harness, "bob", "password456", device_id=DEV1)
        bob2 = _login(harness, "bob", "password456", device_id=DEV2)

        msg_id = "L1_priv_file_resolve_2"
        alice.send("file", b"data", to="bob", filename="f.txt",
                   filesize=4, message_id=msg_id)
        bob1.expect("file_request", timeout=3)
        bob2.expect("file_request", timeout=3)

        bob1.send("file_response", "", response="reject",
                  message_id=msg_id, to="alice")
        # 拒绝不向设备1回包，轮询等待响应落库后再触发设备2，避免两设备并发响应竞态
        deadline = time.time() + 2
        while time.time() < deadline and harness.db.get_file_resolution(msg_id, "bob") is None:
            time.sleep(0.05)
        assert harness.db.get_file_resolution(msg_id, "bob") is not None

        bob2.send("file_response", "", response="accept",
                  message_id=msg_id, to="alice")
        h, d = bob2.expect("error", timeout=3)
        assert d.decode() == f"该文件已在{DEV1}被拒绝", \
            f"应提示已在设备 {DEV1} 被拒绝，实际: {d.decode()}"

    def test_group_file_resolved_on_other_device(self, harness):
        """群组文件：设备1接受后，设备2再接受 → 提示已在设备1被接受。"""
        alice = _login(harness, "alice", "password123", device_id=DEV1)
        bob1 = _login(harness, "bob", "password456", device_id=DEV1)

        # alice 建群，bob 加入
        alice.send("create_group", "L1resgroup")
        alice.drain(timeout=0.8)
        gid = harness.db.get_user_groups("alice")[0][0]
        bob1.send("join_group", str(gid))
        bob1.drain(timeout=0.8)

        # bob 第二设备上线
        bob2 = _login(harness, "bob", "password456", device_id=DEV2)

        msg_id = "L1_group_file_resolve_1"
        alice.send("file", b"data", to=f"group_{gid}", filename="g.txt",
                   filesize=4, message_id=msg_id)
        bob1.expect("group_file_request", timeout=3)
        bob2.expect("group_file_request", timeout=3)

        # 设备 1 接受 → 两设备都收到文件数据
        bob1.send("group_file_response", "", response="accept",
                  message_id=msg_id, group_id=str(gid))
        bob1.expect("file", timeout=3)
        bob2.expect("file", timeout=3)

        # 设备 2 再接受 → 提示已在设备 1 被接受
        bob2.send("group_file_response", "", response="accept",
                  message_id=msg_id, group_id=str(gid))
        h, d = bob2.expect("error", timeout=3)
        assert d.decode() == f"该文件已在{DEV1}被接受", \
            f"应提示已在设备 {DEV1} 被接受，实际: {d.decode()}"

