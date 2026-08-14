"""
============================================================
聊天室项目 —— pytest 共享测试基础设施
============================================================

本文件集中放置跨测试文件复用的夹具与辅助工具，是测试层
"重构" 的核心：原先每个 test_server*.py 都各自重复实现
create_test_db / start_mock_client / expect_response 等样板，
现在统一收敛到此，新测试通过 `harness` 夹具即可获得一个
开箱即用的"服务端 + mock 客户端"环境。

引入的 pytest 插件：
  - pytest-asyncio : async def 测试自动识别（asyncio_mode=auto）
  - pytest-socket  : 通过 socket_disabled 夹具守护纯逻辑测试不触网
  - pytest-xdist   : -n auto 并行执行，本文件提供进程级隔离夹具
  - hypothesis     : 属性/状态机测试（见 test_hypothesis.py）

设计原则：
  - 不修改任何生产代码，仅服务于测试
  - 每个测试使用独立临时数据库（tmp_path），互不污染
  - 会话级 autouse 夹具把 config 默认数据库路径重定向到临时目录，
    避免 Server() 构造时触碰真实 users.db（pytest-xdist 并行安全）
"""

import os
import sys
import ssl
import json
import time
import socket
import threading
import uuid

import pytest

# 确保项目根目录在 sys.path 上，便于 import protocol/database/server 等
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from database import Database
from protocol import send_message, recv_message

try:
    from server.server_main import Server
except Exception:  # pragma: no cover - 仅在极端环境下发生
    Server = None


TEST_ADMIN_SECRET = "test-admin-secret"


# ============================================================
# 会话级 autouse：环境与配置隔离
# ============================================================

@pytest.fixture(autouse=True, scope="session")
def _isolate_default_db_path(tmp_path_factory):
    """把 config 默认 database.path 重定向到临时目录。

    Server() 构造时会 Database()（使用 config 默认路径），
    若不重定向，pytest-xdist 多进程并行时会同时打开真实 users.db
    造成 SQLite 锁竞争。这里在会话开始时把默认路径指向每个 worker
    独立的临时目录，彻底隔离副作用。
    """
    from config import config

    config._load()
    tmp = tmp_path_factory.mktemp("defaultdb")
    if isinstance(config._data, dict):
        config._data.setdefault("database", {})["path"] = str(tmp / "users.db")
    yield


@pytest.fixture(autouse=True, scope="session")
def _ensure_admin_secret():
    """会话级设置管理员密钥环境变量，保证需要管理员的测试可用。"""
    os.environ["CHATROOM_ADMIN_SECRET"] = TEST_ADMIN_SECRET
    yield


# ============================================================
# 夹具：临时数据库
# ============================================================

@pytest.fixture
def db(tmp_path):
    """为每个测试提供一个全新的、独立的 Database（临时文件）。"""
    db_path = str(tmp_path / "test.db")
    return Database(db_path)


@pytest.fixture
def no_admin_secret(monkeypatch):
    """删除管理员密钥环境变量，用于测试"服务器未配置管理员密钥"场景。"""
    monkeypatch.delenv("CHATROOM_ADMIN_SECRET", raising=False)
    yield


# ============================================================
# 共享工具：创建预填充测试数据库
# ============================================================

def create_test_db(db_path, with_admin=True):
    """创建预填充的测试数据库。

    用户：
      - alice / password123  （普通用户）
      - bob   / password456  （普通用户）
      - admin / adminpass    （管理员，仅当 with_admin=True）

    预置好友关系：alice <-> bob
    """
    os.environ["CHATROOM_ADMIN_SECRET"] = TEST_ADMIN_SECRET
    database = Database(db_path)
    database.add_user("alice", _hash("password123"))
    database.add_user("bob", _hash("password456"))
    if with_admin:
        database.add_user("admin", _hash("adminpass"))
        with database._get_connection() as conn:
            conn.execute("UPDATE users SET is_admin = 1 WHERE username = 'admin'")
            conn.commit()
    database.add_friend_request("alice", "bob")
    database.accept_friend_request("alice", "bob")
    return database


def _hash(password):
    import bcrypt
    return bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt())


# ============================================================
# 共享工具：Mock 客户端（socketpair + Mock SSL）
# ============================================================

