"""
============================================================
阶段 N —— 日常使用便利性：服务端协议层 TDD 契约测试（规划中，全部红）
============================================================

【目标】
  按《软件开发文档4.1.0.md》§13.9 阶段 N 编写服务端协议契约测试：

    N6（P2-6 登录设备管理）： list_sessions / kick_session
    N7（P2-7 审计日志）：     admin_command action=audit_log +
                              敏感操作（删除用户/重置密码/发公告/群组治理）
                              成功时自动落库审计

【契约（实现方需严格遵守，本测试即据此验证）】
  ----- N6 登录设备管理 -----
  C → S: type="list_sessions"（无需消息体）
  S → C: type="sessions_response", body=JSON
         [{"device_id": "linux", "last_active": 1724690000.0,
           "is_current": true}, ...]
     - 仅返回**自己**账号的全部在线会话（无需权限校验，普通用户可用）
     - last_active：会话最后活动时间（epoch 秒，float，来自
       Server.session_activity；无记录时取当前时间）
     - 排序：**当前会话在前**，其余按 device_id 升序（确定性输出）
     - 多会话并存语义沿用阶段 L：device_id 即平台类别
       （linux/android/ios/windows/macos/default），同类新登录互踢、异类并存

  C → S: type="kick_session", header {device_id}
  S → C 操作者: type="chat" (from=系统) 确认含 "已下线设备 {device_id}"
  S → C 被下线者(在线): type="error" 内容 "您已被其他设备远程下线"，
      随后会话被关闭（shutdown，由线程 finally 清理映射；复用
      _kick_old_session 的"只 shutdown 不 close"P-07 约定）
    失败: 下线当前设备 → error 含 "不能下线当前设备"；
          设备不在线 → error 含 "不在线"
    语义: 被下线者若是该用户名**最后一个会话** → presence 广播离线；
          仍有其他会话在线 → 不广播（阶段 L presence 按用户名聚合）
    落库: 无（会话映射移除即可）

  ----- N7 审计日志 -----
  表: audit_logs（见 test_stage_n_db.py）
  敏感操作**成功**后由服务端调用 Database.record_audit_log 自动落库：
    delete_user     → (operator=管理员, action="delete_user", target=被删用户名)
    reset_password  → (operator=管理员, action="reset_password", target=被重置用户名)
    announcement    → (operator=管理员, action="announcement",
                       target="全体用户", detail=公告内容)
    kick_member     → (operator=操作者, action="kick_member", target=被踢用户名,
                       detail=群组名)
    transfer_owner  → (operator=操作者, action="transfer_owner", target=新群主,
                       detail=群组名)
    rename_group    → (operator=操作者, action="rename_group", target=新群名,
                       detail=旧群名)
  失败操作不记录（删除自己/无效密码/非群主踢人等）。

  C → S: type="admin_command", header {action="audit_log", limit?}
  S → C: type="admin_response", header {response_type="audit_log"},
         body=JSON [{id, operator, action, target, detail, timestamp}, ...]
     - 最新在前；limit 可选（默认 100）
     - 非管理员 → error "无管理员权限"
     - 实现注意：新协议分支（list_sessions / kick_session）加入
       process_messages 主链；audit 记录调用点在既有成功分支内（admin /
       group handler），不得新增重复分支（阶段 M 维护注意：handle_group_message
       存在两条 if/elif 链，勿与旧分支重名）

【运行】
  实现前：本文件用例全部红，属 TDD 红。实现后：全部通过。

  .venv/bin/python -m pytest tests/test_stage_n_server.py -v
"""

import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

TEST_ADMIN_SECRET = "test-admin-secret"


def _login(harness, username, password, admin_secret=None, device_id=None,
           consume=True):
    c = harness.client()
    c.login(username, password, admin_secret=admin_secret,
            device_id=device_id, consume=consume)
    return c


def _alice(harness, device_id=None):
    return _login(harness, "alice", "password123", device_id=device_id)


def _bob(harness, device_id=None):
    return _login(harness, "bob", "password456", device_id=device_id)


def _admin(harness):
    return _login(harness, "admin", "adminpass", admin_secret=TEST_ADMIN_SECRET)


