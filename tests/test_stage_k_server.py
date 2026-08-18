"""
============================================================
阶段 K —— 会话体验：服务端协议层（已实现，全部转绿）
============================================================

【目标】
  测试阶段 K（见《软件开发文档4.1.0.md》§11 阶段 K / §13.3）的服务端
  协议行为：

    K1（P1-11 会话置顶）：   pin / unpin（conversations 元数据同步）
    K2（P1-12 逐会话草稿）： set_draft（conversations 元数据同步）
    K3（P1-13/14 静音）：    mute（conversations 元数据同步）
    K1-K3 登录推送：         list_conversations（会话元数据随初始数据推送）
    K5（P1-2 引用回复）：    reply
    K5（P1-3 转发）：        forward（以转发人为第一手，无来源标注）
    K5（P1-4 表情回应）：    reaction（离线推送携带聚合，跨登录持久化）
    K5 历史扩展：            history_response 携带 reply_to/reactions

  （用户决策修订：P1-1 消息编辑已移除；转发不标注来源。）

【契约（实现方需严格遵守，本测试即据此验证）】
  ----- K1 会话置顶 -----
  C → S: type="pin", header {peer_key=<好友用户名 或 'group_N'>}
  S → C: type="chat" 确认（from=系统）含 "置顶"
  C → S: type="unpin", header {peer_key}
  S → C: type="chat" 确认含 "取消置顶"
    失败: 好友用户名非好友 → error 含 "好友"；
          group_N 非成员 → error 含 "群组"；
          peer_key 无法解析（非好友且非法 group_N）→ error 含 "会话"
    落库: conversations 表 pinned 置 1/0（upsert 部分更新，不触碰其余字段）

  ----- K2 逐会话草稿 -----
  C → S: type="set_draft", header {peer_key}, body=draft 文本
  S → C: 无确认（静默，草稿高频更新）；落库 conversations.draft
    失败: 同上 peer_key 校验
    body 为空 → draft 清空为 ''

  ----- K3 会话静音 -----
  C → S: type="mute", header {peer_key, muted="1"/"0"}
  S → C: type="chat" 确认含 "静音"（置静音）/ "解除静音"（取消）
    失败: 同上 peer_key 校验

  ----- K1-K3 登录推送 -----
  S → C（登录初始数据，最后一条，紧随 list_blocked）:
      type="admin_response", header {response_type="list_conversations"},
      body=JSON [{"peer_key", "pinned", "muted", "draft", "cleared_at"}, ...]
      - 无会话元数据 → 推送空数组 []
      - 会话元数据为本用户视角（username 不随推送暴露冗余）

  ----- K5 引用回复 -----
  C → S: type="reply", header {reply_to=<原消息id>, to?/group_id?},
          body=回复文本（服务端生成新 message_id）
  S → C 私聊接收方（在线）: type="chat", header {from, message_id=<新id>,
          reply_to, reply_preview=<原文缩略>}, body=回复文本
  S → C 群聊: type="group_chat", header {from, group_id, message_id,
          reply_to, reply_preview}, body=回复文本
    失败:
      - 回复文本为空 → error 含 "内容"
      - 被引用消息不存在 → error 含 "消息"
      - 私聊: 被引用消息不属于该会话（本人非双方之一）→ error 含 "消息"
      - 群聊: 被引用消息不属于同群 → error 含 "消息"
      - 被引用消息已撤回 → 允许，reply_preview="[消息已撤回]"
    落库: message_history 新行 reply_to=<原消息id>；
          目标离线 → offline_messages 保存（chat，带 reply_to/reply_preview）

  ----- K5 转发 -----
  C → S: type="forward", header {source_message_id, to?/group_id?},
          body=''（客户端提供 message_id 沿用、缺省服务端 uuid 生成）
  S → C 私聊目标: type="chat", header {from=<转发者>, message_id=<新id>},
          body=原文（**以转发人为第一手，无任何来源标注**）
  S → C 群聊: type="group_chat", 同上加 group_id
    失败:
      - 源消息不存在 → error 含 "消息"
      - 源消息已撤回 → error 含 "撤回"
      - 源为 file 消息 → error 含 "文件"
      - 源消息参与者校验（私聊源本人非双方之一 / 群源本人非成员）→ error 含 "消息"
      - 私聊目标非好友 → error 含 "好友"
      - 群聊目标非成员 → error 含 "群组"
    落库: message_history 新行 sender=转发者（第一手归属）；
          目标离线 → offline_messages 保存普通 chat（无来源元数据）

  ----- K5 表情回应 -----
  C → S: type="reaction", header {message_id, emoji, action="add"/"remove",
          to?/group_id?}, body=''
  S → C 广播（私聊双方 / 群全体成员）: type="reaction",
      header {from, message_id, emoji, action, group_id?}
    失败:
      - 消息不存在 → error 含 "消息"
      - emoji 为空 → error 含 "表情"
      - 私聊: 消息参与者校验 → error 含 "消息"
      - 群聊: 非成员 → error 含 "群组"
    toggle: action=add 时若该用户对同一消息已有同 emoji →
            服务端切换为 remove 并广播 action=remove
    action=remove 时无既有反应 → 幂等广播（不报错）
    落库: reactions 表（每用户每消息一行，换 emoji 替换）

  ----- K5 历史扩展 -----
  history_response 每条消息 JSON 携带:
    reply_to（缺省 None）、reactions（dict: emoji → [用户名]，无反应为空 dict）
  离线推送（chat/group_chat）携带 reactions 聚合（表情跨登录持久化）。

【运行】
  .venv/bin/python -m pytest tests/test_stage_k_server.py -v
"""

