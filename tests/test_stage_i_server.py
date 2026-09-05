"""
============================================================
阶段 I —— 消息可靠性：重发幂等去重（服务端）
============================================================

【背景】
  客户端断线补发/手动重试会复用原 message_id（阶段 I1 pending 队列）。
  若消息此前已被服务端接收并入库（客户端 write 异常不代表服务端未收到，
  TCP 交付与本地异常之间无确定性），重发会造成"已送达消息被二次下发"。

【契约】
  服务端对 chat / group_chat 按 (message_id, sender) 幂等：
    - message_id 已存在于 message_history（永久表）且 sender 相同
      → 视为重复消息：不重复保存（offline/history）、不重复转发/广播
    - 不同 sender 使用相同 message_id → 不受影响（正常处理）
    - 新 message_id → 正常处理（回归不变式）
  数据库层：Database.message_id_exists(message_id, sender=None)

【运行】
  .venv/bin/python -m pytest tests/test_stage_i_server.py -v
"""

import os
import sys
import time
import uuid

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from database import Database


# ============================================================
# 数据库层：message_id_exists
# ============================================================

class TestMessageIdExists:

    def test_not_exists_initial(self, db):
        """新消息 id 尚未入库 → False。"""
        assert db.message_id_exists(str(uuid.uuid4())) is False

    def test_true_after_history_saved(self, db):
        """消息写入 message_history 后 → True。"""
        mid = str(uuid.uuid4())
        db.add_user("alice", b"x")
        db.add_user("bob", b"x")
        db.save_message_history("alice", "bob", "chat", b"hi", message_id=mid)
        assert db.message_id_exists(mid) is True
        assert db.message_id_exists(mid, sender="alice") is True

    def test_sender_scoped(self, db):
        """不同 sender 同 message_id → 不命中（防跨用户误判）。"""
        mid = str(uuid.uuid4())
        db.add_user("alice", b"x")
        db.add_user("bob", b"x")
        db.save_message_history("alice", "bob", "chat", b"hi", message_id=mid)
        assert db.message_id_exists(mid, sender="alice") is True
        assert db.message_id_exists(mid, sender="bob") is False

    def test_true_after_group_history_saved(self, db):
        """群聊历史（group_id 消息）同样可判重。"""
        mid = str(uuid.uuid4())
        db.add_user("alice", b"x")
        gid = db.create_group("g", "alice")
        db.save_message_history("alice", "", "group_chat", b"hi",
                                group_id=gid, message_id=mid)
        assert db.message_id_exists(mid, sender="alice") is True

    def test_not_affected_by_offline_cleanup(self, db):
        """判重依据 message_history（永久表），offline 清理不影响。"""
        mid = str(uuid.uuid4())
        db.add_user("alice", b"x")
        db.add_user("bob", b"x")
        db.save_offline_message("alice", "bob", "chat", b"hi", message_id=mid)
        # 仅 offline 有记录（尚未写历史）→ 不判重
        assert db.message_id_exists(mid) is False
        db.save_message_history("alice", "bob", "chat", b"hi", message_id=mid)
        db.cleanup_delivered_messages("bob")  # 清理 delivered 不影响判重
        assert db.message_id_exists(mid) is True


# ============================================================
# 服务端：私聊重发幂等
# ============================================================

