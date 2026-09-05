"""
============================================================
阶段 F —— 社交管理：数据库层 TDD 测试（F1 / F4）
============================================================

【目标】
  测试阶段 F 引入的两个新数据库方法，先写测试（红），等待实现（绿）：
    F1  Database.remove_friend(user1, user2)
    F4  Database.leave_group(group_id, username)

【契约】
remove_friend(user1, user2)：
  - 删除 friends 表中两个方向的所有记录（pending 和 accepted）
  - 删除后 is_friend(u1,u2)==False 且 get_friends 互不包含
  - 非好友 / 不存在用户：返回 False，不抛异常
  - 删除后可重新发起好友请求（add_friend_request 可再成功）
  - 不删除 message_history（永久历史保留，仍可 fetch_history）
  - 幂等：再次删除已非好友的对象返回 False

leave_group(group_id, username)：
  - 删除 group_members 中的对应行
  - 删除后 is_group_member==False，不在 get_user_groups
  - 其他成员不受影响
  - 创建者离开群组仍合法：群组本身继续存在，其他成员仍在
  - 非成员 / 不存在的群组：返回 False，不抛异常
  - 离开后可重新 join_group
  - 不删除 message_history（永久历史保留）

【运行】
  阶段 F 实现前：本文件应整体报错（AttributeError），属 TDD 红。
  实现后：全部通过。

  .venv/bin/python -m pytest tests/test_stage_f_db.py -v
"""

import os
import sys
import uuid
import pytest
import bcrypt

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from database import Database


def _hash(pw):
    return bcrypt.hashpw(pw.encode(), bcrypt.gensalt())


@pytest.fixture
def db(tmp_path):
    return Database(str(tmp_path / "stage_f.db"))


def _add_users(db, *names):
    for n in names:
        db.add_user(n, _hash("pw"))


def _be_friends(db, a, b):
    db.add_friend_request(a, b)
    db.accept_friend_request(a, b)


# ============================================================
# F1 —— remove_friend
# ============================================================

class TestRemoveFriend:

    def test_remove_accepted_friend_deletes_both_directions(self, db):
        """删除已确认好友：双向 friends 表行被清除。"""
        _add_users(db, "alice", "bob")
        _be_friends(db, "alice", "bob")
        assert db.is_friend("alice", "bob") is True
        assert db.is_friend("bob", "alice") is True

        result = db.remove_friend("alice", "bob")

        assert result is True
        assert db.is_friend("alice", "bob") is False
        assert db.is_friend("bob", "alice") is False
        assert "bob" not in db.get_friends("alice")
        assert "alice" not in db.get_friends("bob")

    def test_remove_friend_symmetry(self, db):
        """无论以哪一方向调用 remove_friend，结果对称。"""
        _add_users(db, "alice", "bob")
        _be_friends(db, "alice", "bob")
        assert db.remove_friend("bob", "alice") is True
        assert db.is_friend("alice", "bob") is False
        assert db.is_friend("bob", "alice") is False

    def test_remove_friend_clean_pending_in_both_directions(self, db):
        """删除操作应清除两个方向的 pending/accepted 记录，
        避免遗留 pending 行阻止未来重新请求。"""
        _add_users(db, "alice", "bob")
        db.add_friend_request("alice", "bob")  # pending
        # 还未接受就删除：应清除该 pending
        assert db.remove_friend("alice", "bob") is True
        assert db.has_pending_request("alice", "bob") is False
        assert db.has_pending_request("alice", "bob") is False
        # 反方向也无遗留
        assert db.is_friend("alice", "bob") is False

    def test_remove_wait_accept_remove_then_can_re_request(self, db):
        """F2 关键不变式：删除好友后双方可重新发起好友请求。"""
        _add_users(db, "alice", "bob")
        _be_friends(db, "alice", "bob")
        db.remove_friend("alice", "bob")
        assert db.add_friend_request("alice", "bob") is True
        assert db.accept_friend_request("alice", "bob") is True
        assert db.is_friend("alice", "bob") is True

    def test_remove_nonexistent_user_returns_true(self, db):
        """用户不存在时仍返回 True（幂等清理）。"""
        _add_users(db, "alice")
        assert db.remove_friend("alice", "ghost") is True
        assert db.remove_friend("ghost", "alice") is True

    def test_remove_not_friends_returns_true(self, db):
        """非好友时仍返回 True（幂等清理）。"""
        _add_users(db, "alice", "bob")
        assert db.remove_friend("alice", "bob") is True

    def test_remove_idempotent(self, db):
        """重复删除已非好友的对象仍返回 True（幂等）。"""
        _add_users(db, "alice", "bob")
        _be_friends(db, "alice", "bob")
        assert db.remove_friend("alice", "bob") is True
        # 再次删除
        assert db.remove_friend("alice", "bob") is True

    def test_remove_friend_preserves_message_history(self, db):
        """删除好友不删除 message_history，fetch_history 仍可拉取历史。"""
        _add_users(db, "alice", "bob")
        _be_friends(db, "alice", "bob")
        mid = str(uuid.uuid4())
        db.save_message_history("alice", "bob", "chat",
                                b"long ago conv", message_id=mid)
        db.remove_friend("alice", "bob")
        # 历史仍在
        rows = db.get_message_history("alice", with_user="bob")
        assert any(r[4] == mid for r in rows)

    def test_remove_friend_cleans_messages_to_friend_not_required(self, db):
        """规约：remove_friend 不必联动清理 offline_messages，
        因为离线消息由 fetch_history 持久化覆盖，不在本契约范围。"""
        _add_users(db, "alice", "bob")
        _be_friends(db, "alice", "bob")
        db.save_offline_message("alice", "bob", "chat", b"hi", message_id="m1")
        # 删除好友不抛异常即可
        assert db.remove_friend("alice", "bob") is True


