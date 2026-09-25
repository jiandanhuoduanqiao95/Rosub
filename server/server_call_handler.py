import logging
import threading
import time


class CallHandler:
    """阶段 R1/R2：音视频通话信令中继（纯内存态，无 DB、不落协议既有表）。

    消息类型（协议 v1.0.0 向后兼容扩展，tkinter 忽略未知类型）：
      一对一（R1）：
        call_invite / call_accept / call_reject / call_cancel / call_hangup /
        call_offer / call_answer / call_ice（C→S 中继）
        call_active / call_failed（仅 S→C）
      群通话房间（R2，mesh 网状，SFU 排除）：
        group_call_invite / group_call_join / group_call_leave /
        group_call_media（C→S）；S→C 复用同名 invite/joined/left/media +
        call_failed。媒体协商复用 call_offer/answer/ice（call_id=房间ID，
        同房间参与者定向转发，新加入者向既有成员逐对发起 offer）。

    通话占用为用户级：1:1 的 caller/callee 任一角色，或任一房间的
    participants/ringing 成员，即占线（含振铃中未接听）；群来电对忙线
    成员静默跳过。多会话（阶段 L1）下信令统一 broadcast_to_user 到目标
    用户全部会话。
    """

    CALL_INVITE_TIMEOUT = 60.0
    GROUP_CALL_MAX_PARTICIPANTS = 6

    _FAIL_TEXTS = {
        "invalid": "呼叫参数无效",
        "not_friend": "对方不是您的好友，无法呼叫",
        "blocked": "对方已将您拉黑，无法呼叫",
        "offline": "对方不在线",
        "busy": "对方忙线中",
        "expired": "对方无应答",
        "not_member": "您不在该群组中，无法参与群通话",
        "full": "群通话人数已满",
    }

    def __init__(self, server):
        self.server = server
        # call_id -> {"caller", "callee", "call_type", "accepted", "created"}
        self.calls = {}
        # room_id -> {"group_id", "call_type", "participants"(set),
        #             "ringing"(username -> 振铃开始时刻), "created"}
        self.rooms = {}
        self._lock = threading.Lock()

    def _fail(self, username, call_id, reason):
        self.server.broadcast_to_user(
            username, "call_failed", self._FAIL_TEXTS.get(reason, "呼叫失败"),
            extra_headers={"call_id": call_id or "", "reason": reason})

    def _is_busy(self, username):
        if any(call["caller"] == username or call["callee"] == username
               for call in self.calls.values()):
            return True
        return any(username in room["participants"]
                   or username in room["ringing"]
                   for room in self.rooms.values())

    def _group_has_room(self, group_id):
        return any(room["group_id"] == group_id
                   for room in self.rooms.values())

    def _online_usernames(self):
        try:
            with self.server.client_map_lock:
                return {u for (u, _d) in self.server.client_map.keys()}
        except Exception:
            return set()

    def handle(self, username, ssock, msg_type, header, data):
        if msg_type == "call_invite":
            self._handle_invite(username, header)
        elif msg_type == "call_accept":
            self._handle_accept(username, header)
        elif msg_type in ("call_reject", "call_cancel", "call_hangup"):
            self._handle_terminal(username, header, msg_type)
        elif msg_type in ("call_offer", "call_answer", "call_ice"):
            self._handle_relay(username, header, msg_type, data)
        elif msg_type == "group_call_invite":
            self._handle_group_invite(username, header)
        elif msg_type == "group_call_join":
            self._handle_group_join(username, header)
        elif msg_type == "group_call_leave":
            self._handle_group_leave(username, header)
        elif msg_type == "group_call_media":
            self._handle_group_media(username, header)
        else:
            logging.warning(f"未知通话信令类型: 用户={username}, 类型={msg_type}")

    # ============================================================
    # 一对一（阶段 R1，语义不变）
    # ============================================================

    def _handle_invite(self, username, header):
        target = header.get("to")
        call_id = header.get("call_id")
        call_type = header.get("call_type", "audio")
        if (not target or not call_id or target == username
                or call_type not in ("audio", "video")):
            self._fail(username, call_id, "invalid")
            return
        if self.server.db.is_blocked(target, username):
            self._fail(username, call_id, "blocked")
            return
        if not self.server.db.is_friend(username, target):
            self._fail(username, call_id, "not_friend")
            return
        with self._lock:
            if self._is_busy(username) or self._is_busy(target):
                self._fail(username, call_id, "busy")
                return
            self.calls[call_id] = {
                "caller": username,
                "callee": target,
                "call_type": call_type,
                "accepted": False,
                "created": time.time(),
            }
        delivered = self.server.broadcast_to_user(
            target, "call_invite", "",
            extra_headers={"from": username, "call_id": call_id,
                           "call_type": call_type})
        if delivered == 0:
            with self._lock:
                self.calls.pop(call_id, None)
            self._fail(username, call_id, "offline")
            return
        logging.info(f"通话邀请已中继: {username} -> {target}, "
                     f"类型={call_type}, 呼叫ID={call_id}")

    def _handle_accept(self, username, header):
        call_id = header.get("call_id")
        with self._lock:
            call = self.calls.get(call_id)
            if (not call or call["callee"] != username or call["accepted"]):
                logging.info(f"无效的通话应答被忽略: 用户={username}, "
                             f"呼叫ID={call_id}")
                return
            call["accepted"] = True
            caller = call["caller"]
        self.server.broadcast_to_user(
            caller, "call_accept", "",
            extra_headers={"from": username, "call_id": call_id})
        # 多端振铃收敛：被叫全部会话得知本呼叫已接听（其他设备停止响铃）
        self.server.broadcast_to_user(
            username, "call_active", "",
            extra_headers={"from": username, "call_id": call_id})
        logging.info(f"通话已接听: {caller} <-> {username}, 呼叫ID={call_id}")

    def _handle_terminal(self, username, header, msg_type):
        call_id = header.get("call_id")
        with self._lock:
            call = self.calls.get(call_id)
            if not call:
                return
            allowed = {
                "call_reject": call["callee"] == username,
                "call_cancel": call["caller"] == username,
                "call_hangup": username in (call["caller"], call["callee"]),
            }
            if not allowed[msg_type]:
                logging.warning(f"无权发送该通话信令: 用户={username}, "
                                f"类型={msg_type}, 呼叫ID={call_id}")
                return
            del self.calls[call_id]
            target = call["callee"] if username == call["caller"] else call["caller"]
        self.server.broadcast_to_user(
            target, msg_type, "",
            extra_headers={"from": username, "call_id": call_id})
        logging.info(f"通话信令已中继: {username} -> {target}, "
                     f"类型={msg_type}, 呼叫ID={call_id}")

    def _handle_relay(self, username, header, msg_type, data):
        call_id = header.get("call_id")
        target = header.get("to")
        with self._lock:
            call = self.calls.get(call_id)
            if call is not None:
                if username not in (call["caller"], call["callee"]):
                    logging.warning(f"非通话参与者信令被丢弃: 用户={username}, "
                                    f"呼叫ID={call_id}")
                    return
                expected = (call["callee"] if username == call["caller"]
                            else call["caller"])
                if target != expected:
                    logging.warning(f"通话信令目标异常被丢弃: 用户={username}, "
                                    f"目标={target}, 呼叫ID={call_id}")
                    return
            else:
                room = self.rooms.get(call_id)
                if room is None:
                    logging.info(f"丢弃未知呼叫的信令: 用户={username}, "
                                 f"类型={msg_type}, 呼叫ID={call_id}")
                    return
                if (username not in room["participants"]
                        or target not in room["participants"]):
                    logging.warning(f"群通话信令参与者校验失败被丢弃: "
                                    f"用户={username}, 目标={target}, "
                                    f"房间ID={call_id}")
                    return
        self.server.broadcast_to_user(
            target, msg_type, data,
            extra_headers={"from": username, "call_id": call_id})

    # ============================================================
    # 群通话房间（阶段 R2）
    # ============================================================

    def _handle_group_invite(self, username, header):
        try:
            group_id = int(header.get("group_id"))
        except (TypeError, ValueError):
            group_id = None
        room_id = header.get("call_id")
        call_type = header.get("call_type", "audio")
        if group_id is None or not room_id or call_type not in ("audio", "video"):
            self._fail(username, room_id, "invalid")
            return
        group_info = self.server.db.get_group_info(group_id)
        if not group_info:
            self._fail(username, room_id, "invalid")
            return
        if not self.server.db.is_group_member(group_id, username):
            self._fail(username, room_id, "not_member")
            return
        group_name = group_info["group_name"]
        with self._lock:
            if self._is_busy(username):
                self._fail(username, room_id, "busy")
                return
            if self._group_has_room(group_id):
                self._fail(username, room_id, "busy")
                return
            online = self._online_usernames()
            logging.info(f"[r2diag] invite online={sorted(online)} "
                         f"members={self.server.db.get_group_members(group_id)}")
            ringing = {}
            for member in self.server.db.get_group_members(group_id):
                if member == username or member not in online:
                    logging.info(f"[r2diag] skip {member}: "
                                 f"online={member in online}")
                    continue
                if self._is_busy(member):
                    logging.info(f"[r2diag] skip {member}: busy")
                    continue
                ringing[member] = time.time()
            self.rooms[room_id] = {
                "group_id": group_id,
                "call_type": call_type,
                "participants": {username},
                "ringing": ringing,
                "created": time.time(),
            }
        for member in self.server.db.get_group_members(group_id):
            if member == username:
                continue
            self.server.broadcast_to_user(
                member, "group_call_invite", "",
                extra_headers={"from": username, "call_id": room_id,
                               "call_type": call_type, "group_id": group_id,
                               "group_name": group_name})
        logging.info(f"群通话邀请已中继: {username} -> 群组 {group_id}, "
                     f"类型={call_type}, 房间ID={room_id}, "
                     f"振铃={len(ringing)}人")

    def _handle_group_join(self, username, header):
        room_id = header.get("call_id")
        with self._lock:
            room = self.rooms.get(room_id)
            if not room:
                self._fail(username, room_id, "invalid")
                return
            group_id = room["group_id"]
            if username in room["participants"]:
                return
            if not self.server.db.is_group_member(group_id, username):
                self._fail(username, room_id, "not_member")
                return
            if self._is_busy(username) and username not in room["ringing"]:
                self._fail(username, room_id, "busy")
                return
            if len(room["participants"]) >= self.GROUP_CALL_MAX_PARTICIPANTS:
                self._fail(username, room_id, "full")
                return
            room["ringing"].pop(username, None)
            room["participants"].add(username)
            call_type = room["call_type"]
            participants = ",".join(sorted(room["participants"]))
        for member in self.server.db.get_group_members(group_id):
            self.server.broadcast_to_user(
                member, "group_call_joined", "",
                extra_headers={"from": username, "call_id": room_id,
                               "group_id": group_id,
                               "participants": participants,
                               "call_type": call_type})
        logging.info(f"群通话加入: {username} -> 房间 {room_id}, "
                     f"成员={participants}")

    def _handle_group_leave(self, username, header):
        room_id = header.get("call_id")
        with self._lock:
            room = self.rooms.get(room_id)
            if not room:
                return
            group_id = room["group_id"]
            if username in room["participants"]:
                reason = "cancel" if len(room["participants"]) == 1 else "hangup"
                room["participants"].discard(username)
            elif username in room["ringing"]:
                room["ringing"].pop(username, None)
                reason = "declined"
            else:
                return
            # 房间存续只看参与者：全体参与者离开即结束（振铃者收 ended
            # 停止响铃——微信式"主叫取消全员停铃"语义）
            ended = not room["participants"]
            participants = ",".join(sorted(room["participants"]))
            if ended:
                del self.rooms[room_id]
        for member in self.server.db.get_group_members(group_id):
            self.server.broadcast_to_user(
                member, "group_call_left", "",
                extra_headers={"from": username, "call_id": room_id,
                               "group_id": group_id,
                               "participants": participants,
                               "ended": "1" if ended else "0",
                               "reason": reason})
        logging.info(f"群通话离开: {username} -> 房间 {room_id}, "
                     f"原因={reason}, 结束={'是' if ended else '否'}")

    def _handle_group_media(self, username, header):
        room_id = header.get("call_id")
        mic = "1" if header.get("mic") == "1" else "0"
        cam = "1" if header.get("cam") == "1" else "0"
        with self._lock:
            room = self.rooms.get(room_id)
            if not room or username not in room["participants"]:
                return
            others = sorted(room["participants"] - {username})
        for member in others:
            self.server.broadcast_to_user(
                member, "group_call_media", "",
                extra_headers={"from": username, "call_id": room_id,
                               "mic": mic, "cam": cam})

    # ============================================================
    # 清理（断开 / 过期）
    # ============================================================

    def cleanup_user(self, username):
        """用户全部会话下线后的通话清理（client_handler finally 调用，
        须在 client_map_lock 之外）：1:1 主叫断开 → 被叫收 call_cancel；
        1:1 被叫断开 → 主叫收 call_hangup。群房间参与者断开 → 群广播
        group_call_left(reason=disconnect)，房间空则删除并 ended 通知
        振铃者；振铃者断开 → 静默移出 ringing。"""
        with self._lock:
            affected = []
            for call_id, call in list(self.calls.items()):
                if username not in (call["caller"], call["callee"]):
                    continue
                del self.calls[call_id]
                if username == call["caller"]:
                    affected.append((call_id, call["callee"], "call_cancel"))
                else:
                    affected.append((call_id, call["caller"], "call_hangup"))
            room_events = []
            for room_id, room in list(self.rooms.items()):
                if username in room["participants"]:
                    room["participants"].discard(username)
                    ended = not room["participants"]
                    room_events.append((
                        room_id, room["group_id"],
                        ",".join(sorted(room["participants"])), ended))
                    if ended:
                        del self.rooms[room_id]
                else:
                    room["ringing"].pop(username, None)
        for call_id, target, msg_type in affected:
            try:
                self.server.broadcast_to_user(
                    target, msg_type, "",
                    extra_headers={"from": username, "call_id": call_id})
            except Exception as e:
                logging.warning(f"通话断开通知失败: 用户={username}, "
                                f"呼叫ID={call_id}, 错误={e}")
        for room_id, group_id, participants, ended in room_events:
            try:
                for member in self.server.db.get_group_members(group_id):
                    self.server.broadcast_to_user(
                        member, "group_call_left", "",
                        extra_headers={"from": username, "call_id": room_id,
                                       "group_id": group_id,
                                       "participants": participants,
                                       "ended": "1" if ended else "0",
                                       "reason": "disconnect"})
            except Exception as e:
                logging.warning(f"群通话断开清理通知失败: 用户={username}, "
                                f"房间ID={room_id}, 错误={e}")

    def expire_calls(self, now=None):
        """清理超时未接听的邀请与群房间振铃（scheduler_scan 周期调用，
        可测试直驱）：1:1 主叫收 call_failed(reason=expired)，被叫全部
        会话收 call_cancel；群房间超时振铃成员移出并向全体群成员广播
        group_call_left(reason=timeout)（多端收敛）。已接听通话与房间
        参与者不受影响。返回被清理的 1:1 call_id 列表。"""
        now = now if now is not None else time.time()
        with self._lock:
            expired = [(call_id, call)
                       for call_id, call in self.calls.items()
                       if not call["accepted"]
                       and now - call["created"] >= self.CALL_INVITE_TIMEOUT]
            for call_id, _ in expired:
                del self.calls[call_id]
            expired_ringers = []
            for room_id, room in list(self.rooms.items()):
                for member, started in list(room["ringing"].items()):
                    if now - started >= self.CALL_INVITE_TIMEOUT:
                        del room["ringing"][member]
                        expired_ringers.append(
                            (room_id, member, room["group_id"],
                             ",".join(sorted(room["participants"]))))
                if not room["participants"] and not room["ringing"]:
                    del self.rooms[room_id]
        for call_id, call in expired:
            try:
                self._fail(call["caller"], call_id, "expired")
                self.server.broadcast_to_user(
                    call["callee"], "call_cancel", "",
                    extra_headers={"from": call["caller"],
                                   "call_id": call_id})
            except Exception as e:
                logging.warning(f"通话过期清理通知失败: 呼叫ID={call_id}, "
                                f"错误={e}")
        for room_id, member, group_id, participants in expired_ringers:
            try:
                for m in self.server.db.get_group_members(group_id):
                    self.server.broadcast_to_user(
                        m, "group_call_left", "",
                        extra_headers={"from": member, "call_id": room_id,
                                       "group_id": group_id,
                                       "participants": participants,
                                       "ended": "0", "reason": "timeout"})
            except Exception as e:
                logging.warning(f"群通话振铃过期清理通知失败: "
                                f"房间ID={room_id}, 成员={member}, 错误={e}")
        return [call_id for call_id, _ in expired]
