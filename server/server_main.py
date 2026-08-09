import socket
import ssl
import os
import sys
import threading
import logging

# 确保项目根目录在 Python 路径中（支持直接运行或作为模块导入）
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from database import Database
from server.server_client_handler import ClientHandler
from config import config
from protocol import send_message

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')

class Server:
    def __init__(self, host=None, port=None):
        self.host = host or config.get("server.host", "127.0.0.1")
        self.port = port or config.get("server.port", 8090)
        self.client_map = {}
        self.db = Database()
        self.client_map_lock = threading.Lock()
        self.client_handler = ClientHandler(self)
        # 正在被大文件直传转发（recv_and_forward 写入）的 socket 集合：
        # 转发期间禁止向这些连接写入任何其他数据（心跳 pong/kick/推送都会污染 SSL 流）
        self.active_forward_socks = set()
        # 大文件传输专用通道（阶段 G4b 修复-问题2）：登录时带 transfer=1 的
        # 连接注册到此处，不进入 client_map、不踢主会话。
        # 文件数据在主连接之外收发，聊天消息在主连接上畅通无阻——
        # 发送方传输期间发的文字消息不再被发送队列/接收方抑制阻塞。
        self.transfer_sockets = {}

    def guarded_send(self, sock, msg_type, content, extra_headers=None, chunk_size=None):
        """向客户端发送消息；若该连接正在接收大文件直传转发，则抑制写入。

        大文件直传时服务器把接收方 socket 当作纯文件通道，任何其他数据
        （ping/pong、kick 通知、聊天推送等）都会插入文件字节流导致 SSL 记录
        错乱（BAD_LENGTH）与文件损坏。
        """
        with self.client_map_lock:
            if sock in self.active_forward_socks:
                logging.info(f"抑制发送到转发中的连接: 类型={msg_type}")
                return
        if chunk_size is not None:
            send_message(sock, msg_type, content, extra_headers=extra_headers, chunk_size=chunk_size)
        else:
            send_message(sock, msg_type, content, extra_headers=extra_headers)

    def build_listen(self):
        if not os.path.exists("files"):
            os.makedirs("files")
        # 启动时清理过期文件请求
        cleaned = self.db.cleanup_expired_file_requests()
        if cleaned > 0:
            logging.info(f"启动时清理了 {cleaned} 个过期文件请求")
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(
            config.get("server.ssl_cert", "SSL/tsetcn.crt"),
            config.get("server.ssl_key", "SSL/tsetcn.pem")
        )
        server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server_socket.bind((self.host, self.port))
        server_socket.listen(100)
        logging.info(f"服务器启动，监听 {self.host}:{self.port}")
        while True:
            try:
                client_socket, client_address = server_socket.accept()
                client_thread = threading.Thread(
                    target=self.client_handler.handle_client,
                    args=(client_socket, client_address, context)
                )
                client_thread.daemon = True
                client_thread.start()
            except Exception as e:
                logging.error(f"接受客户端连接时出错: {e}")

if __name__ == "__main__":
    server = Server()
    server.build_listen()