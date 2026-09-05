"""
============================================================
阶段 M —— 群组治理 + 运维：数据库层 TDD 契约测试（规划中，全部红）
============================================================

【目标】
  按《软件开发文档4.1.0.md》§11 阶段 M / §13.3 编写数据库层契约测试：

    M1（P1-16 群主权限）：   groups 表扩展（avatar / history_visible /
                            history_limit）+ 踢人 / 转让群主 / 改名 / 群头像
    M2（P1-17 入群审批/邀请）：group_join_requests + group_invitations 新表
                            与审批/邀请全流程方法
    M3（P1-18 历史可见性）： 群主可开关新成员历史可见性（默认最近 N 条）
    M6（P1-21 存储治理）：   过期 delivered 消息清理 + 存储占用统计
                            （9.3 阶段 C 剩余项并入本任务）
    M8（P1-5 文件校验）：    file_requests / group_file_requests 新增
                            sha256 列 + 文件收发历史查询

【契约（实现方需严格遵守，本测试即据此验证）】
  （一）groups 表扩展（旧库自动迁移）
    avatar          TEXT DEFAULT ''     -- 群头像（字符串，如 base64/路径）
    history_visible INTEGER DEFAULT 1   -- 新成员历史可见性（1=可见最近 N 条）
    history_limit   INTEGER DEFAULT 50  -- 可见的历史条数上限（N）
    群主 = groups.created_by（既有列，转让群主 = 更新该列）

  （二）Database 新增方法（实现时按此命名与语义落地）
    get_group_info(group_id) -> dict | None
      - 返回 {id, group_name, created_by, avatar, history_visible,
              history_limit, member_count}；群不存在 → None
    kick_group_member(group_id, username, target) -> bool
      - 仅群主（groups.created_by == username）可踢；不能踢群主/自己
      - target 必须是成员；成功后从 group_members 删除该行
    transfer_group_owner(group_id, username, target) -> bool
      - 仅群主可转让；target 必须是成员且非本人；成功后 created_by = target
    rename_group(group_id, username, new_name) -> bool
      - 仅群主可改名；新名称非空且不与既有群组重名（group_name UNIQUE）
    （2026-08-25 用户决策：头像功能已废除——set_group_avatar 方法
    保留但无 UI/测试使用；avatar 列保留，get_group_info 仍返回该字段）
    set_group_history_visibility(group_id, username, visible, limit) -> bool
      - 仅群主可设置（M3）；visible 为 1/0，limit 为可见条数上限
    request_join_group(group_id, username) -> bool
      - 入群申请（M2）：群存在 + 非成员 + 无既有 pending 申请 → 插入
      - 已是成员 / 已有申请 / 群不存在 → False
    get_pending_group_join_requests(group_id) -> [username]
    has_pending_group_join_request(group_id, username) -> bool
    approve_join_request(group_id, approver, target) -> bool
      - 仅群主可批准：删除申请行 + 加入群组（join_group）
      - 非群主 / 无申请 → False
    reject_join_request(group_id, approver, target) -> bool
      - 仅群主可拒绝：删除申请行；非群主 / 无申请 → False
    invite_group_member(group_id, inviter, invitee) -> bool
      - 邀请制（M2）：inviter 必须是群成员；invitee 存在、非成员、
        无既有邀请 → 插入 group_invitations（status='pending'）
    get_pending_group_invitations(username) -> [(group_id, group_name, inviter)]
    accept_group_invite(group_id, username) -> bool
      - 有邀请 → 删除邀请行 + 加入群组；无邀请 → False
    decline_group_invite(group_id, username) -> bool
      - 有邀请 → 删除邀请行；无邀请 → False
    cleanup_expired_delivered_messages(days=30) -> int
      - 删除 offline_messages 中 status='delivered' 且超过 N 天的行
      - status='sent'（未读）不删；message_history 永久保留不删（9.3）
    get_storage_stats() -> dict
      - 返回 {file_store_bytes, file_count, db_bytes, message_count,
              pending_file_requests}
      - file_store 为数据库同级 file_store/ 目录（pending + history 子目录）
    get_message_count() -> int          -- message_history 总行数
    get_pending_file_request_count() -> int
      -- file_requests + group_file_requests 中 status != 'recalled' 的行数
    get_file_stats() -> dict
      - 返回 {file_count, file_store_bytes}（file_store 目录递归统计）
    save_file_request(..., sha256=None) / save_group_file_request(..., sha256=None)
      - 扩展参数（向后兼容），落库到新列
    get_file_request_extras(message_id) -> {"sha256": ...} | None
    get_group_file_request_extras(message_id) -> {"sha256": ...} | None
      - 仿 get_offline_extras 惯例：不改动既有 get_file_request 的 7 元组
        形态（既有测试/服务端解包依赖），新增平行访问器
    get_user_file_messages(username, with_user=None, group_id=None)
      -> [dict]（P1-7 文件收发管理页数据）
      - message_history 中 message_type='file' 的行：
        私聊（with_user）：sender/receiver 含 username 与 with_user 双向
        群聊（group_id）：该群全部 file 历史（含他人发送）
        缺省：该用户参与的全部 file 消息
      - 每项 {filename, filesize, sender, receiver, message_id, timestamp,
              group_id, status}；filesize 取 file_path 实际字节数
        （文件不存在 → 0）

  （三）新表
    group_join_requests (
        group_id   INTEGER NOT NULL,
        username   TEXT NOT NULL,
        status     TEXT DEFAULT 'pending',
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (group_id, username)
    )
    group_invitations (
        group_id   INTEGER NOT NULL,
        username   TEXT NOT NULL,       -- 被邀请者
        inviter    TEXT NOT NULL,
        status     TEXT DEFAULT 'pending',
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (group_id, username)
    )

【运行】
  实现前：本文件全部红（方法不存在 → AttributeError），属 TDD 红。
  实现后：全部通过。

  .venv/bin/python -m pytest tests/test_stage_m_db.py -v
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
    return Database(str(tmp_path / "stage_m.db"))


def _add_users(db, *names):
    for n in names:
        db.add_user(n, _hash("pw"))


def _create_group(db, name, creator, *members):
    gid = db.create_group(name, creator)
    for m in members:
        db.join_group(gid, m)
    return gid


# ============================================================
# M1 —— groups 表扩展：建表与迁移
# ============================================================

class TestStageMGroupsSchema:

    def test_new_database_has_group_governance_columns(self, db):
        """新库 groups 表含 avatar / history_visible / history_limit 列。"""
        with db._get_connection() as conn:
            cur = conn.cursor()
            cur.execute("PRAGMA table_info(groups)")
            cols = {row[1]: row for row in cur.fetchall()}
            assert {"avatar", "history_visible", "history_limit"} <= set(cols)

    def test_new_columns_defaults(self, db):
        """默认值：avatar 空串、history_visible=1、history_limit=50。"""
        _add_users(db, "alice")
        gid = db.create_group("默认群", "alice")
        with db._get_connection() as conn:
            row = conn.execute(
                "SELECT avatar, history_visible, history_limit "
                "FROM groups WHERE id = ?", (gid,)).fetchone()
        assert row == ("", 1, 50), f"默认值应为 空/1/50: {row}"

    def test_old_database_migrates_group_columns(self, tmp_path):
        """旧库（groups 无新列）初始化自动迁移，既有数据保留。"""
        old_path = str(tmp_path / "old_m.db")
        conn = sqlite3.connect(old_path)
        try:
            conn.execute("""
                CREATE TABLE groups (
                    id INTEGER PRIMARY KEY,
                    group_name TEXT UNIQUE NOT NULL,
                    created_by TEXT NOT NULL,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            """)
            conn.execute("""
                CREATE TABLE group_members (
                    group_id INTEGER NOT NULL,
                    username TEXT NOT NULL,
                    joined_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (group_id, username)
                )
            """)
            conn.execute(
                "INSERT INTO groups (id, group_name, created_by) "
                "VALUES (1, '旧群', 'alice')")
            conn.execute(
                "INSERT INTO group_members (group_id, username) "
                "VALUES (1, 'alice')")
            conn.commit()
        finally:
            conn.close()

        migrated = Database(old_path)
        with migrated._get_connection() as conn:
            cur = conn.cursor()
            cur.execute("PRAGMA table_info(groups)")
            cols = {row[1] for row in cur.fetchall()}
            assert {"avatar", "history_visible", "history_limit"} <= cols
            row = conn.execute(
                "SELECT group_name, avatar, history_visible, history_limit "
                "FROM groups WHERE id = 1").fetchone()
            assert row == ("旧群", "", 1, 50), f"迁移后旧数据保留且新列带默认值: {row}"

    def test_old_database_migrates_file_sha256_columns(self, tmp_path):
        """旧库 file_requests / group_file_requests 无 sha256 列 → 自动补建。"""
        old_path = str(tmp_path / "old_m_files.db")
        conn = sqlite3.connect(old_path)
        try:
            for table in ("file_requests", "group_file_requests"):
                conn.execute(f"""
                    CREATE TABLE {table} (
                        id INTEGER PRIMARY KEY,
                        message_id TEXT UNIQUE NOT NULL,
                        filename TEXT NOT NULL,
                        filesize INTEGER NOT NULL,
                        content BLOB NOT NULL,
                        timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                    )
                """)
            conn.commit()
        finally:
            conn.close()

        migrated = Database(old_path)
        for table in ("file_requests", "group_file_requests"):
            with migrated._get_connection() as conn:
                cur = conn.cursor()
                cur.execute(f"PRAGMA table_info({table})")
                cols = {row[1] for row in cur.fetchall()}
                assert "sha256" in cols, f"{table} 应自动补建 sha256 列"


class TestGetGroupInfo:

    def test_get_group_info_fields(self, db):
        """get_group_info 返回完整治理字段与成员数。"""
        _add_users(db, "alice", "bob")
        gid = _create_group(db, "开发组", "alice", "bob")
        info = db.get_group_info(gid)
        assert info is not None
        assert info["id"] == gid
        assert info["group_name"] == "开发组"
        assert info["created_by"] == "alice"
        assert info["avatar"] == ""
        assert info["history_visible"] == 1
        assert info["history_limit"] == 50
        assert info["member_count"] == 2

    def test_get_group_info_nonexistent(self, db):
        """群不存在 → None。"""
        assert db.get_group_info(9999) is None

    def test_get_group_info_reflects_owner_and_rename(self, db):
        """改名/转让后 get_group_info 反映最新状态（头像功能已废除）。"""
        _add_users(db, "alice", "bob")
        gid = _create_group(db, "开发组", "alice", "bob")
        db.transfer_group_owner(gid, "alice", "bob")
        db.rename_group(gid, "bob", "新开发组")
        info = db.get_group_info(gid)
        assert info["group_name"] == "新开发组"
        assert info["created_by"] == "bob"


# ============================================================
# M1 —— 群主权限：踢人 / 转让 / 改名 / 头像
# ============================================================

class TestKickGroupMember:

    def test_kick_member_success(self, db):
        """群主踢出成员 → 成员行删除，群主保留。"""
        _add_users(db, "alice", "bob", "carol")
        gid = _create_group(db, "开发组", "alice", "bob", "carol")
        assert db.kick_group_member(gid, "alice", "bob") is True
        members = db.get_group_members(gid)
        assert "bob" not in members
        assert "alice" in members and "carol" in members

    def test_kick_member_non_owner_rejected(self, db):
        """非群主踢人 → False，成员保留。"""
        _add_users(db, "alice", "bob", "carol")
        gid = _create_group(db, "开发组", "alice", "bob", "carol")
        assert db.kick_group_member(gid, "bob", "carol") is False
        assert "carol" in db.get_group_members(gid)

    def test_kick_owner_rejected(self, db):
        """不能踢群主（即使操作者是群主自己）。"""
        _add_users(db, "alice", "bob")
        gid = _create_group(db, "开发组", "alice", "bob")
        assert db.kick_group_member(gid, "alice", "alice") is False
        assert "alice" in db.get_group_members(gid)

    def test_kick_non_member_rejected(self, db):
        """目标不是成员 → False。"""
        _add_users(db, "alice", "bob")
        gid = _create_group(db, "开发组", "alice")
        assert db.kick_group_member(gid, "alice", "bob") is False

    def test_kick_nonexistent_group(self, db):
        """群不存在 → False。"""
        _add_users(db, "alice", "bob")
        assert db.kick_group_member(9999, "alice", "bob") is False

    def test_kicked_member_can_rejoin(self, db):
        """被踢后成员可再次申请/加入（行已删除，无残留）。"""
        _add_users(db, "alice", "bob")
        gid = _create_group(db, "开发组", "alice", "bob")
        assert db.kick_group_member(gid, "alice", "bob") is True
        assert db.is_group_member(gid, "bob") is False
        db.join_group(gid, "bob")
        assert db.is_group_member(gid, "bob") is True


class TestTransferGroupOwner:

    def test_transfer_owner_success(self, db):
        """群主转让 → created_by 更新为新群主。"""
        _add_users(db, "alice", "bob")
        gid = _create_group(db, "开发组", "alice", "bob")
        assert db.transfer_group_owner(gid, "alice", "bob") is True
        assert db.get_group_info(gid)["created_by"] == "bob"

    def test_transfer_owner_non_owner_rejected(self, db):
        """非群主转让 → False。"""
        _add_users(db, "alice", "bob", "carol")
        gid = _create_group(db, "开发组", "alice", "bob", "carol")
        assert db.transfer_group_owner(gid, "bob", "carol") is False
        assert db.get_group_info(gid)["created_by"] == "alice"

    def test_transfer_owner_target_not_member(self, db):
        """目标非成员 → False。"""
        _add_users(db, "alice", "bob")
        gid = _create_group(db, "开发组", "alice")
        assert db.transfer_group_owner(gid, "alice", "bob") is False

    def test_transfer_owner_to_self_rejected(self, db):
        """转让给自己 → False（无意义操作）。"""
        _add_users(db, "alice", "bob")
        gid = _create_group(db, "开发组", "alice", "bob")
        assert db.transfer_group_owner(gid, "alice", "alice") is False

    def test_transfer_owner_persists_across_reopen(self, tmp_path):
        """转让落库：重开数据库后新群主仍是 created_by。"""
        db_path = str(tmp_path / "owner.db")
        d = Database(db_path)
        _add_users(d, "alice", "bob")
        gid = _create_group(d, "开发组", "alice", "bob")
        d.transfer_group_owner(gid, "alice", "bob")
        reopened = Database(db_path)
        assert reopened.get_group_info(gid)["created_by"] == "bob"


class TestRenameGroup:

    def test_rename_group_success(self, db):
        """群主改名 → group_name 更新。"""
        _add_users(db, "alice")
        gid = db.create_group("旧名", "alice")
        assert db.rename_group(gid, "alice", "新名") is True
        assert db.get_group_info(gid)["group_name"] == "新名"

    def test_rename_group_non_owner_rejected(self, db):
        """非群主改名 → False。"""
        _add_users(db, "alice", "bob")
        gid = _create_group(db, "开发组", "alice", "bob")
        assert db.rename_group(gid, "bob", "篡改名") is False
        assert db.get_group_info(gid)["group_name"] == "开发组"

    def test_rename_group_duplicate_rejected(self, db):
        """重名（UNIQUE 冲突）→ False，原名保留。"""
        _add_users(db, "alice")
        gid1 = db.create_group("群A", "alice")
        db.create_group("群B", "alice")
        assert db.rename_group(gid1, "alice", "群B") is False
        assert db.get_group_info(gid1)["group_name"] == "群A"

    def test_rename_group_empty_rejected(self, db):
        """空名称 → False。"""
        _add_users(db, "alice")
        gid = db.create_group("群A", "alice")
        assert db.rename_group(gid, "alice", "") is False


# ============================================================
# M2 —— 入群审批：group_join_requests 表与全流程
# ============================================================

class TestGroupJoinRequestsSchema:

    def test_join_requests_table_created(self, db):
        """新库 group_join_requests 表存在，主键 (group_id, username)。"""
        with db._get_connection() as conn:
            cur = conn.cursor()
            cur.execute(
                "SELECT name FROM sqlite_master "
                "WHERE type='table' AND name='group_join_requests'")
            assert cur.fetchone() is not None, "group_join_requests 表未创建"
            cur.execute("PRAGMA table_info(group_join_requests)")
            rows = cur.fetchall()
            cols = {row[1]: row for row in rows}
            assert set(cols) >= {"group_id", "username", "status", "created_at"}
            pk_cols = [row[1] for row in rows if row[5] > 0]
            assert set(pk_cols) == {"group_id", "username"}

    def test_old_database_migrates_join_requests_table(self, tmp_path):
        """旧库初始化自动创建 group_join_requests 表。"""
        old_path = str(tmp_path / "old_m2.db")
        conn = sqlite3.connect(old_path)
        try:
            conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT)")
            conn.commit()
        finally:
            conn.close()
        migrated = Database(old_path)
        with migrated._get_connection() as conn:
            cur = conn.cursor()
            cur.execute(
                "SELECT name FROM sqlite_master "
                "WHERE type='table' AND name='group_join_requests'")
            assert cur.fetchone() is not None


class TestRequestJoinGroup:

    def test_request_join_group_success(self, db):
        """非成员申请入群 → pending 请求行插入。"""
        _add_users(db, "alice", "bob")
        gid = _create_group(db, "开发组", "alice")
        assert db.request_join_group(gid, "bob") is True
        assert db.has_pending_group_join_request(gid, "bob") is True
        assert db.get_pending_group_join_requests(gid) == ["bob"]
        assert db.is_group_member(gid, "bob") is False, "申请不直接入群"

    def test_request_join_group_already_member(self, db):
        """已是成员 → False。"""
        _add_users(db, "alice", "bob")
        gid = _create_group(db, "开发组", "alice", "bob")
        assert db.request_join_group(gid, "bob") is False

    def test_request_join_group_duplicate(self, db):
        """重复申请（已有 pending）→ False。"""
        _add_users(db, "alice", "bob")
        gid = _create_group(db, "开发组", "alice")
        assert db.request_join_group(gid, "bob") is True
        assert db.request_join_group(gid, "bob") is False

    def test_request_join_group_nonexistent_group(self, db):
        """群不存在 → False。"""
        _add_users(db, "alice", "bob")
        assert db.request_join_group(9999, "bob") is False

    def test_request_join_group_rejected_then_requeue(self, db):
        """拒绝后申请行删除 → 可再次申请。"""
        _add_users(db, "alice", "bob")
        gid = _create_group(db, "开发组", "alice")
        db.request_join_group(gid, "bob")
        db.reject_join_request(gid, "alice", "bob")
        assert db.has_pending_group_join_request(gid, "bob") is False
        assert db.request_join_group(gid, "bob") is True


class TestApproveJoinRequest:

    def test_approve_joins_and_clears_request(self, db):
        """群主批准 → 申请行删除 + 成员加入。"""
        _add_users(db, "alice", "bob")
        gid = _create_group(db, "开发组", "alice")
        db.request_join_group(gid, "bob")
        assert db.approve_join_request(gid, "alice", "bob") is True
        assert db.is_group_member(gid, "bob") is True
        assert db.has_pending_group_join_request(gid, "bob") is False

    def test_approve_requires_owner(self, db):
        """非群主批准 → False，申请保留。"""
        _add_users(db, "alice", "bob", "carol")
        gid = _create_group(db, "开发组", "alice", "carol")
        db.request_join_group(gid, "bob")
        assert db.approve_join_request(gid, "carol", "bob") is False
        assert db.has_pending_group_join_request(gid, "bob") is True
        assert db.is_group_member(gid, "bob") is False

    def test_approve_without_request(self, db):
        """无申请 → False。"""
        _add_users(db, "alice", "bob")
        gid = _create_group(db, "开发组", "alice")
        assert db.approve_join_request(gid, "alice", "bob") is False
        assert db.is_group_member(gid, "bob") is False

    def test_approve_multiple_requests(self, db):
        """多个申请各自独立，逐个批准。"""
        _add_users(db, "alice", "bob", "carol")
        gid = _create_group(db, "开发组", "alice")
        db.request_join_group(gid, "bob")
        db.request_join_group(gid, "carol")
        assert set(db.get_pending_group_join_requests(gid)) == {"bob", "carol"}
        db.approve_join_request(gid, "alice", "bob")
        assert db.is_group_member(gid, "bob") is True
        assert db.is_group_member(gid, "carol") is False
        assert db.get_pending_group_join_requests(gid) == ["carol"]


class TestRejectJoinRequest:

    def test_reject_clears_request(self, db):
        """群主拒绝 → 申请行删除，不加入。"""
        _add_users(db, "alice", "bob")
        gid = _create_group(db, "开发组", "alice")
        db.request_join_group(gid, "bob")
        assert db.reject_join_request(gid, "alice", "bob") is True
        assert db.has_pending_group_join_request(gid, "bob") is False
        assert db.is_group_member(gid, "bob") is False

    def test_reject_requires_owner(self, db):
        """非群主拒绝 → False。"""
        _add_users(db, "alice", "bob", "carol")
        gid = _create_group(db, "开发组", "alice", "carol")
        db.request_join_group(gid, "bob")
        assert db.reject_join_request(gid, "carol", "bob") is False
        assert db.has_pending_group_join_request(gid, "bob") is True

    def test_reject_without_request(self, db):
        """无申请 → False。"""
        _add_users(db, "alice", "bob")
        gid = _create_group(db, "开发组", "alice")
        assert db.reject_join_request(gid, "alice", "bob") is False


# ============================================================
# M2 —— 邀请制：group_invitations 表与全流程
# ============================================================

class TestGroupInvitationsSchema:

    def test_invitations_table_created(self, db):
        """新库 group_invitations 表存在，含 inviter 列。"""
        with db._get_connection() as conn:
            cur = conn.cursor()
            cur.execute(
                "SELECT name FROM sqlite_master "
                "WHERE type='table' AND name='group_invitations'")
            assert cur.fetchone() is not None, "group_invitations 表未创建"
            cur.execute("PRAGMA table_info(group_invitations)")
            cols = {row[1] for row in cur.fetchall()}
            assert set(cols) >= {"group_id", "username", "inviter",
                                 "status", "created_at"}


class TestInviteGroupMember:

    def test_invite_success(self, db):
        """成员邀请非成员 → 邀请行插入。"""
        _add_users(db, "alice", "bob", "carol")
        gid = _create_group(db, "开发组", "alice", "bob")
        assert db.invite_group_member(gid, "bob", "carol") is True
        pending = db.get_pending_group_invitations("carol")
        assert (gid, "开发组", "bob") in pending
        assert db.is_group_member(gid, "carol") is False, "邀请不直接入群"

    def test_invite_non_member_inviter_rejected(self, db):
        """非成员发起邀请 → False。"""
        _add_users(db, "alice", "bob", "carol")
        gid = _create_group(db, "开发组", "alice")
        assert db.invite_group_member(gid, "bob", "carol") is False

    def test_invite_already_member_rejected(self, db):
        """目标已是成员 → False。"""
        _add_users(db, "alice", "bob")
        gid = _create_group(db, "开发组", "alice", "bob")
        assert db.invite_group_member(gid, "alice", "bob") is False

    def test_invite_duplicate_rejected(self, db):
        """重复邀请（已有 pending）→ False。"""
        _add_users(db, "alice", "bob")
        gid = _create_group(db, "开发组", "alice")
        assert db.invite_group_member(gid, "alice", "bob") is True
        assert db.invite_group_member(gid, "alice", "bob") is False

    def test_invite_nonexistent_user_rejected(self, db):
        """目标用户不存在 → False。"""
        _add_users(db, "alice")
        gid = db.create_group("开发组", "alice")
        assert db.invite_group_member(gid, "alice", "ghost") is False

    def test_invite_multi_invitees(self, db):
        """可同时邀请多人，互不干扰。"""
        _add_users(db, "alice", "bob", "carol")
        gid = _create_group(db, "开发组", "alice")
        db.invite_group_member(gid, "alice", "bob")
        db.invite_group_member(gid, "alice", "carol")
        assert (gid, "开发组", "alice") in db.get_pending_group_invitations("bob")
        assert (gid, "开发组", "alice") in db.get_pending_group_invitations("carol")


class TestAcceptGroupInvite:

    def test_accept_joins_and_clears_invite(self, db):
        """接受邀请 → 邀请行删除 + 加入群组。"""
        _add_users(db, "alice", "bob")
        gid = _create_group(db, "开发组", "alice")
        db.invite_group_member(gid, "alice", "bob")
        assert db.accept_group_invite(gid, "bob") is True
        assert db.is_group_member(gid, "bob") is True
        assert db.get_pending_group_invitations("bob") == []

    def test_accept_without_invite(self, db):
        """无邀请 → False。"""
        _add_users(db, "alice", "bob")
        gid = _create_group(db, "开发组", "alice")
        assert db.accept_group_invite(gid, "bob") is False
        assert db.is_group_member(gid, "bob") is False


class TestDeclineGroupInvite:

    def test_decline_clears_invite(self, db):
        """拒绝邀请 → 邀请行删除，不加入。"""
        _add_users(db, "alice", "bob")
        gid = _create_group(db, "开发组", "alice")
        db.invite_group_member(gid, "alice", "bob")
        assert db.decline_group_invite(gid, "bob") is True
        assert db.get_pending_group_invitations("bob") == []
        assert db.is_group_member(gid, "bob") is False

    def test_decline_without_invite(self, db):
        """无邀请 → False。"""
        _add_users(db, "alice", "bob")
        gid = _create_group(db, "开发组", "alice")
        assert db.decline_group_invite(gid, "bob") is False


# ============================================================
# M3 —— 新成员历史可见性（群主可关）
# ============================================================

class TestHistoryVisibility:

    def test_set_visibility_success(self, db):
        """群主设置可见性 → 落库。"""
        _add_users(db, "alice", "bob")
        gid = _create_group(db, "开发组", "alice")
        assert db.set_group_history_visibility(gid, "alice", 0, 20) is True
        info = db.get_group_info(gid)
        assert info["history_visible"] == 0
        assert info["history_limit"] == 20

    def test_set_visibility_back_on(self, db):
        """关闭后再开启 → 恢复 1。"""
        _add_users(db, "alice")
        gid = db.create_group("开发组", "alice")
        db.set_group_history_visibility(gid, "alice", 0, 10)
        db.set_group_history_visibility(gid, "alice", 1, 50)
        info = db.get_group_info(gid)
        assert info["history_visible"] == 1
        assert info["history_limit"] == 50

    def test_set_visibility_non_owner_rejected(self, db):
        """非群主设置 → False，原值保留。"""
        _add_users(db, "alice", "bob")
        gid = _create_group(db, "开发组", "alice", "bob")
        assert db.set_group_history_visibility(gid, "bob", 0, 5) is False
        info = db.get_group_info(gid)
        assert info["history_visible"] == 1
        assert info["history_limit"] == 50

    def test_visibility_persists_across_reopen(self, tmp_path):
        """设置落库：重开数据库后策略保留。"""
        db_path = str(tmp_path / "vis.db")
        d = Database(db_path)
        _add_users(d, "alice")
        gid = d.create_group("开发组", "alice")
        d.set_group_history_visibility(gid, "alice", 0, 5)
        reopened = Database(db_path)
        info = reopened.get_group_info(gid)
        assert info["history_visible"] == 0
        assert info["history_limit"] == 5


# ============================================================
# M6 —— 存储治理：过期 delivered 清理 + 占用统计
# ============================================================

class TestCleanupExpiredDeliveredMessages:

    def _save_offline(self, db, message_id, status, days_ago):
        with db._get_connection() as conn:
            conn.execute(
                "INSERT INTO offline_messages "
                "(message_id, sender, receiver, message_type, content, status, timestamp) "
                "VALUES (?, 'alice', 'bob', 'chat', ?, ?, "
                "datetime('now', ?))",
                (message_id, b"x", status, f"-{days_ago} days"))
            conn.commit()

    def test_cleanup_removes_old_delivered_only(self, db):
        """只删超过 N 天的 delivered；sent 与近期的 delivered 保留。"""
        _add_users(db, "alice", "bob")
        self._save_offline(db, "old-delivered", "delivered", 40)
        self._save_offline(db, "old-sent", "sent", 40)
        self._save_offline(db, "recent-delivered", "delivered", 1)
        deleted = db.cleanup_expired_delivered_messages(days=30)
        assert deleted == 1
        with db._get_connection() as conn:
            ids = {r[0] for r in conn.execute(
                "SELECT message_id FROM offline_messages").fetchall()}
        assert ids == {"old-sent", "recent-delivered"}

    def test_cleanup_keeps_message_history(self, db):
        """message_history 永久保留，不参与清理（9.3 契约）。"""
        _add_users(db, "alice", "bob")
        self._save_offline(db, "old-delivered", "delivered", 40)
        db.save_message_history(
            "alice", "bob", "chat", b"old", message_id="hist-old")
        deleted = db.cleanup_expired_delivered_messages(days=30)
        assert deleted == 1
        assert db.get_history_message("hist-old") is not None, \
            "message_history 不应被清理"

    def test_cleanup_with_custom_days(self, db):
        """days 参数可调：7 天前的 delivered 被删。"""
        _add_users(db, "alice", "bob")
        self._save_offline(db, "d7", "delivered", 7)
        self._save_offline(db, "d3", "delivered", 3)
        assert db.cleanup_expired_delivered_messages(days=5) == 1
        with db._get_connection() as conn:
            ids = {r[0] for r in conn.execute(
                "SELECT message_id FROM offline_messages").fetchall()}
        assert ids == {"d3"}

    def test_cleanup_empty_db(self, db):
        """空库清理 → 0，不抛错。"""
        _add_users(db, "alice")
        assert db.cleanup_expired_delivered_messages() == 0


class TestStorageStats:

    def _write_file(self, db, message_id, content=b"hello"):
        """向 pending 目录写一个文件请求，返回 file_path。"""
        file_path = os.path.join(db._pending_dir(), message_id)
        with open(file_path, "wb") as f:
            f.write(content)
        db.save_file_request(
            "alice", "bob", "f.txt", len(content), b"", message_id=message_id,
            file_path=file_path)
        return file_path

    def test_storage_stats_counts(self, db):
        """统计包含 文件字节数/文件数/库大小/消息数/待处理文件请求数。"""
        _add_users(db, "alice", "bob")
        self._write_file(db, "f1", b"hello")
        self._write_file(db, "f2", b"world!")
        db.save_message_history("alice", "bob", "chat", b"hi", message_id="m1")
        stats = db.get_storage_stats()
        assert stats["file_count"] == 2
        assert stats["file_store_bytes"] == 11
        assert stats["db_bytes"] > 0
        assert stats["message_count"] == 1
        assert stats["pending_file_requests"] == 2

    def test_storage_stats_empty_db(self, db):
        """空库统计 → 全 0（不抛错）。"""
        _add_users(db, "alice")
        stats = db.get_storage_stats()
        assert stats["file_count"] == 0
        assert stats["file_store_bytes"] == 0
        assert stats["message_count"] == 0
        assert stats["pending_file_requests"] == 0

    def test_get_message_count(self, db):
        """get_message_count = message_history 总行数。"""
        _add_users(db, "alice", "bob")
        db.save_message_history("alice", "bob", "chat", b"1", message_id="m1")
        db.save_message_history("alice", "bob", "chat", b"2", message_id="m2")
        assert db.get_message_count() == 2

    def test_get_pending_file_request_count_excludes_recalled(self, db):
        """待处理文件请求数排除 recalled（已撤回）。"""
        _add_users(db, "alice", "bob")
        self._write_file(db, "f1")
        self._write_file(db, "f2")
        db.mark_file_request_recalled("f1")
        assert db.get_pending_file_request_count() == 1

    def test_get_file_stats_matches_storage_stats(self, db):
        """get_file_stats 与 get_storage_stats 的文件口径一致。"""
        _add_users(db, "alice", "bob")
        self._write_file(db, "f1", b"12345")
        fs = db.get_file_stats()
        assert fs["file_count"] == 1
        assert fs["file_store_bytes"] == 5


# ============================================================
# M8 —— 文件增强：sha256 列与文件收发历史
# ============================================================

class TestFileSha256:

    def test_save_file_request_with_sha256(self, db):
        """save_file_request 扩展参数 sha256 落库。"""
        _add_users(db, "alice", "bob")
        db.save_file_request("alice", "bob", "f.txt", 5, b"hello",
                             message_id="sha-1", sha256="abc123")
        extras = db.get_file_request_extras("sha-1")
        assert extras is not None and extras["sha256"] == "abc123"
        # 既有 7 元组访问器形态不变
        row = db.get_file_request("sha-1")
        assert row is not None and row[0] == "alice"

    def test_save_file_request_without_sha256(self, db):
        """不带 sha256 → 落库为空串（向后兼容）。"""
        _add_users(db, "alice", "bob")
        db.save_file_request("alice", "bob", "f.txt", 5, b"hello",
                             message_id="sha-2")
        extras = db.get_file_request_extras("sha-2")
        assert extras is not None and not extras["sha256"]

    def test_save_group_file_request_with_sha256(self, db):
        """群组文件请求同样落库 sha256。"""
        _add_users(db, "alice", "bob")
        gid = _create_group(db, "开发组", "alice", "bob")
        db.save_group_file_request(gid, "alice", "f.txt", 5, b"hello",
                                   message_id="gsha-1", sha256="def456")
        extras = db.get_group_file_request_extras("gsha-1")
        assert extras is not None and extras["sha256"] == "def456"

    def test_file_request_extras_nonexistent(self, db):
        """查询不存在的消息 → None。"""
        _add_users(db, "alice")
        assert db.get_file_request_extras("nope") is None
        assert db.get_group_file_request_extras("nope") is None


class TestUserFileMessages:

    def _save_file_history(self, db, sender, receiver, filename, content,
                           message_id, group_id=None, file_path=None):
        db.save_message_history(
            sender, receiver, "file", content, filename=filename,
            message_id=message_id, group_id=group_id, file_path=file_path)

    def test_private_files_both_directions(self, db, tmp_path):
        """私聊文件历史：双向收发均可见，filesize 取磁盘实际大小。"""
        _add_users(db, "alice", "bob")
        p1 = str(tmp_path / "a.txt")
        with open(p1, "wb") as f:
            f.write(b"hello")
        p2 = str(tmp_path / "b.txt")
        with open(p2, "wb") as f:
            f.write(b"world!!")
        self._save_file_history(db, "alice", "bob", "a.txt", b"",
                                "fh-1", file_path=p1)
        self._save_file_history(db, "bob", "alice", "b.txt", b"",
                                "fh-2", file_path=p2)

        alice_files = db.get_user_file_messages("alice")
        assert {f["message_id"] for f in alice_files} == {"fh-1", "fh-2"}
        by_id = {f["message_id"]: f for f in alice_files}
        assert by_id["fh-1"]["filesize"] == 5
        assert by_id["fh-2"]["filesize"] == 7
        assert by_id["fh-1"]["filename"] == "a.txt"

    def test_private_scope_with_user(self, db, tmp_path):
        """with_user 限定会话：仅该会话的文件。"""
        _add_users(db, "alice", "bob", "carol")
        p = str(tmp_path / "f.txt")
        with open(p, "wb") as f:
            f.write(b"x")
        self._save_file_history(db, "alice", "bob", "f.txt", b"",
                                "fh-3", file_path=p)
        self._save_file_history(db, "alice", "carol", "f.txt", b"",
                                "fh-4", file_path=p)
        files = db.get_user_file_messages("alice", with_user="bob")
        assert [f["message_id"] for f in files] == ["fh-3"]

    def test_group_files_visible_to_members(self, db, tmp_path):
        """群文件历史：群内全部 file 消息可见（含他人发送）。"""
        _add_users(db, "alice", "bob", "carol")
        gid = _create_group(db, "开发组", "alice", "bob", "carol")
        p = str(tmp_path / "g.txt")
        with open(p, "wb") as f:
            f.write(b"groupfile")
        self._save_file_history(db, "alice", "", "g.txt", b"", "gfh-1",
                                group_id=gid, file_path=p)
        self._save_file_history(db, "bob", "", "g2.txt", b"", "gfh-2",
                                group_id=gid, file_path=p)
        files = db.get_user_file_messages("carol", group_id=gid)
        assert {f["message_id"] for f in files} == {"gfh-1", "gfh-2"}
        assert files[0]["group_id"] == gid

    def test_missing_file_path_filesize_zero(self, db):
        """文件不存在（file_path 缺失/已删）→ filesize 0，不抛错。"""
        _add_users(db, "alice", "bob")
        self._save_file_history(db, "alice", "bob", "gone.txt", b"", "fh-5")
        files = db.get_user_file_messages("alice")
        assert files[0]["filesize"] == 0

    def test_only_file_messages_returned(self, db, tmp_path):
        """仅返回 file 类型消息（chat 不混入）。"""
        _add_users(db, "alice", "bob")
        db.save_message_history("alice", "bob", "chat", b"hi", message_id="m1")
        p = str(tmp_path / "f.txt")
        with open(p, "wb") as f:
            f.write(b"x")
        self._save_file_history(db, "alice", "bob", "f.txt", b"", "fh-6",
                                file_path=p)
        files = db.get_user_file_messages("alice")
        assert [f["message_id"] for f in files] == ["fh-6"]

    def test_no_files_empty(self, db):
        """无文件历史 → 空列表。"""
        _add_users(db, "alice", "bob")
        assert db.get_user_file_messages("alice") == []


class TestSearchGroups:
    """群组搜索（2026-08-25 用户反馈：群组搜索入口）。"""

    def test_search_by_keyword(self, db):
        """按群名模糊搜索返回治理信息。"""
        _add_users(db, "alice", "bob", "carol")
        _create_group(db, "开发组", "alice", "bob")
        _create_group(db, "项目组", "alice")
        results = db.search_groups("开发", username="carol")
        assert [r["group_name"] for r in results] == ["开发组"]
        target = results[0]
        assert target["created_by"] == "alice"
        assert target["member_count"] == 2

    def test_excludes_joined_groups(self, db):
        """排除自己已加入的群（搜索目的是申请加入）。"""
        _add_users(db, "alice", "bob")
        _create_group(db, "开发组", "alice", "bob")
        _create_group(db, "项目组", "alice")
        results = db.search_groups("组", username="bob")
        assert [r["group_name"] for r in results] == ["项目组"]

    def test_no_keyword_returns_empty(self, db):
        """空关键字 → 空列表。"""
        _add_users(db, "alice")
        _create_group(db, "开发组", "alice")
        assert db.search_groups("") == []

    def test_no_match_returns_empty(self, db):
        """无匹配 → 空列表。"""
        _add_users(db, "alice")
        _create_group(db, "开发组", "alice")
        assert db.search_groups("不存在的群") == []

    def test_without_username_includes_all(self, db):
        """不传 username → 全部匹配群（含已加入）。"""
        _add_users(db, "alice", "bob")
        _create_group(db, "开发组", "alice", "bob")
        results = db.search_groups("开发")
        assert [r["group_name"] for r in results] == ["开发组"]


class TestJoinRequestMessage:
    """入群申请验证消息（2026-08-25 用户反馈）。"""

    def test_join_requests_table_has_message_column(self, db):
        """group_join_requests 表含 request_message 列。"""
        with db._get_connection() as conn:
            cur = conn.cursor()
            cur.execute("PRAGMA table_info(group_join_requests)")
            cols = {row[1] for row in cur.fetchall()}
            assert "request_message" in cols

    def test_old_database_migrates_message_column(self, tmp_path):
        """旧库（无 request_message 列）自动迁移。"""
        old_path = str(tmp_path / "old_msg.db")
        conn = sqlite3.connect(old_path)
        try:
            conn.execute("""
                CREATE TABLE group_join_requests (
                    group_id INTEGER NOT NULL,
                    username TEXT NOT NULL,
                    status TEXT DEFAULT 'pending',
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (group_id, username)
                )
            """)
            conn.commit()
        finally:
            conn.close()
        migrated = Database(old_path)
        with migrated._get_connection() as conn:
            cur = conn.cursor()
            cur.execute("PRAGMA table_info(group_join_requests)")
            cols = {row[1] for row in cur.fetchall()}
            assert "request_message" in cols

    def test_request_with_message_stored(self, db):
        """带验证消息的申请落库。"""
        _add_users(db, "alice", "bob")
        gid = _create_group(db, "开发组", "alice")
        assert db.request_join_group(gid, "bob", "我是 bob") is True
        detail = db.get_pending_group_join_requests_detail(gid)
        assert detail == [("bob", "我是 bob")]

    def test_request_without_message_empty(self, db):
        """不带消息 → 空串。"""
        _add_users(db, "alice", "bob")
        gid = _create_group(db, "开发组", "alice")
        db.request_join_group(gid, "bob")
        detail = db.get_pending_group_join_requests_detail(gid)
        assert detail == [("bob", "")]

    def test_detail_multiple_requests(self, db):
        """多条申请各自携带消息。"""
        _add_users(db, "alice", "bob", "carol")
        gid = _create_group(db, "开发组", "alice")
        db.request_join_group(gid, "bob", "消息一")
        db.request_join_group(gid, "carol", "消息二")
        detail = db.get_pending_group_join_requests_detail(gid)
        assert set(detail) == {("bob", "消息一"), ("carol", "消息二")}

    def test_detail_after_approve_cleared(self, db):
        """批准后申请行删除，detail 不再返回。"""
        _add_users(db, "alice", "bob")
        gid = _create_group(db, "开发组", "alice")
        db.request_join_group(gid, "bob", "x")
        db.approve_join_request(gid, "alice", "bob")
        assert db.get_pending_group_join_requests_detail(gid) == []
