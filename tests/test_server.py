"""
============================================================
服务端集成测试
============================================================

【测试目标】
  验证服务端各个 handler 在真实消息流转下的正确性。
  包括：认证、私聊、好友、群组、文件传输、消息撤回、管理员命令。

【测试策略】
  1. 使用独立的临时数据库（不污染真实环境）
  2. 用 socket.socketpair() 模拟客户端连接
  3. Mock SSL 层（patch context.wrap_socket 使其返回原始 socket）
  4. 一个线程运行 handle_client，另一个线程模拟客户端发/收消息
  5. 预先在数据库中创建测试用户和好友关系

【架构说明】
  测试流程：
    ┌─────────────┐         ┌─────────────┐
    │ 测试代码      │ send    │ s1(socket)  │
    │ (模拟客户端)  │◄───────►│             │ ← handle_client 线程
    │             │ recv    │ s2(socket)  │
    └─────────────┘         └──────┬──────┘
                                   │
                            ┌──────▼──────┐
                            │   Server    │
                            │  (test db)  │
                            └─────────────┘

【注意】
  - 每次测试后需要等待线程结束，避免 socket 泄露
  - 消息顺序很重要：login → 初始数据 → 用户命令 → 响应
"""

import sys
import os
import socket
import ssl
import threading
import json
import time
import pytest
import bcrypt
import uuid
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from database import Database
from server.server_main import Server
from protocol import send_message, recv_message


TEST_ADMIN_SECRET = "test-admin-secret"


# ============================================================
# 全局辅助：初始化测试数据库
# ============================================================

def create_test_db(db_path):
    """
    创建一个预填充了测试用户的数据库。
    
    测试用用户：
    - alice / password123  （普通用户）
    - bob   / password456  （普通用户）
    - admin / adminpass    （管理员）
    
    预置好友关系：alice <-> bob
    """
    os.environ["CHATROOM_ADMIN_SECRET"] = TEST_ADMIN_SECRET
    db = Database(db_path)

    # 创建用户
    db.add_user("alice", bcrypt.hashpw("password123".encode(), bcrypt.gensalt()))
    db.add_user("bob", bcrypt.hashpw("password456".encode(), bcrypt.gensalt()))
    db.add_user("admin", bcrypt.hashpw("adminpass".encode(), bcrypt.gensalt()))

    # 设置 admin 为管理员（需要直接操作 SQLite）
    with db._get_connection() as conn:
        conn.execute("UPDATE users SET is_admin = 1 WHERE username = 'admin'")
        conn.commit()

    # alice 和 bob 已是好友
    db.add_friend_request("alice", "bob")
    db.accept_friend_request("alice", "bob")

    return db


# ============================================================
# 辅助函数：创建模拟的客户端连接
# ============================================================

def start_mock_client(server, s1, db_path):
    """
    在一个新线程中启动 handle_client 处理 s1 端。
    
    为什么需要 patch：
      handle_client 内部会调用 context.wrap_socket(sock, server_side=True)
      对普通 socket 做 SSL 包装会失败。
      我们用 unittest.mock.patch 拦截 SSLContext.wrap_socket 调用，
      让它直接返回原始 socket（等同于不加 SSL）。
    
    参数：
      - server: Server 实例
      - s1: socketpair 的一端（服务端）
      - db_path: 测试数据库路径（用来替换 server.db）
    """
    server.db = Database(db_path)

    def run():
        # Mock SSL: wrap_socket 不包装，直接返回 socket
        with patch.object(ssl.SSLContext, 'wrap_socket', return_value=s1):
            server.client_handler.handle_client(s1, ('127.0.0.1', 12345),
                                                ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER))

    t = threading.Thread(target=run)
    t.daemon = True
    t.start()
    # 给线程一点时间启动
    time.sleep(0.05)
    return t


# ============================================================
# 辅助函数：等待并验证响应消息
# ============================================================

def expect_response(sock, expected_type, timeout=3):
    """
    从 sock 读取一条消息，验证其 type 匹配。
    返回 (header, data)。
    
    参数：
      - sock: 客户端 socket
      - expected_type: 期望的消息类型（如 'chat', 'error' 等）
      - timeout: 超时秒数
    """
    sock.settimeout(timeout)
    try:
        header, data = recv_message(sock)
        if header is None:
            raise Exception("连接已关闭（收到空消息）")
        # 不在此处 assert，让调用者做更灵活的检查
        return header, data
    except socket.timeout:
        pytest.fail(f"超时：等待消息类型 '{expected_type}' 超过 {timeout}s")


