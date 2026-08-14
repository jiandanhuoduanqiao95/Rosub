"""
============================================================
阶段 J —— 身份与社交：服务端协议层 TDD 契约（待实现）
============================================================

【目标】
  测试阶段 J（见《软件开发文档4.1.0.md》§11 阶段 J / §13.2 P0-2/P0-3/P0-5 /
  §13.3 P1-8/P1-9/P1-10）的服务端协议行为，先写测试（红），等待实现（绿）：

    J1（P0-2 用户资料）：  get_profile / set_profile 协议（server_message_handler.py）
    J2（P0-3 在线状态）：  presence 广播（登录/登出/黑名单隐藏）（server_client_handler.py）
    J3（P0-5 密码重置）：  admin_command action=reset_password（server_admin_handler.py）
    J4（P1-8/9/10）：      好友备注/分组、黑名单、验证消息、用户搜索（server_message_handler.py）

【契约（实现方需严格遵守，本测试即据此验证）】
  ----- J1 用户资料 -----
  C → S: type="get_profile", header {to=<目标用户名>}
  S → C: type="profile_response", header {to=<目标用户名>},
         body = JSON {username, nickname, avatar, signature, last_seen, is_admin}
    - 目标不存在 → error 含 "用户"
  C → S: type="set_profile", headers {nickname?, avatar?, signature?}（至少一个）
  S → C: type="profile_response", header {to=自己用户名}, body = 自己资料 JSON
    - nickname/avatar/signature 均为空或缺失 → error 含 "资料"
  J1 附加：登录成功后更新该用户 last_seen（get_profile 可观察到非空）。

  ----- J2 在线状态 presence -----
  S → C: type="presence", headers {from=<用户名>, online="1"/"0"}
    - 登录/注册成功：向该用户之外的全部在线用户广播 presence online="1"
    - 新登录者：登录后收到当前全部其他在线用户的 presence 快照（online="1"），
      快照须在初始数据（好友/群组列表）**之前**到达，否则客户端无法捕获
    - 连接断开：向其余在线用户广播 presence online="0"
    - 传输通道登录（login 带 transfer=1）：不广播、不发快照
    - 黑名单隐藏：subject 与 viewer 任一方向存在拉黑关系 → 不广播、不入快照
      （被拉黑者不可见拉黑者在线状态，反之亦然）

  ----- J3 管理员重置密码 -----
  C → S: type="admin_command", header {action="reset_password", new_password=<新密码>},
         body = <目标用户名>
  S → C 成功: type="admin_response", header {response_type="reset_password"},
              body 含目标用户名；目标用户在线 → 收到 chat（from=系统）含 "重置"
  S → C 失败:
    - 非管理员 → error "无管理员权限"
    - 目标不存在 → error 含 "用户"
    - 新密码不合法（validate_password）→ error
  重置后：旧密码登录失败，新密码登录成功（管理员密钥校验除外）。
  强制下线：目标用户在线时其旧会话被服务端关闭——连接断开（EOF），
  无法继续发送消息，其他在线用户收到其 presence 下线广播。

  ----- J4 好友备注/分组 -----
  C → S: type="set_friend_note", headers {to, note}
  S → C: type="chat" 确认（含 "备注"）；非好友 → error "不是您的好友"
  C → S: type="set_friend_group", headers {to, group_name}
  S → C: type="chat" 确认（含 "分组"）；非好友 → error
  C → S: type="list_friends_meta"
  S → C: type="admin_response", header {response_type="list_friends_meta"},
         body = JSON [{"username", "note", "group_name"}, ...]（本视图视角）

  ----- J4 黑名单 -----
  C → S: type="block_user", header {to}
  S → C: type="chat" 确认（含 "拉黑"）；拉黑自己 → error；目标不存在 → error
  C → S: type="unblock_user", header {to}
  S → C: type="chat" 确认（含 "解除"）；未拉黑 → error 含 "黑名单"
  C → S: type="list_blocked"
  S → C: type="admin_response", header {response_type="list_blocked"},
         body = JSON [用户名, ...]
  拦截规则（拉黑方向：A 拉黑 B → B 对 A 受限）：
    - chat：B → A → error 含 "拉黑"；A → B 正常（单向）
    - file（小文件）与大文件直传（file 超过阈值）：B → A → error 含 "拉黑"
    - file_transfer_check：B 对 A → error 含 "拉黑"
    - friend_request：任一方向拉黑 → error 含 "拉黑"（不可请求）
    - 被拒的 chat/file 不写入 offline_messages（不落库）
  注：黑名单不删除好友关系，但发送被拦（好友关系与拦截独立）。

  ----- J4 好友请求验证消息 -----
  C → S: type="friend_request", headers {to, message?}
    - message 可选；缺省不带
  在线接收方：friend_request 通知带 message header（缺省不带）
  离线接收方：load_offline_data 推送的 friend_request 带 message header

  ----- J4 用户搜索 -----
  C → S: type="search_users", header {keyword}
  S → C: type="user_search_response", body = JSON [用户名, ...]（排除自己）
  S → C 失败: keyword 为空 → error 含 "关键字"

【运行】
  实现前：断言超时/无响应（服务端无对应分支），属 TDD 红。
  实现后：全部通过。

  .venv/bin/python -m pytest tests/test_stage_j_server.py -v
"""

