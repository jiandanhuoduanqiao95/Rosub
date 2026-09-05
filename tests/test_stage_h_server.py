"""
============================================================
阶段 H —— 桌面通知 + Session 持久化 + 消息搜索：服务端协议层 TDD 测试（H5）
============================================================

【目标】
  测试阶段 H5（消息搜索）的服务端行为，先写测试（红），等待实现（绿）：
    H5  search_history 协议         （server_message_handler.py）

【契约（实现方需严格遵守，本测试即据此验证）】
----- H5 search_history -----
  C → S:
    type    = "search_history"
    keyword = <搜索关键字>（必填，extra_headers）
    to      = <私聊对方用户名>（可选；缺省为全局搜索该用户参与的所有消息）
    group_id = <群组 ID>（可选；优先于 to，群组范围搜索）
    limit   = <数量上限>（可选，默认 50；非数字回退 50）
  S → C 成功：
    type = "search_response"
    to   = 回显请求的 to（缺省空串）
    group_id = 回显请求的 group_id（缺省空串）
    keyword = 回显请求的 keyword（客户端据此显示"搜索：<关键字>"）
    body = JSON 数组，元素 schema 与 fetch_history 的 history_response 一致：
           {sender, receiver, type, content, message_id, filename,
            timestamp, group_id, status}
  S → C 失败：
    - keyword 缺失或为空 → error 含 "搜索关键字"
  搜索范围：database.search_message_history(user, keyword, with_user, group_id,
  limit)，即用户发出或收到的全部历史（message_history 永久保留，
  与好友关系无关）。排序：timestamp DESC, id DESC（最新在前）。
  LIMIT 语义：仅限制返回条数。
  范围优先级：group_id > to > 全局。
  注：系统公告会话（'服务器'）无搜索入口（客户端 ChatView 不显示搜索按钮），
  search_history 无 system 范围支持。

【运行】
  实现前：测试断言会超时失败（服务端无 search_history 分支），属 TDD 红。
  实现后：全部通过。

  .venv/bin/python -m pytest tests/test_stage_h_server.py -v
"""

import os
import sys
import json
import uuid

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _seed_history(harness):
    """预置 alice <-> bob 与 alice <-> carol 的消息历史（含关键字 'Python'）。

    返回 [(message_id, content), ...] 供断言。
    """
    rows = [
        ("alice", "bob", "讨论 Python 项目"),
        ("bob", "alice", "Python 很棒"),
        ("alice", "bob", "今天天气不错"),
        ("bob", "alice", "周末去爬山"),
        ("alice", "carol", "Python 和 carol 无关紧要"),
        ("carol", "alice", "收到"),
    ]
    saved = []
    for sender, receiver, content in rows:
        mid = str(uuid.uuid4())
        harness.db.save_message_history(
            sender, receiver, "chat", content.encode("utf-8"), message_id=mid)
        saved.append((mid, content))
    return saved


