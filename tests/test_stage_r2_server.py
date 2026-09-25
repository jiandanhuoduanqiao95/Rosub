"""
============================================================
阶段 R2 —— 群语音/群视频（多方通话）服务端 TDD 契约测试
============================================================

【目标】
  在 R1 一对一信令中继（test_stage_r_server.py，零回归）之上，
  验证房间化群通话信令（mesh 网状拓扑，SFU 维持排除）：
    房间生命周期 / 成员资格 / 定向媒体中继 / 占用互斥 /
    人数上限 / 断开清理 / 振铃过期 / 同群并发房间拒绝 /
    group_call_media 静音·摄像头态中继 / 多端会话收敛。

【信令契约（实现方需严格遵守，本测试即据此验证）】
----- C→S 新消息类型 -----
  group_call_invite  头 {group_id, call_id, call_type(audio|video)}，体空；
                     主叫须为群成员且不在任意通话/房间（含振铃中）；
                     同群已有房间 → busy；校验失败 → 仅主叫收
                     call_failed，头 {call_id, reason}，
                     reason ∈ invalid|not_member|busy。
                     成功：建房间（participants={主叫}，ringing=在线且
                     不忙的其他成员），向其他在线成员广播
                     group_call_invite，头 {from, call_id, call_type,
                     group_id, group_name}。
  group_call_join    头 {call_id}；须房间存在 + 群成员 + 不忙 + 未满
                     （GROUP_CALL_MAX_PARTICIPANTS）；成功后加入
                     participants（自 ringing 移除），向全体在线群成员
                     广播 group_call_joined，头 {from, call_id, group_id,
                     participants(逗号分隔排序，含加入者), call_type}；
                     失败 → 仅加入者收 call_failed
                     （reason ∈ invalid|not_member|busy|full）。
  group_call_leave   头 {call_id}；振铃中离开=拒绝（reason=declined）、
                     参与者离开=挂断（reason=hangup，仅自己一人时为
                     cancel）；向全体在线群成员广播 group_call_left，
                     头 {from, call_id, group_id, participants(剩余，
                     逗号分隔排序), ended('0'|'1'),
                     reason ∈ declined|hangup|cancel|timeout|disconnect}；
                     participants 与 ringing 均空 → 房间删除且 ended='1'。
  group_call_media   头 {call_id, mic('0'|'1'), cam('0'|'1')}；仅参与者可发；
                     中继给其余参与者，头 {from, call_id, mic, cam}。
----- 媒体中继（复用 R1 类型，房间化校验） -----
  call_offer / call_answer / call_ice  头 {to, call_id=房间ID}，体原样；
                     发送方与目标均须为同房间参与者，定向转发
                     （头 {from, call_id}，到达目标全部会话）；
                     跨房间/非参与者丢弃。
----- 房间状态（纯内存，无 DB） -----
  rooms: room_id -> {group_id, call_type, participants, ringing, created}；
  占线判定扩为 1:1 calls ∪ 房间 participants/ringing（双向互斥）；
  cleanup_user：参与者断开 → 群广播 left(reason=disconnect)，房间空则
  删除并 ended 通知振铃者；振铃者断开 → 静默移出 ringing；
  expire_calls：振铃超时成员移出并广播 left(reason=timeout)
  （多端收敛：广播到达该成员全部会话），房间存续不受影响。

【运行】
  .venv/bin/python -m pytest tests/test_stage_r2_server.py -v
"""

import json
import os
import sys
import time

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

_PASSWORDS = {"alice": "password123", "bob": "password456",
              "carol": "password789", "dave": "password111",
              "eve": "password222"}


def _login(harness, username, device_id=None):
    c = harness.client()
    c.login(username, _PASSWORDS.get(username, "password123"),
            device_id=device_id, consume=False)
    c.recv_initial()
    return c


def _make_group(harness, owner="alice", members=("bob", "carol"), name="研发群"):
    gid = harness.db.create_group(name, owner)
    with harness.db._get_connection() as conn:
        for m in members:
            conn.execute(
                "INSERT INTO group_members (group_id, username) VALUES (?, ?)",
                (gid, m))
        conn.commit()
    return gid


def _make_friends(harness, a, b):
    harness.db.add_friend_request(a, b)
    harness.db.accept_friend_request(a, b)


