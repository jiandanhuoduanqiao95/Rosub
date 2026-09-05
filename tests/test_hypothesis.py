"""
============================================================
Hypothesis 属性测试 + 状态机测试
============================================================

引入 Hypothesis 做"属性测试"与"有状态机测试"，弥补传统
示例驱动测试的盲区：

1. validate_username / validate_password 属性测试
   - 任意合法字符集的用户名必定通过；任意含非法字符的必被拒
   - 密码长度边界属性

2. FriendsStateMachine（RuleBasedStateMachine）
   - 用 4 个用户的好友关系状态机对照"参考模型"与真实 Database
   - 随机生成 add_request / accept / reject 序列，断言每一步
     DB 返回值与模型一致，且不变式（对称性、pending/accepted
     一致性、get_friends 集合）始终成立

3. OfflineMessageStateMachine
   - 离线消息 sent→delivered→recalled 状态流转状态机
   - 断言 get_offline_messages 返回集合与模型一致，
     recalled 永不出现，delivered 清理后消失

4. protocol 往返属性测试
   - 任意 bytes 内容 + 任意字符串头部，编解码往返保持一致
   - 使用内存 FakeSocket（不触网，兼容 pytest-socket 守护）
"""

import os
import sys
import pytest
from hypothesis import given, strategies as st, settings, HealthCheck, assume
from hypothesis.stateful import (
    RuleBasedStateMachine,
    rule,
    invariant,
    run_state_machine_as_test,
)

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from validation import validate_username, validate_password
from protocol import send_message, recv_message


# ============================================================
# 第 1 组：输入验证属性测试
# ============================================================

# 仅含 ASCII 字母/数字/下划线/连字符的用户名策略（与 validation 正则一致）
# 注意：validation.py 仍会对包含 "--" 的用户名做纵深防御拒绝（即使正则允许），
# 因此"合法"策略需排除 "--" 子串，以保证属性成立。
_ASCII_USERNAME = st.from_regex(r"[a-zA-Z0-9_-]{3,32}", fullmatch=True) \
    .filter(lambda s: "--" not in s)


class TestValidationProperties:

    @given(username=_ASCII_USERNAME)
    @settings(max_examples=80, deadline=None)
    def test_valid_username_always_accepted(self, username):
        """任意由 ASCII 字母/数字/下划线/连字符组成且长度 3-32（不含 "--"）的用户名必通过。"""
        valid, error = validate_username(username)
        assert valid, f"应通过: {username!r}, 错误: {error}"

    def test_double_hyphen_rejected_as_dangerous(self):
        """纵深防御：含 "--"（SQL 注释符）的用户名即使正则允许也被拒绝。"""
        valid, _ = validate_username("--ab")
        assert valid is False
        valid, _ = validate_username("ab--cd")
        assert valid is False

    @given(username=st.text(min_size=1, max_size=40))
    @settings(max_examples=100, deadline=None)
    def test_username_rejects_non_whitelisted(self, username):
        """含白名单以外字符（且 strip 后非空、长度≥3）的用户名必被拒。"""
        import re
        if len(username.strip()) < 3:
            assume(False)
        # 若只含白名单字符且长度合法 → 合法，跳过（本测试关注非法情况）
        if re.fullmatch(r"[a-zA-Z0-9_-]{3,32}", username):
            assume(False)
        valid, _ = validate_username(username)
        assert not valid, f"应被拒: {username!r}"

    @given(password=st.text(min_size=0, max_size=200, alphabet=st.characters(blacklist_categories=("Cc",))))
    @settings(max_examples=80, deadline=None)
    def test_password_length_boundary(self, password):
        """密码仅由非控制字符组成时，合法性完全由长度 6-128 决定。"""
        valid, _ = validate_password(password)
        if 6 <= len(password) <= 128:
            assert valid
        else:
            assert not valid

    @given(password=st.text(min_size=1, max_size=10, alphabet=st.characters(whitelist_categories=("Cc",))))
    @settings(max_examples=30, deadline=None)
    def test_password_rejects_control_chars(self, password):
        """包含任意控制字符的密码必被拒（即使长度足够）。"""
        valid, _ = validate_password(password)
        assert not valid


# ============================================================
# 第 2 组：好友关系状态机
# ============================================================

