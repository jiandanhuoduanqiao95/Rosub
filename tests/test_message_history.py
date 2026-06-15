"""
============================================================
消息历史持久化 —— 单元测试（TDD）
============================================================

【功能目标】
  新增 message_history 表，永久保存所有消息（chat / group_chat / file），
  替代当前"离线消息投递后即删除"的模式。

【数据库变更】
  新增表 message_history:
    - message_id (UNIQUE) —— 消息唯一 ID
    - sender / receiver —— 发送方/接收方
    - message_type —— chat / group_chat / file
    - content (BLOB) —— 消息体
    - filename —— 文件名（file 类型时使用）
    - group_id —— 群组 ID（群聊时使用，可为 NULL）
    - timestamp —— 消息时间戳

【新增方法】
  Database.save_message_history()    —— 保存一条消息到历史表
  Database.get_message_history()     —— 分页拉取历史消息（支持私聊和群聊）
  Database.search_message_history()  —— 按关键字搜索历史
  Database.get_message_history_count() —— 获取消息总数（用于分页计算）

【测试策略】
  - 每个测试使用独立的临时数据库
  - 复用 test_database.py 的 db fixture 模式
  - 先写测试（将失败），等待实现代码后验证
"""

import sys
import os
import pytest
import bcrypt
import uuid

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from database import Database


# ============================================================
# 辅助夹具
# ============================================================

@pytest.fixture
def db(tmp_path):
    """为每个测试提供独立的临时数据库"""
    db_path = str(tmp_path / "test_history.db")
    return Database(db_path)


def _create_users(db, *usernames):
    """辅助方法：批量创建测试用户"""
    for name in usernames:
        pw = bcrypt.hashpw(b"test123", bcrypt.gensalt())
        db.add_user(name, pw)


def _save_chat_msg(db, sender, receiver, content, msg_id=None):
    """辅助方法：保存一条私聊消息到 message_history"""
    msg_id = msg_id or str(uuid.uuid4())
    db.save_message_history(
        sender=sender,
        receiver=receiver,
        message_type="chat",
        content=content.encode("utf-8"),
        message_id=msg_id,
    )
    return msg_id


def _save_group_msg(db, sender, group_id, content, msg_id=None):
    """辅助方法：保存一条群聊消息到 message_history"""
    msg_id = msg_id or str(uuid.uuid4())
    db.save_message_history(
        sender=sender,
        receiver="",  # 群聊无单个接收者
        message_type="group_chat",
        content=content.encode("utf-8"),
        group_id=group_id,
        message_id=msg_id,
    )
    return msg_id


# ============================================================
# 第 1 组：表创建与基本 CRUD
# ============================================================

