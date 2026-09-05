"""
============================================================
阶段 J —— 身份与社交：数据库层 TDD 契约（待实现）
============================================================

【目标】
  测试阶段 J（见《软件开发文档4.1.0.md》§11 阶段 J / §13.2 P0-2/P0-3/P0-5 /
  §13.3 P1-8/P1-9/P1-10）引入的数据库层能力：

    J1（P0-2 用户资料）：
      users 表新增列 nickname / avatar / signature / last_seen（旧库自动迁移）
      Database.set_profile / get_profile / update_last_seen

    J3（P0-5 管理员重置密码）：
      Database.admin_reset_password(username, new_hash)

    J4（P1-8/9/10 好友分组/备注名、黑名单、验证消息 + 用户搜索）：
      friends 表新增列 note / group_name / request_message（旧库自动迁移）
      set_friend_note / set_friend_group / get_friends_meta
      blocked_users 表（blocker, blocked, created_at，单向黑名单）
      block_user / unblock_user / is_blocked / get_blocked_users
      add_friend_request 扩展验证消息参数（向后兼容）+ get_pending_friend_requests_detail
      search_users（用户名模糊搜索）

【契约（实现方需严格遵守，本测试即据此验证）】
  ----- J1 users 表扩展 -----
  users 表新增 4 列（迁移：旧库初始化自动 ALTER TABLE ADD COLUMN）：
    nickname   TEXT DEFAULT ''   -- 昵称（空串=未设置）
    avatar     TEXT DEFAULT ''   -- 头像（空串=未设置；为 URL 或路径文本）
    signature  TEXT DEFAULT ''   -- 个性签名
    last_seen  TEXT              -- 最后在线时间（UTC 文本；NULL=从未在线）
  新增方法：
    set_profile(username, *, nickname=None, avatar=None, signature=None) -> bool
      - 部分更新语义：仅更新传入的非 None 字段，其余保持原值
      - nickname/avatar/signature 传 '' 表示清除（写回空串）
      - 用户不存在返回 False
    get_profile(username) -> dict | None
      - 返回 {username, nickname, avatar, signature, last_seen, is_admin, created_at}
      - 不存在返回 None
    update_last_seen(username) -> bool
      - 把 last_seen 更新为当前时间（CURRENT_TIMESTAMP）；用户不存在返回 False

  ----- J3 管理员重置密码 -----
    admin_reset_password(username, new_hash) -> bool
      - 直接覆写 users.password_hash（不校验旧密码）；用户不存在返回 False
      - 重置后：bcrypt.checkpw(新密码, 新哈希) 通过；旧密码哈希已失效

  ----- J4 friends 表扩展 -----
  friends 表新增 3 列（迁移同 J1）：
    note            TEXT DEFAULT ''  -- 好友备注名（视图方自己）
    group_name      TEXT DEFAULT ''  -- 好友分组名（'' = 未分组）
    request_message TEXT DEFAULT ''  -- 好友请求验证消息（pending 行）
  新增方法：
    set_friend_note(username, friend, note) -> bool
      - 仅更新"本视图方向"的行（user1=username, user2=friend）
      - 非好友关系（无 accepted 行）返回 False
    set_friend_group(username, friend, group_name) -> bool   （同上语义）
    get_friends_meta(username) -> list[dict]
      - 返回 [{username, note, group_name}, ...]，note/group_name 为视图方视角
      - 无好友返回 []
    block_user(blocker, blocked) -> bool
      - 写入 blocked_users（INSERT OR IGNORE，幂等）；不能拉黑自己（返回 False）
    unblock_user(blocker, blocked) -> bool
      - 删除记录；不存在返回 False
    is_blocked(blocker, blocked) -> bool
      - 单向语义：仅当 blocker 拉黑了 blocked 时为 True
    get_blocked_users(blocker) -> list[str]
    add_friend_request(requester, target, message=None) -> bool
      - 签名向后兼容（message 可选）；message 存入 request_message 列
    get_pending_friend_requests_detail(username) -> list[tuple]
      - 返回 [(requester, message), ...]，按创建时间排序
  blocked_users 表结构：
    blocker   TEXT NOT NULL,
    blocked   TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (blocker, blocked)
  delete_user(username) 应连带清理 blocked_users 中与 username 相关的记录。

  ----- J4 用户搜索 -----
    search_users(keyword, *, exclude=None, limit=50) -> list[str]
      - 按用户名 LIKE %keyword% 模糊匹配（大小写不敏感），排除 exclude 指定的用户名
      - 按用户名升序；limit 限制返回条数；无匹配返回 []

【运行】
  阶段 J 实现前：本文件应整体报错（AttributeError），属 TDD 红。
  实现后：全部通过。

  .venv/bin/python -m pytest tests/test_stage_j_db.py -v
"""

