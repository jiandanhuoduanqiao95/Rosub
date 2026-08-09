"""
============================================================
database.py 扩展单元测试 —— 补全覆盖缺口（阶段 A/D/E）
============================================================

test_database.py 已覆盖基础 CRUD。本文件补充：
  - set_admin 管理员标志切换
  - get_message_history_timestamp / update_message_history_status
    （阶段 E 分页游标 + 撤回历史状态）
  - get_offline_messages 的"发出消息"分支（sender=? AND receiver!=?）
  - 游标分页 get_message_history(before=(ts,id))：私聊/群组/通用
  - cleanup_expired_file_requests 群组文件请求 + 响应级联
  - delete_group_file_request 同时删除响应
  - get_pending_group_file_requests 排除已响应
  - 好友请求在"已是好友"反向记录时阻止
  - accept/reject 不存在请求的返回值
  - save_message_history INSERT OR IGNORE 幂等（含 group_id）
  - 离线消息 sent→delivered→recalled 完整流转
  - recall 占位符与原消息共存时的 get_offline_messages 行为
"""

import os
import sys
import uuid
import pytest
import bcrypt
from datetime import datetime, timedelta, UTC

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from database import Database


# ============================================================
# 辅助
# ============================================================

def _hash(pw):
    return bcrypt.hashpw(pw.encode(), bcrypt.gensalt())


def _make_users(db, *names):
    for n in names:
        db.add_user(n, _hash("pw"))


def _save_chat(db, sender, receiver, content, msg_id=None):
    msg_id = msg_id or str(uuid.uuid4())
    db.save_message_history(sender, receiver, "chat",
                            content.encode("utf-8"), message_id=msg_id)
    return msg_id


def _save_group(db, sender, group_id, content, msg_id=None):
    msg_id = msg_id or str(uuid.uuid4())
    db.save_message_history(sender, "", "group_chat",
                            content.encode("utf-8"),
                            group_id=group_id, message_id=msg_id)
    return msg_id


# ============================================================
# 第 1 组：管理员标志
# ============================================================

class TestAdminFlag:

    def test_set_admin_true(self, db):
        _make_users(db, "alice")
        assert db.set_admin("alice", True) is True
        _, is_admin = db.get_user("alice")
        assert bool(is_admin) is True

    def test_set_admin_false(self, db):
        _make_users(db, "bob")
        db.set_admin("bob", True)
        db.set_admin("bob", False)
        _, is_admin = db.get_user("bob")
        assert bool(is_admin) is False

    def test_set_admin_nonexistent(self, db):
        assert db.set_admin("ghost", True) is False


# ============================================================
# 第 2 组：阶段 E —— 历史分页游标 API
# ============================================================