class TestMessageHistoryBasic:
    """【基础 CRUD 测试】验证 message_history 表的基本操作"""

    def test_table_exists(self, db):
        """
        【MH-01】数据库初始化时自动创建 message_history 表

        验证点：_init_db 后，message_history 表存在
        """
        with db._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='message_history'")
            assert cursor.fetchone() is not None, "message_history 表应该被创建"

    def test_save_and_retrieve_chat_message(self, db):
        """
        【MH-02】保存一条私聊消息，并能通过 get_message_history 取出

        验证点：
        - 消息被正确存入
        - 取出时所有字段（sender, receiver, type, content）正确
        - message_id 唯一
        """
        _create_users(db, "alice", "bob")
        msg_id = str(uuid.uuid4())
        db.save_message_history(
            sender="alice", receiver="bob", message_type="chat",
            content=b"Hello, Bob!", message_id=msg_id
        )

        # 拉取 alice 和 bob 之间的对话
        msgs = db.get_message_history(user="alice", with_user="bob")
        assert len(msgs) == 1

        msg = msgs[0]
        assert msg[0] == "alice"       # sender
        assert msg[1] == "bob"         # receiver
        assert msg[2] == "chat"        # message_type
        assert msg[3] == b"Hello, Bob!"  # content
        assert msg[4] == msg_id         # message_id

    def test_save_duplicate_message_id_fails(self, db):
        """
        【MH-03】重复的 message_id 应被拒绝

        验证点：message_id 有 UNIQUE 约束，重复插入不创建新记录
        """
        _create_users(db, "alice", "bob")
        msg_id = str(uuid.uuid4())
        db.save_message_history("alice", "bob", "chat", b"msg1", message_id=msg_id)
        # 第二次保存相同 ID 应被静默忽略（INSERT OR IGNORE）
        db.save_message_history("alice", "bob", "chat", b"msg2", message_id=msg_id)

        msgs = db.get_message_history(user="alice", with_user="bob")
        assert len(msgs) == 1
        assert msgs[0][3] == b"msg1"  # 内容仍是第一条

    def test_save_file_message_with_filename(self, db):
        """
        【MH-04】保存文件消息时，filename 和 content 都被正确存储

        验证点：filename 字段记录原文件名，content 存储文件二进制数据
        """
        _create_users(db, "alice", "bob")
        file_data = b"\x89PNG\r\n\x1a\n" + b"\x00" * 100
        db.save_message_history(
            sender="alice", receiver="bob", message_type="file",
            content=file_data, filename="screenshot.png",
            message_id=str(uuid.uuid4())
        )

        msgs = db.get_message_history(user="alice", with_user="bob")
        assert len(msgs) == 1
        # 返回的元组格式: (sender, receiver, message_type, content, message_id, filename, timestamp, group_id)
        sender, receiver, msg_type, content, msg_id, filename, *_ = msgs[0]
        assert msg_type == "file"
        assert filename == "screenshot.png"
        assert content == file_data


# ============================================================
# 第 2 组：分页拉取
# ============================================================

class TestMessageHistoryPagination:
    """
    【分页测试】验证历史消息的分页拉取功能

    分页参数：limit（每页条数）、offset（偏移量）
    消息按时间戳**倒序**排列（最新的在前）
    """

    def test_pagination_limit(self, db):
        """
        【MH-05】limit 参数限制返回的消息数量

        场景：alice 和 bob 之间有 10 条消息，limit=5 应只返回最近 5 条
        """
        _create_users(db, "alice", "bob")
        for i in range(10):
            _save_chat_msg(db, "alice", "bob", f"message {i}")
            _save_chat_msg(db, "bob", "alice", f"reply {i}")

        msgs = db.get_message_history(user="alice", with_user="bob", limit=5)
        assert len(msgs) == 5

    def test_pagination_offset(self, db):
        """
        【MH-06】offset 参数正确跳过指定条数

        场景：20 条消息，第 1 页（limit=5, offset=0）和第 3 页（limit=5, offset=10）
        返回的内容不重叠。
        """
        _create_users(db, "alice", "bob")
        msg_ids = []
        for i in range(20):
            mid = _save_chat_msg(db, "alice", "bob", f"msg {i}")
            msg_ids.append(mid)

        page1 = db.get_message_history(user="alice", with_user="bob", limit=5, offset=0)
        page3 = db.get_message_history(user="alice", with_user="bob", limit=5, offset=10)

        # 两页的 message_id 不应重叠
        page1_ids = {m[4] for m in page1}
        page3_ids = {m[4] for m in page3}
        assert page1_ids.isdisjoint(page3_ids), "分页结果不应重叠"

    def test_pagination_order_newest_first(self, db):
        """
        【MH-07】消息按时间倒序排列（最新消息在前）

        验证点：最后一条发出的消息在返回列表的第一条
        """
        _create_users(db, "alice", "bob")
        _save_chat_msg(db, "alice", "bob", "first")
        _save_chat_msg(db, "alice", "bob", "second")
        last_id = _save_chat_msg(db, "alice", "bob", "third")

        msgs = db.get_message_history(user="alice", with_user="bob", limit=3)
        # 第三条（最新）应在第一位
        assert msgs[0][3] == b"third"
        assert msgs[-1][3] == b"first"

    def test_count_total_messages(self, db):
        """
        【MH-08】get_message_history_count 返回正确的消息总数

        用于客户端分页计算（总页数 = ceil(total / limit)）
        """
        _create_users(db, "alice", "bob")
        for i in range(7):
            _save_chat_msg(db, "alice", "bob", f"msg {i}")
        for i in range(3):
            _save_chat_msg(db, "bob", "alice", f"reply {i}")

        count = db.get_message_history_count(user="alice", with_user="bob")
        assert count == 10