import os
import sys
import json
import uuid

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from protocol import send_message

LARGE_SIZE = 400 * 1024 * 1024  # 超过大文件直传阈值（默认 300MB）


def _login(harness, username, password):
    c = harness.client()
    c.login(username, password)
    return c


def _make_friends_with(harness, a, b):
    """在数据库层建立 a <-> b 好友关系（绕过协议，供黑名单等场景预置）。"""
    with harness.db._get_connection() as conn:
        conn.execute(
            "INSERT INTO friends (user1, user2, status) VALUES (?, ?, 'accepted')",
            (a, b))
        conn.execute(
            "INSERT INTO friends (user1, user2, status) VALUES (?, ?, 'accepted')",
            (b, a))
        conn.commit()


def _drain_extra_presence(client):
    """消费并返回缓冲中的全部 presence 消息。"""
    presences = []
    while True:
        h, d = client.recv(timeout=0.4)
        if h is None:
            break
        if h.get("type") == "presence":
            presences.append((h.get("from"), h.get("online")))
    return presences


# ============================================================
# J1 —— 用户资料协议
# ============================================================

class TestGetProfile:

    def test_get_profile_own(self, harness):
        """查询自己的资料：profile_response 字段齐全。"""
        alice = _login(harness, "alice", "password123")
        alice.send("get_profile", "", to="alice")
        h, d = alice.expect("profile_response")
        assert h["type"] == "profile_response"
        assert h["to"] == "alice"
        profile = json.loads(d.decode())
        assert profile["username"] == "alice"
        assert profile["nickname"] == ""
        assert profile["avatar"] == ""
        assert profile["signature"] == ""
        assert "last_seen" in profile
        assert "is_admin" in profile

    def test_get_profile_friend_after_set(self, harness):
        """设置资料后好友可见（nickname/avatar/signature 落库）。"""
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        alice.drain()  # 消费 bob 登录触发的 presence 广播

        alice.send("set_profile", "", nickname="爱丽丝", avatar="ava.png",
                   signature="你好世界")
        h, d = alice.expect("profile_response")
        assert json.loads(d.decode())["nickname"] == "爱丽丝"

        bob.send("get_profile", "", to="alice")
        h, d = bob.expect("profile_response")
        profile = json.loads(d.decode())
        assert profile["username"] == "alice"
        assert profile["nickname"] == "爱丽丝"
        assert profile["avatar"] == "ava.png"
        assert profile["signature"] == "你好世界"

    def test_get_profile_nonexistent(self, harness):
        """目标不存在 → error。"""
        alice = _login(harness, "alice", "password123")
        alice.send("get_profile", "", to="ghost")
        h, d = alice.expect("error")
        assert "用户" in d.decode()

    def test_login_updates_last_seen(self, harness):
        """登录成功后 last_seen 非空（J1 附加契约）。"""
        alice = _login(harness, "alice", "password123")
        alice.send("get_profile", "", to="alice")
        h, d = alice.expect("profile_response")
        profile = json.loads(d.decode())
        assert profile["last_seen"], "登录后 last_seen 应被更新为非空"


