"""
============================================================
database.py 的单元测试
============================================================

【测试目标】
  database.py 封装了所有 SQLite 数据库操作。
  包含 8 张表：users, offline_messages, friends, file_requests,
              groups, group_members, group_file_requests, group_file_responses

【测试策略】
  - 每个测试使用独立的临时数据库文件（避免测试间相互污染）
  - 使用 pytest 的 tmp_path 夹具自动创建临时目录
  - 按照数据库操作类型分组：
    1. 用户管理（增删查）
    2. 离线消息（存/取/清理/状态更新）
    3. 好友系统（请求/接受/拒绝/列表）
    4. 群组系统（创建/加入/成员列表）
    5. 文件请求（私聊文件和群组文件）
    6. 完整性/边界测试

【关键原则】
  - 每个测试方法只测一件事
  - 测试命名：test_<操作>_<场景>
  - 使用 assert 验证结果
"""

import sys
import os
import pytest
import tempfile
import bcrypt

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from database import Database


# ============================================================
# 辅助夹具（Fixture）
# ============================================================

@pytest.fixture
def db(tmp_path):
    """
    【测试夹具】为每个测试提供一个全新的、独立的数据库实例。
    
    解释：
      - tmp_path 是 pytest 内置夹具，提供唯一的临时目录
      - 每个测试函数执行时，pytest 创建一个新的 tmp_path
      - 测试结束后，临时目录自动删除
      - 这样每个测试都有干净独立的数据库，互不影响
    
    用法：
      测试函数参数中写 'db'，pytest 会自动调用这个夹具。
    """
    db_path = str(tmp_path / "test.db")
    database = Database(db_path)
    return database


# ============================================================
# 第 1 组：数据库初始化
# ============================================================

class TestDatabaseInit:
    """
    【测试数据库初始化】
    
    验证 Database() 构造时正确创建了所有表。
    """

    def test_tables_created(self, db):
        """
        【测试16】数据库创建时，8 张表都已正确建立
        
        怎么做：查询 SQLite 的 sqlite_master 系统表
        验证点：所有预期的表都存在
        """
        with db._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
            tables = {row[0] for row in cursor.fetchall()}

        expected = {
            "users", "offline_messages", "friends", "file_requests",
            "groups", "group_members", "group_file_requests", "group_file_responses",
            "message_history"
        }
        assert tables == expected, f"缺少表: {expected - tables}"


# ============================================================
# 第 2 组：用户管理测试
# ============================================================

class TestUserManagement:
    """
    【用户管理测试】
    
    覆盖：添加用户、查询用户、检查存在、删除用户。
    密码使用 bcrypt 哈希存储。
    """

    def test_add_user_success(self, db):
        """
        【测试17】添加一个新用户，应返回 True
        """
        password_hash = bcrypt.hashpw("password123".encode(), bcrypt.gensalt())
        result = db.add_user("alice", password_hash)
        assert result is True

    def test_add_duplicate_user_fails(self, db):
        """
        【测试18】重复添加同名的用户，应返回 False
        
        原因：users 表的 username 列有 UNIQUE 约束，
        add_user() 捕获 IntegrityError 并返回 False。
        """
        pw = bcrypt.hashpw("pass1".encode(), bcrypt.gensalt())
        db.add_user("alice", pw)

        pw2 = bcrypt.hashpw("pass2".encode(), bcrypt.gensalt())
        result = db.add_user("alice", pw2)
        assert result is False

    def test_get_user_returns_correct_data(self, db):
        """
        【测试19】get_user 返回正确的密码哈希和管理员状态
        """
        password = "secret123"
        pw_hash = bcrypt.hashpw(password.encode(), bcrypt.gensalt())
        db.add_user("bob", pw_hash)

        stored_hash, is_admin = db.get_user("bob")
        # 验证 bcrypt 哈希能匹配原密码
        assert bcrypt.checkpw(password.encode(), stored_hash) is True
        # 普通用户 is_admin 应为 False（数据库中默认 FALSE）
        assert is_admin == 0 or is_admin == False

    def test_get_nonexistent_user(self, db):
        """
        【测试20】查询不存在的用户，返回 None
        """
        result = db.get_user("ghost")
        assert result is None

    def test_user_exists(self, db):
        """
        【测试21】user_exists 正确判断用户存在与否
        """
        assert db.user_exists("alice") is False

        pw = bcrypt.hashpw("pwd".encode(), bcrypt.gensalt())
        db.add_user("alice", pw)

        assert db.user_exists("alice") is True

    def test_delete_user_success(self, db):
        """
        【测试22】删除已存在的用户，返回 True
        """
        pw = bcrypt.hashpw("pwd".encode(), bcrypt.gensalt())
        db.add_user("charlie", pw)

        result = db.delete_user("charlie")
        assert result is True
        assert db.user_exists("charlie") is False

    def test_delete_nonexistent_user(self, db):
        """
        【测试23】删除不存在的用户，返回 False
        """
        result = db.delete_user("nobody")
        assert result is False

    def test_get_all_users(self, db):
        """
        【测试24】get_all_users 返回所有已注册用户
        """
        pw = bcrypt.hashpw("pw".encode(), bcrypt.gensalt())
        db.add_user("alice", pw)
        db.add_user("bob", pw)
        db.add_user("charlie", pw)

        users = db.get_all_users()
        usernames = {u[0] for u in users}
        assert usernames == {"alice", "bob", "charlie"}
        # 验证返回格式：(username, is_admin)
        assert len(users[0]) == 2


