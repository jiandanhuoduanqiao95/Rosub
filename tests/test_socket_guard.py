"""
============================================================
pytest-socket 守护测试
============================================================

引入 pytest-socket 作为"防回归"安全网：对纯逻辑模块加载
`socket_disabled` 夹具后执行，若这些模块意外发起网络/ socket
调用，pytest-socket 会抛出 SocketBlockedError 使测试失败。

被守护的纯逻辑：
  - validation.py：用户名/密码格式校验（不应触网）
  - database.py：临时数据库上的 CRUD（不应触网）
  - config.py：配置加载（文件读取，不应触网）
  - protocol.py 编解码：通过内存 FakeSocket 验证往返，
    不创建任何真实 socket

注意：socket_disabled 会阻止 socket.socket/socketpair 等全部
socket 创建，因此本文件绝不使用真实 socket。
"""

import os
import sys
import pytest
from pytest_socket import SocketBlockedError

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from validation import validate_username, validate_password
from config import config
from protocol import send_message, recv_message


# ============================================================
# 内存 FakeSocket（不创建真实 socket）
# ============================================================

class FakeSocket:
    def __init__(self):
        self._buf = bytearray()

    def sendall(self, data):
        self._buf.extend(data)

    def recv(self, n):
        if n <= 0 or not self._buf:
            return b""
        chunk = bytes(self._buf[:n])
        del self._buf[:n]
        return chunk

    def close(self):
        self._buf.clear()


# ============================================================
# 第 1 组：validation 不触网
# ============================================================

@pytest.mark.guard
class TestValidationGuard:

    def test_validate_username_no_socket(self, socket_disabled):
        for name in ["alice", "a", "user_123", "ab", "valid-name-xyz"]:
            validate_username(name)

    def test_validate_password_no_socket(self, socket_disabled):
        for pw in ["123456", "", "password", "p@ss"]:
            validate_password(pw)


# ============================================================
# 第 2 组：database 临时库 CRUD 不触网
# ============================================================

@pytest.mark.guard
class TestDatabaseGuard:

    def test_db_crud_no_socket(self, socket_disabled, tmp_path):
        import bcrypt
        from database import Database
        db = Database(str(tmp_path / "guard.db"))
        db.add_user("alice", bcrypt.hashpw(b"pw", bcrypt.gensalt()))
        assert db.user_exists("alice")
        db.save_offline_message("alice", "bob", "chat", b"hi", message_id="m1")
        db.get_offline_messages("bob")
        db.update_message_status("m1", "recalled")
        db.get_message_info("m1")
        db.cleanup_delivered_messages("bob")

    def test_db_friends_groups_no_socket(self, socket_disabled, tmp_path):
        import bcrypt
        from database import Database
        db = Database(str(tmp_path / "guard2.db"))
        for n in ("a", "b"):
            db.add_user(n, bcrypt.hashpw(b"pw", bcrypt.gensalt()))
        db.add_friend_request("a", "b")
        db.accept_friend_request("a", "b")
        assert db.is_friend("a", "b")
        gid = db.create_group("g", "a")
        db.join_group(gid, "b")
        assert "b" in db.get_group_members(gid)


# ============================================================
# 第 3 组：config 加载不触网
# ============================================================

@pytest.mark.guard
class TestConfigGuard:

    def test_config_get_no_socket(self, socket_disabled):
        # reload 会重新读取 config.yaml（文件 IO，非 socket）
        config.reload()
        assert config.get("server.port") in (8090, "8090")
        assert config.get("protocol.version") == "1.0.0"
        assert config.get("security.admin_secret_env") == "CHATROOM_ADMIN_SECRET"


# ============================================================
# 第 4 组：protocol 编解码通过 FakeSocket 不触网
# ============================================================

@pytest.mark.guard
class TestProtocolGuard:

    def test_protocol_roundtrip_no_socket(self, socket_disabled):
        s = FakeSocket()
        try:
            send_message(s, "chat", "hello 在守护模式下发送",
                         extra_headers={"to": "bob", "message_id": "x1"})
            header, body = recv_message(s)
            assert header["type"] == "chat"
            assert body.decode("utf-8") == "hello 在守护模式下发送"
            assert header["to"] == "bob"
        finally:
            s.close()

    def test_protocol_binary_no_socket(self, socket_disabled):
        s = FakeSocket()
        try:
            data = bytes(range(256))
            send_message(s, "file", data, extra_headers={"filename": "f.bin"})
            header, body = recv_message(s)
            assert body == data
            assert header["filename"] == "f.bin"
        finally:
            s.close()


# ============================================================
# 第 5 组：守护夹具本身确实会拦截 socket 调用
# ============================================================

@pytest.mark.guard
class TestGuardEnforced:

    @pytest.mark.filterwarnings("ignore:A test tried to use socket.socket")
    def test_socket_disabled_blocks_socket_creation(self, socket_disabled):
        import socket
        with pytest.raises((SocketBlockedError, OSError, Exception)):
            socket.socketpair()