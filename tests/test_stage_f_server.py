"""
============================================================
阶段 F —— 社交管理：服务端协议层 TDD 测试（F2 / F5 / F7）
============================================================

【目标】
  测试阶段 F 新增的三个协议类型处理器，先写测试（红），等待实现（绿）：
    F2  delete_friend       （服务端处理 + 双方通知）
    F5  leave_group         （服务端处理 + 群成员通知）
    F7  list_group_members  （服务端处理，返回成员列表）

【契约（实现方需严格遵守，本测试即据此验证）】
----- F2 delete_friend -----
  C → S:
    type      = "delete_friend"
    to        = <目标用户名>
  S → C 请求方：
    type = "chat", content = "已删除好友 <目标用户名>"（系统通知，无 from）
  S → C 被删方（在线）：
    type = "delete_friend", content = ""
    extra_headers = {"from": <请求方用户名>}
  被删方离线：
    save_offline_message(sender=<请求方>, receiver=<目标>, type="chat",
                        content=b"<请求方> 已删除您为好友")
  规约：
    - 即使当前不是好友也成功（幂等清理双向 friends 记录）
    - 目标用户不存在 → 回 error "用户 <X> 不存在"
    - 删除后双方 is_friend=False，可重新发起好友请求

----- F5 leave_group -----
  C → S:
    type      = "leave_group"
    group_id  = <群组 id 字符串>
  S → C 离开方：
    type = "chat", content = "已退出群组 <X> (ID:Y)"（系统通知）
  S → C 群内其他在线成员（通过 notify_group_members）：
    type = "chat", content = "<离开者> 已退出群组 <X>"
    extra_headers = {"from": "系统", "group_id": <X>}
  规约：
    - 群组不存在 → error "群组 <X> 不存在"
    - 非群成员 → error "您不在此群组中"
    - 创建者可离开（群组保留）
    - 离开后 is_group_member=False，可重新加入

----- F7 list_group_members -----
  C → S:
    type      = "list_group_members"
    group_id  = <群组 id 字符串>
  S → C：
    type = "admin_response", content = JSON 数组成员用户名
    extra_headers = {"response_type": "list_group_members", "group_id": <X>}
  规约：
    - 群组不存在 → error "群组 <X> 不存在"
    - 非成员 → error "您不在此群组中"
    - 成员包含创建者在内的所有人

【运行】
  实现前：测试断言会失败（协议类型未处理或行为不符），属 TDD 红。
  实现后：全部通过。

  .venv/bin/python -m pytest tests/test_stage_f_server.py -v
"""

import os
import sys
import json
import uuid
import pytest
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


# ============================================================
# F2 —— delete_friend 服务端处理
# ============================================================

class TestDeleteFriendHandler:

    def test_delete_friend_online_target_notified(self, harness):
        """F2 正向：双方在线好友，删除者收到确认，被删方收到 push。"""
        # alice 和 bob 同时在线
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        bob = harness.client()
        bob.login("bob", "password456", consume=False)
        bob.recv_initial()

        # alice 删除 bob
        alice.send("delete_friend", "", to="bob")

        # alice 应收到系统通知"已删除好友 bob"
        h_a, d_a = alice.expect("chat", timeout=3)
        assert h_a is not None
        assert "已删除好友" in d_a.decode() and "bob" in d_a.decode()
        # 没有 from 字段，表示系统通知
        assert h_a.get("from") in (None, "", "系统")

        # bob 应收到 delete_friend push，from=alice
        h_b, d_b = bob.expect("delete_friend", timeout=3)
        assert h_b is not None
        assert h_b["type"] == "delete_friend"
        assert h_b.get("from") == "alice"

        # DB 中双向好友关系被清除
        assert harness.db.is_friend("alice", "bob") is False
        assert harness.db.is_friend("bob", "alice") is False

    def test_delete_friend_offline_target_persisted(self, harness):
        """F2 离线补发：被删方离线，登录后看到"已删除您为好友"通知。"""
        # alice 在线，bob 离线
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        alice.send("delete_friend", "", to="bob")
        # alice 收到确认
        h_a, d_a = alice.expect("chat", timeout=3)
        assert "已删除好友" in d_a.decode()

        # bob 登录
        bob = harness.client()
        bob.login("bob", "password456", consume=False)
        initial = bob.recv_initial()
        # bob 应在离线消息中看到删除通知
        deleted_msg = False
        for h, d in initial["offline"]:
            text = d.decode("utf-8") if d else ""
            if "已删除" in text and "好友" in text and "alice" in text:
                deleted_msg = True
                break
        assert deleted_msg, (
            f"bob 应看到删除通知，离线消息: "
            f"{[(h.get('type'), h.get('from'), d.decode() if d else '') for h, d in initial['offline']]}")
        # 同时 db 中双方不再是好友
        assert harness.db.is_friend("alice", "bob") is False

    def test_delete_friend_idempotent_not_friends(self, harness):
        """F2 幂等：删除非好友也成功（清理残留）。"""
        harness.add_user("carol")  # carol 与 alice 非好友
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        alice.send("delete_friend", "", to="carol")
        # 应成功通知"已删除好友 carol"（即使之前非好友）
        h, d = alice.expect("chat", timeout=3)
        assert "已删除好友" in d.decode()

    def test_delete_friend_nonexistent_target(self, harness):
        """F2 目标用户不存在 → error。"""
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        alice.send("delete_friend", "", to="ghost_user")
        h, d = alice.expect("error", timeout=3)
        assert "不存在" in d.decode()

    def test_delete_friend_bilateral_db_cleanup(self, harness):
        """F2 DB 双向清理：alice 删除 bob，双方 get_friends 互不包含。"""
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("delete_friend", "", to="bob")
        alice.drain(timeout=1)

        # DB 中两个方向好友列表都不再包含对方
        assert "bob" not in harness.db.get_friends("alice")
        assert "alice" not in harness.db.get_friends("bob")

    def test_can_re_request_after_delete(self, harness):
        """F2 关键不变式：删除后可重新发起好友请求。"""
        # 先让 alice 删除 bob
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("delete_friend", "", to="bob")
        alice.drain(timeout=1)

        # 再次发好友请求应该成功
        alice.send("friend_request", "", to="bob")
        h, d = alice.expect("chat", timeout=3)
        assert "好友请求已发送" in d.decode()


