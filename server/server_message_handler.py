import logging
import json
import uuid
import os
import bcrypt
from datetime import datetime, timedelta, UTC
from protocol import (send_message, recv_message, recv_header_only, recv_body,
                      recv_body_to_file, recv_and_forward, send_file_message,
                      send_message_header_only, _ForwardError)
from server.server_group_handler import GroupHandler
from server.server_admin_handler import AdminHandler
from validation import validate_password
from config import config

# 撤回时限（分钟）
RECALL_TIMEOUT = timedelta(minutes=config.get("message.recall_timeout_minutes", 2))

# 文件大小上限（字节），默认 5GB（阶段 G4）
DEFAULT_MAX_FILE_SIZE = 5368709120

# 大文件直传阈值（字节），默认 300MB：超过则服务器不存储、双方在线时边收边转发
DEFAULT_LARGE_FILE_THRESHOLD = 314572800

class MessageHandler:
    def __init__(self, server):
        self.server = server
        self.group_handler = GroupHandler(server)
        self.admin_handler = AdminHandler(server)

    def send_initial_data(self, username, ssock):
        """发送初始好友和群组列表"""
        # 发送好友列表
        users = self.server.db.get_friends(username)
        users_list = users
        self.server.guarded_send(ssock, "admin_response", json.dumps(users_list), extra_headers={"response_type": "list_friends"})
        logging.info(f"发送初始好友列表给用户: {username}, 好友数={len(users_list)}")

        # 发送群组列表
        groups = self.server.db.get_user_groups(username)
        self.server.guarded_send(ssock, "list_groups", json.dumps([{"id": g[0], "group_name": g[1]} for g in groups]))
        logging.info(f"发送初始群组列表给用户: {username}, 群组数={len(groups)}")

    def load_offline_data(self, username, ssock):
        """加载用户的离线消息和文件请求"""
        messages = self.server.db.get_offline_messages(username)
        logging.info(f"用户 {username} 的离线消息: {len(messages)} 条")

        for msg in messages:
            sender, msg_type, content, filename, message_id, status, msg_receiver, msg_timestamp, file_path = msg
            logging.info(f"发送离线消息: 发送者={sender}, 类型={msg_type}, 消息ID={message_id}")

            if msg_type == "chat":
                extra_headers = {"from": sender, "history": "true", "message_id": message_id,
                                 "timestamp": str(msg_timestamp), "status": status}
                if sender == username:
                    extra_headers["to"] = msg_receiver
                self.server.guarded_send(ssock, "chat", content.decode('utf-8'),
                             extra_headers=extra_headers)
            elif msg_type == "file":
                extra_headers = {"from": sender, "filename": filename, "history": "true",
                                 "message_id": message_id, "timestamp": str(msg_timestamp),
                                 "status": status}
                if sender == username:
                    extra_headers["to"] = msg_receiver
                if file_path and os.path.exists(file_path):
                    # 大文件：流式分块发送，不读入内存
                    send_file_message(ssock, "file", file_path, extra_headers=extra_headers)
                else:
                    self.server.guarded_send(ssock, "file", content, extra_headers=extra_headers)
            elif msg_type == "group_chat":
                try:
                    message_data = json.loads(content.decode('utf-8'))
                    group_id = message_data.get("group_id")
                    message_text = message_data.get("text")

                    if not group_id:
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
                                message_text = content.decode('utf-8')

                    if group_id and self.server.db.is_group_member(group_id, username):
                        self.server.guarded_send(ssock, "group_chat", message_text,
                                     extra_headers={
                                         "from": sender,
                                         "group_id": str(group_id),
                                         "history": "true",
                                         "message_id": message_id.split('_')[0] if '_' in message_id else message_id,
                                         "timestamp": str(msg_timestamp),
                                         "status": status
                                     })
                        logging.info(f"发送离线群聊消息: 发送者={sender}, 群组ID={group_id}, 消息ID={message_id}")
                    else:
                        logging.warning(
                            f"未找到有效群组ID或用户不再是群成员: 发送者={sender}, 接收者={username}, 消息ID={message_id}")
                except json.JSONDecodeError:
                    logging.error(f"解析群组消息内容失败: 发送者={sender}, 接收者={username}, 消息ID={message_id}")
                except Exception as e:
                    logging.error(
                        f"处理群组消息失败: {str(e)}, 发送者={sender}, 接收者={username}, 消息ID={message_id}")

        # 加载私聊待处理文件请求
        file_requests = self.server.db.get_pending_file_requests(username)
        logging.info(f"用户 {username} 的待处理文件请求: {len(file_requests)} 条")

        for request in file_requests:
            sender, filename, filesize, message_id = request
            logging.info(f"发送待处理文件请求: 发送者={sender}, 文件名={filename}, 消息ID={message_id}")
            self.server.guarded_send(ssock, "file_request", "",
                         extra_headers={"from": sender, "filename": filename, "filesize": filesize,
                                        "message_id": message_id})

        # 加载群组待处理文件请求
        groups = self.server.db.get_user_groups(username)
        logging.info(f"用户 {username} 所属群组: {len(groups)} 个")

        for group_id, group_name in groups:
            group_file_requests = self.server.db.get_pending_group_file_requests(group_id, username)
            logging.info(f"群组 {group_id} ({group_name}) 的待处理文件请求: {len(group_file_requests)} 条")
            for request in group_file_requests:
                sender, filename, filesize, message_id = request
                if sender != username:  # 排除发送者本人
                    logging.info(
                        f"发送群组待处理文件请求: 发送者={sender}, 文件名={filename}, 群组ID={group_id}, 消息ID={message_id}")
                    self.server.guarded_send(ssock, "group_file_request", "",
                                 extra_headers={
                                     "from": sender,
                                     "filename": filename,
                                     "filesize": filesize,
                                     "group_id": str(group_id),
                                     "message_id": message_id
                                 })
                else:
                    logging.info(
                        f"跳过发送群组文件请求给发送者本人: 发送者={sender}, 文件名={filename}, 群组ID={group_id}, 消息ID={message_id}")

        # 加载待处理好友请求
        pending_requests = self.server.db.get_pending_friend_requests(username)
        logging.info(f"用户 {username} 的待处理好友请求: {len(pending_requests)} 条")
        for requester in pending_requests:
            try:
                self.server.guarded_send(ssock, "friend_request", f"来自 {requester} 的好友请求",
                             extra_headers={"from": requester})
                logging.info(f"发送待处理好友请求: 请求者={requester}, 接收者={username}")
            except Exception as e:
                logging.error(f"发送待处理好友请求失败: 请求者={requester}, 接收者={username}, 错误={e}")

    def _handle_file_message(self, username, ssock, header, length):
        """处理 file 消息：大文件（> 阈值）在线直传不落盘；小文件落盘暂存。

        返回 True 表示连接仍可用；返回 False 表示连接已断开，应结束消息循环。
        """
        target = header.get("to")
        if not target:
            self.server.guarded_send(ssock, "error", "错误，未指定接收者")
            logging.error(f"文件消息失败: 未指定接收者")
            return True
        message_id = header.get("message_id", str(uuid.uuid4()))
        filename = header.get("filename", "received_file")
        # 文件大小限制（阶段 G4）：filesize 头缺失或非法时按消息体实际长度判定
        try:
            effective_size = int(header.get("filesize", ""))
        except (TypeError, ValueError):
            effective_size = length
        max_file_size = config.get("file.max_file_size", DEFAULT_MAX_FILE_SIZE)
        if effective_size > max_file_size:
            # 超限：消费消息体避免连接错乱，再拒绝
            if length > 0:
                recv_body(ssock, length)
            self.server.guarded_send(ssock, "error", f"文件过大，超出大小限制（最大 {max_file_size} 字节）")
            logging.warning(f"文件发送失败: {username} -> {target}, "
                            f"文件大小 {effective_size} 超过限制 {max_file_size}")
            return True

        # === 大文件直传（> 阈值）：服务器不存储，双方在线时边收边转发 ===
        large_threshold = config.get("file.large_file_threshold", DEFAULT_LARGE_FILE_THRESHOLD)
        if effective_size > large_threshold:
            is_group = target.startswith("群组 ") or target.startswith("group_")
            if is_group:
                if length > 0:
                    recv_body(ssock, length)
                self.server.guarded_send(ssock, "error", "群组暂不支持大文件直传，请发送小于阈值的文件")
                logging.warning(f"大文件直传失败: {username} -> 群组 {target}, 不支持群组大文件")
                return True
            if not self.server.db.user_exists(target):
                if length > 0:
                    recv_body(ssock, length)
                self.server.guarded_send(ssock, "error", f"用户 {target} 不存在")
                logging.warning(f"大文件直传失败: {username} -> {target}, 用户不存在")
                return True
            if not self.server.db.is_friend(username, target):
                if length > 0:
                    recv_body(ssock, length)
                self.server.guarded_send(ssock, "error", f"错误：{target} 不是您的好友")
                logging.warning(f"大文件直传失败: {username} -> {target}, 非好友")
                return True
            # 转发目标：优先接收方的传输通道（transfer socket，聊天主连接
            # 不被占用）；旧客户端无传输通道时回退到主连接（需抑制写入）。
            with self.server.client_map_lock:
                transfer_recipient = self.server.transfer_sockets.get(target)
                main_recipient = self.server.client_map.get(target)
            recipient_socket = transfer_recipient or main_recipient
            if not recipient_socket:
                if length > 0:
                    recv_body(ssock, length)
                self.server.guarded_send(ssock, "error", f"用户 {target} 离线，无法传输大文件")
                logging.warning(f"大文件直传失败: {username} -> {target}, 目标离线")
                return True
            use_main_fallback = transfer_recipient is None
            consumed = 0
            forward_failed = False
            try:
                if use_main_fallback:
                    # 主连接回退：标记接收方为"转发中"，期间抑制一切写入
                    # （pong/kick/推送会污染文件字节流）
                    with self.server.client_map_lock:
                        self.server.active_forward_socks.add(recipient_socket)
                # 先向接收方发送 file 消息头（length = 实际消息体长度），再边收边转发 body
                send_message_header_only(
                    recipient_socket, "file", length,
                    extra_headers={"from": username, "filename": filename,
                                   "filesize": effective_size, "message_id": message_id})
                consumed = recv_and_forward(ssock, recipient_socket, length)
            except _ForwardError as fe:
                # 目标转发失败（接收方掉线）：只消费尚未读取的剩余 body
                # （length - fe.consumed，含 sendall 失败前 recvall 的预读量），
                # 避免把发送方后续消息（如传输中排队的 chat）一并吞掉导致流错位
                consumed = fe.consumed
                forward_failed = True
                logging.error(f"大文件直传中断: {username} -> {target}, "
                              f"消息ID={message_id}, 错误={fe}")
            except Exception as e:
                consumed = 0
                forward_failed = True
                logging.error(f"大文件直传中断: {username} -> {target}, "
                              f"消息ID={message_id}, 错误={e}")
            finally:
                if use_main_fallback:
                    # 转发结束：解除抑制；若接收方仍是最新会话，补推转发期间积压的离线消息
                    with self.server.client_map_lock:
                        self.server.active_forward_socks.discard(recipient_socket)
                        still_current = self.server.client_map.get(target) is recipient_socket
                    if still_current:
                        try:
                            self.load_offline_data(target, recipient_socket)
                        except Exception as e:
                            logging.warning(f"转发后补推离线消息失败: {target}, {e}")
            if forward_failed:
                try:
                    remaining = length - consumed
                    if remaining > 0:
                        recv_body(ssock, remaining)
                except Exception:
                    pass
                try:
                    self.server.guarded_send(ssock, "error", "文件传输中断")
                except Exception:
                    pass
                return True
            if consumed < length:
                # 源连接提前关闭（EOF）
                try:
                    self.server.guarded_send(ssock, "error", "文件传输中断")
                except Exception:
                    pass
                logging.error(f"大文件直传失败: {username} -> {target}, 消息ID={message_id}, "
                              f"转发 {consumed}/{length}")
                return False
            logging.info(f"大文件直传完成: {username} -> {target}, 文件名={filename}, "
                         f"大小={effective_size}, 消息ID={message_id}")
            return True

        # === 小文件（<= 阈值）：落盘暂存，接收方接受后转发 ===
        file_path = None
        file_data = b''
        if length > 0:
            file_path = os.path.join(self.server.db._pending_dir(), os.path.basename(message_id))
            written = recv_body_to_file(ssock, file_path, length)
            if written < length:
                self.server.guarded_send(ssock, "error", "文件接收不完整")
                logging.error(f"文件接收不完整: 消息ID={message_id}, {written}/{length}")
                return False
        # 支持两种群组前缀：中文「群组 」和 Flutter 客户端「group_」
        is_group = target.startswith("群组 ") or target.startswith("group_")
        if is_group:
            try:
                if target.startswith("group_"):
                    group_id = int(target.split("_")[1])
                else:
                    group_id = int(target.split(" ")[1])
                with self.server.db._get_connection() as conn:
                    cursor = conn.cursor()
                    cursor.execute('SELECT 1 FROM groups WHERE id = ?', (group_id,))
                    if not cursor.fetchone():
                        self.server.guarded_send(ssock, "error", f"群组 {group_id} 不存在")
                        logging.error(f"文件发送失败: 群组 {group_id} 不存在")
                        return True
                if not self.server.db.is_group_member(group_id, username):
                    self.server.guarded_send(ssock, "error", "您不在此群组中")
                    logging.warning(f"文件发送失败: 用户 {username} 不在群组 {group_id} 中")
                    return True
                self.server.db.save_group_file_request(group_id, username, filename, effective_size, file_data, message_id, file_path=file_path)
                self.group_handler.notify_group_members(
                    group_id, "group_file_request", "",
                    from_user=username,
                    extra_headers={"filename": filename, "filesize": effective_size, "message_id": message_id}
                )
                logging.info(f"群组文件请求已保存: 群组ID={group_id}, 文件名={filename}, 消息ID={message_id}")
            except ValueError:
                self.server.guarded_send(ssock, "error", "无效的群组ID")
                logging.error(f"文件发送失败: 无效的群组ID {target}")
            return True
        if not self.server.db.is_friend(username, target):
            if file_path:
                self.server.db._delete_disk_file(file_path)
            self.server.guarded_send(ssock, "error", f"错误：{target} 不是您的好友")
            logging.warning(f"文件发送失败: {username} -> {target}, 非好友")
            return True
        self.server.db.save_file_request(username, target, filename, effective_size, file_data, message_id, file_path=file_path)
        with self.server.client_map_lock:
            recipient_socket = self.server.client_map.get(target)
        if recipient_socket:
            try:
                self.server.guarded_send(recipient_socket, "file_request", "",
                             extra_headers={"from": username, "filename": filename, "filesize": effective_size, "message_id": message_id})
                logging.info(f"文件请求已发送: {username} -> {target}, 文件名={filename}, 消息ID={message_id}")
            except Exception as e:
                logging.error(f"发送文件请求失败: {username} -> {target}, 文件名={filename}, 消息ID={message_id}, 错误={e}")
                with self.server.client_map_lock:
                    self.server.client_map.pop(target, None)
        else:
            self.server.guarded_send(ssock, "chat", f"用户 {target} 离线，文件请求已保存")
            logging.info(f"用户 {target} 离线，文件请求已保存: 文件名={filename}, 消息ID={message_id}")
        return True

    def process_messages(self, username, ssock):
        """处理客户端发送的消息"""
        while True:
            # 只读消息头，file 类型按大小分流（大文件在线直传不落盘 / 小文件落盘暂存）
            header = recv_header_only(ssock)
            if not header:
                logging.info(f"客户端 {username} 断开连接")
                break
            msg_type = header.get("type")
            length = header.get('length', 0)
            logging.info(f"收到消息: 用户={username}, 类型={msg_type}, 头信息={header}")

            if msg_type == "file":
                # file 消息体按大小分流处理（大文件直传不落盘 / 小文件落盘暂存）
                alive = self._handle_file_message(username, ssock, header, length)
                if not alive:
                    break
                continue

            # 其余消息：读取消息体到内存后分发
            data = recv_body(ssock, length)
            if data is None:
                logging.info(f"客户端 {username} 断开连接（消息体读取中断）")
                break

            if msg_type == "ping":
                try:
                    self.server.guarded_send(ssock, "pong", b"")
                except Exception as e:
                    logging.warning(f"回复 pong 失败: {username}, {e}")

            elif msg_type == "chat":
                target = header.get("to")
                message_id = header.get("message_id", str(uuid.uuid4()))
                if not self.server.db.is_friend(username, target):
                    self.server.guarded_send(ssock, "error", f"错误：{target} 不是您的好友")
                    logging.warning(f"消息发送失败: {username} -> {target}, 非好友")
                    continue
                message = data.decode("utf-8")
                logging.info(f"来自 {username} 发往 {target} 的聊天消息: {message}, 消息ID={message_id}")
                self.server.db.save_offline_message(username, target, "chat", message.encode('utf-8'), message_id=message_id)
                # 同步写入永久消息历史
                self.server.db.save_message_history(username, target, "chat", message.encode('utf-8'), message_id=message_id)
                with self.server.client_map_lock:
                    recipient_socket = self.server.client_map.get(target)
                if recipient_socket:
                    try:
                        self.server.guarded_send(recipient_socket, "chat", message,
                                     extra_headers={"from": username, "message_id": message_id})
                        logging.info(f"消息已转发: {username} -> {target}, 消息ID={message_id}")
                    except Exception as e:
                        logging.error(f"发送消息失败: {username} -> {target}, 消息ID={message_id}, 错误={e}")
                        with self.server.client_map_lock:
                            self.server.client_map.pop(target, None)
                else:
                    self.server.guarded_send(ssock, "chat", f"用户 {target} 离线，消息已保存")
                    logging.info(f"用户 {target} 离线，消息已保存: 消息ID={message_id}")
                if message.lower() == "quit":
                    break

            elif msg_type == "file_transfer_check":
                # 大文件直传探测（阶段 G4b）：发送方先确认目标在线再传输
                target = header.get("to")
                message_id = header.get("message_id")
                try:
                    check_size = int(header.get("filesize", "") or "0")
                except (TypeError, ValueError):
                    check_size = 0
                large_threshold = config.get("file.large_file_threshold", DEFAULT_LARGE_FILE_THRESHOLD)
                if check_size <= large_threshold:
                    self.server.guarded_send(ssock, "error", "文件未超过大文件阈值，请直接发送")
                    logging.warning(f"大文件探测失败: {username} 检查非大文件 {check_size}")
                    continue
                if target.startswith("群组 ") or target.startswith("group_"):
                    self.server.guarded_send(ssock, "error", "群组暂不支持大文件直传")
                    logging.warning(f"大文件探测失败: {username} -> 群组 {target}")
                    continue
                if not self.server.db.user_exists(target):
                    self.server.guarded_send(ssock, "error", f"用户 {target} 不存在")
                    logging.warning(f"大文件探测失败: {username} -> {target}, 用户不存在")
                    continue
                if not self.server.db.is_friend(username, target):
                    self.server.guarded_send(ssock, "error", f"错误：{target} 不是您的好友")
                    logging.warning(f"大文件探测失败: {username} -> {target}, 非好友")
                    continue
                with self.server.client_map_lock:
                    transfer_recipient = self.server.transfer_sockets.get(target)
                    main_recipient = self.server.client_map.get(target)
                if not transfer_recipient and not main_recipient:
                    self.server.guarded_send(ssock, "error", f"用户 {target} 离线，无法传输大文件")
                    logging.warning(f"大文件探测失败: {username} -> {target}, 目标离线")
                    continue
                self.server.guarded_send(ssock, "file_check_response", "",
                             extra_headers={"ok": "1", "to": target, "message_id": message_id or ""})
                logging.info(f"大文件探测通过: {username} -> {target}, 大小={check_size}")

            elif msg_type == "file_response":
                message_id = header.get("message_id")
                response = header.get("response")
                target = header.get("to")
                file_request = self.server.db.get_file_request(message_id)
                if not file_request:
                    self.server.guarded_send(ssock, "error", f"文件请求 {message_id} 不存在")
                    logging.warning(f"文件响应失败: 消息ID={message_id} 不存在")
                    continue
                sender, receiver, filename, filesize, file_data, file_path = file_request
                if receiver != username:
                    self.server.guarded_send(ssock, "error", "无权限响应此文件请求")
                    logging.warning(f"文件响应失败: 用户 {username} 无权限响应消息ID={message_id}")
                    continue
                if response == "accept":
                    # 大文件：把待处理文件转入历史区（原子 rename），DB 存路径
                    history_path = (self.server.db.promote_file_to_history(file_path, message_id)
                                    if file_path else None)
                    if history_path:
                        file_data = b''
                    self.server.db.save_offline_message(sender, receiver, "file", file_data, filename=filename, message_id=message_id, file_path=history_path)
                    # 同步写入永久消息历史
                    self.server.db.save_message_history(sender, receiver, "file", file_data, filename=filename, message_id=message_id, file_path=history_path)
                    if self.server.client_map.get(receiver):
                        try:
                            if history_path:
                                send_file_message(self.server.client_map[receiver], "file", history_path,
                                                  extra_headers={"from": sender, "filename": filename, "filesize": filesize, "message_id": message_id})
                            else:
                                self.server.guarded_send(self.server.client_map[receiver], "file", file_data,
                                             extra_headers={"from": sender, "filename": filename, "filesize": filesize, "message_id": message_id})
                            logging.info(f"文件已传输: {sender} -> {receiver}, 文件名={filename}, 消息ID={message_id}")
                        except Exception as e:
                            logging.error(f"传输文件失败: {sender} -> {receiver}, 文件名={filename}, 消息ID={message_id}, 错误={e}")
                            with self.server.client_map_lock:
                                self.server.client_map.pop(receiver, None)
                    self.server.db.delete_file_request(message_id)
                    logging.info(f"文件请求已删除: 消息ID={message_id}")
                else:
                    self.server.db.delete_file_request(message_id)
                    logging.info(f"文件请求已删除: 消息ID={message_id}")

            elif msg_type == "friend_request":
                target = header.get("to")
                if not self.server.db.user_exists(target):
                    self.server.guarded_send(ssock, "error", f"用户 {target} 不存在")
                    logging.warning(f"好友请求失败: 目标用户 {target} 不存在")
                    continue
                if self.server.db.is_friend(username, target):
                    self.server.guarded_send(ssock, "error", f"用户 {target} 已是您的好友")
                    logging.warning(f"好友请求失败: {username} 和 {target} 已为好友")
                    continue
                if self.server.db.add_friend_request(username, target):
                    with self.server.client_map_lock:
                        recipient_socket = self.server.client_map.get(target)
                    if recipient_socket:
                        try:
                            self.server.guarded_send(recipient_socket, "friend_request", f"来自 {username} 的好友请求",
                                         extra_headers={"from": username})
                            logging.info(f"好友请求已发送: {username} -> {target}")
                        except Exception as e:
                            logging.error(f"发送好友请求通知失败: {username} -> {target}, 错误={e}")
                            with self.server.client_map_lock:
                                self.server.client_map.pop(target, None)
                    self.server.guarded_send(ssock, "chat", f"好友请求已发送给 {target}")
                    logging.info(f"好友请求发送：{username} -> {target}")
                else:
                    self.server.guarded_send(ssock, "error", "好友请求发送失败，可能已存在")
                    logging.error(f"好友请求发送失败：{username} -> {target}")

            elif msg_type == "list_friend_requests":
                pending_requests = self.server.db.get_pending_friend_requests(username)
                self.server.guarded_send(ssock, "list_friend_requests", json.dumps(pending_requests))
                logging.info(f"发送好友请求列表: 用户={username}, 请求数={len(pending_requests)}")

            elif msg_type == "list_friends":
                users = self.server.db.get_friends(username)
                users_list = users
                self.server.guarded_send(ssock, "admin_response", json.dumps(users_list), extra_headers={"response_type": "list_friends"})
                logging.info(f"用户 {username} 请求好友列表")

            elif msg_type == "fetch_history":
                # 分页拉取历史消息（阶段 E）
                # header: to（私聊对方）/ group_id / before_message_id（游标）/ limit
                with_user = header.get("to")
                group_id = header.get("group_id")
                before_message_id = header.get("before_message_id")
                limit = header.get("limit", "50")
                try:
                    limit_int = int(limit)
                except (ValueError, TypeError):
                    limit_int = 50
                # 通过 before_message_id 查 timestamp 作为游标（避免客户端时区问题）
                before = None
                if before_message_id:
                    before = self.server.db.get_message_history_timestamp(before_message_id)
                if group_id:
                    gid = int(group_id)
                    rows = self.server.db.get_message_history(
                        username, group_id=gid, before=before, limit=limit_int)
                elif with_user:
                    rows = self.server.db.get_message_history(
                        username, with_user=with_user, before=before, limit=limit_int)
                else:
                    rows = self.server.db.get_message_history(
                        username, before=before, limit=limit_int)
                # 回发 JSON 数组：每条含 sender/type/content/message_id/filename/timestamp/group_id/status
                batch = []
                for r in rows:
                    sender, receiver, mtype, content, mid, fname, ts, gid, mstatus = r
                    try:
                        text = content.decode('utf-8') if isinstance(content, bytes) else str(content)
                    except Exception:
                        text = ""
                    batch.append({
                        "sender": sender, "type": mtype, "content": text,
                        "message_id": mid, "filename": fname, "timestamp": ts,
                        "group_id": gid, "status": mstatus or "sent",
                    })
                self.server.guarded_send(ssock, "history_response", json.dumps(batch),
                             extra_headers={"to": with_user or "", "group_id": group_id or ""})
                logging.info(f"历史消息拉取: 用户={username}, 会话={with_user or group_id}, 返回={len(batch)}条")

            elif msg_type == "accept_friend":
                requester = header.get("from")
                if not self.server.db.has_pending_request(requester, username):
                    self.server.guarded_send(ssock, "error", f"没有来自 {requester} 的好友请求")
                    logging.warning(f"接受好友请求失败: 没有来自 {requester} 的请求")
                    continue
                self.server.db.accept_friend_request(requester, username)
                self.server.guarded_send(ssock, "chat", f"已接受 {requester} 的好友请求")
                with self.server.client_map_lock:
                    requester_socket = self.server.client_map.get(requester)
                if requester_socket:
                    try:
                        self.server.guarded_send(requester_socket, "chat", f"{username} 已接受您的好友请求")
                        logging.info(f"通知请求者: {username} 接受好友请求")
                    except Exception as e:
                        logging.error(f"通知请求者失败: {username} 接受好友请求, 错误={e}")
                        with self.server.client_map_lock:
                            self.server.client_map.pop(requester, None)
                else:
                    # 请求方离线：保存离线通知，上线后可见
                    self.server.db.save_offline_message(
                        username, requester, "chat",
                        f"{username} 已接受您的好友请求".encode('utf-8'),
                        message_id=str(uuid.uuid4()))
                    accept_msg_id = str(uuid.uuid4())
                    self.server.db.save_message_history(
                        username, requester, "chat",
                        f"{username} 已接受您的好友请求".encode('utf-8'),
                        message_id=accept_msg_id)
                    logging.info(f"请求方离线，保存接受通知: {requester} <- {username}")
                logging.info(f"好友请求接受：{requester} <-> {username}")

            elif msg_type == "reject_friend":
                requester = header.get("from")
                # 直接删除好友请求记录（不论当前 status），避免残留记录阻止重新请求
                self.server.db.reject_friend_request(requester, username)
                self.server.guarded_send(ssock, "chat", f"已拒绝 {requester} 的好友请求")
                logging.info(f"好友请求拒绝：{requester} -> {username}")


            elif msg_type == "recall":

                message_id = header.get("message_id")

                message_info = self.server.db.get_message_info(message_id)

                file_request = self.server.db.get_file_request(message_id)

                group_file_request = self.server.db.get_group_file_request(message_id)

                # 检查是否存在消息、文件请求或群组文件请求

                if not message_info and not file_request and not group_file_request:
                    # 尝试查找群组消息的变体ID

                    with self.server.db._get_connection() as conn:
                        cursor = conn.cursor()

                        cursor.execute('''

                            SELECT sender, receiver, message_type, content, filename, status, timestamp

                            FROM offline_messages

                            WHERE message_id LIKE ? OR message_id = ?

                        ''', (f"{message_id}_%", message_id))

                        message_info = cursor.fetchone()

                if not message_info and not file_request and not group_file_request:
                    # 目标不存在：可能已被接受或已撤回，静默成功（幂等）
                    logging.info(f"撤回目标不存在（可能已接受或已撤回）: 消息ID={message_id}")
                    continue

                # 处理群组消息撤回

                if message_info and message_info[2] == "group_chat":

                    sender, receiver, msg_type, content, filename, status, timestamp = message_info

                    if sender != username:
                        self.server.guarded_send(ssock, "error", "只能撤回自己的消息")

                        logging.warning(f"撤回消息失败: 用户 {username} 尝试撤回非自己的消息 {message_id}")

                        continue

                    try:

                        message_time = datetime.strptime(timestamp, '%Y-%m-%d %H:%M:%S').replace(tzinfo=UTC)

                        current_time = datetime.now(UTC)

                        time_diff = current_time - message_time

                        logging.info(

                            f"撤回消息时间检查: 消息ID={message_id}, 时间戳={timestamp}, 解析时间={message_time}, 当前时间={current_time}, 时间差={time_diff.total_seconds()}秒")

                        if time_diff > RECALL_TIMEOUT:
                            self.server.guarded_send(ssock, "error",
                                         f"消息超过{RECALL_TIMEOUT.total_seconds() // 60:.0f}分钟，无法撤回 (时间差: {time_diff.total_seconds()}秒)")

                            logging.warning(f"撤回消息失败: 消息 {message_id} 超过2分钟")

                            continue

                    except ValueError as e:

                        self.server.guarded_send(ssock, "error", f"消息时间格式错误: {e}")

                        logging.error(f"撤回消息失败: 消息 {message_id} 时间格式错误: {e}")

                        continue

                    if status == 'recalled':
                        self.server.guarded_send(ssock, "error", "消息已被撤回")

                        logging.warning(f"撤回消息失败: 消息 {message_id} 已被撤回")

                        continue

                    try:

                        # 解析群组ID

                        message_data = json.loads(content.decode('utf-8'))

                        group_id = message_data.get("group_id")

                        if not group_id:
                            self.server.guarded_send(ssock, "error", "无法确定消息的群组")

                            logging.warning(f"撤回群组消息失败: 无法确定群组ID, 消息ID={message_id}")

                            continue

                        # 确认发送者在群组内

                        if not self.server.db.is_group_member(group_id, sender):
                            self.server.guarded_send(ssock, "error", f"您不是群组 {group_id} 的成员")

                            logging.warning(f"撤回消息失败: 用户 {username} 不在群组 {group_id} 中")

                            continue

                        # 更新所有相关消息的状态

                        with self.server.db._get_connection() as conn:

                            cursor = conn.cursor()

                            cursor.execute('''

                                UPDATE offline_messages

                                SET status = 'recalled'

                                WHERE message_id LIKE ? OR message_id = ?

                            ''', (f"{message_id}_%", message_id))

                            conn.commit()

                            if cursor.rowcount > 0:

                                logging.info(
                                    f"群组消息状态更新: 消息ID={message_id}, 群组ID={group_id}, 更新记录数={cursor.rowcount}")

                            else:

                                logging.warning(f"群组消息状态更新失败: 消息ID={message_id}, 群组ID={group_id}")

                        # 同步更新 message_history 的状态
                        self.server.db.update_message_history_status(message_id, 'recalled')

                        # 通知群成员

                        self.group_handler.notify_group_members(

                            group_id, "recall", "",

                            from_user=username,

                            extra_headers={"message_id": message_id, "group_id": str(group_id)}

                        )

                        # 为离线群成员保存撤回占位符
                        members = self.server.db.get_group_members(group_id)
                        for member in members:
                            if member == username:
                                continue
                            with self.server.client_map_lock:
                                if member not in self.server.client_map:
                                    recall_content = json.dumps({"group_id": group_id, "text": f"{username} 撤回了一条消息"})
                                    self.server.db.save_offline_message(
                                        username, member, "group_chat", recall_content.encode('utf-8'),
                                        message_id=str(uuid.uuid4()))
                                    logging.info(f"离线群成员 {member} 的撤回占位符已保存")

                        logging.info(f"群组消息撤回成功: 用户={username}, 群组ID={group_id}, 消息ID={message_id}")

                        try:
                            self.server.guarded_send(ssock, "recall", "",
                                         extra_headers={"message_id": message_id})
                        except Exception as e:
                            logging.warning(f"发送撤回确认失败: {username}, {e}")


                    except json.JSONDecodeError:

                        self.server.guarded_send(ssock, "error", "消息格式错误，无法撤回")

                        logging.error(f"撤回群组消息失败: 解析消息内容失败, 消息ID={message_id}")

                        continue


                # 处理私聊消息撤回（保持原逻辑）

                elif message_info:

                    sender, receiver, msg_type, content, filename, status, timestamp = message_info

                    if sender != username:
                        self.server.guarded_send(ssock, "error", "只能撤回自己的消息")

                        logging.warning(f"撤回消息失败: 用户 {username} 尝试撤回非自己的消息 {message_id}")

                        continue

                    try:

                        message_time = datetime.strptime(timestamp, '%Y-%m-%d %H:%M:%S').replace(tzinfo=UTC)

                        current_time = datetime.now(UTC)

                        time_diff = current_time - message_time

                        logging.info(

                            f"撤回消息时间检查: 消息ID={message_id}, 时间戳={timestamp}, 解析时间={message_time}, 当前时间={current_time}, 时间差={time_diff.total_seconds()}秒")

                        if time_diff > RECALL_TIMEOUT:
                            self.server.guarded_send(ssock, "error", f"消息超过{RECALL_TIMEOUT.total_seconds() // 60:.0f}分钟，无法撤回")

                            logging.warning(f"撤回消息失败: 消息 {message_id} 超过2分钟")

                            continue

                    except ValueError as e:

                        self.server.guarded_send(ssock, "error", f"消息时间格式错误: {e}")

                        logging.error(f"撤回消息失败: 消息 {message_id} 时间格式错误: {e}")

                        continue

                    if status == 'recalled':
                        self.server.guarded_send(ssock, "error", "消息已被撤回")

                        logging.warning(f"撤回消息失败: 消息 {message_id} 已被撤回")

                        continue

                    if self.server.db.update_message_status(message_id, 'recalled'):

                        # 同步更新 message_history 的状态
                        self.server.db.update_message_history_status(message_id, 'recalled')

                        with self.server.client_map_lock:

                            recipient_socket = self.server.client_map.get(receiver)

                        if recipient_socket:

                            try:

                                self.server.guarded_send(recipient_socket, "recall", "",

                                             extra_headers={"from": username, "message_id": message_id})

                                logging.info(f"通知接收方消息撤回: {message_id}, 接收方={receiver}")

                            except Exception as e:

                                logging.error(f"通知接收方消息撤回失败: {message_id}, 错误={e}")

                                with self.server.client_map_lock:

                                    self.server.client_map.pop(receiver, None)

                        else:
                            # 接收方离线：保存撤回占位符通知，上线后可见
                            self.server.db.save_offline_message(
                                username, receiver, "chat",
                                f"{username} 撤回了一条消息".encode('utf-8'),
                                message_id=str(uuid.uuid4()))
                            logging.info(f"接收方离线，保存撤回占位符: {receiver} <- {username}")

                        logging.info(f"私聊消息撤回成功: {username} 撤回了 {message_id}")

                        try:
                            self.server.guarded_send(ssock, "recall", "",
                                         extra_headers={"message_id": message_id})
                        except Exception as e:
                            logging.warning(f"发送撤回确认失败: {username}, {e}")

                    else:

                        self.server.guarded_send(ssock, "error", f"撤回消息 {message_id} 失败")

                        logging.error(f"撤回私聊消息失败: {message_id}")


                # 处理私聊文件请求（保持原逻辑）

                elif file_request:

                    sender, receiver, filename, filesize, content, file_path = file_request

                    if sender != username:
                        self.server.guarded_send(ssock, "error", "只能撤回自己的文件请求")

                        logging.warning(f"撤回文件请求失败: 用户 {username} 尝试撤回非自己的文件请求 {message_id}")

                        continue

                    with self.server.db._get_connection() as conn:

                        cursor = conn.cursor()

                        cursor.execute('SELECT timestamp FROM file_requests WHERE message_id = ?', (message_id,))

                        timestamp = cursor.fetchone()[0]

                    try:

                        request_time = datetime.strptime(timestamp, '%Y-%m-%d %H:%M:%S').replace(tzinfo=UTC)

                        current_time = datetime.now(UTC)

                        time_diff = current_time - request_time

                        if time_diff > RECALL_TIMEOUT:
                            self.server.guarded_send(ssock, "error", f"文件请求超过{RECALL_TIMEOUT.total_seconds() // 60:.0f}分钟，无法撤回")

                            logging.warning(f"撤回文件请求失败: {message_id} 超过2分钟")

                            continue

                    except ValueError as e:

                        self.server.guarded_send(ssock, "error", f"文件请求时间格式错误: {e}")

                        logging.error(f"撤回文件请求失败: {message_id} 时间格式错误: {e}")

                        continue

                    if self.server.db.delete_file_request(message_id):

                        with self.server.client_map_lock:

                            recipient_socket = self.server.client_map.get(receiver)

                        if recipient_socket:

                            try:

                                self.server.guarded_send(recipient_socket, "chat",

                                             f"用户 {username} 撤回了文件请求: {filename} ({message_id})")

                                logging.info(f"通知接收方文件请求撤回: {message_id}, 接收方={receiver}")

                            except Exception as e:

                                logging.error(f"通知接收方文件请求撤回失败: {message_id}, 错误={e}")

                                with self.server.client_map_lock:

                                    self.server.client_map.pop(receiver, None)

                        logging.info(f"私聊文件请求撤回成功: {username} 撤回了 {message_id}")

                        try:
                            self.server.guarded_send(ssock, "recall", "",
                                         extra_headers={"message_id": message_id})
                        except Exception as e:
                            logging.warning(f"发送撤回确认失败: {username}, {e}")

                    else:

                        self.server.guarded_send(ssock, "error", f"撤回文件请求 {message_id} 失败")

                        logging.error(f"撤回私聊文件请求失败: {message_id}")


                # 处理群组文件请求（保持原逻辑）

                elif group_file_request:

                    group_id, sender, filename, filesize, content, file_path = group_file_request

                    if sender != username:
                        self.server.guarded_send(ssock, "error", "只能撤回自己的文件请求")

                        logging.warning(f"撤回群组文件请求失败: 用户 {username} 尝试撤回非自己的文件请求 {message_id}")

                        continue

                    with self.server.db._get_connection() as conn:

                        cursor = conn.cursor()

                        cursor.execute('SELECT timestamp FROM group_file_requests WHERE message_id = ?', (message_id,))

                        timestamp = cursor.fetchone()[0]

                    try:

                        request_time = datetime.strptime(timestamp, '%Y-%m-%d %H:%M:%S').replace(tzinfo=UTC)

                        current_time = datetime.now(UTC)

                        time_diff = current_time - request_time

                        if time_diff > RECALL_TIMEOUT:
                            self.server.guarded_send(ssock, "error", f"群组文件请求超过{RECALL_TIMEOUT.total_seconds() // 60:.0f}分钟，无法撤回")

                            logging.warning(f"撤回群组文件请求失败: {message_id} 超过2分钟")

                            continue

                    except ValueError as e:

                        self.server.guarded_send(ssock, "error", f"群组文件请求时间格式错误: {e}")

                        logging.error(f"撤回群组文件请求失败: {message_id} 时间格式错误: {e}")

                        continue

                    if self.server.db.delete_group_file_request(message_id):

                        self.group_handler.notify_group_members(

                            group_id, "chat", f"用户 {username} 撤回了群组文件请求: {filename} ({message_id})",

                            from_user="系统"

                        )

                        logging.info(f"群组文件请求撤回成功: {username} 撤回了 {message_id} 在群组 {group_id}")

                        try:
                            self.server.guarded_send(ssock, "recall", "",
                                         extra_headers={"message_id": message_id})
                        except Exception as e:
                            logging.warning(f"发送撤回确认失败: {username}, {e}")

                    else:

                        self.server.guarded_send(ssock, "error", f"撤回群组文件请求 {message_id} 失败")

                        logging.error(f"撤回群组文件请求失败: {message_id}")

            elif msg_type == "change_password":
                old_password = header.get("old_password") or ""
                new_password = header.get("new_password") or ""
                valid, error = validate_password(new_password)
                if not valid:
                    self.server.guarded_send(ssock, "error", error)
                    logging.warning(f"修改密码失败: 用户 {username} 新密码格式不合法: {error}")
                    continue
                user_data = self.server.db.get_user(username)
                if not user_data:
                    self.server.guarded_send(ssock, "error", "用户不存在")
                    logging.warning(f"修改密码失败: 用户 {username} 不存在")
                    continue
                stored_hash, _ = user_data
                if not bcrypt.checkpw(old_password.encode('utf-8'), stored_hash):
                    self.server.guarded_send(ssock, "error", "原密码错误")
                    logging.warning(f"修改密码失败: 用户 {username} 原密码错误")
                    continue
                new_hash = bcrypt.hashpw(new_password.encode('utf-8'), bcrypt.gensalt())
                if self.server.db.update_password(username, stored_hash, new_hash):
                    self.server.guarded_send(ssock, "chat", "密码修改成功")
                    logging.info(f"修改密码成功: 用户 {username}")
                else:
                    self.server.guarded_send(ssock, "error", "修改密码失败")
                    logging.error(f"修改密码失败: 用户 {username}")

            elif msg_type == "delete_friend":
                target = header.get("to")
                if not self.server.db.user_exists(target):
                    self.server.guarded_send(ssock, "error", f"用户 {target} 不存在")
                    logging.warning(f"删除好友失败: 目标用户 {target} 不存在")
                    continue
                if self.server.db.remove_friend(username, target):
                    self.server.guarded_send(ssock, "chat", f"已删除好友 {target}")
                    with self.server.client_map_lock:
                        target_socket = self.server.client_map.get(target)
                    if target_socket:
                        try:
                            self.server.guarded_send(target_socket, "delete_friend", "",
                                         extra_headers={"from": username})
                            logging.info(f"通知被删方: {target} 被 {username} 删除好友")
                        except Exception as e:
                            logging.error(f"通知被删方失败: {target}, 错误={e}")
                            with self.server.client_map_lock:
                                self.server.client_map.pop(target, None)
                    else:
                        self.server.db.save_offline_message(
                            username, target, "chat",
                            f"{username} 已删除您为好友".encode("utf-8"),
                            message_id=str(uuid.uuid4()))
                        logging.info(f"被删方离线，保存离线删除通知: {target} <- {username}")
                    logging.info(f"好友已删除: {username} <-> {target}")
                else:
                    self.server.guarded_send(ssock, "error", f"删除好友 {target} 失败")
                    logging.error(f"删除好友失败: {username} <-> {target}")

            elif msg_type == "admin_command":
                self.admin_handler.handle_admin_command(username, ssock, header, data)

            elif msg_type in ("create_group", "join_group", "group_chat", "list_groups",
                             "group_file_response", "leave_group", "list_group_members"):
                self.group_handler.handle_group_message(username, ssock, msg_type, header, data)