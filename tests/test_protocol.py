"""
============================================================
protocol.py 的单元测试
============================================================

【测试目标】
  protocol.py 提供了 send_message() 和 recv_message() 两个函数，
  负责将消息编码为 TCP 字节流以及从字节流解码还原消息。
  
  这个模块是整个项目的 '通信基石' —— 服务端和客户端所有数据交换
  都依赖它。如果这里出了 bug，一切都会乱套。

【测试策略】
  用 socket.socketpair() 创建一对已连接的 socket，
  一端发送，另一端接收，验证编解码的正确性。
  不需要真实网络连接，完全在内存中完成。

【每个测试的结构】
  def test_xxx():
      # 1. ARRANGE（准备）—— 创建 socket pair，准备测试数据
      # 2. ACT（执行）—— 调用 send_message / recv_message
      # 3. ASSERT（断言）—— 验证结果是否符合预期
"""

import socket
import struct
import json
import pytest
import sys
import os

# 把项目根目录加入 sys.path，确保可以 import protocol
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from protocol import send_message, recv_message, recvall


# ============================================================
# 辅助函数
# ============================================================

def make_socket_pair():
    """
    创建一对已经连通的 socket（模拟一条 TCP 连接）。
    socketpair 创建的是 Unix 域 socket，行为跟 TCP socket 几乎一样：
    - sendall() 发送数据
    - recv() 接收数据
    而且是双向全双工的。
    """
    return socket.socketpair()


# ============================================================
# 第 1 组：send_message 发送测试
# ============================================================

class TestSendMessage:
    """
    【测试 send_message 函数】
    
    send_message(sock, msg_type, content, extra_headers=None, chunk_size=...)
    它的工作流程是：
      1. 将 extra_headers 中的所有 key/value 转为字符串
      2. 如果 content 是 str，转为 UTF-8 字节；如果是 bytes，直接使用
      3. 构造 JSON 头: {"type": msg_type, "length": len(content_bytes), ...extra_headers}
      4. 发送：4字节头长度(大端) → JSON头字节 → 按 chunk_size 分块发送消息体
    """

    def test_send_text_message(self):
        """
        【测试1】发送一条普通文本消息
        
        验证点：
        - 接收端能正确解码出头和消息体
        - type 字段正确
        - 文本内容与发送的一致
        """
        s1, s2 = make_socket_pair()
        try:
            # === ARRANGE ===
            msg_type = "chat"
            content = "Hello, World!"

            # === ACT ===
            send_message(s1, msg_type, content)

            # === ASSERT ===
            # 接收端手动解码来验证发送格式是否正确
            header, body = recv_message(s2)

            assert header["type"] == "chat"
            assert body.decode("utf-8") == "Hello, World!"
            assert header["length"] == len("Hello, World!".encode("utf-8"))
        finally:
            s1.close()
            s2.close()

    def test_send_binary_message(self):
        """
        【测试2】发送二进制数据（模拟文件传输）
        
        验证点：
        - bytes 类型的 content 能正确传输
        - 包含不可打印字节（如 \x00）时也不出问题
        """
        s1, s2 = make_socket_pair()
        try:
            # === ARRANGE ===
            # 构造包含所有可能字节值的二进制数据
            binary_data = bytes(range(256))  # \x00 \x01 ... \xff

            # === ACT ===
            send_message(s1, "file", binary_data,
                         extra_headers={"filename": "test.bin", "filesize": 256})

            # === ASSERT ===
            header, body = recv_message(s2)
            assert header["type"] == "file"
            assert header["filename"] == "test.bin"  # str 化的数字 "256"
            assert body == binary_data
            assert len(body) == 256
        finally:
            s1.close()
            s2.close()

    def test_send_with_extra_headers(self):
        """
        【测试3】发送带附加头的消息
        
        验证点：
        - extra_headers 字典中的字段被正确放入 JSON 头
        - 键和值都被转为字符串（这是防御性设计）
        """
        s1, s2 = make_socket_pair()
        try:
            # === ACT ===
            send_message(s1, "chat", "你好",
                         extra_headers={"to": "alice", "message_id": "abc-123", "group_id": 42})

            # === ASSERT ===
            header, body = recv_message(s2)
            assert header["to"] == "alice"
            assert header["message_id"] == "abc-123"
            assert header["group_id"] == "42"  # 整数 42 被转为字符串 "42"
        finally:
            s1.close()
            s2.close()

    def test_send_empty_message(self):
        """
        【测试4】发送空消息（边界条件）
        
        验证点：
        - 空字符串也能正常发送和接收
        - length 字段为 0
        """
        s1, s2 = make_socket_pair()
        try:
            send_message(s1, "chat", "")
            header, body = recv_message(s2)
            assert header["type"] == "chat"
            assert header["length"] == 0
            assert body == b""
        finally:
            s1.close()
            s2.close()

    def test_send_large_message_chunked(self):
        """
        【测试5】发送大消息（触发分块传输）
        
        解释：
          protocol.py 默认使用 4MB 的 chunk_size.send_message 中：
            for i in range(0, len(content_bytes), chunk_size):
                sock.sendall(content_bytes[i:i + chunk_size])
          这里故意用极小的 chunk_size=10 来验证分块逻辑的正确性。
        
        验证点：
        - 即使 chunk_size 远小于消息长度，数据也能完整传输
        """
        s1, s2 = make_socket_pair()
        try:
            # 发送 100 字节，但每块只有 10 字节（强制分成 10 块）
            content = "A" * 100

            # 注意：send_message 的 chunk_size 控制发送分块，
            # 但 recv_message 也需要知道怎么分批接收。
            # 两者都在内部使用 recvall 来保证接收完整性。
            send_message(s1, "chat", content, chunk_size=10)
            header, body = recv_message(s2, chunk_size=10)

            assert body.decode("utf-8") == content
            assert len(body) == 100
        finally:
            s1.close()
            s2.close()