def recv_all_initial_data(sock):
    """
    登录后接收服务器推送的初始数据：
    1. 登录成功响应（chat 或 admin_auth）
    2. 离线消息（chat/file/group_chat, history=true）— 0或多条
    3. 文件请求（file_request/group_file_request）— 0或多条
    4. 好友请求（friend_request）— 0或多条
    5. 好友列表（admin_response, response_type=list_friends）
    6. 群组列表（list_groups）
    
    返回一个 dict 方便后续测试使用。
    """
    result = {
        "login_response": None,
        "friends": [],
        "groups": [],
        "offline": [],
        "friend_requests": [],
    }

    # 第 1 条：登录响应（普通用户是 'chat'，管理员是 'admin_auth'）
    sock.settimeout(3)
    try:
        h, d = recv_message(sock)
        if h is None:
            raise Exception("连接已关闭")
        result["login_response"] = (h, d)
        # 验证登录成功
        assert h["type"] in ("chat", "admin_auth"), \
            f"期望 chat 或 admin_auth，收到 {h['type']}: {d.decode() if d else ''}"
    except socket.timeout:
        pytest.fail("超时：等待登录响应超过 3s")

    # 接收后续初始数据（离线消息/文件请求/好友请求/好友列表/群组列表）
    got_friends = False
    got_groups = False
    for _ in range(50):
        try:
            h, d = expect_response(sock, "initial_data", timeout=3)
        except Exception:
            break
        t = h.get("type")
        if h.get("history") == "true":
            result["offline"].append((h, d))
        elif t == "file_request":
            result.setdefault("file_requests", []).append((h, d))
        elif t == "group_file_request":
            result.setdefault("group_file_requests", []).append((h, d))
        elif t == "friend_request":
            result["friend_requests"].append((h, d))
        elif t == "admin_response" and h.get("response_type") == "list_friends":
            result["friends"] = json.loads(d.decode()) if d else []
            got_friends = True
        elif t == "list_groups":
            result["groups"] = json.loads(d.decode()) if d else []
            got_groups = True
        else:
            result.setdefault("extra", []).append((h, d))
        if got_friends and got_groups:
            break

    return result


# ============================================================
# 第 1 组：认证测试（登录/注册）
# ============================================================