def _group_setup(harness, name="开发组", with_bob=True):
    """alice 建群 + bob 入群，返回 (alice, bob, gid)。"""
    alice = _alice(harness)
    if not harness.db.user_exists("bob"):
        harness.add_user("bob", "password456")
    if not harness.db.user_exists("carol"):
        harness.add_user("carol", "password789")
    gid = harness.db.create_group(name, "alice")
    if with_bob:
        harness.db.join_group(gid, "bob")
    bob = _bob(harness)
    bob.drain(timeout=0.5)
    return alice, bob, gid


def _sessions(harness, client):
    """发 list_sessions 并解析响应，返回会话列表。"""
    client.send("list_sessions", "")
    h, d = client.expect("sessions_response", timeout=3)
    return json.loads(d.decode())


# ============================================================
# N6 —— 登录设备管理：list_sessions
# ============================================================

class TestListSessionsProtocol:

    def test_list_sessions_single_device(self, harness):
        """单设备登录 → 返回 1 个会话且为当前会话。"""
        alice = _alice(harness, device_id="linux")
        sessions = _sessions(harness, alice)
        assert len(sessions) == 1
        s = sessions[0]
        assert s["device_id"] == "linux"
        assert s["is_current"] is True

    def test_list_sessions_multi_device_order(self, harness):
        """双设备登录 → 当前会话在前，其余按 device_id 升序。"""
        dev1 = _alice(harness, device_id="android")
        dev2 = _alice(harness, device_id="linux")
        sessions = _sessions(harness, dev1)
        assert [s["device_id"] for s in sessions] == ["android", "linux"], \
            f"当前会话应在前: {sessions}"

    def test_list_sessions_current_flag_follows_requester(self, harness):
        """当前标记跟随请求方（从 android 查询时 android 为当前）。"""
        _alice(harness, device_id="android")
        linux = _alice(harness, device_id="linux")
        sessions = _sessions(harness, linux)
        current = [s for s in sessions if s["is_current"]]
        assert len(current) == 1 and current[0]["device_id"] == "linux"

    def test_list_sessions_last_active_present(self, harness):
        """last_active 为 epoch 秒且大于 0。"""
        alice = _alice(harness, device_id="linux")
        time.sleep(0.05)
        sessions = _sessions(harness, alice)
        assert isinstance(sessions[0]["last_active"], (int, float))
        assert sessions[0]["last_active"] > 0

    def test_list_sessions_default_device(self, harness):
        """旧客户端（无 device_id 头）→ 设备 id 为 default。"""
        alice = _alice(harness)
        sessions = _sessions(harness, alice)
        assert sessions[0]["device_id"] == "default"

    def test_list_sessions_only_own_sessions(self, harness):
        """只返回自己的会话，不含其他用户。"""
        alice_linux = _alice(harness, device_id="linux")
        alice_android = _alice(harness, device_id="android")
        _bob(harness)
        sessions = _sessions(harness, alice_linux)
        assert sorted(s["device_id"] for s in sessions) == ["android", "linux"]
        sessions_bob = _sessions(harness, alice_android)
        assert len(sessions_bob) == 2  # bob 的会话不出现在 alice 列表中


# ============================================================
# N6 —— 登录设备管理：kick_session
# ============================================================

