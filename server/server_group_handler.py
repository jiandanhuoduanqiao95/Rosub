import json
import logging
from protocol import send_message

class GroupHandler:
    def __init__(self, server):
        self.server = server

    def handle_group_message(self, username, ssock, msg_type, header, data):
        """处理群组相关的消息"""
        if msg_type == "create_group":
            group_name = data.decode("utf-8").strip()
            group_id = self.server.db.create_group(group_name, username)
            send_message(ssock, "chat", f"群组 {group_name} 创建成功，ID: {group_id}")
            logging.info(f"用户 {username} 创建群组: {group_name}, ID: {group_id}")
            self.notify_group_members(group_id, "chat", f"群组 {group_name} 已创建", from_user="系统")

        elif msg_type == "join_group":
            try:
                group_id = int(data.decode("utf-8").strip())
                with self.server.db._get_connection() as conn:
                    cursor = conn.cursor()
                    cursor.execute('SELECT 1 FROM groups WHERE id = ?', (group_id,))
                    if not cursor.fetchone():
                        send_message(ssock, "error", f"群组 {group_id} 不存在")
                        logging.error(f"用户 {username} 尝试加入不存在的群组: {group_id}")
                        return
                if not self.server.db.is_group_member(group_id, username):
                    self.server.db.join_group(group_id, username)
                    send_message(ssock, "chat", f"已加入群组 {group_id}")
                    logging.info(f"用户 {username} 加入群组: {group_id}")
                    self.notify_group_members(group_id, "chat", f"{username} 加入了群组", from_user="系统")
                else:
                    send_message(ssock, "error", "您已在群组中")
                    logging.warning(f"用户 {username} 尝试重复加入群组: {group_id}")
            except ValueError:
                send_message(ssock, "error", "无效的群组ID")
                logging.error(f"用户 {username} 提供无效的群组ID: {data.decode('utf-8')}")
            except Exception as e:
                send_message(ssock, "error", f"加入群组失败: {str(e)}")
                logging.error(f"用户 {username} 加入群组失败: {str(e)}")

        elif msg_type == "group_chat":
            try:
                group_id = int(header.get("group_id"))
                with self.server.db._get_connection() as conn:
                    cursor = conn.cursor()
                    cursor.execute('SELECT 1 FROM groups WHERE id = ?', (group_id,))
                    if not cursor.fetchone():
                        send_message(ssock, "error", f"群组 {group_id} 不存在")
                        logging.error(f"用户 {username} 尝试发送消息到不存在的群组: {group_id}")
                        return
                if not self.server.db.is_group_member(group_id, username):
                    send_message(ssock, "error", "您不在此群组中")
                    logging.warning(f"用户 {username} 尝试发送消息到未加入的群组: {group_id}")
                    return
                message = data.decode("utf-8")
                self.notify_group_members(group_id, "group_chat", message, from_user=username)
                logging.info(f"群组消息: 用户={username}, 群组ID={group_id}, 消息={message}")
            except ValueError:
                send_message(ssock, "error", "无效的群组ID")
                logging.error(f"用户 {username} 提供无效的群组ID: {header.get('group_id')}")
            except Exception as e:
                send_message(ssock, "error", f"发送群组消息失败: {str(e)}")
                logging.error(f"用户 {username} 发送群组消息失败: {str(e)}")

        elif msg_type == "list_groups":
            groups = self.server.db.get_user_groups(username)
            send_message(ssock, "list_groups", json.dumps([{"id": g[0], "group_name": g[1]} for g in groups]))
            logging.info(f"发送群组列表给用户: {username}")

        elif msg_type == "group_file_response":
            message_id = header.get("message_id")
            response = header.get("response")
            group_id = header.get("group_id")
            file_request = self.server.db.get_group_file_request(message_id)
            if not file_request:
                send_message(ssock, "error", f"群组文件请求 {message_id} 不存在")
                logging.warning(f"群组文件响应失败: 消息ID={message_id} 不存在")
                return
            group_id_db, sender, filename, filesize, file_data = file_request
            if int(group_id) != group_id_db:
                send_message(ssock, "error", "无效的群组ID")
                logging.warning(f"群组文件响应失败: 用户 {username} 提供无效的群组ID {group_id}")
                return
            if not self.server.db.is_group_member(group_id, username):
                send_message(ssock, "error", "您不在此群组中")
                logging.warning(f"群组文件响应失败: 用户 {username} 不在群组 {group_id} 中")
                return
            self.server.db.save_group_file_response(message_id, group_id, username, response)
            with self.server.client_map_lock:
                sender_socket = self.server.client_map.get(sender)
            if response == "accept":
                self.server.db.save_offline_message(sender, username, "file", file_data, filename=filename, message_id=message_id)
                if sender_socket:
                    try:
                        send_message(sender_socket, "chat", f"用户 {username} 已接受群组 {group_id} 的文件 {filename}")
                        logging.info(f"通知发送方: {username} 接受群组文件 {filename}, 消息ID={message_id}")
                    except Exception as e:
                        logging.error(f"通知发送方失败: {username} 接受群组文件 {filename}, 消息ID={message_id}, 错误={e}")
                        with self.server.client_map_lock:
                            self.server.client_map.pop(sender, None)
                if self.server.client_map.get(username):
                    try:
                        send_message(self.server.client_map[username], "file", file_data,
                                     extra_headers={"from": sender, "filename": filename, "filesize": filesize, "message_id": message_id, "status": "sent"})
                        logging.info(f"群组文件已传输: {sender} -> {username}, 文件名={filename}, 消息ID={message_id}")
                    except Exception as e:
                        logging.error(f"传输群组文件失败: {sender} -> {username}, 文件名={filename}, 消息ID={message_id}, 错误={e}")
                        with self.server.client_map_lock:
                            self.server.client_map.pop(username, None)
            else:
                if sender_socket:
                    try:
                        send_message(sender_socket, "chat", f"用户 {username} 已拒绝群组 {group_id} 的文件 {filename}")
                        logging.info(f"通知发送方: {username} 拒绝群组文件 {filename}, 消息ID={message_id}")
                    except Exception as e:
                        logging.error(f"通知发送方失败: {username} 拒绝群组文件 {filename}, 消息ID={message_id}, 错误={e}")
                        with self.server.client_map_lock:
                            self.server.client_map.pop(sender, None)
            if self.server.db.all_members_responded(message_id, group_id):
                self.server.db.delete_group_file_request(message_id)
                logging.info(f"群组文件请求已删除: 消息ID={message_id}, 所有成员已响应")
            else:
                logging.info(f"群组文件请求未删除: 消息ID={message_id}, 仍有成员未响应")

    def notify_group_members(self, group_id, msg_type, message, from_user="系统", extra_headers=None):
        """通知群组成员"""
        if extra_headers is None:
            extra_headers = {}
        try:
            if not group_id:
                logging.error(f"无效的群组ID: {group_id}")
                return
            with self.server.db._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute('SELECT username FROM group_members WHERE group_id = ?', (group_id,))
                members = [row[0] for row in cursor.fetchall()]
            logging.info(f"通知群组 {group_id} 的成员: {members}")
            for member in members:
                if msg_type == "group_file_request" and member == from_user:
                    logging.info(f"跳过向发送者 {from_user} 发送群组文件请求: 群组ID={group_id}")
                    continue
                with self.server.client_map_lock:
                    member_socket = self.server.client_map.get(member)
                if member_socket:
                    try:
                        send_message(member_socket, msg_type, message,
                                     extra_headers={"from": from_user, "group_id": str(group_id), **extra_headers})
                        logging.info(f"向 {member} 发送群组消息: 类型={msg_type}, 群组ID={group_id}")
                    except Exception as e:
                        logging.error(f"向 {member} 发送群组消息失败: {e}")
                        with self.server.client_map_lock:
                            self.server.client_map.pop(member, None)
        except Exception as e:
            logging.error(f"通知群组 {group_id} 成员失败: {e}")