import os
import sys
import json
import uuid
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from protocol import send_message


def _login(harness, username, password, consume=True):
    c = harness.client()
    c.login(username, password, consume=consume)
    # consume=False 时登录响应/初始数据由调用方自行消费（recv_initial 一次）
    return c


def _wait_for(predicate, timeout=3.0):
    """轮询等待服务端异步落库（如静默无确认的 set_draft）。"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return False


def _draft_of(harness, username, peer_key):
    conv = harness.db.get_conversation(username, peer_key)
    return conv["draft"] if conv else None


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
# K1 —— 会话置顶 pin / unpin
# ============================================================

class TestPinUnpin:

    def test_pin_friend_success(self, harness):
        alice = _login(harness, "alice", "password123")
        alice.send("pin", "", peer_key="bob")
        h, d = alice.expect("chat")
        assert "置顶" in d.decode()
        conv = harness.db.get_conversation("alice", "bob")
        assert conv["pinned"] is True

    def test_unpin_friend_success(self, harness):
        alice = _login(harness, "alice", "password123")
        alice.send("pin", "", peer_key="bob")
        alice.expect("chat")
        alice.send("unpin", "", peer_key="bob")
        h, d = alice.expect("chat")
        assert "取消置顶" in d.decode()
        assert harness.db.get_conversation("alice", "bob")["pinned"] is False

    def test_pin_group(self, harness):
        alice = _login(harness, "alice", "password123")
        gid = _create_group_with(harness, "alice", "kgroup", "bob")
        alice.send("pin", "", peer_key=f"group_{gid}")
        h, d = alice.expect("chat")
        assert "置顶" in d.decode()
        assert harness.db.get_conversation("alice", f"group_{gid}")["pinned"] is True

    def test_pin_non_friend_rejected(self, harness):
        alice = _login(harness, "alice", "password123")
        harness.add_user("carol")
        alice.send("pin", "", peer_key="carol")
        h, d = alice.expect("error")
        assert "好友" in d.decode()

    def test_pin_non_member_group_rejected(self, harness):
        alice = _login(harness, "alice", "password123")
        gid = _create_group_with(harness, "bob", "kgroup2")
        alice.send("pin", "", peer_key=f"group_{gid}")
        h, d = alice.expect("error")
        assert "群组" in d.decode()

    def test_pin_invalid_peer_key_rejected(self, harness):
        alice = _login(harness, "alice", "password123")
        alice.send("pin", "", peer_key="group_abc")
        h, d = alice.expect("error")
        assert "会话" in d.decode()

    def test_pin_does_not_touch_other_fields(self, harness):
        """upsert 部分更新：置顶不覆盖既有静音/草稿。"""
        alice = _login(harness, "alice", "password123")
        alice.send("mute", "", peer_key="bob", muted="1")
        alice.expect("chat")
        alice.send("set_draft", "草稿内容", peer_key="bob")
        alice.send("pin", "", peer_key="bob")
        alice.expect("chat")
        conv = harness.db.get_conversation("alice", "bob")
        assert conv["pinned"] is True
        assert conv["muted"] is True
        assert conv["draft"] == "草稿内容"

    def test_pin_isolated_between_users(self, harness):
        """alice 置顶 bob 不影响 bob 的元数据。"""
        alice = _login(harness, "alice", "password123")
        alice.send("pin", "", peer_key="bob")
        alice.expect("chat")
        assert harness.db.get_conversation("bob", "alice") is None


# ============================================================
# K2 —— 逐会话草稿 set_draft
# ============================================================

class TestSetDraft:

    def test_set_draft_friend(self, harness):
        alice = _login(harness, "alice", "password123")
        alice.send("set_draft", "还在写…", peer_key="bob")
        # 无确认：草稿高频更新，静默落库（轮询等待异步处理）
        assert _wait_for(lambda: _draft_of(harness, "alice", "bob") == "还在写…"), \
            f"草稿未落库: {harness.db.get_conversation('alice', 'bob')}"

    def test_set_draft_empty_clears(self, harness):
        alice = _login(harness, "alice", "password123")
        alice.send("set_draft", "先写点", peer_key="bob")
        assert _wait_for(lambda: _draft_of(harness, "alice", "bob") == "先写点")
        alice.send("set_draft", "", peer_key="bob")
        assert _wait_for(lambda: _draft_of(harness, "alice", "bob") == "")

    def test_set_draft_group(self, harness):
        alice = _login(harness, "alice", "password123")
        gid = _create_group_with(harness, "alice", "kdraft", "bob")
        alice.send("set_draft", "群草稿", peer_key=f"group_{gid}")
        assert _wait_for(
            lambda: _draft_of(harness, "alice", f"group_{gid}") == "群草稿")

    def test_set_draft_non_friend_rejected(self, harness):
        alice = _login(harness, "alice", "password123")
        harness.add_user("carol")
        alice.send("set_draft", "x", peer_key="carol")
        h, d = alice.expect("error")
        assert "好友" in d.decode()

    def test_set_draft_long_content(self, harness):
        alice = _login(harness, "alice", "password123")
        long_draft = "长草稿" * 500
        alice.send("set_draft", long_draft, peer_key="bob")
        assert _wait_for(
            lambda: _draft_of(harness, "alice", "bob") == long_draft)


# ============================================================
# K3 —— 会话静音 mute
# ============================================================

class TestMute:

    def test_mute_on(self, harness):
        alice = _login(harness, "alice", "password123")
        alice.send("mute", "", peer_key="bob", muted="1")
        h, d = alice.expect("chat")
        assert "静音" in d.decode()
        assert harness.db.get_conversation("alice", "bob")["muted"] is True

    def test_mute_off(self, harness):
        alice = _login(harness, "alice", "password123")
        alice.send("mute", "", peer_key="bob", muted="1")
        alice.expect("chat")
        alice.send("mute", "", peer_key="bob", muted="0")
        h, d = alice.expect("chat")
        assert "解除静音" in d.decode()
        assert harness.db.get_conversation("alice", "bob")["muted"] is False

    def test_mute_group(self, harness):
        alice = _login(harness, "alice", "password123")
        gid = _create_group_with(harness, "alice", "kmute", "bob")
        alice.send("mute", "", peer_key=f"group_{gid}", muted="1")
        alice.expect("chat")
        assert harness.db.get_conversation("alice", f"group_{gid}")["muted"] is True

    def test_mute_non_friend_rejected(self, harness):
        alice = _login(harness, "alice", "password123")
        harness.add_user("carol")
        alice.send("mute", "", peer_key="carol", muted="1")
        h, d = alice.expect("error")
        assert "好友" in d.decode()


# ============================================================
# K1-K3 —— list_conversations 登录推送
# ============================================================

class TestListConversationsPush:

    def test_login_pushes_conversations(self, harness):
        alice = _login(harness, "alice", "password123")
        alice.send("pin", "", peer_key="bob")
        alice.expect("chat")
        alice.send("mute", "", peer_key="bob", muted="1")
        alice.expect("chat")
        alice.send("set_draft", "开会前再看看", peer_key="bob")
        # set_draft 无确认，轮询等待落库后再重登
        assert _wait_for(
            lambda: _draft_of(harness, "alice", "bob") == "开会前再看看")

        # 重新登录：初始数据含 list_conversations
        alice2 = _login(harness, "alice", "password123", consume=False)
        initial = alice2.recv_initial()
        convs = {c.get("peer_key"): c for c in initial["conversations"]}
        assert "bob" in convs
        assert convs["bob"]["pinned"] == 1
        assert convs["bob"]["muted"] == 1
        assert convs["bob"]["draft"] == "开会前再看看"

    def test_login_without_meta_pushes_empty_list(self, harness):
        bob = _login(harness, "bob", "password456", consume=False)
        initial = bob.recv_initial()
        assert initial["conversations"] == []

    def test_push_contains_group_keys(self, harness):
        alice = _login(harness, "alice", "password123")
        gid = _create_group_with(harness, "alice", "kpush", "bob")
        alice.send("pin", "", peer_key=f"group_{gid}")
        alice.expect("chat")
        alice2 = _login(harness, "alice", "password123", consume=False)
        initial = alice2.recv_initial()
        keys = {c.get("peer_key") for c in initial["conversations"]}
        assert f"group_{gid}" in keys

    def test_push_is_last_after_blocked(self, harness):
        """推送顺序：list_conversations 为初始数据最后一条。"""
        alice = _login(harness, "alice", "password123")
        alice.send("pin", "", peer_key="bob")
        alice.expect("chat")
        alice2 = harness.client()
        alice2.send("login", "alice", password="password123")
        h, d = alice2.recv(timeout=3)
        assert h["type"] == "chat", "第一条应为登录响应"
        types = []
        while True:
            h, d = alice2.recv(timeout=2)
            if h is None:
                break
            types.append((h.get("type"), h.get("response_type")))
        admin = [t for t in types if t[0] == "admin_response"]
        assert admin and admin[-1] == ("admin_response", "list_conversations"), \
            f"list_conversations 应为最后一条 admin_response，实际: {types}"


# ============================================================
# K5 —— edit_message（P1-1 消息编辑）
# ============================================================

# ============================================================
# K5 —— reply 引用回复（P1-2）
# ============================================================

class TestReply:

    def test_reply_private(self, harness):
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        orig = _send_chat(alice, "alice", "bob", "明天爬山吗")
        bob.expect("chat")

        alice.send("reply", "去呀去呀", reply_to=orig, to="bob")
        h, d = bob.expect("chat")
        assert h["from"] == "alice"
        assert h["reply_to"] == orig
        assert h["reply_preview"] == "明天爬山吗"
        assert d.decode() == "去呀去呀"
        # 新 message_id（不是原 id），落库 reply_to
        new_mid = h["message_id"]
        assert new_mid != orig
        msg = harness.db.get_history_message(new_mid)
        assert msg["reply_to"] == orig

    def test_reply_group(self, harness):
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        gid = _create_group_with(harness, "alice", "kreply", "bob")
        _drain_notices(bob)
        orig = _send_chat(alice, "alice", None, "楼上说的", group_id=gid)
        bob.expect("group_chat")

        alice.send("reply", "我回复楼上", reply_to=orig, group_id=str(gid))
        h, d = bob.expect("group_chat")
        assert h["reply_to"] == orig
        assert h["reply_preview"] == "楼上说的"
        assert h.get("group_id") == str(gid)
        assert d.decode() == "我回复楼上"

    def test_reply_to_recalled_message(self, harness):
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        orig = _send_chat(alice, "alice", "bob", "将被撤回")
        bob.expect("chat")
        alice.send("recall", "", message_id=orig, to="bob")
        alice.expect("recall")
        bob.expect("recall")

        alice.send("reply", "引用已撤回", reply_to=orig, to="bob")
        h, d = bob.expect("chat")
        assert h["reply_to"] == orig
        assert h["reply_preview"] == "[消息已撤回]"

    def test_reply_to_nonexistent_rejected(self, harness):
        alice = _login(harness, "alice", "password123")
        alice.send("reply", "x", reply_to="ghost", to="bob")
        h, d = alice.expect("error")
        assert "消息" in d.decode()

    def test_reply_empty_content_rejected(self, harness):
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        orig = _send_chat(alice, "alice", "bob", "原文")
        bob.expect("chat")
        alice.send("reply", "", reply_to=orig, to="bob")
        h, d = alice.expect("error")
        assert "内容" in d.decode()

    def test_reply_to_foreign_private_message_rejected(self, harness):
        """alice 不能引用她不是参与者之一的私聊消息。"""
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        harness.add_user("carol")
        harness.add_user("dave")
        _make_friends_with(harness, "carol", "dave")
        carol = _login(harness, "carol", "pass123")
        dave = _login(harness, "dave", "pass123")
        orig = _send_chat(carol, "carol", "dave", "私密内容")
        dave.expect("chat")

        alice.send("reply", "偷听回复", reply_to=orig, to="bob")
        h, d = alice.expect("error")
        assert "消息" in d.decode()

    def test_reply_offline_delivery_with_headers(self, harness):
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        orig = _send_chat(alice, "alice", "bob", "离线前的话")
        bob.expect("chat")
        bob.close()

        alice.send("reply", "离线回复", reply_to=orig, to="bob")
        bob2 = _login(harness, "bob", "password456", consume=False)
        initial = bob2.recv_initial()
        replies = [m for m in initial["offline"]
                   if m[0].get("reply_to") == orig]
        assert replies, "离线回复应携带 reply_to header"
        assert replies[0][0]["reply_preview"] == "离线前的话"
        assert replies[0][1].decode() == "离线回复"


# ============================================================
# K5 —— forward 转发（P1-3）
# ============================================================
class TestForward:

    def test_forward_private_to_friend(self, harness):
        """转发以转发人为第一手：接收方看到的消息归属转发者本人，无来源标注。"""
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        harness.add_user("carol")
        _make_friends_with(harness, "alice", "carol")
        carol = _login(harness, "carol", "pass123")

        orig = _send_chat(bob, "bob", "alice", "给爱丽丝的话")
        alice.expect("chat")

        alice.send("forward", "", source_message_id=orig, to="carol")
        h, d = carol.expect("chat")
        assert h["from"] == "alice"
        assert h.get("forwarded_from") is None, "转发不标注来源"
        assert d.decode() == "给爱丽丝的话"
        new_mid = h["message_id"]
        msg = harness.db.get_history_message(new_mid)
        assert msg["sender"] == "alice"
        assert msg["receiver"] == "carol"

    def test_forward_to_group(self, harness):
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        gid = _create_group_with(harness, "alice", "kfwd", "bob")

        _drain_notices(bob)
        orig = _send_chat(alice, "alice", "bob", "值得分享")
        bob.expect("chat")

        alice.send("forward", "", source_message_id=orig,
                   group_id=str(gid))
        h, d = bob.expect("group_chat")
        assert h.get("group_id") == str(gid)
        assert h["from"] == "alice"
        assert h.get("forwarded_from") is None, "转发不标注来源"
        assert d.decode() == "值得分享"

    def test_forward_group_message_to_friend(self, harness):
        """跨群聊 → 私聊转发：消息归属转发者本人。"""
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        gid = _create_group_with(harness, "alice", "kfwd2", "bob")
        _drain_notices(bob)
        orig = _send_chat(bob, "bob", None, "群内消息", group_id=gid)
        alice.expect("group_chat")

        alice.send("forward", "", source_message_id=orig, to="bob")
        h, d = bob.expect("chat")
        assert h["from"] == "alice"
        assert h.get("forwarded_from") is None, "转发不标注来源"
        assert d.decode() == "群内消息"

    def test_forward_nonexistent_rejected(self, harness):
        alice = _login(harness, "alice", "password123")
        alice.send("forward", "", source_message_id="ghost", to="bob")
        h, d = alice.expect("error")
        assert "消息" in d.decode()

    def test_forward_recalled_rejected(self, harness):
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        orig = _send_chat(alice, "alice", "bob", "要撤回的话")
        bob.expect("chat")
        alice.send("recall", "", message_id=orig, to="bob")
        alice.expect("recall")
        bob.expect("recall")
        alice.send("forward", "", source_message_id=orig, to="bob")
        h, d = alice.expect("error")
        assert "撤回" in d.decode()

    def test_forward_file_message_rejected(self, harness):
        alice = _login(harness, "alice", "password123")
        mid = str(uuid.uuid4())
        harness.db.save_message_history(
            "alice", "bob", "file", b"data", filename="a.pdf",
            message_id=mid)
        alice.send("forward", "", source_message_id=mid, to="bob")
        h, d = alice.expect("error")
        assert "文件" in d.decode()

    def test_forward_invisible_source_rejected(self, harness):
        """alice 不能转发她不可见的消息（他人私聊）。"""
        alice = _login(harness, "alice", "password123")
        harness.add_user("carol")
        harness.add_user("dave")
        _make_friends_with(harness, "carol", "dave")
        carol = _login(harness, "carol", "pass123")
        dave = _login(harness, "dave", "pass123")
        orig = _send_chat(carol, "carol", "dave", "私密")
        dave.expect("chat")
        alice.send("forward", "", source_message_id=orig, to="bob")
        h, d = alice.expect("error")
        assert "消息" in d.decode()

    def test_forward_to_non_friend_rejected(self, harness):
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        harness.add_user("carol")
        orig = _send_chat(bob, "bob", "alice", "内容")
        alice.expect("chat")
        alice.send("forward", "", source_message_id=orig, to="carol")
        h, d = alice.expect("error")
        assert "好友" in d.decode()

    def test_forward_to_non_member_group_rejected(self, harness):
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        gid = _create_group_with(harness, "bob", "knomember")
        orig = _send_chat(bob, "bob", "alice", "内容")
        alice.expect("chat")
        alice.send("forward", "", source_message_id=orig,
                   group_id=str(gid))
        h, d = alice.expect("error")
        assert "群组" in d.decode()

    def test_forward_offline_delivery(self, harness):
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        harness.add_user("carol")
        _make_friends_with(harness, "alice", "carol")
        carol = _login(harness, "carol", "pass123")
        orig = _send_chat(bob, "bob", "alice", "稍后看")
        alice.expect("chat")
        carol.close()

        alice.send("forward", "", source_message_id=orig, to="carol")
        carol2 = _login(harness, "carol", "pass123", consume=False)
        initial = carol2.recv_initial()
        # 转发以转发人为第一手：离线推送为普通 chat，来自转发者 alice
        fwds = [m for m in initial["offline"]
                if m[0].get("from") == "alice"]
        assert fwds
        assert fwds[0][0].get("forwarded_from") is None
        assert fwds[0][1].decode() == "稍后看"


# ============================================================
# K5 —— reaction 表情回应（P1-4）
# ============================================================

class TestReaction:

    def test_add_reaction_private_broadcast(self, harness):
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        orig = _send_chat(alice, "alice", "bob", "收到")
        bob.expect("chat")

        alice.send("reaction", "", message_id=orig, emoji="👍",
                   action="add", to="bob")
        h_a = alice.expect("reaction")[0]
        assert h_a["from"] == "alice"
        assert h_a["emoji"] == "👍"
        assert h_a["action"] == "add"
        h_b = bob.expect("reaction")[0]
        assert h_b["from"] == "alice"
        assert h_b["emoji"] == "👍"
        assert harness.db.get_reactions(orig) == [
            {"username": "alice", "emoji": "👍"}]

    def test_toggle_same_emoji_removes(self, harness):
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        orig = _send_chat(alice, "alice", "bob", "内容")
        bob.expect("chat")

        alice.send("reaction", "", message_id=orig, emoji="👍",
                   action="add", to="bob")
        alice.expect("reaction")
        bob.expect("reaction")
        alice.send("reaction", "", message_id=orig, emoji="👍",
                   action="add", to="bob")
        h_a = alice.expect("reaction")[0]
        assert h_a["action"] == "remove", "同 emoji 再次 add 应切换为 remove"
        bob.expect("reaction")
        assert harness.db.get_reactions(orig) == []

    def test_replace_emoji(self, harness):
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        orig = _send_chat(alice, "alice", "bob", "内容")
        bob.expect("chat")
        alice.send("reaction", "", message_id=orig, emoji="👍",
                   action="add", to="bob")
        alice.expect("reaction")
        bob.expect("reaction")
        alice.send("reaction", "", message_id=orig, emoji="😂",
                   action="add", to="bob")
        alice.expect("reaction")
        bob.expect("reaction")
        assert harness.db.get_reactions(orig) == [
            {"username": "alice", "emoji": "😂"}]

    def test_explicit_remove(self, harness):
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        orig = _send_chat(alice, "alice", "bob", "内容")
        bob.expect("chat")
        alice.send("reaction", "", message_id=orig, emoji="👍",
                   action="add", to="bob")
        alice.expect("reaction")
        bob.expect("reaction")
        alice.send("reaction", "", message_id=orig, emoji="👍",
                   action="remove", to="bob")
        h = alice.expect("reaction")[0]
        assert h["action"] == "remove"
        assert harness.db.get_reactions(orig) == []

    def test_multiple_users_reactions(self, harness):
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        orig = _send_chat(alice, "alice", "bob", "内容")
        bob.expect("chat")
        alice.send("reaction", "", message_id=orig, emoji="👍",
                   action="add", to="bob")
        alice.expect("reaction")
        bob.expect("reaction")
        bob.send("reaction", "", message_id=orig, emoji="👍",
                 action="add", to="alice")
        alice.expect("reaction")
        bob.expect("reaction")
        reactions = harness.db.get_reactions(orig)
        assert {r["username"] for r in reactions} == {"alice", "bob"}

    def test_group_reaction_broadcast(self, harness):
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        gid = _create_group_with(harness, "alice", "kreact", "bob")
        _drain_notices(bob)
        orig = _send_chat(alice, "alice", None, "群消息", group_id=gid)
        bob.expect("group_chat")

        bob.send("reaction", "", message_id=orig, emoji="😂",
                 action="add", group_id=str(gid))
        h_a = alice.expect("reaction")[0]
        assert h_a.get("group_id") == str(gid)
        assert h_a["from"] == "bob"
        bob.expect("reaction")

    def test_reaction_nonexistent_rejected(self, harness):
        alice = _login(harness, "alice", "password123")
        alice.send("reaction", "", message_id="ghost", emoji="👍",
                   action="add", to="bob")
        h, d = alice.expect("error")
        assert "消息" in d.decode()

    def test_reaction_empty_emoji_rejected(self, harness):
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        orig = _send_chat(alice, "alice", "bob", "内容")
        bob.expect("chat")
        alice.send("reaction", "", message_id=orig, emoji="",
                   action="add", to="bob")
        h, d = alice.expect("error")
        assert "表情" in d.decode()

    def test_reaction_foreign_message_rejected(self, harness):
        alice = _login(harness, "alice", "password123")
        harness.add_user("carol")
        harness.add_user("dave")
        _make_friends_with(harness, "carol", "dave")
        carol = _login(harness, "carol", "pass123")
        dave = _login(harness, "dave", "pass123")
        orig = _send_chat(carol, "carol", "dave", "私密")
        dave.expect("chat")
        alice.send("reaction", "", message_id=orig, emoji="👍",
                   action="add", to="bob")
        h, d = alice.expect("error")
        assert "消息" in d.decode()

    def test_reaction_non_member_group_rejected(self, harness):
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        gid = _create_group_with(harness, "alice", "kreact2", "bob")
        _drain_notices(bob)
        orig = _send_chat(alice, "alice", None, "群消息", group_id=gid)
        bob.expect("group_chat")
        harness.add_user("carol")
        carol = _login(harness, "carol", "pass123")
        carol.send("reaction", "", message_id=orig, emoji="👍",
                   action="add", group_id=str(gid))
        h, d = carol.expect("error")
        assert "群组" in d.decode()


# ============================================================
# K5 —— history_response 扩展字段
# ============================================================

class TestHistoryResponseExtensions:

    def test_history_carries_reply_and_reactions(self, harness):
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")

        orig = _send_chat(alice, "alice", "bob", "原始")
        bob.expect("chat")
        # 回复（带 reply_to）
        alice.send("reply", "回复一", reply_to=orig, to="bob")
        bob.expect("chat")
        # 反应
        alice.send("reaction", "", message_id=orig, emoji="👍",
                   action="add", to="bob")
        alice.expect("reaction")
        bob.expect("reaction")

        bob.send("fetch_history", "", to="alice")
        h, d = bob.expect("history_response")
        batch = json.loads(d.decode())
        by_id = {m["message_id"]: m for m in batch}
        assert by_id[orig]["content"] == "原始"
        assert by_id[orig]["reactions"] == {"👍": ["alice"]}
        replied = [m for m in batch if m.get("reply_to") == orig]
        assert replied and replied[0]["reply_to"] == orig

    def test_history_without_extensions_defaults(self, harness):
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        _send_chat(alice, "alice", "bob", "普通消息")
        bob.expect("chat")

        bob.send("fetch_history", "", to="alice")
        h, d = bob.expect("history_response")
        batch = json.loads(d.decode())
        m = batch[0]
        assert m.get("reply_to") is None
        assert m["reactions"] == {}

    def test_offline_push_carries_reactions(self, harness):
        """表情跨登录持久化：离线推送携带 reactions 聚合（P1-4）。"""
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        orig = _send_chat(alice, "alice", "bob", "收到")
        bob.expect("chat")
        bob.close()  # bob 下线

        # 参与者 alice 对消息加反应
        alice.send("reaction", "", message_id=orig, emoji="👍",
                   action="add", to="bob")
        alice.expect("reaction")

        bob2 = _login(harness, "bob", "password456", consume=False)
        initial = bob2.recv_initial()
        reacted = [m for m in initial["offline"]
                   if m[0].get("message_id") == orig]
        assert reacted, "离线推送应包含被反应的消息"
        assert json.loads(reacted[0][0]["reactions"]) == {"👍": ["alice"]}

    def test_group_offline_push_carries_reactions(self, harness):
        """群聊离线推送携带聚合反应（跨登录持久化，多用户）。"""
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        gid = _create_group_with(harness, "alice", "kreac-off", "bob")
        harness.add_user("carol")
        harness.db.join_group(gid, "carol")
        carol = _login(harness, "carol", "pass123")
        _drain_notices(bob)
        _drain_notices(carol)

        orig = _send_chat(alice, "alice", None, "群消息", group_id=gid)
        bob.expect("group_chat")
        carol.expect("group_chat")
        bob.close()  # bob 下线

        alice.send("reaction", "", message_id=orig, emoji="👍",
                   action="add", group_id=str(gid))
        alice.expect("reaction")
        carol.expect("reaction")
        carol.send("reaction", "", message_id=orig, emoji="😂",
                   action="add", group_id=str(gid))
        carol.expect("reaction")
        alice.expect("reaction")

        bob2 = _login(harness, "bob", "password456", consume=False)
        initial = bob2.recv_initial()
        reacted = [m for m in initial["offline"]
                   if m[0].get("message_id") == orig]
        assert reacted, "群聊离线推送应包含被反应的消息"
        assert json.loads(reacted[0][0]["reactions"]) == {
            "👍": ["alice"], "😂": ["carol"]}
