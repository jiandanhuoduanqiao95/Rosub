"""
============================================================
服务端集成扩展测试 —— 补全覆盖缺口（阶段 A/D/E + 文件/管理员/撤回）
============================================================

test_server.py 已覆盖认证/私聊/好友/群聊/离线补发/撤回确认/历史分页。
本文件借助 conftest.harness 统一夹具，补充以下场景：
  - 文件传输：接受投递、拒绝、无权限、不存在的请求
  - 撤回：文件请求撤回、群聊撤回离线占位符（OFF-5）、
          撤回不存在消息（幂等）、重复撤回
  - 管理员：list_users 在线状态、delete_user、不能删除自己、
            非管理员越权、公告多端投递+离线持久化
  - 历史分页：group_id 拉取、非法 limit 回退默认、不存在的 before_message_id
  - 群组：重复创建、加入不存在/已在/非法 ID、群聊到不存在/非成员
  - 文件：未指定接收者、向不存在群组发文件
  - 其它：receipt/未知类型不崩溃、好友请求边界
"""

import os
import sys
import json
import time
import uuid
import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from protocol import send_message



# ============================================================
# 第 1 组：文件传输
# ============================================================

class TestFileTransfer:

    def test_file_accept_delivers_and_persists(self, harness):
        """alice 向 bob 发文件 → bob 接受 → bob 收到 file，历史与离线表记录。"""
        file_data = b"file-content-123"
        # alice 在线，bob 离线
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.drain(timeout=1)

        msg_id = str(uuid.uuid4())
        alice.send("file", file_data, to="bob", filename="doc.txt",
                   filesize=len(file_data), message_id=msg_id)
        alice.drain(timeout=0.6)  # bob 离线提示

        # 验证文件请求已入库
        assert harness.db.get_file_request(msg_id) is not None

        # bob 上线，接受文件
        bob = harness.client()
        bob.login("bob", "password456", consume=False)
        initial = bob.recv_initial()
        # bob 应收到待处理文件请求推送
        fr_ids = [h.get("message_id") for h, _ in initial["file_requests"]]
        assert msg_id in fr_ids

        bob.send("file_response", "", response="accept", message_id=msg_id, to="alice")
        # bob 应收到文件数据
        h, d = bob.expect("file", timeout=3)
        assert h.get("filename") == "doc.txt"
        assert d == file_data
        # 文件请求删除发生在服务端发送文件之后，需短暂等待服务端线程完成
        deadline = time.time() + 2
        while time.time() < deadline and harness.db.get_file_request(msg_id) is not None:
            time.sleep(0.05)
        assert harness.db.get_file_request(msg_id) is None
        # 历史表应有记录
        hist = harness.db.get_message_history("alice", with_user="bob")
        assert any(r[4] == msg_id for r in hist)

    def test_file_reject_deletes_request(self, harness):
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.drain(timeout=1)

        msg_id = str(uuid.uuid4())
        alice.send("file", b"payload", to="bob", filename="x.bin",
                   filesize=7, message_id=msg_id)
        alice.drain(timeout=0.5)

        bob = harness.client()
        bob.login("bob", "password456", consume=False)
        bob.recv_initial()
        bob.send("file_response", "", response="reject", message_id=msg_id, to="alice")

        # 拒绝后请求应被删除，且 bob 不应收到 file 数据
        time.sleep(0.3)
        assert harness.db.get_file_request(msg_id) is None

    def test_file_response_unauthorized(self, harness):
        """非接收者无权响应文件请求。"""
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.drain(timeout=1)
        msg_id = str(uuid.uuid4())
        alice.send("file", b"data", to="bob", filename="f", filesize=4, message_id=msg_id)
        alice.drain(timeout=0.5)

        # admin 上线（admin 不是该文件请求的接收者），尝试响应
        admin = harness.client()
        admin.login("admin", "adminpass", admin_secret="test-admin-secret", consume=False)
        admin.recv_initial()
        admin.send("file_response", "", response="accept", message_id=msg_id, to="alice")
        h, d = admin.expect("error", timeout=3)
        assert "无权限" in d.decode()

    def test_file_response_nonexistent(self, harness):
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("file_response", "", response="accept",
                   message_id="no-such-file", to="bob")
        h, d = alice.expect("error", timeout=3)
        assert "不存在" in d.decode()

    def test_file_no_target_rejected(self, harness):
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("file", b"data")  # 没有 to
        h, d = alice.expect("error", timeout=3)
        assert "未指定接收者" in d.decode()

    def test_file_to_nonexistent_group(self, harness):
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("file", b"data", to="group_9999", filename="f", filesize=4,
                   message_id=str(uuid.uuid4()))
        h, d = alice.expect("error", timeout=3)
        assert "群组" in d.decode() and "不存在" in d.decode()