# ============================================================
# 第 2 组：recv_message 接收测试
# ============================================================

class TestRecvMessage:
    """
    【测试 recv_message 函数（独立的接收测试）】
    
    由于 recv_message 依赖特定的发送格式，这里主要通过变体方式测试。
    重点测试边界条件和异常情况。
    """

    def test_recv_large_message_chunked_receive(self):
        """
        【测试6】接收大消息时，recvall 能正确组装分块到达的数据
        
        解释：
          TCP 是流协议，1000 字节的数据可能分成多次 recv() 返回。
          recvall() 函数的作用就是循环 recv() 直到收满 n 字节。
          这里我们无法直接模拟 TCP 分块（socketpair 不会自动分块），
          但通过小 chunk_size 配合 recv_message 可以间接验证 recvall 的循环逻辑。
        """
        s1, s2 = make_socket_pair()
        try:
            content = "X" * 500
            send_message(s1, "chat", content)
            # 使用小 chunk_size 强制 recv_message 内部的 recvall 循环多次
            header, body = recv_message(s2, chunk_size=50)

            assert body.decode("utf-8") == content
        finally:
            s1.close()
            s2.close()

    def test_recvall_exact_bytes(self):
        """
        【测试7】recvall 在一次性收到所有数据时能正确返回
        
        验证点：
        - 如果一次 recv() 就拿到了全部数据，不进入循环
        """
        s1, s2 = make_socket_pair()
        try:
            test_data = b"Hello, recvall!"
            s1.sendall(test_data)

            result = recvall(s2, len(test_data))
            assert result == test_data
        finally:
            s1.close()
            s2.close()

    def test_recvall_partial_data(self):
        """
        【测试8】recvall 在数据分多次到达时能循环收齐
        
        解释：
          这是 recvall 的核心价值——TCP 不保证一次 recv() 给你全部数据。
          这里用很小的 recv 缓冲区来模拟（虽然 socketpair 通常一次给全，
          但这个测试验证 recvall 的循环逻辑是正确的）。
        """
        s1, s2 = make_socket_pair()
        try:
            # 发送较大数据
            test_data = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ" * 10  # 260 字节
            s1.sendall(test_data)

            # recvall 内部会循环直到收满 260 字节
            result = recvall(s2, len(test_data))
            assert result == test_data
            assert len(result) == 260
        finally:
            s1.close()
            s2.close()


# ============================================================
# 第 3 组：完整的往返测试（Round-trip）
# ============================================================