class TestHistoryCursorPagination:
    """get_message_history(before=(timestamp, id)) 游标分页。"""

    def test_timestamp_lookup_returns_id_and_ts(self, db):
        _make_users(db, "alice", "bob")
        mid = _save_chat(db, "alice", "bob", "hello")
        row = db.get_message_history_timestamp(mid)
        assert row is not None
        ts, rid = row
        assert ts is not None
        assert isinstance(rid, int)

    def test_timestamp_lookup_nonexistent_returns_none(self, db):
        assert db.get_message_history_timestamp("no-such-id") is None

    def test_private_cursor_before(self, db):
        _make_users(db, "alice", "bob")
        ids = [_save_chat(db, "alice", "bob", f"m{i}") for i in range(5)]
        # 取最新一条作为游标，拉取它之前的消息
        first_page = db.get_message_history("alice", with_user="bob", limit=1)
        assert len(first_page) == 1
        cursor = db.get_message_history_timestamp(first_page[0][4])
        assert cursor is not None
        # before 游标：返回比该消息更旧的消息
        older = db.get_message_history("alice", with_user="bob",
                                       before=cursor, limit=10)
        assert len(older) == 4
        # 游标消息本身不应出现在结果中
        older_ids = {r[4] for r in older}
        assert first_page[0][4] not in older_ids

    def test_private_cursor_same_second_stable(self, db):
        """同一秒内多条消息，用 (timestamp, id) 组合游标也能正确分页。"""
        _make_users(db, "alice", "bob")
        ids = [_save_chat(db, "alice", "bob", f"same{i}") for i in range(5)]
        # 全部消息落在同一秒（快速连续写入）
        page1 = db.get_message_history("alice", with_user="bob", limit=2)
        assert len(page1) == 2
        cursor = db.get_message_history_timestamp(page1[1][4])
        ts, rid = cursor
        page2 = db.get_message_history("alice", with_user="bob",
                                       before=(ts, rid), limit=2)
        assert len(page2) == 2
        # 两页不重叠
        assert {r[4] for r in page1}.isdisjoint({r[4] for r in page2})

    def test_group_cursor_before(self, db):
        _make_users(db, "alice")
        gid = db.create_group("g", "alice")
        for i in range(4):
            _save_group(db, "alice", gid, f"grp{i}")
        first = db.get_message_history("alice", group_id=gid, limit=1)
        cursor = db.get_message_history_timestamp(first[0][4])
        older = db.get_message_history("alice", group_id=gid,
                                       before=cursor, limit=10)
        assert len(older) == 3

    def test_generic_cursor_before(self, db):
        """不指定 with_user / group_id 时按用户参与的所有消息分页。"""
        _make_users(db, "alice", "bob", "carol")
        for i in range(3):
            _save_chat(db, "alice", "bob", f"ab{i}")
        for i in range(2):
            _save_chat(db, "carol", "alice", f"ca{i}")
        first = db.get_message_history("alice", limit=1)
        cursor = db.get_message_history_timestamp(first[0][4])
        older = db.get_message_history("alice", before=cursor, limit=10)
        # 最新一条被排除，剩余 4 条
        assert len(older) == 4

    def test_cursor_before_nonexistent_message_returns_latest(self, db):
        """before_message_id 在历史表中不存在时，游标为 None，回退为最新一页。"""
        _make_users(db, "alice", "bob")
        _save_chat(db, "alice", "bob", "x")
        _save_chat(db, "alice", "bob", "y")
        rows = db.get_message_history("alice", with_user="bob",
                                      before=db.get_message_history_timestamp("ghost"),
                                      limit=10)
        assert len(rows) == 2


# ============================================================
# 第 3 组：历史状态更新（撤回）
# ============================================================

class TestHistoryStatusUpdate:

    def test_update_history_status_marks_recalled(self, db):
        _make_users(db, "alice", "bob")
        mid = _save_chat(db, "alice", "bob", "secret")
        assert db.update_message_history_status(mid, "recalled") is True
        rows = db.get_message_history("alice", with_user="bob")
        assert rows[0][8] == "recalled"  # status 列（最后一列）

    def test_update_history_status_group_variants(self, db):
        """群聊撤回时服务端用 LIKE 'mid_%' 批量更新变体。"""
        _make_users(db, "alice", "bob", "carol")
        gid = db.create_group("g", "alice")
        base = str(uuid.uuid4())
        # 群聊消息在 offline_messages 中以 base_bob / base_carol 存储，
        # 但在 message_history 中只存一条 base。这里直接验证 history 表。
        _save_group(db, "alice", gid, "hello", msg_id=base)
        assert db.update_message_history_status(base, "recalled") is True
        rows = db.get_message_history("alice", group_id=gid)
        assert rows[0][8] == "recalled"

    def test_update_history_status_nonexistent(self, db):
        assert db.update_message_history_status("ghost", "recalled") is False


# ============================================================
# 第 4 组：get_offline_messages —— 发出消息分支
# ============================================================

