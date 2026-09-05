# ============================================================
# 阶段 P —— 服务端并发写竞态修复回归
# ============================================================
# 缺陷（2026-09-05 用户手测：登录后断线重连死循环）：
#   离线大文件补发（load_offline_data 的 send_file_message）是裸
#   sendall——不与 guarded_send 的 client_map_lock 互斥，也无
#   active_forward_socks 抑制。接收端（debug 客户端）读得慢时，
#   另一会话线程的 presence/聊天推送与 22MB 文件体并发写同一
#   SSL socket → TLS 记录交错（对端 BAD_LENGTH/EOF）→ 双向流错位
#   → 客户端登录初始数据阶段挂起/断开 → 重连 → 文件重推 → 死循环。
#
# 修复：per-socket 写互斥（Server.with_sock_write）——文件长写与
#   guarded_send 小消息对同一 socket 串行；长写期间推送在写锁上
#   排队（不丢失，活性失效才跳过）。
#
# 本测试以 socketpair 复现该时序（小缓冲天然制造"长写进行中"窗口），
# 锁定串行语义：文件体字节精确不被推送污染，推送在文件完成后送达。
# ============================================================

import time
from pathlib import Path

from protocol import recv_header_only, recvall

def _recv_until_file(client, message_id, timeout=5.0):
    """R-P14：消费登录初始数据直到文件头到达，返回 (文件头, 是否已见列表)。

    文件体补发已延后至 send_initial_data 之后（push_offline_files）——
    好友/群组列表**先于**文件体到达，登录响应后需消费中间消息。
    """
    saw_friends = False
    deadline = time.time() + timeout
    while time.time() < deadline:
        header = recv_header_only(client._sock)
        if header is None:
            break
        if header.get('type') == 'file' and header.get('message_id') == message_id:
            return header, saw_friends
        if header.get('type') == 'admin_response' \
                and header.get('response_type') == 'list_friends':
            saw_friends = True
        from protocol import recv_body
        recv_body(client._sock, header.get('length', 0))
    return None, saw_friends