@pytest.fixture
def gc_env(harness):
    """alice/bob/carol 在线且同群；dave 在线但非群成员。"""
    harness.add_user("carol", _PASSWORDS["carol"])
    harness.add_user("dave", _PASSWORDS["dave"])
    gid = _make_group(harness)
    alice = _login(harness, "alice")
    bob = _login(harness, "bob")
    carol = _login(harness, "carol")
    dave = _login(harness, "dave")
    return harness, alice, bob, carol, dave, gid


def _invite(caller, gid, room_id, call_type="audio"):
    caller.send("group_call_invite", "", group_id=gid, call_id=room_id,
                call_type=call_type)


def _join(client, room_id):
    client.send("group_call_join", "", call_id=room_id)


def _leave(client, room_id):
    client.send("group_call_leave", "", call_id=room_id)


def _participants_of(header):
    raw = header.get("participants", "")
    return [p for p in raw.split(",") if p]


def _assert_no_type(c, msg_type, timeout=0.8):
    c.drain(timeout=0.3)
    deadline = time.time() + timeout
    while time.time() < deadline:
        h, _ = c.recv(timeout=0.4)
        if h is None:
            return
        assert h.get("type") != msg_type, f"不应收到 {msg_type}: {h}"


def _establish_room(gc_env, room_id="room-1", call_type="audio",
                    joiners=("bob",)):
    """alice 建房，指定成员加入（各端 joined 均消费）；返回
    (harness, alice, {name: client}, gid)。"""
    harness, alice, bob, carol, dave, gid = gc_env
    _invite(alice, gid, room_id, call_type=call_type)
    for c in (bob, carol):
        c.expect("group_call_invite")
    clients = {"alice": alice, "bob": bob, "carol": carol, "dave": dave}
    for name in joiners:
        _join(clients[name], room_id)
        for c in (alice, bob, carol):
            c.expect("group_call_joined")
    return harness, alice, clients, gid


class TestGroupCallInvite:

    def test_invite_broadcast_to_online_members(self, gc_env):
        harness, alice, bob, carol, dave, gid = gc_env
        _invite(alice, gid, "room-1", call_type="video")
        for c in (bob, carol):
            h, _ = c.expect("group_call_invite")
            assert h["from"] == "alice"
            assert h["call_id"] == "room-1"
            assert h["call_type"] == "video"
            assert int(h["group_id"]) == gid
            assert h["group_name"] == "研发群"
        _assert_no_type(dave, "group_call_invite")
        _assert_no_type(alice, "group_call_invite")

    def test_invite_by_non_member_rejected(self, gc_env):
        harness, alice, bob, carol, dave, gid = gc_env
        _invite(dave, gid, "room-x")
        h, _ = dave.expect("call_failed")
        assert h["reason"] == "not_member"
        _assert_no_type(bob, "group_call_invite")

    def test_invite_invalid_params_rejected(self, gc_env):
        harness, alice, bob, carol, dave, gid = gc_env
        alice.send("group_call_invite", "", call_id="room-i",
                   call_type="audio")
        h, _ = alice.expect("call_failed")
        assert h["reason"] == "invalid"
        alice.send("group_call_invite", "", group_id=gid, call_type="audio")
        h, _ = alice.expect("call_failed")
        assert h["reason"] == "invalid"
        _invite(alice, gid, "room-t", call_type="hologram")
        h, _ = alice.expect("call_failed")
        assert h["reason"] == "invalid"
        _invite(alice, 99999, "room-g")
        h, _ = alice.expect("call_failed")
        assert h["reason"] == "invalid"

    def test_invite_while_ringing_busy_rejected(self, gc_env):
        harness, alice, bob, carol, dave, gid = gc_env
        _invite(alice, gid, "room-1")
        bob.expect("group_call_invite")
        _invite(bob, gid, "room-2")
        h, _ = bob.expect("call_failed")
        assert h["reason"] == "busy"

    def test_invite_second_room_same_group_rejected(self, gc_env):
        harness, alice, bob, carol, dave, gid = gc_env
        _invite(alice, gid, "room-1")
        for c in (bob, carol):
            c.expect("group_call_invite")
        _invite(bob, gid, "room-2")
        h, _ = bob.expect("call_failed")
        assert h["reason"] == "busy"

    def test_invite_skips_busy_members(self, gc_env):
        harness, alice, bob, carol, dave, gid = gc_env
        harness.add_user("eve", "password222")
        gid_b = _make_group(harness, owner="eve", members=("carol",),
                            name="群B")
        eve = _login(harness, "eve")
        _invite(eve, gid_b, "room-b")
        carol.expect("group_call_invite")
        assert harness.server.call_handler.rooms["room-b"][
            "ringing"].keys() >= {"carol"}
        _invite(alice, gid, "room-9")
        bob.expect("group_call_invite")
        _assert_no_type(carol, "group_call_invite")

    def test_invite_with_all_other_members_offline_succeeds(self, gc_env):
        harness, alice, bob, carol, dave, gid = gc_env
        bob.close()
        carol.close()
        time.sleep(0.2)
        _invite(alice, gid, "room-1")
        _assert_no_type(alice, "call_failed")
        assert "room-1" in harness.server.call_handler.rooms
        carol_back = _login(harness, "carol")
        _assert_no_type(carol_back, "group_call_invite")

    def test_room_state_after_invite(self, gc_env):
        harness, alice, bob, carol, dave, gid = gc_env
        _invite(alice, gid, "room-1")
        for c in (bob, carol):
            c.expect("group_call_invite")
        handler = harness.server.call_handler
        room = handler.rooms["room-1"]
        assert room["group_id"] == gid
        assert room["participants"] == {"alice"}
        assert set(room["ringing"].keys()) == {"bob", "carol"}
        assert room["call_type"] == "audio"


