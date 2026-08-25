"""
============================================================
阶段 M —— 群组治理 + 运维：服务端协议层 TDD 契约测试（规划中，全部红）
============================================================

【目标】
  按《软件开发文档4.1.0.md》§11 阶段 M / §13.3 编写服务端协议契约测试：

    M1（P1-16 群主权限）：  kick_member / transfer_owner / rename_group /
                            set_group_avatar（list_groups 推送扩展）
    M2（P1-17 入群审批/邀请）：request_join_group / approve_join_request /
                            reject_join_request / invite_group_member /
                            accept_group_invite / decline_group_invite
    M3（P1-18 历史可见性）： set_group_history_visible + fetch_history
                            群分支按成员 joined_at 过滤
    M4（P1-19 状态面板）：   admin_command action=server_status /
                            action=storage_cleanup + Server 统计/磁盘/日志
    M6（P1-21 存储治理）：   run_storage_cleanup / check_disk_usage
    M8（P1-5/6/7 文件增强）：file 消息 sha256 校验与透传 / 上传续传 offset /
                            file_resume 下载续传 / list_files 文件列表

【契约（实现方需严格遵守，本测试即据此验证）】
  ----- M1 群主权限 -----
  C → S: type="kick_member", header {group_id, target}
  S → C 操作者: type="chat" 确认含 "已将 {target} 移出群组"
  S → C 被踢者(在线): type="chat" (from=系统) 含 "您已被群主移出群组"；
     被踢者(离线): save_offline_message，下次登录可见
  S → C 其余成员: type="chat" (from=系统) 含 "{target} 已被移出群组"
  S → C 被踢者: type="list_groups"（刷新后列表不含该群）
    失败: 非群主 → error 含 "群主"；踢群主 → error 含 "群主"；
         踢自己 → error 含 "自己"；目标非成员 → error 含 "不在群组"；
         群不存在 → error 含 "不存在"
    落库: group_members 删除 target 行；被踢者不能再发 group_chat

  C → S: type="transfer_owner", header {group_id, target}
  S → C 操作者: type="chat" 确认含 "已将群主转让给 {target}"
  S → C 新群主(在线): type="chat" (from=系统) 含 "已成为群组"；
     新群主(离线): save_offline_message
  S → C 其余成员: type="chat" (from=系统) 含 "群主已变更为 {target}"
  S → C 全体成员: type="list_groups" 刷新（created_by=新群主，客户端据此
     更新群主标识）
    失败: 非群主 → error 含 "群主"；目标非成员 → error 含 "不在群组"；
         转让给自己 → error 含 "自己"
    落库: groups.created_by = target（旧群主失去管理权限）

  C → S: type="rename_group", header {group_id, name}
  S → C 操作者: type="chat" 确认含 "已改名为" + list_groups 刷新
  S → C 其余成员: type="chat" (from=系统) 含 "已改名为" + list_groups 刷新
    失败: 非群主 → error 含 "群主"；空名 → error 含 "不能为空"；
         重名 → error 含 "已存在"

  （2026-08-25 用户决策：头像功能已废除——个人与群聊均不支持自定义
  头像；set_group_avatar 协议/avatar 列保留但客户端不再提供入口，
  相关测试已删除）

  list_groups 推送扩展（登录初始数据/刷新）:
    [{"id", "group_name", "created_by"}, ...]（向后兼容新增 created_by）

  ----- M2 入群审批 -----
  C → S: type="join_group", body=群组ID（**2026-08-25 用户决策修订：与
         request_join_group 同为申请制**——输入群组 ID 加入必须经群主审批，
         不再直接加入；旧客户端消息类型向后兼容复用同一审批流）
  C → S: type="request_join_group", body=群组ID
  S → C 申请者: type="chat" 确认含 "已发送入群申请"
  S → C 群主(在线): type="chat" (from=系统) 含 "请求加入群组"；
     群主(离线): save_offline_message
    失败: 群不存在 → error 含 "不存在"；已是成员 → error 含 "已在群组"；
         重复申请 → error 含 "已发送"
    落库: group_join_requests 行（申请不直接入群）

  C → S: type="list_join_requests", header {group_id}
  S → C: type="admin_response", header {response_type="list_join_requests"},
         body=JSON [username, ...]（待审批申请列表）
    失败: 群不存在 → error 含 "不存在"；非群主 → error 含 "群主"

  C → S: type="search_groups", header {keyword}
  S → C: type="group_search_response", body=JSON
         [{id, group_name, created_by, avatar, member_count}, ...]
      - 按群名 LIKE 模糊搜索；排除自己已加入的群
      - 空关键字 → error 含 "关键字"

  C → S: type="approve_join_request", header {group_id, target}
  S → C 群主: type="chat" 确认含 "已批准 {target} 加入群组"
  S → C 被批准者(在线): type="chat" (from=系统) 含 "您已加入群组" +
     list_groups 刷新；被批准者(离线): save_offline_message
  S → C 其余成员: type="chat" (from=系统) 含 "{target} 已加入群组"
    失败: 非群主 → error 含 "群主"；无申请 → error 含 "没有来自"
    落库: 申请行删除 + 成员加入

  C → S: type="reject_join_request", header {group_id, target}
  S → C 群主: type="chat" 确认含 "已拒绝"
  S → C 被拒者(在线): type="chat" (from=系统) 含 "已被拒绝"；
     被拒者(离线): save_offline_message
    失败: 非群主 → error 含 "群主"；无申请 → error 含 "没有来自"
    落库: 申请行删除

  ----- M2 邀请制 -----
  C → S: type="invite_group_member", header {group_id, target}
  S → C 邀请者: type="chat" 确认含 "已邀请 {target} 加入群组"
  S → C 被邀请者(在线): type="group_invite", header {from, group_id,
     group_name}；被邀请者(离线): save_offline_message chat 含 "邀请您加入"
    失败: 非成员 → error 含 "不在此群组"；目标已是成员 → error 含 "已在群组"；
         重复邀请 → error 含 "已发送"；目标不存在 → error 含 "不存在"
    落库: group_invitations 行

  C → S: type="accept_group_invite", header {group_id}
  S → C: type="chat" 确认含 "已加入群组" + list_groups 刷新
  S → C 其余成员: type="chat" (from=系统) 含 "已加入群组"
    失败: 无邀请 → error 含 "没有来自"
    落库: 邀请行删除 + 成员加入

  C → S: type="decline_group_invite", header {group_id}
  S → C: type="chat" 确认含 "已拒绝邀请"
    失败: 无邀请 → error 含 "没有来自"
    落库: 邀请行删除

  ----- M3 新成员历史可见性 -----
  C → S: type="set_group_history_visible", header {group_id, visible, limit}
  S → C 群主: type="chat" 确认含 "历史可见性"
    失败: 非群主 → error 含 "群主"
    落库: groups.history_visible / history_limit

  fetch_history 群分支（M3 扩展）:
    - 取成员 group_members.joined_at 与群组 history_visible/history_limit
    - visible=1（默认）: 可见范围 = 加入前最近 history_limit 条 ∪ 加入后全部
    - visible=0: 可见范围 = 仅自己加入之后的消息
    新成员请求历史即按此过滤（老成员因 joined_at 早，等效全部可见）

  ----- M4 服务端状态面板 -----
  C → S: type="admin_command", header {action="server_status"}
  S → C: type="admin_response", header {response_type="server_status"},
         body=JSON {"online_users", "online_sessions", "total_users",
         "total_messages", "pending_file_requests", "storage":
         {"file_store_bytes","file_count","db_bytes"}, "disk":
         {"disk_free","disk_total","warn"}, "recent_logs": [...]}
    失败: 非管理员 → error 含 "无管理员权限"

  C → S: type="admin_command", header {action="storage_cleanup",
         days_file?, days_delivered?}
  S → C: type="admin_response", header {response_type="storage_cleanup"},
         body=JSON {"expired_file_requests": N, "expired_delivered_messages": N}
    失败: 非管理员 → error 含 "无管理员权限"

  Server 方法（供状态面板/定时任务调用）:
    Server.get_server_status() -> dict（组装在线/存储/磁盘/日志）
    Server.check_disk_usage(disk_free=None, disk_total=None)
      -> {"disk_free","disk_total","warn"}
      warn = 剩余比例 < config storage.disk_warning_percent（默认 10）
    Server.run_storage_cleanup(days_file=7, days_delivered=30)
      -> {"expired_file_requests", "expired_delivered_messages"}
    Server.recent_logs: 构造时挂 logging.Handler 的环形缓冲（maxlen=200）

  ----- M6 存储治理 -----
  run_storage_cleanup 调用 cleanup_expired_file_requests（既有，默认 7 天）
  + cleanup_expired_delivered_messages（新增，默认 30 天，9.3 契约）
  + 清理 file_request_resolutions（既有 cleanup_expired_file_requests 已含）

  ----- M8 文件增强 -----
  file 消息头 sha256（P1-5）:
    - 发送方 header 携带 sha256=<hex>（可选）
    - 小文件：服务器收完计算实际 SHA-256，与头不匹配 →
      error "文件校验失败（SHA-256 不匹配）"+ 删除磁盘文件，不建请求
    - 匹配/缺省：落库（file_requests.sha256）；file_request 推送头带 sha256
    - 接收方接受后推送 file 消息头带 sha256
    - 群组文件同契约（group_file_request / group_file_request 推送）
    - 大文件直传：不校验（边收边转无法落盘），sha256 头透传到接收方

  上传断点续传（P1-6，发送方 → 服务器）:
    file 消息头 offset=<N>（N>0）: 服务器在 pending/{message_id} 已有 N
    字节基础上追加（'ab'）；磁盘已有大小 != N →
    error "续传偏移不匹配"（先消费消息体避免流错位）
    offset 缺省/0: 从头覆盖接收（既有行为）
    收满后正常建 file_request，接收方接受得到完整拼接内容

  下载断点续传（P1-6，服务器 → 接收方）:
    C → S: type="file_resume", header {message_id, offset}
    S → C: type="file", header {from, filename, filesize, message_id,
           offset=<N>}, body=文件从 N 起的剩余部分
      仅接收方（message_history file 行 receiver == username）可续传
    失败: 无此文件/文件已删 → error 含 "不存在"；
         offset >= filesize → error 含 "超出文件大小"；
         非接收方 → error 含 "无权限"

  文件收发管理页（P1-7）:
    C → S: type="list_files", header {to?/group_id?}
    S → C: type="file_list_response", body=JSON
           [{filename, filesize, sender, receiver, message_id, timestamp,
             group_id, status}, ...]
      范围与 get_user_file_messages 一致（私聊双向/群聊全员/缺省全局）

【运行】
  实现前：本文件多数用例红（服务端未实现新类型/方法），属 TDD 红。
  实现后：全部通过。

  .venv/bin/python -m pytest tests/test_stage_m_server.py -v
"""

