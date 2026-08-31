"""
============================================================
阶段 O —— 群组与消息增强：数据库层 TDD 契约测试（规划中，全部红）
============================================================

【目标】
  按《软件开发文档4.1.0.md》§13.9 阶段 O 编写数据库层契约测试：

    O1（用户已规划 群公告）：      groups.announcement 列 +
                                  set_group_announcement / get_group_announcement
    O2（用户已规划 群置顶）：      groups.pinned_message_id / pinned_preview 列 +
                                  pin_group_message / unpin_group_message
    O1+O2（list_groups 数据源）： get_group_notices 平行访问器
    O5（P2-5 定时消息）：         scheduled_messages 新表 + 增删查/到期扫描方法

  本文件仅覆盖数据库层；服务端协议层见 test_stage_o_server.py。

【契约（实现方需严格遵守，本测试即据此验证）】
  ----- O1 群公告 -----
  groups 表新增列（旧库自动迁移，ALTER TABLE ADD COLUMN）：
    announcement TEXT NOT NULL DEFAULT ''   -- 当前群公告文本（'' = 无公告）
  Database 新增方法：
    set_group_announcement(group_id, operator, text) -> bool
      - 仅群主（groups.created_by == operator）可设置；群不存在/非群主 → False
      - text 为空字符串表示**清除公告**（成功，返回 True）
      - 成功更新 announcement 列，返回 True
    get_group_announcement(group_id) -> str
      - 返回当前公告文本；群不存在 → ''

  ----- O2 群置顶（群主置顶某条群消息，全员可见横幅） -----
  groups 表新增列（旧库自动迁移）：
    pinned_message_id TEXT NOT NULL DEFAULT ''   -- 被置顶消息的 message_id
    pinned_preview    TEXT NOT NULL DEFAULT ''   -- 置顶内容快照（横幅渲染用，
                                                  -- 成员无需加载原消息即可显示）
  Database 新增方法：
    pin_group_message(group_id, operator, message_id) -> bool
      - 仅群主可置顶；群不存在/非群主 → False
      - message_id 必须属于该群（message_history.group_id == group_id 且存在），
        否则 → False（跨群置顶/不存在 → False）
      - 已撤回消息（status == 'recalled'）不可置顶 → False
      - 成功：pinned_message_id = message_id，pinned_preview 从历史行提取——
        content 非空取 content；否则 filename 非空取 "[文件] {filename}"；否则 ''
      - 重复置顶覆盖旧置顶（返回 True）
    unpin_group_message(group_id, operator) -> bool
      - 仅群主可取消；群不存在/非群主 → False
      - 未置顶时调用为幂等（清空两列，返回 True）

  ----- O1+O2 list_groups 数据源（平行访问器，仿 get_offline_extras 惯例） -----
    get_group_notices(username) -> dict
      - 返回 {group_id: {"announcement": str, "pinned_message_id": str,
                          "pinned_preview": str}}（仅该用户所属群组）
      - 供 group_list_json 组装 list_groups 推送的新增字段
        （announcement / pinned_message_id / pinned_preview；旧客户端忽略）
      - 无公告/未置顶 → 对应值为 ''

  ----- O5 定时消息（预约发送；O9 日程卡片依赖此基础） -----
  新表 scheduled_messages（旧库自动迁移，CREATE TABLE IF NOT EXISTS）：
    id          INTEGER PRIMARY KEY AUTOINCREMENT
    message_id  TEXT UNIQUE NOT NULL        -- 客户端生成的唯一 id（幂等/取消依据）
    sender      TEXT NOT NULL               -- 发送者
    receiver    TEXT NOT NULL DEFAULT ''    -- 私聊目标（群消息为空）
    group_id    INTEGER                     -- 群消息的群组 ID（私聊为 NULL）
    content     BLOB NOT NULL               -- 消息文本（UTF-8）
    schedule_at REAL NOT NULL               -- 预定发送时刻（epoch 秒，UTC 中立；
                                            -- "注意时区"以 epoch 比较，不做本地化换算）
    status      TEXT NOT NULL DEFAULT 'pending'   -- pending / sent / cancelled
    created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  Database 新增方法：
    add_scheduled_message(message_id, sender, content, schedule_at,
                          receiver=None, group_id=None) -> bool
      - content 为 str（内部 UTF-8 编码落库）；schedule_at 为 epoch 秒 float
      - message_id 冲突（已存在）→ False（幂等，不覆盖）
      - 成功插入 status='pending' 行，返回 True
    get_due_scheduled_messages(now=None) -> [dict]
      - now 缺省取当前时间（time.time()）；返回 status='pending' 且
        schedule_at <= now 的行，按 schedule_at ASC 排序
      - 每项 dict：{id, message_id, sender, receiver, group_id, content(str),
                    schedule_at}
      - 已投递（sent）/已取消（cancelled）永不返回
    mark_scheduled_message_sent(scheduled_id) -> None（幂等，置 status='sent'）
    cancel_scheduled_message(message_id, sender) -> bool
      - 仅发送者本人可取消（sender 不符 → False；不存在 → False）
      - 仅 pending 可取消；已 sent/cancelled → False；成功置 status='cancelled'
    list_scheduled_messages(sender) -> [dict]
      - 返回该用户自己的 pending 定时消息，按 schedule_at ASC；
        dict 字段同 get_due_scheduled_messages（另含 status）

  ----- 回归锁定 -----
    get_user_groups_detailed 保持 6 元组形态（阶段 M 契约：announcement 等新字段
    一律走 get_group_notices 平行访问器，不改动 6 元组——AGENTS.md 向后兼容红线）

【运行】
  实现前：本文件用例全部红（AttributeError / 断言失败），属 TDD 红。
  实现后：全部通过。

  .venv/bin/python -m pytest tests/test_stage_o_db.py -v
"""

