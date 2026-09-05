"""
============================================================
后端加固集成验证测试
============================================================

【测试目标】
  验证阶段 1 的 4 个功能已正确集成到运行时路径中，
  而不仅仅是作为"死代码"存在。

【测试策略】
  使用 socketpair + Mock SSL（与 test_server.py 相同策略），
  通过真实的 handle_client 流程验证：
  1. 消息发送后出现在 message_history 表中
  2. 无效用户名在注册时被 validation 拦截
  3. 过期文件请求能被清理
"""

import sys
import os
import socket
import ssl
import threading
import time
import json
import uuid
import pytest
import bcrypt
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from database import Database
from server.server_main import Server
from protocol import send_message, recv_message


def create_test_db(db_path):
    """创建预填充的测试数据库"""
    db = Database(db_path)
    db.add_user("alice", bcrypt.hashpw(b"password123", bcrypt.gensalt()))
    db.add_user("bob", bcrypt.hashpw(b"password456", bcrypt.gensalt()))
    # 预置好友关系
    db.add_friend_request("alice", "bob")
    db.accept_friend_request("alice", "bob")
    return db


def start_mock_client(server, s1, db_path):
    """启动 mock 客户端线程"""
    server.db = Database(db_path)

    def run():
        with patch.object(ssl.SSLContext, 'wrap_socket', return_value=s1):
            server.client_handler.handle_client(
                s1, ('127.0.0.1', 12345),
                ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            )

    t = threading.Thread(target=run)
    t.daemon = True
    t.start()
    time.sleep(0.05)
    return t


def drain_initial(sock, timeout=0.3):
    """消费登录后推送的初始数据"""
    sock.settimeout(timeout)
    results = []
    while True:
        try:
            h, d = recv_message(sock)
            if h is None:
                break
            results.append((h, d))
        except socket.timeout:
            break
        except OSError:
            break
    return results


# ============================================================
# 第 1 组：消息历史集成验证
# ============================================================

class TestMessageHistoryIntegration:
    """
    【集成验证】消息发送后必须出现在 message_history 表中

    这些测试通过真实的 handle_client → process_messages 路径发送消息，
    然后直接查询数据库验证 message_history 表中有对应记录。
    """

    def test_chat_message_appears_in_history(self, tmp_path):
        """
        【INT-01】私聊消息通过 process_messages 发送后，
        自动写入 message_history 表
        """
        db_path = str(tmp_path / "test.db")
        create_test_db(db_path)
        server = Server()
        s1, s2 = socket.socketpair()

        try:
            t = start_mock_client(server, s1, db_path)

            # alice 登录
            send_message(s2, "login", "alice",
                         extra_headers={"password": "password123"})
            drain_initial(s2)

            # alice 给 bob 发消息
            msg_id = str(uuid.uuid4())
            send_message(s2, "chat", "integration test message",
                         extra_headers={"to": "bob", "message_id": msg_id})

            # 消费响应
            drain_initial(s2, timeout=0.5)

            s2.close()
            t.join(timeout=2)

            # === 核心断言：message_history 表中有这条消息 ===
            db = Database(db_path)
            msgs = db.get_message_history(user="alice", with_user="bob")
            assert len(msgs) >= 1, "消息应该出现在 message_history 表中"
            found = any(m[4] == msg_id for m in msgs)
            assert found, f"message_history 中应该包含消息ID={msg_id}"

        finally:
            s1.close()

    def test_group_chat_appears_in_history(self, tmp_path):
        """
        【INT-02】群聊消息通过 GroupHandler 发送后，
        自动写入 message_history 表
        """
        db_path = str(tmp_path / "test.db")
        db = create_test_db(db_path)

        # 创建群组
        group_id = db.create_group("test_group", "alice")
        db.join_group(group_id, "bob")

        server = Server()
        s1, s2 = socket.socketpair()

        try:
            t = start_mock_client(server, s1, db_path)

            send_message(s2, "login", "alice",
                         extra_headers={"password": "password123"})
            drain_initial(s2)

            # alice 发群聊
            msg_id = str(uuid.uuid4())
            send_message(s2, "group_chat", "group integration test",
                         extra_headers={"group_id": str(group_id),
                                        "message_id": msg_id})
            drain_initial(s2, timeout=0.5)

            s2.close()
            t.join(timeout=2)

            # === 核心断言 ===
            db2 = Database(db_path)
            msgs = db2.get_message_history(user="alice", group_id=group_id)
            assert len(msgs) >= 1, "群聊消息应该出现在 message_history 中"
            found = any(m[4] == msg_id for m in msgs)
            assert found, f"message_history 中应该包含群聊消息ID={msg_id}"

        finally:
            s1.close()


# ============================================================
# 第 2 组：输入验证集成验证
# ============================================================