# ============================================================
# 第 2 组：撤回扩展
# ============================================================

class TestRecallExtended:

    def test_recall_nonexistent_is_idempotent(self, harness):
        """撤回不存在的消息 ID：静默成功（无 error 回复）。"""
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("recall", "", message_id="ghost-id", to="bob")
        # 不应收到 error；短暂等待后断言无 error
        h, d = alice.recv(timeout=0.8)
        # 允许 None（无回复）或非 error 类型；绝不应是 error
        assert h is None or h.get("type") != "error", \
            f"撤回不存在的消息不应返回 error，收到: {h}"

    def test_recall_already_recalled(self, harness):
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        mid = str(uuid.uuid4())
        alice.send("chat", "secret", to="bob", message_id=mid)
        alice.drain(timeout=0.5)
        # 第一次撤回
        alice.send("recall", "", message_id=mid, to="bob")
        h1, _ = alice.recv(timeout=2)
        # 第二次撤回应提示"已被撤回"或静默
        alice.send("recall", "", message_id=mid, to="bob")
        h2, d2 = alice.recv(timeout=2)
        assert h2 is None or h2.get("type") in ("error", "recall"), \
            f"重复撤回不应崩溃，收到: {h2}"

    def test_recall_file_request(self, harness):
        """2 分钟内撤回自己的文件请求 → 请求删除 + 接收方收到通知。"""
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.drain(timeout=1)
        mid = str(uuid.uuid4())
        alice.send("file", b"payload", to="bob", filename="retract.bin",
                   filesize=7, message_id=mid)
        alice.drain(timeout=0.5)
        assert harness.db.get_file_request(mid) is not None

        alice.send("recall", "", message_id=mid, to="bob")
        h, _ = alice.recv(timeout=2)
        assert h is not None and h.get("type") == "recall"
        assert harness.db.get_file_request(mid) is None

    def test_recall_other_user_blocked(self, harness):
        """非发送者尝试撤回他人消息应被拒绝。"""
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.drain(timeout=1)
        mid = str(uuid.uuid4())
        alice.send("chat", "hi", to="bob", message_id=mid)
        alice.drain(timeout=0.5)

        bob = harness.client()
        bob.login("bob", "password456", consume=False)
        bob.recv_initial()
        bob.send("recall", "", message_id=mid, to="alice")
        h, d = bob.expect("error", timeout=3)
        assert "只能撤回自己的消息" in d.decode()

    def test_group_recall_offline_placeholder(self, harness):
        """OFF-5：群聊撤回，离线成员登录后看到撤回占位符而非原内容。"""
        # alice 创建群组并加入 bob（bob 离线）
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("create_group", "recallgrp")
        alice.drain(timeout=0.6)
        gid = harness.db.get_user_groups("alice")[0][0]
        alice.send("join_group", str(gid))  # alice 已在群，会提示已在
        alice.drain(timeout=0.4)

        # 把 bob 加入群组（直接操作 DB，模拟 bob 曾加入）
        harness.db.join_group(gid, "bob")

        # alice 发群聊消息
        mid = str(uuid.uuid4())
        alice.send("group_chat", "群聊秘密内容", group_id=str(gid), message_id=mid)
        alice.drain(timeout=0.5)

        # alice 立即撤回
        alice.send("recall", "", message_id=mid, to="group_%d" % gid)
        alice.recv(timeout=2)  # 撤回确认

        # bob 登录，应看到撤回占位符
        bob = harness.client()
        bob.login("bob", "password456", consume=False)
        initial = bob.recv_initial()
        texts = []
        for h, d in initial["offline"]:
            if h.get("type") == "group_chat":
                texts.append(d.decode("utf-8") if d else "")
        assert any("撤回了一条消息" in t for t in texts), \
            f"bob 应看到群聊撤回占位符，离线消息: {texts}"
        assert not any("群聊秘密内容" in t for t in texts), \
            "bob 不应看到已撤回的群聊原内容"


