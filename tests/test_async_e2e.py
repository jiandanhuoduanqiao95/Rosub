"""
============================================================
异步端到端测试（pytest-asyncio）
============================================================

用 asyncio 事件循环编排多个客户端连接到同进程真实 TCP 测试服务器，
验证并发场景下的消息路由与状态一致性。相比 test_e2e.py 的"线程 +
同步 socket"方式，asyncio 编排时序更清晰、断言更精确。

服务器仍以线程方式运行（handle_client 是阻塞模型），客户端用
asyncio.open_connection 经 loopback 连入，两者通过 TCP 解耦。

【pytest-asyncio】asyncio_mode=auto 自动识别 async def 测试。
"""

import os
import sys
import json
import uuid
import pytest
import asyncio

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from protocol import send_message as py_send  # 仅用于类型参考


pytestmark = pytest.mark.asyncio


# ============================================================
# 异步客户端辅助
# ============================================================

class AsyncClient:
    """基于 asyncio streams 的无头测试客户端。"""

    def __init__(self, host="127.0.0.1", port=8090):
        self.host = host
        self.port = port
        self.reader = None
        self.writer = None
        self.username = None

    async def connect(self):
        self.reader, self.writer = await asyncio.open_connection(self.host, self.port)

    async def close(self):
        if self.writer:
            try:
                self.writer.close()
                await self.writer.wait_closed()
            except Exception:
                pass

    async def send(self, msg_type, content, **extra):
        assert self.writer is not None
        data = content.encode("utf-8") if isinstance(content, str) else content
        extra = {str(k): str(v) for k, v in extra.items()}
        header = {"type": msg_type, "length": len(data)}
        header.update(extra)
        import json as _json
        header_json = _json.dumps(header).encode("utf-8")
        import struct
        self.writer.write(struct.pack("!I", len(header_json)))
        self.writer.write(header_json)
        self.writer.write(data)
        await self.writer.drain()

    async def recv(self, timeout=3.0):
        try:
            raw = await asyncio.wait_for(self.reader.readexactly(4), timeout)
        except asyncio.IncompleteReadError:
            return None, None
        except asyncio.TimeoutError:
            return None, None
        import struct
        header_len = struct.unpack("!I", raw)[0]
        header_json = await asyncio.wait_for(self.reader.readexactly(header_len), timeout)
        import json as _json
        header = _json.loads(header_json.decode("utf-8"))
        length = header.get("length", 0)
        body = b""
        while len(body) < length:
            chunk = await asyncio.wait_for(
                self.reader.readexactly(length - len(body)), timeout)
            body += chunk
        return header, body

    async def login(self, username, password, admin_secret=None, consume=True):
        self.username = username
        extra = {"password": password}
        if admin_secret:
            extra["admin_secret"] = admin_secret
        await self.send("login", username, **extra)
        if consume:
            return await self.consume_initial()

    async def register(self, username, password, consume=True):
        self.username = username
        await self.send("register", username, password=password)
        if consume:
            return await self.consume_initial()

    async def consume_initial(self):
        result = {"login_ok": False, "friends": [], "groups": [],
                  "offline": [], "friend_requests": [], "file_requests": [],
                  "friend_meta": [], "blocked": [], "conversations": [], "extra": []}
        h, d = await self.recv()
        if h is None:
            return result
        if h.get("type") in ("chat", "admin_auth"):
            result["login_ok"] = True
            result["login_response"] = (h, d)
        else:
            result["extra"].append((h, d))
        got_friends = False
        got_groups = False
        got_meta = False
        got_blocked = False
        for _ in range(40):
            h, d = await self.recv(timeout=1.5)
            if h is None:
                break
            t = h.get("type")
            if h.get("history") == "true":
                result["offline"].append((h, d))
            elif t == "friend_request":
                result["friend_requests"].append((h, d))
            elif t in ("file_request", "group_file_request"):
                result["file_requests"].append((h, d))
            elif t == "admin_response" and h.get("response_type") == "list_friends":
                result["friends"] = json.loads(d.decode()) if d else []
                got_friends = True
            elif t == "admin_response" and h.get("response_type") == "list_friends_meta":
                result["friend_meta"] = json.loads(d.decode()) if d else []
                got_meta = True
            elif t == "admin_response" and h.get("response_type") == "list_blocked":
                result["blocked"] = json.loads(d.decode()) if d else []
                got_blocked = True
            elif t == "admin_response" and h.get("response_type") == "list_conversations":
                result["conversations"] = json.loads(d.decode()) if d else []
            elif t == "list_groups":
                result["groups"] = json.loads(d.decode()) if d else []
                got_groups = True
            else:
                result["extra"].append((h, d))
            if got_friends and got_groups and got_meta and got_blocked:
                break
        # 阶段 K 尾随消费：list_conversations 在 list_blocked 之后推送（最后一条），
        # 主循环在收齐四个列表后已 break，这里短超时补读一次，缓冲不残留
        try:
            h, d = await self.recv(timeout=0.2)
            if (h is not None and h.get("type") == "admin_response"
                    and h.get("response_type") == "list_conversations"):
                result["conversations"] = json.loads(d.decode()) if d else []
        except asyncio.TimeoutError:
            pass
        return result

    async def drain(self, timeout=0.5):
        count = 0
        while True:
            h, _ = await self.recv(timeout=timeout)
            if h is None:
                break
            count += 1
        return count

    async def send_chat(self, target, message):
        mid = str(uuid.uuid4())
        await self.send("chat", message, to=target, message_id=mid)
        return mid