# ============================================================
# 第 3 组：离线消息测试
# ============================================================

class TestOfflineMessages:
    """
    【离线消息测试】
    
    离线消息的生命周期：
      1. save_offline_message() —— 存入，状态 'sent'
      2. get_offline_messages() —— 取出，状态变为 'delivered'
      3. cleanup_delivered_messages() —— 清理已送达的消息
      4. update_message_status() —— 手动更新消息状态
    """

    def test_save_and_get_offline_message(self, db):
        """
        【测试25】保存一条离线消息，然后用 get_offline_messages 取出
        
        验证点：
        - 消息内容、发送者、类型正确
        - 取出后状态变为 'delivered'
        """
        db.save_offline_message("alice", "bob", "chat", b"Hello Bob!",
                                message_id="msg-001")

        messages = db.get_offline_messages("bob")
        assert len(messages) == 1

        sender, msg_type, content, filename, msg_id, status = messages[0]
        assert sender == "alice"
        assert msg_type == "chat"
        assert content == b"Hello Bob!"
        assert msg_id == "msg-001"
        assert status == "sent"  # 取出时返回的状态还是 'sent'

        # 再次查询，应该没有 'sent' 状态的消息了（已被标记为 'delivered'）
        messages2 = db.get_offline_messages("bob")
        assert len(messages2) == 0

    def test_save_offline_message_with_file(self, db):
        """
        【测试26】保存带文件名的离线消息
        
        验证点：filename 参数被正确存储
        """
        db.save_offline_message("alice", "bob", "file", b"file content",
                                filename="report.pdf", message_id="msg-002")

        messages = db.get_offline_messages("bob")
        assert len(messages) == 1
        _, msg_type, content, filename, _, _ = messages[0]
        assert msg_type == "file"
        assert filename == "report.pdf"

    def test_get_offline_messages_only_returns_sent(self, db):
        """
        【测试27】get_offline_messages 只返回 status='sent' 的消息
        
        逻辑：已经 'delivered' 或 'recalled' 的消息不会再返回。
        """
        db.save_offline_message("alice", "bob", "chat", b"msg1", message_id="m1")
        db.save_offline_message("alice", "bob", "chat", b"msg2", message_id="m2")

        # 手动把 m2 标记为 'recalled'
        db.update_message_status("m2", "recalled")

        # 只收到 m1
        messages = db.get_offline_messages("bob")
        assert len(messages) == 1
        assert messages[0][4] == "m1"

    def test_cleanup_delivered_messages(self, db):
        """
        【测试28】清理已送达（delivered）的消息
        
        场景：消息已经被取出（status='delivered'），
              调用 cleanup 后应从数据库中删除。
        """
        db.save_offline_message("alice", "bob", "chat", b"cleanup test",
                                message_id="m-clean")

        # 取出消息（状态变为 delivered）
        db.get_offline_messages("bob")

        # 清理
        deleted = db.cleanup_delivered_messages("bob")
        assert deleted == 1

        # 确认数据库中已不存在
        info = db.get_message_info("m-clean")
        assert info is None

    def test_update_message_status(self, db):
        """
        【测试29】更新消息状态
        
        常见状态流转：sent → delivered（自动）或 sent → recalled（手动）
        """
        db.save_offline_message("alice", "bob", "chat", b"test", message_id="m1")
        result = db.update_message_status("m1", "recalled")
        assert result is True

        info = db.get_message_info("m1")
        assert info[5] == "recalled"  # status 字段

    def test_update_nonexistent_message(self, db):
        """
        【测试30】更新不存在的消息状态，返回 False
        """
        result = db.update_message_status("does-not-exist", "recalled")
        assert result is False

    def test_get_message_info(self, db):
        """
        【测试31】get_message_info 返回消息的完整信息
        """
        db.save_offline_message("sender", "receiver", "chat", b"content",
                                filename="test.txt", message_id="info-test")

        info = db.get_message_info("info-test")
        assert info is not None
        sender, receiver, msg_type, content, filename, status, timestamp = info
        assert sender == "sender"
        assert receiver == "receiver"
        assert msg_type == "chat"
        assert content == b"content"
        assert filename == "test.txt"
        assert status == "sent"
        assert timestamp is not None  # 自动生成的时间戳


