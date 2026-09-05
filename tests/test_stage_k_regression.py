"""
============================================================
阶段 K 用户实测缺陷回归 —— 服务端协议层（TDD：修复前预期红）
============================================================

【背景】
  2026-08-19 用户实测发现三个缺陷，本文件锁定其服务端契约。

【缺陷②：已查看消息重登后仍显示未读徽标】
  用户在线时收到（已实时送达）并查看过的消息，重新登录后
  offline_messages 仍以 status='sent' 推送 → 客户端再次计未读。

  根因：offline_messages 的状态只在登录时 get_offline_messages()
  里由 sent 翻转为 delivered；实时送达（live forward）的进程内
  不会翻状态，导致"已送达/已查看"的消息在下次登录被当作未读
  重新推送。

  契约（修复后须满足）：
    - 实时送达给在线接收者的私聊消息，接收者下次登录的离线推送
      携带 status='delivered'（真实 Flutter 客户端收到实时消息后
      会自动发送 receipt 回执，测试按此模拟）
    - 实时送达给在线成员的群聊消息，成员下次登录的离线推送
      携带 status='delivered'（真实客户端群聊不发回执，
      服务端须在转发成功后自标记）
    - 回归保护：离线期间到达的消息，接收者首次登录仍推 'sent'
      （未读徽标正常显示），再次登录推 'delivered'

【缺陷③：文件撤回不完整（无"已撤回"落库持久化）】
  撤回已接受的文件后，message_history / offline_messages 的状态
  必须持久化为 'recalled'；重登后离线推送与 history_response
  携带 status='recalled'，客户端据此在消息体后附加"已撤回"标志。

  契约（修复后须满足）：
    - 文件被接受后撤回 → message_history status='recalled'、
      offline_messages status='recalled'（含 file_path 不变）
    - 撤回确认 recall 通知发送方与接收方
    - 重登后 history_response 携带该文件行 status='recalled'
    - 回归保护：未接受的文件请求撤回 → file_requests 删除 +
      recall 确认 + 接收方收到 chat 提示（既有行为）

【运行】
  .venv/bin/python -m pytest tests/test_stage_k_regression.py -v
"""

import os
import sys
import json
import uuid

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _login(harness, username, password, consume=True):
    c = harness.client()
    c.login(username, password, consume=consume)
    return c


def _make_friends_with(harness, a, b):
    """在数据库层建立 a <-> b 好友关系（绕过协议，供场景预置）。"""
    with harness.db._get_connection() as conn:
        conn.execute(
            "INSERT INTO friends (user1, user2, status) VALUES (?, ?, 'accepted')",
            (a, b))
        conn.execute(
            "INSERT INTO friends (user1, user2, status) VALUES (?, ?, 'accepted')",
            (b, a))
        conn.commit()


def _create_group_with(harness, creator, group_name, *members):
    """创建群组并让 members 全部加入（数据库层直建，绕过协议）。"""
    gid = harness.db.create_group(group_name, creator)
    for m in members:
        harness.db.join_group(gid, m)
    return gid


def _send_chat(client, sender_name, target, content, group_id=None):
    """sender 向 target 发一条 chat/group_chat，返回 message_id。"""
    mid = str(uuid.uuid4())
    if group_id is not None:
        client.send("group_chat", content, group_id=str(group_id),
                    message_id=mid)
    else:
        client.send("chat", content, to=target, message_id=mid)
    return mid


def _send_file_request(client, sender, target, filename="a.pdf",
                       content=b"file-data"):
    """sender 向 target 发送一个文件请求（小文件落盘路径）。"""
    mid = str(uuid.uuid4())
    client.send("file", content, to=target, filename=filename,
                filesize=str(len(content)), message_id=mid)
    return mid


def _offline_of(initial, message_id):
    """从 recv_initial 结果中按 message_id 取离线推送的 (header, body)。"""
    return [m for m in initial["offline"]
            if m[0].get("message_id") == message_id]


def _drain_notices(client, timeout=0.6):
    """消费缓冲中的确认/通知消息，返回 [(header, body)]。"""
    drained = []
    while True:
        h, d = client.recv(timeout=timeout)
        if h is None:
            break
        drained.append((h, d))
    return drained


# ============================================================
# 缺陷② —— 已查看消息重登后不得再以 status='sent' 推送（未读徽标回归）
# ============================================================