class TestPrivateChatIdempotency:

    def _login_two(self, harness):
        alice = harness.client()
        bob = harness.client()
        alice.login("alice", "password123")
        bob.login("bob", "password456")
        return alice, bob

    def test_duplicate_chat_not_forwarded_twice(self, harness):
        """同 message_id 重发：接收方只收到一次，历史/离线各一条。"""
        alice, bob = self._login_two(harness)
        mid = str(uuid.uuid4())

        alice.send("chat", "通信正常", to="bob", message_id=mid)
        h1, d1 = bob.expect("chat")
        assert h1["message_id"] == mid
        assert d1.decode() == "通信正常"

        # 客户端断线补发：复用同一 message_id
        alice.send("chat", "通信正常", to="bob", message_id=mid)

        # 接收方不应再收到任何转发（等一个超时窗口确认无消息）
        assert bob.recv(timeout=0.6) == (None, None), "重复消息被二次转发"

        # 历史与离线各只存一条
        with harness.db._get_connection() as conn:
            cur = conn.cursor()
            cur.execute("SELECT COUNT(*) FROM message_history WHERE message_id=?", (mid,))
            assert cur.fetchone()[0] == 1
            cur.execute("SELECT COUNT(*) FROM offline_messages WHERE message_id=?", (mid,))
            assert cur.fetchone()[0] == 1

    def test_duplicate_chat_offline_target_no_second_offline(self, harness):
        """目标离线时重发：不重复写入 offline_messages。"""
        alice = harness.client()
        alice.login("alice", "password123")  # bob 离线

        mid = str(uuid.uuid4())
        alice.send("chat", "离线消息", to="bob", message_id=mid)
        h, d = alice.expect("chat")
        assert "离线" in d.decode()

        alice.send("chat", "离线消息", to="bob", message_id=mid)

        with harness.db._get_connection() as conn:
            cur = conn.cursor()
            cur.execute("SELECT COUNT(*) FROM offline_messages WHERE message_id=?", (mid,))
            assert cur.fetchone()[0] == 1
            cur.execute("SELECT COUNT(*) FROM message_history WHERE message_id=?", (mid,))
            assert cur.fetchone()[0] == 1

    def test_new_message_id_normal_delivery(self, harness):
        """新 message_id 正常送达（回归：幂等不得误伤正常消息）。"""
        alice, bob = self._login_two(harness)
        for i in range(3):
            mid = str(uuid.uuid4())
            alice.send("chat", f"m{i}", to="bob", message_id=mid)
            h, d = bob.expect("chat")
            assert h["message_id"] == mid
            assert d.decode() == f"m{i}"

    def test_same_message_id_different_sender_not_deduped(self, harness):
        """不同 sender 复用同一 message_id：正常处理，不被误判为重复。"""
        harness.add_user("carol")
        with harness.db._get_connection() as conn:
            conn.execute(
                "INSERT INTO friends (user1, user2, status) VALUES (?, ?, 'accepted')",
                ("alice", "carol"))
            conn.execute(
                "INSERT INTO friends (user1, user2, status) VALUES (?, ?, 'accepted')",
                ("carol", "alice"))
            conn.commit()

        alice = harness.client()
        carol = harness.client()
        alice.login("alice", "password123")
        carol.login("carol", "pass123")

        mid = str(uuid.uuid4())
        alice.send("chat", "来自 alice", to="carol", message_id=mid)
        h, d = carol.expect("chat")
        assert h["message_id"] == mid

        # carol 用同一 message_id 发回给 alice（不属于 alice 的历史）
        carol.send("chat", "来自 carol", to="alice", message_id=mid)
        h2, d2 = alice.expect("chat")
        assert h2["message_id"] == mid
        assert d2.decode() == "来自 carol"

    def test_duplicate_not_friend_check_still_applies(self, harness):
        """重复消息仍先过好友校验（非好友的重复 id 仍报错）。"""
        alice = harness.client()
        alice.login("alice", "password123")
        mid = str(uuid.uuid4())
        with harness.db._get_connection() as conn:
            conn.execute(
                "INSERT INTO message_history (message_id, sender, receiver, message_type, content) "
                "VALUES (?, 'alice', 'ghost', 'chat', ?)",
                (mid, b"x"))
            conn.commit()
        alice.send("chat", "x", to="ghost", message_id=mid)
        h, d = alice.expect("error")
        assert "不是您的好友" in d.decode()


# ============================================================
# 服务端：群聊重发幂等
# ============================================================

