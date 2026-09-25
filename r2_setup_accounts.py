"""R2 三端真机测试数据准备：真实协议路径建账号/好友/群（gc1，2026-09-21）"""
import os
import ssl
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from protocol import send_message, recv_message

HOST, PORT = "127.0.0.1", 8090
USERS = {
    "lin_a": "lin123456", "lin_b": "lin123456",
    "win_test": "win123456", "and_test": "and123456",
}
FRIEND_PAIRS = [("lin_a", "lin_b"), ("lin_a", "win_test"),
                ("lin_b", "win_test"), ("lin_a", "and_test"),
                ("win_test", "and_test")]
GROUP_NAME = "R2群通话测试群"


def connect():
    raw = __import__("socket").create_connection((HOST, PORT), timeout=10)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx.wrap_socket(raw, server_hostname="tset.cn")


class Client:
    def __init__(self, sock):
        self.sock = sock

    def send(self, msg_type, content, **headers):
        send_message(self.sock, msg_type, content, extra_headers=headers)

    def recv(self, timeout=5):
        self.sock.settimeout(timeout)
        try:
            return recv_message(self.sock)
        except (TimeoutError, __import__("socket").timeout):
            return None, None

    def expect(self, msg_type, timeout=5):
        deadline = time.time() + timeout
        while time.time() < deadline:
            h, d = self.recv(timeout=max(0.1, deadline - time.time()))
            if h is None:
                continue
            if h.get("type") == msg_type:
                return h, d
        raise AssertionError(f"等待 {msg_type} 超时")

    def login(self, username, password):
        self.send("login", username, password=password)
        self.recv_initial()

    def recv_initial(self):
        deadline = time.time() + 8
        while time.time() < deadline:
            h, d = self.recv(timeout=1)
            if h is None:
                break
            if h.get("type") == "admin_response" and \
                    h.get("response_type") == "list_conversations":
                break


def main():
    clients = {}
    for username, password in USERS.items():
        sock = connect()
        c = Client(sock)
        c.send("register", username, password=password)
        h, d = c.recv(5)
        t = h.get("type") if h else "?"
        if t == "error" and "已存在" in (d or b"").decode("utf-8", "ignore"):
            c.login(username, password)
            print(f"[skip] {username} 已存在，直接登录")
        elif t == "chat":
            print(f"[ok] 注册 {username}")
            c.recv_initial()
        else:
            raise AssertionError(f"注册 {username} 异常: {t} {d}")
        clients[username] = c

    for a, b in FRIEND_PAIRS:
        ca, cb = clients[a], clients[b]
        ca.send("friend_request", f"测试好友-{a}->{b}", to=b)
        cb.expect("friend_request")
        cb.send("accept_friend", "", to=a)
        ca.expect("chat")
        print(f"[ok] 好友 {a}<->{b}")

    owner = clients["lin_a"]
    owner.send("create_group", GROUP_NAME)
    h, d = owner.expect("chat")
    body = d.decode("utf-8")
    assert "创建成功" in body, body
    group_id = int(body.rsplit(":", 1)[1].strip())
    print(f"[ok] 建群 {GROUP_NAME} id={group_id}")

    for member in ("lin_b", "win_test", "and_test"):
        owner.send("invite_group_member", "", group_id=group_id, target=member)
        cm = clients[member]
        cm.expect("group_invite")
        cm.send("accept_group_invite", "", group_id=group_id)
        cm.expect("chat")
        print(f"[ok] {member} 入群 {group_id}")

    for c in clients.values():
        c.sock.close()
    print(f"[done] group_id={group_id}")


if __name__ == "__main__":
    main()
