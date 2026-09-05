"""
============================================================
阶段 O —— 群组与消息增强：服务端协议层 TDD 契约测试（规划中，全部红）
============================================================

【目标】
  按《软件开发文档4.1.0.md》§13.9 阶段 O 编写服务端协议契约测试：

    O1（用户已规划 群公告）：  set_group_announcement + 全员推送 +
                              离线补发（复用公告离线补发链路）+ list_groups 扩展
    O2（用户已规划 群置顶）：  pin_group_message / unpin_group_message +
                              撤回联动解除置顶 + list_groups 扩展
    O5（P2-5 定时消息）：      schedule_message / cancel_scheduled /
                              list_scheduled + Server.scheduler_scan 到期投递
    O9（P2-12 名片/位置/日程）：share_contact / share_location / schedule_card
    O8（P2-8 证书检测续期）：  Server.check_cert_expiry + server_status cert 字段
                              + admin_command action=renew_cert + 续期脚本

  数据库层契约见 test_stage_o_db.py；客户端契约见 TESTING_GUIDE_FLUTTER.md §19。

【契约（实现方需严格遵守，本测试即据此验证）】
  ----- O1 群公告 -----
  C → S: type="set_group_announcement", header {group_id, message_id?},
         body=公告文本（UTF-8；空文本 = 清除公告）
    仅群主（groups.created_by）可操作；非群主 → error 含 "群主"；
    非成员/群不存在 → error；message_id 缺省服务端生成。
  成功时序（沿用阶段 M 改名惯例：先落库再通知）：
    1) S → C 操作者: type="chat" 确认（设置 → "群公告已更新"；清除 → "群公告已清除"）
    2) S → 全体成员（**含群主**，notify_group_members 对新 type 不跳过发送者）:
           type="group_announcement", header {from: 群主, group_id, message_id},
           body=公告文本
    3) S → 全体成员: type="list_groups" 刷新（body 各群 JSON 新增
           "announcement" 字段——与 created_by/avatar 同为向后兼容新增）
  离线补发（复用公告/群聊离线补发链路）：
    - 离线成员逐人 save_offline_message(群主, 成员, "group_announcement",
      公告文本, message_id=f"{message_id}_{成员}", group_id=群ID)
    - 成员重登时经 load_offline_data 补发：header {from, group_id,
      "history": "true", message_id（剥离 "_成员" 后缀还原）, timestamp, status}
  永久历史：save_message_history(群主, "", "group_announcement", 公告文本,
      group_id=群ID, message_id=message_id)——群历史一条，fetch_history 可拉取
  审计（N7 契约延伸，群组治理敏感操作）：成功 →
    record_audit_log(群主, "group_announcement", target=群名, detail=公告文本)；
    失败（非群主等）不记录。

  ----- O2 群置顶 -----
  C → S: type="pin_group_message", header {group_id, message_id}
    仅群主；消息必须属于该群（message_history）；已撤回不可置顶。
    成功：操作者 chat 确认 "已置顶群消息" → 全体成员 list_groups 刷新
    （各群 JSON 新增 "pinned_message_id" / "pinned_preview" 字段）。
    失败（非群主/消息不属于该群/不存在/已撤回）→ error。
  C → S: type="unpin_group_message", header {group_id}
    仅群主；幂等（未置顶也成功）。成功：确认 "已取消置顶群消息" → 全员
    list_groups 刷新（pinned_* 为空字符串）。
  撤回联动：被置顶的群消息被撤回（recall）时，服务端**自动解除置顶**
    （groups.pinned_* 清空）并向全体成员广播 list_groups 刷新——
    横幅不得残留已撤回消息。

  ----- O5 定时消息 -----
  C → S: type="schedule_message", header {to=好友名 | group_id=群ID,
         schedule_at=预定时刻}, body=消息文本
    schedule_at 为 **epoch 秒**（字符串化；UTC 中立，"注意时区"以 epoch
    比较，不做本地时区换算）；必须晚于当前时间，否则 error 含 "定时时间"；
    非法数字 → error。私聊沿用 chat 权限语义（黑名单拦截 → error"拉黑"；
    非好友 → error"不是您的好友"）；群聊需成员。
    message_id 幂等（重复发送静默跳过）。
    成功：操作者 chat 确认含 "定时消息已设置"；落 scheduled_messages
    （status='pending'，不写 message_history / offline_messages——到点才投递）。
  S 内部定时器：Server.start_scheduler(interval=5.0) daemon 线程
    （build_listen 启动；测试直驱 scheduler_scan，不依赖线程）。
  Server.scheduler_scan(now=None) -> [message_id]
    - 取 db.get_due_scheduled_messages(now) 逐条投递并 mark sent，返回已投递
      message_id 列表（仿 watchdog_scan 的可测试直驱模式）
    - 私聊投递 = chat 完整路径：save_offline_message + save_message_history
      （message_id 原样）+ broadcast_to_user（header {from, message_id}）+
      在线送达标记 delivered；接收方离线 → 仅落库（无 error 给已消失的会话）
    - 群聊投递 = group_chat 完整路径：save_message_history(group_id) 一条 +
      离线成员副本（message_id=f"{id}_{成员}", group_id）+
      notify_group_members 群推送（跳过发送者）
  C → S: type="cancel_scheduled", header {message_id}
    仅本人可取消；成功 chat 确认含 "已取消定时消息"（status→cancelled，
    到点不再投递）；非本人/不存在/已发送 → error。
  C → S: type="list_scheduled"（无消息体）
    S → C: type="scheduled_list_response", body=JSON
           [{message_id, receiver, group_id, content, schedule_at, status}, ...]
    - 仅返回**自己**的 pending 定时消息，按 schedule_at 升序

  ----- O9 名片/位置/日程卡片 -----
  三种卡片消息均**复用私聊/群聊管道**，消息体为 JSON 文本（卡片数据随
  content 落库，历史/离线补发天然可恢复）：
    C → S: type="share_contact",   header {to|group_id, message_id},
           body=JSON {"username": "被分享人"}
    C → S: type="share_location",  header {to|group_id, message_id},
           body=JSON {"lat": 39.9, "lng": 116.4, "label": "公司附近"}
    C → S: type="schedule_card",   header {to|group_id, message_id},
           body=JSON {"title": "周会", "schedule_at": <epoch 秒>,
                      "note": "带笔记本"}
  校验（失败 → error）：
    - body 非法 JSON → error
    - share_contact：username 不存在 → error 含 "用户不存在"
    - share_location：缺 lat/lng 或非数字 → error
    - schedule_card：缺 title 或 schedule_at 非数字 → error
    - 私聊权限与 chat 一致（黑名单/非好友）；群聊需成员；
      message_id 幂等
  存储与推送（与 chat/group_chat 同构）：
    - 私聊：save_offline_message + save_message_history（message_type=卡片
      type，content=JSON 原文）+ broadcast_to_user（header {from, message_id}）
    - 群聊：历史一条 + 离线成员副本（group_id 落库，N3b 路由契约）+
      notify_group_members（**跳过发送者**，与群聊消息一致）
  客户端按 type 渲染名片/位置/日程气泡（见 TESTING_GUIDE_FLUTTER.md §19）。

  ----- O8 证书过期检测 + 一键续期 -----
  Server.check_cert_expiry(cert_path=None, now=None) -> dict
    - cert_path 缺省取 config server.ssl_cert（与 build_listen 加载点一致）
    - 返回 {"cert_path", "exists": bool, "not_after": epoch秒|None,
            "days_left": float|None, "expired": bool, "warn": bool}
    - 文件缺失/解析失败 → exists=False, expired=True, days_left=None
    - warn：days_left <= Server.CERT_WARN_DAYS（=30，类常量）
  Server.get_server_status() 新增 "cert" 键 = check_cert_expiry() 结果
    （管理面板提示数据源；admin_command action=server_status 响应 JSON
    同步携带——旧客户端忽略新字段）
  C → S(管理员): type="admin_command", header {action="renew_cert"}
    - 重新生成自签名证书并**覆写** config server.ssl_cert / server.ssl_key
      指向的文件（复用 SSL/gen_cert.py:generate_cert，days 参数化，
      默认 3650 保持向后兼容）——运行中的旧连接不受影响，新 TLS 握手
      使用新证书
    - S → C: type="admin_response", header {response_type="renew_cert"},
      body=JSON {"ok": true, "days_left": <新证书剩余天数>}
    - 非管理员 → error "无管理员权限"
  续期脚本 scripts/renew_cert.py（一键续期 CLI，部署/手动场景）：
    - 提供 renew(...) 函数（复用 gen_cert 生成流程）
    - 支持 --check（仅检查打印剩余天数）与 --days（有效期天数）参数
  测试证书生成：本文件用 cryptography 现场签发自签名证书（可指定有效期，
    含已过期），不依赖仓库内 SSL/tsetcn.* 的实际剩余有效期。

【运行】
  实现前：本文件用例全部红，属 TDD 红。实现后：全部通过。

  .venv/bin/python -m pytest tests/test_stage_o_server.py -v
"""