import os
import sqlite3
import sys

import pytest
import bcrypt

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from database import Database


def _hash(pw):
    return bcrypt.hashpw(pw.encode(), bcrypt.gensalt())


@pytest.fixture
def db(tmp_path):
    return Database(str(tmp_path / "stage_j.db"))


def _add_users(db, *names):
    for n in names:
        db.add_user(n, _hash("pw"))


def _make_friends(db, a, b):
    assert db.add_friend_request(a, b)
    assert db.accept_friend_request(a, b)


# ============================================================
# J1 —— users 表扩展 + 用户资料
# ============================================================

class TestUsersProfileSchema:

    def test_new_database_has_profile_columns(self, db):
        """新库 users 表含 nickname/avatar/signature/last_seen 4 列。"""
        with db._get_connection() as conn:
            cur = conn.cursor()
            cur.execute("PRAGMA table_info(users)")
            cols = {row[1] for row in cur.fetchall()}
            for col in ("nickname", "avatar", "signature", "last_seen"):
                assert col in cols, f"users 表缺少列: {col}"

    def test_old_database_migrates_automatically(self, tmp_path):
        """旧库（无资料列）初始化后自动补列，既有数据不受影响。"""
        old_path = str(tmp_path / "old_users_schema.db")
        conn = sqlite3.connect(old_path)
        try:
            conn.execute("""
                CREATE TABLE users (
                    id INTEGER PRIMARY KEY,
                    username TEXT UNIQUE NOT NULL,
                    password_hash TEXT NOT NULL,
                    is_admin BOOLEAN DEFAULT FALSE,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            """)
            conn.execute(
                "INSERT INTO users (username, password_hash, is_admin) "
                "VALUES (?, ?, 1)",
                ("legacy_user", _hash("pw")),
            )
            conn.commit()
        finally:
            conn.close()

        database = Database(old_path)
        with database._get_connection() as conn:
            cur = conn.cursor()
            cur.execute("PRAGMA table_info(users)")
            cols = {row[1] for row in cur.fetchall()}
            for col in ("nickname", "avatar", "signature", "last_seen"):
                assert col in cols, f"迁移后缺少列: {col}"
            cur.execute("SELECT username, is_admin, nickname FROM users")
            row = cur.fetchone()
            assert row is not None and row[0] == "legacy_user" and row[1] == 1
            assert row[2] == "", "迁移后 nickname 默认值应为空串"

    def test_get_profile_missing_returns_none(self, db):
        """不存在的用户 get_profile 返回 None。"""
        assert db.get_profile("ghost") is None

    def test_get_profile_defaults(self, db):
        """新用户未设置资料：昵称/头像/签名均为空串，last_seen 为 None。"""
        db.add_user("alice", _hash("pw"))
        p = db.get_profile("alice")
        assert p is not None
        assert p["username"] == "alice"
        assert p["nickname"] == ""
        assert p["avatar"] == ""
        assert p["signature"] == ""
        assert p["last_seen"] is None
        assert "is_admin" in p
        assert "created_at" in p


