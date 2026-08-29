"""
============================================================
阶段 N —— 日常使用便利性：数据库层 TDD 契约测试（规划中，全部红）
============================================================

【目标】
  按《软件开发文档4.1.0.md》§13.9 阶段 N 编写数据库层契约测试：

    N7（P2-7 审计日志）：   audit_logs 新表 + 记录/查询方法
                            （删除用户/重置密码/发公告/群组治理等敏感操作
                            落库，管理面板可查）

  本文件仅覆盖数据库层；服务端协议层见 test_stage_n_server.py。

【契约（实现方需严格遵守，本测试即据此验证）】
  （一）audit_logs 新表（旧库自动迁移，CREATE TABLE IF NOT EXISTS）
    id         INTEGER PRIMARY KEY AUTOINCREMENT
    operator   TEXT NOT NULL        -- 操作者用户名
    action     TEXT NOT NULL        -- 操作类型（delete_user / reset_password /
                                    -- announcement / kick_member /
                                    -- transfer_owner / rename_group）
    target     TEXT NOT NULL DEFAULT ''   -- 操作对象（被删用户 / 被重置用户 /
                                          -- 被踢成员 / 新群主 / 群名等）
    detail     TEXT NOT NULL DEFAULT ''   -- 附加信息（公告内容 / 群组名等）
    timestamp  TIMESTAMP DEFAULT CURRENT_TIMESTAMP

  （二）Database 新增方法（实现时按此命名与语义落地）
    record_audit_log(operator, action, target='', detail='') -> int
      - 插入一条审计记录，返回新行 id；timestamp 由数据库自动生成
    get_audit_logs(limit=100, action=None) -> [dict]
      - 返回审计记录列表，**最新在前**（timestamp DESC，同秒按 id DESC）
      - 每项为 dict：{id, operator, action, target, detail, timestamp}
      - limit 限制返回条数（默认 100）；action 非空时仅返回该操作类型
      - 无记录 → []

【运行】
  实现前：本文件用例全部红（AttributeError / 断言失败），属 TDD 红。
  实现后：全部通过。

  .venv/bin/python -m pytest tests/test_stage_n_db.py -v
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from database import Database


# ============================================================
# N7 —— audit_logs 表结构
# ============================================================

class TestAuditLogsSchema:

    def test_new_database_has_audit_logs_table(self, db):
        """新建数据库自动创建 audit_logs 表（含全部列）。"""
        with db._get_connection() as conn:
            rows = conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='audit_logs'"
            ).fetchall()
        assert len(rows) == 1, f"audit_logs 表应存在: {rows}"
        with db._get_connection() as conn:
            cols = {r[1] for r in conn.execute("PRAGMA table_info(audit_logs)").fetchall()}
        assert {"id", "operator", "action", "target", "detail", "timestamp"} <= cols, \
            f"audit_logs 列不齐: {cols}"

    def test_old_database_migrates_audit_logs_table(self, tmp_path):
        """旧库（无 audit_logs 表）打开后自动建表（向后兼容迁移）。"""
        import sqlite3
        old_path = str(tmp_path / "old_n.db")
        conn = sqlite3.connect(old_path)
        try:
            conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT)")
            conn.execute("INSERT INTO users (username) VALUES ('alice')")
            conn.commit()
        finally:
            conn.close()
        # 重新打开（触发 _init_db 补建缺失表）
        reopened = Database(old_path)
        with reopened._get_connection() as conn:
            rows = conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='audit_logs'"
            ).fetchall()
        assert len(rows) == 1, "旧库打开后应自动补建 audit_logs 表"
        # 既有数据不受影响
        with reopened._get_connection() as conn:
            assert conn.execute("SELECT username FROM users").fetchall() == [("alice",)]

    def test_audit_logs_table_columns_defaults(self, db):
        """target/detail 列默认空字符串。"""
        db.record_audit_log("alice", "kick_member")
        with db._get_connection() as conn:
            row = conn.execute(
                "SELECT operator, action, target, detail FROM audit_logs"
            ).fetchone()
        assert row == ("alice", "kick_member", "", ""), f"默认值不符: {row}"


# ============================================================
# N7 —— record_audit_log
# ============================================================

class TestRecordAuditLog:

    def test_record_inserts_row(self, db):
        """record_audit_log 插入完整记录并返回行 id。"""
        rid = db.record_audit_log("admin", "delete_user", "bob")
        assert isinstance(rid, int) and rid > 0, f"应返回新行 id: {rid}"
        with db._get_connection() as conn:
            row = conn.execute(
                "SELECT operator, action, target, detail FROM audit_logs WHERE id=?", (rid,)
            ).fetchone()
        assert row == ("admin", "delete_user", "bob", ""), f"落库内容不符: {row}"

    def test_record_with_detail(self, db):
        """detail 附加信息落库。"""
        db.record_audit_log("alice", "kick_member", "bob", "开发群")
        with db._get_connection() as conn:
            row = conn.execute(
                "SELECT operator, action, target, detail FROM audit_logs"
            ).fetchone()
        assert row == ("alice", "kick_member", "bob", "开发群")

    def test_record_unicode_content(self, db):
        """中文操作者/对象/详情正常落库。"""
        db.record_audit_log("管理员", "公告", "全体用户", "系统将于今晚维护")
        with db._get_connection() as conn:
            row = conn.execute(
                "SELECT operator, action, target, detail FROM audit_logs"
            ).fetchone()
        assert row == ("管理员", "公告", "全体用户", "系统将于今晚维护")

    def test_record_multiple_entries(self, db):
        """多次记录互不覆盖，id 递增。"""
        r1 = db.record_audit_log("admin", "reset_password", "bob")
        r2 = db.record_audit_log("admin", "announcement", "全体用户", "公告内容")
        assert r2 > r1, "两次记录的 id 应递增"
        with db._get_connection() as conn:
            count = conn.execute("SELECT COUNT(*) FROM audit_logs").fetchone()[0]
        assert count == 2

    def test_record_timestamp_auto_generated(self, db):
        """timestamp 由数据库自动生成且可解析。"""
        import re
        db.record_audit_log("admin", "delete_user", "bob")
        with db._get_connection() as conn:
            ts = conn.execute("SELECT timestamp FROM audit_logs").fetchone()[0]
        assert re.match(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$", str(ts)), \
            f"timestamp 格式应为 'YYYY-MM-DD HH:MM:SS': {ts}"


# ============================================================
# N7 —— get_audit_logs
# ============================================================

class TestGetAuditLogs:

    def test_empty_on_fresh_database(self, db):
        """无记录时返回空列表。"""
        assert db.get_audit_logs() == []

    def test_fields_complete(self, db):
        """每项为完整 dict（含 id/timestamp）。"""
        db.record_audit_log("admin", "delete_user", "bob")
        logs = db.get_audit_logs()
        assert len(logs) == 1
        entry = logs[0]
        assert set(entry.keys()) == {"id", "operator", "action", "target",
                                     "detail", "timestamp"}, \
            f"字段不齐: {entry.keys()}"

    def test_newest_first_order(self, db):
        """最新在前；同秒多条按 id 倒序（后插入的在前）。"""
        db.record_audit_log("admin", "delete_user", "bob")
        db.record_audit_log("admin", "reset_password", "carol")
        db.record_audit_log("alice", "kick_member", "bob", "开发群")
        logs = db.get_audit_logs()
        assert [e["action"] for e in logs] == ["kick_member", "reset_password",
                                               "delete_user"], \
            f"应最新在前: {[e['action'] for e in logs]}"

    def test_limit(self, db):
        """limit 限制返回条数（默认 100）。"""
        for i in range(5):
            db.record_audit_log("admin", "delete_user", f"user{i}")
        assert len(db.get_audit_logs(limit=3)) == 3
        assert len(db.get_audit_logs()) == 5

    def test_action_filter(self, db):
        """action 过滤只返回指定操作类型。"""
        db.record_audit_log("admin", "delete_user", "bob")
        db.record_audit_log("admin", "reset_password", "carol")
        db.record_audit_log("alice", "kick_member", "dave", "开发群")
        logs = db.get_audit_logs(action="kick_member")
        assert len(logs) == 1 and logs[0]["target"] == "dave", f"过滤失败: {logs}"
        assert len(db.get_audit_logs(action="announcement")) == 0

    def test_action_filter_with_limit(self, db):
        """action 与 limit 组合生效。"""
        for i in range(4):
            db.record_audit_log("alice", "kick_member", f"u{i}", "群A")
            db.record_audit_log("admin", "delete_user", f"u{i}")
        logs = db.get_audit_logs(action="kick_member", limit=2)
        assert len(logs) == 2 and all(e["action"] == "kick_member" for e in logs)

    def test_entries_ordered_newest_even_same_action(self, db):
        """同一操作类型多条仍最新在前。"""
        db.record_audit_log("admin", "delete_user", "bob")
        db.record_audit_log("admin", "delete_user", "carol")
        logs = db.get_audit_logs(action="delete_user")
        assert [e["target"] for e in logs] == ["carol", "bob"]


class TestOfflineGroupIdN3b:
    """N3b 修复（2026-08-29）：offline_messages.group_id 列与平行查询。

    群文件离线补发按 group_id 路由——offline_messages 保存时记录群组，
    get_offline_group_ids 平行还原（get_offline_messages 元组形态不变）。
    """

    def test_save_offline_message_with_group_id(self, db):
        """save_offline_message 支持 group_id 参数并持久化。"""
        db.save_offline_message("alice", "bob", "file", b"x",
                                filename="photo.png",
                                message_id="n3b-off-1", group_id=7)
        gmap = db.get_offline_group_ids(["n3b-off-1"])
        assert gmap == {"n3b-off-1": 7}, f"群文件离线行应记录 group_id: {gmap}"

    def test_private_offline_message_no_group_id(self, db):
        """私聊文件离线行不产生 group_id（平行查询结果为空）。"""
        db.save_offline_message("alice", "bob", "file", b"x",
                                filename="doc.txt", message_id="n3b-off-2")
        assert db.get_offline_group_ids(["n3b-off-2"]) == {}
        assert db.get_offline_group_ids([]) == {}

    def test_get_offline_messages_tuple_shape_unchanged(self, db):
        """既有 9 元组形态不变（追加列不破坏既有解包）。"""
        db.save_offline_message("alice", "bob", "file", b"x",
                                filename="photo.png",
                                message_id="n3b-off-3", group_id=3)
        msgs = db.get_offline_messages("bob")
        assert len(msgs) == 1
        sender, msg_type, content, filename, msg_id, status, receiver, ts, fp = msgs[0]
        assert (sender, msg_type, msg_id, filename) == ("alice", "file", "n3b-off-3", "photo.png")
        assert receiver == "bob" and status in ("sent", "delivered")