class TestGroupCallJoin:

    def test_join_broadcasts_joined_with_sorted_participants(self, gc_env):
        harness, alice, bob, carol, dave, gid = gc_env
        _invite(alice, gid, "room-1")
        for c in (bob, carol):
            c.expect("group_call_invite")
        _join(bob, "room-1")
        for c in (alice, bob, carol):
            h, _ = c.expect("group_call_joined")
            assert h["from"] == "bob"
            assert h["call_id"] == "room-1"
            assert int(h["group_id"]) == gid
            assert h["call_type"] == "audio"
            assert _participants_of(h) == ["alice", "bob"]

    def test_join_requires_membership(self, gc_env):
        harness, alice, bob, carol, dave, gid = gc_env
        _invite(alice, gid, "room-1")
        for c in (bob, carol):
            c.expect("group_call_invite")
        _join(dave, "room-1")
        h, _ = dave.expect("call_failed")
        assert h["reason"] == "not_member"
        _assert_no_type(alice, "group_call_joined")

    def test_join_unknown_room_rejected(self, gc_env):
        harness, alice, bob, carol, dave, gid = gc_env
        _join(bob, "ghost")
        h, _ = bob.expect("call_failed")
        assert h["reason"] == "invalid"

    def test_join_twice_is_idempotent(self, gc_env):
        harness, alice, clients, gid = _establish_room(gc_env, "room-1",
                                                        joiners=("bob",))
        _join(clients["bob"], "room-1")
        for c in (alice, clients["bob"], clients["carol"]):
            _assert_no_type(c, "group_call_joined")
        assert harness.server.call_handler.rooms["room-1"][
            "participants"] == {"alice", "bob"}

    def test_join_while_busy_elsewhere_rejected(self, gc_env):
        harness, alice, bob, carol, dave, gid = gc_env
        harness.add_user("eve", "password222")
        gid_b = _make_group(harness, owner="eve", members=("carol",),
                            name="群B")
        eve = _login(harness, "eve")
        _invite(eve, gid_b, "room-b")
        carol.expect("group_call_invite")
        _join(carol, "room-b")
        for c in (eve, carol):
            c.expect("group_call_joined")
        _invite(alice, gid, "room-1")
        bob.expect("group_call_invite")
        _assert_no_type(carol, "group_call_invite")
        _join(carol, "room-1")
        h, _ = carol.expect("call_failed")
        assert h["reason"] == "busy"
        assert harness.server.call_handler.rooms["room-1"][
            "participants"] == {"alice"}

    def test_join_room_full_rejected(self, gc_env):
        harness, alice, bob, carol, dave, gid = gc_env
        handler = harness.server.call_handler
        handler.GROUP_CALL_MAX_PARTICIPANTS = 2
        _invite(alice, gid, "room-1")
        for c in (bob, carol):
            c.expect("group_call_invite")
        _join(bob, "room-1")
        for c in (alice, bob, carol):
            c.expect("group_call_joined")
        _join(carol, "room-1")
        h, _ = carol.expect("call_failed")
        assert h["reason"] == "full"
        assert handler.rooms["room-1"]["participants"] == {"alice", "bob"}

    def test_join_converges_other_devices_of_joiner(self, gc_env):
        harness, alice, bob, carol, dave, gid = gc_env
        bob2 = _login(harness, "bob", device_id="android")
        _invite(alice, gid, "room-1")
        for c in (bob, bob2, carol):
            c.expect("group_call_invite")
        _join(bob, "room-1")
        h, _ = bob2.expect("group_call_joined")
        assert h["from"] == "bob"
        for c in (alice, bob, carol):
            c.expect("group_call_joined")

    def test_midcall_join_by_member_who_was_offline(self, gc_env):
        harness, alice, bob, carol, dave, gid = gc_env
        carol.close()
        time.sleep(0.2)
        _invite(alice, gid, "room-1")
        bob.expect("group_call_invite")
        carol_back = _login(harness, "carol")
        _join(carol_back, "room-1")
        for c in (alice, bob, carol_back):
            c.expect("group_call_joined")

    def test_declined_member_can_join_later(self, gc_env):
        harness, alice, clients, gid = _establish_room(gc_env, "room-1",
                                                        joiners=("bob",))
        _leave(clients["carol"], "room-1")
        h, _ = alice.expect("group_call_left")
        assert h["reason"] == "declined"
        clients["bob"].expect("group_call_left")
        clients["carol"].expect("group_call_left")
        _join(clients["carol"], "room-1")
        for c in (alice, clients["bob"], clients["carol"]):
            c.expect("group_call_joined")


