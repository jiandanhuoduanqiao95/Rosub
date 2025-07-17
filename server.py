import socket
import ssl
import os
from protocol import send_message, recv_message
import threading
import logging
import bcrypt
from database import Database
import json
import uuid
from datetime import datetime, timedelta

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
                    send_message(ssock, "error", "错误，请先注册或登录")
                    return

                msg_type = header.get("type")
                username = data.decode("utf-8").strip()
                password = header.get("password")
                logging.info(f"处理认证请求: 用户={username}, 类型={msg_type}")
                if msg_type == "register":
                    if self.db.user_exists(username):
                        send_message(ssock, "error", "用户已存在")
                        logging.warning(f"注册失败: 用户 {username} 已存在")
                        return
                    password_hash = bcrypt.hashpw(password.encode('utf-8'), bcrypt.gensalt())
                    if self.db.add_user(username, password_hash):
                        send_message(ssock, "chat", "注册成功")
                        with self.client_map_lock:
                            self.client_map[username] = ssock
                        logging.info(f"注册成功: 用户={username}")
                    else:
                        send_message(ssock, "error", "注册失败")
                        logging.error(f"注册失败: 用户={username}")
                        return
                elif msg_type == "login":
                    user_data = self.db.get_user(username)
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
                        with self.client_map_lock:
                            self.client_map[username] = ssock
                        messages = self.db.get_offline_messages(username)
                        logging.info(f"用户 {username} 的离线消息: {len(messages)} 条")
                        for msg in messages:
                            sender, msg_type, content, filename, message_id, status = msg
                            logging.info(f"发送离线消息: 发送者={sender}, 类型={msg_type}, 消息ID={message_id}")
                            if msg_type == "chat":
                                send_message(ssock, "chat", content.decode('utf-8'),
                                             extra_headers={"from": sender, "history": "true", "message_id": message_id, "status": status})
                            elif msg_type == "file":
                                send_message(ssock, "file", content,
                                             extra_headers={"from": sender, "filename": filename, "history": "true", "message_id": message_id, "status": status})
                            with self.client_map_lock:
                                sender_socket = self.client_map.get(sender)
                            if sender_socket:
                                send_message(sender_socket, "status_update", "",
                                             extra_headers={"message_id": message_id, "status": "delivered"})
                                logging.info(f"通知发送方: 消息ID={message_id}, 状态=delivered, 目标={sender}")
                        self.db.cleanup_delivered_messages(username)
                        pending_requests = self.db.get_pending_friend_requests(username)
                        for requester in pending_requests:
                            send_message(ssock, "friend_request", f"来自 {requester} 的好友请求",
                                         extra_headers={"from": requester})
                            logging.info(f"发送好友请求通知: 请求者={requester}, 目标={username}")
                        file_requests = self.db.get_pending_file_requests(username)
                        for request in file_requests:
                            sender, filename, filesize, message_id = request
                            send_message(ssock, "file_request", "",
                                         extra_headers={"from": sender, "filename": filename, "filesize": filesize, "message_id": message_id})
                            logging.info(f"发送文件请求通知: 发送者={sender}, 目标={username}, 文件名={filename}, 消息ID={message_id}")
                    else:
                        send_message(ssock, "error", "错误：密码错误")
                        logging.warning(f"登录失败: 用户 {username} 密码错误")
                        return

                while True:
                    header, data = recv_message(ssock)
                    if not header:
                        logging.info(f"客户端 {username or client_address} 断开连接")
                        break
                    msg_type = header.get("type")
                    logging.info(f"收到消息: 用户={username}, 类型={msg_type}, 头信息={header}")

                    if msg_type == "chat":
                        target = header.get("to")
                        message_id = header.get("message_id")
                        if not message_id:
                            message_id = str(uuid.uuid4())
                            logging.warning(f"客户端未提供 message_id，生成新ID: {message_id}")
                        if not self.db.is_friend(username, target):
                            send_message(ssock, "error", f"错误：{target} 不是您的好友")
                            logging.warning(f"消息发送失败: {username} -> {target}, 非好友")
                            continue
                        message = data.decode("utf-8")
                        logging.info(f"来自 {username} 发往 {target} 的聊天消息: {message}, 消息ID={message_id}")
                        self.db.save_offline_message(username, target, "chat", message.encode('utf-8'), message_id=message_id)
                        with self.client_map_lock:
                            recipient_socket = self.client_map.get(target)
                        if recipient_socket:
                            send_message(recipient_socket, "chat", message,
                                         extra_headers={"from": username, "message_id": message_id, "status": "sent"})
                            logging.info(f"消息已转发: {username} -> {target}, 消息ID={message_id}")
                        else:
                            send_message(ssock, "chat", f"用户 {target} 离线，消息已保存")
                            logging.info(f"用户 {target} 离线，消息已保存: 消息ID={message_id}")
                        if message.lower() == "quit":
                            break

                    elif msg_type == "file":
                        target = header.get("to")
                        if not target:
                            send_message(ssock, "error", "错误，未指定接收者")
                            logging.error(f"文件消息失败: 未指定接收者")
                            continue
                        if not self.db.is_friend(username, target):
                            send_message(ssock, "error", f"错误：{target} 不是您的好友")
                            logging.warning(f"文件发送失败: {username} -> {target}, 非好友")
                            continue
                        message_id = header.get("message_id")
                        if not message_id:
                            message_id = str(uuid.uuid4())
                            logging.warning(f"客户端未提供 message_id，生成新ID: {message_id}")
                        filename = header.get("filename", "received_file")
                        filesize = header.get("filesize", len(data))
                        file_data = data
                        self.db.save_file_request(username, target, filename, filesize, file_data, message_id)
                        with self.client_map_lock:
                            recipient_socket = self.client_map.get(target)
                        if recipient_socket:
                            send_message(recipient_socket, "file_request", "",
                                         extra_headers={"from": username, "filename": filename, "filesize": filesize, "message_id": message_id})
                            logging.info(f"文件请求已发送: {username} -> {target}, 文件名={filename}, 消息ID={message_id}")
                        else:
                            send_message(ssock, "chat", f"用户 {target} 离线，文件请求已保存")
                            logging.info(f"用户 {target} 离线，文件请求已保存: 文件名={filename}, 消息ID={message_id}")

                    elif msg_type == "file_response":
                        message_id = header.get("message_id")
                        response = header.get("response")
                        target = header.get("to")
                        file_request = self.db.get_file_request(message_id)
                        if not file_request:
                            send_message(ssock, "error", f"文件请求 {message_id} 不存在")
                            logging.warning(f"文件响应失败: 消息ID={message_id} 不存在")
                            continue
                        sender, receiver, filename, filesize, file_data = file_request
                        if receiver != username:
                            send_message(ssock, "error", "无权限响应此文件请求")
                            logging.warning(f"文件响应失败: 用户 {username} 无权限响应消息ID={message_id}")
                            continue
                        with self.client_map_lock:
                            sender_socket = self.client_map.get(sender)
                        if response == "accept":
                            self.db.save_offline_message(sender, receiver, "file", file_data, filename=filename, message_id=message_id)
                            if sender_socket:
                                send_message(sender_socket, "chat", f"用户 {receiver} 已接受文件 {filename}")
                                logging.info(f"通知发送方: {receiver} 接受文件 {filename}, 消息ID={message_id}")
                            if self.client_map.get(receiver):
                                send_message(self.client_map[receiver], "file", file_data,
                                             extra_headers={"from": sender, "filename": filename, "filesize": filesize, "message_id": message_id, "status": "sent"})
                                logging.info(f"文件已传输: {sender} -> {receiver}, 文件名={filename}, 消息ID={message_id}")
                            self.db.delete_file_request(message_id)
                            logging.info(f"文件请求已删除: 消息ID={message_id}")
                        else:
                            if sender_socket:
                                send_message(sender_socket, "chat", f"用户 {receiver} 已拒绝文件 {filename}")
                                logging.info(f"通知发送方: {receiver} 拒绝文件 {filename}, 消息ID={message_id}")
                            self.db.delete_file_request(message_id)
                            logging.info(f"文件请求已删除: 消息ID={message_id}")

                    elif msg_type == "friend_request":
                        target = header.get("to")
                        if not self.db.user_exists(target):
                            send_message(ssock, "error", f"用户 {target} 不存在")
                            logging.warning(f"好友请求失败: 目标用户 {target} 不存在")
                            continue
                        if self.db.is_friend(username, target):
                            send_message(ssock, "error", f"用户 {target} 已是您的好友")
                            logging.warning(f"好友请求失败: {username} 和 {target} 已为好友")
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
                        logging.info(f"发送好友请求列表: 用户={username}, 请求数={len(pending_requests)}")

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
                            logging.warning(f"接受好友请求失败: 没有来自 {requester} 的请求")
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
                            logging.warning(f"拒绝好友请求失败: 没有来自 {requester} 的请求")
                            continue
                        self.db.reject_friend_request(requester, username)
                        send_message(ssock, "chat", f"已拒绝 {requester} 的好友请求")
                        logging.info(f"好友请求拒绝：{requester} -> {username}")

                    elif msg_type == "admin_command":
                        if not self.db.get_user(username)[1]:
                            send_message(ssock, "error", "无管理员权限")
                            logging.warning(f"管理员命令失败: 用户 {username} 无权限")
                            continue
                        command = header.get("action")
                        if command == "list_users":
                            users = self.db.get_all_users()
                            with self.client_map_lock:
                                users_list = [[user, user in self.client_map, is_admin] for user, is_admin in users]
                            send_message(ssock, "admin_response", json.dumps(users_list), extra_headers={"response_type": "list_users"})
                            logging.info(f"列出所有用户: 用户={username}")
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
                                logging.error(f"删除用户失败: {target_user}")
                        elif command == "announcement":
                            announcement_msg = data.decode("utf-8")
                            with self.client_map_lock:
                                for user, sock in self.client_map.items():
                                    try:
                                        send_message(sock, "chat", announcement_msg,
                                                     extra_headers={"from": "[系统公告]"})
                                        logging.info(f"向用户 {user} 发送公告")
                                    except Exception as e:
                                        logging.error(f"向用户 {user} 发送公告失败: {e}")
                        elif command == "exit":
                            send_message(ssock, "admin_response", "退出成功")
                            logging.info(f"管理员 {username} 退出")
                            break

                    elif msg_type == "recall":
                        message_id = header.get("message_id")
                        message_info = self.db.get_message_info(message_id)
                        file_request = self.db.get_file_request(message_id)
                        if not message_info and not file_request:
                            send_message(ssock, "error", f"消息或文件请求 {message_id} 不存在")
                            logging.warning(f"撤回消息失败: 消息ID={message_id} 不存在")
                            continue
                        if message_info:
                            sender, receiver, _, _, _, status, timestamp = message_info
                            if sender != username:
                                send_message(ssock, "error", "只能撤回自己的消息")
                                logging.warning(f"撤回消息失败: 用户 {username} 尝试撤回非自己的消息 {message_id}")
                                continue
                            try:
                                message_time = datetime.strptime(timestamp, '%Y-%m-%d %H:%M:%S')
                                current_time = datetime.utcnow()
                                time_diff = current_time - message_time
                                logging.info(f"撤回消息时间检查: 消息ID={message_id}, 原始时间戳={timestamp}, 解析时间={message_time}, 当前时间={current_time}, 时间差={time_diff.total_seconds()}秒")
                                if time_diff > timedelta(minutes=2):
                                    send_message(ssock, "error", f"消息超过2分钟，无法撤回 (时间差: {time_diff.total_seconds()}秒)")
                                    logging.warning(f"撤回消息失败: 消息 {message_id} 超过2分钟, 时间差={time_diff.total_seconds()}秒")
                                    continue
                            except ValueError as e:
                                send_message(ssock, "error", f"消息时间格式错误: {e}")
                                logging.error(f"撤回消息失败: 消息 {message_id} 时间格式错误: {e}")
                                continue
                            if status == 'recalled':
                                send_message(ssock, "error", "消息已被撤回")
                                logging.warning(f"撤回消息失败: 消息 {message_id} 已被撤回")
                                continue
                            if self.db.update_message_status(message_id, 'recalled'):
                                with self.client_map_lock:
                                    recipient_socket = self.client_map.get(receiver)
                                if recipient_socket:
                                    send_message(recipient_socket, "recall", "", extra_headers={"message_id": message_id, "from": username})
                                    logging.info(f"通知接收方: 消息ID={message_id}, 撤回者={username}")
                                send_message(ssock, "chat", f"消息 {message_id} 已撤回")
                                logging.info(f"消息撤回成功：{username} 撤回了消息 {message_id}")
                            else:
                                send_message(ssock, "error", f"撤回消息 {message_id} 失败")
                                logging.error(f"撤回消息失败：{message_id}")
                        elif file_request:
                            sender, receiver, filename, filesize, _ = file_request
                            if sender != username:
                                send_message(ssock, "error", "只能撤回自己的文件请求")
                                logging.warning(f"撤回文件请求失败: 用户 {username} 尝试撤回非自己的文件请求 {message_id}")
                                continue
                            self.db.delete_file_request(message_id)
                            with self.client_map_lock:
                                recipient_socket = self.client_map.get(receiver)
                            if recipient_socket:
                                send_message(recipient_socket, "chat", f"文件请求 {filename} 已被 {username} 撤回",
                                             extra_headers={"message_id": message_id})
                            send_message(ssock, "chat", f"文件请求 {filename} 已撤回")
                            logging.info(f"文件请求撤回成功：{username} 撤回了文件请求 {message_id}")

                    elif msg_type == "receipt":
                        message_id = header.get("message_id")
                        target = header.get("to")
                        if not target:
                            logging.error(f"回执消息缺少目标用户: 消息ID={message_id}")
                            send_message(ssock, "error", f"消息 {message_id} 回执失败：缺少目标用户")
                            continue
                        if self.db.update_message_status(message_id, "delivered"):
                            with self.client_map_lock:
                                sender_socket = self.client_map.get(target)
                            if sender_socket:
                                send_message(sender_socket, "status_update", "",
                                             extra_headers={"message_id": message_id, "status": "delivered"})
                                logging.info(f"发送状态更新: 消息ID={message_id}, 状态=delivered, 目标={target}")
                            logging.info(f"消息回执：{message_id} 已送达")
                        else:
                            send_message(ssock, "error", f"消息 {message_id} 回执失败")
                            logging.error(f"消息回执失败：{message_id} 不存在或已更新")

                    else:
                        logging.warning(f"未知消息类型来自 {username}: {msg_type}")
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