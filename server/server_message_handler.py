import logging
import json
import uuid
from datetime import datetime, timedelta
from protocol import send_message, recv_message
from server_group_handler import GroupHandler
from server_admin_handler import AdminHandler

class MessageHandler:
    def __init__(self, server):
        self.server = server
        self.group_handler = GroupHandler(server)
        self.admin_handler = AdminHandler(server)

    def send_initial_data(self, username, ssock):
        """发送初始好友和群组列表"""
        # 发送好友列表
        users = self.server.db.get_friends(username)
        with self.server.client_map_lock:
            users_list = [[user, user in self.server.client_map] for user in users]
        send_message(ssock, "admin_response", json.dumps(users_list), extra_headers={"response_type": "list_friends"})
        logging.info(f"发送初始好友列表给用户: {username}, 好友数={len(users_list)}")

        # 发送群组列表
        groups = self.server.db.get_user_groups(username)
        send_message(ssock, "list_groups", json.dumps([{"id": g[0], "group_name": g[1]} for g in groups]))
        logging.info(f"发送初始群组列表给用户: {username}, 群组数={len(groups)}")

    def load_offline_data(self, username, ssock):
        """加载用户的离线消息、好友请求和文件请求"""
        messages = self.server.db.get_offline_messages(username)
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
            elif msg_type == "group_chat":
                group_id = None
                # 从数据库获取群组ID
                with self.server.db._get_connection() as conn:
                    cursor = conn.cursor()
                    cursor.execute('''
                        SELECT group_id FROM group_members 
                        WHERE username = ? AND group_id IN (
                            SELECT group_id FROM group_members WHERE username = ?
                        )
                    ''', (username, sender))
                    result = cursor.fetchone()
                    if result:
                        group_id = result[0]
                if group_id:
                    group_name = self.server.db.get_user_groups(username)
                    group_name = next((g[1] for g in group_name if g[0] == group_id), f"群组 {group_id}")
                    send_message(ssock, "group_chat", content.decode('utf-8'),
                                 extra_headers={"from": sender, "group_id": str(group_id), "history": "true", "message_id": message_id, "status": status})
                    logging.info(f"发送离线群聊消息: 发送者={sender}, 群组ID={group_id}, 消息ID={message_id}")
                else:
                    logging.warning(f"未找到群组ID: 发送者={sender}, 接收者={username}, 消息ID={message_id}")
                    continue
            with self.server.client_map_lock:
                sender_socket = self.server.client_map.get(sender)
            if sender_socket and msg_type != "group_chat":  # 群聊消息不发送回执
                send_message(sender_socket, "status_update", "",
                             extra_headers={"message_id": message_id, "status": "delivered"})
                logging.info(f"通知发送方: 消息ID={message_id}, 状态=delivered, 目标={sender}")
        self.server.db.cleanup_delivered_messages(username)

        pending_requests = self.server.db.get_pending_friend_requests(username)
        for requester in pending_requests:
            send_message(ssock, "friend_request", f"来自 {requester} 的好友请求",
                         extra_headers={"from": requester})
            logging.info(f"发送好友请求通知: 请求者={requester}, 目标={username}")

        file_requests = self.server.db.get_pending_file_requests(username)
        for request in file_requests:
            sender, filename, filesize, message_id = request
            send_message(ssock, "file_request", "",
                         extra_headers={"from": sender, "filename": filename, "filesize": filesize, "message_id": message_id})
            logging.info(f"发送文件请求通知: 发送者={sender}, 目标={username}, 文件名={filename}, 消息ID={message_id}")

        user_groups = self.server.db.get_user_groups(username)
        for group_id, _ in user_groups:
            group_file_requests = self.server.db.get_pending_group_file_requests(group_id, username)
            current_time = datetime.utcnow()
            for request in group_file_requests:
                sender, filename, filesize, message_id = request
                if sender == username:
                    logging.info(f"跳过向发送者 {username} 发送自己的群组文件请求: 消息ID={message_id}, 群组ID={group_id}")
                    continue
                with self.server.db._get_connection() as conn:
                    cursor = conn.cursor()
                    cursor.execute('''
                        SELECT timestamp FROM group_file_requests WHERE message_id = ?
                    ''', (message_id,))
                    timestamp = cursor.fetchone()[0]
                    try:
                        request_time = datetime.strptime(timestamp, '%Y-%m-%d %H:%M:%S')
                        if current_time - request_time > timedelta(hours=24):
                            self.server.db.delete_group_file_request(message_id)
                            logging.info(f"删除过期群组文件请求: 消息ID={message_id}")
                            continue
                    except ValueError as e:
                        logging.error(f"时间格式错误: 消息ID={message_id}, 错误={e}")
                        continue
                send_message(ssock, "group_file_request", "",
                             extra_headers={"from": sender, "filename": filename, "filesize": filesize, "message_id": message_id, "group_id": str(group_id)})
                logging.info(f"发送群组文件请求通知: 发送者={sender}, 群组ID={group_id}, 文件名={filename}, 消息ID={message_id}")

    def process_messages(self, username, ssock):
        """处理客户端发送的消息"""
        while True:
            header, data = recv_message(ssock)
            if not header:
                logging.info(f"客户端 {username} 断开连接")
                break
            msg_type = header.get("type")
            logging.info(f"收到消息: 用户={username}, 类型={msg_type}, 头信息={header}")

            if msg_type == "chat":
                target = header.get("to")
                message_id = header.get("message_id", str(uuid.uuid4()))
                if not self.server.db.is_friend(username, target):
                    send_message(ssock, "error", f"错误：{target} 不是您的好友")
                    logging.warning(f"消息发送失败: {username} -> {target}, 非好友")
                    continue
                message = data.decode("utf-8")
                logging.info(f"来自 {username} 发往 {target} 的聊天消息: {message}, 消息ID={message_id}")
                self.server.db.save_offline_message(username, target, "chat", message.encode('utf-8'), message_id=message_id)
                with self.server.client_map_lock:
                    recipient_socket = self.server.client_map.get(target)
                if recipient_socket:
                    try:
                        send_message(recipient_socket, "chat", message,
                                     extra_headers={"from": username, "message_id": message_id, "status": "sent"})
                        logging.info(f"消息已转发: {username} -> {target}, 消息ID={message_id}")
                    except Exception as e:
                        logging.error(f"发送消息失败: {username} -> {target}, 消息ID={message_id}, 错误={e}")
                        with self.server.client_map_lock:
                            self.server.client_map.pop(target, None)
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
                message_id = header.get("message_id", str(uuid.uuid4()))
                filename = header.get("filename", "received_file")
                filesize = header.get("filesize", len(data))
                file_data = data
                if target.startswith("群组 "):
                    try:
                        group_id = int(target.split(" ")[1])
                        with self.server.db._get_connection() as conn:
                            cursor = conn.cursor()
                            cursor.execute('SELECT 1 FROM groups WHERE id = ?', (group_id,))
                            if not cursor.fetchone():
                                send_message(ssock, "error", f"群组 {group_id} 不存在")
                                logging.error(f"文件发送失败: 群组 {group_id} 不存在")
                                continue
                        if not self.server.db.is_group_member(group_id, username):
                            send_message(ssock, "error", "您不在此群组中")
                            logging.warning(f"文件发送失败: 用户 {username} 不在群组 {group_id} 中")
                            continue
                        self.server.db.save_group_file_request(group_id, username, filename, filesize, file_data, message_id)
                        self.group_handler.notify_group_members(
                            group_id, "group_file_request", "",
                            from_user=username,
                            extra_headers={"filename": filename, "filesize": filesize, "message_id": message_id}
                        )
                        send_message(ssock, "chat", f"文件请求已发送至群组 {group_id}")
                        logging.info(f"群组文件请求已保存: 群组ID={group_id}, 文件名={filename}, 消息ID={message_id}")
                    except ValueError:
                        send_message(ssock, "error", "无效的群组ID")
                        logging.error(f"文件发送失败: 无效的群组ID {target}")
                        continue
                else:
                    if not self.server.db.is_friend(username, target):
                        send_message(ssock, "error", f"错误：{target} 不是您的好友")
                        logging.warning(f"文件发送失败: {username} -> {target}, 非好友")
                        continue
                    self.server.db.save_file_request(username, target, filename, filesize, file_data, message_id)
                    with self.server.client_map_lock:
                        recipient_socket = self.server.client_map.get(target)
                    if recipient_socket:
                        try:
                            send_message(recipient_socket, "file_request", "",
                                         extra_headers={"from": username, "filename": filename, "filesize": filesize, "message_id": message_id})
                            logging.info(f"文件请求已发送: {username} -> {target}, 文件名={filename}, 消息ID={message_id}")
                        except Exception as e:
                            logging.error(f"发送文件请求失败: {username} -> {target}, 文件名={filename}, 消息ID={message_id}, 错误={e}")
                            with self.server.client_map_lock:
                                self.server.client_map.pop(target, None)
                    else:
                        send_message(ssock, "chat", f"用户 {target} 离线，文件请求已保存")
                        logging.info(f"用户 {target} 离线，文件请求已保存: 文件名={filename}, 消息ID={message_id}")

            elif msg_type == "file_response":
                message_id = header.get("message_id")
                response = header.get("response")
                target = header.get("to")
                file_request = self.server.db.get_file_request(message_id)
                if not file_request:
                    send_message(ssock, "error", f"文件请求 {message_id} 不存在")
                    logging.warning(f"文件响应失败: 消息ID={message_id} 不存在")
                    continue
                sender, receiver, filename, filesize, file_data = file_request
                if receiver != username:
                    send_message(ssock, "error", "无权限响应此文件请求")
                    logging.warning(f"文件响应失败: 用户 {username} 无权限响应消息ID={message_id}")
                    continue
                with self.server.client_map_lock:
                    sender_socket = self.server.client_map.get(sender)
                if response == "accept":
                    self.server.db.save_offline_message(sender, receiver, "file", file_data, filename=filename, message_id=message_id)
                    if sender_socket:
                        try:
                            send_message(sender_socket, "chat", f"用户 {receiver} 已接受文件 {filename}")
                            logging.info(f"通知发送方: {receiver} 接受文件 {filename}, 消息ID={message_id}")
                        except Exception as e:
                            logging.error(f"通知发送方失败: {receiver} 接受文件 {filename}, 消息ID={message_id}, 错误={e}")
                            with self.server.client_map_lock:
                                self.server.client_map.pop(sender, None)
                    if self.server.client_map.get(receiver):
                        try:
                            send_message(self.server.client_map[receiver], "file", file_data,
                                         extra_headers={"from": sender, "filename": filename, "filesize": filesize, "message_id": message_id, "status": "sent"})
                            logging.info(f"文件已传输: {sender} -> {receiver}, 文件名={filename}, 消息ID={message_id}")
                        except Exception as e:
                            logging.error(f"传输文件失败: {sender} -> {receiver}, 文件名={filename}, 消息ID={message_id}, 错误={e}")
                            with self.server.client_map_lock:
                                self.server.client_map.pop(receiver, None)
                    self.server.db.delete_file_request(message_id)
                    logging.info(f"文件请求已删除: 消息ID={message_id}")
                else:
                    if sender_socket:
                        try:
                            send_message(sender_socket, "chat", f"用户 {receiver} 已拒绝文件 {filename}")
                            logging.info(f"通知发送方: {receiver} 拒绝文件 {filename}, 消息ID={message_id}")
                        except Exception as e:
                            logging.error(f"通知发送方失败: {receiver} 拒绝文件 {filename}, 消息ID={message_id}, 错误={e}")
                            with self.server.client_map_lock:
                                self.server.client_map.pop(sender, None)
                    self.server.db.delete_file_request(message_id)
                    logging.info(f"文件请求已删除: 消息ID={message_id}")

            elif msg_type == "friend_request":
                target = header.get("to")
                if not self.server.db.user_exists(target):
                    send_message(ssock, "error", f"用户 {target} 不存在")
                    logging.warning(f"好友请求失败: 目标用户 {target} 不存在")
                    continue
                if self.server.db.is_friend(username, target):
                    send_message(ssock, "error", f"用户 {target} 已是您的好友")
                    logging.warning(f"好友请求失败: {username} 和 {target} 已为好友")
                    continue
                if self.server.db.add_friend_request(username, target):
                    with self.server.client_map_lock:
                        recipient_socket = self.server.client_map.get(target)
                    if recipient_socket:
                        try:
                            send_message(recipient_socket, "friend_request", f"来自 {username} 的好友请求",
                                         extra_headers={"from": username})
                            logging.info(f"好友请求已发送: {username} -> {target}")
                        except Exception as e:
                            logging.error(f"发送好友请求通知失败: {username} -> {target}, 错误={e}")
                            with self.server.client_map_lock:
                                self.server.client_map.pop(target, None)
                    send_message(ssock, "chat", f"好友请求已发送给 {target}")
                    logging.info(f"好友请求发送：{username} -> {target}")
                else:
                    send_message(ssock, "error", "好友请求发送失败，可能已存在")
                    logging.error(f"好友请求发送失败：{username} -> {target}")

            elif msg_type == "list_friend_requests":
                pending_requests = self.server.db.get_pending_friend_requests(username)
                send_message(ssock, "list_friend_requests", json.dumps(pending_requests))
                logging.info(f"发送好友请求列表: 用户={username}, 请求数={len(pending_requests)}")

            elif msg_type == "list_friends":
                users = self.server.db.get_friends(username)
                with self.server.client_map_lock:
                    users_list = [[user, user in self.server.client_map] for user in users]
                send_message(ssock, "admin_response", json.dumps(users_list), extra_headers={"response_type": "list_friends"})
                logging.info(f"用户 {username} 请求好友列表")

            elif msg_type == "accept_friend":
                requester = header.get("from")
                if not self.server.db.has_pending_request(requester, username):
                    send_message(ssock, "error", f"没有来自 {requester} 的好友请求")
                    logging.warning(f"接受好友请求失败: 没有来自 {requester} 的请求")
                    continue
                self.server.db.accept_friend_request(requester, username)
                send_message(ssock, "chat", f"已接受 {requester} 的好友请求")
                with self.server.client_map_lock:
                    requester_socket = self.server.client_map.get(requester)
                if requester_socket:
                    try:
                        send_message(requester_socket, "chat", f"{username} 已接受您的好友请求")
                        logging.info(f"通知请求者: {username} 接受好友请求")
                    except Exception as e:
                        logging.error(f"通知请求者失败: {username} 接受好友请求, 错误={e}")
                        with self.server.client_map_lock:
                            self.server.client_map.pop(requester, None)
                logging.info(f"好友请求接受：{requester} <-> {username}")

            elif msg_type == "reject_friend":
                requester = header.get("from")
                if not self.server.db.has_pending_request(requester, username):
                    send_message(ssock, "error", f"没有来自 {requester} 的好友请求")
                    logging.warning(f"拒绝好友请求失败: 没有来自 {requester} 的请求")
                    continue
                self.server.db.reject_friend_request(requester, username)
                send_message(ssock, "chat", f"已拒绝 {requester} 的好友请求")
                logging.info(f"好友请求拒绝：{requester} -> {username}")

            elif msg_type == "recall":
                message_id = header.get("message_id")
                message_info = self.server.db.get_message_info(message_id)
                file_request = self.server.db.get_file_request(message_id)
                group_file_request = self.server.db.get_group_file_request(message_id)
                if not message_info and not file_request and not group_file_request:
                    send_message(ssock, "error", f"消息或文件请求 {message_id} 不存在")
                    logging.warning(f"撤回消息失败: 消息ID={message_id} 不存在")
                    continue

                # 原有：处理 offline_messages
                if message_info:
                    sender, receiver, msg_type, _, _, status, timestamp = message_info
                    if sender != username:
                        send_message(ssock, "error", "只能撤回自己的消息")
                        logging.warning(f"撤回消息失败: 用户 {username} 尝试撤回非自己的消息 {message_id}")
                        continue
                    try:
                        message_time = datetime.strptime(timestamp, '%Y-%m-%d %H:%M:%S')
                        current_time = datetime.utcnow()
                        time_diff = current_time - message_time
                        logging.info(
                            f"撤回消息时间检查: 消息ID={message_id}, 原始时间戳={timestamp}, 解析时间={message_time}, 当前时间={current_time}, 时间差={time_diff.total_seconds()}秒")

                        if time_diff > timedelta(minutes=2):
                            send_message(ssock, "error",
                                         f"消息超过2分钟，无法撤回 (时间差: {time_diff.total_seconds()}秒)")
                            logging.warning(
                                f"撤回消息失败: 消息 {message_id} 超过2分钟, 时间差={time_diff.total_seconds()}秒")
                            continue
                    except ValueError as e:
                        send_message(ssock, "error", f"消息时间格式错误: {e}")
                        logging.error(f"撤回消息失败: 消息 {message_id} 时间格式错误: {e}")
                        continue

                    if status == 'recalled':
                        send_message(ssock, "error", "消息已被撤回")
                        logging.warning(f"撤回消息失败: 消息 {message_id} 已被撤回")
                        continue

                    if self.server.db.update_message_status(message_id, 'recalled'):
                        if msg_type == "group_chat":
                            # 获取群组ID
                            with self.server.db._get_connection() as conn:
                                cursor = conn.cursor()
                                cursor.execute('SELECT group_id FROM group_members WHERE username = ?', (receiver,))
                                group_ids = [row[0] for row in cursor.fetchall()]
                                # 找到包含 sender 和 receiver 的群组
                                for group_id in group_ids:
                                    if self.server.db.is_group_member(group_id, sender):
                                        self.group_handler.notify_group_members(
                                            group_id, "recall", "", from_user=username,
                                            extra_headers={"message_id": message_id}
                                        )
                                        break
                                else:
                                    logging.warning(f"未找到包含 {sender} 和 {receiver} 的群组，消息ID={message_id}")
                        else:
                            with self.server.client_map_lock:
                                recipient_socket = self.server.client_map.get(receiver)
                            if recipient_socket:
                                try:
                                    send_message(recipient_socket, "recall", "",
                                                 extra_headers={"message_id": message_id, "from": username})
                                    logging.info(f"通知接收方: 消息ID={message_id}, 撤回者={username}")
                                except Exception as e:
                                    logging.error(f"通知接收方失败: 消息ID={message_id}, 撤回者={username}, 错误={e}")
                                    with self.server.client_map_lock:
                                        self.server.client_map.pop(receiver, None)
                        send_message(ssock, "chat", f"消息 {message_id} 已撤回")
                        logging.info(f"消息撤回成功：{username} 撤回了消息 {message_id}")
                    else:
                        send_message(ssock, "error", f"撤回消息 {message_id} 失败")
                        logging.error(f"撤回消息失败：{message_id}")

                # 修改处1：处理私聊文件请求 (file_requests)
                elif file_request:
                    sender, receiver, filename, filesize, content = file_request
                    if sender != username:
                        send_message(ssock, "error", "只能撤回自己的文件请求")
                        logging.warning(f"撤回文件请求失败: 用户 {username} 尝试撤回非自己的文件请求 {message_id}")
                        continue

                    # 获取 timestamp 并检查2分钟限制（从 file_requests 表获取）
                    with self.server.db._get_connection() as conn:
                        cursor = conn.cursor()
                        cursor.execute('SELECT timestamp FROM file_requests WHERE message_id = ?', (message_id,))
                        timestamp = cursor.fetchone()[0]
                    try:
                        request_time = datetime.strptime(timestamp, '%Y-%m-%d %H:%M:%S')
                        current_time = datetime.utcnow()
                        time_diff = current_time - request_time
                        if time_diff > timedelta(minutes=2):
                            send_message(ssock, "error", f"文件请求超过2分钟，无法撤回")
                            logging.warning(f"撤回文件请求失败: {message_id} 超过2分钟")
                            continue

                    except ValueError as e:
                        send_message(ssock, "error", f"文件请求时间格式错误: {e}")
                        logging.error(f"撤回文件请求失败: {message_id} 时间格式错误: {e}")
                        continue

                    # 删除文件请求
                    if self.server.db.delete_file_request(message_id):
                        # 如果 receiver 在线，通知撤回
                        with self.server.client_map_lock:
                            recipient_socket = self.server.client_map.get(receiver)
                        if recipient_socket:
                            try:
                                send_message(recipient_socket, "chat",
                                             f"用户 {username} 撤回了文件请求: {filename} ({message_id})")
                                logging.info(f"通知接收方文件请求撤回: {message_id}, 接收方={receiver}")

                            except Exception as e:
                                logging.error(f"通知接收方文件请求撤回失败: {message_id}, 错误={e}")
                                with self.server.client_map_lock:
                                    self.server.client_map.pop(receiver, None)
                        send_message(ssock, "chat", f"文件请求 {message_id} 已撤回")
                        logging.info(f"私聊文件请求撤回成功: {username} 撤回了 {message_id}")
                    else:
                        send_message(ssock, "error", f"撤回文件请求 {message_id} 失败")
                        logging.error(f"撤回私聊文件请求失败: {message_id}")

                # 修改处2：处理群组文件请求 (group_file_requests)
                elif group_file_request:
                    group_id, sender, filename, filesize, content = group_file_request
                    if sender != username:
                        send_message(ssock, "error", "只能撤回自己的文件请求")
                        logging.warning(f"撤回群组文件请求失败: 用户 {username} 尝试撤回非自己的文件请求 {message_id}")
                        continue

                    # 获取 timestamp 并检查2分钟限制（从 group_file_requests 表获取）
                    with self.server.db._get_connection() as conn:
                        cursor = conn.cursor()
                        cursor.execute('SELECT timestamp FROM group_file_requests WHERE message_id = ?', (message_id,))
                        timestamp = cursor.fetchone()[0]
                    try:
                        request_time = datetime.strptime(timestamp, '%Y-%m-%d %H:%M:%S')
                        current_time = datetime.utcnow()
                        time_diff = current_time - request_time

                        if time_diff > timedelta(minutes=2):
                            send_message(ssock, "error", f"群组文件请求超过2分钟，无法撤回")
                            logging.warning(f"撤回群组文件请求失败: {message_id} 超过2分钟")
                            continue

                    except ValueError as e:
                        send_message(ssock, "error", f"群组文件请求时间格式错误: {e}")
                        logging.error(f"撤回群组文件请求失败: {message_id} 时间格式错误: {e}")
                        continue

                    # 删除群组文件请求（会级联删除 responses）
                    if self.server.db.delete_group_file_request(message_id):
                        # 通知群成员文件请求撤回（即使离线，上线时不会加载）
                        self.group_handler.notify_group_members(
                            group_id, "chat", f"用户 {username} 撤回了群组文件请求: {filename} ({message_id})",
                            from_user="系统"
                        )

                        send_message(ssock, "chat", f"群组文件请求 {message_id} 已撤回")
                        logging.info(f"群组文件请求撤回成功: {username} 撤回了 {message_id} 在群组 {group_id}")

                    else:
                        send_message(ssock, "error", f"撤回群组文件请求 {message_id} 失败")
                        logging.error(f"撤回群组文件请求失败: {message_id}")

            elif msg_type == "admin_command":
                self.admin_handler.handle_admin_command(username, ssock, header, data)

            elif msg_type in ("create_group", "join_group", "group_chat", "list_groups", "group_file_response"):
                self.group_handler.handle_group_message(username, ssock, msg_type, header, data)