class TestGroupChatIdempotency:

    def _group_setup(self, harness):
        alice = harness.client()
        bob = harness.client()
        carol = harness.client()
        alice.login("alice", "password123")
        bob.login("bob", "password456")
        carol.login("carol", "pass123")  # harness.add_user 默认密码 pass123
        alice.send("create_group", "测试群")
        alice.expect("chat")  # 创建成功
        with harness.db._get_connection() as conn:
            cur = conn.cursor()
            cur.execute("SELECT id FROM groups WHERE group_name='测试群'")
            gid = cur.fetchone()[0]
        alice.drain()  # 消费"创建了群组"系统提示 + list_groups
        for uname in ("bob", "carol"):
            harness.db.join_group(gid, uname)
        return alice, bob, carol, gid

    def test_duplicate_group_chat_not_broadcast(self, harness):
        """同 message_id 群聊重发：成员只收到一次，历史只存一条。"""
        harness.add_user("carol")
        alice, bob, carol, gid = self._group_setup(harness)
        mid = str(uuid.uuid4())

        alice.send("group_chat", "群消息", group_id=str(gid), message_id=mid)
        h1, d1 = bob.expect("group_chat")
        assert h1["message_id"] == mid
        assert d1.decode() == "群消息"
        h1b, d1b = carol.expect("group_chat")
        assert h1b["message_id"] == mid

        # 重发同一 message_id → 不广播
        alice.send("group_chat", "群消息", group_id=str(gid), message_id=mid)
        assert bob.recv(timeout=0.6) == (None, None), "群聊重复消息被二次广播"
        assert carol.recv(timeout=0.6) == (None, None)

        with harness.db._get_connection() as conn:
            cur = conn.cursor()
            cur.execute("SELECT COUNT(*) FROM message_history WHERE message_id=?", (mid,))
            assert cur.fetchone()[0] == 1
            # 每个成员至多一条离线记录（在线转发后标记 delivered，不新增）
            cur.execute("SELECT COUNT(*) FROM offline_messages WHERE message_id LIKE ?",
                        (f"{mid}%",))
            assert cur.fetchone()[0] == 2

    def test_group_new_message_id_normal_broadcast(self, harness):
        """群聊新 message_id 正常广播（回归）。"""
        harness.add_user("carol")
        alice, bob, carol, gid = self._group_setup(harness)
        for i in range(2):
            mid = str(uuid.uuid4())
            alice.send("group_chat", f"g{i}", group_id=str(gid), message_id=mid)
            for member in (bob, carol):
                h, d = member.expect("group_chat")
                assert h["message_id"] == mid
                assert d.decode() == f"g{i}"

    def test_group_offline_echo_preserves_full_message_id(self, harness):
        """重连离线回显群聊消息须携带完整 message_id（含下划线）——Q-02 三次修复。

        客户端生成的 message_id 形如 "{毫秒}_{随机数}"（含下划线），离线行存为
        "{原始id}_{成员名}"。若回显时只取 split('_')[0]（时间戳前缀），客户端
        按原始 id 去重失败：已送达的群聊消息在每次重连后重复出现，且误入补发
        队列被再次发送。修复后回显必须携带完整原始 id。
        """
        harness.add_user("carol")
        alice, bob, carol, gid = self._group_setup(harness)
        mid = f"{int(time.time() * 1000)}_456789"  # 与客户端 _generateMessageId 同构

        alice.send("group_chat", "群聊已送达消息", group_id=str(gid), message_id=mid)
        for member in (bob, carol):
            h, _ = member.expect("group_chat")
            assert h["message_id"] == mid

        # alice 重连（模拟断线重连）：离线回显须携带完整原始 message_id
        alice2 = harness.client()
        result = alice2.login("alice", "password123")
        echoes = [h for h, _ in result["offline"]
                  if h.get("type") == "group_chat" and h.get("from") == "alice"]
        assert echoes, "重连后应回显自己发出的群聊消息"
        assert any(h.get("message_id") == mid for h in echoes), \
            f"回显 message_id 应为完整原始 id（{mid}），实际: " \
            f"{[h.get('message_id') for h in echoes]}"

    def test_group_offline_echo_member_with_underscore(self, harness):
        """成员名含下划线时回显仍还原出完整原始 message_id。"""
        harness.add_user("foo_bar")
        with harness.db._get_connection() as conn:
            conn.execute(
                "INSERT INTO friends (user1, user2, status) VALUES (?, ?, 'accepted')",
                ("alice", "foo_bar"))
            conn.execute(
                "INSERT INTO friends (user1, user2, status) VALUES (?, ?, 'accepted')",
                ("foo_bar", "alice"))
            conn.commit()

        alice = harness.client()
        alice.login("alice", "password123")
        alice.send("create_group", "带下划线成员")
        alice.expect("chat")
        with harness.db._get_connection() as conn:
            cur = conn.cursor()
            cur.execute("SELECT id FROM groups WHERE group_name='带下划线成员'")
            gid = cur.fetchone()[0]
        alice.drain()

        member = harness.client()
        member.login("foo_bar", "pass123")
        harness.db.join_group(gid, "foo_bar")

        mid = f"{int(time.time() * 1000)}_123456"
        alice.send("group_chat", "含下划线成员群聊", group_id=str(gid), message_id=mid)
        h, _ = member.expect("group_chat")
        assert h["message_id"] == mid

        alice2 = harness.client()
        result = alice2.login("alice", "password123")
        echoes = [h for h, _ in result["offline"]
                  if h.get("type") == "group_chat" and h.get("from") == "alice"]
        assert any(h.get("message_id") == mid for h in echoes), \
            f"成员名含下划线时仍须还原完整 id（{mid}）: " \
            f"{[h.get('message_id') for h in echoes]}"