import hashlib
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _login(harness, username, password, admin_secret=None, consume=True):
    c = harness.client()
    c.login(username, password, admin_secret=admin_secret, consume=consume)
    return c


def _alice(harness):
    return _login(harness, "alice", "password123")


def _bob(harness):
    return _login(harness, "bob", "password456")


def _carol(harness):
    return _login(harness, "carol", "password789")


def _group_setup(harness, name="开发组", with_bob=True, with_carol=False):
    """alice 建群 + 可选成员直接加入（成员用户预创建，登录即用）。

    返回 (alice, bob, carol, gid)；with_* 为 False 时对应元素为 None，
    但 bob/carol 用户仍存在于数据库（需要时自行 _bob/_carol 登录）。
    """
    alice = _alice(harness)
    for u, pw in (("bob", "password456"), ("carol", "password789"),
                  ("dave", "pass1234")):
        if not harness.db.user_exists(u):
            harness.add_user(u, pw)
    gid = harness.db.create_group(name, "alice")
    if with_bob:
        harness.db.join_group(gid, "bob")
    if with_carol:
        harness.db.join_group(gid, "carol")
    bob = _bob(harness) if with_bob else None
    carol = _carol(harness) if with_carol else None
    if bob:
        bob.drain(timeout=0.5)
    if carol:
        carol.drain(timeout=0.5)
    return alice, bob, carol, gid


def _set_large_file_threshold(monkeypatch, size):
    from config import config
    data = dict(config._data) if isinstance(config._data, dict) else {}
    data.setdefault("file", {})["large_file_threshold"] = size
    monkeypatch.setattr(config, "_data", data)


def _set_max_file_size(monkeypatch, size):
    from config import config
    data = dict(config._data) if isinstance(config._data, dict) else {}
    data.setdefault("file", {})["max_file_size"] = size
    monkeypatch.setattr(config, "_data", data)


# ============================================================
# M1 —— 群主权限：踢人
# ============================================================

class TestKickMemberProtocol:

    def test_kick_member_success_and_notifications(self, harness):
        """群主踢人 → 操作者确认 + 被踢者通知 + 其余成员通知 + 列表刷新。"""
        alice, bob, carol, gid = _group_setup(harness, with_carol=True)
        carol.drain(timeout=0.5)

        alice.send("kick_member", "", group_id=str(gid), target="bob")

        h, d = alice.expect("chat", timeout=3)
        assert "已将 bob 移出群组" in d.decode(), f"操作者确认: {d.decode()}"
        h, d = bob.expect("chat", timeout=3)
        assert h.get("from") == "系统" and "您已被群主移出群组" in d.decode(), \
            f"被踢者通知: {d.decode()}"
        h, d = bob.expect("list_groups", timeout=3)
        groups = json.loads(d.decode())
        assert all(g["id"] != gid for g in groups), f"被踢者群列表应移除该群: {groups}"
        h, d = carol.expect("chat", timeout=3)
        assert "bob 已被移出群组" in d.decode(), f"其余成员通知: {d.decode()}"

        assert "bob" not in harness.db.get_group_members(gid)

    def test_kicked_member_cannot_send_group_chat(self, harness):
        """被踢者再发群聊 → error（既有成员校验兜底）。"""
        alice, bob, carol, gid = _group_setup(harness, with_carol=True)
        alice.send("kick_member", "", group_id=str(gid), target="bob")
        alice.expect("chat", timeout=3)
        bob.drain(timeout=0.8)

        bob.send("group_chat", "我还在吗", group_id=str(gid), message_id="m-kick-1")
        h, d = bob.expect("error", timeout=3)
        assert "不在此群组" in d.decode() or "不存在" in d.decode()

    def test_kick_offline_member_notification_saved(self, harness):
        """被踢者离线 → 离线通知保存，下次登录可见。"""
        alice = _alice(harness)
        gid = harness.db.create_group("开发组", "alice")
        harness.add_user("bob", "password456")
        harness.db.join_group(gid, "bob")

        alice.send("kick_member", "", group_id=str(gid), target="bob")
        h, d = alice.expect("chat", timeout=3)
        assert "已将 bob 移出群组" in d.decode()

        # 注意：_bob 已消费初始数据，此处用 consume=False 重新登录读取
        bob = _login(harness, "bob", "password456", consume=False)
        offline = [x for x in bob.recv_initial()["offline"]]
        texts = [x[1].decode() for x in offline]
        assert any("您已被群主移出群组" in t for t in texts), f"离线通知应可见: {texts}"

    def test_kick_non_owner_rejected(self, harness):
        """非群主踢人 → error 含 '群主'，成员保留。"""
        alice, bob, carol, gid = _group_setup(harness, with_carol=True)
        carol.drain(timeout=0.5)

        bob.send("kick_member", "", group_id=str(gid), target="carol")
        h, d = bob.expect("error", timeout=3)
        assert "群主" in d.decode(), f"非群主应被拒: {d.decode()}"
        assert "carol" in harness.db.get_group_members(gid)

    def test_kick_owner_rejected(self, harness):
        """踢群主 → error。"""
        alice, bob, carol, gid = _group_setup(harness, with_carol=True)
        alice.send("kick_member", "", group_id=str(gid), target="alice")
        h, d = alice.expect("error", timeout=3)
        assert "群主" in d.decode() or "自己" in d.decode()

    def test_kick_self_rejected(self, harness):
        """群主踢自己 → error（应走 leave_group）。"""
        alice, bob, carol, gid = _group_setup(harness, with_carol=True)
        alice.send("kick_member", "", group_id=str(gid), target="alice")
        h, d = alice.expect("error", timeout=3)
        assert "自己" in d.decode() or "群主" in d.decode()

    def test_kick_non_member_rejected(self, harness):
        """目标非成员 → error。"""
        alice, bob, carol, gid = _group_setup(harness)
        alice.send("kick_member", "", group_id=str(gid), target="ghost")
        h, d = alice.expect("error", timeout=3)
        assert "不在群组" in d.decode() or "不存在" in d.decode()

    def test_kick_nonexistent_group_rejected(self, harness):
        """群不存在 → error。"""
        alice = _alice(harness)
        alice.send("kick_member", "", group_id="9999", target="bob")
        h, d = alice.expect("error", timeout=3)
        assert "不存在" in d.decode()


# ============================================================
# M1 —— 群主权限：转让群主
# ============================================================

class TestTransferOwnerProtocol:

    def test_transfer_owner_success(self, harness):
        """转让成功 → 双方通知 + created_by 落库 + 旧群主失去权限。"""
        alice, bob, carol, gid = _group_setup(harness, with_carol=True)
        carol.drain(timeout=0.5)

        alice.send("transfer_owner", "", group_id=str(gid), target="bob")

        h, d = alice.expect("chat", timeout=3)
        assert "已将群主转让给 bob" in d.decode(), f"操作者确认: {d.decode()}"
        h, d = bob.expect("chat", timeout=3)
        assert h.get("from") == "系统" and "您已成为群组" in d.decode(), \
            f"新群主通知: {d.decode()}"
        h, d = carol.expect("chat", timeout=3)
        assert "群主已变更为 bob" in d.decode(), f"其余成员通知: {d.decode()}"

        # 全体成员收 list_groups 刷新（客户端据此更新群主标识）
        for client in (alice, bob, carol):
            h, d = client.expect("list_groups", timeout=3)
            groups = json.loads(d.decode())
            target = next(g for g in groups if g["id"] == gid)
            assert target.get("created_by") == "bob", \
                f"列表刷新应携带新群主: {groups}"

        assert harness.db.get_group_info(gid)["created_by"] == "bob"

        # 旧群主失去管理权限：再踢人被拒
        alice.send("kick_member", "", group_id=str(gid), target="carol")
        h, d = alice.expect("error", timeout=3)
        assert "群主" in d.decode(), f"旧群主应失去权限: {d.decode()}"

    def test_transfer_owner_non_owner_rejected(self, harness):
        """非群主转让 → error。"""
        alice, bob, carol, gid = _group_setup(harness, with_carol=True)
        bob.send("transfer_owner", "", group_id=str(gid), target="carol")
        h, d = bob.expect("error", timeout=3)
        assert "群主" in d.decode()
        assert harness.db.get_group_info(gid)["created_by"] == "alice"

    def test_transfer_owner_target_not_member(self, harness):
        """目标非成员 → error。"""
        alice, bob, carol, gid = _group_setup(harness)
        alice.send("transfer_owner", "", group_id=str(gid), target="ghost")
        h, d = alice.expect("error", timeout=3)
        assert "不在群组" in d.decode() or "不存在" in d.decode()

    def test_transfer_owner_to_self_rejected(self, harness):
        """转让给自己 → error。"""
        alice, bob, carol, gid = _group_setup(harness)
        alice.send("transfer_owner", "", group_id=str(gid), target="alice")
        h, d = alice.expect("error", timeout=3)
        assert "自己" in d.decode() or "群主" in d.decode()

    def test_transfer_owner_offline_target_notification_saved(self, harness):
        """新群主离线 → 离线通知保存。"""
        alice = _alice(harness)
        gid = harness.db.create_group("开发组", "alice")
        harness.add_user("bob", "password456")
        harness.db.join_group(gid, "bob")

        alice.send("transfer_owner", "", group_id=str(gid), target="bob")
        h, d = alice.expect("chat", timeout=3)
        assert "已将群主转让给 bob" in d.decode()

        bob = _login(harness, "bob", "password456", consume=False)
        texts = [x[1].decode() for x in bob.recv_initial()["offline"]]
        assert any("您已成为群组" in t for t in texts), f"离线通知应可见: {texts}"


