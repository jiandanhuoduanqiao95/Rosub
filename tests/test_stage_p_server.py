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
        h2 = recv_header_only(bob._sock)
        assert h2 is not None and h2['type'] == 'file', "离线文件头"
        assert h2['length'] == len(big)
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

        # bob 的初始数据流后续正常（list_friends 可达）
        seen_friends = False
        deadline = time.time() + 3
        while time.time() < deadline and not seen_friends:
            hh, _ = bob.recv(timeout=1)
            if hh is not None and hh['type'] == 'admin_response' \
                    and hh.get('response_type') == 'list_friends':
                seen_friends = True
        assert seen_friends, "文件补发后初始数据流中断"

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
        h2 = recv_header_only(bob._sock)
        assert h2['type'] == 'file'
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