class TestValidationIntegration:
    """
    【集成验证】注册流程中无效用户名被 validation 拦截
    """

    def test_register_with_invalid_username_rejected(self, tmp_path):
        """
        【INT-03】包含非法字符的用户名在注册时被服务端拒绝

        测试 sql_injection 类型的用户名（含单引号）
        """
        db_path = str(tmp_path / "test.db")
        create_test_db(db_path)
        server = Server()
        s1, s2 = socket.socketpair()

        try:
            t = start_mock_client(server, s1, db_path)

            # 尝试用非法用户名注册
            send_message(s2, "register", "bad'name",
                         extra_headers={"password": "pass123"})

            h, d = recv_message(s2)
            assert h is not None, "应收到响应"
            assert h["type"] == "error", \
                f"非法用户名'bad'name'应被拒绝，实际收到 type={h['type']}"
            error_msg = d.decode()
            assert "非法" in error_msg or "只能包含" in error_msg, \
                f"错误消息应提示格式问题，实际: {error_msg}"

            s2.close()
            t.join(timeout=2)

        finally:
            s1.close()

    def test_register_with_short_username_rejected(self, tmp_path):
        """
        【INT-04】短于 3 字符的用户名在注册时被服务端拒绝
        """
        db_path = str(tmp_path / "test.db")
        create_test_db(db_path)
        server = Server()
        s1, s2 = socket.socketpair()

        try:
            t = start_mock_client(server, s1, db_path)

            send_message(s2, "register", "ab",
                         extra_headers={"password": "pass123456"})

            h, d = recv_message(s2)
            assert h["type"] == "error", \
                f"短用户名应被拒绝，实际收到 type={h['type']}"
            assert "少于" in d.decode() or "3" in d.decode(), \
                f"错误应提及长度限制，实际: {d.decode()}"

            s2.close()
            t.join(timeout=2)

        finally:
            s1.close()

    def test_register_with_valid_username_succeeds(self, tmp_path):
        """
        【INT-05】合法用户名能正常注册（验证不会误杀合法输入）
        """
        db_path = str(tmp_path / "test.db")
        create_test_db(db_path)
        server = Server()
        s1, s2 = socket.socketpair()

        try:
            t = start_mock_client(server, s1, db_path)

            send_message(s2, "register", "valid_user",
                         extra_headers={"password": "validpass123"})

            h, d = recv_message(s2)
            assert h["type"] == "chat", \
                f"合法用户名应注册成功，实际收到 type={h['type']}"

            # 消费初始数据
            drain_initial(s2, timeout=0.3)

            s2.close()
            t.join(timeout=2)

        finally:
            s1.close()


# ============================================================
# 第 3 组：文件清理集成验证
# ============================================================

class TestFileCleanupIntegration:
    """
    【集成验证】过期文件请求能被 cleanup_expired_file_requests 清理
    """

    def test_cleanup_removes_old_file_requests(self, tmp_path):
        """
        【INT-06】cleanup_expired_file_requests 删除过期的文件请求

        直接测试 database 方法（不需要服务端线程）
        """
        db_path = str(tmp_path / "test.db")
        db = Database(db_path)
        db.add_user("alice", bcrypt.hashpw(b"pw", bcrypt.gensalt()))
        db.add_user("bob", bcrypt.hashpw(b"pw", bcrypt.gensalt()))

        # 保存一个文件请求
        db.save_file_request("alice", "bob", "old_file.pdf", 100,
                             b"test content", "fr-old")

        # 手动把时间改到 30 天前
        from datetime import datetime, timedelta, UTC
        past_time = datetime.now(UTC) - timedelta(days=30)
        with db._get_connection() as conn:
            conn.execute(
                "UPDATE file_requests SET timestamp = ? WHERE message_id = ?",
                (past_time.strftime('%Y-%m-%d %H:%M:%S'), "fr-old")
            )
            conn.commit()

        # 清理
        deleted = db.cleanup_expired_file_requests(expire_days=7)
        assert deleted >= 1, f"应清理至少 1 个过期文件请求，实际清理 {deleted}"
        assert db.get_file_request("fr-old") is None

    def test_cleanup_keeps_recent_file_requests(self, tmp_path):
        """
        【INT-07】近期的文件请求不被清理
        """
        db_path = str(tmp_path / "test.db")
        db = Database(db_path)
        db.add_user("alice", bcrypt.hashpw(b"pw", bcrypt.gensalt()))
        db.add_user("bob", bcrypt.hashpw(b"pw", bcrypt.gensalt()))

        db.save_file_request("alice", "bob", "recent.pdf", 100,
                             b"content", "fr-recent")

        deleted = db.cleanup_expired_file_requests(expire_days=7)
        assert deleted == 0
        assert db.get_file_request("fr-recent") is not None


# ============================================================
# 运行方式
# ============================================================
"""
运行集成验证测试:
  .venv/bin/python -m pytest tests/test_backend_integration.py -v

运行全部测试（含集成验证）:
  .venv/bin/python -m pytest tests/ -v
"""
