import ssl
import socket
import logging
import time
import bcrypt
import hmac
import os
from protocol import send_message, recv_message
from server.server_message_handler import MessageHandler
from validation import validate_username, validate_password
from config import config

class ClientHandler:
    # 登录速率限制（阶段 G6）：连续失败次数与锁定秒数
    MAX_LOGIN_FAILURES = 5
    LOGIN_LOCKOUT_SECONDS = 300

    def __init__(self, server):
        self.server = server
        self._login_failures = {}

    def _is_login_locked(self, username):
        """判断用户名是否处于锁定状态（5 次失败锁定 5 分钟）。"""
        failures = self._login_failures.get(username)
        if not failures:
            return False
        count, first_time = failures
        if count < self.MAX_LOGIN_FAILURES:
            return False
        if time.time() - first_time >= self.LOGIN_LOCKOUT_SECONDS:
            self._login_failures.pop(username, None)
            return False
        return True

    def _record_login_failure(self, username):
        """记录一次登录失败，返回当前累计失败次数。"""
        now = time.time()
        count, first_time = self._login_failures.get(username, (0, now))
        if count == 0:
            self._login_failures[username] = (1, now)
            return 1
        # 锁定期已过 → 从本次失败重新计数
        if count >= self.MAX_LOGIN_FAILURES and now - first_time >= self.LOGIN_LOCKOUT_SECONDS:
            self._login_failures[username] = (1, now)
            return 1
        self._login_failures[username] = (count + 1, first_time)
        return count + 1

    def _clear_login_failures(self, username):
        self._login_failures.pop(username, None)

    def _kick_old_session(self, username, ssock):
        """重复登录踢出（阶段 G1）：通知旧 socket 并关闭，替换为新会话。

        返回 True 表示存在旧会话并被踢出。
        旧会话正在接收大文件直传转发时：跳过通知与关闭（任何写入都会污染
        文件字节流导致 SSL 记录错乱），仅替换 client_map 映射。
        """
        with self.server.client_map_lock:
            old_sock = self.server.client_map.get(username)
            if old_sock is None or old_sock is ssock:
                self.server.client_map[username] = ssock
                return False
            forwarding = old_sock in self.server.active_forward_socks
            if not forwarding:
                try:
                    # 锁内直接发送（guarded_send 会再次取同一把锁导致死锁；
                    # 此处已判断非转发中，无需再守卫）
                    send_message(old_sock, "error", "已在其他地方登录，您已被强制下线")
                    logging.info(f"强制下线旧会话: 用户={username}")
                except Exception as e:
                    logging.warning(f"通知旧会话下线失败: 用户={username}, 错误={e}")
                try:
                    # shutdown 唤醒阻塞在 recv 的旧会话线程（close 不能打断
                    # 阻塞读），其 finally 会清理 client_map / transfer_sockets；
                    # 由于映射已指向新会话，不会误删新会话或广播下线
                    old_sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                try:
                    old_sock.close()
                except Exception:
                    pass
            else:
                logging.info(f"旧会话正在接收大文件转发，跳过踢出: 用户={username}")
            self.server.client_map[username] = ssock
            return True

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
        wrapped = None
        is_transfer_session = False
        try:
            with context.wrap_socket(client_socket, server_side=True) as ssock:
                wrapped = ssock
                header, data = recv_message(ssock)
                if not header or header.get("type") not in ("register", "login"):
                    self.server.guarded_send(ssock, "error", "错误，请先注册或登录")
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
                        self.server.guarded_send(ssock, "error", error)
                        logging.warning(f"注册失败: 用户名 {username} 格式不合法: {error}")
                        return
                    valid, error = validate_password(password or "")
                    if not valid:
                        self.server.guarded_send(ssock, "error", error)
                        logging.warning(f"注册失败: 密码格式不合法: {error}")
                        return
                    is_admin_register = bool(admin_secret)
                    if is_admin_register and not self._admin_secret_valid(admin_secret):
                        self.server.guarded_send(ssock, "error", "管理员注册密钥无效或服务器未配置管理员密钥")
                        logging.warning(f"管理员注册失败: 用户={username}, 密钥无效或未配置")
                        return
                    if self.server.db.user_exists(username):
                        self.server.guarded_send(ssock, "error", "用户已存在")
                        logging.warning(f"注册失败: 用户 {username} 已存在")
                        return
                    password_hash = bcrypt.hashpw(password.encode('utf-8'), bcrypt.gensalt())
                    if self.server.db.add_user(username, password_hash, is_admin=is_admin_register):
                        if is_admin_register:
                            self.server.guarded_send(ssock, "admin_auth", "管理员注册成功")
                        else:
                            self.server.guarded_send(ssock, "chat", "注册成功")
                        with self.server.client_map_lock:
                            self.server.client_map[username] = ssock
                        logging.info(f"注册成功: 用户={username}, 管理员={is_admin_register}")
                        # 阶段 J：注册上线 → 更新 last_seen + presence 广播与快照
                        self.server.db.update_last_seen(username)
                        self.server.broadcast_presence(username, True)
                        self.server.send_presence_snapshot(username, ssock)
                        # 加载离线数据并发送初始好友/群组列表
                        message_handler.load_offline_data(username, ssock)
                        message_handler.send_initial_data(username, ssock)
                        message_handler.process_messages(username, ssock)
                    else:
                        self.server.guarded_send(ssock, "error", "注册失败")
                        logging.error(f"注册失败: 用户={username}")
                        return
                elif msg_type == "login":
                    valid, error = validate_username(username)
                    if not valid:
                        self.server.guarded_send(ssock, "error", error)
                        logging.warning(f"登录失败: 用户名 {username} 格式不合法: {error}")
                        return
                    valid, error = validate_password(password or "")
                    if not valid:
                        self.server.guarded_send(ssock, "error", error)
                        logging.warning(f"登录失败: 密码格式不合法: {error}")
                        return
                    if self._is_login_locked(username):
                        self.server.guarded_send(ssock, "error", "尝试次数过多，请 5 分钟后再试")
                        logging.warning(f"登录失败: 用户 {username} 处于锁定状态")
                        return
                    user_data = self.server.db.get_user(username)
                    if not user_data:
                        self._record_login_failure(username)
                        self.server.guarded_send(ssock, "error", "错误，用户不存在")
                        logging.warning(f"登录失败: 用户 {username} 不存在")
                        return
                    stored_hash, is_admin = user_data
                    if bcrypt.checkpw(password.encode('utf-8'), stored_hash):
                        if is_admin:
                            if not self._admin_secret_valid(admin_secret):
                                self.server.guarded_send(ssock, "error", "管理员登录需要有效管理员密钥")
                                logging.warning(f"管理员登录失败: 用户={username}, 管理员密钥无效或未配置")
                                return
                            self.server.guarded_send(ssock, "admin_auth", "管理员登录成功")
                            logging.info(f"管理员登录成功: 用户={username}")
                        else:
                            if admin_secret:
                                self.server.guarded_send(ssock, "error", "该账号不是管理员")
                                logging.warning(f"登录失败: 普通用户 {username} 尝试使用管理员密钥登录")
                                return
                            self.server.guarded_send(ssock, "chat", "登录成功")
                            logging.info(f"登录成功: 用户={username}")
                        self._clear_login_failures(username)
                        # 传输通道登录（transfer=1）：注册到 transfer_sockets，
                        # 不踢主会话、不加载离线数据、不发送初始列表。
                        # 文件数据经此通道收发，主连接上的聊天不受传输影响。
                        is_transfer_session = header.get("transfer") == "1"
                        if is_transfer_session:
                            with self.server.client_map_lock:
                                old = self.server.transfer_sockets.get(username)
                                if old is not None and old is not ssock:
                                    try:
                                        old.close()
                                    except Exception:
                                        pass
                                self.server.transfer_sockets[username] = ssock
                            logging.info(f"传输通道已注册: 用户={username}")
                            message_handler.process_messages(username, ssock)
                            return
                        # 正常主会话登录：踢出旧会话（如存在）
                        self._kick_old_session(username, ssock)
                        # 主会话登录成功：清理残留的传输通道（旧传输上下文作废）
                        with self.server.client_map_lock:
                            stale = self.server.transfer_sockets.pop(username, None)
                            if stale is not None and stale is not ssock:
                                try:
                                    stale.close()
                                except Exception:
                                    pass
                        # 阶段 J：主会话上线 → 更新 last_seen + presence 广播与快照
                        self.server.db.update_last_seen(username)
                        self.server.broadcast_presence(username, True)
                        self.server.send_presence_snapshot(username, ssock)
                        # 加载离线消息、好友请求和文件请求，并发送初始好友/群组列表
                        message_handler.load_offline_data(username, ssock)
                        message_handler.send_initial_data(username, ssock)
                        # 处理后续消息
                        message_handler.process_messages(username, ssock)
                    else:
                        self._record_login_failure(username)
                        self.server.guarded_send(ssock, "error", "错误：密码错误")
                        logging.warning(f"登录失败: 用户 {username} 密码错误")
                        return
        except ssl.SSLError as e:
            logging.error(f"SSL 错误: {e}")
        except Exception as e:
            logging.error(f"处理客户端 {client_address} 时出错: {e}")
        finally:
            if username and wrapped is not None:
                removed_main = False
                with self.server.client_map_lock:
                    if is_transfer_session:
                        # 仅移除属于自己的传输通道映射
                        if self.server.transfer_sockets.get(username) is wrapped:
                            self.server.transfer_sockets.pop(username, None)
                    else:
                        # 仅移除属于自己的映射，避免误删重复登录后的新会话（阶段 G1）
                        if self.server.client_map.get(username) is wrapped:
                            self.server.client_map.pop(username, None)
                            removed_main = True
                        # 主会话结束：一并关闭自己的传输通道
                        stale = self.server.transfer_sockets.pop(username, None)
                        if stale is not None and stale is not wrapped:
                            try:
                                stale.close()
                            except Exception:
                                pass
                # 阶段 J：主会话下线 → presence 广播（传输通道/未登录成功不广播）
                if removed_main:
                    try:
                        self.server.broadcast_presence(username, False)
                    except Exception as e:
                        logging.warning(f"presence 下线广播失败: 用户={username}, 错误={e}")
            logging.info(f"客户端断开连接: {client_address}")
            client_socket.close()