class TestKickSessionProtocol:

    def test_kick_other_device_success(self, harness):
        """远程下线另一设备 → 操作者确认 + 被下线者收到通知并断连。"""
        alice_linux = _alice(harness, device_id="linux")
        alice_android = _alice(harness, device_id="android")
        alice_linux.drain(timeout=0.5)

        alice_linux.send("kick_session", "", device_id="android")
        h, d = alice_linux.expect("chat", timeout=3)
        assert "已下线设备 android" in d.decode(), f"操作者确认: {d.decode()}"

        h, d = alice_android.expect("error", timeout=3)
        assert "您已被其他设备远程下线" in d.decode(), f"被下线者通知: {d.decode()}"
        # 会话被关闭：再读返回 None（连接已断）
        h, d = alice_android.recv(timeout=3)
        assert h is None, f"被下线会话应关闭: {h}"

    def test_kicked_session_removed_from_list(self, harness):
        """下线后 list_sessions 不再包含该设备。

        被下线会话由线程 finally 异步清理映射，负载下可能晚于确认消息
        到达——轮询重查直到列表收敛（上限 5s）。
        """
        alice_linux = _alice(harness, device_id="linux")
        alice_android = _alice(harness, device_id="android")
        alice_linux.drain(timeout=0.5)

        alice_linux.send("kick_session", "", device_id="android")
        alice_linux.expect("chat", timeout=3)
        alice_android.drain(timeout=0.5)

        devices = None
        deadline = time.time() + 5
        while time.time() < deadline:
            sessions = _sessions(harness, alice_linux)
            devices = [s["device_id"] for s in sessions]
            if devices == ["linux"]:
                break
            time.sleep(0.2)
        assert devices == ["linux"], f"下线后应只剩 linux: {devices}"

    def test_kick_other_device_cannot_send_chat_after(self, harness):
        """被下线设备无法再发送消息（连接已关闭：发送失败或读端关闭）。"""
        alice_linux = _alice(harness, device_id="linux")
        alice_android = _alice(harness, device_id="android")
        bob = _bob(harness)
        alice_linux.drain(timeout=0.5)
        bob.drain(timeout=0.5)

        alice_linux.send("kick_session", "", device_id="android")
        alice_linux.expect("chat", timeout=3)
        alice_android.drain(timeout=0.5)

        # 会话已被服务端 shutdown：发送抛 BrokenPipeError（写失败）
        # 或读端立即返回 None（读失败）——二者均证明连接已失效
        send_failed = False
        try:
            alice_android.send("chat", "还能发吗", to="bob",
                               message_id="n-kick-1")
        except (BrokenPipeError, OSError):
            send_failed = True
        h, d = alice_android.recv(timeout=3)
        assert send_failed or h is None, \
            f"被下线会话发送应失败（连接已关闭）: {h}"

    def test_kick_current_device_rejected(self, harness):
        """下线当前设备 → error 含 '不能下线当前设备'。"""
        alice = _alice(harness, device_id="linux")
        alice.send("kick_session", "", device_id="linux")
        h, d = alice.expect("error", timeout=3)
        assert "不能下线当前设备" in d.decode(), f"拒绝理由: {d.decode()}"
        # 会话保持存活
        sessions = _sessions(harness, alice)
        assert len(sessions) == 1

    def test_kick_offline_device_rejected(self, harness):
        """下线不在线设备 → error 含 '不在线'。"""
        alice = _alice(harness, device_id="linux")
        alice.send("kick_session", "", device_id="windows")
        h, d = alice.expect("error", timeout=3)
        assert "不在线" in d.decode(), f"拒绝理由: {d.decode()}"

    def test_kick_keeps_presence_online_when_other_session_remains(self, harness):
        """下线一设备但仍有其他会话 → 不广播 presence 离线。"""
        alice_linux = _alice(harness, device_id="linux")
        alice_android = _alice(harness, device_id="android")
        bob = _bob(harness)
        alice_linux.drain(timeout=0.5)
        bob.drain(timeout=0.5)

        alice_linux.send("kick_session", "", device_id="android")
        alice_linux.expect("chat", timeout=3)
        alice_android.drain(timeout=0.5)

        # bob 侧不应收到 alice 离线广播
        h, d = bob.recv(timeout=0.6)
        assert h is None, f"bob 不应收到任何消息（alice 仍有会话在线）: {h}"

    def test_kick_other_session_then_disconnect_broadcasts_presence_offline(self, harness):
        """踢出非最后会话不广播离线；请求方（唯一剩余会话）断开才广播离线。

        注：kick_session 拒绝下线请求方当前设备，故"踢到零会话"不可达；
        此场景验证被踢会话清理正确——alice 的在线状态由剩余会话决定，
        最后一个会话下线（此处为请求方主动断开）才广播 presence 离线。
        """
        alice_linux = _alice(harness, device_id="linux")
        alice_android = _alice(harness, device_id="android")
        bob = _bob(harness)
        alice_linux.drain(timeout=0.5)
        bob.drain(timeout=0.5)

        # 先下线 android：alice 仍有 linux 会话在线 → 不广播离线
        alice_linux.send("kick_session", "", device_id="android")
        alice_linux.expect("chat", timeout=3)
        alice_android.drain(timeout=0.5)
        h, d = bob.recv(timeout=0.6)
        assert h is None, f"踢出非最后会话不应广播离线: {h}"

        # 请求方（唯一剩余会话）断开 → presence 广播离线
        alice_linux.close()
        time.sleep(0.5)
        h, d = bob.expect("presence", timeout=3)
        assert h.get("from") == "alice" and h.get("online") == "0", \
            f"应广播 alice 离线: {h}"

    def test_kick_again_reports_offline(self, harness):
        """重复下线已下线设备 → error 含 '不在线'。"""
        alice_linux = _alice(harness, device_id="linux")
        alice_android = _alice(harness, device_id="android")
        alice_linux.drain(timeout=0.5)

        alice_linux.send("kick_session", "", device_id="android")
        alice_linux.expect("chat", timeout=3)
        alice_android.drain(timeout=0.5)

        alice_linux.send("kick_session", "", device_id="android")
        h, d = alice_linux.expect("error", timeout=3)
        assert "不在线" in d.decode(), f"重复下线应报不在线: {d.decode()}"