class TestSetProfile:

    def test_set_profile_partial_update(self, harness):
        """部分更新：仅改昵称，其余字段保留。"""
        alice = _login(harness, "alice", "password123")
        alice.send("set_profile", "", nickname="n1", signature="s1")
        alice.expect("profile_response")
        alice.send("set_profile", "", nickname="n2")
        h, d = alice.expect("profile_response")
        profile = json.loads(d.decode())
        assert profile["nickname"] == "n2"
        assert profile["signature"] == "s1", "未传字段应保持原值"

    def test_set_profile_clear_by_empty(self, harness):
        """空串清除字段。"""
        alice = _login(harness, "alice", "password123")
        alice.send("set_profile", "", nickname="x")
        alice.expect("profile_response")
        alice.send("set_profile", "", nickname="")
        h, d = alice.expect("profile_response")
        assert json.loads(d.decode())["nickname"] == ""

    def test_set_profile_no_fields_error(self, harness):
        """全字段缺失 → error。"""
        alice = _login(harness, "alice", "password123")
        alice.send("set_profile", "")
        h, d = alice.expect("error")
        assert "资料" in d.decode()


# ============================================================
# J2 —— 在线状态 presence 广播
# ============================================================

class TestPresenceBroadcast:

    def test_login_broadcasts_presence_to_others(self, harness):
        """新用户登录：既有在线用户收到 presence online="1"。"""
        alice = _login(harness, "alice", "password123")
        alice.drain()
        bob = harness.client()
        bob.login("bob", "password456", consume=False)
        h, d = alice.expect("presence")
        assert h["type"] == "presence"
        assert h["from"] == "bob"
        assert h["online"] == "1"

    def test_new_login_receives_presence_snapshot(self, harness):
        """新登录者收到当前全部在线用户的 presence 快照。"""
        harness.add_user("carol")
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        bob.drain()
        carol = harness.client()
        result = carol.login("carol", "pass123")
        snapshot = [(h.get("from"), h.get("online")) for h, d in result["extra"]
                    if h.get("type") == "presence"]
        assert set(snapshot) == {("alice", "1"), ("bob", "1")}, \
            f"快照应为 alice+bob 在线，实际: {snapshot}"

    def test_logout_broadcasts_presence_offline(self, harness):
        """用户断开：其余在线用户收到 presence online="0"。"""
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        bob.drain()
        alice.drain()
        bob.close()
        h, d = alice.expect("presence")
        assert h["from"] == "bob"
        assert h["online"] == "0"

    def test_register_broadcasts_presence(self, harness):
        """注册成功同样广播上线。"""
        alice = _login(harness, "alice", "password123")
        alice.drain()
        newbie = harness.client()
        newbie.register("newbie", "pass123", consume=False)
        h, d = alice.expect("presence")
        assert h["from"] == "newbie"
        assert h["online"] == "1"

    def test_no_presence_to_self(self, harness):
        """presence 不广播给自己（快照不含自己）。"""
        alice = _login(harness, "alice", "password123")
        alice2 = harness.client()
        result = alice2.login("alice", "password123")
        snapshot = [h for h, d in result["extra"] if h.get("type") == "presence"]
        assert snapshot == [], f"重复登录不应收到自己的 presence: {snapshot}"

    def test_transfer_login_no_presence(self, harness):
        """传输通道登录（transfer=1）不广播、不发快照。"""
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        bob.drain()
        alice.drain()
        transfer = harness.client()
        transfer.send("login", "alice", password="password123", transfer="1")
        h, d = transfer.recv()
        assert h is not None and h["type"] in ("chat", "admin_auth")
        transfer.drain()
        assert _drain_extra_presence(bob) == [], "传输通道登录不应广播 presence"
        assert _drain_extra_presence(alice) == [], "传输通道登录不应发快照给他人"

    def test_presence_broadcast_skips_blocked(self, harness):
        """黑名单隐藏：A 拉黑 B → B 登录/登出均不对 A 广播，B 快照不含 A。"""
        harness.add_user("carol")
        _make_friends_with(harness, "alice", "carol")
        alice = _login(harness, "alice", "password123")
        carol = _login(harness, "carol", "pass123")
        carol.drain()
        alice.drain()

        # alice 拉黑 carol
        alice.send("block_user", "", to="carol")
        alice.expect("chat")
        alice.drain()
        carol.drain()

        # carol 断开：alice 不应收到 presence
        carol.close()
        assert alice.recv(timeout=0.6) == (None, None), \
            "被拉黑者的登出不应对拉黑者广播"

        # 反向：bob 登录（alice 未拉黑 bob）→ alice 收到
        bob = _login(harness, "bob", "password456")
        bob.drain()
        h, d = alice.expect("presence")
        assert h["from"] == "bob" and h["online"] == "1"

    def test_presence_snapshot_skips_blocked(self, harness):
        """黑名单隐藏：alice 拉黑 bob 后，新登录者 bob 的快照不含 alice。"""
        harness.add_user("carol")
        alice = _login(harness, "alice", "password123")
        alice.drain()
        alice.send("block_user", "", to="bob")
        alice.expect("chat")
        alice.drain()

        bob = harness.client()
        result = bob.login("bob", "password456")
        snapshot = [(h.get("from"), h.get("online")) for h, d in result["extra"]
                    if h.get("type") == "presence"]
        assert snapshot == [], f"被拉黑者的快照不应含拉黑者: {snapshot}"
        assert _drain_extra_presence(alice) == [], \
            "被拉黑者登录不应对拉黑者广播"


