import logging
import json
import uuid
import os
import time
import socket
import hashlib
import bcrypt
from datetime import datetime, timedelta, UTC
from protocol import (send_message, recv_message, recv_header_only, recv_body,
                      recv_body_to_file, recv_and_forward, send_file_message,
                      send_message_header_only, recvall, _ForwardError)
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


def recv_body_to_file_append(sock, file_path, length, chunk_size=1024*1024*4):
    """读取消息体追加写入磁盘文件（阶段 M8 断点续传：不覆盖已有部分）。

    返回实际写入字节数；连接提前关闭返回已写入量（< length）。
    """
    written = 0
    with open(file_path, 'ab') as f:
        while written < length:
            packet = recvall(sock, min(chunk_size, length - written))
            if not packet:
                break
            f.write(packet)
            written += len(packet)
    return written


def _sha256_of_file(file_path, chunk_size=1024*1024*4):
    """计算磁盘文件的 SHA-256（阶段 M8：小文件完整性校验）。"""
    digest = hashlib.sha256()
    with open(file_path, 'rb') as f:
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()

class MessageHandler:
    def __init__(self, server):
        self.server = server
        self.group_handler = GroupHandler(server)
        self.admin_handler = AdminHandler(server)

    def _validate_peer_key(self, username, peer_key, ssock):
        """阶段 K（K1-K3）：校验会话 peer_key 归属，并归一化返回。

        peer_key 为好友用户名或 'group_N'。合法返回 (peer_key, None)；
        非法向 ssock 回发 error 并返回 (None, error_text)。
        """
        if not peer_key:
            self.server.guarded_send(ssock, "error", "无效的会话标识")
            return None, "无效的会话标识"
        if peer_key.startswith("group_"):
            gid_str = peer_key[6:]
            if not gid_str.isdigit():
                self.server.guarded_send(ssock, "error", f"无效的会话: {peer_key}")
                return None, f"无效的会话: {peer_key}"
            if not self.server.db.is_group_member(int(gid_str), username):
                self.server.guarded_send(ssock, "error", f"您不在群组 {gid_str} 中")
                return None, f"您不在群组 {gid_str} 中"
            return peer_key, None
        if not self.server.db.is_friend(username, peer_key):
            self.server.guarded_send(ssock, "error", f"错误：{peer_key} 不是您的好友")
            return None, f"错误：{peer_key} 不是您的好友"
        return peer_key, None

    def _broadcast_k_message(self, usernames, msg_type, content, extra_headers,
                             exclude=None, log_context=""):
        """阶段 K：向在线用户集合广播消息（跳过 exclude），异常隔离。

        阶段 L1：每成员推送到其所有在线会话（会话级推送）。
        """
        for member in usernames:
            if member == exclude:
                continue
            delivered = self.server.broadcast_to_user(
                member, msg_type, content, extra_headers=extra_headers)
            if delivered:
                logging.info(f"K5 广播 {msg_type}: -> {member}, {log_context}")

    def _reactions_for_headers(self, message_id):
        """把 reactions 表聚合为 {emoji: [usernames]}（供历史/编辑等使用）。"""
        by_emoji = {}
        for r in self.server.db.get_reactions(message_id):
            by_emoji.setdefault(r["emoji"], []).append(r["username"])
        return by_emoji

    def send_initial_data(self, username, ssock):
        """发送初始好友和群组列表"""
        # 发送好友列表
        users = self.server.db.get_friends(username)
        users_list = users
        self.server.guarded_send(ssock, "admin_response", json.dumps(users_list), extra_headers={"response_type": "list_friends"})
        logging.info(f"发送初始好友列表给用户: {username}, 好友数={len(users_list)}")

        # 发送群组列表（阶段 M1 扩展：携带 created_by/avatar，向后兼容）
        self.server.guarded_send(ssock, "list_groups",
                                 self.server.group_list_json(username))
        logging.info(f"发送初始群组列表给用户: {username}, 群组数={len(self.server.db.get_user_groups(username))}")

        # 阶段 J 修复（拉黑状态不可逆）：好友备注/分组与黑名单随登录初始数据
        # 一并推送。客户端 Dart SecureSocket 存在连续 add+flush 批次静默丢失
        # 的 VM 缺陷（登录后立即连发 list_friends_meta / list_blocked 请求可能
        # 整条丢失），改为服务端主动推送（客户端读侧可靠），登录即恢复状态，
        # 无需任何客户端请求。
        metas = self.server.db.get_friends_meta(username)
        self.server.guarded_send(ssock, "admin_response", json.dumps(metas),
                     extra_headers={"response_type": "list_friends_meta"})
        blocked = self.server.db.get_blocked_users(username)
        self.server.guarded_send(ssock, "admin_response", json.dumps(blocked),
                     extra_headers={"response_type": "list_blocked"})
        logging.info(f"发送初始社交元数据给用户: {username}, 备注/分组={len(metas)}, 黑名单={len(blocked)}")

        # 阶段 K（K1-K3）：会话元数据随登录初始数据推送（最后一条），
        # 客户端同步消费后恢复置顶/静音/草稿/清空标记（无需登录后请求）。
        conversations = self.server.db.get_conversations(username)
        conversation_list = [
            {
                "peer_key": c["peer_key"],
                "pinned": 1 if c["pinned"] else 0,
                "muted": 1 if c["muted"] else 0,
                "draft": c["draft"],
                "cleared_at": c["cleared_at"],
            }
            for c in conversations
        ]
        self.server.guarded_send(ssock, "admin_response", json.dumps(conversation_list),
                     extra_headers={"response_type": "list_conversations"})
        logging.info(f"发送初始会话元数据给用户: {username}, 会话数={len(conversation_list)}")

    def load_offline_data(self, username, ssock):
        """加载用户的离线消息和文件请求（**不含文件体补发**，见 push_offline_files）。

        阶段 R-P14（2026-09-05 用户实测"登录时间过长"）：文件体补发从本方法
        拆出为 push_offline_files，由登录流程在 send_initial_data（好友/群组
        等列表）**之后**调用——大文件（如 22MB 视频）补发不再阻塞登录初始
        数据，客户端立即完成登录进入主界面，文件在监听循环中后台接收
        （气泡进度条照常显示）。
        """
        messages = self.server.db.get_offline_messages(username)
        logging.info(f"用户 {username} 的离线消息: {len(messages)} 条")

        # 阶段 N3b 修复：群文件离线补发按群组路由——平行查询各离线行的
        # group_id（get_offline_messages 元组形态保持 9 列不变）
        offline_group_ids = self.server.db.get_offline_group_ids(
            [m[4] for m in messages])

        for msg in messages:
            message_id = "?"
            try:
                sender, msg_type, content, filename, message_id, status, msg_receiver, msg_timestamp, file_path = msg
                logging.info(f"发送离线消息: 发送者={sender}, 类型={msg_type}, 消息ID={message_id}")

                if msg_type == "chat":
                    extra_headers = {"from": sender, "history": "true", "message_id": message_id,
                                     "timestamp": str(msg_timestamp), "status": status}
                    if sender == username:
                        extra_headers["to"] = msg_receiver
                    # 阶段 K（K5）：离线投递的引用元数据随 headers 推送；
                    # 表情回应聚合随 headers 推送（跨登录持久化，P1-4）
                    extras = self.server.db.get_offline_extras(message_id)
                    if extras:
                        for key in ("reply_to", "reply_preview"):
                            if extras.get(key):
                                extra_headers[key] = extras[key]
                    reactions = self._reactions_for_headers(message_id)
                    if reactions:
                        extra_headers["reactions"] = json.dumps(reactions)
                    self.server.guarded_send(ssock, "chat", content.decode('utf-8'),
                                 extra_headers=extra_headers)
                elif msg_type == "file":
                    # 阶段 R-P14：文件体补发延后至 send_initial_data 之后
                    # （push_offline_files），不阻塞登录初始数据
                    logging.info(
                        f"离线文件延后补发: 发送者={sender}, 接收者={username}, "
                        f"消息ID={message_id}")
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
                            # 离线行 message_id = "{orig}_{接收者}"，按接收者后缀剥离
                            # 还原原始 id（成员名可含下划线，故不能用固定分段法；
                            # 客户端 id 恒为 "{毫秒}_{随机数}"，UUID 亦无下划线，
                            # endswith 剥离最末 "_接收者" 段即可无损还原）
                            suffix = f"_{msg_receiver}"
                            original_id = (message_id[:-len(suffix)]
                                          if message_id.endswith(suffix)
                                          else message_id)
                            group_extra = {
                                "from": sender,
                                "group_id": str(group_id),
                                "history": "true",
                                "message_id": original_id,
                                "timestamp": str(msg_timestamp),
                                "status": status
                            }
                            # 阶段 K（K5）：群聊离线副本 JSON 中的引用元数据
                            for key in ("reply_to", "reply_preview"):
                                if message_data.get(key):
                                    group_extra[key] = message_data[key]
                            # 表情回应聚合随 headers 推送（跨登录持久化，P1-4）
                            reactions = self._reactions_for_headers(original_id)
                            if reactions:
                                group_extra["reactions"] = json.dumps(reactions)
                            self.server.guarded_send(ssock, "group_chat", message_text,
                                         extra_headers=group_extra)
                            logging.info(f"发送离线群聊消息: 发送者={sender}, 群组ID={group_id}, 消息ID={message_id}")
                        else:
                            logging.warning(
                                f"未找到有效群组ID或用户不再是群成员: 发送者={sender}, 接收者={username}, 消息ID={message_id}")
                    except json.JSONDecodeError:
                        logging.error(f"解析群组消息内容失败: 发送者={sender}, 接收者={username}, 消息ID={message_id}")
                    except Exception as e:
                        logging.error(
                            f"处理群组消息失败: {str(e)}, 发送者={sender}, 接收者={username}, 消息ID={message_id}")
                elif msg_type == "group_announcement":
                    # 阶段 O1：群公告离线补发（复用群聊补发惯例：剥离
                    # "_接收者" 后缀还原原始 message_id，group_id 路由）
                    gid = offline_group_ids.get(message_id)
                    if gid is not None and self.server.db.is_group_member(gid, username):
                        suffix = f"_{msg_receiver}"
                        original_id = (message_id[:-len(suffix)]
                                       if message_id.endswith(suffix)
                                       else message_id)
                        self.server.guarded_send(
                            ssock, "group_announcement", content.decode("utf-8"),
                            extra_headers={"from": sender, "group_id": str(gid),
                                           "history": "true",
                                           "message_id": original_id,
                                           "timestamp": str(msg_timestamp),
                                           "status": status})
                        logging.info(f"发送离线群公告: 群组ID={gid}, 消息ID={original_id}")
            except Exception as e:
                # 阶段 I 修复：单条离线消息推送异常（如瞬时 SQLite 锁）不得中断登录流程
                logging.error(f"推送离线消息异常（跳过）: 用户={username}, 消息ID={message_id}, 错误={e}")

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

        # 加载待处理好友请求（阶段 J：携带验证消息）
        pending_requests = self.server.db.get_pending_friend_requests_detail(username)
        logging.info(f"用户 {username} 的待处理好友请求: {len(pending_requests)} 条")
        for requester, request_message in pending_requests:
            try:
                extra_headers = {"from": requester}
                if request_message:
                    extra_headers["message"] = request_message
                self.server.guarded_send(ssock, "friend_request", f"来自 {requester} 的好友请求",
                             extra_headers=extra_headers)
                logging.info(f"发送待处理好友请求: 请求者={requester}, 接收者={username}")
            except Exception as e:
                logging.error(f"发送待处理好友请求失败: 请求者={requester}, 接收者={username}, 错误={e}")

        # 加载待处理群邀请（阶段 M：P-11 用户反馈——邀请像好友申请一样
        # 保留入口，离线用户登录后补发 group_invite，而非仅文本通知）
        pending_invites = self.server.db.get_pending_group_invitations(username)
        logging.info(f"用户 {username} 的待处理群邀请: {len(pending_invites)} 条")
        for group_id, group_name, inviter in pending_invites:
            try:
                self.server.guarded_send(
                    ssock, "group_invite", "",
                    extra_headers={"from": inviter, "group_id": str(group_id),
                                   "group_name": group_name})
                logging.info(f"发送待处理群邀请: 群组={group_id}, 邀请人={inviter}, "
                             f"接收者={username}")
            except Exception as e:
                logging.error(f"发送待处理群邀请失败: 群组={group_id}, "
                              f"接收者={username}, 错误={e}")

    def push_offline_files(self, username, ssock, device_id="default"):
        """离线文件体补发（阶段 R-P14：从 load_offline_data 拆出）。

        登录流程在 send_initial_data（好友/群组列表）**之后**调用——大文件
        （如 22MB 视频）补发不再阻塞登录初始数据：客户端立即完成登录进入
        主界面，文件体在监听循环中后台接收（进度条气泡照常显示）。

        头部契约与原 load_offline_data file 分支完全一致（from/filename/
        history/message_id/timestamp/status，发送者回显带 to，群文件带
        group_id）；经 per-socket 写锁发送（R-P13：与其它线程的
        guarded_send 串行，杜绝并发 sendall 交错 TLS 记录）。

        R-P21（2026-09-05 用户实测"重登后已下载文件重新下载"）：接收方
        **本设备**此前已完整收过的文件不再重复推送文件体，改推 file_meta
        （同头部、无消息体，追加 filesize 头）——客户端仅重建/对账气泡，
        不触发重新下载。判定依据（阶段 L 的 file_request_resolutions）：
        该用户对此消息的接受记录 device_id 与本次登录 device_id 一致；
        发送者自身回显（sender == username，原文件就在发送端本地）同样
        只推元数据。其他设备登录仍补发完整文件体（多端文件同步语义不变）。
        """
        messages = self.server.db.get_offline_messages(username)
        offline_group_ids = self.server.db.get_offline_group_ids(
            [m[4] for m in messages])
        for msg in messages:
            message_id = "?"
            try:
                sender, msg_type, content, filename, message_id, status, \
                    msg_receiver, msg_timestamp, file_path = msg
                if msg_type != "file":
                    continue
                logging.info(f"发送离线消息: 发送者={sender}, 类型=file, "
                             f"消息ID={message_id}")
                extra_headers = {"from": sender, "filename": filename,
                                 "history": "true",
                                 "message_id": message_id,
                                 "timestamp": str(msg_timestamp),
                                 "status": status}
                if sender == username:
                    extra_headers["to"] = msg_receiver
                gid = offline_group_ids.get(message_id)
                if gid is not None:
                    extra_headers["group_id"] = str(gid)
                if self._skip_offline_file_body(sender, username, message_id,
                                                device_id):
                    if file_path and os.path.exists(file_path):
                        extra_headers["filesize"] = str(
                            os.path.getsize(file_path))
                    self.server.guarded_send(ssock, "file_meta", "",
                                             extra_headers=extra_headers)
                    logging.info(f"已下载文件仅补发元数据（不重复推送文件体）: "
                                 f"接收者={username}, 消息ID={message_id}")
                    continue
                if file_path and os.path.exists(file_path):
                    # 大文件：流式分块发送，不读入内存。
                    # R-P13：per-socket 写锁内发送，与其它线程的
                    # guarded_send（presence/聊天推送）串行
                    self.server.with_sock_write(
                        ssock,
                        lambda: send_file_message(
                            ssock, "file", file_path,
                            extra_headers=extra_headers))
                else:
                    self.server.guarded_send(ssock, "file", content,
                                             extra_headers=extra_headers)
            except Exception as e:
                # 单条推送异常不中断后续补发（与 load_offline_data 隔离惯例一致）
                logging.error(f"推送离线文件异常（跳过）: 用户={username}, "
                              f"消息ID={message_id}, 错误={e}")

    def _skip_offline_file_body(self, sender, username, message_id,
                                device_id):
        """R-P21：判定离线文件是否只补发元数据（file_meta）不推送文件体。

        ① 发送者自身回显：原文件就在发送端本地，重登补发纯浪费带宽；
        ② 接收方本设备此前已接受该文件（file_request_resolutions 存在
           (accept, device_id) 记录且与本次登录设备一致）——阶段 L⑨ 在
           file_response/group_file_response 处理时落库，接受即完整传输
           （delivered 在传输完成后才标记，传输中断仍是 sent 不受影响）。
        无接受记录的旧行（阶段 L 之前的历史数据）保守补发完整文件体。
        """
        if sender == username:
            return True
        resolution = self.server.db.get_file_resolution(message_id, username)
        return (resolution is not None
                and resolution[0] == "accept"
                and resolution[1] == device_id)

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
        # 阶段 M8（P1-5）：发送方携带的文件 SHA-256（可选，接收方校验依据）
        sha256_header = header.get("sha256") or ""
        # 阶段 M8（P1-6 断点续传）：offset > 0 表示在已有部分文件上追加
        offset_str = header.get("offset", "")
        try:
            resume_offset = int(offset_str) if offset_str else 0
        except (TypeError, ValueError):
            resume_offset = 0
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
            if self.server.db.is_blocked(target, username):
                if length > 0:
                    recv_body(ssock, length)
                self.server.guarded_send(ssock, "error", "对方已将您拉黑，无法发送文件")
                logging.warning(f"大文件直传失败: {username} -> {target}, 被对方拉黑")
                return True
            if not self.server.db.is_friend(username, target):
                if length > 0:
                    recv_body(ssock, length)
                self.server.guarded_send(ssock, "error", f"错误：{target} 不是您的好友")
                logging.warning(f"大文件直传失败: {username} -> {target}, 非好友")
                return True
            # 转发目标：优先接收方的传输通道（transfer socket，聊天主连接
            # 不被占用）；旧客户端无传输通道时回退到主会话（需抑制写入）。
            # 阶段 L1：主会话可多个（多设备并存），回退时取任一同名会话。
            with self.server.client_map_lock:
                transfer_recipient = self.server.transfer_sockets.get(target)
                main_sessions = [sock for (u, _d), sock in
                                 self.server.client_map.items() if u == target]
            main_recipient = main_sessions[0] if main_sessions else None
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
            # P-07 修复：长转发前引用接收方 socket——期间任何关闭操作
            # （管理员强制下线等）延迟到转发结束后，杜绝 fd 复用竞态
            # （SSL 字节写进被 sqlite 复用的数据库文件 fd）
            if not self.server.acquire_send_sock(recipient_socket):
                if length > 0:
                    recv_body(ssock, length)
                self.server.guarded_send(ssock, "error", f"用户 {target} 离线，无法传输大文件")
                logging.warning(f"大文件直传失败: {username} -> {target}, 目标已离线")
                return True
            # 心跳守护保护：传输期间发送方持续读取文件体（可能超过超时阈值），
            # 标记为"直传源"跳过超时扫描，避免长文件传输被误判断开
            with self.server.client_map_lock:
                self.server.direct_transfer_sources.add(ssock)
            try:
                if use_main_fallback:
                    # 主连接回退：标记接收方为"转发中"，期间抑制一切写入
                    # （pong/kick/推送会污染文件字节流）
                    with self.server.client_map_lock:
                        self.server.active_forward_socks.add(recipient_socket)
                # 先向接收方发送 file 消息头（length = 实际消息体长度），再边收边转发 body
                # 阶段 M8（P1-5）：sha256 头透传（直传不落盘无法校验，由接收方校验）
                send_message_header_only(
                    recipient_socket, "file", length,
                    extra_headers={"from": username, "filename": filename,
                                   "filesize": effective_size, "message_id": message_id,
                                   "sha256": sha256_header})
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
                with self.server.client_map_lock:
                    self.server.direct_transfer_sources.discard(ssock)
                self.server.release_send_sock(recipient_socket)
                if use_main_fallback:
                    # 转发结束：解除抑制；若接收方仍是最新会话，补推转发期间积压的离线消息
                    with self.server.client_map_lock:
                        self.server.active_forward_socks.discard(recipient_socket)
                        still_current = any(
                            sock is recipient_socket
                            for (u, _d), sock in self.server.client_map.items()
                            if u == target)
                    if still_current:
                        try:
                            self.load_offline_data(target, recipient_socket)
                            # 阶段 R-P14：文件体补发（拆分后需显式调用）
                            # R-P21：按接收方会话设备判定已下载文件只推元数据
                            self.push_offline_files(
                                target, recipient_socket,
                                self.server.device_id_of(recipient_socket))
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
            # 阶段 M8（P1-6 断点续传）：offset > 0 时在已有部分文件上追加
            # （磁盘已有大小必须与 offset 一致，否则拒绝并保留原数据）
            if resume_offset > 0:
                if (os.path.exists(file_path)
                        and os.path.getsize(file_path) == resume_offset):
                    written = recv_body_to_file_append(ssock, file_path, length)
                    if written < length:
                        self.server.guarded_send(ssock, "error", "文件接收不完整")
                        logging.error(f"文件接收不完整: 消息ID={message_id}, {written}/{length}")
                        return False
                else:
                    if length > 0:
                        recv_body(ssock, length)
                    self.server.guarded_send(ssock, "error", "续传偏移不匹配")
                    logging.warning(f"续传偏移不匹配: 消息ID={message_id}, "
                                    f"offset={resume_offset}")
                    return True
            else:
                written = recv_body_to_file(ssock, file_path, length)
                if written < length:
                    self.server.guarded_send(ssock, "error", "文件接收不完整")
                    logging.error(f"文件接收不完整: 消息ID={message_id}, {written}/{length}")
                    return False
            # 阶段 M8（P1-5 文件完整性校验）：头带 sha256 且与内容不符 → 拒绝并删除
            if sha256_header and os.path.exists(file_path):
                actual_sha = _sha256_of_file(file_path)
                if actual_sha != sha256_header:
                    self.server.db._delete_disk_file(file_path)
                    self.server.guarded_send(ssock, "error", "文件校验失败（SHA-256 不匹配）")
                    logging.warning(f"文件 SHA-256 校验失败: 消息ID={message_id}")
                    return True
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
                self.server.db.save_group_file_request(group_id, username, filename, effective_size, file_data, message_id, file_path=file_path, sha256=sha256_header or None)
                self.group_handler.notify_group_members(
                    group_id, "group_file_request", "",
                    from_user=username,
                    extra_headers={"filename": filename, "filesize": effective_size,
                                   "message_id": message_id, "sha256": sha256_header}
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
        if self.server.db.is_blocked(target, username):
            if file_path:
                self.server.db._delete_disk_file(file_path)
            self.server.guarded_send(ssock, "error", "对方已将您拉黑，无法发送文件")
            logging.warning(f"文件发送失败: {username} -> {target}, 被对方拉黑")
            return True
        self.server.db.save_file_request(username, target, filename, effective_size, file_data, message_id, file_path=file_path, sha256=sha256_header or None)
        # 阶段 L1：会话级推送——文件请求到达目标用户所有在线会话
        delivered = self.server.broadcast_to_user(
            target, "file_request", "",
            extra_headers={"from": username, "filename": filename,
                           "filesize": effective_size, "message_id": message_id,
                           "sha256": sha256_header})
        if delivered:
            logging.info(f"文件请求已发送: {username} -> {target}, 文件名={filename}, 消息ID={message_id}")
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
            # 心跳守护：收到任何消息即刷新会话活动时间
            self.server.touch_activity(ssock)
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
            self.server.touch_activity(ssock)

            try:
                if msg_type == "ping":
                    try:
                        self.server.guarded_send(ssock, "pong", b"")
                    except Exception as e:
                        logging.warning(f"回复 pong 失败: {username}, {e}")

                elif msg_type == "chat":
                    target = header.get("to")
                    message_id = header.get("message_id", str(uuid.uuid4()))
                    # 阶段 J：黑名单拦截（A 拉黑 B → B 对 A 的发送被拒）
                    if self.server.db.is_blocked(target, username):
                        self.server.guarded_send(ssock, "error", "对方已将您拉黑，无法发送消息")
                        logging.warning(f"消息发送失败: {username} -> {target}, 被对方拉黑")
                        continue
                    if not self.server.db.is_friend(username, target):
                        self.server.guarded_send(ssock, "error", f"错误：{target} 不是您的好友")
                        logging.warning(f"消息发送失败: {username} -> {target}, 非好友")
                        continue
                    # 阶段 I：重发幂等——客户端断线补发/手动重试复用原 message_id，
                    # 若此前已入库（离线补发/历史），跳过重复保存与转发，
                    # 避免"已送达消息被二次下发"
                    if self.server.db.message_id_exists(message_id, sender=username):
                        logging.info(f"重复消息已跳过（幂等）: 用户={username}, 消息ID={message_id}")
                        continue
                    message = data.decode("utf-8")
                    logging.info(f"来自 {username} 发往 {target} 的聊天消息: {message}, 消息ID={message_id}")
                    self.server.db.save_offline_message(username, target, "chat", message.encode('utf-8'), message_id=message_id)
                    # 同步写入永久消息历史
                    self.server.db.save_message_history(username, target, "chat", message.encode('utf-8'), message_id=message_id)
                    # 阶段 L1：会话级推送——私聊到达目标用户所有在线会话
                    delivered = self.server.broadcast_to_user(
                        target, "chat", message,
                        extra_headers={"from": username, "message_id": message_id})
                    if delivered:
                        # 阶段 K 缺陷修复（P-47）：实时送达成功即标记 delivered，
                        # 否则下次登录该消息仍按 sent 推送 → 已查看消息复发未读徽标
                        self.server.db.update_message_status(message_id, 'delivered')
                        logging.info(f"消息已转发: {username} -> {target}, 消息ID={message_id}")
                    else:
                        self.server.guarded_send(ssock, "chat", f"用户 {target} 离线，消息已保存")
                        logging.info(f"用户 {target} 离线，消息已保存: 消息ID={message_id}")
                    if message.lower() == "quit":
                        break

                elif (msg_type.startswith("call_")
                      or msg_type.startswith("group_call_")):
                    # 阶段 R1/R2：通话信令中继（一对一 invite/accept/.../
                    # ice + 群通话 group_call_invite/join/leave/media）——
                    # 状态与转发逻辑在 CallHandler，异常隔离沿用本
                    # try/except（连接不断开）
                    self.server.call_handler.handle(
                        username, ssock, msg_type, header, data)

                elif msg_type == "schedule_message":
                    # 阶段 O5（P2-5 定时消息）：预约发送——先入 pending 队列，
                    # 服务端定时器（scheduler_scan）到点投递。schedule_at 统一
                    # epoch 秒（UTC 中立，"注意时区"以 epoch 比较）。
                    try:
                        schedule_at = float(header.get("schedule_at"))
                    except (TypeError, ValueError):
                        self.server.guarded_send(ssock, "error", "无效的定时时间")
                        continue
                    if schedule_at <= time.time():
                        self.server.guarded_send(ssock, "error",
                                                 "定时时间必须晚于当前时间")
                        logging.warning(f"定时消息被拒: 用户={username}, "
                                        f"时间早于当前")
                        continue
                    message_id = header.get("message_id", str(uuid.uuid4()))
                    text = data.decode("utf-8")
                    group_id_header = header.get("group_id")
                    if group_id_header is not None:
                        try:
                            group_id = int(group_id_header)
                        except (ValueError, TypeError):
                            self.server.guarded_send(ssock, "error", "无效的群组ID")
                            continue
                        if not self.server.db.is_group_member(group_id, username):
                            self.server.guarded_send(ssock, "error", "您不在此群组中")
                            continue
                        if self.server.db.add_scheduled_message(
                                message_id, username, text, schedule_at,
                                group_id=group_id):
                            self.server.guarded_send(ssock, "chat", "定时消息已设置")
                            logging.info(f"群定时消息已登记: 用户={username}, "
                                         f"群组={group_id}, 消息ID={message_id}")
                        continue
                    target = header.get("to")
                    if not target:
                        self.server.guarded_send(ssock, "error", "缺少接收者")
                        continue
                    if self.server.db.is_blocked(target, username):
                        self.server.guarded_send(ssock, "error",
                                                 "对方已将您拉黑，无法发送消息")
                        continue
                    if not self.server.db.is_friend(username, target):
                        self.server.guarded_send(ssock, "error",
                                                 f"错误：{target} 不是您的好友")
                        continue
                    if self.server.db.add_scheduled_message(
                            message_id, username, text, schedule_at,
                            receiver=target):
                        self.server.guarded_send(ssock, "chat", "定时消息已设置")
                        logging.info(f"定时消息已登记: 用户={username} -> "
                                     f"{target}, 消息ID={message_id}")

                elif msg_type == "cancel_scheduled":
                    # 阶段 O5：取消本人 pending 定时消息
                    message_id = header.get("message_id") or ""
                    if self.server.db.cancel_scheduled_message(message_id, username):
                        self.server.guarded_send(ssock, "chat", "已取消定时消息")
                        logging.info(f"定时消息已取消: 用户={username}, "
                                     f"消息ID={message_id}")
                    else:
                        self.server.guarded_send(
                            ssock, "error", "定时消息不存在、已投递或无权取消")

                elif msg_type == "list_scheduled":
                    # 阶段 O5：列出本人 pending 定时消息（schedule_at 升序）
                    rows = self.server.db.list_scheduled_messages(username)
                    entries = [{
                        "message_id": r["message_id"],
                        "receiver": r["receiver"],
                        "group_id": r["group_id"],
                        "content": r["content"],
                        "schedule_at": r["schedule_at"],
                        "status": r["status"],
                    } for r in rows]
                    self.server.guarded_send(ssock, "scheduled_list_response",
                                             json.dumps(entries))
                    logging.info(f"定时消息列表查询: 用户={username}, "
                                 f"共 {len(entries)} 条")

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
                    if self.server.db.is_blocked(target, username):
                        self.server.guarded_send(ssock, "error", "对方已将您拉黑，无法传输文件")
                        logging.warning(f"大文件探测失败: {username} -> {target}, 被对方拉黑")
                        continue
                    if not self.server.db.is_friend(username, target):
                        self.server.guarded_send(ssock, "error", f"错误：{target} 不是您的好友")
                        logging.warning(f"大文件探测失败: {username} -> {target}, 非好友")
                        continue
                    with self.server.client_map_lock:
                        transfer_recipient = self.server.transfer_sockets.get(target)
                        main_sessions = [sock for (u, _d), sock in
                                         self.server.client_map.items() if u == target]
                    main_recipient = main_sessions[0] if main_sessions else None
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
                    # 阶段 L 多端前置：该用户在其它设备已接受/拒绝过此文件 →
                    # 提示"该文件已在XXX被接受/拒绝"，而非"文件请求不存在"
                    prior = self.server.db.get_file_resolution(message_id, username)
                    if prior:
                        prior_action, prior_device = prior
                        action_text = "接受" if prior_action == "accept" else "拒绝"
                        device_name = prior_device or "default"
                        self.server.guarded_send(
                            ssock, "error", f"该文件已在{device_name}被{action_text}")
                        logging.info(f"文件响应重复: 用户={username}, 消息ID={message_id}, "
                                     f"已在设备 {device_name} 被{action_text}")
                        continue
                    file_request = self.server.db.get_file_request(message_id)
                    if not file_request:
                        self.server.guarded_send(ssock, "error", f"文件请求 {message_id} 不存在")
                        logging.warning(f"文件响应失败: 消息ID={message_id} 不存在")
                        continue
                    sender, receiver, filename, filesize, file_data, file_path, status = file_request
                    if status == 'recalled':
                        # 阶段 K 缺陷修复（P-61）：文件已被发送者撤回——提示"对方已撤回"，
                        # 而非"文件请求不存在"
                        self.server.guarded_send(ssock, "error", "对方已撤回该文件，无法接收")
                        logging.info(f"文件响应失败: 消息ID={message_id} 已被撤回，用户={username}")
                        continue
                    if receiver != username:
                        self.server.guarded_send(ssock, "error", "无权限响应此文件请求")
                        logging.warning(f"文件响应失败: 用户 {username} 无权限响应消息ID={message_id}")
                        continue
                    # 阶段 L 多端前置：在文件落库/推送前先记录响应设备——
                    # 避免其他设备在推送完成前并发响应时读到旧状态误判"不存在"
                    self.server.db.record_file_resolution(
                        message_id, username, response,
                        self.server.device_id_of(ssock))
                    if response == "accept":
                        # 大文件：把待处理文件转入历史区（原子 rename），DB 存路径
                        history_path = (self.server.db.promote_file_to_history(file_path, message_id)
                                        if file_path else None)
                        if history_path:
                            file_data = b''
                        self.server.db.save_offline_message(sender, receiver, "file", file_data, filename=filename, message_id=message_id, file_path=history_path)
                        # 同步写入永久消息历史
                        self.server.db.save_message_history(sender, receiver, "file", file_data, filename=filename, message_id=message_id, file_path=history_path)
                        # 阶段 L1：文件送达接收者所有在线会话（会话级推送）
                        receiver_sessions = self.server.sessions_of(receiver)
                        # 阶段 M8（P1-5）：推送携带 sha256（接收方校验依据）
                        file_extras = self.server.db.get_file_request_extras(message_id)
                        file_sha256 = (file_extras or {}).get("sha256", "")
                        file_headers = {"from": sender, "filename": filename,
                                        "filesize": filesize, "message_id": message_id,
                                        "sha256": file_sha256}
                        file_delivered = 0
                        for r_sock in receiver_sessions:
                            # P-07 修复：长文件推送前引用接收方 socket——
                            # 推送期间接收方会话被关闭时 fd 不被释放（延迟关闭），
                            # 杜绝 SSL 字节写进被 sqlite 复用 fd 的竞态。
                            # 阶段 P 修复：写锁内发送（与 guarded_send 串行）。
                            if history_path and not self.server.acquire_send_sock(r_sock):
                                continue
                            try:
                                if history_path:
                                    self.server.with_sock_write(
                                        r_sock,
                                        lambda r=r_sock: send_file_message(
                                            r, "file", history_path,
                                            extra_headers=file_headers))
                                else:
                                    self.server.guarded_send(r_sock, "file", file_data,
                                                             extra_headers=file_headers)
                                file_delivered += 1
                            except Exception as e:
                                logging.error(f"传输文件失败: {sender} -> {receiver}, 文件名={filename}, 消息ID={message_id}, 错误={e}")
                                self.server.discard_socket(r_sock)
                            finally:
                                if history_path:
                                    self.server.release_send_sock(r_sock)
                        if file_delivered:
                            # 阶段 K 缺陷修复（P-47）：文件实时送达成功即标记 delivered，
                            # 否则下次登录该文件按 sent 重推 → 文件消息复发未读/重复展示
                            self.server.db.update_message_status(message_id, 'delivered')
                            logging.info(f"文件已传输: {sender} -> {receiver}, 文件名={filename}, 消息ID={message_id}")
                        self.server.db.delete_file_request(message_id)
                        logging.info(f"文件请求已删除: 消息ID={message_id}")
                    else:
                        self.server.db.delete_file_request(message_id)
                        logging.info(f"文件请求已删除: 消息ID={message_id}")

                elif msg_type == "friend_request":
                    target = header.get("to")
                    # 阶段 J：黑名单双向不可请求
                    if self.server.db.is_blocked(target, username) or \
                            self.server.db.is_blocked(username, target):
                        self.server.guarded_send(ssock, "error", "对方已将您拉黑，无法发送好友请求")
                        logging.warning(f"好友请求失败: {username} -> {target}, 存在拉黑关系")
                        continue
                    if not self.server.db.user_exists(target):
                        self.server.guarded_send(ssock, "error", f"用户 {target} 不存在")
                        logging.warning(f"好友请求失败: 目标用户 {target} 不存在")
                        continue
                    if self.server.db.is_friend(username, target):
                        self.server.guarded_send(ssock, "error", f"用户 {target} 已是您的好友")
                        logging.warning(f"好友请求失败: {username} 和 {target} 已为好友")
                        continue
                    # 阶段 J：好友请求可携带验证消息（P1-10）
                    request_message = header.get("message")
                    if self.server.db.add_friend_request(username, target, request_message):
                        extra_headers = {"from": username}
                        if request_message:
                            extra_headers["message"] = request_message
                        # 阶段 L1：好友请求到达目标所有在线会话
                        delivered = self.server.broadcast_to_user(
                            target, "friend_request", f"来自 {username} 的好友请求",
                            extra_headers=extra_headers)
                        if delivered:
                            logging.info(f"好友请求已发送: {username} -> {target}")
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
                        # 阶段 M3（P1-18 新成员历史可见性）：按成员加入时间过滤
                        # visible=1（默认）：可见加入前最近 history_limit 条 ∪ 加入后全部
                        # visible=0：仅可见自己加入之后的消息
                        since = None
                        info = self.server.db.get_group_info(gid)
                        if info:
                            with self.server.db._get_connection() as conn:
                                row = conn.execute(
                                    "SELECT joined_at FROM group_members "
                                    "WHERE group_id = ? AND username = ?",
                                    (gid, username)).fetchone()
                                joined_at = row[0] if row else None
                            if joined_at:
                                if info["history_visible"] == 0:
                                    since = joined_at
                                else:
                                    history_limit = info["history_limit"] or 50
                                    with self.server.db._get_connection() as conn:
                                        row2 = conn.execute(
                                            "SELECT MIN(timestamp) FROM ("
                                            "SELECT timestamp FROM message_history "
                                            "WHERE group_id = ? AND timestamp < ? "
                                            "ORDER BY timestamp DESC, id DESC LIMIT ?)",
                                            (gid, joined_at, history_limit)).fetchone()
                                    since = row2[0] if (row2 and row2[0]) else joined_at
                        rows = self.server.db.get_message_history_rows(
                            username, group_id=gid, before=before, limit=limit_int,
                            since=since)
                    elif with_user:
                        rows = self.server.db.get_message_history_rows(
                            username, with_user=with_user, before=before, limit=limit_int)
                    else:
                        rows = self.server.db.get_message_history_rows(
                            username, before=before, limit=limit_int)
                    # 阶段 K（K5）：history_response 携带 reply_to/reactions
                    batch = []
                    for r in rows:
                        reactions_by_emoji = {}
                        for reaction in self.server.db.get_reactions(r["message_id"]):
                            reactions_by_emoji.setdefault(reaction["emoji"], []).append(reaction["username"])
                        batch.append({
                            "sender": r["sender"], "type": r["message_type"],
                            "content": r["content"],
                            "message_id": r["message_id"], "filename": r["filename"],
                            "timestamp": r["timestamp"],
                            "group_id": r["group_id"], "status": r["status"],
                            "reply_to": r["reply_to"],
                            "reactions": reactions_by_emoji,
                        })
                    self.server.guarded_send(ssock, "history_response", json.dumps(batch),
                                 extra_headers={"to": with_user or "", "group_id": group_id or ""})
                    logging.info(f"历史消息拉取: 用户={username}, 会话={with_user or group_id}, 返回={len(batch)}条")

                elif msg_type == "search_history":
                    # 消息搜索（阶段 H5；阶段 P3 扩展复合条件）
                    # header: keyword（条件全空时报错）/ to（可选私聊限定）
                    #         / group_id（可选群聊限定）/ limit（可选，默认 50）
                    #         / sender（可选发送者过滤，R-P28 支持逗号分隔
                    #           多发送者——用户名字符集不含逗号，可安全切分）
                    #         / time_from / time_to（可选时间范围，epoch 秒）
                    # 服务端返回最新在前（timestamp DESC, id DESC），客户端负责翻转展示顺序
                    keyword = (header.get("keyword") or "").strip()
                    with_user = header.get("to")
                    group_id = header.get("group_id")
                    raw_sender = (header.get("sender") or "").strip()
                    senders = [s.strip() for s in raw_sender.split(",")
                               if s.strip()]

                    def _epoch_to_db_ts(raw):
                        if raw in (None, ""):
                            return None
                        try:
                            from datetime import datetime, timezone
                            return datetime.fromtimestamp(
                                int(raw), tz=timezone.utc).strftime(
                                "%Y-%m-%d %H:%M:%S")
                        except (ValueError, TypeError, OSError):
                            return None

                    time_from = _epoch_to_db_ts(header.get("time_from"))
                    time_to = _epoch_to_db_ts(header.get("time_to"))
                    if not keyword and not senders \
                            and time_from is None and time_to is None:
                        self.server.guarded_send(ssock, "error", "搜索关键字不能为空")
                        logging.warning(f"搜索失败: 用户={username}, 缺少搜索关键字")
                        continue
                    limit = header.get("limit", "50")
                    try:
                        limit_int = int(limit)
                    except (ValueError, TypeError):
                        limit_int = 50
                    rows = self.server.db.search_message_history(
                        username, keyword, with_user=with_user, group_id=group_id,
                        limit=limit_int, sender=senders,
                        time_from=time_from, time_to=time_to)
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
                    self.server.guarded_send(ssock, "search_response", json.dumps(batch),
                                 extra_headers={"to": with_user or "",
                                                "group_id": group_id or "",
                                                "keyword": keyword})
                    logging.info(f"消息搜索: 用户={username}, 关键字={keyword}, "
                                 f"会话={with_user or group_id or '全局'}, "
                                 f"返回={len(batch)}条")

                elif msg_type == "get_profile":
                    # 用户资料查询（阶段 J：P0-2）
                    target = header.get("to")
                    profile = self.server.db.get_profile(target) if target else None
                    if not profile:
                        self.server.guarded_send(ssock, "error", f"用户 {target} 不存在")
                        logging.warning(f"资料查询失败: 用户={username}, 目标={target} 不存在")
                        continue
                    body = json.dumps({
                        "username": profile["username"],
                        "nickname": profile["nickname"],
                        "avatar": profile["avatar"],
                        "signature": profile["signature"],
                        "last_seen": profile["last_seen"],
                        "is_admin": 1 if profile["is_admin"] else 0,
                    })
                    self.server.guarded_send(ssock, "profile_response", body,
                                 extra_headers={"to": target})
                    logging.info(f"资料查询: 用户={username}, 目标={target}")

                elif msg_type == "set_profile":
                    # 更新自己的资料（阶段 J：P0-2）
                    # 至少提供一个字段（含空串清除语义）；三个字段均缺失才报错
                    nickname = header.get("nickname")
                    avatar = header.get("avatar")
                    signature = header.get("signature")
                    if nickname is None and avatar is None and signature is None:
                        self.server.guarded_send(ssock, "error", "资料不能为空，请至少设置一个字段")
                        logging.warning(f"资料更新失败: 用户={username}, 字段全部缺失")
                        continue
                    self.server.db.set_profile(
                        username,
                        nickname=nickname if nickname is not None else None,
                        avatar=avatar if avatar is not None else None,
                        signature=signature if signature is not None else None)
                    profile = self.server.db.get_profile(username)
                    body = json.dumps({
                        "username": profile["username"],
                        "nickname": profile["nickname"],
                        "avatar": profile["avatar"],
                        "signature": profile["signature"],
                        "last_seen": profile["last_seen"],
                        "is_admin": 1 if profile["is_admin"] else 0,
                    })
                    self.server.guarded_send(ssock, "profile_response", body,
                                 extra_headers={"to": username})
                    logging.info(f"资料更新: 用户={username}")

                elif msg_type == "set_friend_note":
                    # 好友备注名（阶段 J：P1-8）
                    target = header.get("to")
                    note = header.get("note", "")
                    if not self.server.db.is_friend(username, target):
                        self.server.guarded_send(ssock, "error", f"错误：{target} 不是您的好友")
                        logging.warning(f"备注设置失败: {username} -> {target}, 非好友")
                        continue
                    if self.server.db.set_friend_note(username, target, note or ""):
                        self.server.guarded_send(ssock, "chat", f"已更新 {target} 的备注")
                        logging.info(f"备注已更新: {username} -> {target}")
                    else:
                        self.server.guarded_send(ssock, "error", "备注更新失败")
                        logging.error(f"备注更新失败: {username} -> {target}")

                elif msg_type == "set_friend_group":
                    # 好友分组（阶段 J：P1-8）
                    target = header.get("to")
                    group_name = header.get("group_name", "")
                    if not self.server.db.is_friend(username, target):
                        self.server.guarded_send(ssock, "error", f"错误：{target} 不是您的好友")
                        logging.warning(f"分组设置失败: {username} -> {target}, 非好友")
                        continue
                    if self.server.db.set_friend_group(username, target, group_name or ""):
                        self.server.guarded_send(ssock, "chat", f"已更新 {target} 的分组")
                        logging.info(f"分组已更新: {username} -> {target}, 分组={group_name}")
                    else:
                        self.server.guarded_send(ssock, "error", "分组更新失败")
                        logging.error(f"分组更新失败: {username} -> {target}")

                elif msg_type == "list_friends_meta":
                    # 好友元数据（备注/分组，本视图方向）（阶段 J：P1-8）
                    metas = self.server.db.get_friends_meta(username)
                    self.server.guarded_send(ssock, "admin_response", json.dumps(metas),
                                 extra_headers={"response_type": "list_friends_meta"})
                    logging.info(f"好友元数据查询: 用户={username}, 数量={len(metas)}")

                elif msg_type == "block_user":
                    # 拉黑（阶段 J：P1-9）
                    target = header.get("to")
                    if target == username:
                        self.server.guarded_send(ssock, "error", "不能拉黑自己")
                        logging.warning(f"拉黑失败: 用户 {username} 尝试拉黑自己")
                        continue
                    if not self.server.db.user_exists(target):
                        self.server.guarded_send(ssock, "error", f"用户 {target} 不存在")
                        logging.warning(f"拉黑失败: 目标用户 {target} 不存在")
                        continue
                    if self.server.db.block_user(username, target):
                        self.server.guarded_send(ssock, "chat", f"已拉黑 {target}")
                        logging.info(f"拉黑成功: {username} -> {target}")
                    else:
                        self.server.guarded_send(ssock, "error", "拉黑失败")
                        logging.error(f"拉黑失败: {username} -> {target}")

                elif msg_type == "unblock_user":
                    # 解除拉黑（阶段 J：P1-9）
                    target = header.get("to")
                    if self.server.db.unblock_user(username, target):
                        self.server.guarded_send(ssock, "chat", f"已解除拉黑 {target}")
                        logging.info(f"解除拉黑: {username} -> {target}")
                    else:
                        self.server.guarded_send(ssock, "error", f"未拉黑用户 {target}，不在黑名单中")
                        logging.warning(f"解除拉黑失败: {username} -> {target}, 不在黑名单中")

                elif msg_type == "list_blocked":
                    # 黑名单列表（阶段 J：P1-9）
                    blocked = self.server.db.get_blocked_users(username)
                    self.server.guarded_send(ssock, "admin_response", json.dumps(blocked),
                                 extra_headers={"response_type": "list_blocked"})
                    logging.info(f"黑名单查询: 用户={username}, 数量={len(blocked)}")

                elif msg_type == "search_users":
                    # 用户搜索（阶段 J：P1-10）
                    keyword = (header.get("keyword") or "").strip()
                    if not keyword:
                        self.server.guarded_send(ssock, "error", "搜索关键字不能为空")
                        logging.warning(f"用户搜索失败: 用户={username}, 缺少关键字")
                        continue
                    results = self.server.db.search_users(keyword, exclude=username)
                    self.server.guarded_send(ssock, "user_search_response", json.dumps(results))
                    logging.info(f"用户搜索: 用户={username}, 关键字={keyword}, 返回={len(results)}条")

                elif msg_type == "accept_friend":
                    requester = header.get("from")
                    if not self.server.db.has_pending_request(requester, username):
                        self.server.guarded_send(ssock, "error", f"没有来自 {requester} 的好友请求")
                        logging.warning(f"接受好友请求失败: 没有来自 {requester} 的请求")
                        continue
                    self.server.db.accept_friend_request(requester, username)
                    self.server.guarded_send(ssock, "chat", f"已接受 {requester} 的好友请求")
                    # 阶段 L1：接受通知到达请求者所有在线会话；请求者离线则存离线通知
                    delivered = self.server.broadcast_to_user(
                        requester, "chat", f"{username} 已接受您的好友请求")
                    if not delivered:
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

                            # 阶段 O2（撤回联动）：被置顶的群消息撤回时自动解除
                            # 置顶，并向全员广播 list_groups 刷新——横幅不得
                            # 残留已撤回消息

                            if self.server.db.clear_group_pin_if_pinned(group_id, message_id):

                                for member in self.server.db.get_group_members(group_id):

                                    self.server.broadcast_to_user(

                                        member, "list_groups",

                                        self.server.group_list_json(member))

                                logging.info(f"被置顶消息已撤回，置顶自动解除: 群组={group_id}, 消息ID={message_id}")

                            # 为离线群成员保存撤回占位符（阶段 L1：无任何会话在线才算离线）
                            members = self.server.db.get_group_members(group_id)
                            for member in members:
                                if member == username:
                                    continue
                                if not self.server.has_any_session(member):
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

                            # 阶段 L1：撤回通知到达接收方所有在线会话
                            delivered = self.server.broadcast_to_user(
                                receiver, "recall", "",
                                extra_headers={"from": username, "message_id": message_id})
                            if delivered:
                                logging.info(f"通知接收方消息撤回: {message_id}, 接收方={receiver}")
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

                        sender, receiver, filename, filesize, content, file_path, status = file_request

                        if sender != username:
                            self.server.guarded_send(ssock, "error", "只能撤回自己的文件请求")

                            logging.warning(f"撤回文件请求失败: 用户 {username} 尝试撤回非自己的文件请求 {message_id}")

                            continue

                        if status == 'recalled':
                            # 已撤回：幂等成功（与"目标不存在静默成功"一致）
                            self.server.guarded_send(ssock, "recall", "",
                                         extra_headers={"message_id": message_id})
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

                        if self.server.db.mark_file_request_recalled(message_id):

                            # 阶段 L1：撤回通知到达接收方所有在线会话
                            self.server.broadcast_to_user(
                                receiver, "chat",
                                f"用户 {username} 撤回了文件请求: {filename} ({message_id})")

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

                        group_id, sender, filename, filesize, content, file_path, status = group_file_request

                        if sender != username:
                            self.server.guarded_send(ssock, "error", "只能撤回自己的文件请求")

                            logging.warning(f"撤回群组文件请求失败: 用户 {username} 尝试撤回非自己的文件请求 {message_id}")

                            continue

                        if status == 'recalled':
                            # 已撤回：幂等成功（与"目标不存在静默成功"一致）
                            self.server.guarded_send(ssock, "recall", "",
                                         extra_headers={"message_id": message_id})
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

                        if self.server.db.mark_group_file_request_recalled(message_id):

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
                        # 阶段 L1：删除通知到达被删方所有在线会话
                        delivered = self.server.broadcast_to_user(
                            target, "delete_friend", "",
                            extra_headers={"from": username})
                        if delivered:
                            logging.info(f"通知被删方: {target} 被 {username} 删除好友")
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

                elif msg_type == "pin":
                    # 阶段 K1（P1-11 会话置顶）：conversations.pinned 同步
                    peer_key = header.get("peer_key")
                    valid_key, _ = self._validate_peer_key(username, peer_key, ssock)
                    if not valid_key:
                        continue
                    if self.server.db.upsert_conversation(username, peer_key, pinned=True):
                        self.server.guarded_send(ssock, "chat", f"已置顶会话 {peer_key}")
                        logging.info(f"会话置顶: {username} -> {peer_key}")
                    else:
                        self.server.guarded_send(ssock, "error", "置顶失败")
                        logging.error(f"会话置顶失败: {username} -> {peer_key}")

                elif msg_type == "unpin":
                    # 阶段 K1（P1-11）：取消置顶
                    peer_key = header.get("peer_key")
                    valid_key, _ = self._validate_peer_key(username, peer_key, ssock)
                    if not valid_key:
                        continue
                    if self.server.db.upsert_conversation(username, peer_key, pinned=False):
                        self.server.guarded_send(ssock, "chat", f"已取消置顶会话 {peer_key}")
                        logging.info(f"取消置顶: {username} -> {peer_key}")
                    else:
                        self.server.guarded_send(ssock, "error", "取消置顶失败")
                        logging.error(f"取消置顶失败: {username} -> {peer_key}")

                elif msg_type == "mute":
                    # 阶段 K3（P1-13 逐会话静音）：conversations.muted 同步
                    peer_key = header.get("peer_key")
                    muted = header.get("muted", "1") == "1"
                    valid_key, _ = self._validate_peer_key(username, peer_key, ssock)
                    if not valid_key:
                        continue
                    if self.server.db.upsert_conversation(username, peer_key, muted=muted):
                        self.server.guarded_send(
                            ssock, "chat",
                            f"已静音会话 {peer_key}" if muted else f"已解除静音会话 {peer_key}")
                        logging.info(f"会话静音={muted}: {username} -> {peer_key}")
                    else:
                        self.server.guarded_send(ssock, "error", "静音设置失败")
                        logging.error(f"会话静音设置失败: {username} -> {peer_key}")

                elif msg_type == "set_draft":
                    # 阶段 K2（P1-12 逐会话草稿）：conversations.draft 同步
                    # 草稿高频更新，成功静默无确认
                    peer_key = header.get("peer_key")
                    valid_key, _ = self._validate_peer_key(username, peer_key, ssock)
                    if not valid_key:
                        continue
                    draft = data.decode("utf-8")
                    if self.server.db.upsert_conversation(username, peer_key, draft=draft):
                        logging.info(f"草稿已保存: {username} -> {peer_key}, 长度={len(draft)}")
                    else:
                        self.server.guarded_send(ssock, "error", "草稿保存失败")
                        logging.error(f"草稿保存失败: {username} -> {peer_key}")

                elif msg_type == "reply":
                    # 阶段 K5（P1-2 引用回复）：带原文缩略，落库 reply_to
                    reply_to = header.get("reply_to")
                    text = data.decode("utf-8")
                    if not text.strip():
                        self.server.guarded_send(ssock, "error", "回复内容不能为空")
                        logging.warning(f"引用回复失败: 用户={username}, 内容为空")
                        continue
                    quoted = self.server.db.get_history_message(reply_to) if reply_to else None
                    if not quoted:
                        self.server.guarded_send(ssock, "error", f"被引用的消息 {reply_to} 不存在")
                        logging.warning(f"引用回复失败: 被引用消息 {reply_to} 不存在")
                        continue
                    group_id = header.get("group_id")
                    if group_id:
                        gid = int(group_id)
                        if not self.server.db.is_group_member(gid, username):
                            self.server.guarded_send(ssock, "error", f"您不在群组 {gid} 中")
                            logging.warning(f"引用回复失败: {username} 不在群组 {gid}")
                            continue
                        if quoted.get("group_id") != gid:
                            self.server.guarded_send(ssock, "error", "被引用的消息不属于该群组")
                            logging.warning(f"引用回复失败: 消息 {reply_to} 不属于群组 {gid}")
                            continue
                        mid = header.get("message_id") or str(uuid.uuid4())
                        preview = quoted["content"] if quoted["status"] != "recalled" else "[消息已撤回]"
                        self.server.db.save_message_history(
                            username, "", "group_chat", text.encode("utf-8"),
                            group_id=gid, message_id=mid, reply_to=reply_to)
                        members = self.server.db.get_group_members(gid)
                        for member in members:
                            if member == username:
                                continue
                            member_mid = f"{mid}_{member}"
                            self.server.db.save_offline_message(
                                username, member, "group_chat",
                                json.dumps({"text": text, "group_id": gid,
                                            "reply_to": reply_to,
                                            "reply_preview": preview}).encode("utf-8"),
                                message_id=member_mid)
                        self._broadcast_k_message(
                            members, "group_chat", text,
                            {"from": username, "group_id": str(gid),
                             "message_id": mid, "reply_to": reply_to,
                             "reply_preview": preview},
                            exclude=username, log_context=f"引用={reply_to}")
                    else:
                        target = header.get("to")
                        if not self.server.db.is_friend(username, target):
                            self.server.guarded_send(ssock, "error", f"错误：{target} 不是您的好友")
                            logging.warning(f"引用回复失败: {username} -> {target}, 非好友")
                            continue
                        if username not in (quoted.get("sender"), quoted.get("receiver")):
                            self.server.guarded_send(ssock, "error", "被引用的消息不属于该会话")
                            logging.warning(f"引用回复失败: {username} 引用越权消息 {reply_to}")
                            continue
                        mid = header.get("message_id") or str(uuid.uuid4())
                        preview = quoted["content"] if quoted["status"] != "recalled" else "[消息已撤回]"
                        self.server.db.save_message_history(
                            username, target, "chat", text.encode("utf-8"),
                            message_id=mid, reply_to=reply_to)
                        self.server.db.save_offline_message(
                            username, target, "chat", text.encode("utf-8"),
                            message_id=mid, reply_to=reply_to, reply_preview=preview)
                        # 阶段 L1：引用回复到达目标所有在线会话
                        self.server.broadcast_to_user(
                            target, "chat", text,
                            extra_headers={"from": username, "message_id": mid,
                                           "reply_to": reply_to,
                                           "reply_preview": preview})
                        logging.info(f"引用回复成功: {username} -> {target}, 消息ID={mid}")

                elif msg_type == "forward":
                    # 阶段 K5（P1-3 转发）：跨私聊/群聊转发 + 来源标注
                    source_message_id = header.get("source_message_id")
                    source = self.server.db.get_history_message(source_message_id) if source_message_id else None
                    if not source:
                        self.server.guarded_send(ssock, "error", f"源消息 {source_message_id} 不存在")
                        logging.warning(f"转发失败: 源消息 {source_message_id} 不存在")
                        continue
                    if source["status"] == "recalled":
                        self.server.guarded_send(ssock, "error", "消息已被撤回，无法转发")
                        logging.warning(f"转发失败: 源消息 {source_message_id} 已撤回")
                        continue
                    if source["message_type"] == "file":
                        self.server.guarded_send(ssock, "error", "文件消息暂不支持转发")
                        logging.warning(f"转发失败: 源消息 {source_message_id} 为文件")
                        continue
                    # 源可见性：私聊源本人必须是双方之一；群源本人必须是成员
                    if source.get("group_id") is not None:
                        if not self.server.db.is_group_member(source["group_id"], username):
                            self.server.guarded_send(ssock, "error", "您不可见该消息，无法转发")
                            logging.warning(f"转发失败: {username} 不可见群消息 {source_message_id}")
                            continue
                    elif username not in (source.get("sender"), source.get("receiver")):
                        self.server.guarded_send(ssock, "error", "您不可见该消息，无法转发")
                        logging.warning(f"转发失败: {username} 不可见消息 {source_message_id}")
                        continue
                    group_id = header.get("group_id")
                    if group_id:
                        gid = int(group_id)
                        if not self.server.db.is_group_member(gid, username):
                            self.server.guarded_send(ssock, "error", f"您不在群组 {gid} 中")
                            logging.warning(f"转发失败: {username} 不在群组 {gid}")
                            continue
                        mid = header.get("message_id") or str(uuid.uuid4())
                        # 转发以转发人为第一手：消息归属转发者本人，无来源标注
                        self.server.db.save_message_history(
                            username, "", "group_chat",
                            source["content"].encode("utf-8"),
                            group_id=gid, message_id=mid)
                        members = self.server.db.get_group_members(gid)
                        for member in members:
                            if member == username:
                                continue
                            member_mid = f"{mid}_{member}"
                            self.server.db.save_offline_message(
                                username, member, "group_chat",
                                json.dumps({"text": source["content"], "group_id": gid}).encode("utf-8"),
                                message_id=member_mid)
                        self._broadcast_k_message(
                            members, "group_chat", source["content"],
                            {"from": username, "group_id": str(gid),
                             "message_id": mid},
                            exclude=username, log_context=f"源={source_message_id}")
                    else:
                        target = header.get("to")
                        if not self.server.db.is_friend(username, target):
                            self.server.guarded_send(ssock, "error", f"错误：{target} 不是您的好友")
                            logging.warning(f"转发失败: {username} -> {target}, 非好友")
                            continue
                        mid = header.get("message_id") or str(uuid.uuid4())
                        # 转发以转发人为第一手：消息归属转发者本人，无来源标注
                        self.server.db.save_message_history(
                            username, target, "chat",
                            source["content"].encode("utf-8"),
                            message_id=mid)
                        self.server.db.save_offline_message(
                            username, target, "chat",
                            source["content"].encode("utf-8"),
                            message_id=mid)
                        # 阶段 L1：转发到达目标所有在线会话
                        self.server.broadcast_to_user(
                            target, "chat", source["content"],
                            extra_headers={"from": username, "message_id": mid})
                        logging.info(f"转发成功: {username} -> {target}, 消息ID={mid}")

                elif msg_type == "reaction":
                    # 阶段 K5（P1-4 表情回应）：广播给会话各方，落库 reactions
                    message_id = header.get("message_id")
                    emoji = header.get("emoji")
                    action = header.get("action", "add")
                    if not emoji:
                        self.server.guarded_send(ssock, "error", "表情不能为空")
                        logging.warning(f"表情回应失败: {username}, emoji 为空")
                        continue
                    msg = self.server.db.get_history_message(message_id) if message_id else None
                    if not msg:
                        self.server.guarded_send(ssock, "error", f"消息 {message_id} 不存在")
                        logging.warning(f"表情回应失败: 消息 {message_id} 不存在")
                        continue
                    if msg["group_id"] is not None:
                        gid = msg["group_id"]
                        if not self.server.db.is_group_member(gid, username):
                            self.server.guarded_send(ssock, "error", f"您不在群组 {gid} 中")
                            logging.warning(f"表情回应失败: {username} 不在群组 {gid}")
                            continue
                        members = self.server.db.get_group_members(gid)
                        audiences = members
                        group_id_header = str(gid)
                    else:
                        if username not in (msg.get("sender"), msg.get("receiver")):
                            self.server.guarded_send(ssock, "error", "您不可见该消息，无法回应")
                            logging.warning(f"表情回应失败: {username} 不可见消息 {message_id}")
                            continue
                        audiences = [msg.get("sender"), msg.get("receiver")]
                        group_id_header = None
                    # toggle：同 emoji 再次 add → 切换为 remove；换 emoji → 替换
                    existing = self.server.db.get_reactions(message_id)
                    mine = next((r for r in existing if r["username"] == username), None)
                    effective_action = action
                    if action == "add":
                        if mine is not None and mine["emoji"] == emoji:
                            self.server.db.remove_reaction(message_id, username)
                            effective_action = "remove"
                        else:
                            self.server.db.set_reaction(message_id, username, emoji)
                    else:
                        self.server.db.remove_reaction(message_id, username)
                    extra = {"from": username, "message_id": message_id,
                             "emoji": emoji, "action": effective_action}
                    if group_id_header:
                        extra["group_id"] = group_id_header
                    self._broadcast_k_message(
                        audiences, "reaction", "", extra,
                        log_context=f"消息ID={message_id}, emoji={emoji}, action={effective_action}")
                    logging.info(f"表情回应: {username} 对 {message_id} {effective_action} {emoji}")

                elif msg_type == "file_resume":
                    # 阶段 M8（P1-6 下载断点续传）：接收方请求从 offset 续传文件
                    message_id = header.get("message_id")
                    try:
                        resume_offset = int(header.get("offset", "0") or "0")
                    except (TypeError, ValueError):
                        resume_offset = 0
                    if resume_offset < 0:
                        resume_offset = 0
                    with self.server.db._get_connection() as conn:
                        row = conn.execute(
                            "SELECT sender, receiver, filename, file_path "
                            "FROM message_history "
                            "WHERE message_id = ? AND message_type = 'file'",
                            (message_id,)).fetchone()
                    if not row or not row[3] or not os.path.exists(row[3]):
                        self.server.guarded_send(ssock, "error", "文件不存在或已过期")
                        logging.warning(f"文件续传失败: 消息ID={message_id} 不存在")
                        continue
                    if row[1] != username:
                        self.server.guarded_send(ssock, "error", "无权限续传此文件")
                        logging.warning(f"文件续传失败: 用户 {username} 非接收方")
                        continue
                    filesize = os.path.getsize(row[3])
                    if resume_offset >= filesize:
                        self.server.guarded_send(ssock, "error", "偏移超出文件大小")
                        logging.warning(f"文件续传失败: 偏移 {resume_offset} 超出 {filesize}")
                        continue
                    # 从 offset起推送剩余部分（header 携带 offset 供客户端识别续传）
                    remaining = filesize - resume_offset
                    from protocol import send_message_header_only as _send_hdr

                    def _resume_push(_sock=ssock):
                        _send_hdr(
                            _sock, "file", remaining,
                            extra_headers={"from": row[0], "filename": row[2] or "",
                                           "filesize": str(filesize),
                                           "message_id": message_id,
                                           "offset": str(resume_offset)})
                        with open(row[3], "rb") as f:
                            f.seek(resume_offset)
                            sent = 0
                            while sent < remaining:
                                chunk = f.read(1024 * 1024 * 4)
                                if not chunk:
                                    break
                                _sock.sendall(chunk)
                                sent += len(chunk)

                    # 阶段 P 修复：header+分块 body 全程持 per-socket 写锁——
                    # 与其它线程的 guarded_send 串行，防 TLS 记录交错
                    self.server.with_sock_write(ssock, _resume_push)
                    logging.info(f"文件续传完成: 消息ID={message_id}, "
                                 f"offset={resume_offset}, 剩余={remaining} 字节")

                elif msg_type == "list_files":
                    # 阶段 M8（P1-7 文件收发管理页）：按会话聚合文件历史
                    with_user = header.get("to")
                    group_id = header.get("group_id")
                    gid = None
                    if group_id:
                        try:
                            gid = int(group_id)
                        except (ValueError, TypeError):
                            self.server.guarded_send(ssock, "error", "无效的群组ID")
                            continue
                    files = self.server.db.get_user_file_messages(
                        username, with_user=with_user, group_id=gid)
                    self.server.guarded_send(ssock, "file_list_response",
                                             json.dumps(files))
                    logging.info(f"文件列表查询: 用户={username}, "
                                 f"会话={with_user or group_id or '全局'}, "
                                 f"返回={len(files)}条")

                elif msg_type == "admin_command":
                    self.admin_handler.handle_admin_command(username, ssock, header, data)

                elif msg_type == "list_sessions":
                    # 阶段 N6（P2-6 登录设备管理）：列出自己账号全部在线会话。
                    # 排序：当前会话在前，其余按 device_id 升序（确定性输出）；
                    # last_active 取 Server.session_activity（epoch 秒），
                    # 无记录（理论不发生）时回退当前时间。
                    with self.server.client_map_lock:
                        own = [(d, s) for (u, d), s in self.server.client_map.items()
                               if u == username]
                    now = time.time()
                    current_dev = None
                    for d, s in own:
                        if s is ssock:
                            current_dev = d
                            break
                    entries = []
                    for d, s in own:
                        last = self.server.session_activity.get(s, now)
                        entries.append({
                            "device_id": d,
                            "last_active": last,
                            "is_current": d == current_dev,
                        })
                    entries.sort(key=lambda e: (not e["is_current"], e["device_id"]))
                    self.server.guarded_send(ssock, "sessions_response",
                                             json.dumps(entries))
                    logging.info(f"会话列表查询: 用户={username}, 会话数={len(entries)}")

                elif msg_type == "kick_session":
                    # 阶段 N6（P2-6 登录设备管理）：远程下线自己账号的指定设备。
                    # 复用 _kick_old_session 的 P-07 约定：只 shutdown 不 close，
                    # 被下线线程 finally 在锁内清理映射并广播 presence。
                    device = (header.get("device_id") or "").strip()
                    if not device:
                        self.server.guarded_send(ssock, "error", "缺少设备标识")
                        continue
                    with self.server.client_map_lock:
                        target_sock = self.server.client_map.get((username, device))
                        is_current = (self.server.client_map.get((username, device))
                                      is ssock)
                    if is_current:
                        self.server.guarded_send(ssock, "error", "不能下线当前设备")
                        logging.warning(f"下线当前设备被拒: 用户={username}, 设备={device}")
                        continue
                    if target_sock is None:
                        self.server.guarded_send(ssock, "error",
                                                 f"设备 {device} 不在线")
                        logging.warning(f"下线不在线设备被拒: 用户={username}, 设备={device}")
                        continue
                    try:
                        self.server.guarded_send(target_sock, "error",
                                                 "您已被其他设备远程下线")
                    except Exception as e:
                        logging.warning(f"通知被下线设备失败: 用户={username}, 设备={device}, 错误={e}")
                    try:
                        target_sock.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
                    self.server.guarded_send(ssock, "chat",
                                             f"已下线设备 {device}")
                    logging.info(f"远程下线设备: 用户={username}, 设备={device}")

                elif msg_type in ("create_group", "join_group", "group_chat", "list_groups",
                                 "group_file_response", "leave_group", "list_group_members",
                                 "kick_member", "transfer_owner", "rename_group",
                                 "set_group_avatar", "set_group_history_visible",
                                 "request_join_group", "approve_join_request",
                                 "reject_join_request", "invite_group_member",
                                 "accept_group_invite", "decline_group_invite",
                                 "search_groups", "list_join_requests",
                                 "set_group_announcement", "pin_group_message",
                                 "unpin_group_message",
                                 "list_group_announcements",
                                 "delete_group_announcement"):
                    self.group_handler.handle_group_message(username, ssock, msg_type, header, data)
            except Exception as e:
                # 阶段 I 修复：单条消息处理异常（如瞬时 SQLite 锁）不得断开整个连接，
                # 记录后继续；客户端会在下一次重连时补发未送达的消息（重发幂等去重兜底）
                logging.error(f"处理消息异常（连接保持）: 用户={username}, 类型={msg_type}, 错误={e}")