class TestSetProfile:

    def test_set_all_fields(self, db):
        """全字段设置：昵称/头像/签名可读回。"""
        _add_users(db, "alice")
        assert db.set_profile(
            "alice", nickname="爱丽丝", avatar="a.png", signature="你好") is True
        p = db.get_profile("alice")
        assert p["nickname"] == "爱丽丝"
        assert p["avatar"] == "a.png"
        assert p["signature"] == "你好"

    def test_partial_update_preserves_others(self, db):
        """部分更新：仅改昵称不影响头像/签名。"""
        _add_users(db, "alice")
        db.set_profile("alice", nickname="n", avatar="a.png", signature="s")
        db.set_profile("alice", nickname="n2")
        p = db.get_profile("alice")
        assert p["nickname"] == "n2"
        assert p["avatar"] == "a.png"
        assert p["signature"] == "s"

    def test_clear_by_empty_string(self, db):
        """传空串清除对应字段。"""
        _add_users(db, "alice")
        db.set_profile("alice", nickname="n", signature="s")
        db.set_profile("alice", nickname="", signature="")
        p = db.get_profile("alice")
        assert p["nickname"] == ""
        assert p["signature"] == ""

    def test_set_profile_nonexistent_user(self, db):
        """用户不存在返回 False。"""
        assert db.set_profile("ghost", nickname="x") is False

    def test_profile_persists_across_connections(self, tmp_path):
        """资料真实落盘：重开数据库仍可读。"""
        db_path = str(tmp_path / "profile_persist.db")
        db1 = Database(db_path)
        db1.add_user("alice", _hash("pw"))
        db1.set_profile("alice", nickname="昵称")

        db2 = Database(db_path)
        assert db2.get_profile("alice")["nickname"] == "昵称"

    def test_profile_special_characters(self, db):
        """昵称/签名含 SQL 特殊字符与中文不注入、不崩溃。"""
        _add_users(db, "alice")
        evil = 'x"; DROP TABLE users;--'
        assert db.set_profile("alice", nickname=evil, signature="签名'OR'1=1") is True
        p = db.get_profile("alice")
        assert p["nickname"] == evil
        assert p["signature"] == "签名'OR'1=1"
        assert db.user_exists("alice"), "恶意昵称不应导致 users 表被删"


class TestUpdateLastSeen:

    def test_update_last_seen(self, db):
        """update_last_seen 写入非空时间戳。"""
        _add_users(db, "alice")
        assert db.update_last_seen("alice") is True
        p = db.get_profile("alice")
        assert p["last_seen"] is not None
        assert p["last_seen"] != ""

    def test_update_last_seen_nonexistent(self, db):
        """用户不存在返回 False。"""
        assert db.update_last_seen("ghost") is False

    def test_last_seen_overwrites(self, db):
        """多次更新覆盖旧值。"""
        _add_users(db, "alice")
        db.update_last_seen("alice")
        p1 = db.get_profile("alice")["last_seen"]
        db.update_last_seen("alice")
        p2 = db.get_profile("alice")["last_seen"]
        assert p2 >= p1


# ============================================================
# J3 —— 管理员重置密码
# ============================================================

class TestAdminResetPassword:

    def test_reset_password_updates_hash(self, db):
        """admin_reset_password 覆写哈希，新密码校验通过、旧密码失效。"""
        db.add_user("alice", _hash("oldpass"))
        new_hash = _hash("newpass123")
        assert db.admin_reset_password("alice", new_hash) is True
        stored_hash, _ = db.get_user("alice")
        assert bcrypt.checkpw("newpass123".encode(), stored_hash)
        assert not bcrypt.checkpw("oldpass".encode(), stored_hash)

    def test_reset_password_nonexistent_user(self, db):
        """用户不存在返回 False。"""
        assert db.admin_reset_password("ghost", _hash("x")) is False

    def test_reset_password_then_login_flow(self, db):
        """重置后用户可登录、is_admin 不变。"""
        db.add_user("alice", _hash("old"), is_admin=True)
        db.admin_reset_password("alice", _hash("fresh123"))
        stored_hash, is_admin = db.get_user("alice")
        assert bcrypt.checkpw("fresh123".encode(), stored_hash)
        assert is_admin == 1

    def test_reset_password_does_not_touch_profile(self, db):
        """重置密码不影响用户资料。"""
        _add_users(db, "alice")
        db.set_profile("alice", nickname="保留")
        db.admin_reset_password("alice", _hash("new12345"))
        assert db.get_profile("alice")["nickname"] == "保留"