class TestGroupCallLeave:

    def test_participant_leave_broadcasts_remaining(self, gc_env):
        harness, alice, clients, gid = _establish_room(gc_env, "room-1",
                                                        joiners=("bob",))
        _leave(clients["bob"], "room-1")
        for c in (alice, clients["bob"], clients["carol"]):
            h, _ = c.expect("group_call_left")
            assert h["from"] == "bob"
            assert h["reason"] == "hangup"
            assert h["ended"] == "0"
            assert _participants_of(h) == ["alice"]
        assert "room-1" in harness.server.call_handler.rooms

    def test_last_leave_ends_room(self, gc_env):
        harness, alice, clients, gid = _establish_room(gc_env, "room-1",
                                                        joiners=("bob",))
        _leave(clients["bob"], "room-1")
        for c in (alice, clients["bob"], clients["carol"]):
            c.expect("group_call_left")
        _leave(alice, "room-1")
        for c in (alice, clients["bob"], clients["carol"]):
            h, _ = c.expect("group_call_left")
            assert h["from"] == "alice"
            assert h["ended"] == "1"
        assert "room-1" not in harness.server.call_handler.rooms

    def test_decline_keeps_room_and_ringing(self, gc_env):
        harness, alice, bob, carol, dave, gid = gc_env
        _invite(alice, gid, "room-1")
        for c in (bob, carol):
            c.expect("group_call_invite")
        _leave(bob, "room-1")
        for c in (alice, bob, carol):
            h, _ = c.expect("group_call_left")
            assert h["reason"] == "declined"
            assert _participants_of(h) == ["alice"]
        handler = harness.server.call_handler
        assert handler.rooms["room-1"]["participants"] == {"alice"}
        assert set(handler.rooms["room-1"]["ringing"].keys()) == {"carol"}

    def test_caller_cancel_alone_notifies_ringees_room_gone(self, gc_env):
        harness, alice, bob, carol, dave, gid = gc_env
        _invite(alice, gid, "room-1")
        for c in (bob, carol):
            c.expect("group_call_invite")
        _leave(alice, "room-1")
        for c in (alice, bob, carol):
            h, _ = c.expect("group_call_left")
            assert h["from"] == "alice"
            assert h["ended"] == "1"
            assert h["reason"] == "cancel"
        assert not harness.server.call_handler.rooms

    def test_leave_unknown_room_ignored(self, gc_env):
        harness, alice, bob, carol, dave, gid = gc_env
        _leave(bob, "ghost")
        _assert_no_type(bob, "call_failed")