# ============================================================
# F5 —— leave_group 服务端处理
# ============================================================

class TestLeaveGroupHandler:

    def test_leave_group_member_success(self, harness):
        """F5 成员离开：本人收到确认，DB 不再是成员。"""
        # alice 建群，bob 加入
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("create_group", "leavegrp")
        alice.drain(timeout=0.8)
        gid = harness.db.get_user_groups("alice")[0][0]

        bob = harness.client()
        bob.login("bob", "password456", consume=False)
        bob.recv_initial()
        harness.db.join_group(gid, "bob")

        # bob 离开
        assert harness.db.is_group_member(gid, "bob") is True
        bob.send("leave_group", "", group_id=str(gid))

        # bob 应收到离开确认
        h, d = bob.expect("chat", timeout=3)
        assert "已退出群组" in d.decode() and str(gid) in d.decode()
        assert harness.db.is_group_member(gid, "bob") is False

    def test_leave_group_other_members_notified(self, harness):
        """F5 群成员通知：成员离开后其他在线成员收到通知。"""
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("create_group", "leavegrp")
        alice.drain(timeout=0.8)
        gid = harness.db.get_user_groups("alice")[0][0]

        bob = harness.client()
        bob.login("bob", "password456", consume=False)
        bob.recv_initial()
        # 阶段 J：消费 bob 登录触发的 presence 广播（通知性噪声）
        alice.drain(timeout=0.8)
        harness.db.join_group(gid, "bob")

        # alice 还在线时 bob 离开 → alice 应收到通知
        bob.send("leave_group", "", group_id=str(gid))
        bob.drain(timeout=0.5)

        h_a, d_a = alice.recv(timeout=3)
        assert h_a is not None
        # 通知文本包含 bob 与离开字样
        text = d_a.decode() if d_a else ""
        assert "bob" in text and "退出" in text, f"alice 应收到 bob 退出通知，实际收到: {h_a} {text}"

    def test_leave_group_creator_allowed(self, harness):
        """F5 创建者可以离开群组，群组本身继续存在。"""
        # alice 建群，bob 加入
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("create_group", "creators")
        alice.drain(timeout=0.8)
        gid = harness.db.get_user_groups("alice")[0][0]

        bob = harness.client()
        bob.login("bob", "password456", consume=False)
        bob.recv_initial()
        harness.db.join_group(gid, "bob")

        # alice（创建者）离开
        alice.send("leave_group", "", group_id=str(gid))
        h, d = alice.expect("chat", timeout=3)
        assert "已退出群组" in d.decode()
        assert harness.db.is_group_member(gid, "alice") is False
        assert harness.db.is_group_member(gid, "bob") is True
        # 群组仍存在
        with harness.db._get_connection() as conn:
            cur = conn.cursor()
            cur.execute("SELECT group_name FROM groups WHERE id=?", (gid,))
            assert cur.fetchone() is not None

    def test_leave_group_not_member_rejected(self, harness):
        """F5 非成员离开 → error。"""
        # alice 建群，carol 不加入
        harness.add_user("carol")
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("create_group", "priv")
        alice.drain(timeout=0.8)
        gid = harness.db.get_user_groups("alice")[0][0]

        carol = harness.client()
        carol.login("carol", "pass123", consume=False)
        carol.recv_initial()
        carol.send("leave_group", "", group_id=str(gid))
        h, d = carol.expect("error", timeout=3)
        assert "群组" in d.decode() and ("不在此群组" in d.decode() or "非成员" in d.decode())

    def test_leave_group_nonexistent_rejected(self, harness):
        """F5 不存在的群组 → error。"""
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("leave_group", "", group_id="9999")
        h, d = alice.expect("error", timeout=3)
        assert "不存在" in d.decode()

    def test_can_rejoin_after_leave(self, harness):
        """F5 离开后可重新加入。"""
        # alice 建群、bob 加入后又离开
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("create_group", "regroup")
        alice.drain(timeout=0.8)
        gid = harness.db.get_user_groups("alice")[0][0]

        bob = harness.client()
        bob.login("bob", "password456", consume=False)
        bob.recv_initial()
        harness.db.join_group(gid, "bob")
        bob.send("leave_group", "", group_id=str(gid))
        bob.drain(timeout=0.8)

        # 重新加入：申请制（输入群组 ID 加入需群主审批）
        bob.send("join_group", str(gid))
        h, d = bob.recv(timeout=2)
        assert h is not None
        assert "已发送入群申请" in d.decode()
        harness.db.approve_join_request(gid, "alice", "bob")
        assert harness.db.is_group_member(gid, "bob") is True

    def test_last_member_leave_deletes_group(self, harness):
        """最后一名成员离开后，群组及其历史从数据库删除。"""
        # alice 创建群组（唯一成员）
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("create_group", "emptygroup")
        alice.drain(timeout=0.8)
        gid = harness.db.get_user_groups("alice")[0][0]
        # 群组有历史记录
        harness.db.save_message_history("alice", "", "group_chat",
                                        b"history msg", group_id=gid,
                                        message_id=str(uuid.uuid4()))

        # alice 离开（唯一成员）
        alice.send("leave_group", "", group_id=str(gid))
        h, d = alice.expect("chat", timeout=3)
        assert "已退出群组" in d.decode()

        # 服务端在通知成员后异步执行 delete_group，轮询等待删除完成
        deadline = time.time() + 3
        group_exists = True
        while time.time() < deadline:
            with harness.db._get_connection() as conn:
                cur = conn.cursor()
                cur.execute("SELECT 1 FROM groups WHERE id=?", (gid,))
                group_exists = cur.fetchone() is not None
            if not group_exists:
                break
            time.sleep(0.05)

        # 群组应被彻底删除：groups / group_members / message_history 全部清空
        assert harness.db.is_group_member(gid, "alice") is False
        assert group_exists is False, "空群组应被删除"
        with harness.db._get_connection() as conn:
            cur = conn.cursor()
            cur.execute("SELECT 1 FROM message_history WHERE group_id=?", (gid,))
            assert cur.fetchone() is None, "群组历史应一并删除"