# ============================================================
# J4 —— 好友备注名 / 分组
# ============================================================

class TestFriendNoteSchema:

    def test_friends_table_has_new_columns(self, db):
        """friends 表含 note/group_name/request_message 3 列。"""
        with db._get_connection() as conn:
            cur = conn.cursor()
            cur.execute("PRAGMA table_info(friends)")
            cols = {row[1] for row in cur.fetchall()}
            for col in ("note", "group_name", "request_message"):
                assert col in cols, f"friends 表缺少列: {col}"

    def test_old_database_migrates_friend_columns(self, tmp_path):
        """旧库 friends 表无新列时初始化自动补列。"""
        old_path = str(tmp_path / "old_friends_schema.db")
        conn = sqlite3.connect(old_path)
        try:
            conn.execute("""
                CREATE TABLE users (
                    id INTEGER PRIMARY KEY,
                    username TEXT UNIQUE NOT NULL,
                    password_hash TEXT NOT NULL,
                    is_admin BOOLEAN DEFAULT FALSE,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            """)
            conn.execute("""
                CREATE TABLE friends (
                    user1 TEXT NOT NULL,
                    user2 TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'pending',
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (user1, user2)
                )
            """)
            conn.execute(
                "INSERT INTO users (username, password_hash) VALUES (?, ?)",
                ("alice", _hash("pw")))
            conn.execute(
                "INSERT INTO users (username, password_hash) VALUES (?, ?)",
                ("bob", _hash("pw")))
            conn.execute(
                "INSERT INTO friends (user1, user2, status) VALUES ('alice', 'bob', 'accepted')")
            conn.execute(
                "INSERT INTO friends (user1, user2, status) VALUES ('bob', 'alice', 'accepted')")
            conn.commit()
        finally:
            conn.close()

        database = Database(old_path)
        with database._get_connection() as conn:
            cur = conn.cursor()
            cur.execute("PRAGMA table_info(friends)")
            cols = {row[1] for row in cur.fetchall()}
            for col in ("note", "group_name", "request_message"):
                assert col in cols, f"迁移后缺少列: {col}"
            cur.execute("SELECT user1, user2, note, group_name FROM friends")
            rows = cur.fetchall()
            assert len(rows) == 2
            assert all(r[2] == "" and r[3] == "" for r in rows)


class TestSetFriendNote:

    def test_set_note_on_friend(self, db):
        """好友可设置备注名，视图方独立。"""
        _add_users(db, "alice", "bob")
        _make_friends(db, "alice", "bob")
        assert db.set_friend_note("alice", "bob", "阿波") is True
        meta = db.get_friends_meta("alice")
        assert meta[0]["username"] == "bob"
        assert meta[0]["note"] == "阿波"

    def test_note_is_directional(self, db):
        """备注名单向：alice 的备注不影响 bob 视角。"""
        _add_users(db, "alice", "bob")
        _make_friends(db, "alice", "bob")
        db.set_friend_note("alice", "bob", "阿波")
        db.set_friend_note("bob", "alice", "爱丽丝")
        a_meta = {m["username"]: m for m in db.get_friends_meta("alice")}
        b_meta = {m["username"]: m for m in db.get_friends_meta("bob")}
        assert a_meta["bob"]["note"] == "阿波"
        assert b_meta["alice"]["note"] == "爱丽丝"

    def test_set_note_clear_by_empty(self, db):
        """空串清除备注。"""
        _add_users(db, "alice", "bob")
        _make_friends(db, "alice", "bob")
        db.set_friend_note("alice", "bob", "备注")
        db.set_friend_note("alice", "bob", "")
        assert db.get_friends_meta("alice")[0]["note"] == ""

    def test_set_note_not_friend(self, db):
        """非好友关系返回 False。"""
        _add_users(db, "alice", "bob")
        assert db.set_friend_note("alice", "bob", "x") is False

    def test_set_note_nonexistent_friend(self, db):
        """不存在的对端用户返回 False。"""
        _add_users(db, "alice")
        assert db.set_friend_note("alice", "ghost", "x") is False

    def test_set_note_group_before_accept(self, db):
        """好友请求 pending 期间不可设备注（非好友）。"""
        _add_users(db, "alice", "bob")
        db.add_friend_request("alice", "bob")
        assert db.set_friend_note("alice", "bob", "x") is False