import os
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from database import Database


def _create_group(db, name="开发组", owner="alice", members=("bob",)):
    """建群 + 拉入成员，返回 (gid, message_id)。"""
    gid = db.create_group(name, owner)
    for m in members:
        db.join_group(gid, m)
    return gid


def _save_group_message(db, gid, message_id, sender="bob", content="群里的消息"):
    """向历史表写一条群消息（置顶对象）。"""
    db.save_message_history(sender, "", "group_chat", content.encode("utf-8"),
                            group_id=gid, message_id=message_id)


# ============================================================
# O1 —— groups.announcement 列
# ============================================================

class TestGroupAnnouncementSchemaO1:

    def test_new_database_groups_has_announcement_column(self, db):
        """新建数据库 groups 表自带 announcement 列（默认空）。"""
        gid = _create_group(db)
        with db._get_connection() as conn:
            cols = {r[1] for r in conn.execute("PRAGMA table_info(groups)").fetchall()}
        assert "announcement" in cols, f"groups 应含 announcement 列: {cols}"
        with db._get_connection() as conn:
            row = conn.execute(
                "SELECT announcement FROM groups WHERE id = ?", (gid,)).fetchone()
        assert row == ("",), f"新群公告默认空字符串: {row}"

    def test_old_database_migrates_announcement_column(self, tmp_path):
        """旧库（无 announcement 列）打开后自动迁移补列，既有数据保留。"""
        old_path = str(tmp_path / "old_o1.db")
        conn = sqlite3.connect(old_path)
        try:
            conn.execute(
                "CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT)")
            conn.execute('''
                CREATE TABLE groups (
                    id INTEGER PRIMARY KEY,
                    group_name TEXT UNIQUE NOT NULL,
                    created_by TEXT NOT NULL,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            ''')
            conn.execute(
                "INSERT INTO groups (group_name, created_by) VALUES ('老群', 'alice')")
            conn.commit()
        finally:
            conn.close()
        reopened = Database(old_path)
        with reopened._get_connection() as conn:
            cols = {r[1] for r in conn.execute("PRAGMA table_info(groups)").fetchall()}
        assert {"announcement", "pinned_message_id", "pinned_preview"} <= cols, \
            f"旧库迁移应补齐阶段 O 列: {cols}"
        with reopened._get_connection() as conn:
            row = conn.execute(
                "SELECT group_name, created_by, announcement "
                "FROM groups WHERE group_name = '老群'").fetchone()
        assert row == ("老群", "alice", ""), f"既有数据不受迁移影响: {row}"

    def test_get_group_announcement_default_empty(self, db):
        """未发布公告的群 → get_group_announcement 返回空字符串。"""
        gid = _create_group(db)
        assert db.get_group_announcement(gid) == ""

    def test_get_group_announcement_missing_group(self, db):
        """群不存在 → 返回空字符串（不抛异常）。"""
        assert db.get_group_announcement(9999) == ""


# ============================================================
# O1 —— set_group_announcement
# ============================================================