class TestOfflineFileConcurrentPush:
    def test_offline_file_push_serializes_with_presence(self, harness, tmp_path):
        """离线大文件补发期间并发 presence 推送：流不交错、推送不丢失。"""
        h = harness

        # 构造 bob 的离线 file 消息（4MB，字节模式可辨识）
        big = bytes(range(256)) * (4 * 1024 * 1024 // 256)
        file_path = Path(tmp_path) / 'big.bin'
        file_path.write_bytes(big)
        h.db.save_offline_message('alice', 'bob', 'file', b'',
                                  filename='big.bin', message_id='mfile1',
                                  file_path=str(file_path))

        # bob 登录（手动消费：读到 file header 后故意不读 body，
        # 服务器线程随即阻塞在写锁内的 sendall——socketpair 小缓冲）
        bob = h.client()
        bob.send('login', 'bob', password='password456')
        h1, _ = bob.recv(timeout=3)
        assert h1 is not None and h1['type'] == 'chat', "登录响应"
        # R-P14：文件体在初始数据列表之后——先消费列表直到文件头
        h2, saw_friends_early = _recv_until_file(bob, 'mfile1')
        assert h2 is not None and h2['type'] == 'file', "离线文件头"
        assert h2['length'] == len(big)
        assert saw_friends_early, "R-P14：好友/群组列表应先于文件体到达"
        time.sleep(0.5)

        # alice 登录 → 服务器向 bob 推 presence——修复前此刻与文件体
        # 并发写同一 socket（交错损坏）；修复后在写锁上排队
        alice = h.client()
        alice.login('alice', 'password123')

        # bob 恢复读文件体：字节必须精确等于原文件（无推送字节混入）
        body = recvall(bob._sock, len(big))
        assert body == big, "文件体被并发推送污染（TLS 流交错）"

        # 文件发完后写锁释放，排队的 presence 才送达（顺序完整）
        deadline = time.time() + 3
        presence = None
        while time.time() < deadline and presence is None:
            hh, _ = bob.recv(timeout=1)
            if hh is not None and hh['type'] == 'presence':
                presence = hh
        assert presence is not None, "文件补发后未收到排队的 presence"
        assert presence['from'] == 'alice' and presence['online'] == '1'

    def test_guarded_send_waits_not_corrupts_during_long_write(self, harness, tmp_path):
        """guarded_send 与文件长写互斥：写锁内小消息在长写完成后到达。"""
        h = harness
        big = b'\xcd' * (2 * 1024 * 1024)
        file_path = Path(tmp_path) / 'mid.bin'
        file_path.write_bytes(big)
        h.db.save_offline_message('alice', 'bob', 'file', b'',
                                  filename='mid.bin', message_id='mfile2',
                                  file_path=str(file_path))

        bob = h.client()
        bob.send('login', 'bob', password='password456')
        h1, _ = bob.recv(timeout=3)
        assert h1['type'] == 'chat'
        # R-P14：文件体在初始数据列表之后——先消费列表直到文件头
        h2, _saw = _recv_until_file(bob, 'mfile2')
        assert h2 is not None and h2['type'] == 'file'
        time.sleep(0.3)

        # 另一线程直接对 bob 的 socket guarded_send（模拟聊天推送路径）
        alice = h.client()
        alice.login('alice', 'password123')
        bob_sock = None
        with h.server.client_map_lock:
            for (u, _d), s in h.server.client_map.items():
                if u == 'bob':
                    bob_sock = s
        assert bob_sock is not None
        import threading
        t = threading.Thread(
            target=lambda: h.server.guarded_send(
                bob_sock, 'chat', 'push-during-file',
                extra_headers={'from': 'alice', 'history': 'false'}),
            daemon=True)
        t.start()

        # 文件体完整
        body = recvall(bob._sock, len(big))
        assert body == big
        # 推送消息在文件之后完整到达
        got = None
        deadline = time.time() + 3
        while time.time() < deadline and got is None:
            hh, dd = bob.recv(timeout=1)
            if hh is not None and hh['type'] == 'chat' \
                    and dd == b'push-during-file':
                got = hh
        assert got is not None, "长写期间 guarded_send 消息丢失"
        t.join(timeout=2)


# ============================================================
# R-P21 —— 已下载文件重登元数据补推（用户实测"重登后重新下载"）
# ============================================================
# 缺陷（2026-09-05 用户手测）：接收方重登后，此前已完整接收过的文件
#   再次全量推送文件体（进度条气泡重现 + 重复消耗带宽）。
#
# 修复：push_offline_files 按接收记录判定——本设备（device_id 一致）
#   已接受过的文件与发送者自身回显改推 file_meta（同头部、无消息体、
#   追加 filesize 头），客户端仅重建/对账气泡；其他设备登录仍补发
#   完整文件体（多端文件同步语义不变，见 test_stage_g_server 重登段）。
# ============================================================

class TestOfflineFileMetaSkip:

    def _login_and_expect_meta(self, h, username, password, message_id):
        client = h.client()
        client.send('login', username, password=password)
        h1, _ = client.recv(timeout=3)
        assert h1 is not None and h1['type'] == 'chat', "登录响应"
        deadline = time.time() + 3
        while time.time() < deadline:
            hh, dd = client.recv(timeout=1)
            if hh is None:
                break
            if (hh.get('type') == 'file_meta'
                    and hh.get('message_id') == message_id):
                return client, (hh, dd)
        return client, None

    def test_accepted_same_device_file_pushes_meta_only(self, harness,
                                                        tmp_path):
        """本设备已接受过的文件：重登只收 file_meta，无文件体。"""
        h = harness
        payload = b'meta-only-payload' * 16
        file_path = Path(tmp_path) / 'doc.bin'
        file_path.write_bytes(payload)
        h.db.save_offline_message('alice', 'bob', 'file', b'',
                                  filename='doc.bin', message_id='rpx1',
                                  file_path=str(file_path))
        # bob 此前在本设备（default）完整接受过该文件
        h.db.record_file_resolution('rpx1', 'bob', 'accept', 'default')

        bob, meta = self._login_and_expect_meta(h, 'bob', 'password456',
                                                'rpx1')
        assert meta is not None, "本设备已接受文件应收到 file_meta 补推"
        assert meta[0].get('history') == 'true'
        assert meta[0].get('filesize') == str(len(payload)), \
            "file_meta 应携带 filesize 头（气泡大小显示）"
        assert meta[1] == b'', "file_meta 不得携带消息体"
        # 补发窗口内不得再出现同 id 完整文件体
        deadline = time.time() + 1
        while time.time() < deadline:
            hh, dd = bob.recv(timeout=0.5)
            if hh is None:
                break
            assert not (hh.get('type') == 'file'
                        and hh.get('message_id') == 'rpx1'), \
                "同设备重登不得再推送完整文件体"

    def test_sender_self_echo_pushes_meta_only(self, harness, tmp_path):
        """发送者自身回显：原文件在发送端本地，重登只收 file_meta。"""
        h = harness
        payload = b'self-echo' * 8
        file_path = Path(tmp_path) / 'sent.bin'
        file_path.write_bytes(payload)
        # 发送者回显行（sender=alice, receiver=bob）：alice 重登时命中
        h.db.save_offline_message('alice', 'bob', 'file', b'',
                                  filename='sent.bin', message_id='rpx2',
                                  file_path=str(file_path))

        alice, meta = self._login_and_expect_meta(h, 'alice', 'password123',
                                                  'rpx2')
        assert meta is not None, "发送者回显应收到 file_meta 补推"
        assert meta[0].get('to') == 'bob', "发送者回显应带 to 头"
        assert meta[1] == b'', "file_meta 不得携带消息体"

    def test_unaccepted_file_still_pushes_full_body(self, harness, tmp_path):
        """无接受记录（历史遗留/未接受）：仍补发完整文件体（保守兼容）。"""
        h = harness
        payload = b'legacy-body' * 8
        file_path = Path(tmp_path) / 'old.bin'
        file_path.write_bytes(payload)
        h.db.save_offline_message('alice', 'bob', 'file', b'',
                                  filename='old.bin', message_id='rpx3',
                                  file_path=str(file_path))
        # 不写 file_request_resolutions——旧行为完整补发

        bob = h.client()
        bob.send('login', 'bob', password='password456')
        h1, _ = bob.recv(timeout=3)
        assert h1['type'] == 'chat'
        h2, _saw = _recv_until_file(bob, 'rpx3')
        assert h2 is not None and h2['type'] == 'file', \
            "无接受记录应仍补发完整文件体"
        assert h2['length'] == len(payload)
        from protocol import recvall
        assert recvall(bob._sock, len(payload)) == payload