# ============================================================
# N7 —— 审计日志：查询协议
# ============================================================

class TestAuditLogProtocol:

    def test_audit_log_requires_admin(self, harness):
        """非管理员查询 → error 无管理员权限。"""
        alice = _alice(harness)
        alice.send("admin_command", "", action="audit_log")
        h, d = alice.expect("error", timeout=3)
        assert "无管理员权限" in d.decode(), f"拒绝理由: {d.decode()}"

    def test_audit_log_empty_returns_empty_list(self, harness):
        """无记录时返回空数组。"""
        admin = _admin(harness)
        admin.send("admin_command", "", action="audit_log")
        h, d = admin.expect("admin_response", timeout=3)
        assert h.get("response_type") == "audit_log"
        assert json.loads(d.decode()) == []

    def test_audit_log_response_format(self, harness):
        """响应项含 id/operator/action/target/detail/timestamp。"""
        harness.db.record_audit_log("admin", "delete_user", "bob")
        admin = _admin(harness)
        admin.send("admin_command", "", action="audit_log")
        h, d = admin.expect("admin_response", timeout=3)
        entry = json.loads(d.decode())[0]
        assert set(entry.keys()) == {"id", "operator", "action", "target",
                                     "detail", "timestamp"}, \
            f"字段不齐: {entry.keys()}"


# ============================================================
# N7 —— 审计日志：敏感操作自动落库
# ============================================================