# ============================================================
# M1 —— 群主权限：改名 / 群头像
# ============================================================

class TestRenameGroupProtocol:

    def test_rename_group_success(self, harness):
        """改名成功 → 操作者确认 + 成员通知 + 列表刷新。"""
        alice, bob, carol, gid = _group_setup(harness, with_carol=True)
        carol.drain(timeout=0.5)

        alice.send("rename_group", "", group_id=str(gid), name="新开发组")

        h, d = alice.expect("chat", timeout=3)
        assert "已改名为 新开发组" in d.decode(), f"操作者确认: {d.decode()}"
        h, d = alice.expect("list_groups", timeout=3)
        groups = json.loads(d.decode())
        assert any(g["id"] == gid and g["group_name"] == "新开发组" for g in groups)
        h, d = bob.expect("chat", timeout=3)
        assert h.get("from") == "系统" and "已改名为 新开发组" in d.decode(), \
            f"成员通知: {d.decode()}"
        h, d = bob.expect("list_groups", timeout=3)
        groups = json.loads(d.decode())
        assert any(g["id"] == gid and g["group_name"] == "新开发组" for g in groups)
        # 其余成员同样收"系统 chat 通知 + list_groups 刷新"（与 bob 一致）
        h, d = carol.expect("chat", timeout=3)
        assert h.get("from") == "系统" and "已改名为 新开发组" in d.decode(), \
            f"成员通知: {d.decode()}"
        h, d = carol.expect("list_groups", timeout=3)
        groups = json.loads(d.decode())
        assert any(g["id"] == gid and g["group_name"] == "新开发组" for g in groups)

        assert harness.db.get_group_info(gid)["group_name"] == "新开发组"

    def test_rename_group_non_owner_rejected(self, harness):
        """非群主改名 → error。"""
        alice, bob, carol, gid = _group_setup(harness, with_carol=True)
        bob.send("rename_group", "", group_id=str(gid), name="篡改名")
        h, d = bob.expect("error", timeout=3)
        assert "群主" in d.decode()
        assert harness.db.get_group_info(gid)["group_name"] == "开发组"

    def test_rename_group_duplicate_rejected(self, harness):
        """重名 → error，原名保留。"""
        alice, bob, carol, gid = _group_setup(harness)
        harness.db.create_group("已存在名", "alice")
        alice.send("rename_group", "", group_id=str(gid), name="已存在名")
        h, d = alice.expect("error", timeout=3)
        assert "已存在" in d.decode() or "失败" in d.decode()
        assert harness.db.get_group_info(gid)["group_name"] == "开发组"

    def test_rename_group_empty_rejected(self, harness):
        """空名 → error。"""
        alice, bob, carol, gid = _group_setup(harness)
        alice.send("rename_group", "", group_id=str(gid), name="")
        h, d = alice.expect("error", timeout=3)
        assert "不能为空" in d.decode() or "失败" in d.decode()


class TestListGroupsCarriesOwner:
    """list_groups 推送携带 created_by（群主标识，向后兼容扩展）。
    头像功能已废除（2026-08-25 用户决策），不再验证 avatar。"""

    def test_list_groups_carries_owner(self, harness):
        """登录初始数据 list_groups 携带 created_by。"""
        alice = _alice(harness)
        gid = harness.db.create_group("开发组", "alice")
        harness.db.join_group(gid, "bob")

        bob = _bob(harness)
        bob.send("list_groups", "")
        h, d = bob.expect("list_groups", timeout=3)
        groups = json.loads(d.decode())
        assert len(groups) >= 1
        for g in groups:
            assert "id" in g and "group_name" in g
            if g["id"] == gid:
                assert g.get("created_by") == "alice", f"应携带群主: {g}"


# ============================================================
# M2 —— 入群审批
# ============================================================

class TestRequestJoinGroupProtocol:

    def test_request_join_group_success(self, harness):
        """申请成功 → 申请者确认 + 群主在线通知。"""
        alice, bob, carol, gid = _group_setup(harness, with_bob=False)
        carol = _carol(harness)
        carol.send("request_join_group", str(gid))
        h, d = carol.expect("chat", timeout=3)
        assert "已发送入群申请" in d.decode(), f"申请者确认: {d.decode()}"

        h, d = alice.expect("chat", timeout=3)
        assert h.get("from") == "系统" and "carol 请求加入群组" in d.decode(), \
            f"群主通知: {d.decode()}"

        assert harness.db.has_pending_group_join_request(gid, "carol")
        assert not harness.db.is_group_member(gid, "carol"), "申请不直接入群"

    def test_request_join_group_owner_offline_notification(self, harness):
        """群主离线 → 申请通知离线保存，群主登录可见。"""
        harness.add_user("carol", "password789")
        gid = harness.db.create_group("开发组", "alice")
        carol = _carol(harness)

        carol.send("request_join_group", str(gid))
        h, d = carol.expect("chat", timeout=3)
        assert "已发送入群申请" in d.decode()

        alice = _login(harness, "alice", "password123", consume=False)
        texts = [x[1].decode() for x in alice.recv_initial()["offline"]]
        assert any("carol 请求加入群组" in t for t in texts), f"离线通知: {texts}"

    def test_request_join_group_already_member(self, harness):
        """已是成员 → error。"""
        alice, bob, carol, gid = _group_setup(harness)
        bob.send("request_join_group", str(gid))
        h, d = bob.expect("error", timeout=3)
        assert "已在群组" in d.decode(), f"已是成员应被拒: {d.decode()}"

    def test_request_join_group_duplicate(self, harness):
        """重复申请 → error。"""
        alice, bob, carol, gid = _group_setup(harness, with_bob=False)
        carol = _carol(harness)
        carol.send("request_join_group", str(gid))
        carol.expect("chat", timeout=3)
        alice.drain(timeout=0.5)

        carol.send("request_join_group", str(gid))
        h, d = carol.expect("error", timeout=3)
        assert "已发送" in d.decode(), f"重复申请应被拒: {d.decode()}"

    def test_request_join_group_nonexistent_group(self, harness):
        """群不存在 → error。"""
        alice, bob, carol, gid = _group_setup(harness, with_bob=False)
        carol = _carol(harness)
        carol.send("request_join_group", "9999")
        h, d = carol.expect("error", timeout=3)
        assert "不存在" in d.decode()


class TestApproveJoinRequestProtocol:

    def test_approve_join_success(self, harness):
        """批准 → 群主确认 + 被批准者通知 + 列表刷新 + 成员通知 + 入群。"""
        alice, bob, carol, gid = _group_setup(harness, with_bob=True, with_carol=True)
        dave = _login(harness, "dave", "pass1234")
        harness.db.request_join_group(gid, "dave")
        dave.drain(timeout=0.5)
        bob.drain(timeout=0.5)
        carol.drain(timeout=0.5)

        alice.send("approve_join_request", "", group_id=str(gid), target="dave")

        h, d = alice.expect("chat", timeout=3)
        assert "已批准 dave 加入群组" in d.decode(), f"群主确认: {d.decode()}"
        h, d = dave.expect("chat", timeout=3)
        assert h.get("from") == "系统" and "您已加入群组" in d.decode(), \
            f"被批准者通知: {d.decode()}"
        h, d = dave.expect("list_groups", timeout=3)
        groups = json.loads(d.decode())
        assert any(g["id"] == gid for g in groups), f"被批准者群列表应含该群: {groups}"
        h, d = bob.expect("chat", timeout=3)
        assert "dave 已加入群组" in d.decode(), f"成员通知: {d.decode()}"
        carol.drain(timeout=0.5)

        assert harness.db.is_group_member(gid, "dave")
        assert not harness.db.has_pending_group_join_request(gid, "dave")

    def test_approve_join_offline_target(self, harness):
        """被批准者离线 → 离线通知 + 下次登录已入群。"""
        alice = _alice(harness)
        gid = harness.db.create_group("开发组", "alice")
        harness.add_user("bob", "password456")
        harness.db.request_join_group(gid, "bob")

        alice.send("approve_join_request", "", group_id=str(gid), target="bob")
        h, d = alice.expect("chat", timeout=3)
        assert "已批准 bob 加入群组" in d.decode()

        bob = _login(harness, "bob", "password456", consume=False)
        data = bob.recv_initial()
        texts = [x[1].decode() for x in data["offline"]]
        assert any("您已加入群组" in t for t in texts), f"离线通知: {texts}"
        assert any(g["id"] == gid for g in data["groups"]), \
            "登录群列表应已含该群"

    def test_approve_join_non_owner_rejected(self, harness):
        """非群主批准 → error。"""
        alice, bob, carol, gid = _group_setup(harness, with_bob=True)
        carol = _carol(harness)
        harness.db.request_join_group(gid, "carol")
        bob.send("approve_join_request", "", group_id=str(gid), target="carol")
        h, d = bob.expect("error", timeout=3)
        assert "群主" in d.decode()
        assert not harness.db.is_group_member(gid, "carol")
        assert harness.db.has_pending_group_join_request(gid, "carol")

    def test_approve_join_without_request(self, harness):
        """无申请 → error。"""
        alice, bob, carol, gid = _group_setup(harness)
        alice.send("approve_join_request", "", group_id=str(gid), target="bob")
        h, d = alice.expect("error", timeout=3)
        assert "没有来自" in d.decode()


