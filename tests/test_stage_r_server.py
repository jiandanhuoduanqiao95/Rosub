"""
============================================================
阶段 R1 —— 音视频通话信令中继 TDD 契约测试（Spike 先行）
============================================================

【目标】
  按《软件开发文档4.1.0.md》§13.9 阶段 R 表格与 R1 Spike 决策编写服务端
  契约测试：
    R1  通话信令中继：呼叫邀请/应答/拒绝/取消/挂断/offer/answer/ICE 转发、
        占线与离线处理、断开清理、邀请过期清理、异常隔离。
        call_type（audio/video）双类型同一信令流程；协议 v1.0.0 向后兼容
        （新增 type 为非破坏性扩展，tkinter 忽略未知类型惯例覆盖）。

【信令契约（实现方需严格遵守，本测试即据此验证）】
----- 消息类型与头部 -----
  call_invite  C→S 头 {to, call_id, call_type(audio|video)}，体空；
               服务端校验（好友/黑名单/在线/占线/参数）后中继给被叫
               **全部在线会话**，头 {from, call_id, call_type}。
               校验失败 → 仅向主叫回 call_failed，头 {call_id, reason}，
               reason ∈ invalid|not_friend|blocked|offline|busy|expired。
  call_accept  C→S 头 {to, call_id}；中继给主叫 {from, call_id}，
               同时向被叫全部会话广播 call_active（头 {call_id, from=接听者}，
               多端振铃收敛——其他设备据此停止响铃）。
  call_reject  C→S 头 {to, call_id}；中继给主叫 {from, call_id}；清理通话。
  call_cancel  C→S 头 {to, call_id}（主叫振铃中取消）；中继给被叫全部会话
               {from, call_id}；清理通话。
  call_hangup  C→S 头 {to, call_id}（任一方挂断）；中继给对方全部会话
               {from, call_id}；清理通话。
  call_offer / call_answer / call_ice
               C→S 头 {to, call_id}，体 = SDP/ICE JSON（服务端原样转发）；
               中继头 {from, call_id}。仅通话参与者可中继，未知 call_id 丢弃。
----- 通话状态（服务端内存态，无 DB）-----
  active_calls: call_id -> {caller, callee, call_type, accepted, created}；
  占线判定 = 用户为任一通话（含振铃中未接听）的主叫或被叫；
  被叫下线 → 主叫收 call_hangup；主叫下线 → 被叫收 call_cancel；
  未接听邀请超过 CALL_INVITE_TIMEOUT（默认 60s）由 expire_calls 清理：
  主叫收 call_failed(reason=expired)，被叫全部会话收 call_cancel。

【运行】
  .venv/bin/python -m pytest tests/test_stage_r_server.py -v
"""

import json
import os
import sys
import time

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _make_friends_with(harness, a, b):
    with harness.db._get_connection() as conn:
        conn.execute(
            "INSERT INTO friends (user1, user2, status) VALUES (?, ?, 'accepted')",
            (a, b))
        conn.execute(
            "INSERT INTO friends (user1, user2, status) VALUES (?, ?, 'accepted')",
            (b, a))
        conn.commit()


_PASSWORDS = {"alice": "password123", "bob": "password456",
              "carol": "password789"}


def _login(harness, username, device_id=None):
    c = harness.client()
    c.login(username, _PASSWORDS.get(username, "password123"),
            device_id=device_id, consume=False)
    c.recv_initial()
    return c


@pytest.fixture
def call_env(harness):
    """alice/bob 在线且互为好友（conftest 预置）；carol 与 alice/bob 均好友，
    dave 与所有人非好友（not_friend 用例）。"""
    harness.add_user("carol", "password789")
    harness.add_user("dave", "password111")
    _make_friends_with(harness, "alice", "carol")
    _make_friends_with(harness, "bob", "carol")
    alice = _login(harness, "alice")
    bob = _login(harness, "bob")
    return harness, alice, bob