class TestGroupAnnouncementDbO1:

    def test_owner_sets_announcement(self, db):
        """群主设置公告 → 落库并返回 True。"""
        gid = _create_group(db)
        assert db.set_group_announcement(gid, "alice", "周五 18:00 团建") is True
        assert db.get_group_announcement(gid) == "周五 18:00 团建"

    def test_non_owner_rejected(self, db):
        """非群主成员设置 → False，公告不变。"""
        gid = _create_group(db)
        assert db.set_group_announcement(gid, "bob", "篡改公告") is False
        assert db.get_group_announcement(gid) == ""

    def test_missing_group_rejected(self, db):
        """群不存在 → False。"""
        assert db.set_group_announcement(9999, "alice", "幽灵公告") is False

    def test_empty_text_clears_announcement(self, db):
        """空文本 = 清除公告（成功，返回 True）。"""
        gid = _create_group(db)
        db.set_group_announcement(gid, "alice", "临时公告")
        assert db.set_group_announcement(gid, "alice", "") is True
        assert db.get_group_announcement(gid) == ""

    def test_non_owner_cannot_clear(self, db):
        """非群主借空文本清除 → False，公告保留。"""
        gid = _create_group(db)
        db.set_group_announcement(gid, "alice", "保留公告")
        assert db.set_group_announcement(gid, "bob", "") is False
        assert db.get_group_announcement(gid) == "保留公告"

    def test_unicode_announcement_roundtrip(self, db):
        """中英文混排公告往返无损。"""
        gid = _create_group(db)
        text = "📢 Release v2.0 于下周一发布，请及时更新！"
        assert db.set_group_announcement(gid, "alice", text) is True
        assert db.get_group_announcement(gid) == text


# ============================================================
# O2 —— pin_group_message / unpin_group_message
# ============================================================