class TestRejectJoinRequestProtocol:

    def test_reject_join_success(self, harness):
        """拒绝 → 群主确认 + 被拒者通知。"""
        alice, bob, carol, gid = _group_setup(harness, with_bob=False)
        carol = _carol(harness)
        carol.send("request_join_group", str(gid))
        carol.expect("chat", timeout=3)
        alice.drain(timeout=0.5)

        alice.send("reject_join_request", "", group_id=str(gid), target="carol")

        h, d = alice.expect("chat", timeout=3)
        assert "已拒绝 carol 的入群申请" in d.decode(), f"群主确认: {d.decode()}"
        h, d = carol.expect("chat", timeout=3)
        assert h.get("from") == "系统" and "已被拒绝" in d.decode(), \
            f"被拒者通知: {d.decode()}"

        assert not harness.db.has_pending_group_join_request(gid, "carol")
        assert not harness.db.is_group_member(gid, "carol")

    def test_reject_join_offline_target(self, harness):
        """被拒者离线 → 离线通知保存。"""
        alice = _alice(harness)
        gid = harness.db.create_group("开发组", "alice")
        harness.add_user("bob", "password456")
        harness.db.request_join_group(gid, "bob")

        alice.send("reject_join_request", "", group_id=str(gid), target="bob")
        h, d = alice.expect("chat", timeout=3)
        assert "已拒绝 bob 的入群申请" in d.decode()

        bob = _login(harness, "bob", "password456", consume=False)
        texts = [x[1].decode() for x in bob.recv_initial()["offline"]]
        assert any("已被拒绝" in t for t in texts), f"离线通知: {texts}"

    def test_reject_join_non_owner_rejected(self, harness):
        """非群主拒绝 → error。"""
        alice, bob, carol, gid = _group_setup(harness, with_bob=True)
        carol = _carol(harness)
        harness.db.request_join_group(gid, "carol")
        bob.send("reject_join_request", "", group_id=str(gid), target="carol")
        h, d = bob.expect("error", timeout=3)
        assert "群主" in d.decode()
        assert harness.db.has_pending_group_join_request(gid, "carol")

    def test_reject_join_without_request(self, harness):
        """无申请 → error。"""
        alice, bob, carol, gid = _group_setup(harness)
        alice.send("reject_join_request", "", group_id=str(gid), target="bob")
        h, d = alice.expect("error", timeout=3)
        assert "没有来自" in d.decode()

    def test_reject_then_requeue(self, harness):
        """拒绝后可再次申请（申请行已清理）。"""
        alice, bob, carol, gid = _group_setup(harness, with_bob=False)
        carol = _carol(harness)
        carol.send("request_join_group", str(gid))
        carol.expect("chat", timeout=3)
        alice.drain(timeout=0.5)
        alice.send("reject_join_request", "", group_id=str(gid), target="carol")
        alice.expect("chat", timeout=3)
        carol.drain(timeout=0.5)

        carol.send("request_join_group", str(gid))
        h, d = carol.expect("chat", timeout=3)
        assert "已发送入群申请" in d.decode()


# ============================================================
# M2 —— 邀请制
# ============================================================

class TestInviteGroupMemberProtocol:

    def test_invite_success_pushes_group_invite(self, harness):
        """邀请成功 → 邀请者确认 + 被邀请者收到 group_invite 推送。"""
        alice, bob, carol, gid = _group_setup(harness, with_bob=False)
        carol = _carol(harness)

        alice.send("invite_group_member", "", group_id=str(gid), target="carol")

        h, d = alice.expect("chat", timeout=3)
        assert "已邀请 carol 加入群组" in d.decode(), f"邀请者确认: {d.decode()}"
        h, d = carol.expect("group_invite", timeout=3)
        assert h.get("from") == "alice"
        assert h.get("group_id") == str(gid)
        assert h.get("group_name") == "开发组", f"应携带群名: {h}"

        assert (gid, "开发组", "alice") in harness.db.get_pending_group_invitations("carol")
        assert not harness.db.is_group_member(gid, "carol")

    def test_invite_offline_target_notification(self, harness):
        """被邀请者离线 → 邀请持久化，登录补发 group_invite（入口保留）。"""
        alice = _alice(harness)
        gid = harness.db.create_group("开发组", "alice")
        harness.add_user("bob", "password456")

        alice.send("invite_group_member", "", group_id=str(gid), target="bob")
        h, d = alice.expect("chat", timeout=3)
        assert "已邀请 bob 加入群组" in d.decode()

        # 邀请行持久化（离线可补发）
        assert (gid, "开发组", "alice") in harness.db.get_pending_group_invitations("bob")

        bob = _login(harness, "bob", "password456", consume=False)
        data = bob.recv_initial()
        invites = [h for h, _ in data["extra"] if h.get("type") == "group_invite"]
        assert len(invites) == 1, f"登录应补发 group_invite: {data['extra']}"
        assert invites[0].get("group_id") == str(gid)
        assert invites[0].get("group_name") == "开发组"
        assert invites[0].get("from") == "alice"

    def test_invite_non_member_rejected(self, harness):
        """非成员发起邀请 → error。"""
        alice, bob, carol, gid = _group_setup(harness, with_bob=False)
        bob = _bob(harness)
        bob.send("invite_group_member", "", group_id=str(gid), target="carol")
        h, d = bob.expect("error", timeout=3)
        assert "不在此群组" in d.decode() or "群组" in d.decode()

    def test_invite_already_member_rejected(self, harness):
        """目标已是成员 → error。"""
        alice, bob, carol, gid = _group_setup(harness)
        alice.send("invite_group_member", "", group_id=str(gid), target="bob")
        h, d = alice.expect("error", timeout=3)
        assert "已在群组" in d.decode() or "已" in d.decode()

    def test_invite_duplicate_rejected(self, harness):
        """重复邀请 → error。"""
        alice, bob, carol, gid = _group_setup(harness, with_bob=False)
        carol = _carol(harness)
        alice.send("invite_group_member", "", group_id=str(gid), target="carol")
        alice.expect("chat", timeout=3)
        carol.drain(timeout=0.5)
        alice.send("invite_group_member", "", group_id=str(gid), target="carol")
        h, d = alice.expect("error", timeout=3)
        assert "已发送" in d.decode() or "邀请" in d.decode()

    def test_invite_nonexistent_user_rejected(self, harness):
        """目标不存在 → error。"""
        alice, bob, carol, gid = _group_setup(harness)
        alice.send("invite_group_member", "", group_id=str(gid), target="ghost")
        h, d = alice.expect("error", timeout=3)
        assert "不存在" in d.decode()


class TestAcceptGroupInviteProtocol:

    def test_accept_invite_joins_group(self, harness):
        """接受邀请 → 确认 + 入群 + 列表刷新 + 成员通知。"""
        alice, bob, carol, gid = _group_setup(harness, with_bob=True)
        carol = _carol(harness)
        harness.db.invite_group_member(gid, "alice", "carol")
        bob.drain(timeout=0.5)
        carol.drain(timeout=0.5)

        carol.send("accept_group_invite", "", group_id=str(gid))

        h, d = carol.expect("chat", timeout=3)
        assert "已加入群组" in d.decode(), f"确认: {d.decode()}"
        h, d = carol.expect("list_groups", timeout=3)
        groups = json.loads(d.decode())
        assert any(g["id"] == gid for g in groups), f"群列表应含该群: {groups}"
        h, d = bob.expect("chat", timeout=3)
        assert "carol 已加入群组" in d.decode(), f"成员通知: {d.decode()}"

        assert harness.db.is_group_member(gid, "carol")
        assert harness.db.get_pending_group_invitations("carol") == []

    def test_accept_invite_without_invite(self, harness):
        """无邀请接受 → error。"""
        alice, bob, carol, gid = _group_setup(harness, with_bob=False)
        carol = _carol(harness)
        carol.send("accept_group_invite", "", group_id=str(gid))
        h, d = carol.expect("error", timeout=3)
        assert "没有来自" in d.decode() or "邀请" in d.decode()
        assert not harness.db.is_group_member(gid, "carol")


class TestDeclineGroupInviteProtocol:

    def test_decline_invite(self, harness):
        """拒绝邀请 → 确认 + 邀请行删除，不入群。"""
        alice, bob, carol, gid = _group_setup(harness, with_bob=False)
        carol = _carol(harness)
        harness.db.invite_group_member(gid, "alice", "carol")
        carol.drain(timeout=0.5)

        carol.send("decline_group_invite", "", group_id=str(gid))
        h, d = carol.expect("chat", timeout=3)
        assert "已拒绝邀请" in d.decode(), f"确认: {d.decode()}"

        assert harness.db.get_pending_group_invitations("carol") == []
        assert not harness.db.is_group_member(gid, "carol")

    def test_decline_without_invite(self, harness):
        """无邀请拒绝 → error。"""
        alice, bob, carol, gid = _group_setup(harness, with_bob=False)
        carol = _carol(harness)
        carol.send("decline_group_invite", "", group_id=str(gid))
        h, d = carol.expect("error", timeout=3)
        assert "没有来自" in d.decode() or "邀请" in d.decode()


# ============================================================
# M3 —— 新成员历史可见性
# ============================================================