class FriendsStateMachine(RuleBasedStateMachine):
    """对照参考模型验证 Database 好友关系状态机。

    模型：
      - users: 固定集合 {a,b,c,d}
      - accepted: set(frozenset({x,y})) 已接受的好友对（无序）
      - pending: set((requester, target)) 待处理请求（有序）

    不变式：
      - is_friend 对称
      - 已接受 ⇒ 双向 is_friend 为 True
      - pending ⇒ is_friend 为 False
      - get_friends(u) == {与 u 已接受的所有对方}
    """

    def __init__(self):
        super().__init__()
        import tempfile
        import bcrypt
        from database import Database

        self._tmp = tempfile.mkdtemp(prefix="hypo_friends_")
        self.db = Database(os.path.join(self._tmp, "f.db"))
        self._pw = bcrypt.hashpw(b"x", bcrypt.gensalt())
        for n in ("a", "b", "c", "d"):
            self.db.add_user(n, self._pw)
        self.users = {"a", "b", "c", "d"}
        self.accepted = set()
        self.pending = set()

    def _model_add_request(self, r, t):
        if r == t:
            return False
        if r not in self.users or t not in self.users:
            return False
        if frozenset({r, t}) in self.accepted:
            return False
        if (r, t) in self.pending or (t, r) in self.pending:
            return False
        return True

    @rule(r=st.sampled_from(["a", "b", "c", "d"]),
          t=st.sampled_from(["a", "b", "c", "d"]))
    def add_request(self, r, t):
        expected = self._model_add_request(r, t)
        actual = self.db.add_friend_request(r, t)
        assert actual == expected, (
            f"add_friend_request({r},{t}): model={expected}, db={actual}, "
            f"pending={self.pending}, accepted={self.accepted}")
        if actual:
            self.pending.add((r, t))

    @rule(r=st.sampled_from(["a", "b", "c", "d"]),
          t=st.sampled_from(["a", "b", "c", "d"]))
    def accept(self, r, t):
        if (r, t) not in self.pending:
            return  # 仅在存在 (r,t) pending 时才接受，保持模型精确
        actual = self.db.accept_friend_request(r, t)
        assert actual is True, f"accept({r},{t}) 应成功"
        self.pending.discard((r, t))
        self.accepted.add(frozenset({r, t}))

    @rule(r=st.sampled_from(["a", "b", "c", "d"]),
          t=st.sampled_from(["a", "b", "c", "d"]))
    def reject(self, r, t):
        if (r, t) not in self.pending and (t, r) not in self.pending:
            return  # 仅在任一方向 pending 时才拒绝
        actual = self.db.reject_friend_request(r, t)
        assert actual is True, f"reject({r},{t}) 应成功"
        self.pending.discard((r, t))
        self.pending.discard((t, r))

    @invariant()
    def accepted_implies_symmetric_friendship(self):
        for pair in self.accepted:
            a, b = tuple(pair)
            assert self.db.is_friend(a, b) is True, f"已接受 {pair} 但 is_friend({a},{b}) 为 False"
            assert self.db.is_friend(b, a) is True, f"is_friend 不对称: {pair}"

    @invariant()
    def pending_implies_not_friend(self):
        for (r, t) in self.pending:
            assert self.db.is_friend(r, t) is False, f"pending ({r},{t}) 但已是好友"
            assert self.db.has_pending_request(r, t) is True, f"pending ({r},{t}) 未被记录"

    @invariant()
    def get_friends_consistent(self):
        for u in self.users:
            expected = {x for pair in self.accepted for x in tuple(pair)
                        if u in pair and x != u}
            actual = set(self.db.get_friends(u))
            assert actual == expected, (
                f"get_friends({u}) 不一致: model={expected}, db={actual}")


def test_friends_state_machine():
    """运行好友关系状态机。"""
    run_state_machine_as_test(
        FriendsStateMachine,
        settings=settings(
            max_examples=40,
            stateful_step_count=60,
            deadline=None,
            suppress_health_check=[HealthCheck.too_slow],
        ),
    )


# ============================================================
# 第 3 组：离线消息状态机
# ============================================================