import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

TEST_ADMIN_SECRET = "test-admin-secret"


# ============================================================
# 测试辅助：登录 / 建群
# ============================================================

def _login(harness, username, password, admin_secret=None, device_id=None,
           consume=True):
    c = harness.client()
    c.login(username, password, admin_secret=admin_secret,
            device_id=device_id, consume=consume)
    return c


def _alice(harness):
    return _login(harness, "alice", "password123")


def _bob(harness):
    return _login(harness, "bob", "password456")


def _admin(harness):
    return _login(harness, "admin", "adminpass",
                  admin_secret=TEST_ADMIN_SECRET)


def _group_setup(harness, name="开发组", with_bob=True, with_carol=False):
    """alice 建群（群主）+ 成员入群（直接落库，不走协议），返回 (alice, bob, gid)。

    carol 同时确保账号存在（是否入群由 with_carol 控制）。
    """
    alice = _alice(harness)
    if not harness.db.user_exists("bob"):
        harness.add_user("bob", "password456")
    if not harness.db.user_exists("carol"):
        harness.add_user("carol", "password789")
    gid = harness.db.create_group(name, "alice")
    if with_bob:
        harness.db.join_group(gid, "bob")
    if with_carol:
        harness.db.join_group(gid, "carol")
    bob = _bob(harness)
    bob.drain(timeout=0.5)
    return alice, bob, gid


def _groups_in_push(header, data, gid):
    """从 list_groups 推送 body 中取指定群的 JSON dict。"""
    groups = json.loads(data.decode())
    return next(g for g in groups if g["id"] == gid)


# ============================================================
# 测试辅助：现场签发自签名证书（O8，可指定有效期）
# ============================================================

def _write_cert(tmp_path, name, days, common_name="tset.cn"):
    """生成自签名证书 + 私钥，返回 (cert_path, key_path)。

    days < 0 表示已过期（not_valid_after 在过去）。
    """
    import datetime

    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = x509.Name(
        [x509.NameAttribute(NameOID.COMMON_NAME, common_name)])
    now = datetime.datetime.now(datetime.timezone.utc)
    not_before = now - datetime.timedelta(days=2) if days < 0 else now
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(not_before)
        .not_valid_after(now + datetime.timedelta(days=days))
        .sign(key, hashes.SHA256())
    )
    cert_path = str(tmp_path / f"{name}.crt")
    key_path = str(tmp_path / f"{name}.key")
    with open(cert_path, "wb") as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))
    with open(key_path, "wb") as f:
        f.write(key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.TraditionalOpenSSL,
            serialization.NoEncryption()))
    return cert_path, key_path


# ============================================================
# O1 —— 群公告：set_group_announcement
# ============================================================