# ============================================================
# 服务端：单条消息处理异常不中断连接（Q-02 二次修复）
# ============================================================
# 断线重连后立即补发时，若服务端正经历瞬时 SQLite 锁等单条消息处理异常，
# 旧实现会让整个连接线程崩溃 → 客户端刚重连成功就被断开，补发要等第二次
# 重连才送达。修复：process_messages / load_offline_data 逐条隔离异常，
# 连接保持，客户端在（下一次）重连时全量补发队列。

import sqlite3


class TestMessageProcessingResilience:

    def test_transient_db_error_does_not_kill_connection(self, harness, monkeypatch):
        """chat 处理中 DB 抛一次瞬时异常 → 连接保持，后续消息正常处理。"""
        alice, bob = self._login_two(harness)
        original_save = harness.db.save_message_history
        state = {"failed": False}

        def flaky_save(*args, **kwargs):
            if not state["failed"]:
                state["failed"] = True
                raise sqlite3.OperationalError("database is locked")
            return original_save(*args, **kwargs)

        monkeypatch.setattr(harness.db, "save_message_history", flaky_save)

        mid1 = str(uuid.uuid4())
        alice.send("chat", "首次触发异常", to="bob", message_id=mid1)
        # 连接未被断开：下一条消息仍能被处理
        mid2 = str(uuid.uuid4())
        alice.send("chat", "连接仍然存活", to="bob", message_id=mid2)

        # 第二条消息正常送达 bob（连接未因第一条的瞬时异常而中断）
        h, d = bob.expect("chat")
        assert d.decode() == "连接仍然存活"
        # 第一条消息：服务端处理中断，未入库（客户端会在重连时补发）
        assert harness.db.message_id_exists(mid1) is False

    def test_login_offline_push_error_does_not_kill_connection(self, harness, monkeypatch):
        """登录推送离线消息时单条异常 → 登录流程不中断，其余消息照常推送。"""
        # 预置两条 alice 发出的离线消息（bob 离线时发送）
        harness.db.save_offline_message(
            "alice", "bob", "chat", b"first", message_id="off1")
        harness.db.save_offline_message(
            "alice", "bob", "chat", b"second", message_id="off2")

        original_send = harness.server.guarded_send
        state = {"failed": False}

        def flaky_send(sock, msg_type, content, **kw):
            if not state["failed"] and msg_type == "chat" and \
                    str(content).startswith("first"):
                state["failed"] = True
                raise sqlite3.OperationalError("database is locked")
            return original_send(sock, msg_type, content, **kw)

        monkeypatch.setattr(harness.server, "guarded_send", flaky_send)

        alice = harness.client()
        result = alice.login("alice", "password123")
        # 登录成功（初始数据照常推送，包括第二条离线消息）
        assert result["login_response"][0]["type"] in ("chat", "admin_auth")
        history_offline = [h for h, _ in result["offline"]
                           if h.get("message_id", "").startswith("off")]
        assert any(h.get("message_id") == "off2" for h in history_offline), \
            "第二条离线消息应照常推送"

        # 连接仍可用：登录后再发一条消息能正常送达
        bob = harness.client()
        bob.login("bob", "password456")
        alice.send("chat", "after login", to="bob", message_id=str(uuid.uuid4()))
        h, d = bob.expect("chat")
        assert d.decode() == "after login"

    def _login_two(self, harness):
        alice = harness.client()
        bob = harness.client()
        alice.login("alice", "password123")
        bob.login("bob", "password456")
        return alice, bob