class Client:
    """对 socketpair 客户端的封装，提供便捷的收发与初始数据消费。"""

    def __init__(self, sock):
        self._sock = sock

    # ---- 原始收发 ----
    def send(self, msg_type, content, **extra_headers):
        send_message(self._sock, msg_type, content, extra_headers=extra_headers)

    def recv(self, timeout=3):
        self._sock.settimeout(timeout)
        try:
            header, data = recv_message(self._sock)
            return header, data
        except socket.timeout:
            return None, None

    def expect(self, expected_type, timeout=3):
        """读取一条消息并断言类型，返回 (header, data)。

        阶段 J 修订：presence（在线状态广播，登录/登出触发）为通知性消息，
        不属于测试关注的消息流。期望类型非 presence 时读到 presence 自动跳过
        （避免既有多客户端测试被登录/登出广播噪声打断）；
        期望类型恰为 presence 时不跳过（阶段 J 契约测试据此断言广播内容）。
        """
        deadline = time.time() + timeout
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                pytest.fail(f"超时：等待 '{expected_type}' 超过 {timeout}s")
            self._sock.settimeout(remaining)
            try:
                header, data = recv_message(self._sock)
            except socket.timeout:
                pytest.fail(f"超时：等待 '{expected_type}' 超过 {timeout}s")
            if header is None:
                pytest.fail(f"连接已关闭，期望 '{expected_type}'")
            if header.get("type") == "presence" and expected_type != "presence":
                continue
            return header, data

    def drain(self, timeout=0.4):
        """清空缓冲的待处理消息，返回消费数量。"""
        count = 0
        while True:
            h, _ = self.recv(timeout=timeout)
            if h is None:
                break
            count += 1
        return count

    def recv_initial(self, max_msg=60):
        """消费登录后推送的初始数据，返回结构化 dict。

        服务器登录成功后依次发送：
          1. 登录响应（chat / admin_auth）
          2. 离线消息（history=true）— 0 或多条
          3. 文件请求 / 群文件请求 — 0 或多条
          4. 好友请求 — 0 或多条
          5. 好友列表（admin_response, response_type=list_friends）
          6. 群组列表（list_groups）
          7. 好友元数据（admin_response, response_type=list_friends_meta）
          8. 黑名单（admin_response, response_type=list_blocked）
        全部消费完毕后返回（缓冲不留残余，后续 expect 不被打扰）。
        """
        result = {
            "login_response": None,
            "friends": [],
            "groups": [],
            "offline": [],
            "friend_requests": [],
            "file_requests": [],
            "group_file_requests": [],
            "friend_meta": [],
            "blocked": [],
            "extra": [],
        }
        got_friends = False
        got_groups = False
        got_meta = False
        got_blocked = False

        # 第 1 条：登录响应
        h, d = self.recv(timeout=3)
        if h is None:
            return result
        result["login_response"] = (h, d)

        for _ in range(max_msg):
            h, d = self.recv(timeout=2)
            if h is None:
                break
            t = h.get("type")
            if h.get("history") == "true":
                result["offline"].append((h, d))
            elif t == "file_request":
                result["file_requests"].append((h, d))
            elif t == "group_file_request":
                result["group_file_requests"].append((h, d))
            elif t == "friend_request":
                result["friend_requests"].append((h, d))
            elif t == "admin_response" and h.get("response_type") == "list_friends":
                result["friends"] = json.loads(d.decode()) if d else []
                got_friends = True
            elif t == "admin_response" and h.get("response_type") == "list_friends_meta":
                result["friend_meta"] = json.loads(d.decode()) if d else []
                got_meta = True
            elif t == "admin_response" and h.get("response_type") == "list_blocked":
                result["blocked"] = json.loads(d.decode()) if d else []
                got_blocked = True
            elif t == "list_groups":
                result["groups"] = json.loads(d.decode()) if d else []
                got_groups = True
            else:
                result["extra"].append((h, d))
            if got_friends and got_groups and got_meta and got_blocked:
                break
        return result

    def login(self, username, password, admin_secret=None, consume=True):
        extra = {"password": password}
        if admin_secret:
            extra["admin_secret"] = admin_secret
        self.send("login", username, **extra)
        if consume:
            return self.recv_initial()
        return None

    def register(self, username, password, admin_secret=None, consume=True):
        extra = {"password": password}
        if admin_secret:
            extra["admin_secret"] = admin_secret
        self.send("register", username, **extra)
        if consume:
            return self.recv_initial()
        return None

    def close(self):
        try:
            self._sock.close()
        except Exception:
            pass