class TestGroupPinDbO2:

    def test_owner_pins_group_message(self, db):
        """群主置顶本群消息 → pinned_message_id/pinned_preview 落库。"""
        gid = _create_group(db)
        _save_group_message(db, gid, "o2-m1", sender="bob", content="重要通知")
        assert db.pin_group_message(gid, "alice", "o2-m1") is True
        notices = db.get_group_notices("alice")
        assert notices[gid]["pinned_message_id"] == "o2-m1"
        assert notices[gid]["pinned_preview"] == "重要通知"

    def test_pin_preview_falls_back_to_filename(self, db):
        """文件消息置顶 → preview 取 '[文件] {filename}'。"""
        gid = _create_group(db)
        db.save_message_history("bob", "", "group_chat", b"",
                                group_id=gid, message_id="o2-file",
                                filename="报告.pdf")
        assert db.pin_group_message(gid, "alice", "o2-file") is True
        assert db.get_group_notices("bob")[gid]["pinned_preview"] == "[文件] 报告.pdf"

    def test_non_owner_pin_rejected(self, db):
        """非群主置顶 → False，置顶状态不变。"""
        gid = _create_group(db)
        _save_group_message(db, gid, "o2-m2")
        assert db.pin_group_message(gid, "bob", "o2-m2") is False
        assert db.get_group_notices("alice")[gid]["pinned_message_id"] == ""

    def test_cross_group_message_rejected(self, db):
        """置顶其他群的消息 → False（message_id 不属于该群）。"""
        gid_a = _create_group(db, name="群A")
        gid_b = _create_group(db, name="群B")
        _save_group_message(db, gid_a, "o2-cross")
        assert db.pin_group_message(gid_b, "alice", "o2-cross") is False

    def test_missing_message_rejected(self, db):
        """置顶不存在的消息 → False。"""
        gid = _create_group(db)
        assert db.pin_group_message(gid, "alice", "ghost-id") is False

    def test_recalled_message_rejected(self, db):
        """已撤回消息不可置顶 → False。"""
        gid = _create_group(db)
        _save_group_message(db, gid, "o2-recalled")
        db.update_message_history_status("o2-recalled", "recalled")
        assert db.pin_group_message(gid, "alice", "o2-recalled") is False

    def test_unpin_clears_and_is_idempotent(self, db):
        """不带 message_id 取消全部置顶；未置顶时重复取消幂等成功。"""
        gid = _create_group(db)
        _save_group_message(db, gid, "o2-m3")
        db.pin_group_message(gid, "alice", "o2-m3")
        ok, removed = db.unpin_group_message(gid, "alice")
        assert ok is True and removed == "o2-m3"
        notices = db.get_group_notices("alice")
        assert notices[gid]["pinned_message_id"] == ""
        assert notices[gid]["pinned_preview"] == ""
        ok, removed = db.unpin_group_message(gid, "alice")
        assert ok is True and removed is None

    def test_unpin_non_owner_rejected(self, db):
        """非群主取消置顶 → (False, None)，置顶保留。"""
        gid = _create_group(db)
        _save_group_message(db, gid, "o2-m4")
        db.pin_group_message(gid, "alice", "o2-m4")
        assert db.unpin_group_message(gid, "bob") == (False, None)
        assert db.get_group_notices("alice")[gid]["pinned_message_id"] == "o2-m4"

    def test_multi_pin_coexist(self, db):
        """多置顶并存（2026-08-31 用户反馈）：重复置顶不同消息均成功，
        兼容快照取最早置顶的一条；单条取消不影响其余。"""
        gid = _create_group(db)
        _save_group_message(db, gid, "o2-p1", content="第一条置顶")
        _save_group_message(db, gid, "o2-p2", content="第二条置顶")
        db.pin_group_message(gid, "alice", "o2-p1")
        assert db.pin_group_message(gid, "alice", "o2-p2") is True
        pins = db.get_group_pinned_messages(gid)
        assert [p["message_id"] for p in pins] == ["o2-p1", "o2-p2"]
        assert pins[0]["preview"] == "第一条置顶"
        # 兼容快照 = 最早置顶
        notices = db.get_group_notices("alice")
        assert notices[gid]["pinned_message_id"] == "o2-p1"
        # 单条取消：其余保留
        ok, removed = db.unpin_group_message(gid, "alice", message_id="o2-p1")
        assert ok is True and removed == "o2-p1"
        assert [p["message_id"] for p in
                db.get_group_pinned_messages(gid)] == ["o2-p2"]
        # 兼容快照切到剩余最早一条
        assert db.get_group_notices("alice")[gid]["pinned_message_id"] == "o2-p2"

    def test_pin_duplicate_idempotent(self, db):
        """重复置顶同一消息幂等（不产生重复行）。"""
        gid = _create_group(db)
        _save_group_message(db, gid, "o2-dup")
        assert db.pin_group_message(gid, "alice", "o2-dup") is True
        assert db.pin_group_message(gid, "alice", "o2-dup") is True
        assert len(db.get_group_pinned_messages(gid)) == 1

    def test_unpin_all_and_missing_group(self, db):
        """不带 message_id 取消全部；群不存在 → (False, None)。"""
        gid = _create_group(db)
        _save_group_message(db, gid, "o2-a1")
        _save_group_message(db, gid, "o2-a2")
        db.pin_group_message(gid, "alice", "o2-a1")
        db.pin_group_message(gid, "alice", "o2-a2")
        ok, removed = db.unpin_group_message(gid, "alice")
        assert ok is True and removed == "o2-a1"
        assert db.get_group_pinned_messages(gid) == []
        assert db.unpin_group_message(9999, "alice") == (False, None)


# ============================================================
# O1+O2 —— get_group_notices 平行访问器
# ============================================================

class TestGroupNoticesExtras:

    def test_shape_complete(self, db):
        """返回 {gid: {announcement, pinned_message_id, pinned_preview}}。"""
        gid = _create_group(db)
        _save_group_message(db, gid, "o2-m5")
        db.set_group_announcement(gid, "alice", "公告A")
        db.pin_group_message(gid, "alice", "o2-m5")
        notices = db.get_group_notices("alice")
        assert set(notices.keys()) == {gid}
        assert set(notices[gid].keys()) == {
            "announcement", "pinned_message_id", "pinned_preview"}
        assert notices[gid]["announcement"] == "公告A"
        assert notices[gid]["pinned_message_id"] == "o2-m5"

    def test_defaults_empty_strings(self, db):
        """无公告/未置顶 → 三个值均为空字符串。"""
        gid = _create_group(db)
        notices = db.get_group_notices("bob")
        assert notices[gid] == {
            "announcement": "", "pinned_message_id": "", "pinned_preview": ""}

    def test_only_own_groups(self, db):
        """只包含自己所在的群组。

        修正记录（实现期）：原断言期望建群者 carol 的 notices 为空——与
        create_group 既有契约"建群者自动成为成员"矛盾（阶段 F 起如此，
        实现不得改动）。修正为断言 carol 只见自己建的群，核心不变式
        （bob 看不到 carol 的群）不变。
        """
        gid_a = _create_group(db, name="群A")
        gid_b = _create_group(db, name="群B", owner="carol", members=())
        db.set_group_announcement(gid_a, "alice", "A 公告")
        notices_bob = db.get_group_notices("bob")
        assert set(notices_bob.keys()) == {gid_a}, \
            "bob 不得看到 carol 的群"
        assert set(db.get_group_notices("carol").keys()) == {gid_b}, \
            "建群者自动为成员，只见自己的群"

    def test_user_with_no_groups(self, db):
        """不属于任何群 → 空 dict。"""
        assert db.get_group_notices("ghost") == {}