# ============================================================
# 第 3 组：管理员命令扩展
# ============================================================

class TestAdminExtended:

    def test_list_users_includes_online_status(self, harness):
        # alice 在线
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        admin = harness.client()
        admin.login("admin", "adminpass", admin_secret="test-admin-secret", consume=False)
        admin.recv_initial()

        admin.send("admin_command", "", action="list_users")
        h, d = admin.expect("admin_response", timeout=3)
        assert h.get("response_type") == "list_users"
        users = json.loads(d.decode())
        # 每项 [username, online, is_admin]；is_admin 必须是 JSON 布尔
        # （历史缺陷：曾用 DB 整数 0/1 直接发送，Dart `item[2] == true` 永远 false）
        status = {u[0]: (u[1], u[2]) for u in users}
        assert status["alice"][0] is True  # alice 在线
        assert status["admin"][1] is True  # admin 是管理员（严格 is True）
        # bob 离线
        assert status["bob"][0] is False

    def test_list_users_is_admin_serialized_as_bool(self, harness):
        """回归测试：list_users 响应中 is_admin 字段必须是 JSON 布尔。

        历史缺陷：server_admin_handler.py 曾直接发送 DB 整数 0/1，
        导致 Dart 客户端 `item[2] == true` 比较 int 1 时永远 false，
        "查看所有用户"列表里管理员不显示 [管理员] 标记。
        修复后服务端用 bool(is_admin) 转换，本测试锁定该行为。
        """
        # 确保有管理员（admin）与普通用户（alice/bob）
        admin = harness.client()
        admin.login("admin", "adminpass", admin_secret="test-admin-secret", consume=False)
        admin.recv_initial()

        admin.send("admin_command", "", action="list_users")
        h, d = admin.expect("admin_response", timeout=3)
        assert h.get("response_type") == "list_users"
        users = json.loads(d.decode())
        for user in users:
            # 第三列 is_admin 必须是 Python bool / JSON boolean，绝不能是 int
            assert isinstance(user[2], bool), (
                f"is_admin 必须序列化为 JSON 布尔，实际 {user[2]!r}({type(user[2]).__name__})")
        # admin 行的 is_admin 应为 True，其它为 False
        admin_row = next(u for u in users if u[0] == "admin")
        assert admin_row[2] is True
        non_admin = next(u for u in users if u[0] == "alice")
        assert non_admin[2] is False

    def test_admin_delete_user(self, harness):
        harness.add_user("charlie", "pass123")
        admin = harness.client()
        admin.login("admin", "adminpass", admin_secret="test-admin-secret", consume=False)
        admin.recv_initial()
        admin.send("admin_command", "charlie", action="delete_user")
        h, d = admin.expect("admin_response", timeout=3)
        assert h.get("action_result") is not None
        assert "charlie" in h.get("action_result", "")
        assert harness.db.user_exists("charlie") is False
        # delete_user 响应同 list_users：返回删除后的用户列表，is_admin 必须是布尔
        users = json.loads(d.decode())
        admin_row = next(u for u in users if u[0] == "admin")
        assert isinstance(admin_row[2], bool) and admin_row[2] is True

    def test_admin_cannot_delete_self(self, harness):
        admin = harness.client()
        admin.login("admin", "adminpass", admin_secret="test-admin-secret", consume=False)
        admin.recv_initial()
        admin.send("admin_command", "admin", action="delete_user")
        h, d = admin.expect("error", timeout=3)
        assert "不能删除当前登录的管理员" in d.decode()

    def test_admin_delete_nonexistent_fails(self, harness):
        admin = harness.client()
        admin.login("admin", "adminpass", admin_secret="test-admin-secret", consume=False)
        admin.recv_initial()
        admin.send("admin_command", "ghostuser", action="delete_user")
        h, d = admin.expect("error", timeout=3)
        assert "删除用户" in d.decode()

    def test_non_admin_command_rejected(self, harness):
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("admin_command", "", action="list_users")
        h, d = alice.expect("error", timeout=3)
        assert "无管理员权限" in d.decode()

    def test_announcement_multi_user_and_offline(self, harness):
        """公告：在线用户实时收到，离线用户登录后看到。"""
        # alice 在线
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        # admin 发公告（bob 离线）
        admin = harness.client()
        admin.login("admin", "adminpass", admin_secret="test-admin-secret", consume=False)
        admin.recv_initial()
        admin.send("admin_command", "全民公告内容", action="announcement")
        # admin 先收到自己被广播的公告，再收到"公告发送成功"
        admin.recv(timeout=2)
        h_ok, d_ok = admin.expect("chat", timeout=3)
        assert "公告发送成功" in d_ok.decode()

        # alice 在线应实时收到公告
        h_alice, d_alice = alice.recv(timeout=2)
        assert h_alice.get("from") == "[系统公告]"
        assert "全民公告内容" in d_alice.decode()

        # bob 离线，登录后应在离线消息中看到公告
        bob = harness.client()
        bob.login("bob", "password456", consume=False)
        initial = bob.recv_initial()
        found = any(
            h.get("from") == "[系统公告]" and d and "全民公告内容" in d.decode()
            for h, d in initial["offline"]
        )
        assert found, "bob 应在离线消息中收到公告"