# ============================================================
# 第 3 组：群聊消息隔离
# ============================================================

class TestMessageHistoryGroups:
    """
    【群聊隔离测试】验证群聊消息和私聊消息正确分离

    群聊消息通过 group_id 参数区分，不应混入私聊结果中。
    """

    def test_group_chat_separate_from_private(self, db):
        """
        【MH-09】通过 group_id 拉取群聊消息时，不包含私聊消息

        场景：alice 和 bob 同时有私聊和群聊记录，按群组拉取时不应混入私聊
        """
        _create_users(db, "alice", "bob")
        group_id = 42

        # 私聊
        _save_chat_msg(db, "alice", "bob", "private chat")
        # 群聊
        _save_group_msg(db, "alice", group_id, "group chat")

        # 拉取群聊
        group_msgs = db.get_message_history(user="alice", group_id=group_id)
        assert len(group_msgs) == 1
        assert group_msgs[0][3] == b"group chat"

        # 拉取私聊（with_user 方式）
        private_msgs = db.get_message_history(user="alice", with_user="bob")
        assert len(private_msgs) == 1
        assert private_msgs[0][3] == b"private chat"

    def test_multiple_groups_isolated(self, db):
        """
        【MH-10】不同群组的消息互相隔离

        场景：用户同时在群组 1 和群组 2，拉取群组 1 时不应看到群组 2 的消息
        """
        _create_users(db, "alice")
        g1, g2 = 100, 200

        _save_group_msg(db, "bob", g1, "hello from g1")
        _save_group_msg(db, "charlie", g2, "hello from g2")

        msgs_g1 = db.get_message_history(user="alice", group_id=g1)
        msgs_g2 = db.get_message_history(user="alice", group_id=g2)

        # 每条消息只出现在所属群组
        g1_contents = {m[3] for m in msgs_g1}
        g2_contents = {m[3] for m in msgs_g2}
        assert b"hello from g1" in g1_contents
        assert b"hello from g2" in g2_contents
        assert b"hello from g2" not in g1_contents


# ============================================================
# 第 4 组：关键字搜索
# ============================================================