class TestGroupAnnouncementO1:

    def test_owner_sets_announcement_full_chain(self, harness):
        """群主设置公告 → 确认 + 全员推送（含群主）+ 全员 list_groups 刷新。"""
        alice, bob, gid = _group_setup(harness, name="公告组")
        alice.drain(timeout=0.5)

        alice.send("set_group_announcement", "周五 18:00 团建",
                   group_id=str(gid), message_id="o1-ann-1")

        # 1) 操作者确认
        h, d = alice.expect("chat", timeout=3)
        assert "群公告已更新" in d.decode(), f"操作者确认: {d.decode()}"

        # 2) 群主自己的推送（notify_group_members 对新 type 不跳过发送者）
        h, d = alice.expect("group_announcement", timeout=3)
        assert h.get("group_id") == str(gid), f"group_id 头: {h}"
        assert h.get("from") == "alice", f"from 头: {h}"
        assert h.get("message_id") == "o1-ann-1", f"message_id 头: {h}"
        assert d.decode() == "周五 18:00 团建"

        # 3) 群主 list_groups 刷新（announcement 字段）
        h, d = alice.expect("list_groups", timeout=3)
        g = _groups_in_push(h, d, gid)
        assert g.get("announcement") == "周五 18:00 团建", \
            f"list_groups 应携带 announcement: {g}"

        # 成员侧：group_announcement → list_groups
        h, d = bob.expect("group_announcement", timeout=3)
        assert h.get("from") == "alice" and h.get("group_id") == str(gid)
        assert d.decode() == "周五 18:00 团建"
        h, d = bob.expect("list_groups", timeout=3)
        g = _groups_in_push(h, d, gid)
        assert g.get("announcement") == "周五 18:00 团建"

    def test_non_owner_rejected(self, harness):
        """非群主成员设置 → error 含 '群主'，不产生推送。"""
        alice, bob, gid = _group_setup(harness, name="公告组")
        alice.drain(timeout=0.5)

        bob.send("set_group_announcement", "篡改的公告",
                 group_id=str(gid), message_id="o1-ann-bad")
        h, d = bob.expect("error", timeout=3)
        assert "群主" in d.decode(), f"拒绝理由: {d.decode()}"
        # 群主收不到任何推送
        h, d = alice.recv(timeout=0.6)
        assert h is None, f"非群主设置不应触发推送: {h}"

    def test_non_member_rejected(self, harness):
        """非成员设置 → error。"""
        alice, bob, gid = _group_setup(harness, name="公告组", with_bob=False)
        alice.drain(timeout=0.5)
        carol = _login(harness, "carol", "password789")
        carol.drain(timeout=0.5)

        carol.send("set_group_announcement", "路人公告",
                   group_id=str(gid), message_id="o1-ann-out")
        h, d = carol.expect("error", timeout=3)
        assert d.decode(), "非成员应收到 error"

    def test_missing_group_rejected(self, harness):
        """群不存在 → error。"""
        alice, _, _ = _group_setup(harness, with_bob=False)
        alice.drain(timeout=0.5)

        alice.send("set_group_announcement", "幽灵公告",
                   group_id="9999", message_id="o1-ann-ghost")
        h, d = alice.expect("error", timeout=3)
        assert d.decode(), "群不存在应收到 error"

    def test_empty_text_clears_announcement(self, harness):
        """空文本 = 清除公告：确认 '群公告已清除' + 推送空文本 + 刷新为空。"""
        alice, bob, gid = _group_setup(harness, name="公告组")
        alice.drain(timeout=0.5)
        alice.send("set_group_announcement", "临时公告",
                   group_id=str(gid), message_id="o1-ann-set")
        alice.expect("chat", timeout=3)
        alice.expect("group_announcement", timeout=3)
        alice.expect("list_groups", timeout=3)
        bob.expect("group_announcement", timeout=3)
        bob.expect("list_groups", timeout=3)

        alice.send("set_group_announcement", "",
                   group_id=str(gid), message_id="o1-ann-clear")
        h, d = alice.expect("chat", timeout=3)
        assert "群公告已清除" in d.decode(), f"清除确认: {d.decode()}"
        h, d = alice.expect("group_announcement", timeout=3)
        assert d.decode() == "", "清除推送内容应为空"
        h, d = alice.expect("list_groups", timeout=3)
        g = _groups_in_push(h, d, gid)
        assert g.get("announcement") == "", "刷新后公告应为空"

    def test_offline_member_republish_on_relogin(self, harness):
        """离线成员重登 → 补发 group_announcement（history=true + group_id 头）。"""
        alice, bob, gid = _group_setup(harness, name="公告组", with_carol=True)
        harness.db.join_group(gid, "carol")
        alice.drain(timeout=0.5)

        # bob 下线，公告发布
        bob.close()
        time.sleep(0.3)
        alice.send("set_group_announcement", "离线也能看到",
                   group_id=str(gid), message_id="o1-ann-off")
        alice.expect("chat", timeout=3)
        alice.expect("group_announcement", timeout=3)
        alice.expect("list_groups", timeout=3)

        # bob 重登：离线补发走 recv_initial（history=true 归入 offline 桶）
        bob2 = _login(harness, "bob", "password456", consume=False)
        initial = bob2.recv_initial()
        seen = [h for h, d in initial.get("offline", [])
                if h.get("type") == "group_announcement"]
        assert len(seen) == 1, f"应补发一条群公告: {seen}"
        h = seen[0]
        assert h.get("history") == "true", f"补发标记 history: {h}"
        assert h.get("group_id") == str(gid), f"路由 group_id 头: {h}"
        assert h.get("from") == "alice", f"from 头: {h}"
        assert h.get("message_id") == "o1-ann-off", \
            f"补发 message_id 应还原原始 id（剥离 _成员 后缀）: {h}"

        # 重登后的 list_groups 携带最新公告
        g = next((g for g in initial.get("groups", []) if g["id"] == gid), None)
        assert g and g.get("announcement") == "离线也能看到", \
            f"登录推送 list_groups 应含公告: {initial.get('groups')}"

    def test_announcement_saved_to_history_and_fetchable(self, harness):
        """公告落永久历史（group_announcement 类型）→ fetch_history 可拉取。"""
        alice, bob, gid = _group_setup(harness, name="公告组")
        alice.drain(timeout=0.5)

        alice.send("set_group_announcement", "历史里的公告",
                   group_id=str(gid), message_id="o1-ann-hist")
        alice.expect("chat", timeout=3)
        alice.expect("group_announcement", timeout=3)
        alice.expect("list_groups", timeout=3)

        alice.send("fetch_history", "", group_id=str(gid), limit="50")
        h, d = alice.expect("history_response", timeout=3)
        rows = json.loads(d.decode())
        # history_response 线上格式（既有惯例）：类型字段为 "type"
        match = [r for r in rows if r.get("type") == "group_announcement"]
        assert len(match) == 1, f"历史应含一条群公告: {rows}"
        assert "历史里的公告" in match[0]["content"]
        assert match[0].get("group_id") == gid

    def test_announcement_records_audit(self, harness):
        """设置公告成功 → 审计落库 (操作者, group_announcement, 群名, 公告文本)。"""
        alice, bob, gid = _group_setup(harness, name="公告组")
        alice.drain(timeout=0.5)

        alice.send("set_group_announcement", "审计可见的公告",
                   group_id=str(gid), message_id="o1-ann-audit")
        alice.expect("chat", timeout=3)
        alice.drain(timeout=0.5)

        logs = harness.db.get_audit_logs()
        assert any(e["operator"] == "alice"
                   and e["action"] == "group_announcement"
                   and e["target"] == "公告组"
                   and e["detail"] == "审计可见的公告" for e in logs), \
            f"应记录群公告审计: {logs}"

    def test_failed_announcement_not_recorded(self, harness):
        """非群主设置失败 → 不记录审计。"""
        alice, bob, gid = _group_setup(harness, name="公告组")
        alice.drain(timeout=0.5)

        bob.send("set_group_announcement", "失败的公告",
                 group_id=str(gid), message_id="o1-ann-fail")
        bob.expect("error", timeout=3)
        assert harness.db.get_audit_logs() == []

    def test_clear_records_audit_too(self, harness):
        """清除公告同为群组治理操作 → 落审计（detail 为空）。"""
        alice, bob, gid = _group_setup(harness, name="公告组")
        alice.drain(timeout=0.5)
        alice.send("set_group_announcement", "先设置",
                   group_id=str(gid), message_id="o1-ann-a1")
        alice.expect("chat", timeout=3)
        alice.drain(timeout=0.5)

        alice.send("set_group_announcement", "",
                   group_id=str(gid), message_id="o1-ann-a2")
        alice.expect("chat", timeout=3)
        alice.drain(timeout=0.5)

        logs = harness.db.get_audit_logs()
        clears = [e for e in logs if e["action"] == "group_announcement"
                  and e["detail"] == ""]
        assert len(clears) == 1, f"清除公告应落一条 detail 为空的审计: {logs}"