class OfflineMessageStateMachine(RuleBasedStateMachine):
    """对照参考模型验证离线消息状态流转。

    模型：
      - users: {alice, bob}
      - msgs: dict mid -> (sender, receiver, status)
      - status ∈ {sent, delivered, recalled}

    规则：
      - save(sender, receiver, mid)
      - get(user): 返回 (receiver==user 或 (sender==user 且 receiver!=user)) 且 status∈{sent,delivered}
        的消息；随后将 receiver==user 且 status==sent 标记 delivered
      - update_status(mid, status)
      - cleanup_delivered(user): 删除 receiver==user 且 status==delivered
    """

    def __init__(self):
        super().__init__()
        import tempfile
        import bcrypt
        from database import Database

        self._tmp = tempfile.mkdtemp(prefix="hypo_offline_")
        self.db = Database(os.path.join(self._tmp, "o.db"))
        self._pw = bcrypt.hashpw(b"x", bcrypt.gensalt())
        for n in ("alice", "bob"):
            self.db.add_user(n, self._pw)
        self.msgs = {}  # mid -> (sender, receiver, status)

    @rule(sender=st.sampled_from(["alice", "bob"]),
          receiver=st.sampled_from(["alice", "bob"]),
          mid=st.text(min_size=1, max_size=8, alphabet=st.characters(whitelist_categories=("Lu", "Ll", "Nd"))))
    def save(self, sender, receiver, mid):
        assume(mid not in self.msgs)  # 避免主键冲突
        self.db.save_offline_message(sender, receiver, "chat", b"m", message_id=mid)
        self.msgs[mid] = (sender, receiver, "sent")

    @rule(user=st.sampled_from(["alice", "bob"]))
    def get(self, user):
        rows = self.db.get_offline_messages(user)
        actual_ids = {r[4] for r in rows}
        expected_ids = {
            mid for mid, (s, r, st_) in self.msgs.items()
            if st_ in ("sent", "delivered")
            and (r == user or (s == user and r != user))
        }
        assert actual_ids == expected_ids, (
            f"get_offline_messages({user}) 不一致: model={expected_ids}, db={actual_ids}")
        # 模型同步：receiver==user 且 sent → delivered
        for mid, (s, r, st_) in list(self.msgs.items()):
            if r == user and st_ == "sent":
                self.msgs[mid] = (s, r, "delivered")

    @rule(mid=st.sampled_from(list("xyz")), status=st.sampled_from(["sent", "delivered", "recalled"]))
    def update_status(self, mid, status):
        # 使用已存在的 mid（从固定小集合里挑，命中存在的概率合理）
        if mid not in self.msgs:
            assume(False)
        expected = mid in self.msgs
        actual = self.db.update_message_status(mid, status)
        assert actual == expected
        if actual:
            s, r, _ = self.msgs[mid]
            self.msgs[mid] = (s, r, status)

    @rule(user=st.sampled_from(["alice", "bob"]))
    def cleanup_delivered(self, user):
        deleted = self.db.cleanup_delivered_messages(user)
        expected_ids = {mid for mid, (s, r, st_) in self.msgs.items()
                        if r == user and st_ == "delivered"}
        assert deleted == len(expected_ids), (
            f"cleanup_delivered({user}) 数量不一致: model={len(expected_ids)}, db={deleted}")
        for mid in expected_ids:
            del self.msgs[mid]

    @invariant()
    def db_status_matches_model(self):
        """非变更式不变式：每条模型消息的 DB 状态与模型一致。

        注意：不能用 get_offline_messages 做不变式检查——它有
        sent→delivered 的副作用，会破坏模型同步。改用无副作用的
        get_message_info 逐条核对。
        """
        for mid, (s, r, st_) in self.msgs.items():
            info = self.db.get_message_info(mid)
            assert info is not None, f"{mid} 应仍存在"
            assert info[5] == st_, f"{mid} 状态不一致: model={st_}, db={info[5]}"
            # recalled 消息由 get/delete 时被排除，这里间接保证：
            # 模型从不把 recalled 放入 sent/delivered 集合
            assert st_ in ("sent", "delivered", "recalled")


def test_offline_message_state_machine():
    """运行离线消息状态机。"""
    run_state_machine_as_test(
        OfflineMessageStateMachine,
        settings=settings(
            max_examples=40,
            stateful_step_count=60,
            deadline=None,
            suppress_health_check=[HealthCheck.too_slow],
        ),
    )


# ============================================================
# 第 4 组：协议往返属性测试（内存 FakeSocket，不触网）
# ============================================================

class FakeSocket:
    """内存双工 socket：sendall 写入缓冲，recv 读取缓冲。

    用于在不创建真实 socket 的情况下验证 protocol 编解码，
    兼容 pytest-socket 的 socket_disabled 守护。
    """

    def __init__(self):
        self._buf = bytearray()

    def sendall(self, data):
        self._buf.extend(data)

    def recv(self, n):
        if n <= 0 or not self._buf:
            return b""
        chunk = bytes(self._buf[:n])
        del self._buf[:n]
        return chunk

    def close(self):
        self._buf.clear()


class TestProtocolProperty:

    @given(content=st.binary(min_size=0, max_size=4096),
           msg_type=st.sampled_from(["chat", "file", "login", "group_chat"]),
           extra=st.dictionaries(
               keys=st.text(min_size=1, max_size=10, alphabet=st.characters(whitelist_categories=("Lu", "Ll", "Nd"))),
               values=st.text(min_size=0, max_size=20),
               max_size=5))
    @settings(max_examples=60, deadline=None)
    def test_roundtrip_preserves_content_and_headers(self, content, msg_type, extra):
        assume("type" not in extra and "length" not in extra)
        s = FakeSocket()
        try:
            send_message(s, msg_type, content, extra_headers=extra)
            header, body = recv_message(s)
            assert header is not None
            assert header["type"] == msg_type
            assert body == content
            assert header["length"] == len(content)
            for k, v in extra.items():
                assert header[k] == v
        finally:
            s.close()

    @given(content=st.binary(min_size=0, max_size=2048), chunk=st.integers(min_value=1, max_value=64))
    @settings(max_examples=30, deadline=None)
    def test_chunked_roundtrip(self, content, chunk):
        """任意分块大小下编解码往返保持一致。"""
        s = FakeSocket()
        try:
            send_message(s, "chat", content, chunk_size=chunk)
            header, body = recv_message(s, chunk_size=chunk)
            assert body == content
        finally:
            s.close()