class TestAuthentication:
    """
    【认证流程测试】
    
    测试各种登录/注册场景。
    """

    def test_login_success(self, tmp_path):
        """
        【测试51】正常登录流程
        
        验证点：
        1. 登录成功收到 'chat' 类型的响应
        2. 响应内容为 '登录成功'
        3. 随后收到好友列表（alice 的好友 bob）
        4. 随后收到群组列表（空）
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

            initial = recv_all_initial_data(s2)

            # 验证登录响应
            assert initial["login_response"][0]["type"] == "chat"
            assert "登录成功" in initial["login_response"][1].decode()

            # 验证好友列表中有 bob
            assert len(initial["friends"]) == 1
            assert initial["friends"][0] == "bob"  # username

            # 群组列表为空
            assert initial["groups"] == []

            # 清理：关闭连接让 handle_client 线程退出
            s2.close()
            t.join(timeout=2)

        finally:
            s1.close()
            # s2 already closed above
            if not s2._closed:
                s2.close()

    def test_login_admin(self, tmp_path):
        """
        【测试52】管理员登录
        
        验证点：
        1. 管理员收到 'admin_auth' 类型的响应
        2. 后续可执行管理命令
        """
        db_path = str(tmp_path / "test.db")
        create_test_db(db_path)

        server = Server()
        s1, s2 = socket.socketpair()

        try:
            t = start_mock_client(server, s1, db_path)

            send_message(s2, "login", "admin",
                         extra_headers={"password": "adminpass", "admin_secret": TEST_ADMIN_SECRET})

            # 管理员登录的第一个响应是 admin_auth，不是 chat
            h, d = expect_response(s2, "admin_auth")
            assert h["type"] == "admin_auth"

            # 清理
            s2.close()
            t.join(timeout=2)

        finally:
            s1.close()

    def test_login_admin_requires_secret(self, tmp_path):
        """管理员账号缺少二次密钥时应拒绝登录。"""
        db_path = str(tmp_path / "test.db")
        create_test_db(db_path)

        server = Server()
        s1, s2 = socket.socketpair()

        try:
            t = start_mock_client(server, s1, db_path)

            send_message(s2, "login", "admin",
                         extra_headers={"password": "adminpass"})

            h, d = expect_response(s2, "error")
            assert h["type"] == "error"
            assert "管理员密钥" in d.decode()

            s2.close()
            t.join(timeout=2)

        finally:
            s1.close()

    def test_login_admin_rejects_wrong_secret(self, tmp_path):
        """管理员账号二次密钥错误时应拒绝登录。"""
        db_path = str(tmp_path / "test.db")
        create_test_db(db_path)

        server = Server()
        s1, s2 = socket.socketpair()

        try:
            t = start_mock_client(server, s1, db_path)

            send_message(s2, "login", "admin",
                         extra_headers={"password": "adminpass", "admin_secret": "wrong"})

            h, d = expect_response(s2, "error")
            assert h["type"] == "error"
            assert "管理员密钥" in d.decode()

            s2.close()
            t.join(timeout=2)

        finally:
            s1.close()

    def test_login_wrong_password(self, tmp_path):
        """
        【测试53】密码错误时应收到 error 响应
        
        验证点：服务器拒绝连接，返回错误消息
        """
        db_path = str(tmp_path / "test.db")
        create_test_db(db_path)

        server = Server()
        s1, s2 = socket.socketpair()

        try:
            t = start_mock_client(server, s1, db_path)

            send_message(s2, "login", "alice",
                         extra_headers={"password": "wrongpassword"})

            h, d = expect_response(s2, "error")
            assert h["type"] == "error"
            assert "密码错误" in d.decode()

            s2.close()
            t.join(timeout=2)

        finally:
            s1.close()

    def test_login_nonexistent_user(self, tmp_path):
        """
        【测试54】登录不存在的用户
        
        验证点：返回 '用户不存在' 错误
        """
        db_path = str(tmp_path / "test.db")
        create_test_db(db_path)

        server = Server()
        s1, s2 = socket.socketpair()

        try:
            t = start_mock_client(server, s1, db_path)

            send_message(s2, "login", "ghost_user",
                         extra_headers={"password": "whatever"})

            h, d = expect_response(s2, "error")
            assert h["type"] == "error"
            assert "不存在" in d.decode()

            s2.close()
            t.join(timeout=2)

        finally:
            s1.close()

    def test_register_new_user(self, tmp_path):
        """
        【测试55】注册新用户
        
        验证点：
        1. 注册成功收到 'chat' 响应
        2. 之后可以用这个账号登录
        """
        db_path = str(tmp_path / "test.db")
        create_test_db(db_path)

        server = Server()
        s1, s2 = socket.socketpair()

        try:
            t = start_mock_client(server, s1, db_path)

            send_message(s2, "register", "new_user",
                         extra_headers={"password": "newpass"})

            h, d = expect_response(s2, "chat")
            assert "注册成功" in d.decode()

            s2.close()
            t.join(timeout=2)

            # 验证可以用新账号登录
            s3, s4 = socket.socketpair()
            try:
                t2 = start_mock_client(server, s3, db_path)
                send_message(s4, "login", "new_user",
                             extra_headers={"password": "newpass"})
                h, d = expect_response(s4, "chat")
                assert "登录成功" in d.decode()

                s4.close()
                t2.join(timeout=2)
            finally:
                s3.close()

        finally:
            s1.close()

    def test_register_duplicate_user(self, tmp_path):
        """
        【测试56】注册已存在的用户名
        
        验证点：返回 '用户已存在' 错误
        """
        db_path = str(tmp_path / "test.db")
        create_test_db(db_path)

        server = Server()
        s1, s2 = socket.socketpair()

        try:
            t = start_mock_client(server, s1, db_path)

            send_message(s2, "register", "alice",
                         extra_headers={"password": "newpass"})

            h, d = expect_response(s2, "error")
            assert "已存在" in d.decode()

            s2.close()
            t.join(timeout=2)

        finally:
            s1.close()


# ============================================================
# 第 2 组：私聊消息测试
# ============================================================

class TestPrivateChat:
    """
    【私聊消息测试】
    
    测试好友之间发送消息的完整流程。
    alice 和 bob 在测试数据库中已预置为好友。
    """

    def test_chat_to_friend(self, tmp_path):
        """
        【测试57】向在线好友发消息
        
        流程：
        1. alice 登录
        2. alice 向 bob 发送一条私聊消息
        3. 因为 bob 不在线，服务器应回复 '离线，消息已保存'
        
        验证点：消息被正确保存为离线消息
        """
        db_path = str(tmp_path / "test.db")
        db = create_test_db(db_path)

        server = Server()
        s1, s2 = socket.socketpair()

        try:
            t = start_mock_client(server, s1, db_path)

            # alice 登录
            send_message(s2, "login", "alice",
                         extra_headers={"password": "password123"})
            recv_all_initial_data(s2)  # 消费初始数据

            # alice 发消息给 bob
            msg_id = str(uuid.uuid4())
            send_message(s2, "chat", "Hello Bob!",
                         extra_headers={"to": "bob", "message_id": msg_id})

            # 因为 bob 不在线，服务器回复离线保存
            h, d = expect_response(s2, "chat")
            # 验证服务器确实保存了离线消息
            info = db.get_message_info(msg_id)
            assert info is not None, "消息应该被保存到离线消息表"
            assert info[0] == "alice"   # sender
            assert info[1] == "bob"     # receiver

            s2.close()
            t.join(timeout=2)

        finally:
            s1.close()

    def test_chat_to_non_friend_is_blocked(self, tmp_path):
        """
        【测试58】向非好友发消息应被阻止
        
        验证点：服务器返回错误，不会转发消息
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
            recv_all_initial_data(s2)

            # alice 向 admin 发消息（admin 不是 alice 的好友）
            send_message(s2, "chat", "Hi admin!",
                         extra_headers={"to": "admin", "message_id": str(uuid.uuid4())})

            h, d = expect_response(s2, "error")
            assert "不是您的好友" in d.decode()

            s2.close()
            t.join(timeout=2)

        finally:
            s1.close()

    def test_offline_message_delivery_on_login(self, tmp_path):
        """
        【测试59】离线消息在登录时被正确投递
        
        流程：
        1. alice 登录 → 向 bob 发消息（bob 离线）
        2. alice 退出
        3. bob 登录 → 应收到 alice 的离线消息
        
        验证点：bob 登录后收到标记为历史的消息
        """
        db_path = str(tmp_path / "test.db")
        create_test_db(db_path)

        server = Server()
        msg_id = str(uuid.uuid4())

        # 第一阶段：alice 发消息给离线的 bob
        s1, s2 = socket.socketpair()
        try:
            t = start_mock_client(server, s1, db_path)
            send_message(s2, "login", "alice",
                         extra_headers={"password": "password123"})
            recv_all_initial_data(s2)
            send_message(s2, "chat", "Offline message test!",
                         extra_headers={"to": "bob", "message_id": msg_id})
            expect_response(s2, "chat")  # "用户离线" 消息
            s2.close()
            t.join(timeout=2)
        finally:
            s1.close()

        # 第二阶段：bob 登录接收离线消息
        s3, s4 = socket.socketpair()
        try:
            t2 = start_mock_client(server, s3, db_path)
            send_message(s4, "login", "bob",
                         extra_headers={"password": "password456"})

            # 第 1 条：登录成功
            h, d = expect_response(s4, "chat")
            assert "登录成功" in d.decode()

            # 第 2 条：离线消息（history=true）
            h, d = expect_response(s4, "chat")
            assert h.get("history") == "true", "离线消息应有 history=true 标记"
            assert "Offline message test!" in d.decode()
            assert h.get("from") == "alice"

            s4.close()
            t2.join(timeout=2)
        finally:
            s3.close()