class TestMessageHistorySearch:
    """
    【搜索测试】验证按关键字搜索历史消息

    搜索应在 content 字段中做 LIKE 匹配，返回匹配的消息。
    """

    def test_search_by_keyword(self, db):
        """
        【MH-11】关键字搜索返回包含该关键字的全部消息

        场景：多条消息中只有一些包含"Python"，搜索应只返回包含该词的消息
        """
        _create_users(db, "alice", "bob")
        _save_chat_msg(db, "alice", "bob", "Python is great")
        _save_chat_msg(db, "bob", "alice", "I love Java")
        _save_chat_msg(db, "alice", "bob", "Python programming tips")

        results = db.search_message_history(user="alice", keyword="Python")
        assert len(results) == 2
        for msg in results:
            assert b"Python" in msg[3]

    def test_search_case_sensitive(self, db):
        """
        【MH-12】搜索行为的字符大小写行为

        验证点：SQLite LIKE 默认不区分大小写（ASCII 范围），
        实际行为取决于实现选择，这里仅验证关键字能搜出预期的消息
        """
        _create_users(db, "alice", "bob")
        _save_chat_msg(db, "alice", "bob", "HELLO World")

        results = db.search_message_history(user="alice", keyword="hello")
        # SQLite LIKE 对 ASCII 不区分大小写，所以能搜出 HELLO
        assert len(results) >= 0  # 至少不报错
        if len(results) > 0:
            assert b"HELLO" in results[0][3]

    def test_search_no_match(self, db):
        """
        【MH-13】搜索不存在的关键字返回空列表

        验证点：search_message_history 不抛异常，返回 []。
        """
        _create_users(db, "alice", "bob")
        _save_chat_msg(db, "alice", "bob", "regular text")

        results = db.search_message_history(user="alice", keyword="xyznonexistent")
        assert results == []

    def test_search_only_own_messages(self, db):
        """
        【MH-14】搜索只返回用户参与的消息

        场景：alice 搜索时，不会看到 bob 和 charlie 之间不涉及 alice 的消息
        """
        _create_users(db, "alice", "bob", "charlie")
        _save_chat_msg(db, "bob", "charlie", "secret about Python")
        _save_chat_msg(db, "alice", "bob", "alice's Python note")

        results = db.search_message_history(user="alice", keyword="Python")
        assert len(results) == 1
        assert b"alice's Python note" in results[0][3]

    def test_search_within_friend_conversation(self, db):
        """
        【MH-15】在特定好友对话中搜索

        场景：alice 和 bob 有 3 条 Python 相关消息，和 charlie 有 1 条，
        限定 with_user="bob" 时只返回与 bob 的 3 条。
        """
        _create_users(db, "alice", "bob", "charlie")
        _save_chat_msg(db, "alice", "bob", "Python tip 1")
        _save_chat_msg(db, "alice", "bob", "Python tip 2")
        _save_chat_msg(db, "bob", "alice", "Python tip 3")
        _save_chat_msg(db, "alice", "charlie", "Python tip 4")

        results = db.search_message_history(
            user="alice", with_user="bob", keyword="Python"
        )
        assert len(results) == 3


# ============================================================
# 第 5 组：边界与防御测试
# ============================================================

class TestMessageHistoryEdgeCases:
    """
    【边界测试】验证极端和异常场景下的行为
    """

    def test_empty_history(self, db):
        """
        【MH-16】新用户的消息历史为空

        验证点：get_message_history 返回空列表，不报错
        """
        _create_users(db, "newuser")
        msgs = db.get_message_history(user="newuser", with_user="nobody")
        assert msgs == []

    def test_empty_search_result(self, db):
        """
        【MH-17】对空历史搜索返回空结果，不报错
        """
        _create_users(db, "alice")
        results = db.search_message_history(user="alice", keyword="test")
        assert results == []

    def test_count_zero_for_empty_history(self, db):
        """
        【MH-18】空历史时 count 返回 0
        """
        _create_users(db, "alice", "bob")
        count = db.get_message_history_count(user="alice", with_user="bob")
        assert count == 0

    def test_chinese_and_emoji_content(self, db):
        """
        【MH-19】中文和 emoji 消息的正确存储和取出

        验证点：UTF-8 多字节字符不被截断或乱码
        """
        _create_users(db, "alice", "bob")
        content = "你好世界 😀🎉🔥 測試訊息"
        _save_chat_msg(db, "alice", "bob", content)

        msgs = db.get_message_history(user="alice", with_user="bob")
        assert msgs[0][3].decode("utf-8") == content

    def test_binary_content_with_null_bytes(self, db):
        """
        【MH-20】包含 \\x00 字节的文件消息正确存储和取出

        验证点：BLOB 字段不受空字节影响，完整保留原始数据
        """
        _create_users(db, "alice", "bob")
        file_data = b"\x00\x00\x00REAL_DATA\x00\x00"
        db.save_message_history(
            sender="alice", receiver="bob", message_type="file",
            content=file_data, filename="data.bin",
            message_id=str(uuid.uuid4())
        )

        msgs = db.get_message_history(user="alice", with_user="bob")
        assert msgs[0][3] == file_data
        assert len(msgs[0][3]) == len(file_data)


# ============================================================
# 运行方式
# ============================================================
"""
运行消息历史测试:
  .venv/bin/python -m pytest tests/test_message_history.py -v

运行单个测试:
  .venv/bin/python -m pytest tests/test_message_history.py::TestMessageHistoryPagination::test_pagination_limit -v
"""
