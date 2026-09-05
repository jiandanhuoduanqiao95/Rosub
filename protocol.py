#TODO:发送、接收消息模块，便于客户端和服务器直接调用
#设计一套简单的消息格式，使得双方能够区分不同类型的数据-消息or文件
#消息头:使用 JSON 格式来描述消息类型及相关元数据（消息体长度、文件名、文件大小等）
#固定前缀:为了解决 TCP 数据边界问题，先发送一个固定大小(如 4 字节)的整数，表示后续 JSON 消息头的字节数
#消息体:根据消息头中的 length 字段确定消息体数据的长度。对于聊天消息，消息体就是纯文本；对于文件传输，则为文件的二进制数据

# ============================================================
# 协议版本 —— 已冻结 (1.0.0)
# 此版本号作为所有客户端与服务端的通信契约。
# 任何破坏性修改必须递增版本号，旧版本客户端应收到兼容性错误。
# ============================================================
PROTOCOL_VERSION = "1.0.0"

import json
import os
import struct
import uuid

def send_message(sock, msg_type, content, extra_headers=None, chunk_size=1024*1024*4):
    """
    发送消息：
    - sock: 已连接的socket
    - msg_type: 消息类型，如 'chat' 或 'file'
    - content: 消息体内容。对于文本消息，传入 str；对于文件，传入 bytes
    - extra_headers: 可选字典，包含其它附加头部信息，如文件名、文件大小等
    """
    if extra_headers is None:
        extra_headers = {}
    # 如果内容为字符串则转为字节流
    # 确保所有头部字段为字符串(防御数字用户名)
    extra_headers = {str(k): str(v) for k, v in extra_headers.items()}
    if isinstance(content, str):
        content_bytes = content.encode('utf-8')
    else:
        content_bytes = content

    header = {'type': msg_type, 'length': len(content_bytes)}
    header.update(extra_headers)
    header_json = json.dumps(header).encode('utf-8')
    # 先发送消息头的长度（4字节，大端格式）
    sock.sendall(struct.pack('!I', len(header_json)))
    # 发送消息头
    sock.sendall(header_json)
    # 发送消息体
    #sock.sendall(content_bytes)
    # 分块发送
    for i in range(0, len(content_bytes), chunk_size):
        sock.sendall(content_bytes[i:i + chunk_size])


def recv_message(sock,chunk_size=1024*1024*4):
    """
    接收消息：
    返回：(header字典, 消息体字节流)
    """
    header = recv_header_only(sock)
    if header is None:
        return None, None
    content = recv_body(sock, header.get('length', 0), chunk_size)
    if content is None:
        return None, None
    return header, content

def recvall(sock, n):
    """确保接收n个字节的数据"""
    data = b''
    while len(data) < n:
        packet = sock.recv(n - len(data))
        if not packet:
            return None
        data += packet
    return data


def send_message_header_only(sock, msg_type, length, extra_headers=None):
    """只发送消息头（4 字节头长度 + JSON 头），消息体由调用方随后发送。

    length 为随后消息体的实际字节数（与 recv 端 header['length'] 一致）。
    """
    if extra_headers is None:
        extra_headers = {}
    extra_headers = {str(k): str(v) for k, v in extra_headers.items()}
    header = {'type': msg_type, 'length': length}
    header.update(extra_headers)
    header_json = json.dumps(header).encode('utf-8')
    sock.sendall(struct.pack('!I', len(header_json)))
    sock.sendall(header_json)


def recv_header_only(sock):
    """读取消息头（4 字节头长度 + JSON 头），不消费消息体。返回 header 或 None。"""
    raw_header_len = recvall(sock, 4)
    if not raw_header_len:
        return None
    header_len = struct.unpack('!I', raw_header_len)[0]
    header_json = recvall(sock, header_len)
    if header_json is None:
        return None
    return json.loads(header_json.decode('utf-8'))


def recv_body(sock, length, chunk_size=1024*1024*4):
    """读取消息体到内存。返回 bytes；连接提前关闭返回 None。"""
    content_bytes = b''
    while len(content_bytes) < length:
        packet = recvall(sock, min(chunk_size, length - len(content_bytes)))
        if not packet:
            return None
        content_bytes += packet
    return content_bytes


def recv_body_to_file(sock, file_path, length, chunk_size=1024*1024*4):
    """读取消息体边收边写入磁盘文件（不占内存）。返回实际写入字节数。"""
    written = 0
    with open(file_path, 'wb') as f:
        while written < length:
            packet = recvall(sock, min(chunk_size, length - written))
            if not packet:
                break
            f.write(packet)
            written += len(packet)
    return written


class _ForwardError(Exception):
    """转发失败（接收方连接中断）：携带已从源连接消费的字节数。

    消费量 = 已转发 + 预读缓冲（sendall 失败前 recvall 已读入的数据）。
    调用方需据此只消费剩余的 length - consumed 字节，否则会把发送方
    后续消息（如传输中排队的 chat）一并吞掉导致流错位。
    """

    def __init__(self, consumed):
        super().__init__(f"转发失败，已消费 {consumed} 字节")
        self.consumed = consumed


def recv_and_forward(sock, target_sock, length, chunk_size=1024*1024*4):
    """从 sock 读取消息体并实时转发到 target_sock（服务器不存储，边收边发）。

    返回实际从源连接消费（已转发）的字节数；小于 length 表示源连接提前关闭。
    转发失败（接收方掉线）时抛出 _ForwardError，携带已消费字节数。
    """
    consumed = 0
    while consumed < length:
        packet = recvall(sock, min(chunk_size, length - consumed))
        if not packet:
            break
        try:
            target_sock.sendall(packet)
        except Exception:
            # 预读的 packet 已从源连接消费，不能再被后续 drain 读到
            raise _ForwardError(consumed + len(packet))
        consumed += len(packet)
    return consumed


def send_file_message(sock, msg_type, file_path, extra_headers=None, chunk_size=1024*1024*4):
    """分块发送文件消息（不将整个文件读入内存）。

    帧格式与 send_message 完全一致：4 字节头长度 + JSON 头 + 分块消息体。
    length 字段取文件实际大小。仅用于超大文件（如数百 MB 以上）。
    """
    if extra_headers is None:
        extra_headers = {}
    extra_headers = {str(k): str(v) for k, v in extra_headers.items()}
    file_size = os.path.getsize(file_path)

    header = {'type': msg_type, 'length': file_size}
    header.update(extra_headers)
    header_json = json.dumps(header).encode('utf-8')
    sock.sendall(struct.pack('!I', len(header_json)))
    sock.sendall(header_json)
    with open(file_path, 'rb') as f:
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            sock.sendall(chunk)


def recv_message_detached(sock, file_dir=None, chunk_size=1024*1024*4):
    """接收一条消息；file 类型消息的消息体边收边写入磁盘，不占内存。

    帧格式与 recv_message 完全一致。返回 (header, data)：
      - type == 'file' 且提供了 file_dir：data 为消息体落盘后的文件路径；
      - 其他类型：data 为消息体字节（bytes）。
    连接关闭返回 (None, None)。
    """
    header = recv_header_only(sock)
    if header is None:
        return None, None
    length = header.get('length', 0)

    if header.get('type') == 'file' and file_dir:
        os.makedirs(file_dir, exist_ok=True)
        message_id = header.get('message_id') or str(uuid.uuid4())
        file_path = os.path.join(file_dir, os.path.basename(message_id))
        written = recv_body_to_file(sock, file_path, length, chunk_size)
        if written < length:
            return None, None
        return header, file_path

    content = recv_body(sock, length, chunk_size)
    if content is None:
        return None, None
    return header, content