# ============================================================
# J3 —— 管理员重置密码
# ============================================================

class TestAdminResetPassword:

    def _admin_login(self, harness):
        admin = harness.client()
        admin.login("admin", "adminpass", admin_secret="test-admin-secret")
        return admin

    def test_reset_password_success(self, harness):
        """管理员重置成功：admin_response + 目标在线收到提示。"""
        alice = _login(harness, "alice", "password123")
        admin = self._admin_login(harness)
        alice.drain()  # 消费 admin 登录触发的 presence 广播
        admin.drain()

        admin.send("admin_command", "alice", action="reset_password",
                   new_password="reset123")
        h, d = admin.expect("admin_response")
        assert h["response_type"] == "reset_password"
        assert "alice" in d.decode()

        h2, d2 = alice.expect("chat")
        assert "重置" in d2.decode()

    def test_reset_password_then_login(self, harness):
        """重置后旧密码失效、新密码可登录。"""
        admin = self._admin_login(harness)
        admin.drain()
        admin.send("admin_command", "alice", action="reset_password",
                   new_password="reset123")
        admin.expect("admin_response")

        old = harness.client()
        old.login("alice", "password123", consume=False)
        h, d = old.recv()
        assert h["type"] == "error", "旧密码登录应失败"

        new = harness.client()
        new.login("alice", "reset123", consume=False)
        h2, d2 = new.recv()
        assert h2["type"] in ("chat", "admin_auth"), "新密码登录应成功"

    def test_reset_password_not_admin(self, harness):
        """非管理员调用 → error 无管理员权限。"""
        alice = _login(harness, "alice", "password123")
        alice.send("admin_command", "bob", action="reset_password",
                   new_password="x12345")
        h, d = alice.expect("error")
        assert "权限" in d.decode()

    def test_reset_password_nonexistent_target(self, harness):
        """目标不存在 → error。"""
        admin = self._admin_login(harness)
        admin.send("admin_command", "ghost", action="reset_password",
                   new_password="x12345")
        h, d = admin.expect("error")
        assert "用户" in d.decode()

    def test_reset_password_invalid_format(self, harness):
        """新密码格式不合法 → error。"""
        admin = self._admin_login(harness)
        admin.send("admin_command", "alice", action="reset_password",
                   new_password="123")
        h, d = admin.expect("error")
        assert "密码" in d.decode()

    def test_reset_password_offline_target(self, harness):
        """目标离线：重置成功，无通知发送（不崩溃）。"""
        admin = self._admin_login(harness)
        admin.drain()
        admin.send("admin_command", "bob", action="reset_password",
                   new_password="reset456")
        h, d = admin.expect("admin_response")
        assert h["response_type"] == "reset_password"

    def test_reset_password_forces_offline_target(self, harness):
        """在线目标被强制下线：旧会话关闭，无法继续收发消息。"""
        alice = _login(harness, "alice", "password123")
        admin = self._admin_login(harness)
        alice.drain()
        admin.drain()

        admin.send("admin_command", "alice", action="reset_password",
                   new_password="reset123")
        h, d = admin.expect("admin_response")
        h2, d2 = alice.expect("chat")
        assert "重置" in d2.decode()

        # 旧会话已被服务端关闭：发送不再可达（连接 EOF）
        try:
            alice.send("chat", "密码被重置后还能发吗", to="bob",
                       message_id=str(uuid.uuid4()))
        except OSError:
            pass
        h3, d3 = alice.recv(timeout=0.6)
        assert h3 is None, "密码重置后旧会话应被强制关闭（连接 EOF）"

    def test_reset_password_broadcasts_offline_presence(self, harness):
        """被强制下线后，其余在线用户收到 presence 下线广播。"""
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        admin = self._admin_login(harness)
        alice.drain()
        bob.drain()
        admin.drain()

        admin.send("admin_command", "alice", action="reset_password",
                   new_password="reset123")
        admin.expect("admin_response")
        alice.expect("chat")
        alice.drain()

        h, d = bob.expect("presence")
        assert h["from"] == "alice" and h["online"] == "0", \
            "密码重置强制下线应广播 presence offline"