def _assert_no_type(c, msg_type, timeout=0.8):
    """断言 [timeout] 窗口内不再收到指定类型（先排空残留噪声）。"""
    c.drain(timeout=0.3)
    deadline = time.time() + timeout
    while time.time() < deadline:
        h, _ = c.recv(timeout=0.4)
        if h is None:
            return
        assert h.get("type") != msg_type, f"不应收到 {msg_type}: {h}"


def _invite(caller, callee_name, call_id, call_type="audio"):
    caller.send("call_invite", "", to=callee_name, call_id=call_id,
                call_type=call_type)


class TestCallInviteRelay:

    @pytest.mark.parametrize("call_type", ["audio", "video"])
    def test_invite_relayed_with_call_type(self, call_env, call_type):
        harness, alice, bob = call_env
        _invite(alice, "bob", "call-1", call_type=call_type)
        h, d = bob.expect("call_invite")
        assert h["from"] == "alice"
        assert h["call_id"] == "call-1"
        assert h["call_type"] == call_type

    def test_invite_not_friend_rejected(self, call_env):
        harness, alice, bob = call_env
        bob.send("call_invite", "", to="dave", call_id="call-x",
                 call_type="audio")
        h, _ = bob.expect("call_failed")
        assert h["reason"] == "not_friend"

    def test_invite_blocked_rejected(self, call_env):
        harness, alice, bob = call_env
        harness.db.block_user("bob", "alice")
        _invite(alice, "bob", "call-b")
        h, _ = alice.expect("call_failed")
        assert h["reason"] == "blocked"

    def test_invite_offline_rejected(self, call_env):
        harness, alice, bob = call_env
        carol = _login(harness, "carol")
        carol.close()
        time.sleep(0.2)
        _invite(alice, "carol", "call-o")
        h, _ = alice.expect("call_failed")
        assert h["reason"] == "offline"

    @pytest.mark.parametrize("kwargs", [
        {"to": "bob"},                          # 缺 call_id
        {"call_id": "call-m"},                  # 缺 to
        {"to": "alice", "call_id": "call-s"},   # 呼叫自己
    ])
    def test_invite_invalid_rejected(self, call_env, kwargs):
        harness, alice, bob = call_env
        alice.send("call_invite", "", call_type="audio", **kwargs)
        h, _ = alice.expect("call_failed")
        assert h["reason"] == "invalid"

    def test_invite_bad_call_type_rejected(self, call_env):
        harness, alice, bob = call_env
        alice.send("call_invite", "", to="bob", call_id="call-t",
                   call_type="hologram")
        h, _ = alice.expect("call_failed")
        assert h["reason"] == "invalid"


class TestCallBusy:

    def test_callee_ringing_counts_busy(self, call_env):
        harness, alice, bob = call_env
        _invite(alice, "bob", "call-1")
        bob.expect("call_invite")
        carol = _login(harness, "carol")
        _invite(carol, "bob", "call-2")
        h, _ = carol.expect("call_failed")
        assert h["reason"] == "busy"

    def test_callee_in_active_call_counts_busy(self, call_env):
        harness, alice, bob = call_env
        _invite(alice, "bob", "call-1")
        bob.expect("call_invite")
        bob.send("call_accept", "", to="alice", call_id="call-1")
        alice.expect("call_accept")
        carol = _login(harness, "carol")
        _invite(carol, "bob", "call-3")
        h, _ = carol.expect("call_failed")
        assert h["reason"] == "busy"

    def test_caller_busy_on_second_invite(self, call_env):
        harness, alice, bob = call_env
        _invite(alice, "bob", "call-1")
        bob.expect("call_invite")
        _invite(alice, "carol", "call-2")
        h, _ = alice.expect("call_failed")
        assert h["reason"] == "busy"