class TestSetFriendGroup:

    def test_set_group(self, db):
        """好友可被分入分组，未分组默认为空串。"""
        _add_users(db, "alice", "bob")
        _make_friends(db, "alice", "bob")
        assert db.set_friend_group("alice", "bob", "家人") is True
        meta = db.get_friends_meta("alice")[0]
        assert meta["username"] == "bob"
        assert meta["group_name"] == "家人"

    def test_group_is_directional(self, db):
        """分组单向：alice 的分组不影响 bob 视角。"""
        _add_users(db, "alice", "bob")
        _make_friends(db, "alice", "bob")
        db.set_friend_group("alice", "bob", "同事")
        b_meta = db.get_friends_meta("bob")[0]
        assert b_meta["username"] == "alice"
        assert b_meta["group_name"] == ""

    def test_group_clear_by_empty(self, db):
        """空串移出分组（回未分组）。"""
        _add_users(db, "alice", "bob")
        _make_friends(db, "alice", "bob")
        db.set_friend_group("alice", "bob", "同事")
        db.set_friend_group("alice", "bob", "")
        assert db.get_friends_meta("alice")[0]["group_name"] == ""

    def test_group_not_friend(self, db):
        """非好友设置分组返回 False。"""
        _add_users(db, "alice", "bob")
        assert db.set_friend_group("alice", "bob", "家人") is False


class TestGetFriendsMeta:

    def test_meta_for_all_friends(self, db):
        """多好友元数据齐全，顺序与 get_friends 一致。"""
        _add_users(db, "alice", "bob", "carol")
        _make_friends(db, "alice", "bob")
        _make_friends(db, "alice", "carol")
        db.set_friend_note("alice", "bob", "B")
        db.set_friend_group("alice", "carol", "同事")
        meta = {m["username"]: m for m in db.get_friends_meta("alice")}
        assert set(meta) == {"bob", "carol"}
        assert meta["bob"]["note"] == "B"
        assert meta["carol"]["group_name"] == "同事"

    def test_meta_no_friends(self, db):
        """无好友返回空列表。"""
        _add_users(db, "alice")
        assert db.get_friends_meta("alice") == []

    def test_meta_ignores_pending(self, db):
        """pending 好友请求不计入好友元数据。"""
        _add_users(db, "alice", "bob")
        db.add_friend_request("alice", "bob")
        assert db.get_friends_meta("alice") == []

    def test_meta_ignores_blocked_relation(self, db):
        """拉黑与好友关系互不影响：拉黑好友后元数据仍含对方。"""
        _add_users(db, "alice", "bob")
        _make_friends(db, "alice", "bob")
        db.block_user("alice", "bob")
        assert len(db.get_friends_meta("alice")) == 1


# ============================================================
# J4 —— 黑名单
# ============================================================