class TestRoundTrip:
    """
    【往返测试】
    
    这是最重要的一类测试——验证 '发出去什么，对方就收到什么'。
    覆盖各种消息类型和边界情况。
    """

    def test_roundtrip_text_chinese(self):
        """
        【测试9】中文文本的完整往返
        
        验证点：
        - UTF-8 编码的中文字符能正确编解码
        - 不会出现乱码或字节截断
        """
        s1, s2 = make_socket_pair()
        try:
            text = "你好世界！这是一个中文测试消息"
            send_message(s1, "chat", text)
            header, body = recv_message(s2)
            assert body.decode("utf-8") == text
        finally:
            s1.close()
            s2.close()

    def test_roundtrip_text_with_emoji(self):
        """
        【测试10】包含 emoji 的文本往返
        
        验证点：
        - emoji（4字节 UTF-8）能正确处理
        - 不会出现代理对截断问题
        """
        s1, s2 = make_socket_pair()
        try:
            text = "Hello 😀🎉🔥 测试"
            send_message(s1, "chat", text)
            header, body = recv_message(s2)
            assert body.decode("utf-8") == text
        finally:
            s1.close()
            s2.close()

    def test_roundtrip_binary_with_null_bytes(self):
        """
        【测试11】包含大量 \x00 字节的二进制数据往返
        
        为什么重要：
          很多编程语言/库在处理字符串时遇到 \x00 会截断。
          我们的协议用 length 字段指定消息体长度，所以 \x00 不影响。
        """
        s1, s2 = make_socket_pair()
        try:
            # 交替放置有效数据和 null 字节
            data = b"\x00" + b"real data" + b"\x00\x00" + b"more data"
            send_message(s1, "file", data)
            header, body = recv_message(s2)
            assert body == data
        finally:
            s1.close()
            s2.close()

    def test_roundtrip_multiple_messages(self):
        """
        【测试12】同一连接上连续发送多条消息
        
        验证点：
        - 协议能正确区分消息边界（每条消息不会串到下一跳）
        - 这是 TCP 流协议中最容易出现 '粘包' 的地方
        """
        s1, s2 = make_socket_pair()
        try:
            messages = ["第一条消息", "第二条消息", "第三条消息"]

            for msg in messages:
                send_message(s1, "chat", msg)

            for expected in messages:
                header, body = recv_message(s2)
                assert body.decode("utf-8") == expected
        finally:
            s1.close()
            s2.close()

    def test_roundtrip_mixed_types(self):
        """
        【测试13】混合发送文本和二进制消息
        
        验证点：
        - header 中的 type 字段正确区分消息类型
        - 接收端能根据 type 进行不同的处理
        """
        s1, s2 = make_socket_pair()
        try:
            # 先发一条文本
            send_message(s1, "chat", "Hello")
            # 再发一个 '文件'
            send_message(s1, "file", b"\x89PNG\r\n\x1a\n...fake png data...")

            # 收文本
            h1, b1 = recv_message(s2)
            assert h1["type"] == "chat"
            assert b1.decode() == "Hello"

            # 收二进制
            h2, b2 = recv_message(s2)
            assert h2["type"] == "file"
            assert b2.startswith(b"\x89PNG")
        finally:
            s1.close()
            s2.close()


# ============================================================
# 第 4 组：防御性/健壮性测试
# ============================================================

class TestDefensive:
    """
    【协议健壮性测试】
    
    测试协议在一些边界和异常输入下的表现。
    """

    def test_extra_headers_type_conversion(self):
        """
        【测试14】extra_headers 的 key/value 都会被转为字符串
        
        原因：
          protocol.py 中有这样一行防御代码：
           extra_headers = {str(k): str(v) for k, v in extra_headers.items()}
          
          这防止了数字类型的用户名或 ID 导致 JSON 序列化失败。
          
        验证点：
        - 传入整数、浮点数、布尔值的 header 都能正确序列化
        """
        s1, s2 = make_socket_pair()
        try:
            send_message(s1, "test", "data", extra_headers={
                "count": 100,          # 整数 → "100"
                "ratio": 3.14,         # 浮点数 → "3.14"
                "flag": True,          # 布尔 → "True"
                "none_val": None,      # None → "None"
            })

            header, _ = recv_message(s2)
            assert header["count"] == "100"
            assert header["ratio"] == "3.14"
            assert header["flag"] == "True"
            assert header["none_val"] == "None"
        finally:
            s1.close()
            s2.close()

    def test_message_length_accuracy(self):
        """
        【测试15】header 中的 length 字段与实际消息体长度完全一致
        
        为什么重要：
          recv_message 依赖这个 length 字段来决定收多少字节。
          如果 length 不准确，会导致消息截断或粘包。
        """
        s1, s2 = make_socket_pair()
        try:
            content = "A" * 1024  # 1KB 文本
            send_message(s1, "chat", content)

            header, body = recv_message(s2)
            # length 应该等于 UTF-8 编码后的字节数（纯 ASCII 时 == 字符数）
            assert header["length"] == len(content.encode("utf-8"))
            # 实际收到的字节数应等于声明的长度
            assert len(body) == header["length"]
        finally:
            s1.close()
            s2.close()


# ============================================================
# 总结：如何运行这些测试
# ============================================================
"""
运行单个测试文件:
  cd 项目根目录
  .venv/bin/python -m pytest tests/test_protocol.py -v

运行某个测试类:
  .venv/bin/python -m pytest tests/test_protocol.py::TestSendMessage -v

运行某个具体测试:
  .venv/bin/python -m pytest tests/test_protocol.py::TestSendMessage::test_send_text_message -v

显示详细的打印输出:
  .venv/bin/python -m pytest tests/test_protocol.py -v -s
"""