class TestAuditLogRecording:

    def test_delete_user_records_audit(self, harness):
        """删除用户成功 → 记录 (admin, delete_user, 被删用户名)。"""
        harness.add_user("carol", "password789")
        admin = _admin(harness)
        admin.send("admin_command", "carol", action="delete_user")
        h, d = admin.expect("admin_response", timeout=3)
        assert h.get("response_type") == "list_users"
        assert "删除用户 carol 成功" in h.get("action_result", ""), \
            f"删除确认在 action_result 头: {h}"

        logs = harness.db.get_audit_logs()
        assert any(e["operator"] == "admin" and e["action"] == "delete_user"
                   and e["target"] == "carol" for e in logs), \
            f"应记录删除用户: {logs}"

    def test_delete_self_not_recorded(self, harness):
        """删除自己失败 → 不记录审计。"""
        admin = _admin(harness)
        admin.send("admin_command", "admin", action="delete_user")
        h, d = admin.expect("error", timeout=3)
        assert "不能删除当前登录的管理员账号" in d.decode()
        assert harness.db.get_audit_logs() == []

    def test_delete_nonexistent_user_not_recorded(self, harness):
        """删除不存在用户失败 → 不记录审计。"""
        admin = _admin(harness)
        admin.send("admin_command", "ghost", action="delete_user")
        h, d = admin.expect("error", timeout=3)
        assert "失败" in d.decode()
        assert harness.db.get_audit_logs() == []

    def test_reset_password_records_audit(self, harness):
        """重置密码成功 → 记录 (admin, reset_password, 目标)。"""
        admin = _admin(harness)
        admin.send("admin_command", "bob", action="reset_password",
                   new_password="newpass456")
        h, d = admin.expect("admin_response", timeout=3)
        assert "已将用户 bob 的密码重置" in d.decode()

        logs = harness.db.get_audit_logs()
        assert any(e["operator"] == "admin" and e["action"] == "reset_password"
                   and e["target"] == "bob" for e in logs), \
            f"应记录重置密码: {logs}"

    def test_reset_password_invalid_not_recorded(self, harness):
        """新密码不合法（失败）→ 不记录审计。"""
        admin = _admin(harness)
        admin.send("admin_command", "bob", action="reset_password",
                   new_password="1")
        h, d = admin.expect("error", timeout=3)
        assert "密码" in d.decode()
        assert harness.db.get_audit_logs() == []

    def test_announcement_records_audit(self, harness):
        """发送公告成功 → 记录 (admin, announcement, 全体用户, 公告内容)。"""
        _bob(harness)  # 在线用户（公告广播路径）
        admin = _admin(harness)
        admin.drain(timeout=0.5)
        admin.send("admin_command", "系统将于今晚 22:00 维护",
                   action="announcement")
        # 公告广播含管理员自己的会话：先收到公告本体，再收到发送成功确认
        h, d = admin.expect("chat", timeout=3)
        assert "系统将于今晚 22:00 维护" in d.decode(), f"公告本体: {d.decode()}"
        h, d = admin.expect("chat", timeout=3)
        assert "公告发送成功" in d.decode()

        logs = harness.db.get_audit_logs()
        assert any(e["operator"] == "admin" and e["action"] == "announcement"
                   and e["target"] == "全体用户"
                   and e["detail"] == "系统将于今晚 22:00 维护"
                   for e in logs), f"应记录公告: {logs}"

    def test_kick_member_records_audit(self, harness):
        """群主踢人成功 → 记录 (操作者, kick_member, 被踢者, 群组名)。"""
        alice, bob, gid = _group_setup(harness, name="开发组")
        alice.send("kick_member", "", group_id=str(gid), target="bob")
        alice.expect("chat", timeout=3)
        bob.drain(timeout=0.5)

        logs = harness.db.get_audit_logs()
        assert any(e["operator"] == "alice" and e["action"] == "kick_member"
                   and e["target"] == "bob" and e["detail"] == "开发组"
                   for e in logs), f"应记录踢人: {logs}"

    def test_kick_member_failed_not_recorded(self, harness):
        """非群主踢人失败 → 不记录审计。"""
        alice, bob, gid = _group_setup(harness)
        harness.db.join_group(gid, "carol")
        carol = _login(harness, "carol", "password789")
        carol.drain(timeout=0.5)

        carol.send("kick_member", "", group_id=str(gid), target="bob")
        h, d = carol.expect("error", timeout=3)
        assert "群主" in d.decode()
        assert harness.db.get_audit_logs() == []

    def test_transfer_owner_records_audit(self, harness):
        """转让群主成功 → 记录 (操作者, transfer_owner, 新群主, 群组名)。"""
        alice, bob, gid = _group_setup(harness, name="开发组")
        alice.send("transfer_owner", "", group_id=str(gid), target="bob")
        alice.expect("chat", timeout=3)
        bob.drain(timeout=0.5)

        logs = harness.db.get_audit_logs()
        assert any(e["operator"] == "alice" and e["action"] == "transfer_owner"
                   and e["target"] == "bob" and e["detail"] == "开发组"
                   for e in logs), f"应记录转让: {logs}"

    def test_rename_group_records_audit(self, harness):
        """改名成功 → 记录 (操作者, rename_group, 新群名, 旧群名)。"""
        alice, bob, gid = _group_setup(harness, name="旧名组")
        alice.send("rename_group", "", group_id=str(gid), name="新名组")
        alice.expect("chat", timeout=3)
        bob.drain(timeout=0.5)

        logs = harness.db.get_audit_logs()
        assert any(e["operator"] == "alice" and e["action"] == "rename_group"
                   and e["target"] == "新名组" and e["detail"] == "旧名组"
                   for e in logs), f"应记录改名: {logs}"

    def test_rename_group_failed_not_recorded(self, harness):
        """重名/空名改名失败 → 不记录审计。"""
        alice, bob, gid = _group_setup(harness, name="组A")
        harness.db.create_group("组B", "alice")
        alice.send("rename_group", "", group_id=str(gid), name="组B")
        h, d = alice.expect("error", timeout=3)
        assert "已存在" in d.decode()
        assert harness.db.get_audit_logs() == []

    def test_audit_log_limit_and_order(self, harness):
        """查询支持 limit 且最新在前。"""
        for i in range(4):
            harness.db.record_audit_log("admin", "delete_user", f"u{i}")
        admin = _admin(harness)
        admin.send("admin_command", "", action="audit_log", limit="2")
        h, d = admin.expect("admin_response", timeout=3)
        entries = json.loads(d.decode())
        assert len(entries) == 2
        assert [e["target"] for e in entries] == ["u3", "u2"], \
            f"应最新在前: {entries}"

    def test_audit_log_persists_across_relogin(self, harness):
        """审计记录落库持久化，重登后仍可查。"""
        harness.db.record_audit_log("admin", "delete_user", "bob")
        admin1 = _admin(harness)
        admin1.close()
        time.sleep(0.3)
        admin2 = _admin(harness)
        admin2.send("admin_command", "", action="audit_log")
        h, d = admin2.expect("admin_response", timeout=3)
        entries = json.loads(d.decode())
        assert len(entries) == 1 and entries[0]["target"] == "bob"


