"""
============================================================
阶段 I —— 消息可靠性 + 数据地基：I2 conversations 会话元数据表
（TDD 契约，待实现）
============================================================

【目标】
  测试阶段 I2 引入的 conversations 表（P0-8，见《软件开发文档4.1.0.md》
  §4.1 / §13.2 P0-8 / §11 阶段 I）：

    新增 conversations 表：
      username TEXT NOT NULL          -- 会话所属用户
      peer_key TEXT NOT NULL          -- 对端 key：好友用户名 或 'group_N'
      pinned   INTEGER DEFAULT 0      -- 置顶（0/1）
      muted    INTEGER DEFAULT 0      -- 静音（0/1）
      draft    TEXT DEFAULT ''        -- 逐会话草稿
      cleared_at TEXT                 -- 清空标记时间（UTC 文本；NULL=未清空）
      PRIMARY KEY (username, peer_key)

【契约】
  Database 新增方法（实现时按此命名与语义落地）：
    upsert_conversation(username, peer_key, *,
                        pinned=None, muted=None, draft=None, cleared_at=None)
      - 不存在则插入；存在则更新
      - 仅更新传入的非 None 字段，其余保持原值（部分更新语义）
      - pinned / muted 传 True/False 均可（0/1 归一）
      - cleared_at 传 None 表示"不清空"（保持原值）；传 '' 表示清除
      - 返回 True
    get_conversation(username, peer_key)
      - 返回 dict {username, peer_key, pinned(bool), muted(bool),
                    draft(str), cleared_at(str|None)}
      - 不存在返回 None
    get_conversations(username)
      - 返回该用户全部会话元数据 dict 列表（顺序不保证）
      - 无会话返回 []
    reset_conversation(username, peer_key)
      - 删除该行（CRUD 的 D）；幂等：不存在时返回 False 不抛异常
      - 删除后 get_conversation 返回 None
      迁移：旧库（无 conversations 表）初始化时自动建表，既有数据不受影响

【运行】
  阶段 I 实现前：本文件应整体报错（AttributeError），属 TDD 红。
  实现后：全部通过。

  .venv/bin/python -m pytest tests/test_stage_i_db.py -v
"""

import os
import sqlite3
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
    return Database(str(tmp_path / "stage_i.db"))


def _add_users(db, *names):
    for n in names:
        db.add_user(n, _hash("pw"))


# ============================================================
# I2-1 —— 建表与迁移
# ============================================================

class TestConversationsSchema:

    def test_new_database_creates_conversations_table(self, db):
        """新库初始化后 conversations 表存在，且含全部 6 列。"""
        with db._get_connection() as conn:
            cur = conn.cursor()
            cur.execute(
                "SELECT name FROM sqlite_master "
                "WHERE type='table' AND name='conversations'"
            )
            assert cur.fetchone() is not None, "conversations 表未创建"
            cur.execute("PRAGMA table_info(conversations)")
            cols = {row[1]: row for row in cur.fetchall()}
            for col in ("username", "peer_key", "pinned",
                        "muted", "draft", "cleared_at"):
                assert col in cols, f"缺少列: {col}"

    def test_conversations_table_primary_key(self, db):
        """主键为 (username, peer_key)，同一对只能存在一行。"""
        with db._get_connection() as conn:
            cur = conn.cursor()
            cur.execute("PRAGMA table_info(conversations)")
            pk_cols = [row[1] for row in cur.fetchall() if row[5] > 0]
            assert set(pk_cols) == {"username", "peer_key"}, \
                f"主键应为 (username, peer_key)，实际: {pk_cols}"

    def test_old_database_migrates_automatically(self, tmp_path):
        """旧库（无 conversations 表）初始化后自动建表，既有数据不受影响。

        模拟：手工用 sqlite3 创建一个仅含旧版 users 表与数据的库，
        再交给 Database() 初始化 —— 应自动补建 conversations 表。
        """
        old_path = str(tmp_path / "old_schema.db")
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

        db = Database(old_path)

        with db._get_connection() as conn:
            cur = conn.cursor()
            cur.execute(
                "SELECT name FROM sqlite_master "
                "WHERE type='table' AND name='conversations'"
            )
            assert cur.fetchone() is not None, "旧库迁移后未建 conversations 表"
            # 既有数据不受影响
            cur.execute("SELECT username, is_admin FROM users")
            row = cur.fetchone()
            assert row is not None and row[0] == "legacy_user" and row[1] == 1

    def test_migration_runs_on_existing_conversations_table(self, db):
        """重复初始化（表已存在）不报错，幂等。"""
        with db._get_connection() as conn:
            conn.execute("CREATE TABLE IF NOT EXISTS conversations_test_ok (id INTEGER)")
        db._init_db()
        with db._get_connection() as conn:
            cur = conn.cursor()
            cur.execute(
                "SELECT name FROM sqlite_master "
                "WHERE type='table' AND name='conversations'"
            )
            assert cur.fetchone() is not None