class TestCallAcceptRejectCancelHangup:

    def test_accept_relayed_and_active_broadcast(self, harness):
        alice = _login(harness, "alice")
        bob1 = _login(harness, "bob", device_id="linux")
        bob2 = _login(harness, "bob", device_id="android")
        _invite(alice, "bob", "call-1", call_type="video")
        for c in (bob1, bob2):
            h, _ = c.expect("call_invite")
            assert h["call_type"] == "video"
        bob1.send("call_accept", "", to="alice", call_id="call-1")
        h, _ = alice.expect("call_accept")
        assert h["from"] == "bob"
        assert h["call_id"] == "call-1"
        h2, _ = bob2.expect("call_active")
        assert h2["call_id"] == "call-1"
        assert h2["from"] == "bob"

    def test_accept_by_non_callee_ignored(self, call_env):
        harness, alice, bob = call_env
        carol = _login(harness, "carol")
        _invite(alice, "bob", "call-1")
        bob.expect("call_invite")
        carol.send("call_accept", "", to="alice", call_id="call-1")
        _assert_no_type(alice, "call_accept")

    def test_double_accept_second_ignored(self, call_env):
        harness, alice, bob = call_env
        _invite(alice, "bob", "call-1")
        bob.expect("call_invite")
        bob.send("call_accept", "", to="alice", call_id="call-1")
        alice.expect("call_accept")
        bob.send("call_accept", "", to="alice", call_id="call-1")
        _assert_no_type(alice, "call_accept")

    def test_reject_relayed_and_cleanup(self, call_env):
        harness, alice, bob = call_env
        _invite(alice, "bob", "call-1")
        bob.expect("call_invite")
        bob.send("call_reject", "", to="alice", call_id="call-1")
        h, _ = alice.expect("call_reject")
        assert h["from"] == "bob"
        # 通话已清理：同两人可立即再次呼叫
        _invite(alice, "bob", "call-2")
        bob.expect("call_invite")

    def test_cancel_relayed_and_cleanup(self, call_env):
        harness, alice, bob = call_env
        _invite(alice, "bob", "call-1")
        bob.expect("call_invite")
        alice.send("call_cancel", "", to="bob", call_id="call-1")
        h, _ = bob.expect("call_cancel")
        assert h["from"] == "alice"
        _invite(alice, "bob", "call-2")
        bob.expect("call_invite")

    def test_hangup_relayed_and_cleanup(self, call_env):
        harness, alice, bob = call_env
        _invite(alice, "bob", "call-1")
        bob.expect("call_invite")
        bob.send("call_accept", "", to="alice", call_id="call-1")
        alice.expect("call_accept")
        bob.send("call_hangup", "", to="alice", call_id="call-1")
        h, _ = alice.expect("call_hangup")
        assert h["from"] == "bob"
        _invite(alice, "bob", "call-2")
        bob.expect("call_invite")


class TestOfferAnswerIceRelay:

    def _establish(self, call_env, call_id="call-1"):
        harness, alice, bob = call_env
        _invite(alice, "bob", call_id)
        bob.expect("call_invite")
        bob.send("call_accept", "", to="alice", call_id=call_id)
        alice.expect("call_accept")
        # 接听者自身会话也收到 call_active（多端收敛广播），先消费
        h, _ = bob.expect("call_active")
        assert h["call_id"] == call_id
        return harness, alice, bob

    def test_offer_answer_ice_relayed_verbatim(self, call_env):
        harness, alice, bob = self._establish(call_env)
        offer = {"sdp": "v=0 offer-sdp", "type": "offer"}
        alice.send("call_offer", json.dumps(offer), to="bob", call_id="call-1")
        h, d = bob.expect("call_offer")
        assert h["from"] == "alice"
        assert json.loads(d.decode()) == offer
        answer = {"sdp": "v=0 answer-sdp", "type": "answer"}
        bob.send("call_answer", json.dumps(answer), to="alice",
                 call_id="call-1")
        h, d = alice.expect("call_answer")
        assert h["from"] == "bob"
        assert json.loads(d.decode()) == answer
        cand = {"candidate": "candidate:1 udp", "sdpMid": "0",
                "sdpMLineIndex": 0}
        alice.send("call_ice", json.dumps(cand), to="bob", call_id="call-1")
        h, d = bob.expect("call_ice")
        assert h["from"] == "alice"
        assert json.loads(d.decode()) == cand

    def test_relay_unknown_call_id_dropped(self, call_env):
        harness, alice, bob = call_env
        alice.send("call_offer", json.dumps({"sdp": "x", "type": "offer"}),
                   to="bob", call_id="ghost")
        _assert_no_type(bob, "call_offer")

    def test_relay_by_non_participant_dropped(self, call_env):
        harness, alice, bob = self._establish(call_env)
        carol = _login(harness, "carol")
        carol.send("call_offer", json.dumps({"sdp": "x", "type": "offer"}),
                   to="bob", call_id="call-1")
        _assert_no_type(bob, "call_offer")