# ============================================================
# 回归锁定 —— 阶段 M 契约不回退
# ============================================================

class TestRegressionLocked:

    def test_get_user_groups_detailed_stays_6_tuple(self, db):
        """get_user_groups_detailed 保持 6 元组（M 契约：新字段走平行访问器）。

        AGENTS.md 阶段 M 维护注意：list_groups 在 {"id","group_name"} 基础上
        新增 created_by/avatar/history_visible/history_limit——阶段 O 的
        announcement/pinned_* 字段同样不得改动该 6 元组形态。
        """
        gid = _create_group(db, name="回归组")
        detailed = db.get_user_groups_detailed("alice")
        assert len(detailed) == 1
        row = detailed[0]
        assert len(row) == 6, f"应为 6 元组，实际 {len(row)}: {row}"
        assert (row[0], row[1], row[2]) == (gid, "回归组", "alice")


# ============================================================
# O5 —— scheduled_messages 表
# ============================================================

class TestScheduledMessagesSchemaO5:

    def test_new_database_has_scheduled_messages_table(self, db):
        """新建数据库自动创建 scheduled_messages 表（含全部列）。"""
        with db._get_connection() as conn:
            rows = conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table' "
                "AND name='scheduled_messages'").fetchall()
        assert len(rows) == 1, f"scheduled_messages 表应存在: {rows}"
        with db._get_connection() as conn:
            cols = {r[1] for r in conn.execute(
                "PRAGMA table_info(scheduled_messages)").fetchall()}
        assert {"id", "message_id", "sender", "receiver", "group_id",
                "content", "schedule_at", "status", "created_at"} <= cols, \
            f"scheduled_messages 列不齐: {cols}"

    def test_old_database_migrates_scheduled_messages(self, tmp_path):
        """旧库（无 scheduled_messages 表）打开后自动建表。"""
        old_path = str(tmp_path / "old_o5.db")
        conn = sqlite3.connect(old_path)
        try:
            conn.execute(
                "CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT)")
            conn.execute("INSERT INTO users (username) VALUES ('alice')")
            conn.commit()
        finally:
            conn.close()
        reopened = Database(old_path)
        with reopened._get_connection() as conn:
            rows = conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table' "
                "AND name='scheduled_messages'").fetchall()
        assert len(rows) == 1, "旧库打开后应自动补建 scheduled_messages 表"
        with reopened._get_connection() as conn:
            assert conn.execute(
                "SELECT username FROM users").fetchall() == [("alice",)]


# ============================================================
# O5 —— 定时消息增删查
# ============================================================