# ============================================================
# 第 3 组：好友系统测试
# ============================================================

class TestFriendOperations:
    """
    【好友系统集成测试】
    
    测试好友请求的完整流程。
    """

    def test_friend_request_and_accept(self, tmp_path):
        """
        【测试60】完整的好友请求 → 接受流程
        
        流程：
        1. alice 登录，向 admin 发好友请求
        2. alice 退出
        3. admin 登录，查看待处理请求，接受
        4. 双方成为好友
        
        验证点：admin 收到好友请求通知，alice 被告知请求已接受
        """
        db_path = str(tmp_path / "test.db")
        db = create_test_db(db_path)

        server = Server()

        # alice 发送好友请求给 admin
        s1, s2 = socket.socketpair()
        try:
            t = start_mock_client(server, s1, db_path)
            send_message(s2, "login", "alice",
                         extra_headers={"password": "password123"})
            recv_all_initial_data(s2)

            send_message(s2, "friend_request", "",
                         extra_headers={"to": "admin"})

            # alice 收到确认
            h, d = expect_response(s2, "chat")
            assert "好友请求已发送" in d.decode()
            s2.close()
            t.join(timeout=2)
        finally:
            s1.close()

        # 验证：此时 alice 和 admin 还不是好友（请求还是 pending）
        assert db.is_friend("alice", "admin") is False
        assert db.get_pending_friend_requests("admin") == ["alice"]

        # admin 登录并接受好友请求
        s3, s4 = socket.socketpair()
        try:
            t2 = start_mock_client(server, s3, db_path)
            send_message(s4, "login", "admin",
                         extra_headers={"password": "adminpass", "admin_secret": TEST_ADMIN_SECRET})

            # 接收初始数据（含 alice 的好友请求推送）
            initial = recv_all_initial_data(s4)

            # 验证 admin 收到了 alice 的好友请求推送
            fr_senders = [h.get("from") for h, d in initial["friend_requests"]]
            assert "alice" in fr_senders, f"应在初始数据中收到 alice 的好友请求，收到: {fr_senders}"

            # admin 查看好友请求列表
            send_message(s4, "list_friend_requests", "")
            h, d = expect_response(s4, "list_friend_requests")
            requests = json.loads(d.decode())
            assert "alice" in requests

            # admin 接受 alice 的好友请求
            send_message(s4, "accept_friend", "",
                         extra_headers={"from": "alice"})

            h, d = expect_response(s4, "chat")
            assert "已接受" in d.decode()

            s4.close()
            t2.join(timeout=2)
        finally:
            s3.close()

        # 验证：现在他们是好友了
        assert db.is_friend("alice", "admin") is True

    def test_friend_request_reject(self, tmp_path):
        """
        【测试61】拒绝好友请求
        
        验证点：拒绝后请求被删除，双方不是好友
        """
        db_path = str(tmp_path / "test.db")
        db = create_test_db(db_path)

        server = Server()

        # alice 发请求
        s1, s2 = socket.socketpair()
        try:
            t = start_mock_client(server, s1, db_path)
            send_message(s2, "login", "alice",
                         extra_headers={"password": "password123"})
            recv_all_initial_data(s2)
            send_message(s2, "friend_request", "",
                         extra_headers={"to": "admin"})
            expect_response(s2, "chat")
            s2.close()
            t.join(timeout=2)
        finally:
            s1.close()

        # admin 登录并拒绝
        s3, s4 = socket.socketpair()
        try:
            t2 = start_mock_client(server, s3, db_path)
            send_message(s4, "login", "admin",
                         extra_headers={"password": "adminpass", "admin_secret": TEST_ADMIN_SECRET})
            recv_all_initial_data(s4)

            send_message(s4, "reject_friend", "",
                         extra_headers={"from": "alice"})

            h, d = expect_response(s4, "chat")
            assert "已拒绝" in d.decode()

            s4.close()
            t2.join(timeout=2)
        finally:
            s3.close()

        # 验证：不是好友，也没有待处理请求
        assert db.is_friend("alice", "admin") is False
        assert db.get_pending_friend_requests("admin") == []