class TestRoomMediaRelay:

    def test_offer_answer_ice_directed_to_peer_only(self, gc_env):
        harness, alice, clients, gid = _establish_room(
            gc_env, "room-1", joiners=("bob", "carol"))
        offer = {"sdp": "v=0 offer", "type": "offer"}
        alice.send("call_offer", json.dumps(offer), to="bob",
                   call_id="room-1")
        h, d = clients["bob"].expect("call_offer")
        assert h["from"] == "alice"
        assert json.loads(d.decode()) == offer
        _assert_no_type(clients["carol"], "call_offer")
        answer = {"sdp": "v=0 answer", "type": "answer"}
        clients["bob"].send("call_answer", json.dumps(answer), to="alice",
                            call_id="room-1")
        h, d = alice.expect("call_answer")
        assert h["from"] == "bob"
        assert json.loads(d.decode()) == answer
        cand = {"candidate": "c:1", "sdpMid": "0", "sdpMLineIndex": 0}
        clients["carol"].send("call_ice", json.dumps(cand), to="bob",
                              call_id="room-1")
        h, d = clients["bob"].expect("call_ice")
        assert h["from"] == "carol"
        assert json.loads(d.decode()) == cand

    def test_relay_by_non_participant_dropped(self, gc_env):
        harness, alice, clients, gid = _establish_room(gc_env, "room-1",
                                                        joiners=("bob",))
        clients["carol"].send("call_offer", json.dumps({"sdp": "x"}),
                              to="alice", call_id="room-1")
        _assert_no_type(alice, "call_offer")

    def test_relay_to_non_participant_dropped(self, gc_env):
        harness, alice, clients, gid = _establish_room(gc_env, "room-1",
                                                        joiners=("bob",))
        alice.send("call_offer", json.dumps({"sdp": "x"}), to="carol",
                   call_id="room-1")
        _assert_no_type(clients["carol"], "call_offer")

    def test_relay_unknown_room_dropped(self, gc_env):
        harness, alice, clients, gid = _establish_room(gc_env, "room-1",
                                                        joiners=("bob",))
        alice.send("call_offer", json.dumps({"sdp": "x"}), to="bob",
                   call_id="ghost")
        _assert_no_type(clients["bob"], "call_offer")

    def test_1to1_call_relay_unaffected_by_rooms(self, harness):
        harness.add_user("carol", "password789")
        _make_group(harness)
        alice = _login(harness, "alice")
        bob = _login(harness, "bob")
        alice.send("call_invite", "", to="bob", call_id="p2p",
                   call_type="audio")
        h, _ = bob.expect("call_invite")
        assert h["from"] == "alice"
        bob.send("call_accept", "", to="alice", call_id="p2p")
        alice.expect("call_accept")
        bob.expect("call_active")
        alice.send("call_offer", json.dumps({"sdp": "p2p-offer"}),
                   to="bob", call_id="p2p")
        h, d = bob.expect("call_offer")
        assert json.loads(d.decode()) == {"sdp": "p2p-offer"}


class TestOccupancyInterplay:

    def test_group_participant_busy_for_1to1(self, gc_env):
        harness, alice, clients, gid = _establish_room(gc_env, "room-1",
                                                        joiners=("bob",))
        dave = clients["dave"]
        _make_friends(harness, "dave", "bob")
        dave.send("call_invite", "", to="bob", call_id="p2p-1",
                  call_type="audio")
        h, _ = dave.expect("call_failed")
        assert h["reason"] == "busy"

    def test_group_ringing_busy_for_1to1(self, gc_env):
        harness, alice, bob, carol, dave, gid = gc_env
        _invite(alice, gid, "room-1")
        for c in (bob, carol):
            c.expect("group_call_invite")
        _make_friends(harness, "dave", "carol")
        dave.send("call_invite", "", to="carol", call_id="p2p-2",
                  call_type="audio")
        h, _ = dave.expect("call_failed")
        assert h["reason"] == "busy"

    def test_1to1_ringing_member_skipped_by_group_invite(self, gc_env):
        harness, alice, bob, carol, dave, gid = gc_env
        _make_friends(harness, "dave", "carol")
        dave.send("call_invite", "", to="carol", call_id="p2p-3",
                  call_type="audio")
        carol.expect("call_invite")
        _invite(alice, gid, "room-1")
        bob.expect("group_call_invite")
        _assert_no_type(carol, "group_call_invite")