class TestHistoryVisibilityProtocol:

    def _insert_group_messages(self, harness, gid, sender, count,
                               minutes_ago=60):
        """直接向 message_history 插入 count 条群消息（过去时间戳）。"""
        from datetime import datetime, timedelta
        base = datetime.utcnow() - timedelta(minutes=minutes_ago)
        for i in range(count):
            ts = (base + timedelta(seconds=i)).strftime("%Y-%m-%d %H:%M:%S")
            with harness.db._get_connection() as conn:
                conn.execute(
                    "INSERT INTO message_history "
                    "(message_id, sender, receiver, message_type, content, "
                    "group_id, status, timestamp) VALUES (?, ?, '', 'group_chat', ?, ?, 'sent', ?)",
                    (f"hist-{sender}-{i}", sender, f"msg {i}".encode(), gid, ts))
                conn.commit()

    def test_set_history_visible_success(self, harness):
        """群主设置可见性 → 确认 + 落库 + 全体成员列表刷新（开关状态同步）。"""
        alice, bob, carol, gid = _group_setup(harness)
        alice.send("set_group_history_visible", "", group_id=str(gid),
                   visible="0", limit="10")
        h, d = alice.expect("chat", timeout=3)
        assert "历史可见性" in d.decode(), f"确认: {d.decode()}"
        info = harness.db.get_group_info(gid)
        assert info["history_visible"] == 0
        assert info["history_limit"] == 10

        # 全体成员收 list_groups 刷新且携带 history_visible（缺陷修复：
        # 开关状态不同步——客户端 Group 不更新则一直显示旧值）
        for client in (alice, bob):
            h, d = client.expect("list_groups", timeout=3)
            groups = json.loads(d.decode())
            target = next(g for g in groups if g["id"] == gid)
            assert target.get("history_visible") == 0, \
                f"列表刷新应携带关闭后的 visible: {target}"
            assert target.get("history_limit") == 10

    def test_set_history_visible_toggle_roundtrip(self, harness):
        """开关可闭合可开启：关闭后再次开启，list_groups 状态往返同步。"""
        alice, bob, carol, gid = _group_setup(harness)
        # 关闭
        alice.send("set_group_history_visible", "", group_id=str(gid),
                   visible="0", limit="10")
        alice.expect("chat", timeout=3)
        alice.expect("list_groups", timeout=3)
        # 再次开启
        alice.send("set_group_history_visible", "", group_id=str(gid),
                   visible="1", limit="50")
        h, d = alice.expect("chat", timeout=3)
        assert "开启" in d.decode(), f"重新开启确认: {d.decode()}"
        h, d = alice.expect("list_groups", timeout=3)
        groups = json.loads(d.decode())
        target = next(g for g in groups if g["id"] == gid)
        assert target.get("history_visible") == 1, \
            f"重新开启后列表刷新应携带 visible=1: {target}"
        assert target.get("history_limit") == 50
        info = harness.db.get_group_info(gid)
        assert info["history_visible"] == 1
        assert info["history_limit"] == 50

    def test_set_history_visible_non_owner_rejected(self, harness):
        """非群主设置 → error。"""
        alice, bob, carol, gid = _group_setup(harness)
        bob.send("set_group_history_visible", "", group_id=str(gid),
                 visible="0", limit="10")
        h, d = bob.expect("error", timeout=3)
        assert "群主" in d.decode()
        assert harness.db.get_group_info(gid)["history_visible"] == 1

    def test_new_member_sees_recent_limit_when_visible(self, harness):
        """visible=1：新成员可见加入前最近 limit 条 + 加入后全部（默认 50）。"""
        alice, bob, carol, gid = _group_setup(harness)
        # 加入前 60 条历史（60 分钟前）
        self._insert_group_messages(harness, gid, "alice", 60)

        # carol 此刻加入（joined_at = now，晚于全部历史）
        carol = _carol(harness)
        harness.db.join_group(gid, "carol")
        carol.drain(timeout=0.5)

        # 加入后 3 条
        carol.send("group_chat", "加入后第一条", group_id=str(gid), message_id="m-after-1")
        bob.send("group_chat", "加入后第二条", group_id=str(gid), message_id="m-after-2")
        bob.send("group_chat", "加入后第三条", group_id=str(gid), message_id="m-after-3")
        carol.drain(timeout=0.8)

        carol.send("fetch_history", "", group_id=str(gid), limit="100")
        h, d = carol.expect("history_response", timeout=3)
        batch = json.loads(d.decode())
        # 60 条历史中可见最近 50 条 + 加入后 3 条 = 53
        # （limit=100 避免分页上限掩盖 M3 可见性过滤效果）
        assert len(batch) == 53, f"应可见最近 50 条历史 + 3 条新消息: {len(batch)}"
        contents = [m["content"] for m in batch]
        assert "msg 59" in contents, "最新的历史消息应可见"
        assert "msg 0" not in contents, "最早的 10 条历史应不可见"
        assert "加入后第一条" in contents

    def test_new_member_sees_nothing_when_visibility_off(self, harness):
        """visible=0：新成员仅可见自己加入后的消息，历史一片空白。"""
        alice, bob, carol, gid = _group_setup(harness)
        self._insert_group_messages(harness, gid, "alice", 10)
        harness.db.set_group_history_visibility(gid, "alice", 0, 50)

        carol = _carol(harness)
        harness.db.join_group(gid, "carol")
        carol.drain(timeout=0.5)

        carol.send("fetch_history", "", group_id=str(gid))
        h, d = carol.expect("history_response", timeout=3)
        batch = json.loads(d.decode())
        assert batch == [], f"关闭可见性后新成员历史应为空: {batch}"

        # 加入后发一条 → 可见
        carol.send("group_chat", "我加入后的消息", group_id=str(gid), message_id="m-vis-off-1")
        carol.drain(timeout=0.8)
        carol.send("fetch_history", "", group_id=str(gid))
        h, d = carol.expect("history_response", timeout=3)
        batch = json.loads(d.decode())
        assert [m["content"] for m in batch] == ["我加入后的消息"]

    def test_old_member_history_unaffected(self, harness):
        """老成员（加入早）历史不受影响：仍可见全部历史。"""
        alice, bob, carol, gid = _group_setup(harness)
        # bob 是"老成员"：joined_at 早于全部历史消息
        with harness.db._get_connection() as conn:
            conn.execute(
                "UPDATE group_members SET joined_at = datetime('now', '-2 hours') "
                "WHERE group_id = ? AND username = 'bob'", (gid,))
            conn.commit()
        self._insert_group_messages(harness, gid, "alice", 5)
        harness.db.set_group_history_visibility(gid, "alice", 0, 50)

        bob.send("fetch_history", "", group_id=str(gid))
        h, d = bob.expect("history_response", timeout=3)
        batch = json.loads(d.decode())
        assert len(batch) == 5, f"老成员应仍可见全部历史: {len(batch)}"

    def test_visibility_persists_after_relogin(self, harness):
        """策略落库：重登后 fetch_history 仍按策略过滤。"""
        alice, bob, carol, gid = _group_setup(harness)
        self._insert_group_messages(harness, gid, "alice", 5)
        harness.db.set_group_history_visibility(gid, "alice", 0, 50)

        carol = _carol(harness)
        harness.db.join_group(gid, "carol")
        carol.drain(timeout=0.5)
        carol.send("fetch_history", "", group_id=str(gid))
        h, d = carol.expect("history_response", timeout=3)
        assert json.loads(d.decode()) == []

        carol.close()
        time.sleep(0.3)
        carol2 = _carol(harness)
        carol2.send("fetch_history", "", group_id=str(gid))
        h, d = carol2.expect("history_response", timeout=3)
        assert json.loads(d.decode()) == [], "重登后策略应仍然生效"


# ============================================================
# M4 —— 服务端状态面板
# ============================================================

class TestServerStatusPanel:

    def test_server_status_fields(self, harness):
        """server_status 返回完整字段与正确计数。"""
        alice = _alice(harness)
        bob = _bob(harness)
        harness.db.save_message_history("alice", "bob", "chat", b"hi",
                                        message_id="st-m1")

        admin = _login(harness, "admin", "adminpass",
                       admin_secret="test-admin-secret")
        admin.send("admin_command", "", action="server_status")
        h, d = admin.expect("admin_response", timeout=3)
        assert h.get("response_type") == "server_status"
        status = json.loads(d.decode())

        assert status["online_users"] == 3, f"在线用户数: {status}"
        assert status["online_sessions"] == 3
        assert status["total_users"] == 3  # alice / bob / admin
        assert status["total_messages"] == 1
        assert status["pending_file_requests"] == 0
        assert set(status["storage"]) == {"file_store_bytes", "file_count", "db_bytes"}
        assert set(status["disk"]) == {"disk_free", "disk_total", "warn"}
        assert isinstance(status["recent_logs"], list)
        assert len(status["recent_logs"]) > 0, "应有最近日志"

    def test_server_status_tracks_file_stats(self, harness, tmp_path):
        """有文件请求时 storage 统计反映文件占用。"""
        alice = _alice(harness)
        bob = _bob(harness)
        file_path = os.path.join(harness.db._pending_dir(), "st-f1")
        with open(file_path, "wb") as f:
            f.write(b"0123456789")
        harness.db.save_file_request("alice", "bob", "f.txt", 10, b"",
                                     message_id="st-f1", file_path=file_path)

        admin = _login(harness, "admin", "adminpass",
                       admin_secret="test-admin-secret")
        admin.send("admin_command", "", action="server_status")
        h, d = admin.expect("admin_response", timeout=3)
        status = json.loads(d.decode())
        assert status["storage"]["file_count"] == 1
        assert status["storage"]["file_store_bytes"] == 10
        assert status["pending_file_requests"] == 1

    def test_server_status_rejects_non_admin(self, harness):
        """非管理员请求 server_status → error。"""
        alice = _alice(harness)
        alice.send("admin_command", "", action="server_status")
        h, d = alice.expect("error", timeout=3)
        assert "无管理员权限" in d.decode()

    def test_get_server_status_direct(self, harness):
        """Server.get_server_status() 可直接调用（面板/脚本复用）。"""
        _alice(harness)
        _bob(harness)
        status = harness.server.get_server_status()
        assert status["online_users"] == 2
        assert status["online_sessions"] == 2
        assert status["total_users"] == 3

    def test_recent_logs_record_activity(self, harness):
        """recent_logs 记录服务器活动（登录等）。"""
        _alice(harness)
        assert len(harness.server.recent_logs) > 0, "登录应产生日志记录"

    def test_check_disk_usage_no_warn_normally(self, harness):
        """磁盘充足 → warn=False。"""
        result = harness.server.check_disk_usage(
            disk_free=500 * 1024 * 1024 * 1024,
            disk_total=1000 * 1024 * 1024 * 1024)
        assert result["disk_free"] == 500 * 1024 * 1024 * 1024
        assert result["warn"] is False

    def test_check_disk_usage_warns_below_threshold(self, harness):
        """剩余比例低于阈值（默认 10%）→ warn=True。"""
        result = harness.server.check_disk_usage(
            disk_free=5 * 1024 * 1024 * 1024,
            disk_total=100 * 1024 * 1024 * 1024)
        assert result["warn"] is True, "剩余 5% < 10% 应告警"

    def test_check_disk_usage_threshold_overridable(self, harness, monkeypatch):
        """storage.disk_warning_percent 可配置。"""
        from config import config
        data = dict(config._data)
        data.setdefault("storage", {})["disk_warning_percent"] = 30
        monkeypatch.setattr(config, "_data", data)
        result = harness.server.check_disk_usage(
            disk_free=20 * 1024 * 1024 * 1024,
            disk_total=100 * 1024 * 1024 * 1024)
        assert result["warn"] is True, "剩余 20% < 30% 应告警"