class TestGroupFileRoutingN3b:
    """N3b 修复（2026-08-29 用户实测）：群文件必须按 group_id 路由。

    问题 3：alice 在群组中发送图片，图片出现在与 bob 的私聊中——
    根因：群文件接受推送与离线补发的 file 消息头缺 group_id，接收方
    无法区分群文件与私聊文件。
    """

    def test_group_file_push_carries_group_id(self, harness):
        """群文件接受推送携带 group_id 头（接收方据此路由到群聊）。"""
        alice = _alice(harness)
        bob = _bob(harness)
        gid = harness.db.create_group("开发组", "alice")
        harness.db.join_group(gid, "bob")
        bob.drain(timeout=0.5)

        payload = b"group image bytes"
        alice.send("file", payload, to=f"group_{gid}", filename="photo.png",
                   filesize=str(len(payload)), message_id="n3b-grp-1")
        h, d = bob.expect("group_file_request", timeout=3)
        assert h.get("group_id") == str(gid)

        bob.send("group_file_response", "", message_id="n3b-grp-1",
                 response="accept", group_id=str(gid))
        h, d = bob.expect("file", timeout=3)
        assert h.get("group_id") == str(gid), \
            f"群文件接受推送必须携带 group_id: {h}"
        assert h.get("from") == "alice"
        assert d == payload

    def test_group_file_offline_repush_carries_group_id(self, harness):
        """群文件离线补发携带 group_id 头（重登后仍路由到群聊）。"""
        alice = _alice(harness)
        bob = _bob(harness)
        gid = harness.db.create_group("开发组", "alice")
        harness.db.join_group(gid, "bob")
        bob.drain(timeout=0.5)

        payload = b"offline group file"
        alice.send("file", payload, to=f"group_{gid}", filename="pic.gif",
                   filesize=str(len(payload)), message_id="n3b-grp-2")
        h, d = bob.expect("group_file_request", timeout=3)
        bob.send("group_file_response", "", message_id="n3b-grp-2",
                 response="accept", group_id=str(gid))
        h, d = bob.expect("file", timeout=3)
        assert h.get("group_id") == str(gid)
        # 落库断言：离线行带 group_id（平行查询可还原）
        gmap = harness.db.get_offline_group_ids(["n3b-grp-2"])
        assert gmap.get("n3b-grp-2") == gid, \
            f"offline_messages 应记录群文件 group_id: {gmap}"

        # bob 重登：离线补发的 file 消息应带 group_id 头
        bob.close()
        time.sleep(0.3)
        bob2 = _login(harness, "bob", "password456", consume=False)
        initial = bob2.recv_initial()
        seen = [h for h, d in initial.get("offline", []) if h.get("type") == "file"]
        assert any(h.get("group_id") == str(gid) for h in seen), \
            f"离线补发的群文件必须携带 group_id: {seen}"
