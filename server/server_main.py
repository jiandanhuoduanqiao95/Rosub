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

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')

class Server:
    def __init__(self, host=None, port=None):
        self.host = host or config.get("server.host", "127.0.0.1")
        self.port = port or config.get("server.port", 8090)
        self.client_map = {}
        self.db = Database()
        self.client_map_lock = threading.Lock()
        self.client_handler = ClientHandler(self)

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