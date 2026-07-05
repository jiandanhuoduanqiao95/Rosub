import ssl
import logging
import bcrypt
import hmac
import os
from protocol import send_message, recv_message
from server.server_message_handler import MessageHandler
from validation import validate_username, validate_password
from config import config

class ClientHandler:
    def __init__(self, server):
        self.server = server

    def _admin_secret(self):
        env_name = config.get("security.admin_secret_env", "CHATROOM_ADMIN_SECRET")
        return os.environ.get(env_name) or config.get("security.admin_secret", "") or ""

    def _admin_secret_valid(self, provided_secret):
        configured_secret = self._admin_secret()
        if not configured_secret or not provided_secret:
            return False
        return hmac.compare_digest(str(provided_secret), str(configured_secret))

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
                admin_secret = header.get("admin_secret")
                logging.info(f"处理认证请求: 用户={username}, 类型={msg_type}")

                message_handler = MessageHandler(self.server)  # 提前初始化 message_handler

                if msg_type == "register":
                    # 服务端验证用户名和密码格式
                    valid, error = validate_username(username)
                    if not valid:
                        send_message(ssock, "error", error)
                        logging.warning(f"注册失败: 用户名 {username} 格式不合法: {error}")
                        return
                    valid, error = validate_password(password or "")
                    if not valid:
                        send_message(ssock, "error", error)
                        logging.warning(f"注册失败: 密码格式不合法: {error}")
                        return
                    is_admin_register = bool(admin_secret)
                    if is_admin_register and not self._admin_secret_valid(admin_secret):
                        send_message(ssock, "error", "管理员注册密钥无效或服务器未配置管理员密钥")
                        logging.warning(f"管理员注册失败: 用户={username}, 密钥无效或未配置")
                        return
                    if self.server.db.user_exists(username):
                        send_message(ssock, "error", "用户已存在")
                        logging.warning(f"注册失败: 用户 {username} 已存在")
                        return
                    password_hash = bcrypt.hashpw(password.encode('utf-8'), bcrypt.gensalt())
                    if self.server.db.add_user(username, password_hash, is_admin=is_admin_register):
                        if is_admin_register:
                            send_message(ssock, "admin_auth", "管理员注册成功")
                        else:
                            send_message(ssock, "chat", "注册成功")
                        with self.server.client_map_lock:
                            self.server.client_map[username] = ssock
                        logging.info(f"注册成功: 用户={username}, 管理员={is_admin_register}")
                        # 加载离线数据并发送初始好友/群组列表
                        message_handler.load_offline_data(username, ssock)
                        message_handler.send_initial_data(username, ssock)
                        message_handler.process_messages(username, ssock)
                    else:
                        send_message(ssock, "error", "注册失败")
                        logging.error(f"注册失败: 用户={username}")
                        return
                elif msg_type == "login":
                    valid, error = validate_username(username)
                    if not valid:
                        send_message(ssock, "error", error)
                        logging.warning(f"登录失败: 用户名 {username} 格式不合法: {error}")
                        return
                    valid, error = validate_password(password or "")
                    if not valid:
                        send_message(ssock, "error", error)
                        logging.warning(f"登录失败: 密码格式不合法: {error}")
                        return
                    user_data = self.server.db.get_user(username)
                    if not user_data:
                        send_message(ssock, "error", "错误，用户不存在")
                        logging.warning(f"登录失败: 用户 {username} 不存在")
                        return
                    stored_hash, is_admin = user_data
                    if bcrypt.checkpw(password.encode('utf-8'), stored_hash):
                        if is_admin:
                            if not self._admin_secret_valid(admin_secret):
                                send_message(ssock, "error", "管理员登录需要有效管理员密钥")
                                logging.warning(f"管理员登录失败: 用户={username}, 管理员密钥无效或未配置")
                                return
                            send_message(ssock, "admin_auth", "管理员登录成功")
                            logging.info(f"管理员登录成功: 用户={username}")
                        else:
                            if admin_secret:
                                send_message(ssock, "error", "该账号不是管理员")
                                logging.warning(f"登录失败: 普通用户 {username} 尝试使用管理员密钥登录")
                                return
                            send_message(ssock, "chat", "登录成功")
                            logging.info(f"登录成功: 用户={username}")
                        with self.server.client_map_lock:
                            self.server.client_map[username] = ssock
                        # 加载离线消息、好友请求和文件请求，并发送初始好友/群组列表
                        message_handler.load_offline_data(username, ssock)
                        message_handler.send_initial_data(username, ssock)
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