# ============================================================
# 第 4 组：历史分页扩展
# ============================================================

class TestFetchHistoryExtended:

    def test_fetch_group_history(self, harness):
        # alice 建群并发若干群聊
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("create_group", "histgrp")
        alice.drain(timeout=0.6)
        gid = harness.db.get_user_groups("alice")[0][0]
        for i in range(3):
            alice.send("group_chat", f"g{i}", group_id=str(gid),
                       message_id=str(uuid.uuid4()))
            alice.drain(timeout=0.3)

        alice.send("fetch_history", "", group_id=str(gid), limit="50")
        h, d = alice.expect("history_response", timeout=3)
        assert h.get("group_id") == str(gid)
        batch = json.loads(d.decode())
        assert len(batch) == 3
        contents = {b["content"] for b in batch}
        assert {"g0", "g1", "g2"} <= contents

    def test_fetch_history_invalid_limit_defaults(self, harness):
        """limit 非法时服务端回退默认 50。"""
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("fetch_history", "", to="bob", limit="not-a-number")
        h, d = alice.expect("history_response", timeout=3)
        assert h.get("type") == "history_response"
        # 不抛异常即说明回退成功
        json.loads(d.decode())

    def test_fetch_history_nonexistent_before_id(self, harness):
        """before_message_id 在历史表不存在时，游标为 None，返回最新一页。"""
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        # 先制造 2 条历史
        for i in range(2):
            alice.send("chat", f"hist{i}", to="bob", message_id=str(uuid.uuid4()))
            alice.drain(timeout=0.3)
        # 用一个不存在的 before_message_id 拉取
        alice.send("fetch_history", "", to="bob",
                   before_message_id="no-such-history-id", limit="50")
        h, d = alice.expect("history_response", timeout=3)
        batch = json.loads(d.decode())
        # 应回退为最新一页，返回 2 条
        assert len(batch) == 2


