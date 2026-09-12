import logging
import threading
import time


class CallHandler:
    """阶段 R1：音视频通话信令中继（纯内存态，无 DB、不落协议既有表）。

    消息类型（协议 v1.0.0 向后兼容扩展，tkinter 忽略未知类型）：
      call_invite / call_accept / call_reject / call_cancel / call_hangup /
      call_offer / call_answer / call_ice（C→S 中继）
      call_active / call_failed（仅 S→C）

    通话占用为用户级（caller/callee 任一角色即占线，含振铃中未接听）；
    多会话（阶段 L1）下信令统一 broadcast_to_user 到目标用户全部会话，
    接听后 call_active 收敛其余设备振铃。
    """

    CALL_INVITE_TIMEOUT = 60.0

    _FAIL_TEXTS = {
        "invalid": "呼叫参数无效",
        "not_friend": "对方不是您的好友，无法呼叫",
        "blocked": "对方已将您拉黑，无法呼叫",
        "offline": "对方不在线",
        "busy": "对方忙线中",
        "expired": "对方无应答",
    }

    def __init__(self, server):
        self.server = server
        # call_id -> {"caller", "callee", "call_type", "accepted", "created"}
        self.calls = {}
        self._lock = threading.Lock()

    def _fail(self, username, call_id, reason):
        self.server.broadcast_to_user(
            username, "call_failed", self._FAIL_TEXTS.get(reason, "呼叫失败"),
            extra_headers={"call_id": call_id or "", "reason": reason})

    def _is_busy(self, username):
        return any(call["caller"] == username or call["callee"] == username
                   for call in self.calls.values())

    def handle(self, username, ssock, msg_type, header, data):
        if msg_type == "call_invite":
            self._handle_invite(username, header)
        elif msg_type == "call_accept":
            self._handle_accept(username, header)
        elif msg_type in ("call_reject", "call_cancel", "call_hangup"):
            self._handle_terminal(username, header, msg_type)
        elif msg_type in ("call_offer", "call_answer", "call_ice"):
            self._handle_relay(username, header, msg_type, data)
        else:
            logging.warning(f"未知通话信令类型: 用户={username}, 类型={msg_type}")

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
            if not call:
                logging.info(f"丢弃未知呼叫的信令: 用户={username}, "
                             f"类型={msg_type}, 呼叫ID={call_id}")
                return
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
        self.server.broadcast_to_user(
            target, msg_type, data,
            extra_headers={"from": username, "call_id": call_id})

    def cleanup_user(self, username):
        """用户全部会话下线后的通话清理（client_handler finally 调用，
        须在 client_map_lock 之外）：主叫断开 → 被叫收 call_cancel；
        被叫断开 → 主叫收 call_hangup。"""
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
        for call_id, target, msg_type in affected:
            try:
                self.server.broadcast_to_user(
                    target, msg_type, "",
                    extra_headers={"from": username, "call_id": call_id})
            except Exception as e:
                logging.warning(f"通话断开通知失败: 用户={username}, "
                                f"呼叫ID={call_id}, 错误={e}")

    def expire_calls(self, now=None):
        """清理超时未接听的邀请（scheduler_scan 周期调用，可测试直驱）：
        主叫收 call_failed(reason=expired)，被叫全部会话收 call_cancel。
        已接听的通话不受影响。返回被清理的 call_id 列表。"""
        now = now if now is not None else time.time()
        with self._lock:
            expired = [(call_id, call)
                       for call_id, call in self.calls.items()
                       if not call["accepted"]
                       and now - call["created"] >= self.CALL_INVITE_TIMEOUT]
            for call_id, _ in expired:
                del self.calls[call_id]
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
        return [call_id for call_id, _ in expired]