# ============================================================
# I2-2 —— 创建与默认值
# ============================================================

class TestConversationsCreate:

    def test_get_conversation_missing_returns_none(self, db):
        """不存在的会话返回 None（未设置元数据）。"""
        _add_users(db, "alice", "bob")
        assert db.get_conversation("alice", "bob") is None

    def test_upsert_creates_with_defaults(self, db):
        """首次 upsert（不传任何字段）创建默认元数据行。"""
        _add_users(db, "alice", "bob")
        assert db.upsert_conversation("alice", "bob") is True
        row = db.get_conversation("alice", "bob")
        assert row is not None
        assert row["pinned"] is False
        assert row["muted"] is False
        assert row["draft"] == ""
        assert row["cleared_at"] is None

    def test_upsert_creates_with_values(self, db):
        """首次 upsert 携带字段值创建完整行。"""
        _add_users(db, "alice", "bob")
        db.upsert_conversation(
            "alice", "bob",
            pinned=True, muted=True, draft="草稿内容",
            cleared_at="2026-08-12 10:00:00",
        )
        row = db.get_conversation("alice", "bob")
        assert row["pinned"] is True
        assert row["muted"] is True
        assert row["draft"] == "草稿内容"
        assert row["cleared_at"] == "2026-08-12 10:00:00"

    def test_group_peer_key_supported(self, db):
        """群聊会话使用 peer_key='group_N'，与私聊同表共存。"""
        _add_users(db, "alice", "bob")
        db.upsert_conversation("alice", "group_1", pinned=True)
        row = db.get_conversation("alice", "group_1")
        assert row is not None and row["pinned"] is True
        assert db.get_conversation("alice", "bob") is None


# ============================================================
# I2-3 —— 更新（部分更新语义）
# ============================================================