# ============================================================
# J4 —— 好友备注 / 分组
# ============================================================

class TestFriendNoteAndGroup:

    def test_set_friend_note(self, harness):
        """设置好友备注 → chat 确认，list_friends_meta 反映。"""
        alice = _login(harness, "alice", "password123")
        alice.drain()
        alice.send("set_friend_note", "", to="bob", note="阿波")
        h, d = alice.expect("chat")
        assert "备注" in d.decode()

        alice.send("list_friends_meta", "")
        h, d = alice.expect("admin_response")
        assert h["response_type"] == "list_friends_meta"
        metas = json.loads(d.decode())
        bob_meta = next(m for m in metas if m["username"] == "bob")
        assert bob_meta["note"] == "阿波"

    def test_set_friend_note_directional(self, harness):
        """备注单向：alice 的备注不影响 bob 视角。"""
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        alice.drain()
        bob.drain()
        alice.send("set_friend_note", "", to="bob", note="阿波")
        alice.expect("chat")

        bob.send("list_friends_meta", "")
        h, d = bob.expect("admin_response")
        metas = json.loads(d.decode())
        alice_meta = next(m for m in metas if m["username"] == "alice")
        assert alice_meta["note"] == ""

    def test_set_friend_note_clear(self, harness):
        """空串备注 = 清除。"""
        alice = _login(harness, "alice", "password123")
        alice.drain()
        alice.send("set_friend_note", "", to="bob", note="临时")
        alice.expect("chat")
        alice.send("set_friend_note", "", to="bob", note="")
        alice.expect("chat")
        alice.send("list_friends_meta", "")
        h, d = alice.expect("admin_response")
        metas = json.loads(d.decode())
        assert next(m for m in metas if m["username"] == "bob")["note"] == ""

    def test_set_friend_note_not_friend(self, harness):
        """非好友设置备注 → error。"""
        alice = _login(harness, "alice", "password123")
        alice.send("set_friend_note", "", to="carol", note="x")
        h, d = alice.expect("error")
        assert "好友" in d.decode()

    def test_set_friend_group(self, harness):
        """设置好友分组 → chat 确认 + list_friends_meta 反映。"""
        alice = _login(harness, "alice", "password123")
        alice.drain()
        alice.send("set_friend_group", "", to="bob", group_name="家人")
        h, d = alice.expect("chat")
        assert "分组" in d.decode()

        alice.send("list_friends_meta", "")
        h, d = alice.expect("admin_response")
        metas = json.loads(d.decode())
        assert next(m for m in metas if m["username"] == "bob")["group_name"] == "家人"

    def test_set_friend_group_clear(self, harness):
        """空串分组 = 移回未分组。"""
        alice = _login(harness, "alice", "password123")
        alice.drain()
        alice.send("set_friend_group", "", to="bob", group_name="同事")
        alice.expect("chat")
        alice.send("set_friend_group", "", to="bob", group_name="")
        alice.expect("chat")
        alice.send("list_friends_meta", "")
        h, d = alice.expect("admin_response")
        metas = json.loads(d.decode())
        assert next(m for m in metas if m["username"] == "bob")["group_name"] == ""

    def test_set_friend_group_not_friend(self, harness):
        """非好友设置分组 → error。"""
        alice = _login(harness, "alice", "password123")
        alice.send("set_friend_group", "", to="carol", group_name="家人")
        h, d = alice.expect("error")
        assert "好友" in d.decode()

    def test_list_friends_meta_empty(self, harness):
        """无好友时 list_friends_meta 返回空数组。"""
        harness.add_user("solo")
        solo = _login(harness, "solo", "pass123")
        solo.send("list_friends_meta", "")
        h, d = solo.expect("admin_response")
        assert h["response_type"] == "list_friends_meta"
        assert json.loads(d.decode()) == []