# ============================================================
# O2 —— 群置顶：pin_group_message / unpin_group_message
# ============================================================

class TestGroupPinO2:

    def test_owner_pins_message_full_chain(self, harness):
        """群主置顶本群消息 → 确认 + 全员 list_groups 刷新（pinned 字段）。"""
        alice, bob, gid = _group_setup(harness, name="置顶组")
        alice.drain(timeout=0.5)

        bob.send("group_chat", "重要通知", group_id=str(gid),
                 message_id="o2-pin-1")
        h, d = alice.expect("group_chat", timeout=3)
        assert d.decode() == "重要通知"
        alice.drain(timeout=0.5)
        bob.drain(timeout=0.5)

        alice.send("pin_group_message", "", group_id=str(gid),
                   message_id="o2-pin-1")
        h, d = alice.expect("chat", timeout=3)
        assert "已置顶群消息" in d.decode(), f"置顶确认: {d.decode()}"

        # 全员 list_groups 刷新（pinned_message_id / pinned_preview / pinned_messages）
        h, d = alice.expect("list_groups", timeout=3)
        g = _groups_in_push(h, d, gid)
        assert g.get("pinned_message_id") == "o2-pin-1", \
            f"list_groups 应携带置顶消息 id: {g}"
        assert g.get("pinned_preview") == "重要通知", \
            f"list_groups 应携带置顶内容快照: {g}"
        pinned_list = g.get("pinned_messages") or []
        assert [p["message_id"] for p in pinned_list] == ["o2-pin-1"], \
            f"list_groups 应携带全量置顶列表: {g}"
        h, d = bob.expect("list_groups", timeout=3)
        g = _groups_in_push(h, d, gid)
        assert g.get("pinned_message_id") == "o2-pin-1"

    def test_non_owner_pin_rejected(self, harness):
        """非群主置顶 → error 含 '群主'。"""
        alice, bob, gid = _group_setup(harness, name="置顶组")
        alice.drain(timeout=0.5)
        bob.send("group_chat", "普通消息", group_id=str(gid),
                 message_id="o2-pin-2")
        alice.expect("group_chat", timeout=3)
        alice.drain(timeout=0.5)

        bob.send("pin_group_message", "", group_id=str(gid),
                 message_id="o2-pin-2")
        h, d = bob.expect("error", timeout=3)
        assert "群主" in d.decode(), f"拒绝理由: {d.decode()}"

    def test_pin_message_of_other_group_rejected(self, harness):
        """置顶其他群的消息 → error（消息不属于该群）。"""
        alice, bob, gid_a = _group_setup(harness, name="群A")
        gid_b = harness.db.create_group("群B", "alice")
        harness.db.join_group(gid_b, "bob")
        alice.drain(timeout=0.5)
        bob.drain(timeout=0.5)

        bob.send("group_chat", "群A的消息", group_id=str(gid_a),
                 message_id="o2-cross")
        alice.expect("group_chat", timeout=3)
        alice.drain(timeout=0.5)

        alice.send("pin_group_message", "", group_id=str(gid_b),
                   message_id="o2-cross")
        h, d = alice.expect("error", timeout=3)
        assert d.decode(), "跨群置顶应收到 error"

    def test_pin_nonexistent_message_rejected(self, harness):
        """置顶不存在的消息 → error。"""
        alice, _, gid = _group_setup(harness, with_bob=False)
        alice.drain(timeout=0.5)

        alice.send("pin_group_message", "", group_id=str(gid),
                   message_id="ghost")
        h, d = alice.expect("error", timeout=3)
        assert d.decode(), "置顶不存在的消息应收到 error"

    def test_unpin_full_chain(self, harness):
        """取消置顶 → 确认 + 全员刷新（pinned_* 清空）。"""
        alice, bob, gid = _group_setup(harness, name="置顶组")
        alice.drain(timeout=0.5)
        bob.send("group_chat", "将被取消置顶", group_id=str(gid),
                 message_id="o2-unpin")
        alice.expect("group_chat", timeout=3)
        alice.drain(timeout=0.5)
        alice.send("pin_group_message", "", group_id=str(gid),
                   message_id="o2-unpin")
        alice.expect("chat", timeout=3)
        alice.expect("list_groups", timeout=3)
        bob.expect("list_groups", timeout=3)

        alice.send("unpin_group_message", "", group_id=str(gid))
        h, d = alice.expect("chat", timeout=3)
        assert "已取消置顶群消息" in d.decode(), f"取消确认: {d.decode()}"
        h, d = alice.expect("list_groups", timeout=3)
        g = _groups_in_push(h, d, gid)
        assert g.get("pinned_message_id") == "", f"取消后应清空: {g}"
        h, d = bob.expect("list_groups", timeout=3)
        g = _groups_in_push(h, d, gid)
        assert g.get("pinned_message_id") == ""

    def test_unpin_non_owner_rejected(self, harness):
        """非群主取消置顶 → error 含 '群主'。"""
        alice, bob, gid = _group_setup(harness, name="置顶组")
        alice.drain(timeout=0.5)
        bob.send("group_chat", "x", group_id=str(gid), message_id="o2-u1")
        alice.expect("group_chat", timeout=3)
        alice.drain(timeout=0.5)
        alice.send("pin_group_message", "", group_id=str(gid),
                   message_id="o2-u1")
        alice.expect("chat", timeout=3)
        alice.expect("list_groups", timeout=3)
        # bob 会收到置顶引发的 list_groups 刷新，先消费再发起取消
        bob.expect("list_groups", timeout=3)

        bob.send("unpin_group_message", "", group_id=str(gid))
        h, d = bob.expect("error", timeout=3)
        assert "群主" in d.decode(), f"拒绝理由: {d.decode()}"

    def test_recall_clears_pin_and_refreshes(self, harness):
        """撤回被置顶的群消息 → 自动解除置顶 + 全员 list_groups 刷新。"""
        alice, bob, gid = _group_setup(harness, name="置顶组")
        alice.drain(timeout=0.5)
        bob.send("group_chat", "撤回我", group_id=str(gid),
                 message_id="o2-recall-pin")
        alice.expect("group_chat", timeout=3)
        alice.drain(timeout=0.5)
        alice.send("pin_group_message", "", group_id=str(gid),
                   message_id="o2-recall-pin")
        alice.expect("chat", timeout=3)
        alice.expect("list_groups", timeout=3)
        bob.expect("list_groups", timeout=3)

        # 发送者撤回被置顶的消息
        bob.send("recall", "", message_id="o2-recall-pin")
        # alice 收到撤回广播后的 list_groups 刷新：置顶已清空
        deadline = time.time() + 5
        refreshed = None
        while time.time() < deadline and refreshed is None:
            h, d = alice.recv(timeout=1)
            if h is not None and h.get("type") == "list_groups":
                g = _groups_in_push(h, d, gid)
                if g.get("pinned_message_id") == "":
                    refreshed = g
        assert refreshed is not None, \
            "撤回置顶消息后应收到置顶清空的 list_groups 刷新"
        # 落库终态：置顶两列清空
        with harness.db._get_connection() as conn:
            row = conn.execute(
                "SELECT pinned_message_id, pinned_preview FROM groups "
                "WHERE id = ?", (gid,)).fetchone()
        assert row == ("", ""), f"撤回后置顶应解除: {row}"

    def test_multi_pin_coexist_and_single_unpin(self, harness):
        """多条置顶并存（2026-08-31 用户反馈）：pin 两条并存；单条取消只移除
        该条，list_groups 携带全量 pinned_messages 列表。"""
        alice, bob, gid = _group_setup(harness, name="置顶组")
        alice.drain(timeout=0.5)
        for i, (mid, text) in enumerate(
                [("o2-multi-1", "公告补充一"), ("o2-multi-2", "公告补充二")]):
            bob.send("group_chat", text, group_id=str(gid), message_id=mid)
            alice.expect("group_chat", timeout=3)
            alice.drain(timeout=0.5)
            bob.drain(timeout=0.5)
            alice.send("pin_group_message", "", group_id=str(gid),
                       message_id=mid)
            alice.expect("chat", timeout=3)
            alice.expect("list_groups", timeout=3)
            bob.expect("list_groups", timeout=3)

        # 置顶两条并存：横幅数据源字段 pinned_messages 长度 2
        alice.send("unpin_group_message", "", group_id=str(gid),
                   message_id="o2-multi-1")
        h, d = alice.expect("chat", timeout=3)
        assert "已取消置顶群消息" in d.decode()
        h, d = alice.expect("list_groups", timeout=3)
        g = _groups_in_push(h, d, gid)
        assert [p["message_id"] for p in (g.get("pinned_messages") or [])] \
            == ["o2-multi-2"], f"单条取消后应剩一条: {g}"

        # 全部取消（不带 message_id）
        alice.send("unpin_group_message", "", group_id=str(gid))
        h, d = alice.expect("chat", timeout=3)
        assert "已取消置顶群消息" in d.decode()
        h, d = alice.expect("list_groups", timeout=3)
        g = _groups_in_push(h, d, gid)
        assert g.get("pinned_messages") == [], f"全部取消后应为空: {g}"
        assert g.get("pinned_message_id") == ""


