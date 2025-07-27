import ssl
import logging
import bcrypt
from protocol import send_message, recv_message
from server_message_handler import MessageHandler

class ClientHandler:
    def __init__(self, server):
        self.server = server

    def handle_client(self, client_socket, client_address, context):
        logging.info(f"新客户端连接: {client_address}")
        username = None
        try:
            with context.wrap_socket(client_socket, server_side=True) as ssock:
                header, data = recv_message(ssock)
                if not header or header.get("type") not in ("register", "login"):
                    send_message(ssock, "error", "错误，请先注册或登录")
                    return

                msg_type = header.get("type")
                username = data.decode("utf-8").strip()
                password = header.get("password")
                logging.info(f"处理认证请求: 用户={username}, 类型={msg_type}")

                message_handler = MessageHandler(self.server)  # 提前初始化 message_handler

                if msg_type == "register":
                    if self.server.db.user_exists(username):
                        send_message(ssock, "error", "用户已存在")
                        logging.warning(f"注册失败: 用户 {username} 已存在")
                        return
                    password_hash = bcrypt.hashpw(password.encode('utf-8'), bcrypt.gensalt())
                    if self.server.db.add_user(username, password_hash):
                        send_message(ssock, "chat", "注册成功")
                        with self.server.client_map_lock:
                            self.server.client_map[username] = ssock
                        logging.info(f"注册成功: 用户={username}")
                        # 加载离线数据并进入消息处理循环
                        message_handler.load_offline_data(username, ssock)
                        message_handler.process_messages(username, ssock)
                    else:
                        send_message(ssock, "error", "注册失败")
                        logging.error(f"注册失败: 用户={username}")
                        return
                elif msg_type == "login":
                    user_data = self.server.db.get_user(username)
                    if not user_data:
                        send_message(ssock, "error", "错误，用户不存在")
                        logging.warning(f"登录失败: 用户 {username} 不存在")
                        return
                    stored_hash, is_admin = user_data
                    if bcrypt.checkpw(password.encode('utf-8'), stored_hash):
                        if is_admin:
                            send_message(ssock, "admin_auth", "管理员登录成功")
                            logging.info(f"管理员登录成功: 用户={username}")
                        else:
                            send_message(ssock, "chat", "登录成功")
                            logging.info(f"登录成功: 用户={username}")
                        with self.server.client_map_lock:
                            self.server.client_map[username] = ssock
                        # 加载离线消息、好友请求和文件请求
                        message_handler.load_offline_data(username, ssock)
                        # 处理后续消息
                        message_handler.process_messages(username, ssock)
                    else:
                        send_message(ssock, "error", "错误：密码错误")
                        logging.warning(f"登录失败: 用户 {username} 密码错误")
                        return
        except ssl.SSLError as e:
            logging.error(f"SSL 错误: {e}")
        except Exception as e:
            logging.error(f"处理客户端 {client_address} 时出错: {e}")
        finally:
            if username:
                with self.server.client_map_lock:
                    self.server.client_map.pop(username, None)
            logging.info(f"客户端断开连接: {client_address}")
            client_socket.close()