# ============================================================
# J4 —— 黑名单
# ============================================================

class TestBlockUser:

    def test_block_user_success(self, harness):
        """拉黑成功 → chat 确认，list_blocked 可见。"""
        alice = _login(harness, "alice", "password123")
        alice.drain()
        alice.send("block_user", "", to="bob")
        h, d = alice.expect("chat")
        assert "拉黑" in d.decode()

        alice.send("list_blocked", "")
        h, d = alice.expect("admin_response")
        assert h["response_type"] == "list_blocked"
        assert json.loads(d.decode()) == ["bob"]

    def test_block_user_self(self, harness):
        """拉黑自己 → error。"""
        alice = _login(harness, "alice", "password123")
        alice.send("block_user", "", to="alice")
        h, d = alice.expect("error")
        assert "自己" in d.decode()

    def test_block_user_nonexistent(self, harness):
        """拉黑不存在的用户 → error。"""
        alice = _login(harness, "alice", "password123")
        alice.send("block_user", "", to="ghost")
        h, d = alice.expect("error")
        assert "用户" in d.decode()

    def test_block_duplicate_idempotent(self, harness):
        """重复拉黑幂等成功。"""
        alice = _login(harness, "alice", "password123")
        alice.drain()
        alice.send("block_user", "", to="bob")
        alice.expect("chat")
        alice.send("block_user", "", to="bob")
        h, d = alice.expect("chat")
        assert "拉黑" in d.decode()
        alice.send("list_blocked", "")
        h, d = alice.expect("admin_response")
        assert json.loads(d.decode()) == ["bob"]


class TestUnblockUser:

    def test_unblock_user_success(self, harness):
        """解除拉黑 → chat 确认，list_blocked 移除。"""
        alice = _login(harness, "alice", "password123")
        alice.drain()
        alice.send("block_user", "", to="bob")
        alice.expect("chat")
        alice.send("unblock_user", "", to="bob")
        h, d = alice.expect("chat")
        assert "解除" in d.decode()
        alice.send("list_blocked", "")
        h, d = alice.expect("admin_response")
        assert json.loads(d.decode()) == []

    def test_unblock_not_blocked(self, harness):
        """未拉黑时解除 → error。"""
        alice = _login(harness, "alice", "password123")
        alice.send("unblock_user", "", to="bob")
        h, d = alice.expect("error")
        assert "黑名单" in d.decode()