class TestConversationsUpdate:

    def test_upsert_updates_existing_row(self, db):
        """重复 upsert 更新而非插入（主键约束不冲突）。"""
        _add_users(db, "alice", "bob")
        db.upsert_conversation("alice", "bob", pinned=True)
        db.upsert_conversation("alice", "bob", muted=True)
        row = db.get_conversation("alice", "bob")
        assert row["pinned"] is True
        assert row["muted"] is True
        with db._get_connection() as conn:
            cur = conn.cursor()
            cur.execute(
                "SELECT COUNT(*) FROM conversations "
                "WHERE username=? AND peer_key=?",
                ("alice", "bob"),
            )
            assert cur.fetchone()[0] == 1

    def test_partial_update_preserves_other_fields(self, db):
        """仅更新 pinned 不影响 muted/draft/cleared_at。"""
        _add_users(db, "alice", "bob")
        db.upsert_conversation(
            "alice", "bob",
            pinned=False, muted=True, draft="d", cleared_at="2026-08-12 10:00:00",
        )
        db.upsert_conversation("alice", "bob", pinned=True)
        row = db.get_conversation("alice", "bob")
        assert row["pinned"] is True
        assert row["muted"] is True
        assert row["draft"] == "d"
        assert row["cleared_at"] == "2026-08-12 10:00:00"

    def test_unpin_by_false(self, db):
        """pinned=False 取消置顶。"""
        _add_users(db, "alice", "bob")
        db.upsert_conversation("alice", "bob", pinned=True)
        db.upsert_conversation("alice", "bob", pinned=False)
        assert db.get_conversation("alice", "bob")["pinned"] is False

    def test_unmute_by_false(self, db):
        """muted=False 取消静音。"""
        _add_users(db, "alice", "bob")
        db.upsert_conversation("alice", "bob", muted=True)
        db.upsert_conversation("alice", "bob", muted=False)
        assert db.get_conversation("alice", "bob")["muted"] is False

    def test_draft_update_and_clear(self, db):
        """草稿可更新；置空串表示清除草稿。"""
        _add_users(db, "alice", "bob")
        db.upsert_conversation("alice", "bob", draft="第一版")
        db.upsert_conversation("alice", "bob", draft="第二版")
        assert db.get_conversation("alice", "bob")["draft"] == "第二版"
        db.upsert_conversation("alice", "bob", draft="")
        assert db.get_conversation("alice", "bob")["draft"] == ""

    def test_cleared_at_set_and_clear(self, db):
        """清空标记可设置；传 '' 清除标记（回 None）。"""
        _add_users(db, "alice", "bob")
        db.upsert_conversation("alice", "bob", cleared_at="2026-08-12 10:00:00")
        assert db.get_conversation("alice", "bob")["cleared_at"] \
            == "2026-08-12 10:00:00"
        db.upsert_conversation("alice", "bob", cleared_at="")
        assert db.get_conversation("alice", "bob")["cleared_at"] is None

    def test_cleared_at_none_keeps_existing_value(self, db):
        """cleared_at=None 表示不清空（保持原值），不覆盖已有标记。"""
        _add_users(db, "alice", "bob")
        db.upsert_conversation("alice", "bob", cleared_at="2026-08-12 10:00:00")
        db.upsert_conversation("alice", "bob", draft="x")
        assert db.get_conversation("alice", "bob")["cleared_at"] \
            == "2026-08-12 10:00:00"

    def test_all_fields_set_at_once(self, db):
        """一次 upsert 同时设置全部字段。"""
        _add_users(db, "alice", "bob")
        db.upsert_conversation(
            "alice", "bob",
            pinned=True, muted=True, draft="全量",
            cleared_at="2026-08-12 10:00:00",
        )
        row = db.get_conversation("alice", "bob")
        assert row == {
            "username": "alice",
            "peer_key": "bob",
            "pinned": True,
            "muted": True,
            "draft": "全量",
            "cleared_at": "2026-08-12 10:00:00",
        }


# ============================================================
# I2-4 —— 查询与隔离
# ============================================================

class TestConversationsQuery:

    def test_get_conversations_returns_all_for_user(self, db):
        """get_conversations 返回该用户全部会话（含群聊）。"""
        _add_users(db, "alice", "bob", "carol")
        db.upsert_conversation("alice", "bob", pinned=True)
        db.upsert_conversation("alice", "carol", draft="d")
        db.upsert_conversation("alice", "group_1", muted=True)
        rows = db.get_conversations("alice")
        by_key = {r["peer_key"]: r for r in rows}
        assert set(by_key) == {"bob", "carol", "group_1"}
        assert by_key["bob"]["pinned"] is True
        assert by_key["carol"]["draft"] == "d"
        assert by_key["group_1"]["muted"] is True

    def test_get_conversations_no_rows_returns_empty(self, db):
        """无会话的用户返回空列表（非 None）。"""
        _add_users(db, "alice")
        assert db.get_conversations("alice") == []

    def test_user_isolation_same_peer_key(self, db):
        """同 peer_key 不同用户互不影响。"""
        _add_users(db, "alice", "bob", "carol")
        db.upsert_conversation("alice", "bob", pinned=True)
        db.upsert_conversation("carol", "bob", muted=True)
        assert db.get_conversation("alice", "bob")["pinned"] is True
        assert db.get_conversation("alice", "bob")["muted"] is False
        assert db.get_conversation("carol", "bob")["pinned"] is False
        assert db.get_conversation("carol", "bob")["muted"] is True
        # carol 不应看到 alice 的会话
        assert db.get_conversations("carol")[0]["peer_key"] == "bob"

    def test_conversation_isolation_different_peers(self, db):
        """同一用户的不同会话互不影响。"""
        _add_users(db, "alice", "bob", "carol")
        db.upsert_conversation("alice", "bob", pinned=True)
        row = db.get_conversation("alice", "carol")
        assert row is None or row["pinned"] is False