class TestUnreadReLoginRegression:

    def test_live_delivered_private_message_pushed_as_delivered_on_relogin(self, harness):
        """私聊实时送达后，接收者重登的离线推送必须携带 status='delivered'。

        模拟真实 Flutter 客户端行为：收到实时消息后自动发送 receipt 回执。
        修复前该消息保持 status='sent'，重登推送 sent → 未读徽标复发（缺陷）。
        """
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")

        # alice → bob 实时消息（bob 在线，live forward）
        mid = _send_chat(alice, "alice", "bob", "在线消息")
        bob.expect("chat")

        # 真实 Flutter 客户端收到实时消息后自动回执（服务端应据此/或按
        # 转发成功把该行标记 delivered，保证重登不复发未读）
        bob.send("receipt", "", message_id=mid, to="alice")

        # bob 重登：离线推送不得再携带 sent（否则客户端重新计未读）
        bob.close()
        bob2 = _login(harness, "bob", "password456", consume=False)
        initial = bob2.recv_initial()
        offline = _offline_of(initial, mid)
        assert offline, "实时送达过的消息应仍作为最近历史推送"
        assert offline[0][0].get("status") == "delivered", \
            f"已实时送达的消息重登后不得推 sent，实际: {offline[0][0].get('status')}"

    def test_live_delivered_group_message_pushed_as_delivered_on_relogin(self, harness):
        """群聊实时送达后，成员重登的离线推送必须携带 status='delivered'。

        真实客户端群聊不发回执，服务端须在实时转发成功后自标记。
        """
        alice = _login(harness, "alice", "password123")
        gid = _create_group_with(harness, "alice", "unread-reg", "bob")
        bob = _login(harness, "bob", "password456")
        _drain_notices(bob)

        mid = _send_chat(alice, "alice", None, "群在线消息", group_id=gid)
        bob.expect("group_chat")

        bob.close()
        bob2 = _login(harness, "bob", "password456", consume=False)
        initial = bob2.recv_initial()
        offline = _offline_of(initial, mid)
        assert offline, "群聊实时送达过的消息应仍作为最近历史推送"
        assert offline[0][0].get("status") == "delivered", \
            f"已实时送达的群聊消息重登后不得推 sent，实际: {offline[0][0].get('status')}"

    def test_live_delivered_private_message_without_receipt_still_delivered(self, harness):
        """实时送达但回执丢失（客户端崩溃/回执未发）：重登同样不得复发未读。"""
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")

        mid = _send_chat(alice, "alice", "bob", "无回执在线消息")
        bob.expect("chat")
        # 不发回执（模拟回执丢失场景）

        bob.close()
        bob2 = _login(harness, "bob", "password456", consume=False)
        initial = bob2.recv_initial()
        offline = _offline_of(initial, mid)
        assert offline and offline[0][0].get("status") == "delivered", \
            "实时送达语义不依赖回执：转发成功即应标记 delivered"

    def test_offline_message_first_login_sent_second_login_delivered(self, harness):
        """回归保护：离线期间到达的消息，首次登录仍推 sent（未读正常），
        再次登录推 delivered（已送达历史）。"""
        alice = _login(harness, "alice", "password123")
        mid = _send_chat(alice, "alice", "bob", "离线消息")
        alice.expect("chat", timeout=3)  # 用户离线 → 服务端回发"消息已保存"

        # 首次登录：未读（sent）→ 客户端显示未读徽标
        bob = _login(harness, "bob", "password456", consume=False)
        initial = bob.recv_initial()
        offline = _offline_of(initial, mid)
        assert offline and offline[0][0].get("status") == "sent", \
            "离线到达的消息首次登录应推 sent（未读徽标依据）"

        # 再次登录：已送达（delivered）→ 不再显示未读
        bob.close()
        bob2 = _login(harness, "bob", "password456", consume=False)
        initial2 = bob2.recv_initial()
        offline2 = _offline_of(initial2, mid)
        assert offline2 and offline2[0][0].get("status") == "delivered", \
            "再次登录应推 delivered（不复发未读）"


# ============================================================
# 缺陷③ —— 文件撤回持久化：status='recalled' 落库 + 重登/历史携带
# ============================================================