# ============================================================
# 异步 E2E 测试
# ============================================================

class TestAsyncE2EAuth:
    """认证与私聊的异步编排。"""

    async def test_register_add_friend_chat(self, tcp_server):
        """两用户注册 → 加好友 → 实时私聊（asyncio 编排）。"""
        alice = AsyncClient(port=tcp_server.port)
        bob = AsyncClient(port=tcp_server.port)
        await alice.connect()
        await bob.connect()

        # 使用不与预置用户冲突的名字
        r_a = await alice.register("ava", "ava12345")
        assert r_a["login_ok"]
        r_b = await bob.register("ben", "ben12345")
        assert r_b["login_ok"]

        # alice 向 bob 发好友请求
        await alice.send("friend_request", "", to="ben")
        h, _ = await bob.recv(timeout=3)
        assert h is not None and h.get("type") == "friend_request"

        # bob 接受
        await bob.send("accept_friend", "", **{"from": "ava"})
        await bob.recv(timeout=2)
        await alice.recv(timeout=2)

        # alice 发消息，bob 实时收到
        await alice.send_chat("ben", "async hello")
        h, d = await bob.recv(timeout=3)
        assert h is not None and h.get("type") == "chat"
        assert "async hello" in d.decode()

        await alice.close()
        await bob.close()

    async def test_offline_message_async(self, tcp_server):
        """离线消息：bob 下线后 alice 发消息，bob 重新上线收到。"""
        alice = AsyncClient(port=tcp_server.port)
        bob = AsyncClient(port=tcp_server.port)
        await alice.connect()
        await bob.connect()
        await alice.register("ava", "ava12345")
        await alice.drain(0.3)
        await bob.register("ben", "ben12345")
        await bob.drain(0.3)

        # 加好友
        await alice.send("friend_request", "", to="ben")
        await bob.recv(timeout=2)
        await bob.send("accept_friend", "", **{"from": "ava"})
        await alice.drain(1.0)
        await bob.drain(1.0)

        # bob 下线
        await bob.close()
        await asyncio.sleep(0.2)
        # 阶段 J：消费 bob 下线的 presence 广播（通知性噪声）
        await alice.drain(1.0)

        # alice 发消息给离线 bob
        await alice.send_chat("ben", "while you were away")
        h, d = await alice.recv(timeout=2)
        assert h is not None
        assert "离线" in d.decode() or h.get("type") == "chat"

        await alice.close()

        # bob 重新上线
        bob2 = AsyncClient(port=tcp_server.port)
        await bob2.connect()
        r = await bob2.login("ben", "ben12345")
        offline_texts = [d.decode() for h, d in r["offline"]
                         if h.get("type") == "chat" and d]
        assert any("while you were away" in t for t in offline_texts), \
            f"bob 应收到离线消息，实际: {offline_texts}"
        await bob2.close()


class TestAsyncE2EGroup:
    """群组并发广播的异步编排。"""

    async def test_group_broadcast_concurrent(self, tcp_server):
        """群组创建 → 两成员并发在线 → 群聊广播到每个在线成员。"""
        alice = AsyncClient(port=tcp_server.port)
        bob = AsyncClient(port=tcp_server.port)
        await alice.connect()
        await bob.connect()
        await alice.register("ava", "ava12345")
        await bob.register("ben", "ben12345")
        await alice.drain(0.3)
        await bob.drain(0.3)

        # alice 建群
        await alice.send("create_group", "asyncgrp")
        await alice.drain(1.0)
        # 取群组 ID
        await alice.send("list_groups", "")
        h, d = await alice.recv(timeout=2)
        groups = json.loads(d.decode())
        gid = str(groups[0]["id"])

        # bob 加入（阶段 M：join_group 改为申请制，测试前置直接落库）
        tcp_server.db.join_group(int(gid), "ben")

        # alice 发群聊，bob 并发收到
        mid = str(uuid.uuid4())
        await alice.send("group_chat", "group broadcast async", group_id=gid, message_id=mid)
        h, d = await bob.recv(timeout=3)
        assert h is not None and h.get("type") == "group_chat"
        assert "group broadcast async" in d.decode()

        await alice.close()
        await bob.close()