class ServerHarness:
    """一个 Server + 临时数据库，可按需创建多个 mock 客户端。

    用法：
        def test_x(harness):
            alice = harness.client()
            alice.login("alice", "password123")
            ...
    """

    def __init__(self, db_path, with_admin=True):
        self.db_path = db_path
        self.db = create_test_db(db_path, with_admin=with_admin)
        assert Server is not None, "Server 模块导入失败"
        self.server = Server()
        self.server.db = self.db
        self._threads = []
        self._socks = []

    def _spawn(self, s1):
        """在线程中启动 handle_client，使用每线程独立的假 SSL 上下文。

        注意：不用全局 patch.object(SSLContext.wrap_socket) —— 多客户端并发
        时线程交错在 patch→wrap_socket 窗口会互相覆盖补丁（拿到错误 socket
        或丢失补丁触发真实 TLS 握手），导致偶发 ConnectionResetError。
        每线程独立的假上下文对象从根上消除该竞态。
        """
        class _FakeSSLContext:
            def wrap_socket(self, sock, server_side=False):
                return s1
        fake_ctx = _FakeSSLContext()

        def run():
            self.server.client_handler.handle_client(
                s1, ("127.0.0.1", 12345), fake_ctx,
            )
        t = threading.Thread(target=run, daemon=True)
        t.start()
        time.sleep(0.05)
        self._threads.append(t)

    def client(self):
        s1, s2 = socket.socketpair()
        self._socks.extend([s1, s2])
        self._spawn(s1)
        return Client(s2)

    def add_user(self, username, password="pass123"):
        self.db.add_user(username, _hash(password))

    def stop(self):
        for s in self._socks:
            try:
                s.close()
            except Exception:
                pass
        for t in self._threads:
            t.join(timeout=2)


@pytest.fixture
def harness(tmp_path):
    """提供一个开箱即用的 ServerHarness，测试结束自动清理。"""
    h = ServerHarness(str(tmp_path / "test.db"))
    yield h
    h.stop()


# ============================================================
# 共享工具：同进程真实 TCP 测试服务器（无 SSL，用于 E2E / async）
# ============================================================

class InProcessTCPServer:
    """在同进程中以线程方式启动的真实 TCP 测试服务器（跳过 SSL）。

    用于 E2E 与 pytest-asyncio 异步测试：客户端通过真实 loopback
    TCP 连接，服务端 handle_client 在独立线程中处理，最大程度
    还原生产网络路径。
    """

    def __init__(self, db_path):
        assert Server is not None, "Server 模块导入失败"
        self._tmpdir = os.path.dirname(db_path)
        self.db = create_test_db(db_path, with_admin=True)
        self.port = self._find_free_port()
        self.server = Server(port=self.port)
        self.server.db = self.db
        self._running = False
        self._thread = None
        self._server_socket = None

    @staticmethod
    def _find_free_port():
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        return port

    def start(self):
        self._server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._server_socket.bind(("127.0.0.1", self.port))
        self._server_socket.listen(20)
        self._server_socket.settimeout(1.0)
        self._running = True

        class _NoSSL:
            def wrap_socket(self, sock, server_side=False):
                return sock

        ctx = _NoSSL()

        def accept_loop():
            while self._running:
                try:
                    client_sock, _ = self._server_socket.accept()
                    threading.Thread(
                        target=self.server.client_handler.handle_client,
                        args=(client_sock, ("127.0.0.1", 0), ctx),
                        daemon=True,
                    ).start()
                except socket.timeout:
                    continue
                except Exception:
                    if self._running:
                        continue
                    break

        self._thread = threading.Thread(target=accept_loop, daemon=True)
        self._thread.start()
        time.sleep(0.2)

    def stop(self):
        self._running = False
        if self._server_socket:
            try:
                self._server_socket.close()
            except Exception:
                pass
        if self._thread:
            self._thread.join(timeout=3)


@pytest.fixture
def tcp_server(tmp_path):
    """提供一个真实 loopback TCP 测试服务器，自动启停。"""
    srv = InProcessTCPServer(str(tmp_path / "tcp_test.db"))
    srv.start()
    yield srv
    srv.stop()