# ============================================================
# 第 4 组：群组测试
# ============================================================

class TestGroupOperations:
    """
    【群组集成测试】
    
    测试群组的创建、加入、群聊。
    """

    def test_create_group(self, tmp_path):
        """
        【测试62】创建群组
        
        验证点：
        1. 创建成功，服务器返回群组名称和 ID
        2. 创建者自动成为成员
        """
        db_path = str(tmp_path / "test.db")
        db = create_test_db(db_path)

        server = Server()
        s1, s2 = socket.socketpair()

        try:
            t = start_mock_client(server, s1, db_path)
            send_message(s2, "login", "alice",
                         extra_headers={"password": "password123"})
            recv_all_initial_data(s2)

            send_message(s2, "create_group", "测试群组")

            h, d = expect_response(s2, "chat")
            response_text = d.decode()
            assert "创建成功" in response_text
            assert "测试群组" in response_text

            # 验证群组在数据库中存在
            groups = db.get_user_groups("alice")
            assert len(groups) == 1
            assert groups[0][1] == "测试群组"

            s2.close()
            t.join(timeout=2)

        finally:
            s1.close()

    def test_join_group(self, tmp_path):
        """
        【测试63】加入群组并发送群聊消息
        
        流程：
        1. alice 创建群组
        2. bob 加入（需要知道群组 ID）
        3. alice 发群聊消息
        4. 验证消息被路由到 bob
        
        验证点：bob 能收到群聊消息
        """
        db_path = str(tmp_path / "test.db")
        db = create_test_db(db_path)

        server = Server()

        # alice 创建群组
        s1, s2 = socket.socketpair()
        try:
            t = start_mock_client(server, s1, db_path)
            send_message(s2, "login", "alice",
                         extra_headers={"password": "password123"})
            recv_all_initial_data(s2)

            send_message(s2, "create_group", "开发群")
            h, d = expect_response(s2, "chat")
            # 从响应中提取 group_id（格式："群组 开发群 创建成功，ID: 1"）
            response_text = d.decode()
            # 获取群组 ID
            groups = db.get_user_groups("alice")
            group_id = groups[0][0]

            s2.close()
            t.join(timeout=2)
        finally:
            s1.close()

        # bob 加入群组并收发消息
        s3, s4 = socket.socketpair()
        try:
            t2 = start_mock_client(server, s3, db_path)
            send_message(s4, "login", "bob",
                         extra_headers={"password": "password456"})
            recv_all_initial_data(s4)  # 消费登录数据

            # bob 加入群组
            send_message(s4, "join_group", str(group_id))
            h, d = expect_response(s4, "chat")
            assert "已加入群组" in d.decode()

            s4.close()
            t2.join(timeout=2)
        finally:
            s3.close()

        # 验证 bob 现在是群成员
        assert db.is_group_member(group_id, "bob") is True

    def test_group_chat_message_routing(self, tmp_path):
        """
        【测试64】群聊消息路由到全部在线成员
        
        流程：
        1. alice 创建群组，bob 加入
        2. alice 和 bob 同时在线
        3. alice 发群聊消息
        4. bob 应收到此消息
        
        注意：需要两个客户端同时在线
        """
        db_path = str(tmp_path / "test.db")
        db = create_test_db(db_path)

        server = Server()

        # 先创建群组
        s_admin, s_admin_cli = socket.socketpair()
        try:
            t_admin = start_mock_client(server, s_admin, db_path)
            send_message(s_admin_cli, "login", "alice",
                         extra_headers={"password": "password123"})
            recv_all_initial_data(s_admin_cli)

            send_message(s_admin_cli, "create_group", "聊天群")
            h, d = expect_response(s_admin_cli, "chat")
            groups = db.get_user_groups("alice")
            group_id = groups[0][0]

            s_admin_cli.close()
            t_admin.join(timeout=2)
        finally:
            s_admin.close()

        # bob 加入群组
        s_bob, s_bob_cli = socket.socketpair()
        try:
            t_bob = start_mock_client(server, s_bob, db_path)
            send_message(s_bob_cli, "login", "bob",
                         extra_headers={"password": "password456"})
            recv_all_initial_data(s_bob_cli)
            send_message(s_bob_cli, "join_group", str(group_id))
            expect_response(s_bob_cli, "chat")  # 加入响应

            # 消费掉 bob 的群组列表更新消息
            # (join_group 会触发 list_groups 推送)
            try:
                s_bob_cli.settimeout(1)
                recv_message(s_bob_cli)  # 可能是 list_groups 或群组通知
            except socket.timeout:
                pass  # 没有更多消息也没关系
            s_bob_cli.close()
            t_bob.join(timeout=2)
        finally:
            s_bob.close()

        # alice 和 bob 同时在线并发群聊消息
        s1, s_alice_cli = socket.socketpair()
        s2, s_bob_cli2 = socket.socketpair()

        try:
            # alice 登录
            t1 = start_mock_client(server, s1, db_path)
            send_message(s_alice_cli, "login", "alice",
                         extra_headers={"password": "password123"})
            recv_all_initial_data(s_alice_cli)

            # bob 登录
            t2 = start_mock_client(server, s2, db_path)
            send_message(s_bob_cli2, "login", "bob",
                         extra_headers={"password": "password456"})
            recv_all_initial_data(s_bob_cli2)

            # alice 发群聊消息
            msg_id = str(uuid.uuid4())
            send_message(s_alice_cli, "group_chat", "大家好！",
                         extra_headers={"group_id": str(group_id),
                                        "message_id": msg_id})

            # bob 应收到群聊消息（服务端不再回发"已发送"确认给 alice）
            h_bob, d_bob = expect_response(s_bob_cli2, "group_chat")
            assert h_bob.get("from") == "alice"
            assert h_bob.get("group_id") == str(group_id)
            assert "大家好！" in d_bob.decode()

            # 关闭
            s_alice_cli.close()
            s_bob_cli2.close()
            t1.join(timeout=2)
            t2.join(timeout=2)

        finally:
            s1.close()
            s2.close()