# ============================================================
# M6 —— 存储治理
# ============================================================

class TestStorageCleanupProtocol:

    def _insert_old_delivered(self, harness, message_id, days=40):
        with harness.db._get_connection() as conn:
            conn.execute(
                "INSERT INTO offline_messages "
                "(message_id, sender, receiver, message_type, content, status, timestamp) "
                "VALUES (?, 'alice', 'bob', 'chat', ?, 'delivered', datetime('now', ?))",
                (message_id, b"old", f"-{days} days"))
            conn.commit()

    def _insert_old_file_request(self, harness, message_id, days=40):
        file_path = os.path.join(harness.db._pending_dir(), message_id)
        with open(file_path, "wb") as f:
            f.write(b"oldfile")
        with harness.db._get_connection() as conn:
            conn.execute(
                "INSERT INTO file_requests "
                "(message_id, sender, receiver, filename, filesize, content, "
                "file_path, status, timestamp) "
                "VALUES (?, 'alice', 'bob', 'old.txt', 7, '', ?, 'pending', "
                "datetime('now', ?))",
                (message_id, file_path, f"-{days} days"))
            conn.commit()

    def test_run_storage_cleanup_counts(self, harness):
        """run_storage_cleanup 清理两类过期数据并返回统计。"""
        _alice(harness)
        self._insert_old_delivered(harness, "old-del-1")
        self._insert_old_file_request(harness, "old-fr-1")

        result = harness.server.run_storage_cleanup()
        assert result["expired_file_requests"] == 1
        assert result["expired_delivered_messages"] == 1

        with harness.db._get_connection() as conn:
            assert conn.execute(
                "SELECT 1 FROM offline_messages WHERE message_id='old-del-1'"
            ).fetchone() is None
            assert conn.execute(
                "SELECT 1 FROM file_requests WHERE message_id='old-fr-1'"
            ).fetchone() is None
        assert not os.path.exists(
            os.path.join(harness.db._pending_dir(), "old-fr-1")), "磁盘文件应删除"

    def test_run_storage_cleanup_keeps_recent(self, harness):
        """近期数据不被清理。"""
        _alice(harness)
        harness.db.save_offline_message("alice", "bob", "chat", b"new",
                                        message_id="new-del")
        result = harness.server.run_storage_cleanup()
        assert result["expired_delivered_messages"] == 0
        assert harness.db.get_message_info("new-del") is not None

    def test_run_storage_cleanup_keeps_message_history(self, harness):
        """message_history 永久保留（9.3 契约）。"""
        _alice(harness)
        harness.db.save_message_history("alice", "bob", "chat", b"old",
                                        message_id="hist-keep")
        self._insert_old_delivered(harness, "old-del-2")
        harness.server.run_storage_cleanup()
        assert harness.db.get_history_message("hist-keep") is not None

    def test_storage_cleanup_admin_command(self, harness):
        """admin_command action=storage_cleanup → 统计回执。"""
        _alice(harness)
        self._insert_old_delivered(harness, "old-del-3")
        admin = _login(harness, "admin", "adminpass",
                       admin_secret="test-admin-secret")
        admin.send("admin_command", "", action="storage_cleanup")
        h, d = admin.expect("admin_response", timeout=3)
        assert h.get("response_type") == "storage_cleanup"
        result = json.loads(d.decode())
        assert result["expired_delivered_messages"] == 1

    def test_storage_cleanup_rejects_non_admin(self, harness):
        """非管理员 → error。"""
        alice = _alice(harness)
        alice.send("admin_command", "", action="storage_cleanup")
        h, d = alice.expect("error", timeout=3)
        assert "无管理员权限" in d.decode()


# ============================================================
# M8 —— 文件 SHA-256 校验（P1-5）
# ============================================================

class TestFileSha256Protocol:

    def _sha256(self, content):
        return hashlib.sha256(content).hexdigest()

    def test_file_with_sha256_stored_and_pushed(self, harness):
        """带 sha256 的小文件 → 落库 + file_request 推送头带 sha256。"""
        alice = _alice(harness)
        bob = _bob(harness)
        payload = b"hello sha256"
        digest = self._sha256(payload)

        alice.send("file", payload, to="bob", filename="sha.txt",
                   filesize=str(len(payload)), message_id="m-sha-1",
                   sha256=digest)
        h, d = bob.expect("file_request", timeout=3)
        assert h.get("message_id") == "m-sha-1"
        assert h.get("sha256") == digest, f"推送应携带 sha256: {h}"

        extras = harness.db.get_file_request_extras("m-sha-1")
        assert extras is not None and extras["sha256"] == digest

    def test_file_sha256_mismatch_rejected(self, harness):
        """sha256 与内容不符 → error + 不建请求 + 磁盘文件删除。"""
        alice = _alice(harness)
        bob = _bob(harness)
        payload = b"hello sha256"
        wrong = self._sha256(b"other content")

        alice.send("file", payload, to="bob", filename="sha.txt",
                   filesize=str(len(payload)), message_id="m-sha-2",
                   sha256=wrong)
        h, d = alice.expect("error", timeout=3)
        assert "SHA-256" in d.decode() or "校验失败" in d.decode(), \
            f"校验失败应报错: {d.decode()}"

        assert harness.db.get_file_request("m-sha-2") is None, "不应建立文件请求"
        pending = os.path.join(harness.db._pending_dir(), "m-sha-2")
        assert not os.path.exists(pending), "校验失败的文件应删除"

        # 接收方不受影响（未收到请求）
        h, d = bob.recv(timeout=0.5)
        assert h is None, f"接收方不应收到请求: {h}"

    def test_file_without_sha256_backward_compatible(self, harness):
        """不带 sha256 → 正常流程（向后兼容）。"""
        alice = _alice(harness)
        bob = _bob(harness)
        alice.send("file", b"plain", to="bob", filename="plain.txt",
                   filesize="5", message_id="m-sha-3")
        h, d = bob.expect("file_request", timeout=3)
        assert h.get("message_id") == "m-sha-3"
        extras = harness.db.get_file_request_extras("m-sha-3")
        assert extras is not None and not extras["sha256"]

    def test_file_accept_push_carries_sha256(self, harness):
        """接受文件后推送的 file 消息头带 sha256（接收方校验依据）。"""
        alice = _alice(harness)
        bob = _bob(harness)
        payload = b"accept me"
        digest = self._sha256(payload)
        alice.send("file", payload, to="bob", filename="sha.txt",
                   filesize=str(len(payload)), message_id="m-sha-4",
                   sha256=digest)
        h, d = bob.expect("file_request", timeout=3)
        bob.send("file_response", "", message_id="m-sha-4",
                 response="accept", to="alice")
        h, d = bob.expect("file", timeout=3)
        assert h.get("sha256") == digest, f"接受后的 file 应携带 sha256: {h}"
        assert d == payload

    def test_group_file_sha256(self, harness):
        """群组文件同样落库与推送 sha256。"""
        alice = _alice(harness)
        bob = _bob(harness)
        gid = harness.db.create_group("开发组", "alice")
        harness.db.join_group(gid, "bob")
        bob.drain(timeout=0.5)

        payload = b"group sha"
        digest = self._sha256(payload)
        alice.send("file", payload, to=f"group_{gid}", filename="g.txt",
                   filesize=str(len(payload)), message_id="m-gsha-1",
                   sha256=digest)
        h, d = bob.expect("group_file_request", timeout=3)
        assert h.get("sha256") == digest, f"群文件请求应携带 sha256: {h}"
        extras = harness.db.get_group_file_request_extras("m-gsha-1")
        assert extras is not None and extras["sha256"] == digest

        bob.send("group_file_response", "", message_id="m-gsha-1",
                 response="accept", group_id=str(gid))
        h, d = bob.expect("file", timeout=3)
        assert h.get("sha256") == digest
        assert d == payload

    def test_large_file_sha256_passthrough(self, harness, monkeypatch):
        """大文件直传：不校验，sha256 头透传接收方。"""
        _set_large_file_threshold(monkeypatch, 1024 * 1024)
        _set_max_file_size(monkeypatch, 8 * 1024 * 1024)
        alice = _alice(harness)
        bob = _bob(harness)

        payload = os.urandom(2 * 1024 * 1024)
        digest = self._sha256(payload)
        alice.send("file_transfer_check", "", to="bob",
                   filesize=str(len(payload)), filename="big.bin",
                   message_id="m-bigsha-1")
        h, d = alice.expect("file_check_response", timeout=3)
        assert h.get("ok") == "1"

        alice.send("file", payload, to="bob", filename="big.bin",
                   filesize=str(len(payload)), message_id="m-bigsha-1",
                   sha256=digest)
        h, d = bob.expect("file", timeout=5)
        assert h.get("sha256") == digest, f"直传应透传 sha256: {h}"
        assert d == payload


# ============================================================
# M8 —— 断点续传（P1-6）
# ============================================================