# ============================================================
# 第 4 组：好友系统测试
# ============================================================

class TestFriendSystem:
    """
    【好友系统测试】
    
    好友关系设计的要点：
    - 好友关系在 friends 表中存储为两条记录（双向）
    - 状态流转：pending → accepted（接受）/ 删除（拒绝）
    - 查询时使用 UNION 来获取双向好友
    """

    def _setup_user(self, db, username):
        """辅助方法：创建单个测试用户"""
        pw = bcrypt.hashpw("pw".encode(), bcrypt.gensalt())
        db.add_user(username, pw)

    def _setup_users(self, db, *extra_users):
        """辅助方法：创建 alice, bob 以及可选的更多用户"""
        self._setup_user(db, "alice")
        self._setup_user(db, "bob")
        for user in extra_users:
            self._setup_user(db, user)

    def test_add_friend_request(self, db):
        """
        【测试32】发送好友请求
        
        验证：
        - 请求成功返回 True
        - 请求方可以看到 'pending' 状态
        - 目标方在 get_pending_friend_requests 中能看到
        """
        self._setup_users(db)
        result = db.add_friend_request("alice", "bob")
        assert result is True
        assert db.has_pending_request("alice", "bob") is True

        # bob 收到待处理请求
        pending = db.get_pending_friend_requests("bob")
        assert "alice" in pending

    def test_add_duplicate_friend_request(self, db):
        """
        【测试33】重复发送好友请求，返回 False
        
        代码中会检查双向关系是否已存在
        """
        self._setup_users(db)
        db.add_friend_request("alice", "bob")
        result = db.add_friend_request("alice", "bob")
        assert result is False

    def test_add_friend_request_self(self, db):
        """
        【测试34】给自己发好友请求应被拒绝
        
        修复 BUG-02：现在 add_friend_request 会检查 requester == target，
        如果相同则返回 False。
        """
        pw = bcrypt.hashpw("pw".encode(), bcrypt.gensalt())
        db.add_user("alice", pw)
        result = db.add_friend_request("alice", "alice")
        assert result is False

    def test_accept_friend_request(self, db):
        """
        【测试35】接受好友请求
        
        验证完整流程：
        1. alice 向 bob 发请求
        2. bob 接受
        3. 两人互相出现在对方的好友列表中
        4. is_friend 返回 True
        5. 待处理请求列表清空
        """
        self._setup_users(db)
        db.add_friend_request("alice", "bob")
        result = db.accept_friend_request("alice", "bob")
        assert result is True

        # 双向都是好友
        assert db.is_friend("alice", "bob") is True
        assert db.is_friend("bob", "alice") is True

        # alice 的好友列表中有 bob
        assert "bob" in db.get_friends("alice")
        assert "alice" in db.get_friends("bob")

        # bob 不再有待处理的请求
        assert db.get_pending_friend_requests("bob") == []

    def test_reject_friend_request(self, db):
        """
        【测试36】拒绝好友请求
        
        验证：拒绝后请求被删除，双方不是好友
        """
        self._setup_users(db)
        db.add_friend_request("alice", "bob")
        result = db.reject_friend_request("alice", "bob")
        assert result is True

        # 请求已删除
        assert db.has_pending_request("alice", "bob") is False
        # 不是好友
        assert db.is_friend("alice", "bob") is False

    def test_get_friends_empty(self, db):
        """
        【测试37】新用户的好友列表为空
        """
        pw = bcrypt.hashpw("pw".encode(), bcrypt.gensalt())
        db.add_user("newuser", pw)
        assert db.get_friends("newuser") == []

    def test_is_friend_different_scenarios(self, db):
        """
        【测试38】is_friend 在不同场景下的正确性
        
        覆盖：
        - 两个陌生人
        - 只有 pending 请求
        - 已接受的好友
        """
        self._setup_users(db)
        # 陌生人
        assert db.is_friend("alice", "bob") is False

        # 有 pending 请求但未接受（不算好友）
        db.add_friend_request("alice", "bob")
        assert db.is_friend("alice", "bob") is False

        # 接受后才是好友
        db.accept_friend_request("alice", "bob")
        assert db.is_friend("alice", "bob") is True

    def test_add_friend_request_self_blocked(self, db):
        """
        【BUG-02 验证】自己不能添加自己为好友
        
        验证 add_friend_request("alice", "alice") 返回 False。
        """
        pw = bcrypt.hashpw("pw".encode(), bcrypt.gensalt())
        db.add_user("alice", pw)
        result = db.add_friend_request("alice", "alice")
        assert result is False
        # 也没有待处理请求
        assert db.get_pending_friend_requests("alice") == []