class TestBlockedSchema:

    def test_blocked_users_table_created(self, db):
        """新库创建 blocked_users 表，主键 (blocker, blocked)。"""
        with db._get_connection() as conn:
            cur = conn.cursor()
            cur.execute(
                "SELECT name FROM sqlite_master "
                "WHERE type='table' AND name='blocked_users'"
            )
            assert cur.fetchone() is not None, "blocked_users 表未创建"
            cur.execute("PRAGMA table_info(blocked_users)")
            rows = cur.fetchall()
            cols = {r[1]: r for r in rows}
            for col in ("blocker", "blocked", "created_at"):
                assert col in cols, f"缺少列: {col}"
            pk_cols = [r[1] for r in rows if r[5] > 0]
            assert set(pk_cols) == {"blocker", "blocked"}

    def test_old_database_migrates_blocked_table(self, tmp_path):
        """旧库初始化自动补建 blocked_users 表。"""
        old_path = str(tmp_path / "old_blocked_schema.db")
        conn = sqlite3.connect(old_path)
        try:
            conn.execute("""
                CREATE TABLE users (
                    id INTEGER PRIMARY KEY,
                    username TEXT UNIQUE NOT NULL,
                    password_hash TEXT NOT NULL,
                    is_admin BOOLEAN DEFAULT FALSE,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            """)
            conn.commit()
        finally:
            conn.close()
        database = Database(old_path)
        with database._get_connection() as conn:
            cur = conn.cursor()
            cur.execute(
                "SELECT name FROM sqlite_master "
                "WHERE type='table' AND name='blocked_users'"
            )
            assert cur.fetchone() is not None, "迁移后未建 blocked_users 表"


class TestBlockUser:

    def test_block_user(self, db):
        """拉黑成功，双向查询语义单向。"""
        _add_users(db, "alice", "bob")
        assert db.block_user("alice", "bob") is True
        assert db.is_blocked("alice", "bob") is True
        assert db.is_blocked("bob", "alice") is False, "黑名单为单向语义"

    def test_block_self_forbidden(self, db):
        """不能拉黑自己。"""
        _add_users(db, "alice")
        assert db.block_user("alice", "alice") is False

    def test_block_duplicate_idempotent(self, db):
        """重复拉黑幂等（不抛异常）。"""
        _add_users(db, "alice", "bob")
        assert db.block_user("alice", "bob") is True
        assert db.block_user("alice", "bob") is True
        assert len(db.get_blocked_users("alice")) == 1

    def test_block_multiple_users(self, db):
        """一个用户可拉黑多人。"""
        _add_users(db, "alice", "bob", "carol", "dave")
        db.block_user("alice", "bob")
        db.block_user("alice", "carol")
        assert set(db.get_blocked_users("alice")) == {"bob", "carol"}

    def test_block_isolation(self, db):
        """不同拉黑者互不影响。"""
        _add_users(db, "alice", "bob", "carol")
        db.block_user("alice", "bob")
        db.block_user("bob", "carol")
        assert db.get_blocked_users("alice") == ["bob"]
        assert db.get_blocked_users("bob") == ["carol"]
        assert db.get_blocked_users("carol") == []


class TestUnblockUser:

    def test_unblock_user(self, db):
        """解除拉黑后 is_blocked 为 False。"""
        _add_users(db, "alice", "bob")
        db.block_user("alice", "bob")
        assert db.unblock_user("alice", "bob") is True
        assert db.is_blocked("alice", "bob") is False

    def test_unblock_not_blocked(self, db):
        """解除不存在的拉黑返回 False。"""
        _add_users(db, "alice", "bob")
        assert db.unblock_user("alice", "bob") is False


class TestBlockedLifecycle:

    def test_delete_user_cleans_blocked_rows(self, db):
        """删除用户连带清理其作为拉黑者与被拉黑者的记录。"""
        _add_users(db, "alice", "bob", "carol")
        db.block_user("alice", "bob")
        db.block_user("bob", "alice")
        db.block_user("bob", "carol")
        db.delete_user("alice")
        assert db.get_blocked_users("alice") == []
        assert db.get_blocked_users("bob") == ["carol"], "仅清除与 alice 相关的记录"
        assert db.is_blocked("bob", "alice") is False

    def test_blocked_does_not_remove_friendship(self, db):
        """拉黑不自动删除好友关系（拦截由服务端业务层处理）。"""
        _add_users(db, "alice", "bob")
        _make_friends(db, "alice", "bob")
        db.block_user("alice", "bob")
        assert "bob" in db.get_friends("alice")

    def test_add_friend_request_does_not_clear_block(self, db):
        """DB 层 add_friend_request 不破坏黑名单（黑名单拦截在服务端业务层）。"""
        _add_users(db, "alice", "bob")
        db.block_user("alice", "bob")
        assert db.add_friend_request("bob", "alice") is True
        assert db.is_blocked("alice", "bob") is True