# ============================================================
# 第 5 组：管理员命令测试
# ============================================================

class TestAdminCommands:
    """
    【管理员命令集成测试】
    
    测试管理员特权操作：列出用户、发送公告。
    """

    def test_admin_list_users(self, tmp_path):
        """
        【测试65】管理员查看所有用户列表
        
        验证点：返回的用户列表包含所有注册用户及其在线状态
        """
        db_path = str(tmp_path / "test.db")
        create_test_db(db_path)

        server = Server()
        s1, s2 = socket.socketpair()

        try:
            t = start_mock_client(server, s1, db_path)
            send_message(s2, "login", "admin",
                         extra_headers={"password": "adminpass", "admin_secret": TEST_ADMIN_SECRET})

            # 消费初始数据（管理员登录响应是 admin_auth，不适用于 recv_all_initial_data）
            h, _ = expect_response(s2, "admin_auth")
            # 好友列表
            h_fr, _ = expect_response(s2, "admin_response")
            # 群组列表
            expect_response(s2, "list_groups")

            # admin 请求用户列表
            send_message(s2, "admin_command", "",
                         extra_headers={"action": "list_users"})

            h, d = expect_response(s2, "admin_response")
            assert h.get("response_type") == "list_users"

            users = json.loads(d.decode())
            usernames = {u[0] for u in users}
            assert "alice" in usernames
            assert "bob" in usernames
            assert "admin" in usernames

            s2.close()
            t.join(timeout=2)

        finally:
            s1.close()

    def test_admin_send_announcement(self, tmp_path):
        """
        【测试66】管理员发送公告
        
        验证点：管理员收到 '公告发送成功'，在线用户收到公告
        """
        db_path = str(tmp_path / "test.db")
        create_test_db(db_path)

        server = Server()

        # alice 也同时在线
        s_alice, s_alice_cli = socket.socketpair()
        s_admin, s_admin_cli = socket.socketpair()

        try:
            # alice 登录
            t_alice = start_mock_client(server, s_alice, db_path)
            send_message(s_alice_cli, "login", "alice",
                         extra_headers={"password": "password123"})
            recv_all_initial_data(s_alice_cli)

            # admin 登录
            t_admin = start_mock_client(server, s_admin, db_path)
            send_message(s_admin_cli, "login", "admin",
                         extra_headers={"password": "adminpass", "admin_secret": TEST_ADMIN_SECRET})
            expect_response(s_admin_cli, "admin_auth")
            # 好友列表
            expect_response(s_admin_cli, "admin_response")
            # 群组列表
            expect_response(s_admin_cli, "list_groups")

            # admin 发公告
            send_message(s_admin_cli, "admin_command", "系统维护通知",
                         extra_headers={"action": "announcement"})

            # admin 首先收到自己被广播的公告（因为 admin 也在 client_map 中）
            h_echo, d_echo = expect_response(s_admin_cli, "chat")
            # 然后是 '公告发送成功'
            h, d = expect_response(s_admin_cli, "chat")
            assert "公告发送成功" in d.decode(), f"期望'公告发送成功'，收到: {d.decode()}"

            # alice 收到公告（from = '[系统公告]'）
            h_alice, d_alice = expect_response(s_alice_cli, "chat")
            assert h_alice.get("from") == "[系统公告]"
            assert "系统维护通知" in d_alice.decode()

            s_alice_cli.close()
            s_admin_cli.close()
            t_alice.join(timeout=2)
            t_admin.join(timeout=2)

        finally:
            s_alice.close()
            s_admin.close()