# ============================================================
# 第 5 组：群组系统测试
# ============================================================

class TestGroupSystem:
    """
    【群组系统测试】
    
    群组操作：create_group → join_group → get_user_groups → get_group_members
    """

    def _setup_user(self, db, username):
        pw = bcrypt.hashpw("pw".encode(), bcrypt.gensalt())
        db.add_user(username, pw)

    def test_create_group(self, db):
        """
        【测试39】创建群组
        
        验证：
        - 返回有效的 group_id（整数 > 0）
        - 创建者自动成为群成员
        """
        self._setup_user(db, "alice")
        group_id = db.create_group("测试群", "alice")
        assert group_id > 0
        assert db.is_group_member(group_id, "alice") is True

    def test_join_group(self, db):
        """
        【测试40】加入群组
        
        验证：
        - 加入后 is_group_member 返回 True
        - 重复加入（INSERT OR IGNORE）不会报错
        """
        self._setup_user(db, "alice")
        self._setup_user(db, "bob")
        group_id = db.create_group("开发群", "alice")

        db.join_group(group_id, "bob")
        assert db.is_group_member(group_id, "bob") is True

        # 重复加入不应出错
        db.join_group(group_id, "bob")
        assert db.is_group_member(group_id, "bob") is True

    def test_get_user_groups(self, db):
        """
        【测试41】获取用户所属的所有群组
        """
        self._setup_user(db, "alice")
        g1 = db.create_group("群A", "alice")
        g2 = db.create_group("群B", "alice")

        groups = db.get_user_groups("alice")
        group_ids = {g[0] for g in groups}
        group_names = {g[1] for g in groups}
        assert group_ids == {g1, g2}
        assert group_names == {"群A", "群B"}

    def test_get_group_members(self, db):
        """
        【测试42】获取群组成员列表
        
        验证：创建者 + 后加入的成员都在列表中
        """
        self._setup_user(db, "alice")
        self._setup_user(db, "bob")
        self._setup_user(db, "charlie")

        gid = db.create_group("三国群", "alice")
        db.join_group(gid, "bob")
        db.join_group(gid, "charlie")

        members = db.get_group_members(gid)
        assert set(members) == {"alice", "bob", "charlie"}

    def test_is_group_member_false(self, db):
        """
        【测试43】未加入群组的用户 is_group_member 返回 False
        """
        self._setup_user(db, "alice")
        gid = db.create_group("私密群", "alice")

        self._setup_user(db, "intruder")
        assert db.is_group_member(gid, "intruder") is False