class TestBlockEnforcement:

    def test_blocked_chat_rejected(self, harness):
        """被拉黑者发送 chat 被拒；拉黑者发送正常（单向）。"""
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        alice.drain()
        bob.drain()
        alice.send("block_user", "", to="bob")
        alice.expect("chat")
        alice.drain()
        bob.drain()

        # bob 发消息给 alice → 拒绝
        bob.send("chat", "你好", to="alice", message_id=str(uuid.uuid4()))
        h, d = bob.expect("error")
        assert "拉黑" in d.decode()

        # alice 发消息给 bob → 正常
        alice.send("chat", "我发没事", to="bob", message_id=str(uuid.uuid4()))
        h2, d2 = bob.expect("chat")
        assert d2.decode() == "我发没事"

    def test_blocked_chat_not_saved_offline(self, harness):
        """被拒 chat 不写入 offline_messages（不落库）。"""
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        alice.drain()
        bob.drain()
        alice.send("block_user", "", to="bob")
        alice.expect("chat")
        alice.drain()
        bob.drain()

        mid = str(uuid.uuid4())
        bob.send("chat", "不该落库", to="alice", message_id=mid)
        bob.expect("error")

        with harness.db._get_connection() as conn:
            cur = conn.cursor()
            cur.execute("SELECT COUNT(*) FROM offline_messages WHERE message_id=?", (mid,))
            assert cur.fetchone()[0] == 0
            cur.execute("SELECT COUNT(*) FROM message_history WHERE message_id=?", (mid,))
            assert cur.fetchone()[0] == 0

    def test_blocked_file_rejected(self, harness):
        """被拉黑者发送小文件被拒。"""
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        alice.drain()
        bob.drain()
        alice.send("block_user", "", to="bob")
        alice.expect("chat")
        alice.drain()
        bob.drain()

        bob.send("file", b"payload", to="alice", filename="a.txt",
                 filesize="7", message_id=str(uuid.uuid4()))
        h, d = bob.expect("error")
        assert "拉黑" in d.decode()

    def test_blocked_large_file_rejected(self, harness):
        """被拉黑者发送大文件直传被拒。"""
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        alice.drain()
        bob.drain()
        alice.send("block_user", "", to="bob")
        alice.expect("chat")
        alice.drain()
        bob.drain()

        bob.send("file", b"", to="alice", filename="big.bin",
                 filesize=str(LARGE_SIZE), message_id=str(uuid.uuid4()))
        h, d = bob.expect("error")
        assert "拉黑" in d.decode()

    def test_blocked_file_check_rejected(self, harness):
        """被拉黑者发起大文件探测被拒。"""
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        alice.drain()
        bob.drain()
        alice.send("block_user", "", to="bob")
        alice.expect("chat")
        alice.drain()
        bob.drain()

        bob.send("file_transfer_check", "", to="alice",
                 filesize=str(LARGE_SIZE), message_id=str(uuid.uuid4()))
        h, d = bob.expect("error")
        assert "拉黑" in d.decode()

    def test_blocked_friend_request_rejected_both_directions(self, harness):
        """任一方向拉黑 → 双向均不可发起好友请求。"""
        harness.add_user("carol")
        alice = _login(harness, "alice", "password123")
        carol = _login(harness, "carol", "pass123")
        alice.drain()
        carol.drain()
        alice.send("block_user", "", to="carol")
        alice.expect("chat")
        alice.drain()
        carol.drain()

        # 被拉黑者请求拉黑者 → 拒绝
        carol.send("friend_request", "", to="alice")
        h, d = carol.expect("error")
        assert "拉黑" in d.decode()

        # 拉黑者请求被拉黑者 → 也拒绝（双向不可请求）
        alice.send("friend_request", "", to="carol")
        h2, d2 = alice.expect("error")
        assert "拉黑" in d2.decode()

    def test_block_does_not_remove_friendship(self, harness):
        """拉黑不删除好友关系（拦截独立于关系）。"""
        alice = _login(harness, "alice", "password123")
        alice.drain()
        alice.send("block_user", "", to="bob")
        alice.expect("chat")
        alice.send("list_friends", "")
        h, d = alice.expect("admin_response")
        assert h["response_type"] == "list_friends"
        assert "bob" in json.loads(d.decode())

    def test_unblock_restores_chat(self, harness):
        """解除拉黑后发送恢复。"""
        alice = _login(harness, "alice", "password123")
        bob = _login(harness, "bob", "password456")
        alice.drain()
        bob.drain()
        alice.send("block_user", "", to="bob")
        alice.expect("chat")
        alice.send("unblock_user", "", to="bob")
        alice.expect("chat")
        alice.drain()
        bob.drain()

        bob.send("chat", "恢复通信", to="alice", message_id=str(uuid.uuid4()))
        h, d = alice.expect("chat")
        assert d.decode() == "恢复通信"