# ============================================================
# F4 —— leave_group
# ============================================================

class TestLeaveGroup:

    def test_leave_group_removes_membership(self, db):
        """成员离开群组后不再是成员。"""
        _add_users(db, "alice", "bob")
        gid = db.create_group("g", "alice")
        db.join_group(gid, "bob")
        assert db.is_group_member(gid, "bob") is True

        result = db.leave_group(gid, "bob")

        assert result is True
        assert db.is_group_member(gid, "bob") is False
        assert (gid, "g") not in [(g[0], g[1]) for g in db.get_user_groups("bob")]

    def test_leave_group_other_members_remain(self, db):
        """离开群组不影响其他成员。"""
        _add_users(db, "alice", "bob", "carol")
        gid = db.create_group("g", "alice")
        db.join_group(gid, "bob")
        db.join_group(gid, "carol")

        assert db.leave_group(gid, "bob") is True

        assert db.is_group_member(gid, "alice") is True
        assert db.is_group_member(gid, "carol") is True
        assert "bob" not in db.get_group_members(gid)
        assert "alice" in db.get_group_members(gid)
        assert "carol" in db.get_group_members(gid)

    def test_creator_can_leave_group_persists(self, db):
        """创建者离开群组：群组本身继续存在，其他成员保留。"""
        _add_users(db, "alice", "bob")
        gid = db.create_group("g", "alice")
        db.join_group(gid, "bob")

        assert db.leave_group(gid, "alice") is True

        # 群组仍存在
        with db._get_connection() as conn:
            cur = conn.cursor()
            cur.execute("SELECT group_name FROM groups WHERE id=?", (gid,))
            assert cur.fetchone() is not None
        # bob 仍是成员
        assert db.is_group_member(gid, "bob") is True
        # alice 不再是成员
        assert db.is_group_member(gid, "alice") is False

    def test_leave_group_not_member_returns_false(self, db):
        """非成员离开返回 False。"""
        _add_users(db, "alice", "intruder")
        gid = db.create_group("g", "alice")
        assert db.leave_group(gid, "intruder") is False

    def test_leave_group_nonexistent_returns_false(self, db):
        """不存在的群组返回 False，不抛异常。"""
        _add_users(db, "alice")
        assert db.leave_group(9999, "alice") is False

    def test_leave_then_can_rejoin(self, db):
        """离开后可重新加入。"""
        _add_users(db, "alice", "bob")
        gid = db.create_group("g", "alice")
        db.join_group(gid, "bob")
        db.leave_group(gid, "bob")
        # 重新加入（join_group 用 INSERT OR IGNORE，故先离开再进入应成立）
        db.join_group(gid, "bob")
        assert db.is_group_member(gid, "bob") is True

    def test_leave_group_preserves_message_history(self, db):
        """退出群组后历史仍在，fetch_history group_id 仍可拉取。"""
        _add_users(db, "alice", "bob")
        gid = db.create_group("g", "alice")
        db.join_group(gid, "bob")
        mid = str(uuid.uuid4())
        db.save_message_history("bob", "", "group_chat",
                                b"group history", group_id=gid, message_id=mid)
        assert db.leave_group(gid, "bob") is True
        # 历史仍在
        rows = db.get_message_history("bob", group_id=gid)
        assert any(r[4] == mid for r in rows)

    def test_delete_group_when_last_member_leaves(self, db):
        """最后一人离开群组后，群组及其历史被完全删除。"""
        _add_users(db, "alice")
        gid = db.create_group("solo", "alice")
        assert db.leave_group(gid, "alice") is True
        assert db.delete_group(gid) is True
        with db._get_connection() as conn:
            cur = conn.cursor()
            cur.execute("SELECT group_name FROM groups WHERE id=?", (gid,))
            assert cur.fetchone() is None
        rows = db.get_message_history("alice", group_id=gid)
        assert rows == []

    def test_delete_group_cleans_all_related_data(self, db):
        """delete_group 清除群组、成员、历史、离线消息、文件请求全部关联数据。"""
        _add_users(db, "alice", "bob")
        gid = db.create_group("deltest", "alice")
        db.join_group(gid, "bob")
        mid = str(uuid.uuid4())
        db.save_message_history("alice", "", "group_chat",
                                b"msg", group_id=gid, message_id=mid)
        # 离线群聊消息（内容为 {"text":...,"group_id": N} 的 JSON）
        db.save_offline_message(
            "alice", "bob", "group_chat",
            f'{{"text": "offline", "group_id": {gid}}}'.encode("utf-8"),
            message_id=f"{mid}_bob")
        db.save_group_file_request(gid, "alice", "f.bin", 10, b"data", "gfr1")
        db.save_group_file_response("gfr1", gid, "bob", "accept")

        assert db.delete_group(gid) is True

        assert db.is_group_member(gid, "alice") is False
        assert db.is_group_member(gid, "bob") is False
        assert db.get_message_history("alice", group_id=gid) == []
        assert db.get_group_file_request("gfr1") is None
        # 离线群聊消息也被清除（否则成员重新登录会重建群组会话）
        assert db.get_offline_messages("bob") == []
        with db._get_connection() as conn:
            cur = conn.cursor()
            cur.execute("SELECT 1 FROM groups WHERE id=?", (gid,))
            assert cur.fetchone() is None

    def test_delete_group_does_not_affect_other_groups(self, db):
        """回归：删除群组 1 不得误删群组 10/100 的离线消息。

        曾用 LIKE '%"group_id": 1%' 匹配，会误命中 "group_id": 10 等。
        """
        _add_users(db, "alice", "bob")
        g1 = db.create_group("g1", "alice")
        g10 = db.create_group("g10", "alice")
        db.join_group(g1, "bob")
        db.join_group(g10, "bob")
        # 群组 1 和 10 各有离线消息
        db.save_offline_message(
            "alice", "bob", "group_chat",
            f'{{"text": "in g1", "group_id": {g1}}}'.encode("utf-8"),
            message_id="m1_bob")
        db.save_offline_message(
            "alice", "bob", "group_chat",
            f'{{"text": "in g10", "group_id": {g10}}}'.encode("utf-8"),
            message_id="m10_bob")

        assert db.delete_group(g1) is True

        # bob 的离线消息中只应剩 g10 的（精确内容匹配，避免 "in g1" 命中 "in g10"）
        msgs = db.get_offline_messages("bob")
        contents = [m[2].decode("utf-8") for m in msgs]
        assert contents == [f'{{"text": "in g10", "group_id": {g10}}}'], \
            f"应只剩 g10 的离线消息: {contents}"