# ============================================================
# O5 —— 定时消息：schedule_message / scheduler_scan / cancel / list
# ============================================================

class TestScheduledMessageO5:

    def test_schedule_private_message_confirmed_and_pending(self, harness):
        """私聊定时：确认 '定时消息已设置'，落 pending（不写历史/离线）。"""
        alice, bob, _ = _group_setup(harness, with_bob=True)
        # alice/bob 是好友（conftest 预置）；清掉建群噪声
        alice.drain(timeout=0.5)
        bob.drain(timeout=0.5)

        due = time.time() + 3600
        alice.send("schedule_message", "下午 3 点提醒你",
                   to="bob", schedule_at=f"{due:.6f}",
                   message_id="o5-pend-1")
        h, d = alice.expect("chat", timeout=3)
        assert "定时消息已设置" in d.decode(), f"定时确认: {d.decode()}"

        rows = harness.db.list_scheduled_messages("alice")
        assert len(rows) == 1
        assert rows[0]["message_id"] == "o5-pend-1"
        assert rows[0]["receiver"] == "bob"
        assert rows[0]["status"] == "pending"
        # 到点前不投递：无历史行、对方无离线行
        assert harness.db.get_history_message("o5-pend-1") is None
        offline_ids = [m[4] for m in harness.db.get_offline_messages("bob")]
        assert "o5-pend-1" not in offline_ids

    def test_schedule_past_time_rejected(self, harness):
        """定时时间早于当前 → error 含 '定时时间'。"""
        alice, _, _ = _group_setup(harness)
        alice.drain(timeout=0.5)

        alice.send("schedule_message", "过去的消息",
                   to="bob", schedule_at=f"{time.time() - 10:.6f}",
                   message_id="o5-past")
        h, d = alice.expect("error", timeout=3)
        assert "定时时间" in d.decode(), f"拒绝理由: {d.decode()}"

    def test_schedule_invalid_time_rejected(self, harness):
        """schedule_at 非数字 → error。"""
        alice, _, _ = _group_setup(harness)
        alice.drain(timeout=0.5)

        alice.send("schedule_message", "坏时间", to="bob",
                   schedule_at="not-a-number", message_id="o5-bad")
        h, d = alice.expect("error", timeout=3)
        assert d.decode(), "非法 schedule_at 应收到 error"

    def test_schedule_to_non_friend_rejected(self, harness):
        """非好友定时私聊 → error 含 '不是您的好友'（沿用 chat 权限语义）。"""
        alice, _, _ = _group_setup(harness)
        harness.add_user("dave", "password999")
        alice.drain(timeout=0.5)

        alice.send("schedule_message", "给陌生人",
                   to="dave", schedule_at=f"{time.time() + 60:.6f}",
                   message_id="o5-stranger")
        h, d = alice.expect("error", timeout=3)
        assert "不是您的好友" in d.decode(), f"拒绝理由: {d.decode()}"

    def test_schedule_group_message_confirmed(self, harness):
        """群定时：确认 + pending 行带 group_id。"""
        alice, bob, gid = _group_setup(harness, name="定时组")
        alice.drain(timeout=0.5)
        bob.drain(timeout=0.5)

        due = time.time() + 3600
        bob.send("schedule_message", "晚上群里发周报",
                 group_id=str(gid), schedule_at=f"{due:.6f}",
                 message_id="o5-grp-1")
        h, d = bob.expect("chat", timeout=3)
        assert "定时消息已设置" in d.decode()

        rows = harness.db.list_scheduled_messages("bob")
        assert len(rows) == 1
        assert rows[0]["group_id"] == gid
        assert rows[0]["receiver"] == ""

    def test_schedule_group_non_member_rejected(self, harness):
        """非成员定时群发 → error。"""
        alice, _, gid = _group_setup(harness, name="定时组", with_carol=True)
        carol = _login(harness, "carol", "password789")
        carol.drain(timeout=0.5)

        carol.send("schedule_message", "路人定时",
                   group_id=str(gid), schedule_at=f"{time.time() + 60:.6f}",
                   message_id="o5-outsider")
        h, d = carol.expect("error", timeout=3)
        assert d.decode(), "非成员定时群发应收到 error"

    def test_scheduler_scan_delivers_online_receiver(self, harness):
        """到点扫描（测试直驱）→ 在线接收方实时收到 chat + 历史落库 + 状态 sent。"""
        alice, bob, _ = _group_setup(harness)
        alice.drain(timeout=0.5)
        bob.drain(timeout=0.5)

        due = time.time() + 1.0
        alice.send("schedule_message", "定时提醒",
                   to="bob", schedule_at=f"{due:.6f}",
                   message_id="o5-scan-1")
        alice.expect("chat", timeout=3)
        time.sleep(1.2)

        delivered = harness.server.scheduler_scan()
        assert delivered == ["o5-scan-1"], f"应投递到点消息: {delivered}"

        # 接收方实时收到（header 同 chat 推送惯例）
        h, d = bob.expect("chat", timeout=3)
        assert h.get("from") == "alice", f"from 头: {h}"
        assert h.get("message_id") == "o5-scan-1", f"message_id 头: {h}"
        assert d.decode() == "定时提醒"

        # 永久历史落库（原 message_id）+ 定时行状态流转 + 不重复投递
        row = harness.db.get_history_message("o5-scan-1")
        assert row is not None and row["message_type"] == "chat"
        assert row["content"] == "定时提醒"
        assert harness.db.list_scheduled_messages("alice") == []
        assert harness.server.scheduler_scan() == []

    def test_scheduler_scan_offline_receiver_and_future_excluded(self, harness):
        """离线接收方 → 落离线行+历史行；未到期的不投递。"""
        alice, bob, _ = _group_setup(harness)
        alice.drain(timeout=0.5)
        bob.drain(timeout=0.5)
        bob.close()
        time.sleep(0.3)

        due_soon = time.time() + 1.0
        due_late = time.time() + 3600
        alice.send("schedule_message", "离线定时",
                   to="bob", schedule_at=f"{due_soon:.6f}",
                   message_id="o5-off-1")
        alice.expect("chat", timeout=3)
        alice.send("schedule_message", "未到期",
                   to="bob", schedule_at=f"{due_late:.6f}",
                   message_id="o5-future-1")
        alice.expect("chat", timeout=3)
        time.sleep(1.2)

        delivered = harness.server.scheduler_scan()
        assert delivered == ["o5-off-1"], f"只投递到点消息: {delivered}"

        # 离线行 + 历史行均落库（重登补发由既有链路承担）
        offline_ids = [m[4] for m in harness.db.get_offline_messages("bob")]
        assert "o5-off-1" in offline_ids
        assert harness.db.get_history_message("o5-off-1") is not None
        # 未到期的仍为 pending
        pending_ids = [r["message_id"]
                       for r in harness.db.list_scheduled_messages("alice")]
        assert pending_ids == ["o5-future-1"]

    def test_scheduler_scan_group_delivery(self, harness):
        """群定时到点 → 群聊完整路径：历史一条 + 成员推送（跳过发送者）。"""
        alice, bob, gid = _group_setup(harness, name="定时组")
        alice.drain(timeout=0.5)
        bob.drain(timeout=0.5)

        due = time.time() + 1.0
        bob.send("schedule_message", "定时群发",
                 group_id=str(gid), schedule_at=f"{due:.6f}",
                 message_id="o5-gscan")
        bob.expect("chat", timeout=3)
        time.sleep(1.2)

        delivered = harness.server.scheduler_scan()
        assert delivered == ["o5-gscan"], f"群定时应投递: {delivered}"

        # 成员（非发送者）实时收到，携带 group_id 头
        h, d = alice.expect("group_chat", timeout=3)
        assert h.get("group_id") == str(gid), f"group_id 头: {h}"
        assert h.get("message_id") == "o5-gscan", f"message_id 头: {h}"
        assert d.decode() == "定时群发"
        # 发送者收到回显（定时消息无即时本地回显，到点推送补足聊天流展示）
        h, d = bob.expect("group_chat", timeout=3)
        assert h.get("group_id") == str(gid), f"发送者回显 group_id 头: {h}"
        assert h.get("from") == "bob", f"发送者回显 from 头: {h}"
        assert d.decode() == "定时群发"
        # 历史一条（group_id 归属）
        row = harness.db.get_history_message("o5-gscan")
        assert row is not None and row["message_type"] == "group_chat"
        assert row["group_id"] == gid

    def test_cancel_scheduled_protocol(self, harness):
        """取消定时：本人确认 + 不再投递；非本人 error。"""
        alice, bob, _ = _group_setup(harness)
        alice.drain(timeout=0.5)
        bob.drain(timeout=0.5)

        due = time.time() + 3600
        alice.send("schedule_message", "会取消的", to="bob",
                   schedule_at=f"{due:.6f}", message_id="o5-cancel-1")
        alice.expect("chat", timeout=3)
        alice.send("schedule_message", "别人的", to="bob",
                   schedule_at=f"{due + 10:.6f}", message_id="o5-keep-1")
        alice.expect("chat", timeout=3)

        bob.send("cancel_scheduled", "", message_id="o5-cancel-1")
        h, d = bob.expect("error", timeout=3)
        assert d.decode(), "非本人取消应收到 error"

        alice.send("cancel_scheduled", "", message_id="o5-cancel-1")
        h, d = alice.expect("chat", timeout=3)
        assert "已取消定时消息" in d.decode(), f"取消确认: {d.decode()}"

        rows = harness.db.list_scheduled_messages("alice")
        assert [r["message_id"] for r in rows] == ["o5-keep-1"]

    def test_cancel_nonexistent_rejected(self, harness):
        """取消不存在的定时消息 → error。"""
        alice, _, _ = _group_setup(harness)
        alice.drain(timeout=0.5)

        alice.send("cancel_scheduled", "", message_id="ghost")
        h, d = alice.expect("error", timeout=3)
        assert d.decode(), "取消不存在的定时消息应收到 error"

    def test_list_scheduled_response(self, harness):
        """list_scheduled → scheduled_list_response（仅自己的 pending，升序）。"""
        alice, bob, gid = _group_setup(harness, name="定时组")
        alice.drain(timeout=0.5)
        bob.drain(timeout=0.5)

        base = time.time() + 1000
        alice.send("schedule_message", "晚的", to="bob",
                   schedule_at=f"{base + 100:.6f}", message_id="o5-l2")
        alice.expect("chat", timeout=3)
        alice.send("schedule_message", "早的", to="bob",
                   schedule_at=f"{base:.6f}", message_id="o5-l1")
        alice.expect("chat", timeout=3)
        bob.send("schedule_message", "别人的", group_id=str(gid),
                 schedule_at=f"{base + 50:.6f}", message_id="o5-l3")
        bob.expect("chat", timeout=3)

        alice.send("list_scheduled", "")
        h, d = alice.expect("scheduled_list_response", timeout=3)
        entries = json.loads(d.decode())
        assert [e["message_id"] for e in entries] == ["o5-l1", "o5-l2"], \
            f"应按 schedule_at 升序且仅含自己: {entries}"
        for e in entries:
            assert {"message_id", "receiver", "group_id", "content",
                    "schedule_at", "status"} <= set(e.keys()), \
                f"字段不齐: {e}"
            assert e["status"] == "pending"
        assert entries[0]["content"] == "早的"

        bob.send("list_scheduled", "")
        h, d = bob.expect("scheduled_list_response", timeout=3)
        entries_bob = json.loads(d.decode())
        assert [e["message_id"] for e in entries_bob] == ["o5-l3"]

    def test_schedule_idempotent_message_id(self, harness):
        """同 message_id 重复定时 → 静默跳过（不重复落库）。"""
        alice, _, _ = _group_setup(harness)
        alice.drain(timeout=0.5)

        due = time.time() + 3600
        alice.send("schedule_message", "第一次", to="bob",
                   schedule_at=f"{due:.6f}", message_id="o5-dup")
        alice.expect("chat", timeout=3)
        alice.send("schedule_message", "第二次", to="bob",
                   schedule_at=f"{due:.6f}", message_id="o5-dup")
        rows = harness.db.list_scheduled_messages("alice")
        assert len(rows) == 1 and rows[0]["content"] == "第一次"