class TestFileRecallPersistence:

    def test_file_recall_after_accept_persists_recalled(self, harness):
        """文件被接受后撤回：message_history 与 offline_messages 均持久化 recalled。"""
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")

        mid = _send_file_request(alice, "alice", "bob")
        bob.expect("file_request")
        bob.send("file_response", "", response="accept", message_id=mid,
                 to="alice")
        bob.expect("file")  # 接收方收到文件（file 消息送达接受者）

        alice.send("recall", "", message_id=mid, to="bob")
        h_a, _ = alice.expect("recall")
        assert h_a.get("message_id") == mid, "发送方应收到撤回确认"
        h_b, _ = bob.expect("recall")
        assert h_b.get("message_id") == mid, "接收方应收到撤回广播"

        # 落库持久化：永久历史与离线消息均标记 recalled
        hist = harness.db.get_history_message(mid)
        assert hist is not None and hist["status"] == "recalled", \
            f"message_history 应持久化 recalled，实际: {hist}"
        info = harness.db.get_message_info(mid)
        assert info is not None and info[5] == "recalled", \
            f"offline_messages 应持久化 recalled，实际: {info}"

    def test_file_recall_history_response_carries_recalled(self, harness):
        """撤回的文件重登后：history_response 携带 status='recalled'，
        客户端据此在消息体后附加"已撤回"标志。"""
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")

        mid = _send_file_request(alice, "alice", "bob")
        bob.expect("file_request")
        bob.send("file_response", "", response="accept", message_id=mid,
                 to="alice")
        bob.expect("file")
        alice.send("recall", "", message_id=mid, to="bob")
        alice.expect("recall")
        bob.expect("recall")

        # 发送方重登后拉取历史：撤回状态必须携带
        alice.close()
        alice2 = _login(harness, "alice", "password123", consume=False)
        alice2.recv_initial()
        alice2.send("fetch_history", "", to="bob")
        h, d = alice2.expect("history_response")
        batch = json.loads(d.decode())
        by_id = {m["message_id"]: m for m in batch}
        assert mid in by_id, "撤回的文件应仍在历史中（状态置 recalled 而非删除）"
        assert by_id[mid]["status"] == "recalled", \
            f"历史应携带 recalled，实际: {by_id[mid]['status']}"
        assert by_id[mid]["filename"] == "a.pdf"

    def test_file_recall_before_accept_marks_recalled(self, harness):
        """个人文件撤回（未接受）：不报错，请求行保留并标记 recalled（P-61 缺陷修复，
        与群组文件撤回一致）——接收方再接受时提示"对方已撤回"，而非"文件请求不存在"。"""
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")

        mid = _send_file_request(alice, "alice", "bob")
        bob.expect("file_request")

        alice.send("recall", "", message_id=mid, to="bob")
        h_a, _ = alice.expect("recall")
        assert h_a.get("message_id") == mid
        # 接收方收到"撤回文件请求"的 chat 提示（既有行为）
        h_b, d_b = bob.expect("chat")
        assert "撤回了文件请求" in d_b.decode()
        # 请求行保留并标记 recalled（供接收方接受时提示"对方已撤回"）
        row = harness.db.get_file_request(mid)
        assert row is not None and row[6] == "recalled", \
            f"文件请求应标记 recalled，实际: {row}"
        # 接收方再接受 → 提示"对方已撤回"，而非"文件请求不存在"
        bob.send("file_response", "", response="accept", message_id=mid, to="alice")
        h_b2, d_b2 = bob.expect("error")
        assert "对方已撤回" in d_b2.decode(), \
            f"应提示对方已撤回，实际: {d_b2.decode()}"
        assert "不存在" not in d_b2.decode()

    def test_recalled_file_message_not_pushed_as_sent_on_relogin(self, harness):
        """撤回后的文件不得在重登时以 sent 状态推送（避免复发为"新文件"）。"""
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")

        mid = _send_file_request(alice, "alice", "bob")
        bob.expect("file_request")
        bob.send("file_response", "", response="accept", message_id=mid,
                 to="alice")
        bob.expect("file")
        alice.send("recall", "", message_id=mid, to="bob")
        alice.expect("recall")
        bob.expect("recall")

        # 发送方重登：recalled 行不得以 sent 出现（offline 推送排除 recalled）
        alice.close()
        alice2 = _login(harness, "alice", "password123", consume=False)
        initial = alice2.recv_initial()
        pushed = [m for m in initial["offline"] if m[0].get("message_id") == mid]
        for hdr in pushed:
            assert hdr[0].get("status") != "sent", \
                "已撤回的文件不得以 sent 复发（未读/新文件语义）"


