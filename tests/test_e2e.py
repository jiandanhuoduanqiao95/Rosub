"""
============================================================
多客户端端到端 (E2E) 场景测试
============================================================

【测试策略】
  在同进程中启动测试服务器（后台线程），监听随机端口，
  跳过 SSL。多个 HeadlessTestClient 通过 TCP 连接，
  执行完整业务流程。

【覆盖场景】
  - 两用户注册、加好友、私聊
  - 离线消息投递
  - 群组创建-加入-群聊
  - 消息撤回（2分钟内）

【标签】
  所有 E2E 测试使用 @pytest.mark.e2e 标记，
  可以选择性运行或跳过。
"""

import sys
import os
import socket
import time
import json
import uuid
import threading
import random
import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from protocol import send_message, recv_message


# ============================================================
# HeadlessTestClient —— 无头测试客户端
# ============================================================

class HeadlessTestClient:
    """
    没有 GUI 的测试客户端。支持连接、注册/登录、发送/接收消息。

    用法：
      c = HeadlessTestClient(port)
      c.connect()
      c.register("alice", "pass")
      c.consume_initial()
      c.send_chat("bob", "Hello")
      h, d = c.recv()
    """

    def __init__(self, host="127.0.0.1", port=8091):
        self.host = host
        self.port = port
        self.sock = None
        self.username = None
        self.received = []

    def connect(self):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.settimeout(5)
        self.sock.connect((self.host, self.port))

    def disconnect(self):
        try:
            if self.sock:
                self.sock.close()
        except Exception:
            pass
        self.sock = None

    def send(self, msg_type, content, **extra_headers):
        send_message(self.sock, msg_type, content, extra_headers=extra_headers)

    def recv(self, timeout=3):
        self.sock.settimeout(timeout)
        try:
            header, data = recv_message(self.sock)
            if header:
                self.received.append((header, data))
            return header, data
        except socket.timeout:
            return None, None
        except OSError:
            return None, None

    def login(self, username, password):
        self.send("login", username, password=password)
        self.username = username

    def register(self, username, password):
        self.send("register", username, password=password)
        self.username = username

    def consume_initial(self, max_msg=15):
        """
        消费登录后的初始推送。
        返回 (login_ok, friends_json, groups_json, offline_msgs)
        """
        result = {"login_ok": False, "friends": [], "groups": [], "offline": []}
        for _ in range(max_msg):
            h, d = self.recv(timeout=2)
            if h is None:
                break
            t = h.get("type")
            # 离线消息（history=true）在任何情况下都应被记录
            if h.get("history") == "true":
                result["offline"].append((h, d))
                continue
            if t in ("chat", "admin_auth"):
                result["login_ok"] = True
                txt = d.decode() if d else ""
                if "离线" in txt:
                    continue
            elif t == "admin_response" and h.get("response_type") == "list_friends":
                result["friends"] = json.loads(d.decode()) if d else []
            elif t == "list_groups":
                result["groups"] = json.loads(d.decode()) if d else []
        return result

    def drain(self, timeout=0.5):
        """清空所有缓冲的待处理消息，返回消费的消息数量"""
        count = 0
        while True:
            h, d = self.recv(timeout=timeout)
            if h is None:
                break
            count += 1
        return count

    def send_chat(self, target, message):
        msg_id = str(uuid.uuid4())
        self.send("chat", message, to=target, message_id=msg_id)
        return msg_id

    def send_group_chat(self, group_id, message):
        msg_id = str(uuid.uuid4())
        self.send("group_chat", message, group_id=str(group_id), message_id=msg_id)
        return msg_id


# ============================================================
# 同进程测试服务器
# ============================================================