class TestOfflineMessagesSelfBranch:
    """get_offline_messages 合并接收与发出的消息（sender=? AND receiver!=?）。"""

    def test_includes_sent_by_self(self, db):
        _make_users(db, "alice", "bob")
        # alice 发给 bob 的消息
        db.save_offline_message("alice", "bob", "chat", b"hi bob",
                                message_id="m1")
        # alice 登录时应看到自己发出的消息（作为最近历史）
        msgs = db.get_offline_messages("alice")
        senders = [m[0] for m in msgs]
        assert "alice" in senders
        # 该消息 receiver 为 bob，非 alice
        self_msg = [m for m in msgs if m[0] == "alice"][0]
        assert self_msg[6] == "bob"  # receiver 字段

    def test_marks_received_sent_to_delivered(self, db):
        _make_users(db, "alice", "bob")
        db.save_offline_message("alice", "bob", "chat", b"hello",
                                message_id="m1")
        # bob 取消息 → alice 发给 bob 的那条应被标记 delivered
        db.get_offline_messages("bob")
        info = db.get_message_info("m1")
        assert info[5] == "delivered"

    def test_recalled_excluded_from_offline(self, db):
        _make_users(db, "alice", "bob")
        db.save_offline_message("alice", "bob", "chat", b"will recall",
                                message_id="m1")
        db.update_message_status("m1", "recalled")
        msgs = db.get_offline_messages("bob")
        assert all(m[4] != "m1" for m in msgs)

    def test_limit_500_caps_result(self, db):
        _make_users(db, "alice", "bob")
        for i in range(600):
            db.save_offline_message("alice", "bob", "chat",
                                    f"m{i}".encode(), message_id=f"id{i}")
        msgs = db.get_offline_messages("bob")
        assert len(msgs) == 500


# ============================================================
# 第 5 组：群组文件请求清理与响应
# ============================================================

class TestGroupFileCleanup:

    def _setup(self, db):
        _make_users(db, "alice", "bob", "carol")
        gid = db.create_group("fg", "alice")
        db.join_group(gid, "bob")
        db.join_group(gid, "carol")
        db.save_group_file_request(gid, "alice", "f.bin", 10, b"data", "gfr1")
        return gid

    def test_pending_excludes_responded(self, db):
        gid = self._setup(db)
        db.save_group_file_response("gfr1", gid, "bob", "accept")
        # bob 已响应 → 不再出现在 bob 的待处理列表
        pending_bob = db.get_pending_group_file_requests(gid, "bob")
        assert pending_bob == []
        # carol 未响应 → 仍出现
        assert len(db.get_pending_group_file_requests(gid, "carol")) == 1

    def test_delete_group_file_request_cascades_responses(self, db):
        gid = self._setup(db)
        db.save_group_file_response("gfr1", gid, "bob", "accept")
        db.save_group_file_response("gfr1", gid, "carol", "reject")
        assert db.delete_group_file_request("gfr1") is True
        assert db.get_group_file_request("gfr1") is None
        # 响应表也应被清空
        with db._get_connection() as conn:
            cur = conn.cursor()
            cur.execute("SELECT COUNT(*) FROM group_file_responses WHERE message_id=?", ("gfr1",))
            assert cur.fetchone()[0] == 0

    def test_cleanup_expired_group_file_requests(self, db):
        gid = self._setup(db)
        db.save_group_file_response("gfr1", gid, "bob", "accept")
        # 把时间改到 30 天前
        past = (datetime.now(UTC) - timedelta(days=30)).strftime('%Y-%m-%d %H:%M:%S')
        with db._get_connection() as conn:
            conn.execute("UPDATE group_file_requests SET timestamp=? WHERE message_id=?", (past, "gfr1"))
            conn.execute("UPDATE group_file_responses SET timestamp=? WHERE message_id=?", (past, "gfr1"))
            conn.commit()
        deleted = db.cleanup_expired_file_requests(expire_days=7)
        assert deleted >= 1
        assert db.get_group_file_request("gfr1") is None

    def test_cleanup_keeps_recent_group_file_request(self, db):
        gid = self._setup(db)
        deleted = db.cleanup_expired_file_requests(expire_days=7)
        assert deleted == 0
        assert db.get_group_file_request("gfr1") is not None


# ============================================================
# 第 6 组：好友请求边界
# ============================================================