# ============================================================
# F7 —— list_group_members 服务端处理
# ============================================================

class TestListGroupMembersHandler:

    def test_list_group_members_member_can_query(self, harness):
        """F7 群成员可查询成员列表，返回 JSON 数组。"""
        # alice 建群，bob 加入
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("create_group", "memgrp")
        alice.drain(timeout=0.8)
        gid = harness.db.get_user_groups("alice")[0][0]

        bob = harness.client()
        bob.login("bob", "password456", consume=False)
        bob.recv_initial()
        harness.db.join_group(gid, "bob")

        # alice 查询成员列表
        alice.send("list_group_members", "", group_id=str(gid))
        h, d = alice.expect("admin_response", timeout=3)
        assert h.get("response_type") == "list_group_members"
        # 内容是 JSON 字符串数组
        members = json.loads(d.decode())
        assert isinstance(members, list)
        assert set(members) == {"alice", "bob"}

    def test_list_group_members_only_creator(self, harness):
        """F7 仅创建者的群组返回单成员列表。"""
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("create_group", "solo")
        alice.drain(timeout=0.8)
        gid = harness.db.get_user_groups("alice")[0][0]

        alice.send("list_group_members", "", group_id=str(gid))
        h, d = alice.expect("admin_response", timeout=3)
        assert h.get("response_type") == "list_group_members"
        members = json.loads(d.decode())
        assert members == ["alice"]

    def test_list_group_members_non_member_rejected(self, harness):
        """F7 非成员查询成员列表 → error。"""
        harness.add_user("carol")
        # alice 建群
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        alice.send("create_group", "priv")
        alice.drain(timeout=0.8)
        gid = harness.db.get_user_groups("alice")[0][0]

        # carol 非成员查询
        carol = harness.client()
        carol.login("carol", "pass123", consume=False)
        carol.recv_initial()
        carol.send("list_group_members", "", group_id=str(gid))
        h, d = carol.expect("error", timeout=3)
        assert "群组" in d.decode() and ("不在此群组" in d.decode() or "权限" in d.decode())

    def test_list_group_members_nonexistent_group_rejected(self, harness):
        """F7 不存在的群组 → error。"""
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        alice.send("list_group_members", "", group_id="9999")
        h, d = alice.expect("error", timeout=3)
        assert "不存在" in d.decode()