class TestUploadResumeProtocol:

    def test_upload_resume_appends_to_partial(self, harness):
        """offset 续传：服务器在已有部分文件上追加，接受后内容完整。"""
        alice = _alice(harness)
        bob = _bob(harness)
        partial = os.path.join(harness.db._pending_dir(), "m-resume-1")
        with open(partial, "wb") as f:
            f.write(b"abc")

        alice.send("file", b"def", to="bob", filename="r.txt",
                   filesize="6", message_id="m-resume-1", offset="3")
        h, d = bob.expect("file_request", timeout=3)
        assert h.get("message_id") == "m-resume-1"
        with open(partial, "rb") as f:
            assert f.read() == b"abcdef", "续传应追加而非覆盖"

        # 接受后接收方得到完整拼接内容
        bob.send("file_response", "", message_id="m-resume-1",
                 response="accept", to="alice")
        h, d = bob.expect("file", timeout=3)
        assert d == b"abcdef", f"接受后应收到完整文件: {d}"

    def test_upload_resume_offset_mismatch(self, harness):
        """已有部分大小与 offset 不符 → error + 不建请求。"""
        alice = _alice(harness)
        bob = _bob(harness)
        partial = os.path.join(harness.db._pending_dir(), "m-resume-2")
        with open(partial, "wb") as f:
            f.write(b"ab")

        alice.send("file", b"def", to="bob", filename="r.txt",
                   filesize="6", message_id="m-resume-2", offset="3")
        h, d = alice.expect("error", timeout=3)
        assert "续传偏移" in d.decode(), f"偏移不匹配应报错: {d.decode()}"
        assert harness.db.get_file_request("m-resume-2") is None
        with open(partial, "rb") as f:
            assert f.read() == b"ab", "偏移不匹配时不得破坏已有数据"

    def test_upload_offset_zero_overwrites(self, harness):
        """offset=0 或缺省 → 从头覆盖接收（既有语义）。"""
        alice = _alice(harness)
        bob = _bob(harness)
        partial = os.path.join(harness.db._pending_dir(), "m-resume-3")
        with open(partial, "wb") as f:
            f.write(b"stale")

        alice.send("file", b"new", to="bob", filename="r.txt",
                   filesize="3", message_id="m-resume-3", offset="0")
        h, d = bob.expect("file_request", timeout=3)
        with open(partial, "rb") as f:
            assert f.read() == b"new", "offset=0 应从头覆盖"

    def test_upload_resume_without_offset_still_works(self, harness):
        """无 offset 头 → 正常接收（向后兼容）。"""
        alice = _alice(harness)
        bob = _bob(harness)
        alice.send("file", b"plain", to="bob", filename="r.txt",
                   filesize="5", message_id="m-resume-4")
        h, d = bob.expect("file_request", timeout=3)
        assert h.get("message_id") == "m-resume-4"


class TestDownloadResumeProtocol:

    def _save_accepted_file(self, harness, message_id, sender, receiver,
                            filename, content):
        """模拟已接受的文件：history 区落盘 + message_history file 行。"""
        file_path = os.path.join(harness.db._history_dir(), message_id)
        with open(file_path, "wb") as f:
            f.write(content)
        harness.db.save_message_history(
            sender, receiver, "file", b"", filename=filename,
            message_id=message_id, file_path=file_path)
        return file_path

    def test_file_resume_sends_tail(self, harness):
        """file_resume → 从 offset 起的剩余部分 + 头带 offset。"""
        alice = _alice(harness)
        bob = _bob(harness)
        self._save_accepted_file(harness, "m-dl-1", "alice", "bob",
                                 "big.bin", b"abcdef")

        bob.send("file_resume", "", message_id="m-dl-1", offset="3")
        h, d = bob.expect("file", timeout=3)
        assert h.get("message_id") == "m-dl-1"
        assert h.get("offset") == "3", f"应携带 offset: {h}"
        assert h.get("from") == "alice"
        assert h.get("filename") == "big.bin"
        assert h.get("filesize") == "6"
        assert d == b"def", f"应返回剩余部分: {d}"

    def test_file_resume_full_offset(self, harness):
        """offset=0 → 返回完整文件。"""
        alice = _alice(harness)
        bob = _bob(harness)
        self._save_accepted_file(harness, "m-dl-2", "alice", "bob",
                                 "big.bin", b"abcdef")
        bob.send("file_resume", "", message_id="m-dl-2", offset="0")
        h, d = bob.expect("file", timeout=3)
        assert h.get("offset") == "0"
        assert d == b"abcdef"

    def test_file_resume_nonexistent(self, harness):
        """文件不存在 → error。"""
        alice = _alice(harness)
        bob = _bob(harness)
        bob.send("file_resume", "", message_id="m-ghost", offset="3")
        h, d = bob.expect("error", timeout=3)
        assert "不存在" in d.decode() or "过期" in d.decode()

    def test_file_resume_offset_beyond_size(self, harness):
        """offset >= filesize → error。"""
        alice = _alice(harness)
        bob = _bob(harness)
        self._save_accepted_file(harness, "m-dl-3", "alice", "bob",
                                 "big.bin", b"abcdef")
        bob.send("file_resume", "", message_id="m-dl-3", offset="99")
        h, d = bob.expect("error", timeout=3)
        assert "超出文件大小" in d.decode() or "偏移" in d.decode()

    def test_file_resume_rejects_non_receiver(self, harness):
        """非接收方请求续传 → error。"""
        alice = _alice(harness)
        bob = _bob(harness)
        self._save_accepted_file(harness, "m-dl-4", "alice", "bob",
                                 "big.bin", b"abcdef")
        alice.send("file_resume", "", message_id="m-dl-4", offset="3")
        h, d = alice.expect("error", timeout=3)
        assert "无权限" in d.decode() or "接收" in d.decode()

    def test_file_resume_missing_disk_file(self, harness):
        """file_path 已删（磁盘文件不存在）→ error。"""
        alice = _alice(harness)
        bob = _bob(harness)
        harness.db.save_message_history(
            "alice", "bob", "file", b"", filename="gone.bin",
            message_id="m-dl-5",
            file_path=os.path.join(harness.db._history_dir(), "gone.bin"))
        bob.send("file_resume", "", message_id="m-dl-5", offset="3")
        h, d = bob.expect("error", timeout=3)
        assert "不存在" in d.decode() or "过期" in d.decode()


# ============================================================
# M8 —— 文件收发管理页（P1-7）
# ============================================================

class TestFileListProtocol:

    def _seed_files(self, harness, tmp_path):
        p1 = os.path.join(harness.db._history_dir(), "fl-1")
        with open(p1, "wb") as f:
            f.write(b"11111")
        harness.db.save_message_history("alice", "bob", "file", b"",
                                        filename="a.txt", message_id="fl-1",
                                        file_path=p1)
        p2 = os.path.join(harness.db._history_dir(), "fl-2")
        with open(p2, "wb") as f:
            f.write(b"2222222")
        harness.db.save_message_history("bob", "alice", "file", b"",
                                        filename="b.txt", message_id="fl-2",
                                        file_path=p2)
        gid = harness.db.create_group("开发组", "alice")
        harness.db.join_group(gid, "bob")
        p3 = os.path.join(harness.db._history_dir(), "fl-3")
        with open(p3, "wb") as f:
            f.write(b"333")
        harness.db.save_message_history("alice", "", "file", b"",
                                        filename="g.txt", message_id="fl-3",
                                        group_id=gid, file_path=p3)
        return gid

    def test_list_files_global_scope(self, harness, tmp_path):
        """list_files 缺省 → 该用户参与的全部文件消息。"""
        alice = _alice(harness)
        bob = _bob(harness)
        self._seed_files(harness, tmp_path)

        alice.send("list_files", "")
        h, d = alice.expect("file_list_response", timeout=3)
        files = json.loads(d.decode())
        by_id = {f["message_id"]: f for f in files}
        assert set(by_id) == {"fl-1", "fl-2", "fl-3"}
        assert by_id["fl-1"]["filename"] == "a.txt"
        assert by_id["fl-1"]["filesize"] == 5
        assert by_id["fl-1"]["sender"] == "alice"
        assert by_id["fl-1"]["receiver"] == "bob"
        assert by_id["fl-3"]["group_id"] is not None, "群文件应携带 group_id"

    def test_list_files_private_scope(self, harness, tmp_path):
        """list_files 带 to → 仅该私聊会话的文件。"""
        alice = _alice(harness)
        bob = _bob(harness)
        self._seed_files(harness, tmp_path)

        alice.send("list_files", "", to="bob")
        h, d = alice.expect("file_list_response", timeout=3)
        files = json.loads(d.decode())
        assert {f["message_id"] for f in files} == {"fl-1", "fl-2"}

    def test_list_files_group_scope(self, harness, tmp_path):
        """list_files 带 group_id → 仅该群的文件。"""
        alice = _alice(harness)
        bob = _bob(harness)
        gid = self._seed_files(harness, tmp_path)

        bob.send("list_files", "", group_id=str(gid))
        h, d = bob.expect("file_list_response", timeout=3)
        files = json.loads(d.decode())
        assert {f["message_id"] for f in files} == {"fl-3"}

    def test_list_files_empty(self, harness):
        """无文件 → 空数组。"""
        alice = _alice(harness)
        bob = _bob(harness)
        alice.send("list_files", "")
        h, d = alice.expect("file_list_response", timeout=3)
        assert json.loads(d.decode()) == []


# ============================================================
# M2 —— join_group 申请制（2026-08-25 用户决策修订）
# ============================================================