# ============================================================
# I2-5 —— 删除（CRUD 的 D）
# ============================================================

class TestConversationsDelete:

    def test_reset_conversation_deletes_row(self, db):
        """reset_conversation 删除整行，读回 None。"""
        _add_users(db, "alice", "bob")
        db.upsert_conversation("alice", "bob", pinned=True, draft="d")
        assert db.reset_conversation("alice", "bob") is True
        assert db.get_conversation("alice", "bob") is None
        assert db.get_conversations("alice") == []

    def test_reset_conversation_idempotent(self, db):
        """reset 不存在的会话返回 False，不抛异常。"""
        _add_users(db, "alice", "bob")
        assert db.reset_conversation("alice", "bob") is False
        assert db.reset_conversation("alice", "bob") is False

    def test_reset_only_affects_target_row(self, db):
        """删除一行不影响该用户其他会话、不影响其他用户。"""
        _add_users(db, "alice", "bob", "carol")
        db.upsert_conversation("alice", "bob", pinned=True)
        db.upsert_conversation("alice", "carol", pinned=True)
        db.upsert_conversation("bob", "carol", pinned=True)
        db.reset_conversation("alice", "bob")
        assert db.get_conversation("alice", "bob") is None
        assert db.get_conversation("alice", "carol")["pinned"] is True
        assert db.get_conversation("bob", "carol")["pinned"] is True


# ============================================================
# I2-6 —— 持久化与安全
# ============================================================

class TestConversationsPersistence:

    def test_data_persists_across_connections(self, tmp_path):
        """写入后重新打开数据库，数据仍在（真实落盘）。"""
        db_path = str(tmp_path / "persist.db")
        db1 = Database(db_path)
        db1.add_user("alice", _hash("pw"))
        db1.add_user("bob", _hash("pw"))
        db1.upsert_conversation("alice", "bob", pinned=True, draft="草稿")

        db2 = Database(db_path)
        row = db2.get_conversation("alice", "bob")
        assert row is not None
        assert row["pinned"] is True
        assert row["draft"] == "草稿"

    def test_special_characters_peer_key(self, db):
        """peer_key 含引号/中文/SQL 特殊字符不注入、不崩溃。"""
        _add_users(db, "alice")
        for key in ("o'brien", 'x"; DROP TABLE users;--', "张三",
                    "group_1' OR '1'='1"):
            db.upsert_conversation("alice", key, draft="safe")
            row = db.get_conversation("alice", key)
            assert row is not None and row["draft"] == "safe"
        # 其他会话不受影响
        assert db.get_conversation("alice", "bob") is None

    def test_roundtrip_full_lifecycle(self, db):
        """全生命周期：创建 → 更新 → 查询 → 删除 → 重建。"""
        _add_users(db, "alice", "bob")
        mid = str(uuid.uuid4())
        db.save_message_history("alice", "bob", "chat",
                                b"history", message_id=mid)
        db.upsert_conversation("alice", "bob", pinned=True)
        assert db.get_conversation("alice", "bob")["pinned"] is True
        db.upsert_conversation("alice", "bob", draft="hi")
        assert db.get_conversation("alice", "bob")["draft"] == "hi"
        assert db.reset_conversation("alice", "bob") is True
        assert db.get_conversation("alice", "bob") is None
        db.upsert_conversation("alice", "bob", muted=True)
        assert db.get_conversation("alice", "bob")["muted"] is True
        # 会话元数据操作不影响消息历史
        rows = db.get_message_history("alice", with_user="bob")
        assert any(r[4] == mid for r in rows)