class InProcessTestServer:
    """
    在同进程中以线程方式启动的测试服务器（无 SSL）。
    解决了子进程方式的各种问题（导入路径、启动竞态等）。
    """

    def __init__(self):
        from database import Database
        from server.server_main import Server
        import tempfile

        # 使用独立临时数据库
        self._tmpdir = tempfile.mkdtemp(prefix="chat_test_")
        db_path = os.path.join(self._tmpdir, "test.db")

        # 分配随机端口
        self.port = self._find_free_port()

        # 创建 Server 实例
        self.server = Server(port=self.port)
        self.server.db = Database(db_path)

        self._thread = None
        self._running = False
        self._server_socket = None

    def _find_free_port(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.bind(('127.0.0.1', 0))
        port = s.getsockname()[1]
        s.close()
        return port

    def start(self):
        """启动服务端监听线程"""
        from server.server_client_handler import ClientHandler

        self._server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._server_socket.bind(('127.0.0.1', self.port))
        self._server_socket.listen(10)
        self._server_socket.settimeout(1.0)
        self._running = True

        def accept_loop():
            # Mock SSL context
            import ssl
            class NoSSLContext:
                def wrap_socket(self, sock, server_side=False):
                    return sock

            ctx = NoSSLContext()

            while self._running:
                try:
                    client_sock, addr = self._server_socket.accept()
                    t = threading.Thread(
                        target=self.server.client_handler.handle_client,
                        args=(client_sock, addr, ctx),
                        daemon=True
                    )
                    t.start()
                except socket.timeout:
                    continue
                except Exception:
                    if self._running:
                        continue
                    break

        self._thread = threading.Thread(target=accept_loop, daemon=True)
        self._thread.start()
        time.sleep(0.2)  # 确保监听线程已启动

    def stop(self):
        """停止服务器并清理"""
        self._running = False
        if self._server_socket:
            try:
                self._server_socket.close()
            except Exception:
                pass
        if self._thread:
            self._thread.join(timeout=3)
        # 清理临时数据库
        import shutil
        try:
            shutil.rmtree(self._tmpdir, ignore_errors=True)
        except Exception:
            pass


# ============================================================
# 夹具：每个测试函数一个独立服务器
# ============================================================

@pytest.fixture
def srv():
    """为每个测试启动一个全新的测试服务器"""
    server = InProcessTestServer()
    server.start()
    yield server
    server.stop()


# ============================================================
# 第 1 组：基本认证和私聊
# ============================================================

@pytest.mark.e2e
class TestE2EAuthentication:

    def test_two_users_register_and_chat(self, srv):
        """
        【E2E-86】两个用户注册 → 加好友 → 私聊

        验证点：
        - 注册成功
        - 好友请求/接受流程
        - 消息实时投递
        """
        alice = HeadlessTestClient(port=srv.port)
        bob = HeadlessTestClient(port=srv.port)

        # 注册
        alice.connect()
        alice.register("alice", "pass123")
        r = alice.consume_initial()
        assert r["login_ok"], "alice 注册失败"

        bob.connect()
        bob.register("bob", "pass456")
        r = bob.consume_initial()
        assert r["login_ok"], "bob 注册失败"

        # 加好友
        alice.send("friend_request", "", to="bob")
        h, _ = bob.recv(timeout=3)
        assert h is not None and h.get("type") == "friend_request", "bob 未收到好友请求"

        bob.send("accept_friend", "", **{"from": "alice"})
        h, _ = bob.recv(timeout=2)  # 确认
        h, _ = alice.recv(timeout=2)  # 通知

        # 私聊
        alice.send_chat("bob", "Hello Bob!")
        h, d = bob.recv(timeout=3)
        assert h is not None and h.get("type") == "chat", f"bob 未收到消息: {h}"
        assert "Hello Bob!" in d.decode()

        alice.disconnect()
        bob.disconnect()

    def test_offline_message_delivery(self, srv):
        """
        【E2E-87】离线消息投递

        流程：
        1. alice 和 bob 注册并加好友
        2. bob 下线
        3. alice 发消息（bob 离线）
        4. bob 重新上线
        5. bob 收到 history=true 的离线消息
        """
        alice = HeadlessTestClient(port=srv.port)
        bob = HeadlessTestClient(port=srv.port)

        alice.connect()
        alice.register("alice", "alice123")
        alice.consume_initial()

        bob.connect()
        bob.register("bob", "bob12345")
        bob.consume_initial()

        # 加好友
        alice.send("friend_request", "", to="bob")
        bob.recv(timeout=3)  # 好友请求
        bob.send("accept_friend", "", **{"from": "alice"})
        # 消费双方的好友相关通知
        alice.drain(timeout=1.0)
        bob.drain(timeout=1.0)

        # bob 下线
        bob.disconnect()
        time.sleep(0.3)

        # alice 发消息给离线的 bob
        alice.send_chat("bob", "离线消息测试内容")
        h, d = alice.recv(timeout=2)
        assert h is not None, "alice 未收到任何回复"
        txt = d.decode() if d else ""
        assert "离线" in txt or h.get("type") == "chat", \
            f"应有离线提示, got type={h.get('type')} text={txt}"

        alice.disconnect()

        # bob 重新上线
        bob2 = HeadlessTestClient(port=srv.port)
        bob2.connect()
        bob2.login("bob", "bob12345")
        r = bob2.consume_initial(max_msg=15)

        # 检查离线消息
        offline_texts = []
        for h, d in r["offline"]:
            if h.get("type") == "chat":
                offline_texts.append(d.decode() if d else "")
        assert any("离线消息测试内容" in t for t in offline_texts), \
            f"未收到离线消息! got: {offline_texts}"

        bob2.disconnect()


# ============================================================
# 第 2 组：群组场景
# ============================================================

@pytest.mark.e2e
class TestE2EGroupScenarios:

    def test_group_create_join_chat(self, srv):
        """
        【E2E-88】群组：创建 → 加入 → 群聊广播

        验证点：
        - alice 创建群组成功
        - bob 加入成功
        - 群聊消息被路由到全部成员
        """
        alice = HeadlessTestClient(port=srv.port)
        bob = HeadlessTestClient(port=srv.port)

        # 注册
        for c, name, pw in [(alice, "alice", "alice123"), (bob, "bob", "bob12345")]:
            c.connect()
            c.register(name, pw)
            c.consume_initial()

        # alice 创建群组
        alice.send("create_group", "测试群")
        # 消费群组创建响应和通知（可能有 2-3 条消息）
        alice.drain(timeout=1.0)

        # 获取 group_id
        alice.send("list_groups", "")
        h, d = alice.recv(timeout=2)
        groups = json.loads(d.decode())
        group_id = str(groups[0]["id"])

        # bob 加入
        bob.send("join_group", group_id)
        bob.drain(timeout=1.0)  # 消费加入响应和通知

        # alice 发群聊（先清管道）
        alice.drain(timeout=0.5)
        bob.drain(timeout=0.5)
        alice.send_group_chat(group_id, "群聊测试消息")
        alice.recv(timeout=2)  # 自己的确认

        # bob 应收到
        h, d = bob.recv(timeout=3)
        assert h is not None and h.get("type") == "group_chat", f"bob 未收到群聊: {h}"
        assert "群聊测试消息" in d.decode()

        alice.disconnect()
        bob.disconnect()


# ============================================================
# 第 3 组：消息撤回
# ============================================================

@pytest.mark.e2e
class TestE2EMessageRecall:

    def test_recall_chat_message(self, srv):
        """
        【E2E-89】发送消息 → 立即撤回（2分钟内）

        验证点：
        - 撤回成功
        - 对方收到 recall 通知
        """
        alice = HeadlessTestClient(port=srv.port)
        bob = HeadlessTestClient(port=srv.port)

        for c, name, pw in [(alice, "alice", "alice123"), (bob, "bob", "bob12345")]:
            c.connect()
            c.register(name, pw)
            c.consume_initial()

        # 加好友
        alice.send("friend_request", "", to="bob")
        bob.recv(timeout=3)
        bob.send("accept_friend", "", **{"from": "alice"})
        alice.drain(timeout=1.0)
        bob.drain(timeout=1.0)

        # 发消息
        msg_id = alice.send_chat("bob", "这条消息将被撤回")
        h, d = bob.recv(timeout=3)
        assert h is not None and "将被撤回" in (d.decode() if d else ""), f"bob 未收到消息: {h}"

        # 撤回
        alice.send("recall", "", message_id=msg_id)
        h, d = alice.recv(timeout=2)
        assert "已撤回" in (d.decode() if d else ""), f"撤回失败: {d.decode() if d else h}"

        # bob 收到撤回通知
        h, d = bob.recv(timeout=3)
        assert h is not None, "bob 未收到任何消息"
        assert h.get("type") == "recall", f"bob 应收到 recall, 实际收到: {h.get('type')} text={d.decode() if d else ''}"

        alice.disconnect()
        bob.disconnect()


# ============================================================
# 运行方式
# ============================================================
"""
运行所有 E2E 测试:
  .venv/bin/python -m pytest tests/test_e2e.py -v -m e2e

运行除 E2E 外的快速测试:
  .venv/bin/python -m pytest tests/ -v --ignore=tests/test_e2e.py

E2E 测试比单元测试慢（每个测试 2-5 秒，因为需要启动真实服务器），
建议在日常开发中频繁运行快速测试，提交前再运行 E2E。
"""