class TestSearchHistoryHandler:
    """H5 —— search_history 服务端处理器。"""

    def test_search_history_private_match_both_directions(self, harness):
        """双向历史都匹配：alice 搜 'Python' → 3 条（含自己发的与对方发的）。"""
        _seed_history(harness)
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        alice.send("search_history", "", keyword="Python")
        h, d = alice.expect("search_response", timeout=3)
        assert h["type"] == "search_response"
        batch = json.loads(d.decode())
        assert len(batch) == 3, f"实际: {[b['content'] for b in batch]}"
        contents = {b["content"] for b in batch}
        assert contents == {
            "讨论 Python 项目", "Python 很棒", "Python 和 carol 无关紧要"}

    def test_search_history_no_results_returns_empty(self, harness):
        """无匹配 → search_response 空数组（非 error）。"""
        _seed_history(harness)
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        alice.send("search_history", "", keyword="xyznonexistent")
        h, d = alice.expect("search_response", timeout=3)
        assert h["type"] == "search_response"
        assert json.loads(d.decode()) == []

    def test_search_history_missing_keyword_rejected(self, harness):
        """缺 keyword 头 → error 含 '搜索关键字'。"""
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        alice.send("search_history", "")
        h, d = alice.expect("error", timeout=3)
        assert "搜索关键字" in d.decode(), f"实际: {d.decode()}"

    def test_search_history_empty_keyword_rejected(self, harness):
        """keyword 为空串 → error 含 '搜索关键字'。"""
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        alice.send("search_history", "", keyword="")
        h, d = alice.expect("error", timeout=3)
        assert "搜索关键字" in d.decode(), f"实际: {d.decode()}"

    def test_search_history_global_without_to(self, harness):
        """不带 to → 全局搜索该用户参与的所有会话（含 carol）。"""
        _seed_history(harness)
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        alice.send("search_history", "", keyword="Python")
        h, d = alice.expect("search_response", timeout=3)
        batch = json.loads(d.decode())
        # 全局：alice 参与的所有会话（alice↔bob 2 条 + alice↔carol 1 条）
        assert len(batch) == 3

    def test_search_history_to_filters_private_chat(self, harness):
        """带 to=bob → 仅 alice↔bob 的消息（carol 的匹配结果被排除）。"""
        _seed_history(harness)
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        alice.send("search_history", "", keyword="Python", to="bob")
        h, d = alice.expect("search_response", timeout=3)
        assert h.get("to") == "bob"
        batch = json.loads(d.decode())
        assert len(batch) == 2, f"实际: {[b['content'] for b in batch]}"
        assert {b["content"] for b in batch} == {"讨论 Python 项目", "Python 很棒"}

    def test_search_history_limit_caps_results(self, harness):
        """limit 生效：15 条匹配中 limit=5 → 返回最新 5 条（timestamp DESC, id DESC）。"""
        saved = []
        for i in range(15):
            mid = str(uuid.uuid4())
            harness.db.save_message_history(
                "alice", "bob", "chat",
                f"keyword{i}".encode("utf-8"), message_id=mid)
            saved.append((mid, f"keyword{i}"))
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        alice.send("search_history", "", keyword="keyword", to="bob", limit="5")
        h, d = alice.expect("search_response", timeout=3)
        batch = json.loads(d.decode())
        assert len(batch) == 5
        # 最新在前（timestamp DESC, id DESC）：最后 5 条 = keyword14..keyword10
        newest_first = [c for _, c in reversed(saved[-5:])]
        assert [b["content"] for b in batch] == newest_first, f"实际: {batch}"

    def test_search_history_malformed_limit_defaults(self, harness):
        """limit 非数字 → 回退默认 50，不崩溃。"""
        _seed_history(harness)
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        alice.send("search_history", "", keyword="Python", to="bob",
                   limit="not-a-number")
        h, d = alice.expect("search_response", timeout=3)
        assert h["type"] == "search_response"
        batch = json.loads(d.decode())
        assert len(batch) == 2  # 全部返回，无异常

    def test_search_history_response_schema(self, harness):
        """响应元素 schema 与 history_response 对齐（sender/type/content/...）。"""
        _seed_history(harness)
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        alice.send("search_history", "", keyword="Python", to="bob")
        h, d = alice.expect("search_response", timeout=3)
        assert h["type"] == "search_response"
        assert h.get("keyword") == "Python", "服务端需回显 keyword"
        assert h.get("to") == "bob"
        batch = json.loads(d.decode())
        assert len(batch) >= 1
        for item in batch:
            assert "sender" in item and item["sender"] in ("alice", "bob")
            assert item["type"] == "chat"
            assert isinstance(item["content"], str)
            assert item["message_id"]
            assert item["timestamp"]
            assert item["status"]
            # filename/group_id 键存在（可为 None）
            assert "filename" in item and "group_id" in item

    def test_search_history_via_real_chat_flow(self, harness):
        """真实聊天流：alice 发消息给 bob（入库历史）→ 搜索能搜到。"""
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()
        bob = harness.client()
        bob.login("bob", "password456", consume=False)
        bob.recv_initial()

        alice.send("chat", "我们聊聊 flutter 吧", to="bob",
                   message_id=str(uuid.uuid4()))
        alice.drain(timeout=0.6)
        bob.drain(timeout=0.6)

        alice.send("search_history", "", keyword="flutter")
        h, d = alice.expect("search_response", timeout=3)
        batch = json.loads(d.decode())
        assert len(batch) == 1
        assert batch[0]["content"] == "我们聊聊 flutter 吧"

    def test_search_history_special_chars_no_crash(self, harness):
        """关键字含 % _ 中文 emoji → 不崩溃（记录通配符透传行为）。"""
        _seed_history(harness)
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        # '%' 是 SQL LIKE 通配符：搜索全部（记录行为，不崩溃）
        alice.send("search_history", "", keyword="%")
        h, d = alice.expect("search_response", timeout=3)
        batch = json.loads(d.decode())
        assert isinstance(batch, list) and len(batch) >= 1

        # 中文 + emoji 关键字
        alice.send("search_history", "", keyword="🐍蛇 中文")
        h, d = alice.expect("search_response", timeout=3)
        assert json.loads(d.decode()) == []

    def test_search_history_no_history_returns_empty(self, harness):
        """无任何历史 → search_response 空数组。"""
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        alice.send("search_history", "", keyword="anything")
        h, d = alice.expect("search_response", timeout=3)
        assert json.loads(d.decode()) == []

    def test_search_history_not_friends_history_kept(self, harness):
        """删除好友后历史仍可搜索（message_history 永久保留）。"""
        _seed_history(harness)
        harness.db.remove_friend("alice", "bob")
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        alice.send("search_history", "", keyword="Python", to="bob")
        h, d = alice.expect("search_response", timeout=3)
        batch = json.loads(d.decode())
        assert len(batch) == 2, "删除好友不应影响历史搜索（永久历史）"

    def test_search_history_group_scope(self, harness):
        """带 group_id → 仅搜索该群组的历史消息，不混入私聊/其他群组。"""
        harness.db.save_message_history(
            "bob", "", "group_chat", "群里聊 Python".encode("utf-8"),
            group_id=1, message_id=str(uuid.uuid4()))
        harness.db.save_message_history(
            "alice", "", "group_chat", "Python 群消息 2".encode("utf-8"),
            group_id=1, message_id=str(uuid.uuid4()))
        harness.db.save_message_history(
            "bob", "", "group_chat", "别的群的 Python".encode("utf-8"),
            group_id=2, message_id=str(uuid.uuid4()))
        harness.db.save_message_history(
            "alice", "bob", "chat", "私聊 Python".encode("utf-8"),
            message_id=str(uuid.uuid4()))
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        alice.send("search_history", "", keyword="Python", group_id="1")
        h, d = alice.expect("search_response", timeout=3)
        assert h["type"] == "search_response"
        assert h.get("group_id") == "1", "服务端需回显 group_id"
        batch = json.loads(d.decode())
        assert len(batch) == 2, f"实际: {[b['content'] for b in batch]}"
        assert {b["content"] for b in batch} == {"群里聊 Python", "Python 群消息 2"}
        assert all(b["group_id"] == 1 for b in batch)

    def test_search_history_group_no_match(self, harness):
        """群组范围无匹配 → search_response 空数组。"""
        harness.db.save_message_history(
            "bob", "", "group_chat", "你好群".encode("utf-8"),
            group_id=5, message_id=str(uuid.uuid4()))
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        alice.send("search_history", "", keyword="xyznonexistent", group_id="5")
        h, d = alice.expect("search_response", timeout=3)
        assert h.get("group_id") == "5"
        assert json.loads(d.decode()) == []

    def test_search_history_group_takes_precedence_over_to(self, harness):
        """同时带 group_id 与 to → 以群组范围为准（优先级约定）。"""
        harness.db.save_message_history(
            "bob", "", "group_chat", "群 Python".encode("utf-8"),
            group_id=9, message_id=str(uuid.uuid4()))
        harness.db.save_message_history(
            "bob", "alice", "chat", "私聊 Python".encode("utf-8"),
            message_id=str(uuid.uuid4()))
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        alice.send("search_history", "", keyword="Python", to="bob",
                   group_id="9")
        h, d = alice.expect("search_response", timeout=3)
        assert h.get("group_id") == "9"
        batch = json.loads(d.decode())
        assert len(batch) == 1
        assert batch[0]["content"] == "群 Python"

    def test_search_history_multi_sender_header(self, harness):
        """R-P28：sender 头逗号分隔多发送者 → IN 匹配（选项式多选）。"""
        _seed_history(harness)
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        alice.send("search_history", "", keyword="Python",
                   sender="alice,bob")
        h, d = alice.expect("search_response", timeout=3)
        batch = json.loads(d.decode())
        contents = {b["content"] for b in batch}
        # 三条含 Python 的消息分别由 alice（2 条）与 bob（1 条）发送
        assert contents == {"讨论 Python 项目", "Python 很棒",
                            "Python 和 carol 无关紧要"}

    def test_search_history_single_sender_unchanged(self, harness):
        """R-P28：sender 单值（旧客户端形态）行为不变。"""
        _seed_history(harness)
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        alice.send("search_history", "", keyword="Python", sender="bob")
        h, d = alice.expect("search_response", timeout=3)
        batch = json.loads(d.decode())
        assert {b["content"] for b in batch} == {"Python 很棒"}
        assert all(b["sender"] == "bob" for b in batch)

    def test_search_history_sender_with_spaces_tolerated(self, harness):
        """R-P28：逗号分隔值带空白 → 切分后 strip，不产生空发送者。"""
        _seed_history(harness)
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        alice.send("search_history", "", keyword="Python",
                   sender=" bob , ,alice ")
        h, d = alice.expect("search_response", timeout=3)
        batch = json.loads(d.decode())
        assert {b["content"] for b in batch} == {
            "讨论 Python 项目", "Python 很棒", "Python 和 carol 无关紧要"}

    def test_search_history_sender_only_no_keyword_ok(self, harness):
        """R-P28：仅多发送者、无关键词/时间 → 合法组合检索（不报错）。"""
        _seed_history(harness)
        alice = harness.client()
        alice.login("alice", "password123", consume=False)
        alice.recv_initial()

        alice.send("search_history", "", sender="bob,carol")
        h, d = alice.expect("search_response", timeout=3)
        assert h["type"] == "search_response"
        batch = json.loads(d.decode())
        senders = {b["sender"] for b in batch}
        assert senders == {"bob", "carol"}