class TestJoinGroupApprovalMode:
    """输入群组 ID 加入（join_group）改为申请制：必须经群主审批。"""

    def test_join_group_creates_request_not_direct_join(self, harness):
        """join_group 现在创建申请：申请者确认 + 群主通知 + 不直接入群。"""
        alice, bob, carol, gid = _group_setup(harness, with_bob=False)
        carol = _carol(harness)

        carol.send("join_group", str(gid))
        h, d = carol.expect("chat", timeout=3)
        assert "已发送入群申请" in d.decode(), f"申请者确认: {d.decode()}"

        h, d = alice.expect("chat", timeout=3)
        assert h.get("from") == "系统" and "carol 请求加入群组" in d.decode(), \
            f"群主通知: {d.decode()}"

        assert harness.db.has_pending_group_join_request(gid, "carol")
        assert not harness.db.is_group_member(gid, "carol"), \
            "申请制下不得直接入群（P-11 缺陷修复）"

    def test_join_group_already_member_rejected(self, harness):
        """已是成员 → error。"""
        alice, bob, carol, gid = _group_setup(harness)
        bob.send("join_group", str(gid))
        h, d = bob.expect("error", timeout=3)
        assert "已在群组" in d.decode()

    def test_join_group_nonexistent_rejected(self, harness):
        """群不存在 → error。"""
        alice, bob, carol, gid = _group_setup(harness, with_bob=False)
        carol = _carol(harness)
        carol.send("join_group", "9999")
        h, d = carol.expect("error", timeout=3)
        assert "不存在" in d.decode()

    def test_join_group_invalid_id_rejected(self, harness):
        """无效群组 ID → error。"""
        alice, bob, carol, gid = _group_setup(harness, with_bob=False)
        carol = _carol(harness)
        carol.send("join_group", "not-a-number")
        h, d = carol.expect("error", timeout=3)
        assert "无效" in d.decode()

    def test_join_group_duplicate_request(self, harness):
        """重复申请 → error。"""
        alice, bob, carol, gid = _group_setup(harness, with_bob=False)
        carol = _carol(harness)
        carol.send("join_group", str(gid))
        carol.expect("chat", timeout=3)
        alice.drain(timeout=0.5)
        carol.send("join_group", str(gid))
        h, d = carol.expect("error", timeout=3)
        assert "已发送" in d.decode()

    def test_join_group_then_approve_joins(self, harness):
        """申请后群主批准 → 入群（申请制完整链路）。"""
        alice, bob, carol, gid = _group_setup(harness, with_bob=False)
        carol = _carol(harness)
        carol.send("join_group", str(gid))
        carol.expect("chat", timeout=3)
        alice.drain(timeout=0.5)

        alice.send("approve_join_request", "", group_id=str(gid), target="carol")
        h, d = alice.expect("chat", timeout=3)
        assert "已批准 carol 加入群组" in d.decode()
        assert harness.db.is_group_member(gid, "carol"), "批准后应入群"


# ============================================================
# M2 —— 群组搜索（2026-08-25 用户反馈：群组搜索入口）
# ============================================================

class TestGroupSearchProtocol:

    def test_search_groups_by_keyword(self, harness):
        """按群名模糊搜索 → 返回群组信息（含群主/人数）。"""
        alice, bob, carol, gid = _group_setup(harness)
        harness.db.create_group("项目组", "alice")
        harness.db.join_group(gid, "carol")

        # 搜索者为非成员（dave 未加入任何群）
        dave = _login(harness, "dave", "pass1234")
        dave.send("search_groups", "", keyword="开发")
        h, d = dave.expect("group_search_response", timeout=3)
        results = json.loads(d.decode())
        assert len(results) == 1, f"应只命中开发组: {results}"
        target = results[0]
        assert target["group_name"] == "开发组"
        assert target["created_by"] == "alice"
        assert target["member_count"] == 3  # alice + bob + carol

    def test_search_groups_excludes_joined(self, harness):
        """自己已加入的群不出现在搜索结果（搜索目的是申请加入）。"""
        alice, bob, carol, gid = _group_setup(harness)
        harness.db.create_group("项目组", "alice")

        bob.send("search_groups", "", keyword="组")
        h, d = bob.expect("group_search_response", timeout=3)
        results = json.loads(d.decode())
        names = {r["group_name"] for r in results}
        assert names == {"项目组"}, f"bob 已加入的开发组应被排除: {names}"

    def test_search_groups_no_results(self, harness):
        """无匹配 → 空数组。"""
        alice, bob, carol, gid = _group_setup(harness)
        bob.send("search_groups", "", keyword="不存在的群")
        h, d = bob.expect("group_search_response", timeout=3)
        assert json.loads(d.decode()) == []

    def test_search_groups_empty_keyword_rejected(self, harness):
        """空关键字 → error。"""
        alice, bob, carol, gid = _group_setup(harness)
        bob.send("search_groups", "", keyword="")
        h, d = bob.expect("error", timeout=3)
        assert "关键字" in d.decode()


# ============================================================
# M2 —— 待审批申请列表（群管理对话框数据源）
# ============================================================

class TestListJoinRequestsProtocol:

    def test_list_join_requests_owner(self, harness):
        """群主拉取待审批申请列表。"""
        alice, bob, carol, gid = _group_setup(harness, with_bob=False)
        carol = _carol(harness)
        carol.send("request_join_group", str(gid))
        carol.expect("chat", timeout=3)
        alice.drain(timeout=0.5)

        alice.send("list_join_requests", "", group_id=str(gid))
        h, d = alice.expect("admin_response", timeout=3)
        assert h.get("response_type") == "list_join_requests"
        assert json.loads(d.decode()) == [{"username": "carol", "message": ""}]

    def test_list_join_requests_empty(self, harness):
        """无待审批申请 → 空数组。"""
        alice, bob, carol, gid = _group_setup(harness)
        alice.send("list_join_requests", "", group_id=str(gid))
        h, d = alice.expect("admin_response", timeout=3)
        assert h.get("response_type") == "list_join_requests"
        assert json.loads(d.decode()) == []

    def test_list_join_requests_non_owner_rejected(self, harness):
        """非群主拉取 → error。"""
        alice, bob, carol, gid = _group_setup(harness, with_bob=False)
        carol = _carol(harness)
        carol.send("list_join_requests", "", group_id=str(gid))
        h, d = carol.expect("error", timeout=3)
        assert "群主" in d.decode()

    def test_list_join_requests_nonexistent_group(self, harness):
        """群不存在 → error。"""
        alice, bob, carol, gid = _group_setup(harness)
        alice.send("list_join_requests", "", group_id="9999")
        h, d = alice.expect("error", timeout=3)
        assert "不存在" in d.decode()


# ============================================================
# M2 —— 申请验证消息（2026-08-25 用户反馈）+ 邀请离线补发
# ============================================================

class TestJoinRequestMessageProtocol:

    def test_request_join_with_message_notifies_owner(self, harness):
        """申请携带验证消息 → 群主通知含消息 + 落库 + 审批列表可见。"""
        alice, bob, carol, gid = _group_setup(harness, with_bob=False)
        carol = _carol(harness)

        carol.send("request_join_group", str(gid), message="我是 carol，请批准")
        h, d = carol.expect("chat", timeout=3)
        assert "已发送入群申请" in d.decode()

        h, d = alice.expect("chat", timeout=3)
        assert "我是 carol，请批准" in d.decode(), f"群主通知应含验证消息: {d.decode()}"

        # 落库 + 审批列表返回消息
        with harness.db._get_connection() as conn:
            row = conn.execute(
                "SELECT request_message FROM group_join_requests "
                "WHERE group_id = ? AND username = 'carol'", (gid,)).fetchone()
        assert row and row[0] == "我是 carol，请批准"

        alice.send("list_join_requests", "", group_id=str(gid))
        h, d = alice.expect("admin_response", timeout=3)
        assert json.loads(d.decode()) == [{"username": "carol", "message": "我是 carol，请批准"}]

    def test_request_join_without_message(self, harness):
        """不带验证消息 → 消息为空串（向后兼容）。"""
        alice, bob, carol, gid = _group_setup(harness, with_bob=False)
        carol = _carol(harness)
        carol.send("request_join_group", str(gid))
        carol.expect("chat", timeout=3)
        alice.drain(timeout=0.5)
        alice.send("list_join_requests", "", group_id=str(gid))
        h, d = alice.expect("admin_response", timeout=3)
        assert json.loads(d.decode()) == [{"username": "carol", "message": ""}]

    def test_join_group_with_message_uses_same_flow(self, harness):
        """join_group（输入 ID 申请）同样支持验证消息。"""
        alice, bob, carol, gid = _group_setup(harness, with_bob=False)
        carol = _carol(harness)
        carol.send("join_group", str(gid), message="通过 ID 申请")
        carol.expect("chat", timeout=3)
        h, d = alice.expect("chat", timeout=3)
        assert "通过 ID 申请" in d.decode(), f"群主通知应含验证消息: {d.decode()}"


class TestInviteOfflineReplay:

    def test_offline_invite_replayed_on_login(self, harness):
        """离线邀请在登录时补发 group_invite（邀请入口保留，P-11 用户反馈）。"""
        alice = _alice(harness)
        gid = harness.db.create_group("开发组", "alice")
        harness.add_user("bob", "password456")
        harness.db.join_group(gid, "bob")
        harness.add_user("carol", "password789")

        alice.send("invite_group_member", "", group_id=str(gid), target="carol")
        alice.expect("chat", timeout=3)

        carol = _login(harness, "carol", "password789", consume=False)
        data = carol.recv_initial()
        invites = [h for h, _ in data["extra"] if h.get("type") == "group_invite"]
        assert len(invites) == 1, f"登录应补发 group_invite: {data['extra']}"
        assert invites[0].get("from") == "alice"
        assert invites[0].get("group_id") == str(gid)
        assert invites[0].get("group_name") == "开发组"

    def test_invite_offline_not_saved_as_chat_text(self, harness):
        """离线邀请不再保存为系统文本通知（避免与入口重复）。"""
        alice = _alice(harness)
        gid = harness.db.create_group("开发组", "alice")
        harness.add_user("bob", "password456")

        alice.send("invite_group_member", "", group_id=str(gid), target="bob")
        alice.expect("chat", timeout=3)

        bob = _login(harness, "bob", "password456", consume=False)
        data = bob.recv_initial()
        texts = [x[1].decode() for x in data["offline"]]
        assert not any("邀请您加入群组" in t for t in texts), \
            f"离线邀请不应再以文本通知形式保存: {texts}"
        # 入口保留：group_invite 补发
        invites = [h for h, _ in data["extra"] if h.get("type") == "group_invite"]
        assert len(invites) == 1

    def test_accepted_invite_not_replayed(self, harness):
        """已接受的邀请不再补发（邀请行已删除）。"""
        alice = _alice(harness)
        gid = harness.db.create_group("开发组", "alice")
        harness.add_user("bob", "password456")
        harness.db.invite_group_member(gid, "alice", "bob")
        harness.db.accept_group_invite(gid, "bob")

        bob = _login(harness, "bob", "password456", consume=False)
        data = bob.recv_initial()
        invites = [h for h, _ in data["extra"] if h.get("type") == "group_invite"]
        assert invites == [], f"已接受邀请不应补发: {data['extra']}"