class TestFileUnreadReLoginRegression:

    def test_live_delivered_file_not_pushed_as_sent_on_relogin(self, harness):
        """缺陷②文件形态：实时送达（接受后回传）的文件不得在重登时以
        status='sent' 复发——否则文件消息也被误计未读徽标。"""
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")

        mid = _send_file_request(alice, "alice", "bob")
        bob.expect("file_request")
        bob.send("file_response", "", response="accept", message_id=mid,
                 to="alice")
        bob.expect("file")

        # 接收方重登：已实时送达的文件不得以 sent 重新推送
        bob.close()
        bob2 = _login(harness, "bob", "password456", consume=False)
        initial = bob2.recv_initial()
        pushed = [m for m in initial["offline"] if m[0].get("message_id") == mid]
        for hdr in pushed:
            assert hdr[0].get("status") != "sent", \
                "已实时送达的文件重登后不得推 sent（delivered 文件本就不重复下发）"


# ============================================================
# 缺陷④（第二轮用户实测）—— 群组文件撤回
# ============================================================
# 2026-08-19 第二轮实测发现：
#   ① 群组中发送文件后撤回显示"错误：撤回群组消息请求失败"，但其实文件
#      已成功撤回——根因：delete_group_file_request 误取最后一条 DELETE
#      （group_file_responses）的 rowcount，无成员响应时恒为 0 → 误报失败。
#   ② 撤回后其他成员点击接收报"群组文件请求不存在"——应提示"对方已撤回"。
#      ——修复：撤回改为标记 group_file_requests.status='recalled'（保留行），
#        成员响应时据 status 提示"对方已撤回"。

def _send_group_file(client, sender, gid, filename="a.pdf", content=b"data",
                     mid=None):
    """sender 向群组 gid 发送一个群文件请求。"""
    mid = mid or str(uuid.uuid4())
    client.send("file", content, to=f"group_{gid}", filename=filename,
                filesize=str(len(content)), message_id=mid)
    return mid


class TestGroupFileRecallRegression:

    def test_group_file_recall_without_responses_succeeds(self, harness):
        """撤回群组文件前无成员响应：不得误报失败（rowcount 修复），
        请求行保留并标记 recalled，成员收到撤回提示。"""
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        gid = _create_group_with(harness, "alice", "grec", "bob")
        _drain_notices(bob)

        mid = _send_group_file(alice, "alice", gid)
        bob.expect("group_file_request")

        # 撤回（无任何成员响应过）
        alice.send("recall", "", message_id=mid, to=f"group_{gid}")
        # 发送者也会收到群内"系统"撤回提示 chat（既有行为），先消费再取确认
        h_n, d_n = alice.expect("chat")
        assert "撤回了群组文件请求" in d_n.decode()
        h_a, _ = alice.expect("recall")
        assert h_a.get("message_id") == mid, "撤回应返回确认而非错误"
        # 请求行保留并标记 recalled（供成员接受时提示"对方已撤回"）
        row = harness.db.get_group_file_request(mid)
        assert row is not None and row[6] == "recalled", \
            f"群组文件请求应标记 recalled，实际: {row}"
        # 成员收到撤回提示（chat 通知）
        h_b, d_b = bob.expect("chat")
        assert "撤回了群组文件请求" in d_b.decode()

    def test_group_file_accept_after_recall_returns_recalled(self, harness):
        """撤回后成员点击接收 → 提示"对方已撤回"，而非"文件不存在"。"""
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        gid = _create_group_with(harness, "alice", "grec2", "bob")
        _drain_notices(bob)

        mid = _send_group_file(alice, "alice", gid)
        bob.expect("group_file_request")
        alice.send("recall", "", message_id=mid, to=f"group_{gid}")
        alice.expect("chat")  # 发送者收到群内撤回提示（既有行为）
        alice.expect("recall")
        bob.expect("chat")

        # 成员仍点击"接收"（客户端在收到撤回提示前已打开待处理列表的竞态）
        bob.send("group_file_response", "", response="accept",
                 message_id=mid, group_id=str(gid))
        h, d = bob.expect("error")
        assert "对方已撤回" in d.decode(), \
            f"应提示对方已撤回，实际: {d.decode()}"
        assert "不存在" not in d.decode()

    def test_recalled_group_file_excluded_from_pending(self, harness):
        """已撤回的群组文件不再出现在成员的待处理请求列表中（重登不复发）。"""
        db = harness.db
        gid = db.create_group("grec3", "alice")
        db.join_group(gid, "bob")
        db.save_group_file_request(gid, "alice", "f.bin", 10, b"data", "gfr-r1")
        db.save_group_file_request(gid, "alice", "f2.bin", 10, b"data", "gfr-r2")

        db.mark_group_file_request_recalled("gfr-r1")
        pending = db.get_pending_group_file_requests(gid, "bob")
        ids = {p[3] for p in pending}
        assert "gfr-r1" not in ids, "已撤回的请求不得出现在待处理列表"
        assert "gfr-r2" in ids, "未撤回的请求应仍在待处理列表"

    def test_delete_group_file_request_without_responses_returns_true(self, harness):
        """rowcount 修复回归：无成员响应时删除群组文件请求返回 True。"""
        db = harness.db
        gid = db.create_group("grec4", "alice")
        db.save_group_file_request(gid, "alice", "f.bin", 10, b"data", "gfr-del-1")
        assert db.delete_group_file_request("gfr-del-1") is True
        assert db.get_group_file_request("gfr-del-1") is None

    def test_group_file_recall_idempotent(self, harness):
        """已撤回的群组文件再次撤回：幂等成功（不报错）。"""
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        gid = _create_group_with(harness, "alice", "grec5", "bob")
        _drain_notices(bob)

        mid = _send_group_file(alice, "alice", gid)
        bob.expect("group_file_request")
        alice.send("recall", "", message_id=mid, to=f"group_{gid}")
        alice.expect("chat")  # 发送者收到群内撤回提示（既有行为）
        alice.expect("recall")
        bob.expect("chat")

        # 再次撤回：幂等成功（不重复群内提示，仅返回确认）
        alice.send("recall", "", message_id=mid, to=f"group_{gid}")
        h, _ = alice.expect("recall")
        assert h.get("message_id") == mid
        row = harness.db.get_group_file_request(mid)
        assert row is not None and row[6] == "recalled"