class TestScheduledMessagesDbO5:

    def test_add_and_shape(self, db):
        """add_scheduled_message 插入 pending 行并返回 True。"""
        due = time.time() + 60
        ok = db.add_scheduled_message("o5-1", "alice", "提醒站会",
                                      due, receiver="bob")
        assert ok is True
        rows = db.list_scheduled_messages("alice")
        assert len(rows) == 1
        row = rows[0]
        assert row["message_id"] == "o5-1"
        assert row["sender"] == "alice"
        assert row["receiver"] == "bob"
        assert row["group_id"] is None
        assert row["content"] == "提醒站会"
        assert row["schedule_at"] == due
        assert row["status"] == "pending"

    def test_add_group_scheduled(self, db):
        """群定时消息：receiver 为空、group_id 落库。"""
        gid = _create_group(db)
        ok = db.add_scheduled_message("o5-g1", "alice", "群提醒",
                                      time.time() + 60, group_id=gid)
        assert ok is True
        row = db.list_scheduled_messages("alice")[0]
        assert row["receiver"] == ""
        assert row["group_id"] == gid

    def test_add_duplicate_message_id_rejected(self, db):
        """message_id 冲突 → False（幂等，不覆盖原行）。"""
        due = time.time() + 60
        assert db.add_scheduled_message("o5-dup", "alice", "第一条",
                                        due, receiver="bob") is True
        assert db.add_scheduled_message("o5-dup", "alice", "第二条",
                                        due + 5, receiver="carol") is False
        rows = db.list_scheduled_messages("alice")
        assert len(rows) == 1 and rows[0]["content"] == "第一条"

    def test_get_due_excludes_future(self, db):
        """未到期的 pending 不返回。"""
        db.add_scheduled_message("o5-f1", "alice", "还没到点",
                                 time.time() + 3600, receiver="bob")
        assert db.get_due_scheduled_messages() == []

    def test_get_due_includes_at_boundary(self, db):
        """schedule_at == now（恰好到期）包含在内（<= 语义）。"""
        now = time.time()
        db.add_scheduled_message("o5-b1", "alice", "到点了",
                                 now, receiver="bob")
        rows = db.get_due_scheduled_messages(now=now + 1)
        assert [r["message_id"] for r in rows] == ["o5-b1"]

    def test_get_due_excludes_sent_and_cancelled(self, db):
        """已投递（sent）/已取消（cancelled）永不返回。"""
        due = time.time() - 1
        db.add_scheduled_message("o5-s1", "alice", "已发", due, receiver="bob")
        db.add_scheduled_message("o5-c1", "alice", "已取消", due, receiver="bob")
        rows = db.get_due_scheduled_messages()
        assert len(rows) == 2
        db.mark_scheduled_message_sent(rows[0]["id"])
        db.cancel_scheduled_message("o5-c1", "alice")
        assert db.get_due_scheduled_messages() == []

    def test_mark_sent_idempotent(self, db):
        """mark_scheduled_message_sent 可重复调用（幂等）。"""
        db.add_scheduled_message("o5-m1", "alice", "x",
                                 time.time() - 1, receiver="bob")
        row = db.get_due_scheduled_messages()[0]
        db.mark_scheduled_message_sent(row["id"])
        db.mark_scheduled_message_sent(row["id"])
        assert db.get_due_scheduled_messages() == []
        assert db.list_scheduled_messages("alice") == []

    def test_cancel_by_sender(self, db):
        """本人取消 pending → True 且状态 cancelled。"""
        db.add_scheduled_message("o5-x1", "alice", "取消我",
                                 time.time() + 3600, receiver="bob")
        assert db.cancel_scheduled_message("o5-x1", "alice") is True
        assert db.list_scheduled_messages("alice") == []

    def test_cancel_by_other_rejected(self, db):
        """非本人取消 → False（即便消息存在）。"""
        db.add_scheduled_message("o5-x2", "alice", "别人的",
                                 time.time() + 3600, receiver="bob")
        assert db.cancel_scheduled_message("o5-x2", "bob") is False
        assert db.cancel_scheduled_message("o5-x2", "admin") is False
        assert len(db.list_scheduled_messages("alice")) == 1

    def test_cancel_missing_or_not_pending_rejected(self, db):
        """不存在/已投递的定时消息不可取消 → False。"""
        assert db.cancel_scheduled_message("ghost", "alice") is False
        db.add_scheduled_message("o5-x3", "alice", "已发",
                                 time.time() - 1, receiver="bob")
        row = db.get_due_scheduled_messages()[0]
        db.mark_scheduled_message_sent(row["id"])
        assert db.cancel_scheduled_message("o5-x3", "alice") is False

    def test_list_sorted_by_schedule_at_and_scoped(self, db):
        """list 按 schedule_at 升序；只含本人的 pending；中文内容往返。"""
        base = time.time() + 1000
        db.add_scheduled_message("o5-l2", "alice", "晚的", base + 100,
                                 receiver="bob")
        db.add_scheduled_message("o5-l1", "alice", "早的：早上好", base,
                                 receiver="bob")
        db.add_scheduled_message("o5-l3", "bob", "别人的", base + 50,
                                 receiver="alice")
        db.add_scheduled_message("o5-l4", "alice", "已取消", base - 100,
                                 receiver="bob")
        db.cancel_scheduled_message("o5-l4", "alice")
        rows = db.list_scheduled_messages("alice")
        assert [r["message_id"] for r in rows] == ["o5-l1", "o5-l2"]
        assert rows[0]["content"] == "早的：早上好"

    def test_unicode_content_roundtrip(self, db):
        """中文/emoji 内容经 encode-decode 往返无损。"""
        text = "🎉 明天上午 9:00 提醒大家站会！"
        db.add_scheduled_message("o5-u1", "alice", text,
                                 time.time() + 60, receiver="bob")
        assert db.list_scheduled_messages("alice")[0]["content"] == text
