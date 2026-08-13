import json
import logging
from protocol import send_message, send_file_message
import uuid

class GroupHandler:
    def __init__(self, server):
        self.server = server

    def handle_group_message(self, username, ssock, msg_type, header, data):
        if msg_type == "create_group":
            try:
                group_name = data.decode("utf-8").strip()
                if not group_name:
                    self.server.guarded_send(ssock, "error", "群组名称不能为空")
                    logging.error(f"用户 {username} 尝试创建空群组名")
                    return
                group_id = self.server.db.create_group(group_name, username)
                if group_id:
                    self.server.guarded_send(ssock, "chat", f"群组 {group_name} 创建成功，ID: {group_id}")
                    logging.info(f"用户 {username} 创建群组: {group_name}, ID={group_id}")
                    # 通知客户端刷新群组列表
                    self.notify_group_members(group_id, "chat", f"{username} 创建了群组 {group_name}", from_user="系统")
                    with self.server.client_map_lock:
                        if username in self.server.client_map:
                            # 发送全部群组列表，而非仅新创建的群组
                            groups = self.server.db.get_user_groups(username)
                            list_sock = self.server.client_map[username]
                    if list_sock:
                        self.server.guarded_send(list_sock, "list_groups",
                                     json.dumps([{"id": g[0], "group_name": g[1]} for g in groups]))
                else:
                    self.server.guarded_send(ssock, "error", "群组创建失败，可能已存在")
                    logging.error(f"用户 {username} 创建群组失败: {group_name}")
            except Exception as e:
                self.server.guarded_send(ssock, "error", f"创建群组失败: {str(e)}")
                logging.error(f"用户 {username} 创建群组失败: {str(e)}")

        elif msg_type == "join_group":
            try:
                group_id = int(data.decode("utf-8").strip())
                with self.server.db._get_connection() as conn:
                    cursor = conn.cursor()
                    cursor.execute('SELECT 1 FROM groups WHERE id = ?', (group_id,))
                    if not cursor.fetchone():
                        self.server.guarded_send(ssock, "error", f"群组 {group_id} 不存在")
                        logging.error(f"用户 {username} 尝试加入不存在的群组: {group_id}")
                        return
                if not self.server.db.is_group_member(group_id, username):
                    self.server.db.join_group(group_id, username)
                    self.server.guarded_send(ssock, "chat", f"已加入群组 {group_id}")
                    logging.info(f"用户 {username} 加入群组: {group_id}")
                    # 通知客户端刷新群组列表
                    list_sock = None
                    with self.server.client_map_lock:
                        if username in self.server.client_map:
                            groups = self.server.db.get_user_groups(username)
                            list_sock = self.server.client_map[username]
                    if list_sock:
                        self.server.guarded_send(list_sock, "list_groups", json.dumps([{"id": g[0], "group_name": g[1]} for g in groups]))
                else:
                    self.server.guarded_send(ssock, "error", "您已在群组中")
                    logging.warning(f"用户 {username} 尝试重复加入群组: {group_id}")
            except ValueError:
                self.server.guarded_send(ssock, "error", "无效的群组ID")
                logging.error(f"用户 {username} 提供无效的群组ID: {data.decode('utf-8')}")
            except Exception as e:
                self.server.guarded_send(ssock, "error", f"加入群组失败: {str(e)}")
                logging.error(f"用户 {username} 加入群组失败: {str(e)}")

        if msg_type == "leave_group":
            try:
                group_id_str = header.get("group_id", "")
                group_id = int(group_id_str)
                with self.server.db._get_connection() as conn:
                    cursor = conn.cursor()
                    cursor.execute('SELECT group_name FROM groups WHERE id = ?', (group_id,))
                    group_row = cursor.fetchone()
                    if not group_row:
                        self.server.guarded_send(ssock, "error", f"群组 {group_id} 不存在")
                        logging.error(f"用户 {username} 离开群组失败: 群组 {group_id} 不存在")
                        return
                if not self.server.db.is_group_member(group_id, username):
                    self.server.guarded_send(ssock, "error", f"群组 {group_id} 不存在或您不在此群组中")
                    logging.warning(f"用户 {username} 离开群组失败: 不在群组 {group_id} 中")
                    return
                self.server.db.leave_group(group_id, username)
                self.server.guarded_send(ssock, "chat", f"已退出群组 {group_row[0]} (ID:{group_id})")
                self.notify_group_members(group_id, "chat",
                                          f"{username} 已退出群组 {group_id}",
                                          from_user="系统",
                                          extra_headers={"group_id": str(group_id)})
                logging.info(f"用户 {username} 已离开群组 {group_id} ({group_row[0]})")
                remaining = self.server.db.get_group_members(group_id)
                if not remaining:
                    self.server.db.delete_group(group_id)
                    logging.info(f"群组 {group_id} ({group_row[0]}) 已无成员，已删除群组及历史")
            except ValueError:
                self.server.guarded_send(ssock, "error", "无效的群组 ID")
                logging.error(f"用户 {username} 离开群组失败: 无效的 group_id")
            except Exception as e:
                self.server.guarded_send(ssock, "error", f"离开群组失败: {str(e)}")
                logging.error(f"用户 {username} 离开群组失败: {str(e)}")

        if msg_type == "group_chat":
            try:
                group_id = int(header.get("group_id"))
                original_message_id = header.get("message_id", str(uuid.uuid4()))

                # 验证群组存在
                with self.server.db._get_connection() as conn:
                    cursor = conn.cursor()
                    cursor.execute('SELECT 1 FROM groups WHERE id = ?', (group_id,))
                    if not cursor.fetchone():
                        self.server.guarded_send(ssock, "error", f"群组 {group_id} 不存在")
                        logging.error(f"用户 {username} 尝试发送消息到不存在的群组: {group_id}")
                        return

                if not self.server.db.is_group_member(group_id, username):
                    self.server.guarded_send(ssock, "error", "您不在此群组中")
                    logging.warning(f"用户 {username} 尝试发送消息到未加入的群组: {group_id}")
                    return

                # 阶段 I：重发幂等——客户端断线补发/手动重试复用原 message_id，
                # 若此前已写入永久历史，跳过重复保存与广播，避免重复下发
                if self.server.db.message_id_exists(original_message_id, sender=username):
                    logging.info(
                        f"重复群聊消息已跳过（幂等）: 用户={username}, "
                        f"群组ID={group_id}, 消息ID={original_message_id}")
                    return

                message = data.decode("utf-8")
                members = self.server.db.get_group_members(group_id)
                message_with_metadata = json.dumps({"text": message, "group_id": group_id})
                for member in members:
                    if member != username:
                        member_message_id = f"{original_message_id}_{member}"
                        self.server.db.save_offline_message(
                            username, member, "group_chat",
                            message_with_metadata.encode('utf-8'),
                            message_id=member_message_id
                        )
                        logging.info(f"保存群组消息: 消息ID={member_message_id}, 群组ID={group_id}, 接收者={member}")

                # 同步写入永久消息历史（群聊消息只存一条）
                self.server.db.save_message_history(
                    username, "", "group_chat",
                    message.encode('utf-8'),
                    group_id=group_id,
                    message_id=original_message_id
                )

                # 通知群组成员，使用原始消息ID
                self.notify_group_members(
                    group_id, "group_chat", message,
                    from_user=username,
                    extra_headers={"message_id": original_message_id}
                )
                logging.info(f"群组消息: 用户={username}, 群组ID={group_id}, 消息ID={original_message_id}")

            except ValueError:
                self.server.guarded_send(ssock, "error", "无效的群组ID")
                logging.error(f"用户 {username} 提供无效的群组ID: {header.get('group_id')}")
            except Exception as e:
                self.server.guarded_send(ssock, "error", f"发送群组消息失败: {str(e)}")
                logging.error(f"用户 {username} 发送群组消息失败: {str(e)}")

        elif msg_type == "list_groups":
            groups = self.server.db.get_user_groups(username)
            self.server.guarded_send(ssock, "list_groups", json.dumps([{"id": g[0], "group_name": g[1]} for g in groups]))
            logging.info(f"发送群组列表给用户: {username}")

        elif msg_type == "list_group_members":
            group_id_str = header.get("group_id", "")
            try:
                group_id = int(group_id_str)
            except (ValueError, TypeError):
                self.server.guarded_send(ssock, "error", "无效的群组 ID")
                logging.error(f"用户 {username} 查询群成员失败: 无效的 group_id {group_id_str}")
                return
            with self.server.db._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute('SELECT 1 FROM groups WHERE id = ?', (group_id,))
                if not cursor.fetchone():
                    self.server.guarded_send(ssock, "error", f"群组 {group_id} 不存在")
                    logging.error(f"用户 {username} 查询群成员失败: 群组 {group_id} 不存在")
                    return
            if not self.server.db.is_group_member(group_id, username):
                self.server.guarded_send(ssock, "error", f"群组 {group_id} 不存在或您不在此群组中")
                logging.warning(f"用户 {username} 查询群成员失败: 不在群组 {group_id} 中")
                return
            members = self.server.db.get_group_members(group_id)
            self.server.guarded_send(ssock, "admin_response", json.dumps(members),
                         extra_headers={"response_type": "list_group_members",
                                        "group_id": str(group_id)})
            logging.info(f"发送群成员列表: 用户={username}, 群组={group_id}, 成员={members}")

        elif msg_type == "group_file_response":
            message_id = header.get("message_id")
            response = header.get("response")
            group_id = header.get("group_id")
            file_request = self.server.db.get_group_file_request(message_id)
            if not file_request:
                self.server.guarded_send(ssock, "error", f"群组文件请求 {message_id} 不存在")
                logging.warning(f"群组文件响应失败: 消息ID={message_id} 不存在")
                return
            group_id_db, sender, filename, filesize, file_data, file_path = file_request
            if int(group_id) != group_id_db:
                self.server.guarded_send(ssock, "error", "无效的群组ID")
                logging.warning(f"群组文件响应失败: 用户 {username} 提供无效的群组ID {group_id}")
                return
            if not self.server.db.is_group_member(group_id, username):
                self.server.guarded_send(ssock, "error", "您不在此群组中")
                logging.warning(f"群组文件响应失败: 用户 {username} 不在群组 {group_id} 中")
                return
            self.server.db.save_group_file_response(message_id, group_id, username, response)
            if response == "accept":
                # 大文件：把待处理文件转入历史区（原子 rename），DB 存路径
                history_path = (self.server.db.promote_file_to_history(file_path, message_id)
                                if file_path else None)
                if history_path:
                    file_data = b''
                self.server.db.save_offline_message(sender, username, "file", file_data, filename=filename, message_id=message_id, file_path=history_path)
                self.server.db.save_message_history(sender, username, "file", file_data, filename=filename, message_id=message_id, file_path=history_path)
                if self.server.client_map.get(username):
                    try:
                        if history_path:
                            send_file_message(self.server.client_map[username], "file", history_path,
                                              extra_headers={"from": sender, "filename": filename, "filesize": filesize, "message_id": message_id})
                        else:
                            self.server.guarded_send(self.server.client_map[username], "file", file_data,
                                         extra_headers={"from": sender, "filename": filename, "filesize": filesize, "message_id": message_id})
                        logging.info(f"群组文件已传输: {sender} -> {username}, 文件名={filename}, 消息ID={message_id}")
                    except Exception as e:
                        logging.error(f"传输群组文件失败: {sender} -> {username}, 文件名={filename}, 消息ID={message_id}, 错误={e}")
                        with self.server.client_map_lock:
                            self.server.client_map.pop(username, None)
            if self.server.db.all_members_responded(message_id, group_id):
                self.server.db.delete_group_file_request(message_id)
                logging.info(f"群组文件请求已删除: 消息ID={message_id}, 所有成员已响应")
            else:
                logging.info(f"群组文件请求未删除: 消息ID={message_id}, 仍有成员未响应")

    def notify_group_members(self, group_id, msg_type, message, from_user="系统", extra_headers=None):
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
                if member == from_user and msg_type in ("group_file_request", "group_chat"):
                    logging.info(f"跳过向发送者 {from_user} 发送 {msg_type}: 群组ID={group_id}")
                    continue
                with self.server.client_map_lock:
                    member_socket = self.server.client_map.get(member)
                if member_socket:
                    try:
                        self.server.guarded_send(member_socket, msg_type, message,
                                     extra_headers={"from": from_user, "group_id": str(group_id), **extra_headers})
                        logging.info(f"向 {member} 发送群组消息: 类型={msg_type}, 群组ID={group_id}")
                        # 在线成员已实时收到，标记 offline_messages 为 delivered 避免下次登录误计未读
                        msg_id = extra_headers.get("message_id")
                        if msg_id:
                            self.server.db.update_message_status(f"{msg_id}_{member}", 'delivered')
                    except Exception as e:
                        logging.error(f"向 {member} 发送群组消息失败: {e}")
                        with self.server.client_map_lock:
                            self.server.client_map.pop(member, None)
        except Exception as e:
            logging.error(f"通知群组 {group_id} 成员失败: {e}")