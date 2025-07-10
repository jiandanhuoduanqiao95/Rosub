import socket
import ssl
import os
from protocol import send_message, recv_message
import threading
import logging
import bcrypt
from database import Database
import json

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')

class Server:
    def __init__(self, host="127.0.0.1", port=8090):
        self.host = host
        self.port = port
        self.client_map = {}
        self.db = Database()
        self.client_map_lock = threading.Lock()

    def handle_client(self, client_socket, client_address, context):
        logging.info(f"新客户端连接: {client_address}")
        username = None
        try:
            with context.wrap_socket(client_socket, server_side=True) as ssock:
                header, data = recv_message(ssock)
                if not header or header.get("type") not in ("register", "login"):
                    send_message(ssock, "chat", "错误，请先注册或登录")
                    return

                msg_type = header.get("type")
                username = data.decode("utf-8").strip()
                password = header.get("password")
                if msg_type == "register":
                    if self.db.user_exists(username):
                        send_message(ssock, "error", "用户已存在")
                        return
                    password_hash = bcrypt.hashpw(password.encode('utf-8'), bcrypt.gensalt())
                    if self.db.add_user(username, password_hash):
                        send_message(ssock, "chat", "注册成功")
                        with self.client_map_lock:
                            self.client_map[username] = ssock
                    else:
                        send_message(ssock, "error", "注册失败")
                        return
                elif msg_type == "login":
                    user_data = self.db.get_user(username)
                    if not user_data:
                        send_message(ssock, "error", "错误，用户不存在")
                        return
                    stored_hash, is_admin = user_data
                    if bcrypt.checkpw(password.encode('utf-8'), stored_hash):
                        if is_admin:
                            send_message(ssock, "admin_auth", "管理员登录成功")
                        else:
                            send_message(ssock, "chat", "登录成功")
                        with self.client_map_lock:
                            self.client_map[username] = ssock
                        messages = self.db.get_offline_messages(username)
                        for msg in messages:
                            sender, msg_type, content, filename = msg
                            if msg_type == "chat":
                                send_message(ssock, "chat", content.decode('utf-8'),
                                             extra_headers={"from": sender, "history": "true"})
                            elif msg_type == "file":
                                send_message(ssock, "file", content,
                                             extra_headers={"from": sender, "filename": filename, "history": "true"})
                        pending_requests = self.db.get_pending_friend_requests(username)
                        for requester in pending_requests:
                            send_message(ssock, "friend_request", f"来自 {requester} 的好友请求",
                                         extra_headers={"from": requester})
                    else:
                        send_message(ssock, "error", "错误：密码错误")
                        return

                while True:
                    header, data = recv_message(ssock)
                    if not header:
                        logging.info(f"客户端 {username or client_address} 断开连接")
                        break
                    msg_type = header.get("type")

                    if msg_type == "chat":
                        target = header.get("to")
                        if not self.db.is_friend(username, target):
                            send_message(ssock, "error", f"错误：{target} 不是您的好友")
                            continue
                        message = data.decode("utf-8")
                        logging.info(f"来自 {username} 发往 {target} 的聊天消息: {message}")
                        with self.client_map_lock:
                            recipient_socket = self.client_map.get(target)
                        if recipient_socket:
                            send_message(recipient_socket, "chat", message, extra_headers={"from": username})
                        else:
                            self.db.save_offline_message(username, target, "chat", message.encode('utf-8'))
                            send_message(ssock, "chat", f"用户 {target} 离线，消息已保存")
                        if message.lower() == "quit":
                            break

                    elif msg_type == "file":
                        target = header.get("to")
                        if not target:
                            send_message(ssock, "chat", "错误，未指定接收者")
                            continue
                        if not self.db.is_friend(username, target):
                            send_message(ssock, "error", f"错误：{target} 不是您的好友")
                            continue
                        with self.client_map_lock:
                            recipient_socket = self.client_map.get(target)
                        if not recipient_socket:
                            filename = header.get("filename", "received_file")
                            self.db.save_offline_message(username, target, "file", data, filename=filename)
                            send_message(ssock, "chat", f"用户 {target} 离线，文件已保存")
                            continue
                        filename = header.get("filename", "received_file")
                        file_data = data
                        file_path = f"files/recv_{username}_to_{target}_{filename}"
                        try:
                            with open(file_path, 'wb') as f:
                                f.write(file_data)
                            send_message(recipient_socket, "file", file_data,
                                         extra_headers={"from": username, "filename": filename, "filesize": len(file_data)})
                            logging.info(f"文件 {filename} 已接收并转发")
                            #删除中转文件
                            os.remove(file_path)
                        except Exception as e:
                            logging.error(f"接收文件失败: {e}")

                    elif msg_type == "friend_request":
                        target = header.get("to")
                        if not self.db.user_exists(target):
                            send_message(ssock, "error", f"用户 {target} 不存在")
                            continue
                        if self.db.is_friend(username, target):
                            send_message(ssock, "error", f"用户 {target} 已是您的好友")
                            continue
                        if self.db.add_friend_request(username, target):
                            with self.client_map_lock:
                                recipient_socket = self.client_map.get(target)
                            if recipient_socket:
                                send_message(recipient_socket, "friend_request", f"来自 {username} 的好友请求",
                                             extra_headers={"from": username})
                            send_message(ssock, "chat", f"好友请求已发送给 {target}")
                            logging.info(f"好友请求发送：{username} -> {target}")
                        else:
                            send_message(ssock, "error", "好友请求发送失败，可能已存在")
                            logging.error(f"好友请求发送失败：{username} -> {target}")

                    elif msg_type == "list_friend_requests":
                        pending_requests = self.db.get_pending_friend_requests(username)
                        send_message(ssock, "list_friend_requests", json.dumps(pending_requests))

                    elif msg_type == "list_friends":
                        users = self.db.get_friends(username)
                        with self.client_map_lock:
                            users_list = [[user, user in self.client_map] for user in users]
                        send_message(ssock, "admin_response", json.dumps(users_list), extra_headers={"response_type": "list_friends"})
                        logging.info(f"用户 {username} 请求好友列表")

                    elif msg_type == "accept_friend":
                        requester = header.get("from")
                        if not self.db.has_pending_request(requester, username):
                            send_message(ssock, "error", f"没有来自 {requester} 的好友请求")
                            continue
                        self.db.accept_friend_request(requester, username)
                        send_message(ssock, "chat", f"已接受 {requester} 的好友请求")
                        with self.client_map_lock:
                            requester_socket = self.client_map.get(requester)
                        if requester_socket:
                            send_message(requester_socket, "chat", f"{username} 已接受您的好友请求")
                        logging.info(f"好友请求接受：{requester} <-> {username}")

                    elif msg_type == "reject_friend":
                        requester = header.get("from")
                        if not self.db.has_pending_request(requester, username):
                            send_message(ssock, "error", f"没有来自 {requester} 的好友请求")
                            continue
                        self.db.reject_friend_request(requester, username)
                        send_message(ssock, "chat", f"已拒绝 {requester} 的好友请求")
                        logging.info(f"好友请求拒绝：{requester} -> {username}")

                    elif msg_type == "admin_command":
                        if not self.db.get_user(username)[1]:
                            send_message(ssock, "error", "无管理员权限")
                            continue
                        command = header.get("action")
                        if command == "list_users":
                            users = self.db.get_all_users()
                            with self.client_map_lock:
                                users_list = [[user, user in self.client_map, is_admin] for user, is_admin in users]
                            send_message(ssock, "admin_response", json.dumps(users_list), extra_headers={"response_type": "list_users"})
                        elif command == "delete_user":
                            target_user = data.decode("utf-8")
                            if self.db.delete_user(target_user):
                                users = self.db.get_all_users()
                                with self.client_map_lock:
                                    users_list = [[user, user in self.client_map, is_admin] for user, is_admin in users]
                                send_message(ssock, "admin_response", json.dumps(users_list),
                                             extra_headers={"response_type": "list_users", "action_result": f"删除用户 {target_user} 成功"})
                                logging.info(f"管理员 {username} 删除用户: {target_user}")
                            else:
                                send_message(ssock, "error", f"删除用户 {target_user} 失败")
                        elif command == "announcement":
                            announcement_msg = data.decode("utf-8")
                            with self.client_map_lock:
                                for user, sock in self.client_map.items():
                                    try:
                                        send_message(sock, "chat", announcement_msg,
                                                     extra_headers={"from": "[系统公告]"})
                                    except Exception as e:
                                        logging.error(f"向用户 {user} 发送公告失败: {e}")
                        elif command == "exit":
                            send_message(ssock, "admin_response", "退出成功")
                            break
                    else:
                        logging.warning(f"未知消息类型来自 {username}")
        except ssl.SSLError as e:
            logging.error(f"SSL 错误: {e}")
        except Exception as e:
            logging.error(f"处理客户端 {client_address} 时出错: {e}")
        finally:
            if username:
                with self.client_map_lock:
                    self.client_map.pop(username, None)
            logging.info(f"客户端断开连接: {client_address}")
            client_socket.close()

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
                client_thread = threading.Thread(target=self.handle_client,
                                                args=(client_socket, client_address, context))
                client_thread.daemon = True
                client_thread.start()
            except Exception as e:
                logging.error(f"接受客户端连接时出错: {e}")

if __name__ == "__main__":
    server = Server()
    server.build_listen()