class TestFriendRequestEdges:

    def test_add_request_blocked_when_already_friends_reverse(self, db):
        _make_users(db, "alice", "bob")
        db.add_friend_request("alice", "bob")
        db.accept_friend_request("alice", "bob")
        # 已是好友，反向再请求应被阻止
        assert db.add_friend_request("bob", "alice") is False

    def test_accept_nonexistent_request_returns_false(self, db):
        _make_users(db, "alice", "bob")
        assert db.accept_friend_request("alice", "bob") is False

    def test_reject_nonexistent_request_returns_false(self, db):
        _make_users(db, "alice", "bob")
        assert db.reject_friend_request("alice", "bob") is False

    def test_reject_then_can_re_request(self, db):
        _make_users(db, "alice", "bob")
        db.add_friend_request("alice", "bob")
        assert db.reject_friend_request("alice", "bob") is True
        # 拒绝后 alice 可以再次发起请求
        assert db.add_friend_request("alice", "bob") is True

    def test_add_request_nonexistent_user_returns_false(self, db):
        _make_users(db, "alice")
        assert db.add_friend_request("alice", "ghost") is False
        assert db.add_friend_request("ghost", "alice") is False


# ============================================================
# 第 7 组：save_message_history 幂等
# ============================================================

class TestSaveHistoryIdempotent:

    def test_duplicate_id_ignored(self, db):
        _make_users(db, "alice", "bob")
        mid = str(uuid.uuid4())
        assert db.save_message_history("alice", "bob", "chat", b"a",
                                       message_id=mid) is True
        # 相同 message_id 再次保存应被忽略
        assert db.save_message_history("alice", "bob", "chat", b"b",
                                       message_id=mid) is False
        msgs = db.get_message_history("alice", with_user="bob")
        assert len(msgs) == 1
        assert msgs[0][3] == b"a"

    def test_save_with_group_id(self, db):
        _make_users(db, "alice")
        gid = db.create_group("g", "alice")
        mid = str(uuid.uuid4())
        assert db.save_message_history("alice", "", "group_chat", b"hi",
                                       group_id=gid, message_id=mid) is True
        rows = db.get_message_history("alice", group_id=gid)
        assert len(rows) == 1
        assert rows[0][7] == gid  # group_id 列


# ============================================================
# 第 8 组：消息状态完整流转
# ============================================================

class TestMessageStatusFlow:

    def test_sent_to_delivered_to_recalled(self, db):
        _make_users(db, "alice", "bob")
        db.save_offline_message("alice", "bob", "chat", b"m", message_id="m1")
        assert db.get_message_info("m1")[5] == "sent"
        db.get_offline_messages("bob")  # → delivered
        assert db.get_message_info("m1")[5] == "delivered"
        db.update_message_status("m1", "recalled")
        assert db.get_message_info("m1")[5] == "recalled"

    def test_update_status_idempotent_returns_true(self, db):
        """对已存在的消息设置为相同状态仍返回 True（行存在即 True）。"""
        _make_users(db, "alice", "bob")
        db.save_offline_message("alice", "bob", "chat", b"m", message_id="m1")
        db.update_message_status("m1", "delivered")
        # 再次设置为 delivered，行仍存在 → True
        assert db.update_message_status("m1", "delivered") is True


# ============================================================
# 第 9 组：count 接口
# ============================================================

class TestHistoryCount:

    def test_count_per_group(self, db):
        _make_users(db, "alice")
        g1 = db.create_group("g1", "alice")
        g2 = db.create_group("g2", "alice")
        _save_group(db, "alice", g1, "a")
        _save_group(db, "alice", g1, "b")
        _save_group(db, "alice", g2, "c")
        assert db.get_message_history_count("alice", group_id=g1) == 2
        assert db.get_message_history_count("alice", group_id=g2) == 1

    def test_count_per_user_pair(self, db):
        _make_users(db, "alice", "bob", "carol")
        _save_chat(db, "alice", "bob", "1")
        _save_chat(db, "bob", "alice", "2")
        _save_chat(db, "alice", "carol", "3")
        assert db.get_message_history_count("alice", with_user="bob") == 2
        assert db.get_message_history_count("alice", with_user="carol") == 1