# ============================================================
# O1 补充（2026-08-30 用户反馈 #2）—— 公告管理：查看全部公告 + 选择性删除
# ============================================================

class TestGroupAnnouncementManageO1:

    def test_list_announcements(self, harness):
        """群成员拉取公告历史（announcements_list_response，最新在前）。"""
        alice, bob, gid = _group_setup(harness, name="公告组")
        alice.drain(timeout=0.5)
        bob.drain(timeout=0.5)
        alice.send("set_group_announcement", "第一条公告",
                   group_id=str(gid), message_id="o1m-1")
        alice.expect("chat", timeout=3)
        alice.drain(timeout=0.5)
        alice.send("set_group_announcement", "第二条公告",
                   group_id=str(gid), message_id="o1m-2")
        alice.expect("chat", timeout=3)
        alice.drain(timeout=0.5)
        bob.drain(timeout=0.5)

        bob.send("list_group_announcements", "", group_id=str(gid))
        h, d = bob.expect("announcements_list_response", timeout=3)
        entries = json.loads(d.decode())
        assert len(entries) == 2, f"应有两条公告历史: {entries}"
        assert entries[0]["content"] == "第二条公告"
        assert entries[1]["content"] == "第一条公告"
        assert {"message_id", "sender", "content", "timestamp"} <= \
            set(entries[0].keys()), f"字段不齐: {entries[0]}"

    def test_list_requires_membership(self, harness):
        """非成员拉取公告历史 → error。"""
        alice, bob, gid = _group_setup(harness, name="公告组", with_carol=True)
        carol = _login(harness, "carol", "password789")
        carol.drain(timeout=0.5)

        carol.send("list_group_announcements", "", group_id=str(gid))
        h, d = carol.expect("error", timeout=3)
        assert d.decode(), "非成员应收到 error"

    def test_delete_old_announcement(self, harness):
        """删除非当前公告：历史行删除；全员收到 announcement_deleted 推送
        （2026-08-31 用户反馈 R-O12：删除须全端同步）；横幅（当前公告）
        不受影响、无 list_groups 刷新。"""
        alice, bob, gid = _group_setup(harness, name="公告组")
        alice.drain(timeout=0.5)
        alice.send("set_group_announcement", "旧公告",
                   group_id=str(gid), message_id="o1m-old")
        alice.expect("chat", timeout=3)
        alice.drain(timeout=0.5)
        alice.send("set_group_announcement", "新公告",
                   group_id=str(gid), message_id="o1m-new")
        alice.expect("chat", timeout=3)
        alice.drain(timeout=0.5)
        bob.drain(timeout=0.5)

        alice.send("delete_group_announcement", "", group_id=str(gid),
                   message_id="o1m-old")
        h, d = alice.expect("chat", timeout=3)
        assert "公告已删除" in d.decode(), f"删除确认: {d.decode()}"

        # 全员（含群主）收到 announcement_deleted 推送
        for client, who in [(alice, "群主"), (bob, "成员")]:
            h, d = client.expect("announcement_deleted", timeout=3)
            assert h.get("group_id") == str(gid), f"{who} group_id 头: {h}"
            assert h.get("message_id") == "o1m-old", f"{who} message_id 头: {h}"

        alice.send("list_group_announcements", "", group_id=str(gid))
        h, d = alice.expect("announcements_list_response", timeout=3)
        entries = json.loads(d.decode())
        assert [e["content"] for e in entries] == ["新公告"], \
            f"旧公告应从历史删除: {entries}"

        # 当前公告未被清除：无 list_groups 刷新，横幅保持
        h, d = alice.recv(timeout=0.6)
        assert h is None, f"删除非当前公告不应刷新 list_groups: {h}"

    def test_delete_current_clears_banner(self, harness):
        """删除当前公告：横幅字段清空 + 全员 list_groups 刷新。"""
        alice, bob, gid = _group_setup(harness, name="公告组")
        alice.drain(timeout=0.5)
        alice.send("set_group_announcement", "将被删除的公告",
                   group_id=str(gid), message_id="o1m-cur")
        alice.expect("chat", timeout=3)
        alice.drain(timeout=0.5)
        bob.drain(timeout=0.5)

        alice.send("delete_group_announcement", "", group_id=str(gid),
                   message_id="o1m-cur")
        h, d = alice.expect("chat", timeout=3)
        assert "公告已删除" in d.decode()
        h, d = alice.expect("announcement_deleted", timeout=3)
        assert h.get("message_id") == "o1m-cur"

        h, d = alice.expect("list_groups", timeout=3)
        g = _groups_in_push(h, d, gid)
        assert g.get("announcement") == "", f"当前公告应清空: {g}"
        h, d = bob.expect("announcement_deleted", timeout=3)
        assert h.get("message_id") == "o1m-cur"
        h, d = bob.expect("list_groups", timeout=3)
        g = _groups_in_push(h, d, gid)
        assert g.get("announcement") == ""

    def test_delete_non_owner_rejected(self, harness):
        """非群主删除公告 → error 含 '群主'。"""
        alice, bob, gid = _group_setup(harness, name="公告组")
        alice.drain(timeout=0.5)
        alice.send("set_group_announcement", "受保护的公告",
                   group_id=str(gid), message_id="o1m-p")
        alice.expect("chat", timeout=3)
        alice.drain(timeout=0.5)
        bob.drain(timeout=0.5)

        bob.send("delete_group_announcement", "", group_id=str(gid),
                 message_id="o1m-p")
        h, d = bob.expect("error", timeout=3)
        assert "群主" in d.decode(), f"拒绝理由: {d.decode()}"

    def test_delete_missing_announcement_rejected(self, harness):
        """删除不存在的公告 → error。"""
        alice, _, gid = _group_setup(harness, with_bob=False)
        alice.drain(timeout=0.5)

        alice.send("delete_group_announcement", "", group_id=str(gid),
                   message_id="ghost")
        h, d = alice.expect("error", timeout=3)
        assert d.decode(), "删除不存在的公告应收到 error"


