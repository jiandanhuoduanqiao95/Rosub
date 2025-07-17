#TODO:发送、接收消息模块，便于客户端和服务器直接调用
#设计一套简单的消息格式，使得双方能够区分不同类型的数据-消息or文件
#消息头:使用 JSON 格式来描述消息类型及相关元数据（消息体长度、文件名、文件大小等）
#固定前缀:为了解决 TCP 数据边界问题，先发送一个固定大小(如 4 字节)的整数，表示后续 JSON 消息头的字节数
#消息体:根据消息头中的 length 字段确定消息体数据的长度。对于聊天消息，消息体就是纯文本；对于文件传输，则为文件的二进制数据
import json
import struct

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
    # 先接收4字节消息头长度
    raw_header_len = recvall(sock, 4)
    if not raw_header_len:
        return None, None
    header_len = struct.unpack('!I', raw_header_len)[0]
    header_json = recvall(sock, header_len)
    header = json.loads(header_json.decode('utf-8'))
    length = header.get('length', 0)
    content_bytes = b''
    while len(content_bytes) < length:
        packet = recvall(sock, min(chunk_size, length - len(content_bytes)))
        if not packet:
            return None, None
        content_bytes += packet
    return header, content_bytes

def recvall(sock, n):
    """确保接收n个字节的数据"""
    data = b''
    while len(data) < n:
        packet = sock.recv(n - len(data))
        if not packet:
            return None
        data += packet
    return data