# ============================================================
# 第 6 组：文件请求测试
# ============================================================

class TestFileRequests:
    """
    【文件请求测试】
    
    文件传输采用 '请求-响应' 模式：
      私聊文件：Sender → save_file_request → Receiver get_file_request → accept/reject
      群组文件：Sender → save_group_file_request → Members get_pending_group_file_requests → respond
    """

    def _setup_users(self, db, *extra_users):
        """辅助方法：创建 alice, bob 以及可选的更多用户"""
        pw = bcrypt.hashpw("pw".encode(), bcrypt.gensalt())
        db.add_user("alice", pw)
        db.add_user("bob", pw)
        for user in extra_users:
            db.add_user(user, pw)

    def test_save_and_get_file_request(self, db):
        """
        【测试44】保存私聊文件请求并取出
        
        验证：保存后能完整取出所有字段
        """
        self._setup_users(db)
        file_content = b"This is the file content"
        db.save_file_request("alice", "bob", "doc.txt", len(file_content),
                             file_content, message_id="file-req-1")

        info = db.get_file_request("file-req-1")
        assert info is not None
        sender, receiver, filename, filesize, content = info
        assert sender == "alice"
        assert receiver == "bob"
        assert filename == "doc.txt"
        assert content == file_content

    def test_get_pending_file_requests(self, db):
        """
        【测试45】列出待处理的私聊文件请求
        
        验证：receiver 能查到发给自己的所有文件请求
        """
        self._setup_users(db)

        db.save_file_request("alice", "bob", "a.txt", 100, b"aa", "r1")
        db.save_file_request("alice", "bob", "b.txt", 200, b"bb", "r2")

        pending = db.get_pending_file_requests("bob")
        assert len(pending) == 2
        filenames = {r[1] for r in pending}
        assert filenames == {"a.txt", "b.txt"}

    def test_delete_file_request(self, db):
        """
        【测试46】删除文件请求
        
        场景：接受或拒绝后删除
        """
        self._setup_users(db)
        db.save_file_request("alice", "bob", "f.txt", 50, b"data", "r-del")
        assert db.delete_file_request("r-del") is True
        assert db.get_file_request("r-del") is None

    def test_group_file_request_and_response(self, db):
        """
        【测试47】群组文件请求的完整流程：
        保存 → 获取待处理 → 响应 → 检查所有成员是否已响应
        
        这是群文件功能的核心流程。
        """
        self._setup_users(db)
        self._setup_users(db, "charlie")

        gid = db.create_group("文件群", "alice")
        db.join_group(gid, "bob")
        db.join_group(gid, "charlie")

        # alice 发群文件
        db.save_group_file_request(gid, "alice", "group_doc.pdf", 500,
                                   b"PDF content", "grp-file-1")

        # bob 和 charlie 都能看到待处理的群文件请求
        bob_pending = db.get_pending_group_file_requests(gid, "bob")
        charlie_pending = db.get_pending_group_file_requests(gid, "charlie")
        assert len(bob_pending) == 1
        assert len(charlie_pending) == 1

        # bob 接受，charlie 拒绝
        db.save_group_file_response("grp-file-1", gid, "bob", "accept")
        db.save_group_file_response("grp-file-1", gid, "charlie", "reject")

        # all_members_responded 应排除发送者 alice，因此 bob+charlie 都响应后返回 True
        assert db.all_members_responded("grp-file-1", gid) is True

    def test_all_members_responded_false(self, db):
        """
        【测试48】部分成员响应时，all_members_responded 返回 False
        """
        self._setup_users(db)
        self._setup_users(db, "charlie")

        gid = db.create_group("测试群", "alice")
        db.join_group(gid, "bob")
        db.join_group(gid, "charlie")

        db.save_group_file_request(gid, "alice", "test.pdf", 100, b"x", "gfr-1")

        # 只有 bob 响应
        db.save_group_file_response("gfr-1", gid, "bob", "accept")

        # charlie 还没响应，所以不是全部
        assert db.all_members_responded("gfr-1", gid) is False

    def test_all_members_responded_excludes_sender(self, db):
        """
        【BUG-01 验证】发送者不需要响应自己的群文件请求
        
        场景：群组有 alice(发送者), bob, charlie
        bob 和 charlie 都响应后 → all_members_responded 应返回 True
        （alice 作为发送者被排除）
        """
        self._setup_users(db, "charlie")

        gid = db.create_group("BUG01测试群", "alice")
        db.join_group(gid, "bob")
        db.join_group(gid, "charlie")

        db.save_group_file_request(gid, "alice", "bug01.pdf", 100, b"test", "bug01-1")

        # bob 和 charlie 都响应
        db.save_group_file_response("bug01-1", gid, "bob", "accept")
        db.save_group_file_response("bug01-1", gid, "charlie", "reject")

        # 发送者 alice 被排除，全部非发送者成员已响应 → True
        assert db.all_members_responded("bug01-1", gid) is True

        # 对比：如果 bob 还没响应，应返回 False
        db2 = self._fresh_db()
        self._setup_users(db2, "charlie")
        gid2 = db2.create_group("BUG01b", "alice")
        db2.join_group(gid2, "bob")
        db2.join_group(gid2, "charlie")
        db2.save_group_file_request(gid2, "alice", "b.pdf", 100, b"x", "bug01-2")
        db2.save_group_file_response("bug01-2", gid2, "bob", "accept")
        # charlie 未响应 → False
        assert db2.all_members_responded("bug01-2", gid2) is False

    def _fresh_db(self):
        """创建一个新的独立数据库实例用于子测试"""
        import tempfile
        return Database(tempfile.mktemp(suffix=".db"))