class TestDisconnectCleanup:

    def test_caller_disconnect_notifies_callee_cancel(self, harness):
        alice = _login(harness, "alice")
        bob = _login(harness, "bob")
        _invite(alice, "bob", "call-1")
        bob.expect("call_invite")
        alice.close()
        h, _ = bob.expect("call_cancel")
        assert h["from"] == "alice"

    def test_callee_disconnect_notifies_caller_hangup(self, harness):
        alice = _login(harness, "alice")
        bob = _login(harness, "bob")
        _invite(alice, "bob", "call-1")
        bob.expect("call_invite")
        bob.close()
        h, _ = alice.expect("call_hangup")
        assert h["from"] == "bob"

    def test_disconnect_clears_busy(self, harness):
        alice = _login(harness, "alice")
        bob = _login(harness, "bob")
        _invite(alice, "bob", "call-1")
        bob.expect("call_invite")
        bob.close()
        alice.expect("call_hangup")
        _invite(alice, "bob", "call-2")
        # bob 离线：占线应已清除，失败原因是 offline 而非 busy
        h, _ = alice.expect("call_failed")
        assert h["reason"] == "offline"


class TestInviteExpiry:

    def test_expired_invite_notifies_both_and_cleans(self, call_env):
        harness, alice, bob = call_env
        handler = harness.server.call_handler
        handler.CALL_INVITE_TIMEOUT = 0.2
        _invite(alice, "bob", "call-1")
        bob.expect("call_invite")
        time.sleep(0.3)
        expired = handler.expire_calls()
        assert expired == ["call-1"]
        h, _ = alice.expect("call_failed")
        assert h["reason"] == "expired"
        h2, _ = bob.expect("call_cancel")
        assert h2["from"] == "alice"
        assert not handler.calls

    def test_active_call_not_expired(self, call_env):
        harness, alice, bob = call_env
        handler = harness.server.call_handler
        handler.CALL_INVITE_TIMEOUT = 0.2
        _invite(alice, "bob", "call-1")
        bob.expect("call_invite")
        bob.send("call_accept", "", to="alice", call_id="call-1")
        alice.expect("call_accept")
        time.sleep(0.3)
        assert handler.expire_calls() == []
        assert "call-1" in handler.calls


class TestExceptionIsolation:

    def test_malformed_signaling_keeps_connection_alive(self, call_env):
        harness, alice, bob = call_env
        alice.send("call_offer", "not-a-json", to="bob", call_id="nope")
        alice.send("call_ice", "", to="bob")
        alice.send("chat", "hello", to="bob", message_id="m-alive")
        h, d = bob.expect("chat")
        assert d == b"hello"

    def test_call_after_malformed_still_works(self, call_env):
        harness, alice, bob = call_env
        alice.send("call_invite", "", to="bob")
        h, _ = alice.expect("call_failed")
        assert h["reason"] == "invalid"
        _invite(alice, "bob", "call-ok")
        bob.expect("call_invite")