# ============================================================
# 缺陷⑥（第三轮用户实测）—— 个人聊天文件撤回
# ============================================================
# 2026-08-19 第三轮实测要求：个人聊天文件撤回与群组文件撤回一致——
# 撤回不报错，接收方点击接收时提示"对方已撤回文件"，而非"文件请求不存在"。

class TestPrivateFileRecallRegression:

    def test_private_file_recall_marks_recalled_no_error(self, harness):
        """个人文件撤回（未接受）：撤回确认返回、不报错，请求行标记 recalled。"""
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")

        mid = _send_file_request(alice, "alice", "bob")
        bob.expect("file_request")
        alice.send("recall", "", message_id=mid, to="bob")
        h_a, _ = alice.expect("recall")
        assert h_a.get("message_id") == mid, "撤回应返回确认而非错误"
        bob.expect("chat")  # 接收方收到撤回提示（既有行为）
        row = harness.db.get_file_request(mid)
        assert row is not None and row[6] == "recalled", \
            f"文件请求应标记 recalled，实际: {row}"

    def test_private_file_accept_after_recall_returns_recalled(self, harness):
        """撤回后接收方点击接收 → 提示"对方已撤回"，而非"文件请求不存在"。"""
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")

        mid = _send_file_request(alice, "alice", "bob")
        bob.expect("file_request")
        alice.send("recall", "", message_id=mid, to="bob")
        alice.expect("recall")
        bob.expect("chat")

        bob.send("file_response", "", response="accept", message_id=mid, to="alice")
        h, d = bob.expect("error")
        assert "对方已撤回" in d.decode(), \
            f"应提示对方已撤回，实际: {d.decode()}"
        assert "不存在" not in d.decode()

    def test_recalled_private_file_excluded_from_pending(self, harness):
        """已撤回的个人文件不再出现在接收方待处理请求列表（重登不复发）。"""
        db = harness.db
        db.save_file_request("alice", "bob", "f.bin", 10, b"data", "fr-r1")
        db.save_file_request("alice", "bob", "f2.bin", 10, b"data", "fr-r2")

        db.mark_file_request_recalled("fr-r1")
        pending = db.get_pending_file_requests("bob")
        ids = {p[3] for p in pending}
        assert "fr-r1" not in ids, "已撤回的请求不得出现在待处理列表"
        assert "fr-r2" in ids, "未撤回的请求应仍在待处理列表"

    def test_private_file_recall_idempotent(self, harness):
        """已撤回的个人文件再次撤回：幂等成功（不报错）。"""
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")

        mid = _send_file_request(alice, "alice", "bob")
        bob.expect("file_request")
        alice.send("recall", "", message_id=mid, to="bob")
        alice.expect("recall")
        bob.expect("chat")

        alice.send("recall", "", message_id=mid, to="bob")
        h, _ = alice.expect("recall")
        assert h.get("message_id") == mid
        row = harness.db.get_file_request(mid)
        assert row is not None and row[6] == "recalled"