# ============================================================
# O8 —— 证书过期检测 + 一键续期
# ============================================================

class TestCertExpiryO8:

    def test_check_cert_expiry_valid(self, harness, tmp_path):
        """有效证书（3650 天）→ expired=False / warn=False / days_left 充足。"""
        cert_path, _ = _write_cert(tmp_path, "valid", days=3650)
        info = harness.server.check_cert_expiry(cert_path=cert_path)
        assert info["exists"] is True
        assert info["expired"] is False
        assert info["warn"] is False
        assert info["days_left"] is not None and info["days_left"] > 3600
        assert info["not_after"] is not None
        assert info["cert_path"] == cert_path

    def test_check_cert_expiry_expired(self, harness, tmp_path):
        """过期证书 → expired=True / days_left < 0。"""
        cert_path, _ = _write_cert(tmp_path, "expired", days=-1)
        info = harness.server.check_cert_expiry(cert_path=cert_path)
        assert info["exists"] is True
        assert info["expired"] is True
        assert info["days_left"] is not None and info["days_left"] < 0

    def test_check_cert_expiry_soon_warn(self, harness, tmp_path):
        """即将过期（10 天 < CERT_WARN_DAYS=30）→ warn=True / expired=False。"""
        cert_path, _ = _write_cert(tmp_path, "soon", days=10)
        info = harness.server.check_cert_expiry(cert_path=cert_path)
        assert info["expired"] is False
        assert info["warn"] is True, "10 天有效期应触发预警"

    def test_check_cert_expiry_missing_file(self, harness, tmp_path):
        """证书文件缺失 → exists=False / expired=True / days_left=None。"""
        missing = str(tmp_path / "nope.crt")
        info = harness.server.check_cert_expiry(cert_path=missing)
        assert info["exists"] is False
        assert info["expired"] is True
        assert info["days_left"] is None

    def test_cert_warn_days_constant(self, harness):
        """CERT_WARN_DAYS = 30（类常量，供状态面板/日志提示）。"""
        assert harness.server.CERT_WARN_DAYS == 30

    def test_server_status_includes_cert(self, harness):
        """get_server_status 聚合 cert 检查结果（仓库默认证书存在且未过期）。"""
        status = harness.server.get_server_status()
        assert "cert" in status, f"状态面板应含 cert 键: {list(status.keys())}"
        cert = status["cert"]
        assert {"exists", "expired", "days_left"} <= set(cert.keys()), \
            f"cert 字段不齐: {cert}"

    def test_server_status_protocol_carries_cert(self, harness):
        """admin_command action=server_status 响应 JSON 携带 cert（旧客户端忽略）。"""
        admin = _admin(harness)
        admin.drain(timeout=0.5)
        admin.send("admin_command", "", action="server_status")
        h, d = admin.expect("admin_response", timeout=3)
        assert h.get("response_type") == "server_status"
        body = json.loads(d.decode())
        assert "cert" in body, f"server_status 响应应含 cert: {list(body.keys())}"

    def test_renew_cert_admin_success(self, harness, tmp_path, monkeypatch):
        """管理员一键续期 → 覆写证书文件 + 响应 ok/days_left + 检查转绿。"""
        from config import config

        cert_path, key_path = _write_cert(tmp_path, "renewme", days=-1)
        monkeypatch.setitem(config._data.setdefault("server", {}),
                            "ssl_cert", cert_path)
        monkeypatch.setitem(config._data.setdefault("server", {}),
                            "ssl_key", key_path)

        admin = _admin(harness)
        admin.drain(timeout=0.5)
        admin.send("admin_command", "", action="renew_cert")
        h, d = admin.expect("admin_response", timeout=5)
        assert h.get("response_type") == "renew_cert", f"响应头: {h}"
        body = json.loads(d.decode())
        assert body.get("ok") is True, f"续期响应: {body}"
        assert body.get("days_left", 0) > 3000, \
            f"新证书应有约 3650 天有效期: {body}"

        # 证书文件已被替换为有效证书
        info = harness.server.check_cert_expiry(cert_path=cert_path)
        assert info["exists"] is True and info["expired"] is False
        assert info["days_left"] > 3000

    def test_renew_cert_non_admin_rejected(self, harness):
        """非管理员续期 → error '无管理员权限'。"""
        alice = _alice(harness)
        alice.drain(timeout=0.5)
        alice.send("admin_command", "", action="renew_cert")
        h, d = alice.expect("error", timeout=3)
        assert "无管理员权限" in d.decode(), f"拒绝理由: {d.decode()}"