class TestDisconnectCleanup:

    def test_participant_disconnect_broadcasts_left(self, gc_env):
        harness, alice, clients, gid = _establish_room(gc_env, "room-1",
                                                        joiners=("bob",))
        clients["bob"].close()
        h, _ = alice.expect("group_call_left")
        assert h["from"] == "bob"
        assert h["reason"] == "disconnect"
        assert _participants_of(h) == ["alice"]
        assert h["ended"] == "0"
        assert harness.server.call_handler.rooms["room-1"][
            "participants"] == {"alice"}

    def test_last_participant_disconnect_ends_room_stops_ringing(self, gc_env):
        harness, alice, bob, carol, dave, gid = gc_env
        _invite(alice, gid, "room-1")
        for c in (bob, carol):
            c.expect("group_call_invite")
        alice.close()
        for c in (bob, carol):
            h, _ = c.expect("group_call_left")
            assert h["from"] == "alice"
            assert h["ended"] == "1"
            assert h["reason"] == "disconnect"
        assert "room-1" not in harness.server.call_handler.rooms

    def test_ringing_member_disconnect_is_silent(self, gc_env):
        harness, alice, bob, carol, dave, gid = gc_env
        _invite(alice, gid, "room-1")
        for c in (bob, carol):
            c.expect("group_call_invite")
        bob.close()
        _assert_no_type(alice, "group_call_left")
        assert harness.server.call_handler.rooms["room-1"][
            "participants"] == {"alice"}


class TestRingExpiry:

    def test_ringee_timeout_notified_all_devices(self, gc_env):
        harness, alice, bob, carol, dave, gid = gc_env
        bob2 = _login(harness, "bob", device_id="android")
        handler = harness.server.call_handler
        handler.CALL_INVITE_TIMEOUT = 0.2
        _invite(alice, gid, "room-1")
        for c in (bob, bob2, carol):
            c.expect("group_call_invite")
        time.sleep(0.3)
        handler.expire_calls()
        # 每端按序收到两条超时广播（bob 先、carol 后）——expect 仅跳过
        # presence，须逐条消费后再断言
        for c in (bob, bob2, carol):
            h, _ = c.expect("group_call_left")
            assert h["from"] == "bob"
            assert h["reason"] == "timeout"
            h2, _ = c.expect("group_call_left")
            assert h2["from"] == "carol"
            assert h2["reason"] == "timeout"
        room = handler.rooms["room-1"]
        assert room["participants"] == {"alice"}
        assert room["ringing"] == {}

    def test_expire_keeps_room_alive(self, gc_env):
        harness, alice, bob, carol, dave, gid = gc_env
        handler = harness.server.call_handler
        handler.CALL_INVITE_TIMEOUT = 0.2
        _invite(alice, gid, "room-1")
        for c in (bob, carol):
            c.expect("group_call_invite")
        time.sleep(0.3)
        handler.expire_calls()
        _join(carol, "room-1")
        for c in (alice, bob, carol):
            c.expect("group_call_left")
            c.expect("group_call_left")
            h, _ = c.expect("group_call_joined")
            assert _participants_of(h) == ["alice", "carol"]


class TestGroupCallMedia:

    def test_media_state_relayed_to_other_participants(self, gc_env):
        harness, alice, clients, gid = _establish_room(
            gc_env, "room-1", joiners=("bob", "carol"))
        alice.send("group_call_media", "", call_id="room-1", mic="1",
                   cam="0")
        for c in (clients["bob"], clients["carol"]):
            h, _ = c.expect("group_call_media")
            assert h["from"] == "alice"
            assert h["mic"] == "1"
            assert h["cam"] == "0"
        _assert_no_type(alice, "group_call_media")

    def test_media_from_non_participant_dropped(self, gc_env):
        harness, alice, clients, gid = _establish_room(gc_env, "room-1",
                                                        joiners=("bob",))
        clients["carol"].send("group_call_media", "", call_id="room-1",
                              mic="1", cam="0")
        _assert_no_type(clients["bob"], "group_call_media")


class TestMalformedInput:

    def test_malformed_group_call_keeps_connection_alive(self, gc_env):
        harness, alice, bob, carol, dave, gid = gc_env
        alice.send("group_call_invite", "", group_id="abc",
                   call_id="room-bad", call_type="audio")
        h, _ = alice.expect("call_failed")
        assert h["reason"] == "invalid"
        alice.send("chat", "still-alive", to="bob", message_id="m-r2")
        h, d = bob.expect("chat")
        assert d == b"still-alive"

    def test_non_member_join_after_malformed_still_valid(self, gc_env):
        harness, alice, bob, carol, dave, gid = gc_env
        _invite(alice, gid, "room-1")
        for c in (bob, carol):
            c.expect("group_call_invite")
        dave.send("group_call_join", "", call_id="")
        h, _ = dave.expect("call_failed")
        assert h["reason"] == "invalid"
        _join(bob, "room-1")
        for c in (alice, bob, carol):
            c.expect("group_call_joined")