# ============================================================
# J4 —— 好友请求验证消息
# ============================================================

class TestFriendRequestMessage:

    def test_friend_request_with_message_online(self, harness):
        """在线接收方收到带验证消息的 friend_request。"""
        harness.add_user("carol")
        alice = _login(harness, "alice", "password123")
        carol = _login(harness, "carol", "pass123")
        alice.drain()
        carol.drain()

        alice.send("friend_request", "", to="carol", message="我是 alice，来自项目组")
        h, d = carol.expect("friend_request")
        assert h["from"] == "alice"
        assert h.get("message") == "我是 alice，来自项目组"

    def test_friend_request_without_message_online(self, harness):
        """不带验证消息：接收方 friend_request 无 message 头（兼容）。"""
        harness.add_user("carol")
        alice = _login(harness, "alice", "password123")
        carol = _login(harness, "carol", "pass123")
        alice.drain()
        carol.drain()

        alice.send("friend_request", "", to="carol")
        h, d = carol.expect("friend_request")
        assert h["from"] == "alice"
        assert h.get("message") is None or h.get("message") == ""

    def test_friend_request_with_message_offline(self, harness):
        """离线接收方重连后，load_offline_data 推送带验证消息的请求。"""
        harness.add_user("carol")
        alice = _login(harness, "alice", "password123")
        alice.send("friend_request", "", to="carol", message="验证消息X")
        alice.expect("chat")  # "好友请求已发送给 carol"

        carol = harness.client()
        result = carol.login("carol", "pass123")
        fr = [h for h, d in result["friend_requests"]]
        assert len(fr) == 1, f"应有 1 条离线好友请求: {fr}"
        assert fr[0].get("from") == "alice"
        assert fr[0].get("message") == "验证消息X"

    def test_friend_request_message_survives_accept(self, harness):
        """验证消息随请求落库（接受后仍可查，供资料页展示）。"""
        harness.add_user("carol")
        alice = _login(harness, "alice", "password123")
        alice.send("friend_request", "", to="carol", message="备注我一下")
        alice.expect("chat")

        carol = harness.client()
        result = carol.login("carol", "pass123")
        # 注意：accept_friend 的 from 头用 send_message 直发（from 为 Python 关键字）
        send_message(carol._sock, "accept_friend", "",
                     extra_headers={"from": "alice"})
        carol.expect("chat")

        with harness.db._get_connection() as conn:
            cur = conn.cursor()
            cur.execute(
                "SELECT request_message FROM friends WHERE user1=? AND user2=?",
                ("alice", "carol"))
            row = cur.fetchone()
            assert row is not None and row[0] == "备注我一下"


# ============================================================
# J4 —— 用户搜索
# ============================================================

class TestSearchUsers:

    def test_search_users_excludes_self(self, harness):
        """搜索结果排除自己。"""
        harness.add_user("alice2")
        alice = _login(harness, "alice", "password123")
        alice.send("search_users", "", keyword="alice")
        h, d = alice.expect("user_search_response")
        results = json.loads(d.decode())
        assert "alice" not in results, f"结果不应含自己: {results}"
        assert "alice2" in results

    def test_search_users_partial(self, harness):
        """部分匹配返回全部命中。"""
        harness.add_user("bob2")
        alice = _login(harness, "alice", "password123")
        alice.send("search_users", "", keyword="bob")
        h, d = alice.expect("user_search_response")
        results = json.loads(d.decode())
        assert set(results) == {"bob", "bob2"}

    def test_search_users_no_match(self, harness):
        """无匹配 → 空数组。"""
        alice = _login(harness, "alice", "password123")
        alice.send("search_users", "", keyword="xyzzy")
        h, d = alice.expect("user_search_response")
        assert json.loads(d.decode()) == []

    def test_search_users_empty_keyword(self, harness):
        """空关键字 → error。"""
        alice = _login(harness, "alice", "password123")
        alice.send("search_users", "", keyword="")
        h, d = alice.expect("error")
        assert "关键字" in d.decode()
