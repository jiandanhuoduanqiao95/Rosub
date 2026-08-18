"""
============================================================
阶段 K —— 会话体验：K5 消息层数据库扩展（已实现，全部转绿）
============================================================

【目标】
  测试阶段 K5（P1-2 引用回复 / P1-4 表情回应，见《软件开发文档4.1.0.md》
  §11 阶段 K / §13.3 消息层）的数据库支撑：

    P1-2 引用回复（quote）：     message_history 增加 reply_to 列
    P1-4 表情回应（reaction）：  新增 reactions 表 + 增删查方法

  （用户决策修订：P1-1 消息编辑、P1-3 转发来源标注已移除——
  已发送消息仅保留/撤回/仅我删除（本地），转发以转发人为第一手，
  不存储来源标注。）

  另提供历史拉取扩展方法（服务端 history_response 改用它携带新字段，
  既有 9 元组 get_message_history 保持不动，避免破坏既有测试/调用方）。

【契约】
  （一）建表与迁移（旧库自动迁移，既有数据不受影响）
    message_history 新增列：
      reply_to        TEXT                         -- 引用原消息 message_id
    新表 reactions：
      message_id TEXT NOT NULL,
      username   TEXT NOT NULL,
      emoji      TEXT NOT NULL,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      PRIMARY KEY (message_id, username)

  （二）Database 新增方法（实现时按此命名与语义落地）
    save_message_history(..., reply_to=None)
      - 扩展参数（向后兼容：既有调用不受影响），落库到新列
    get_history_message(message_id) -> dict | None
      - 返回 {sender, receiver, message_type, content, filename,
              group_id, status, reply_to}
      - content 为 UTF-8 解码后的 str（解码失败返回空串）
      - 不存在 → None
    get_message_history_rows(user, with_user=None, group_id=None,
                             limit=50, before=None) -> list[dict]
      - 范围/排序与既有 get_message_history 完全一致（时间倒序）
      - 每行 dict 含上述 get_history_message 的全部字段
    set_reaction(message_id, username, emoji) -> bool
      - upsert：同用户换 emoji 时替换（保留一行）
      - 不存在则插入
    remove_reaction(message_id, username) -> bool
      - 不存在 → False（幂等）
    get_reactions(message_id) -> list[dict]
      - [{username, emoji}]，按 created_at 升序；无 → []

【运行】
  .venv/bin/python -m pytest tests/test_stage_k_db.py -v
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
    return Database(str(tmp_path / "stage_k.db"))


def _add_users(db, *names):
    for n in names:
        db.add_user(n, _hash("pw"))


def _save(db, sender, receiver, content, message_id=None, **kwargs):
    return db.save_message_history(
        sender, receiver, "chat", content.encode("utf-8"),
        message_id=message_id or str(uuid.uuid4()), **kwargs)


# ============================================================
# K5-1 —— 建表与迁移
# ============================================================

class TestStageKSchema:

    def test_new_database_has_extended_message_history_columns(self, db):
        """新库 message_history 含 reply_to 列（引用回复元数据）。"""
        with db._get_connection() as conn:
            cur = conn.cursor()
            cur.execute("PRAGMA table_info(message_history)")
            cols = {row[1]: row for row in cur.fetchall()}
            assert "reply_to" in cols

    def test_new_database_creates_reactions_table(self, db):
        """新库 reactions 表存在，主键 (message_id, username)。"""
        with db._get_connection() as conn:
            cur = conn.cursor()
            cur.execute(
                "SELECT name FROM sqlite_master "
                "WHERE type='table' AND name='reactions'")
            assert cur.fetchone() is not None, "reactions 表未创建"
            cur.execute("PRAGMA table_info(reactions)")
            rows = cur.fetchall()
            cols = {row[1]: row for row in rows}
            assert set(cols) >= {"message_id", "username", "emoji",
                                 "created_at"}
            pk_cols = [row[1] for row in rows if row[5] > 0]
            assert set(pk_cols) == {"message_id", "username"}

    def test_old_database_migrates_automatically(self, tmp_path):
        """旧库（message_history 无新列、无 reactions 表）初始化自动迁移。"""
        old_path = str(tmp_path / "old_k.db")
        conn = sqlite3.connect(old_path)
        try:
            conn.execute("""
                CREATE TABLE message_history (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    message_id TEXT UNIQUE NOT NULL,
                    sender TEXT NOT NULL,
                    receiver TEXT NOT NULL,
                    message_type TEXT NOT NULL,
                    content BLOB NOT NULL,
                    filename TEXT,
                    file_path TEXT,
                    group_id INTEGER,
                    status TEXT DEFAULT 'sent',
                    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            """)
            conn.execute(
                "INSERT INTO message_history "
                "(message_id, sender, receiver, message_type, content) "
                "VALUES ('legacy-1', 'alice', 'bob', 'chat', ?)",
                ("旧消息".encode("utf-8"),))
            conn.commit()
        finally:
            conn.close()

        migrated = Database(old_path)
        with migrated._get_connection() as conn:
            cur = conn.cursor()
            cur.execute("PRAGMA table_info(message_history)")
            cols = {row[1] for row in cur.fetchall()}
            assert "reply_to" in cols
            cur.execute("SELECT content FROM message_history "
                        "WHERE message_id = 'legacy-1'")
            row = cur.fetchone()
            assert row[0].decode("utf-8") == "旧消息"
            cur.execute(
                "SELECT name FROM sqlite_master "
                "WHERE type='table' AND name='reactions'")
            assert cur.fetchone() is not None


# ============================================================
# K5-2 —— save_message_history 扩展参数（P1-2 引用回复）
# ============================================================

class TestSaveMessageHistoryExtensions:

    def test_save_with_reply_to(self, db):
        _add_users(db, "alice", "bob")
        mid = str(uuid.uuid4())
        _save(db, "alice", "bob", "回复内容", message_id=mid,
              reply_to="orig-1")
        assert db.get_history_message(mid)["reply_to"] == "orig-1"

    def test_save_without_extensions_defaults_null(self, db):
        _add_users(db, "alice", "bob")
        mid = str(uuid.uuid4())
        _save(db, "alice", "bob", "普通消息", message_id=mid)
        assert db.get_history_message(mid)["reply_to"] is None

    def test_existing_callers_still_work(self, db):
        """向后兼容：既有签名调用不受扩展影响。"""
        _add_users(db, "alice", "bob")
        mid = str(uuid.uuid4())
        db.save_message_history("alice", "bob", "chat",
                                "旧调用".encode("utf-8"), message_id=mid)
        assert db.get_history_message(mid)["content"] == "旧调用"


# ============================================================
# K5-5 —— get_history_message / get_message_history_rows
# ============================================================

class TestGetHistoryMessage:

    def test_get_existing(self, db):
        _add_users(db, "alice", "bob")
        mid = str(uuid.uuid4())
        _save(db, "alice", "bob", "内容", message_id=mid)
        msg = db.get_history_message(mid)
        assert msg["sender"] == "alice"
        assert msg["receiver"] == "bob"
        assert msg["message_type"] == "chat"
        assert msg["content"] == "内容"
        assert msg["reply_to"] is None

    def test_get_nonexistent(self, db):
        assert db.get_history_message("ghost") is None


class TestGetMessageHistoryRows:

    def test_rows_are_dicts_with_new_fields(self, db):
        _add_users(db, "alice", "bob")
        mid = str(uuid.uuid4())
        _save(db, "alice", "bob", "内容", message_id=mid, reply_to="r1")
        rows = db.get_message_history_rows("alice", with_user="bob")
        assert isinstance(rows, list) and isinstance(rows[0], dict)
        keys = {"sender", "receiver", "message_type", "content",
                "message_id", "filename", "timestamp", "group_id",
                "status", "reply_to"}
        assert keys <= set(rows[0].keys())
        assert rows[0]["reply_to"] == "r1"

    def test_private_scope_and_order(self, db):
        _add_users(db, "alice", "bob")
        for i in range(3):
            _save(db, "alice", "bob", f"第{i}条", message_id=str(uuid.uuid4()))
        rows = db.get_message_history_rows("alice", with_user="bob", limit=2)
        assert len(rows) == 2
        assert rows[0]["content"] == "第2条"
        assert rows[1]["content"] == "第1条"

    def test_group_scope(self, db):
        _add_users(db, "alice")
        db.save_message_history("alice", "group", "group_chat",
                                "群消息".encode("utf-8"), group_id=9,
                                message_id=str(uuid.uuid4()))
        rows = db.get_message_history_rows("alice", group_id=9)
        assert len(rows) == 1
        assert rows[0]["group_id"] == 9
        assert db.get_message_history_rows("alice", group_id=5) == []

    def test_cursor_pagination_before(self, db):
        _add_users(db, "alice", "bob")
        mids = [str(uuid.uuid4()) for _ in range(3)]
        for i, mid in enumerate(mids):
            _save(db, "alice", "bob", f"第{i}条", message_id=mid)
        rows = db.get_message_history_rows("alice", with_user="bob",
                                           limit=10)
        ts, rid = db.get_message_history_timestamp(rows[-1]["message_id"])
        older = db.get_message_history_rows("alice", with_user="bob",
                                            limit=10, before=(ts, rid))
        older_ids = {r["message_id"] for r in older}
        assert rows[-1]["message_id"] not in older_ids


# ============================================================
# K5-6 —— reactions 表（P1-4 表情回应）
# ============================================================

class TestReactions:

    def test_set_new_reaction(self, db):
        _add_users(db, "alice")
        mid = str(uuid.uuid4())
        assert db.set_reaction(mid, "alice", "👍")
        assert db.get_reactions(mid) == [{"username": "alice", "emoji": "👍"}]

    def test_set_replaces_previous_emoji(self, db):
        """同用户同消息换 emoji → 替换（保留一行）。"""
        _add_users(db, "alice")
        mid = str(uuid.uuid4())
        db.set_reaction(mid, "alice", "👍")
        assert db.set_reaction(mid, "alice", "😂")
        assert db.get_reactions(mid) == [{"username": "alice", "emoji": "😂"}]

    def test_remove_reaction(self, db):
        _add_users(db, "alice", "bob")
        mid = str(uuid.uuid4())
        db.set_reaction(mid, "alice", "👍")
        db.set_reaction(mid, "bob", "👍")
        assert db.remove_reaction(mid, "alice") is True
        assert db.get_reactions(mid) == [{"username": "bob", "emoji": "👍"}]

    def test_remove_nonexistent_reaction_is_idempotent(self, db):
        _add_users(db, "alice")
        assert db.remove_reaction(str(uuid.uuid4()), "alice") is False

    def test_multiple_users_and_emojis(self, db):
        _add_users(db, "alice", "bob", "carol")
        mid = str(uuid.uuid4())
        db.set_reaction(mid, "alice", "👍")
        db.set_reaction(mid, "bob", "👍")
        db.set_reaction(mid, "carol", "😂")
        reactions = db.get_reactions(mid)
        by_emoji = {}
        for r in reactions:
            by_emoji.setdefault(r["emoji"], []).append(r["username"])
        assert sorted(by_emoji["👍"]) == ["alice", "bob"]
        assert by_emoji["😂"] == ["carol"]

    def test_reactions_isolated_by_message(self, db):
        _add_users(db, "alice")
        m1, m2 = str(uuid.uuid4()), str(uuid.uuid4())
        db.set_reaction(m1, "alice", "👍")
        db.set_reaction(m2, "alice", "😂")
        assert db.get_reactions(m1) == [{"username": "alice", "emoji": "👍"}]
        assert db.get_reactions(m2) == [{"username": "alice", "emoji": "😂"}]

    def test_reactions_persist_across_reopen(self, tmp_path):
        path = str(tmp_path / "reactions.db")
        db1 = Database(path)
        _add_users(db1, "alice")
        mid = str(uuid.uuid4())
        db1.set_reaction(mid, "alice", "👍")
        db2 = Database(path)
        assert db2.get_reactions(mid) == [{"username": "alice",
                                           "emoji": "👍"}]

    def test_emoji_special_characters_safe(self, db):
        """emoji/引号类内容不注入、不崩溃（参数化查询）。"""
        _add_users(db, "alice")
        mid = str(uuid.uuid4())
        payload = "👍'; DROP TABLE users;--"
        assert db.set_reaction(mid, "alice", payload)
        assert db.get_reactions(mid)[0]["emoji"] == payload
        assert db.user_exists("alice")