# ============================================================
# J4 —— 好友请求验证消息
# ============================================================

class TestFriendRequestMessage:

    def test_add_request_with_message(self, db):
        """带验证消息的请求落库 request_message 列。"""
        _add_users(db, "alice", "bob")
        assert db.add_friend_request("alice", "bob", message="我是 alice，来自项目组") is True
        detail = db.get_pending_friend_requests_detail("bob")
        assert (("alice", "我是 alice，来自项目组")) in detail

    def test_add_request_without_message_default(self, db):
        """不带验证消息时默认为空串（向后兼容）。"""
        _add_users(db, "alice", "bob")
        assert db.add_friend_request("alice", "bob") is True
        detail = db.get_pending_friend_requests_detail("bob")
        assert detail == [("alice", "")]

    def test_pending_names_still_works(self, db):
        """旧接口 get_pending_friend_requests 保持兼容（仅用户名）。"""
        _add_users(db, "alice", "bob")
        db.add_friend_request("alice", "bob", message="hi")
        assert db.get_pending_friend_requests("bob") == ["alice"]

    def test_accept_preserves_request_message(self, db):
        """接受请求后 request_message 仍可查（pending 行保留）。"""
        _add_users(db, "alice", "bob")
        db.add_friend_request("alice", "bob", message="验证信息")
        db.accept_friend_request("alice", "bob")
        with db._get_connection() as conn:
            cur = conn.cursor()
            cur.execute(
                "SELECT request_message FROM friends WHERE user1=? AND user2=?",
                ("alice", "bob"))
            row = cur.fetchone()
            assert row is not None and row[0] == "验证信息"

    def test_multiple_requests_detail_order(self, db):
        """多人请求时 detail 返回全部 (requester, message)。"""
        _add_users(db, "alice", "bob", "carol")
        db.add_friend_request("alice", "bob", message="m1")
        db.add_friend_request("carol", "bob", message="m2")
        detail = db.get_pending_friend_requests_detail("bob")
        assert set(detail) == {("alice", "m1"), ("carol", "m2")}


# ============================================================
# J4 —— 用户搜索
# ============================================================

class TestSearchUsers:

    def test_search_exact_match(self, db):
        """精确用户名可被搜到。"""
        _add_users(db, "alice", "bob")
        assert db.search_users("alice") == ["alice"]

    def test_search_partial_match(self, db):
        """部分匹配返回全部命中（升序）。"""
        _add_users(db, "alice", "alice2", "bob", "carol")
        assert db.search_users("ali") == ["alice", "alice2"]

    def test_search_case_insensitive(self, db):
        """大小写不敏感匹配。"""
        _add_users(db, "Alice", "bob")
        assert db.search_users("ALICE") == ["Alice"]

    def test_search_exclude(self, db):
        """exclude 排除指定用户（如排除自己）。"""
        _add_users(db, "alice", "bob", "alice2")
        assert db.search_users("ali", exclude="alice") == ["alice2"]

    def test_search_limit(self, db):
        """limit 限制返回条数。"""
        _add_users(db, "u1", "u2", "u3", "u4", "u5")
        assert len(db.search_users("u", limit=3)) == 3

    def test_search_no_match(self, db):
        """无匹配返回空列表。"""
        _add_users(db, "alice")
        assert db.search_users("xyz") == []

    def test_search_empty_keyword(self, db):
        """空关键字不返回任何结果。"""
        _add_users(db, "alice", "bob")
        assert db.search_users("") == []

    def test_search_only_registered_users(self, db):
        """仅搜索已注册用户（users 表）。"""
        assert db.search_users("alice") == []

    def test_search_does_not_leak_password(self, db):
        """搜索结果不含敏感字段（仅用户名）。"""
        _add_users(db, "alice")
        results = db.search_users("alice")
        assert results == ["alice"]
        assert all(isinstance(u, str) for u in results)