class TestCertRenewScriptO8:
    """续期脚本 scripts/renew_cert.py 源码静态契约（仿 test_stage_m_deploy）。"""

    PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    def _read(self, rel):
        path = os.path.join(self.PROJECT_ROOT, rel)
        assert os.path.exists(path), f"缺少文件: {path}（阶段 O8 应创建）"
        with open(path, "r", encoding="utf-8") as f:
            return f.read()

    def test_renew_script_exists(self):
        """scripts/renew_cert.py 存在。"""
        self._read(os.path.join("scripts", "renew_cert.py"))

    def test_renew_script_contract(self):
        """提供 renew(...) + 复用 gen_cert 生成流程 + 支持 --check / --days。"""
        src = self._read(os.path.join("scripts", "renew_cert.py"))
        assert "def renew(" in src, "应提供 renew(...) 函数"
        assert "generate_cert" in src, "应复用 SSL/gen_cert.py 生成流程"
        assert "--check" in src, "应支持 --check 检查模式"
        assert "--days" in src, "应支持 --days 有效期参数"

    def test_gen_cert_days_parameterized(self):
        """SSL/gen_cert.py:generate_cert 支持 days 参数（默认 3650 向后兼容）。"""
        import re
        src = self._read(os.path.join("SSL", "gen_cert.py"))
        assert re.search(r"def generate_cert\([^)]*days", src), \
            "generate_cert 应参数化 days（默认 3650）"