# ============================================================
# 第 6 组：离线功能全链路测试
# ============================================================

class TestOfflineFeatures:
    """
    【离线功能集成测试】
    
    测试离线补发机制：用户离线期间发生的操作（好友请求、接受通知、公告、撤回）
    在用户重新登录后应正确推送。
    """

    def test_offline_friend_request_delivered_on_login(self, tmp_path):
        """
        【测试OFF-1】离线好友请求在登录时推送
        
        流程：B 离线 → A 向 B 发好友请求 → B 登录 → B 收到 friend_request 推送
        """
        db_path = str(tmp_path / "test.db")
        db = create_test_db(db_path)
        server = Server()

        # 创建用户 charlie（离线用户）
        db.add_user("charlie", bcrypt.hashpw("pass456".encode(), bcrypt.gensalt()))

        # alice 登录，向 charlie 发好友请求
        s1, s2 = socket.socketpair()
        try:
            t = start_mock_client(server, s1, db_path)
            send_message(s2, "login", "alice",
                         extra_headers={"password": "password123"})
            recv_all_initial_data(s2)

            send_message(s2, "friend_request", "",
                         extra_headers={"to": "charlie"})
            h, d = expect_response(s2, "chat")
            assert "好友请求已发送" in d.decode()
            s2.close()
            t.join(timeout=2)
        finally:
            s1.close()

        # charlie 登录，应收到 alice 的好友请求推送
        s3, s4 = socket.socketpair()
        try:
            t2 = start_mock_client(server, s3, db_path)
            send_message(s4, "login", "charlie",
                         extra_headers={"password": "pass456"})
            initial = recv_all_initial_data(s4)

            # 验证 charlie 收到了 alice 的好友请求
            assert len(initial["friend_requests"]) >= 1, \
                f"应收到好友请求推送，收到: {initial['friend_requests']}"
            fr = initial["friend_requests"][0]
            assert fr[0].get("from") == "alice", \
                f"好友请求发送者应为 alice，收到: {fr[0].get('from')}"

            s4.close()
            t2.join(timeout=2)
        finally:
            s3.close()

    def test_offline_friend_accept_notification(self, tmp_path):
        """
        【测试OFF-2】好友接受通知在离线请求方登录时推送
        
        流程：A 发好友请求给 B → A 离线 → B 登录并接受 → A 登录 → A 收到接受通知
        """
        db_path = str(tmp_path / "test.db")
        db = create_test_db(db_path)
        server = Server()

        # 创建用户 dave
        db.add_user("dave", bcrypt.hashpw("pass789".encode(), bcrypt.gensalt()))

        # alice 登录，向 dave 发好友请求，然后 alice 离线
        s1, s2 = socket.socketpair()
        try:
            t = start_mock_client(server, s1, db_path)
            send_message(s2, "login", "alice",
                         extra_headers={"password": "password123"})
            recv_all_initial_data(s2)
            send_message(s2, "friend_request", "",
                         extra_headers={"to": "dave"})
            expect_response(s2, "chat")
            s2.close()
            t.join(timeout=2)
        finally:
            s1.close()

        # dave 登录并接受 alice 的好友请求
        s3, s4 = socket.socketpair()
        try:
            t2 = start_mock_client(server, s3, db_path)
            send_message(s4, "login", "dave",
                         extra_headers={"password": "pass789"})
            initial = recv_all_initial_data(s4)
            assert "alice" in [h.get("from") for h, d in initial["friend_requests"]]

            send_message(s4, "accept_friend", "",
                         extra_headers={"from": "alice"})
            h, d = expect_response(s4, "chat")
            assert "已接受" in d.decode()
            s4.close()
            t2.join(timeout=2)
        finally:
            s3.close()

        # alice 重新登录，应收到接受通知（作为离线消息）
        s5, s6 = socket.socketpair()
        try:
            t3 = start_mock_client(server, s5, db_path)
            send_message(s6, "login", "alice",
                         extra_headers={"password": "password123"})
            initial = recv_all_initial_data(s6)

            # 验证 alice 收到了 dave 的接受通知
            accept_found = False
            for h, d in initial["offline"]:
                if d and "已接受您的好友请求" in d.decode():
                    accept_found = True
                    break
            assert accept_found, \
                f"alice 应在离线消息中收到接受通知，离线消息: {[(h.get('type'), d.decode() if d else '') for h, d in initial['offline']]}"

            s6.close()
            t3.join(timeout=2)
        finally:
            s5.close()

    def test_offline_announcement_persisted(self, tmp_path):
        """
        【测试OFF-3】公告对离线用户持久化
        
        流程：alice 离线 → admin 发公告 → alice 登录 → alice 在系统消息中看到公告
        """
        db_path = str(tmp_path / "test.db")
        db = create_test_db(db_path)
        server = Server()

        # admin 登录并发送公告（alice 离线）
        s1, s2 = socket.socketpair()
        try:
            t = start_mock_client(server, s1, db_path)
            send_message(s2, "login", "admin",
                         extra_headers={"password": "adminpass", "admin_secret": TEST_ADMIN_SECRET})
            recv_all_initial_data(s2)

            send_message(s2, "admin_command", "紧急维护通知",
                         extra_headers={"action": "announcement"})
            # admin 自己收到广播的公告
            expect_response(s2, "chat")
            # 然后收到 "公告发送成功"
            h, d = expect_response(s2, "chat")
            assert "公告发送成功" in d.decode()

            s2.close()
            t.join(timeout=2)
        finally:
            s1.close()

        # alice 登录，应在离线消息中看到公告
        s3, s4 = socket.socketpair()
        try:
            t2 = start_mock_client(server, s3, db_path)
            send_message(s4, "login", "alice",
                         extra_headers={"password": "password123"})
            initial = recv_all_initial_data(s4)

            # 验证 alice 在离线消息中收到了公告
            announcement_found = False
            for h, d in initial["offline"]:
                if h.get("from") == "[系统公告]" and d and "紧急维护通知" in d.decode():
                    announcement_found = True
                    break
            assert announcement_found, \
                f"alice 应在离线消息中收到公告，离线消息: {[(h.get('from'), d.decode() if d else '') for h, d in initial['offline']]}"

            s4.close()
            t2.join(timeout=2)
        finally:
            s3.close()

    def test_offline_recall_placeholder(self, tmp_path):
        """
        【测试OFF-4】撤回消息对离线用户显示占位符
        
        流程：A 发消息给 B → B 离线 → A 撤回 → B 登录 → B 看到"撤回了一条消息"占位符
        """
        db_path = str(tmp_path / "test.db")
        db = create_test_db(db_path)
        server = Server()

        # alice 登录，向 bob 发消息，然后撤回（bob 离线）
        s1, s2 = socket.socketpair()
        try:
            t = start_mock_client(server, s1, db_path)
            send_message(s2, "login", "alice",
                         extra_headers={"password": "password123"})
            recv_all_initial_data(s2)

            msg_id = str(uuid.uuid4())
            send_message(s2, "chat", "测试消息", extra_headers={"to": "bob", "message_id": msg_id})
            # alice 收到 "离线消息已保存" 或类似
            time.sleep(0.3)

            # alice 撤回消息
            send_message(s2, "recall", "", extra_headers={"message_id": msg_id})

            s2.close()
            t.join(timeout=2)
        finally:
            s1.close()

        # bob 登录，应在离线消息中看到撤回占位符，而非原消息
        s3, s4 = socket.socketpair()
        try:
            t2 = start_mock_client(server, s3, db_path)
            send_message(s4, "login", "bob",
                         extra_headers={"password": "password456"})
            initial = recv_all_initial_data(s4)

            # 验证 bob 看到了撤回占位符
            recall_found = False
            original_found = False
            for h, d in initial["offline"]:
                text = d.decode('utf-8') if d else ""
                if "撤回了一条消息" in text:
                    recall_found = True
                if "测试消息" == text:
                    original_found = True
            assert recall_found, \
                f"bob 应在离线消息中看到撤回占位符，离线消息: {[d.decode('utf-8') if d else '' for h, d in initial['offline']]}"
            assert not original_found, \
                "bob 不应在离线消息中看到已撤回的原消息内容"

            s4.close()
            t2.join(timeout=2)
        finally:
            s3.close()
"""
运行所有集成测试:
  .venv/bin/python -m pytest tests/test_server.py -v

运行单个测试（例如只测登录）:
  .venv/bin/python -m pytest tests/test_server.py::TestAuthentication::test_login_success -v

显示详细日志（调试时非常有用）:
  .venv/bin/python -m pytest tests/test_server.py -v -s --log-cli-level=INFO

限制失败时显示完整输出:
  .venv/bin/python -m pytest tests/test_server.py -v --tb=long

!!! 测试注意事项 !!!
1. 服务端集成测试会真实调用 handle_client，但 SSL 被 mock 掉了。
2. 每个测试创建独立的临时数据库，不会影响真实 users.db。
3. 如果测试卡住不动，可能是 socket 超时或线程未退出——检查控制台日志。
4. 测试顺序不影响结果，每个测试完全独立。

完整运行所有测试（一键）:
  .venv/bin/python -m pytest tests/ -v
"""