# ============================================================
# 第 5 组：群组操作边界
# ============================================================

class TestGroupEdges:

    def test_create_duplicate_group(self, harness):
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("create_group", "dupgrp")
        alice.drain(timeout=0.5)
        alice.send("create_group", "dupgrp")
        h, d = alice.recv(timeout=2)
        assert h is not None
        assert h.get("type") == "error" or "失败" in d.decode(), \
            f"重复创建群组应失败，收到: {h} {d.decode() if d else ''}"

    def test_join_nonexistent_group(self, harness):
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("join_group", "9999")
        h, d = alice.expect("error", timeout=3)
        assert "不存在" in d.decode()

    def test_join_invalid_group_id(self, harness):
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("join_group", "not-a-number")
        h, d = alice.expect("error", timeout=3)
        assert "无效" in d.decode()

    def test_join_already_member(self, harness):
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("create_group", "memgrp")
        alice.drain(timeout=0.6)
        gid = harness.db.get_user_groups("alice")[0][0]
        alice.send("join_group", str(gid))
        h, d = alice.recv(timeout=2)
        assert h is not None and "已在群组" in d.decode()

    def test_group_chat_nonexistent_group(self, harness):
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("group_chat", "hi", group_id="9999", message_id=str(uuid.uuid4()))
        h, d = alice.expect("error", timeout=3)
        assert "不存在" in d.decode()

    def test_group_chat_non_member(self, harness):
        # alice 建群，bob 不加入即发群聊
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("create_group", "privgrp")
        alice.drain(timeout=0.6)
        gid = harness.db.get_user_groups("alice")[0][0]

        bob = harness.client()
        bob.login("bob", "password456", consume=False)
        bob.recv_initial()
        bob.send("group_chat", "intruder", group_id=str(gid), message_id=str(uuid.uuid4()))
        h, d = bob.expect("error", timeout=3)
        assert "不在此群组" in d.decode()


# ============================================================
# 第 6 组：好友请求边界 + 未知类型健壮性
# ============================================================

class TestFriendAndUnknown:

    def test_friend_request_to_nonexistent_user(self, harness):
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("friend_request", "", to="ghost")
        h, d = alice.expect("error", timeout=3)
        assert "不存在" in d.decode()

    def test_friend_request_to_self(self, harness):
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("friend_request", "", to="alice")
        # add_friend_request 拒绝自己 → 服务端回复"发送失败"
        h, d = alice.recv(timeout=2)
        assert h is not None
        assert h.get("type") == "error" or "失败" in d.decode(), \
            f"向自己发好友请求应失败，收到: {h}"

    def test_friend_request_to_existing_friend(self, harness):
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        # alice 和 bob 已是好友
        alice.send("friend_request", "", to="bob")
        h, d = alice.expect("error", timeout=3)
        assert "已是您的好友" in d.decode()

    def test_list_friend_requests_handler(self, harness):
        """list_friend_requests 返回待处理请求 JSON。"""
        # dave 注册并向 alice 发好友请求（不预置 dave，避免注册冲突）
        dave = harness.client()
        dave.register("dave", "pass123", consume=False)
        dave.recv_initial()
        dave.send("friend_request", "", to="alice")
        dave.drain(timeout=0.5)

        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("list_friend_requests", "")
        h, d = alice.expect("list_friend_requests", timeout=3)
        reqs = json.loads(d.decode())
        assert "dave" in reqs

    def test_unknown_message_type_does_not_crash(self, harness):
        """服务端收到未知类型（如 receipt）应静默跳过，不崩溃。"""
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("receipt", "", message_id=str(uuid.uuid4()), to="bob")
        # 再发一条正常消息验证连接仍然存活
        mid = str(uuid.uuid4())
        alice.send("chat", "still alive", to="bob", message_id=mid)
        h, d = alice.recv(timeout=2)
        assert h is not None and h.get("type") == "chat"
        assert "离线" in d.decode()  # bob 离线