# ============================================================
# 第 7 组：级联删除与数据完整性
# ============================================================

class TestCascadeAndIntegrity:
    """
    【数据完整性测试】
    
    测试 delete_user 是否正确清理了关联数据。
    """

    def test_delete_user_cleans_friend_relations(self, db):
        """
        【测试49】删除用户时，关联的好友关系被清除
        """
        pw = bcrypt.hashpw("pw".encode(), bcrypt.gensalt())
        db.add_user("alice", pw)
        db.add_user("bob", pw)
        db.add_friend_request("alice", "bob")
        db.accept_friend_request("alice", "bob")
        assert db.is_friend("alice", "bob") is True

        db.delete_user("alice")
        # alice 已被删除，好友关系也应该消失
        assert db.user_exists("alice") is False

    def test_delete_user_cleans_file_requests(self, db):
        """
        【测试50】删除用户时，关联的文件请求被清除
        """
        pw = bcrypt.hashpw("pw".encode(), bcrypt.gensalt())
        db.add_user("alice", pw)
        db.add_user("bob", pw)
        db.save_file_request("alice", "bob", "f.txt", 10, b"x", "fr-1")

        db.delete_user("alice")
        # 文件请求应该被清理
        assert db.get_file_request("fr-1") is None


# ============================================================
# 总结：如何运行这些测试
# ============================================================
"""
运行所有数据库测试:
  .venv/bin/python -m pytest tests/test_database.py -v

运行某一组测试:
  .venv/bin/python -m pytest tests/test_database.py::TestFriendSystem -v

运行单个测试:
  .venv/bin/python -m pytest tests/test_database.py::TestFriendSystem::test_accept_friend_request -v

显示每个测试的耗时（帮助发现慢查询）:
  .venv/bin/python -m pytest tests/test_database.py -v --durations=5
"""
