import socket
import ssl
import os
import threading
import logging
from database import Database
from server_client_handler import ClientHandler

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')

class Server:
    def __init__(self, host="127.0.0.1", port=8090):
        self.host = host
        self.port = port
        self.client_map = {}
        self.db = Database()
        self.client_map_lock = threading.Lock()
        self.client_handler = ClientHandler(self)

    def build_listen(self):
        if not os.path.exists("files"):
            os.makedirs("files")
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain("SSL/tsetcn.crt", "SSL/tsetcn.pem")
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