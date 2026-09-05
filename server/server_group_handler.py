import json
import logging
from protocol import send_message, send_file_message
import uuid


def group_id_from_body(data):
    """解析消息体中的群组 ID（int）；非法返回 None。"""
    try:
        return int(data.decode("utf-8").strip())
    except (ValueError, TypeError):
        return None


class GroupHandler:
    def __init__(self, server):
        self.server = server

    def _request_join(self, group_id, username, ssock, message=None):
        """入群申请（P1-17 申请制）：非成员 + 无 pending → 建申请并通知群主。

        join_group（旧客户端消息类型）与 request_join_group 共用本流程：
        输入群组 ID 加入必须经群主审批，不再直接加入。
        message 为可选验证消息（P-11 用户反馈：申请可附验证消息）。
        """
        if group_id is None:
            self.server.guarded_send(ssock, "error", "无效的群组ID")
            return
        info = self.server.db.get_group_info(group_id)
        if not info:
            self.server.guarded_send(ssock, "error", f"群组 {group_id} 不存在")
            return
        if self.server.db.is_group_member(group_id, username):
            self.server.guarded_send(ssock, "error", "您已在群组中")
            return
        if not self.server.db.request_join_group(group_id, username, message):
            self.server.guarded_send(ssock, "error", "入群申请已发送，请等待群主审批")
            return
        self.server.guarded_send(ssock, "chat", "已发送入群申请，请等待群主审批")
        logging.info(f"入群申请: {username} -> 群组 {group_id}, "
                     f"验证消息={message or ''}")
        # 通知群主（在线实时 / 离线保存），携带验证消息
        notice = f"{username} 请求加入群组 {info['group_name']}（ID:{group_id}）"
        if message:
            notice += f"：{message}"
        if self.server.broadcast_to_user(info["created_by"], "chat", notice,
                                         extra_headers={"from": "系统"}):
            logging.info(f"已通知群主: {info['created_by']}")
        else:
            self.server.db.save_offline_message(
                "系统", info["created_by"], "chat", notice.encode("utf-8"),
                message_id=str(uuid.uuid4()))

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
                    # 通知客户端刷新群组列表（阶段 L1：该用户名所有在线会话）
                    self.notify_group_members(group_id, "chat", f"{username} 创建了群组 {group_name}", from_user="系统")
                    self.server.broadcast_to_user(
                        username, "list_groups", self.server.group_list_json(username))
                else:
                    self.server.guarded_send(ssock, "error", "群组创建失败，可能已存在")
                    logging.error(f"用户 {username} 创建群组失败: {group_name}")
            except Exception as e:
                self.server.guarded_send(ssock, "error", f"创建群组失败: {str(e)}")
                logging.error(f"用户 {username} 创建群组失败: {str(e)}")

        elif msg_type == "join_group":
            # 阶段 M（P1-17 用户决策修订）：输入群组 ID 加入改为**申请制**——
            # 创建入群申请并通知群主审批，不再直接加入（与 request_join_group
            # 同语义；旧客户端消息类型向后兼容复用同一审批流）
            self._request_join(group_id_from_body(data), username, ssock,
                               message=header.get("message"))

        elif msg_type == "request_join_group":
            self._request_join(group_id_from_body(data), username, ssock,
                               message=header.get("message"))

        elif msg_type == "search_groups":
            # 阶段 M（群组搜索入口）：按群名模糊搜索，排除自己已加入的群
            keyword = (header.get("keyword") or "").strip()
            if not keyword:
                self.server.guarded_send(ssock, "error", "搜索关键字不能为空")
                logging.warning(f"群组搜索失败: 用户={username}, 缺少关键字")
                return
            results = self.server.db.search_groups(keyword, username=username)
            self.server.guarded_send(ssock, "group_search_response",
                                     json.dumps(results))
            logging.info(f"群组搜索: 用户={username}, 关键字={keyword}, "
                         f"返回={len(results)}条")

        elif msg_type == "list_join_requests":
            # 阶段 M（P1-17）：群主拉取待审批入群申请列表
            try:
                group_id = int(header.get("group_id"))
            except (ValueError, TypeError):
                self.server.guarded_send(ssock, "error", "无效的群组ID")
                return
            info = self.server.db.get_group_info(group_id)
            if not info:
                self.server.guarded_send(ssock, "error", f"群组 {group_id} 不存在")
                return
            if info["created_by"] != username:
                self.server.guarded_send(ssock, "error", "只有群主可以查看入群申请")
                return
            requests = self.server.db.get_pending_group_join_requests_detail(group_id)
            self.server.guarded_send(ssock, "admin_response", json.dumps([
                {"username": u, "message": m} for u, m in requests
            ]), extra_headers={"response_type": "list_join_requests",
                               "group_id": str(group_id)})
            logging.info(f"待审批入群申请查询: 群主={username}, 群组={group_id}, "
                         f"待审批={len(requests)}人")

        elif msg_type == "set_group_announcement":
            # 阶段 O1（群公告）：群主编辑 → 全员推送（复用公告离线补发链路）。
            # 空文本 = 清除公告。时序沿用阶段 M 改名惯例：操作者确认 →
            # 全员 group_announcement 推送（notify_group_members 对新 type
            # 不跳过发送者，全员含群主）→ 全员 list_groups 刷新（携带
            # announcement 字段）；公告本体落 message_history +
            # 离线成员副本（group_id 路由，重登补发）。
            try:
                group_id = int(header.get("group_id"))
            except (ValueError, TypeError):
                self.server.guarded_send(ssock, "error", "无效的群组ID")
                return
            text = data.decode("utf-8").strip()
            message_id = header.get("message_id") or str(uuid.uuid4())
            info = self.server.db.get_group_info(group_id)
            if not info:
                self.server.guarded_send(ssock, "error", f"群组 {group_id} 不存在")
                return
            if info["created_by"] != username:
                self.server.guarded_send(ssock, "error", "只有群主可以设置群公告")
                return
            if not self.server.db.is_group_member(group_id, username):
                self.server.guarded_send(ssock, "error", "您不在此群组中")
                return
            if not self.server.db.set_group_announcement(
                    group_id, username, text, message_id=message_id):
                self.server.guarded_send(ssock, "error", "群公告设置失败")
                return
            # 公告本体落永久历史（fetch_history 可拉取）
            self.server.db.save_message_history(
                username, "", "group_announcement", text.encode("utf-8"),
                group_id=group_id, message_id=message_id)
            # 离线成员副本（message_id=f"{id}_{成员}"，补发剥离后缀还原）
            for member in self.server.db.get_group_members(group_id):
                if member != username:
                    self.server.db.save_offline_message(
                        username, member, "group_announcement",
                        text.encode("utf-8"),
                        message_id=f"{message_id}_{member}",
                        group_id=group_id)
            confirm = "群公告已清除" if text == "" else "群公告已更新"
            self.server.guarded_send(ssock, "chat", confirm)
            self.notify_group_members(group_id, "group_announcement", text,
                                      from_user=username,
                                      extra_headers={"message_id": message_id})
            for member in self.server.db.get_group_members(group_id):
                self.server.broadcast_to_user(
                    member, "list_groups", self.server.group_list_json(member))
            # 阶段 N7：群组治理敏感操作，成功即落库（清除 detail 为空）
            self.server.db.record_audit_log(
                username, "group_announcement", info["group_name"], detail=text)
            logging.info(f"群公告已更新: 群组={group_id}, 操作者={username}, "
                         f"清除={text == ''}")

        elif msg_type == "pin_group_message":
            # 阶段 O2（群置顶）：群主置顶本群消息（新增语义，区别于 K1 会话置顶）；
            # 2026-08-31 修订：允许多条并存，重复置顶同一消息幂等成功
            try:
                group_id = int(header.get("group_id"))
            except (ValueError, TypeError):
                self.server.guarded_send(ssock, "error", "无效的群组ID")
                return
            message_id = header.get("message_id") or ""
            info = self.server.db.get_group_info(group_id)
            if not info:
                self.server.guarded_send(ssock, "error", f"群组 {group_id} 不存在")
                return
            if info["created_by"] != username:
                self.server.guarded_send(ssock, "error", "只有群主可以置顶群消息")
                return
            if not self.server.db.pin_group_message(group_id, username, message_id):
                self.server.guarded_send(
                    ssock, "error", "置顶失败：消息不存在、不属于该群或已被撤回")
                return
            self.server.guarded_send(ssock, "chat", "已置顶群消息")
            for member in self.server.db.get_group_members(group_id):
                self.server.broadcast_to_user(
                    member, "list_groups", self.server.group_list_json(member))
            logging.info(f"群消息已置顶: 群组={group_id}, 操作者={username}, "
                         f"消息ID={message_id}")

        elif msg_type == "unpin_group_message":
            # 阶段 O2（群置顶）：群主取消置顶（未置顶时幂等成功）。
            # 2026-08-31 修订（多置顶并存）：header message_id 非空时仅取消
            # 该条，缺省取消全部置顶。
            try:
                group_id = int(header.get("group_id"))
            except (ValueError, TypeError):
                self.server.guarded_send(ssock, "error", "无效的群组ID")
                return
            message_id = header.get("message_id") or None
            info = self.server.db.get_group_info(group_id)
            if not info:
                self.server.guarded_send(ssock, "error", f"群组 {group_id} 不存在")
                return
            if info["created_by"] != username:
                self.server.guarded_send(ssock, "error", "只有群主可以取消置顶")
                return
            ok, removed = self.server.db.unpin_group_message(
                group_id, username, message_id=message_id)
            self.server.guarded_send(ssock, "chat", "已取消置顶群消息")
            if removed:
                for member in self.server.db.get_group_members(group_id):
                    self.server.broadcast_to_user(
                        member, "list_groups", self.server.group_list_json(member))
            logging.info(f"群置顶已取消: 群组={group_id}, 操作者={username}, "
                         f"消息ID={message_id or '全部'}, 移除={removed}")

        elif msg_type == "list_group_announcements":
            # 阶段 O1 公告管理（2026-08-30 用户反馈 #2）：查看全部公告历史
            # （群成员均可查看）
            try:
                group_id = int(header.get("group_id"))
            except (ValueError, TypeError):
                self.server.guarded_send(ssock, "error", "无效的群组ID")
                return
            if not self.server.db.is_group_member(group_id, username):
                self.server.guarded_send(ssock, "error", "您不在此群组中")
                return
            entries = self.server.db.list_group_announcements(group_id)
            self.server.guarded_send(ssock, "announcements_list_response",
                                     json.dumps(entries),
                                     extra_headers={"group_id": str(group_id)})
            logging.info(f"群公告历史查询: 用户={username}, 群组={group_id}, "
                         f"共 {len(entries)} 条")

        elif msg_type == "delete_group_announcement":
            # 阶段 O1 公告管理（2026-08-30 用户反馈 #2）：群主选择性删除公告；
            # 删除的是当前公告时同步清空横幅并广播 list_groups 刷新
            try:
                group_id = int(header.get("group_id"))
            except (ValueError, TypeError):
                self.server.guarded_send(ssock, "error", "无效的群组ID")
                return
            message_id = header.get("message_id") or ""
            info = self.server.db.get_group_info(group_id)
            if not info:
                self.server.guarded_send(ssock, "error", f"群组 {group_id} 不存在")
                return
            if info["created_by"] != username:
                self.server.guarded_send(ssock, "error", "只有群主可以删除群公告")
                return
            ok, cleared_current = self.server.db.delete_group_announcement(
                group_id, username, message_id)
            if not ok:
                self.server.guarded_send(ssock, "error", "公告不存在或删除失败")
                return
            self.server.guarded_send(ssock, "chat", "公告已删除")
            # 2026-08-31 用户反馈（R-O12）：删除公告须全端同步——向全体成员
            # 广播 announcement_deleted 推送（header group_id + message_id），
            # 客户端据此移除横幅条目与聊天流中的该公告气泡（离线成员重登时
            # 经公告历史拉取对账自愈）
            for member in self.server.db.get_group_members(group_id):
                self.server.broadcast_to_user(
                    member, "announcement_deleted", "",
                    extra_headers={"group_id": str(group_id),
                                   "message_id": message_id})
            if cleared_current:
                for member in self.server.db.get_group_members(group_id):
                    self.server.broadcast_to_user(
                        member, "list_groups", self.server.group_list_json(member))
            logging.info(f"群公告已删除: 群组={group_id}, 操作者={username}, "
                         f"消息ID={message_id}, 清除当前公告={cleared_current}")

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
            self.server.guarded_send(ssock, "list_groups",
                                     self.server.group_list_json(username))
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
            # 阶段 L 多端前置：该成员在其它设备已接受/拒绝过此群组文件 →
            # 提示"该文件已在XXX被接受/拒绝"，而非"群组文件请求不存在"
            prior = self.server.db.get_file_resolution(message_id, username)
            if prior:
                prior_action, prior_device = prior
                action_text = "接受" if prior_action == "accept" else "拒绝"
                device_name = prior_device or "default"
                self.server.guarded_send(
                    ssock, "error", f"该文件已在{device_name}被{action_text}")
                logging.info(f"群组文件响应重复: 用户={username}, 消息ID={message_id}, "
                             f"已在设备 {device_name} 被{action_text}")
                return
            file_request = self.server.db.get_group_file_request(message_id)
            if not file_request:
                self.server.guarded_send(ssock, "error", f"群组文件请求 {message_id} 不存在")
                logging.warning(f"群组文件响应失败: 消息ID={message_id} 不存在")
                return
            group_id_db, sender, filename, filesize, file_data, file_path, status = file_request
            if status == 'recalled':
                # 阶段 K 缺陷修复（P-59）：文件已被发送者撤回——提示"对方已撤回"，
                # 而非"文件不存在"
                self.server.guarded_send(ssock, "error", "对方已撤回该文件，无法接收")
                logging.info(f"群组文件响应失败: 消息ID={message_id} 已被撤回，用户={username}")
                return
            if int(group_id) != group_id_db:
                self.server.guarded_send(ssock, "error", "无效的群组ID")
                logging.warning(f"群组文件响应失败: 用户 {username} 提供无效的群组ID {group_id}")
                return
            if not self.server.db.is_group_member(group_id, username):
                self.server.guarded_send(ssock, "error", "您不在此群组中")
                logging.warning(f"群组文件响应失败: 用户 {username} 不在群组 {group_id} 中")
                return
            self.server.db.save_group_file_response(message_id, group_id, username, response)
            # 阶段 L 多端前置：记录响应设备，供该成员其他设备提示"该文件已在XXX被接受/拒绝"
            self.server.db.record_file_resolution(
                message_id, username, response,
                self.server.device_id_of(ssock))
            if response == "accept":
                # 大文件：把待处理文件转入历史区（原子 rename），DB 存路径
                history_path = (self.server.db.promote_file_to_history(file_path, message_id)
                                if file_path else None)
                if history_path:
                    file_data = b''
                self.server.db.save_offline_message(sender, username, "file", file_data, filename=filename, message_id=message_id, file_path=history_path, group_id=group_id_db)
                self.server.db.save_message_history(sender, username, "file", file_data, filename=filename, message_id=message_id, file_path=history_path, group_id=group_id_db)
                # 阶段 L1：群文件送达接受者所有在线会话
                # 阶段 M8（P1-5）：推送携带 sha256（接收方校验依据）
                # 阶段 N3b 修复：推送携带 group_id——接收方据此路由到群聊
                # （旧实现缺 group_id，群文件错落入与发送者的私聊）
                group_extras = self.server.db.get_group_file_request_extras(message_id)
                group_sha256 = (group_extras or {}).get("sha256", "")
                file_headers = {"from": sender, "filename": filename,
                                "filesize": filesize, "message_id": message_id,
                                "sha256": group_sha256,
                                "group_id": str(group_id_db)}
                for u_sock in self.server.sessions_of(username):
                    # P-07 修复：长文件推送前引用接收方 socket——
                    # 推送期间接收方会话被关闭时 fd 不被释放（延迟关闭），
                    # 杜绝 SSL 字节写进被 sqlite 复用 fd 的竞态。
                    # 阶段 P 修复：写锁内发送（与 guarded_send 串行）。
                    if history_path and not self.server.acquire_send_sock(u_sock):
                        continue
                    try:
                        if history_path:
                            self.server.with_sock_write(
                                u_sock,
                                lambda s=u_sock: send_file_message(
                                    s, "file", history_path,
                                    extra_headers=file_headers))
                        else:
                            self.server.guarded_send(u_sock, "file", file_data,
                                                     extra_headers=file_headers)
                        logging.info(f"群组文件已传输: {sender} -> {username}, 文件名={filename}, 消息ID={message_id}")
                    except Exception as e:
                        logging.error(f"传输群组文件失败: {sender} -> {username}, 文件名={filename}, 消息ID={message_id}, 错误={e}")
                        self.server.discard_socket(u_sock)
                    finally:
                        if history_path:
                            self.server.release_send_sock(u_sock)
            if self.server.db.all_members_responded(message_id, group_id):
                self.server.db.delete_group_file_request(message_id)
                logging.info(f"群组文件请求已删除: 消息ID={message_id}, 所有成员已响应")
            else:
                logging.info(f"群组文件请求未删除: 消息ID={message_id}, 仍有成员未响应")

        # ============================================================
        # 阶段 M1（P1-16 群主权限）
        # ============================================================

        elif msg_type == "kick_member":
            try:
                group_id = int(header.get("group_id"))
                target = (header.get("target") or "").strip()
            except (ValueError, TypeError):
                self.server.guarded_send(ssock, "error", "无效的群组ID")
                return
            info = self.server.db.get_group_info(group_id)
            if not info:
                self.server.guarded_send(ssock, "error", f"群组 {group_id} 不存在")
                return
            if info["created_by"] != username:
                self.server.guarded_send(ssock, "error", "只有群主可以移出成员")
                return
            if target == username:
                self.server.guarded_send(ssock, "error", "不能移出自己")
                return
            if info["created_by"] == target:
                self.server.guarded_send(ssock, "error", "不能移出群主")
                return
            if not self.server.db.is_group_member(group_id, target):
                self.server.guarded_send(ssock, "error", f"用户 {target} 不在群组中")
                return
            if self.server.db.kick_group_member(group_id, username, target):
                # 阶段 N7（P2-7 审计日志）：群组治理为敏感操作，成功即落库
                self.server.db.record_audit_log(
                    username, "kick_member", target, detail=info["group_name"])
                self.server.guarded_send(ssock, "chat", f"已将 {target} 移出群组")
                logging.info(f"群主 {username} 将 {target} 移出群组 {group_id}")
                # 被踢者通知（在线实时 / 离线保存）+ 群列表刷新
                notice = f"您已被群主移出群组 {info['group_name']}"
                if self.server.broadcast_to_user(target, "chat", notice,
                                                 extra_headers={"from": "系统"}):
                    logging.info(f"已通知被移出成员: {target}")
                else:
                    self.server.db.save_offline_message(
                        "系统", target, "chat", notice.encode("utf-8"),
                        message_id=str(uuid.uuid4()))
                self.server.broadcast_to_user(target, "list_groups",
                                              self.server.group_list_json(target))
                # 其余成员通知（被踢者已不在成员表，天然排除）
                self.notify_group_members(group_id, "chat",
                                          f"{target} 已被移出群组", from_user="系统")
            else:
                self.server.guarded_send(ssock, "error", "移出成员失败")

        elif msg_type == "transfer_owner":
            try:
                group_id = int(header.get("group_id"))
                target = (header.get("target") or "").strip()
            except (ValueError, TypeError):
                self.server.guarded_send(ssock, "error", "无效的群组ID")
                return
            info = self.server.db.get_group_info(group_id)
            if not info:
                self.server.guarded_send(ssock, "error", f"群组 {group_id} 不存在")
                return
            if info["created_by"] != username:
                self.server.guarded_send(ssock, "error", "只有群主可以转让群主")
                return
            if target == username:
                self.server.guarded_send(ssock, "error", "不能转让给自己")
                return
            if not self.server.db.is_group_member(group_id, target):
                self.server.guarded_send(ssock, "error", f"用户 {target} 不在群组中")
                return
            if self.server.db.transfer_group_owner(group_id, username, target):
                # 阶段 N7（P2-7 审计日志）：转让群主为敏感操作，成功即落库
                self.server.db.record_audit_log(
                    username, "transfer_owner", target, detail=info["group_name"])
                self.server.guarded_send(ssock, "chat", f"已将群主转让给 {target}")
                logging.info(f"群主已转让: {username} -> {target}, 群组={group_id}")
                # 新群主通知（在线实时 / 离线保存）
                notice = f"您已成为群组 {info['group_name']} 的群主"
                if self.server.broadcast_to_user(target, "chat", notice,
                                                 extra_headers={"from": "系统"}):
                    logging.info(f"已通知新群主: {target}")
                else:
                    self.server.db.save_offline_message(
                        "系统", target, "chat", notice.encode("utf-8"),
                        message_id=str(uuid.uuid4()))
                # 其余成员通知（排除操作者与新群主）
                for member in self.server.db.get_group_members(group_id):
                    if member in (username, target):
                        continue
                    self.server.broadcast_to_user(
                        member, "chat", f"群主已变更为 {target}",
                        extra_headers={"from": "系统"})
                # 全体成员列表刷新（客户端据此更新群主标识）
                for member in self.server.db.get_group_members(group_id):
                    self.server.broadcast_to_user(
                        member, "list_groups", self.server.group_list_json(member))
            else:
                self.server.guarded_send(ssock, "error", "转让群主失败")

        elif msg_type == "rename_group":
            try:
                group_id = int(header.get("group_id"))
            except (ValueError, TypeError):
                self.server.guarded_send(ssock, "error", "无效的群组ID")
                return
            new_name = (header.get("name") or "").strip()
            info = self.server.db.get_group_info(group_id)
            if not info:
                self.server.guarded_send(ssock, "error", f"群组 {group_id} 不存在")
                return
            if info["created_by"] != username:
                self.server.guarded_send(ssock, "error", "只有群主可以修改群组名称")
                return
            if not new_name:
                self.server.guarded_send(ssock, "error", "群组名称不能为空")
                return
            if self.server.db.rename_group(group_id, username, new_name):
                # 阶段 N7（P2-7 审计日志）：改名成功即落库（target=新名，detail=旧名）
                self.server.db.record_audit_log(
                    username, "rename_group", new_name, detail=info["group_name"])
                self.server.guarded_send(ssock, "chat", f"群组已改名为 {new_name}")
                logging.info(f"群组改名: {group_id} -> {new_name}, 操作者={username}")
                self.server.broadcast_to_user(
                    username, "list_groups", self.server.group_list_json(username))
                # 其余成员逐个：通知 + 列表刷新
                for member in self.server.db.get_group_members(group_id):
                    if member == username:
                        continue
                    self.server.broadcast_to_user(
                        member, "chat", f"群组已改名为 {new_name}",
                        extra_headers={"from": "系统"})
                    self.server.broadcast_to_user(
                        member, "list_groups", self.server.group_list_json(member))
            else:
                self.server.guarded_send(ssock, "error", "群组名称已存在或修改失败")

        elif msg_type == "set_group_avatar":
            try:
                group_id = int(header.get("group_id"))
            except (ValueError, TypeError):
                self.server.guarded_send(ssock, "error", "无效的群组ID")
                return
            avatar = header.get("avatar") or ""
            info = self.server.db.get_group_info(group_id)
            if not info:
                self.server.guarded_send(ssock, "error", f"群组 {group_id} 不存在")
                return
            if info["created_by"] != username:
                self.server.guarded_send(ssock, "error", "只有群主可以设置群头像")
                return
            if self.server.db.set_group_avatar(group_id, username, avatar):
                self.server.guarded_send(ssock, "chat", "群头像已更新")
                logging.info(f"群头像已更新: 群组={group_id}, 操作者={username}")
                # 全体成员列表刷新（携带 avatar）
                for member in self.server.db.get_group_members(group_id):
                    self.server.broadcast_to_user(
                        member, "list_groups", self.server.group_list_json(member))
            else:
                self.server.guarded_send(ssock, "error", "设置群头像失败")

        # ============================================================
        # 阶段 M3（P1-18 新成员历史可见性）
        # ============================================================

        elif msg_type == "set_group_history_visible":
            try:
                group_id = int(header.get("group_id"))
                visible = header.get("visible", "1")
                limit = int(header.get("limit", "50") or "50")
            except (ValueError, TypeError):
                self.server.guarded_send(ssock, "error", "无效的群组ID")
                return
            info = self.server.db.get_group_info(group_id)
            if not info:
                self.server.guarded_send(ssock, "error", f"群组 {group_id} 不存在")
                return
            if info["created_by"] != username:
                self.server.guarded_send(ssock, "error", "只有群主可以设置历史可见性")
                return
            if visible not in ("0", "1"):
                self.server.guarded_send(ssock, "error", "无效的历史可见性设置")
                return
            if self.server.db.set_group_history_visibility(
                    group_id, username, visible == "1", limit):
                state_text = "开启" if visible == "1" else "关闭"
                self.server.guarded_send(
                    ssock, "chat",
                    f"已设置群组历史可见性：{state_text}（新成员可见最近 {limit} 条）")
                logging.info(f"群组历史可见性已设置: 群组={group_id}, "
                             f"visible={visible}, limit={limit}")
                # 全体成员 list_groups 刷新（携带 history_visible/history_limit，
                # 客户端开关状态据此同步——否则开关一直显示旧值，缺陷修复）
                for member in self.server.db.get_group_members(group_id):
                    self.server.broadcast_to_user(
                        member, "list_groups", self.server.group_list_json(member))
            else:
                self.server.guarded_send(ssock, "error", "设置历史可见性失败")

        # ============================================================
        # 阶段 M2（P1-17 入群审批/邀请制）
        # ============================================================

        elif msg_type == "approve_join_request":
            try:
                group_id = int(header.get("group_id"))
                target = (header.get("target") or "").strip()
            except (ValueError, TypeError):
                self.server.guarded_send(ssock, "error", "无效的群组ID")
                return
            info = self.server.db.get_group_info(group_id)
            if not info:
                self.server.guarded_send(ssock, "error", f"群组 {group_id} 不存在")
                return
            if info["created_by"] != username:
                self.server.guarded_send(ssock, "error", "只有群主可以审批入群申请")
                return
            if not self.server.db.has_pending_group_join_request(group_id, target):
                self.server.guarded_send(ssock, "error", f"没有来自 {target} 的入群申请")
                return
            if self.server.db.approve_join_request(group_id, username, target):
                self.server.guarded_send(ssock, "chat", f"已批准 {target} 加入群组")
                logging.info(f"入群申请已批准: {target} -> 群组 {group_id}")
                # 被批准者通知（在线实时 / 离线保存）+ 群列表刷新
                notice = f"您已加入群组 {info['group_name']}（ID:{group_id}）"
                if self.server.broadcast_to_user(target, "chat", notice,
                                                 extra_headers={"from": "系统"}):
                    logging.info(f"已通知被批准者: {target}")
                else:
                    self.server.db.save_offline_message(
                        "系统", target, "chat", notice.encode("utf-8"),
                        message_id=str(uuid.uuid4()))
                self.server.broadcast_to_user(target, "list_groups",
                                              self.server.group_list_json(target))
                # 其余成员通知（排除操作者与被批准者）
                for member in self.server.db.get_group_members(group_id):
                    if member in (username, target):
                        continue
                    self.server.broadcast_to_user(
                        member, "chat", f"{target} 已加入群组",
                        extra_headers={"from": "系统"})
            else:
                self.server.guarded_send(ssock, "error", "批准入群申请失败")

        elif msg_type == "reject_join_request":
            try:
                group_id = int(header.get("group_id"))
                target = (header.get("target") or "").strip()
            except (ValueError, TypeError):
                self.server.guarded_send(ssock, "error", "无效的群组ID")
                return
            info = self.server.db.get_group_info(group_id)
            if not info:
                self.server.guarded_send(ssock, "error", f"群组 {group_id} 不存在")
                return
            if info["created_by"] != username:
                self.server.guarded_send(ssock, "error", "只有群主可以拒绝入群申请")
                return
            if not self.server.db.has_pending_group_join_request(group_id, target):
                self.server.guarded_send(ssock, "error", f"没有来自 {target} 的入群申请")
                return
            if self.server.db.reject_join_request(group_id, username, target):
                self.server.guarded_send(ssock, "chat", f"已拒绝 {target} 的入群申请")
                logging.info(f"入群申请已拒绝: {target} -> 群组 {group_id}")
                notice = "您的入群申请已被拒绝"
                if self.server.broadcast_to_user(target, "chat", notice,
                                                 extra_headers={"from": "系统"}):
                    logging.info(f"已通知被拒者: {target}")
                else:
                    self.server.db.save_offline_message(
                        "系统", target, "chat", notice.encode("utf-8"),
                        message_id=str(uuid.uuid4()))
            else:
                self.server.guarded_send(ssock, "error", "拒绝入群申请失败")

        elif msg_type == "invite_group_member":
            try:
                group_id = int(header.get("group_id"))
                target = (header.get("target") or "").strip()
            except (ValueError, TypeError):
                self.server.guarded_send(ssock, "error", "无效的群组ID")
                return
            info = self.server.db.get_group_info(group_id)
            if not info:
                self.server.guarded_send(ssock, "error", f"群组 {group_id} 不存在")
                return
            if not self.server.db.is_group_member(group_id, username):
                self.server.guarded_send(ssock, "error", "您不在此群组中")
                return
            if not self.server.db.user_exists(target):
                self.server.guarded_send(ssock, "error", f"用户 {target} 不存在")
                return
            if self.server.db.is_group_member(group_id, target):
                self.server.guarded_send(ssock, "error", "该用户已在群组中")
                return
            if not self.server.db.invite_group_member(group_id, username, target):
                self.server.guarded_send(ssock, "error", "已向该用户发送过邀请")
                return
            self.server.guarded_send(ssock, "chat", f"已邀请 {target} 加入群组")
            logging.info(f"群邀请: {username} 邀请 {target} 加入群组 {group_id}")
            # 被邀请者：在线实时推送 group_invite（含群名）；
            # 离线不存文本通知——邀请持久化于 group_invitations 表，
            # 登录时由 load_offline_data 补发 group_invite（P-11 用户反馈：
            # 邀请像好友申请一样保留入口，离线可接收）
            invite_headers = {"from": username, "group_id": str(group_id),
                              "group_name": info["group_name"]}
            self.server.broadcast_to_user(target, "group_invite", "",
                                          extra_headers=invite_headers)

        elif msg_type == "accept_group_invite":
            try:
                group_id = int(header.get("group_id"))
            except (ValueError, TypeError):
                self.server.guarded_send(ssock, "error", "无效的群组ID")
                return
            info = self.server.db.get_group_info(group_id)
            if not info:
                self.server.guarded_send(ssock, "error", f"群组 {group_id} 不存在")
                return
            if not self.server.db.accept_group_invite(group_id, username):
                self.server.guarded_send(ssock, "error", "没有来自该群组的邀请")
                return
            self.server.guarded_send(ssock, "chat", f"已加入群组 {info['group_name']}")
            logging.info(f"群邀请已接受: {username} 加入群组 {group_id}")
            self.server.broadcast_to_user(username, "list_groups",
                                          self.server.group_list_json(username))
            # 其余成员通知（排除接受者）
            for member in self.server.db.get_group_members(group_id):
                if member == username:
                    continue
                self.server.broadcast_to_user(
                    member, "chat", f"{username} 已加入群组",
                    extra_headers={"from": "系统"})

        elif msg_type == "decline_group_invite":
            try:
                group_id = int(header.get("group_id"))
            except (ValueError, TypeError):
                self.server.guarded_send(ssock, "error", "无效的群组ID")
                return
            if not self.server.db.get_group_info(group_id):
                self.server.guarded_send(ssock, "error", f"群组 {group_id} 不存在")
                return
            if not self.server.db.decline_group_invite(group_id, username):
                self.server.guarded_send(ssock, "error", "没有来自该群组的邀请")
                return
            self.server.guarded_send(ssock, "chat", "已拒绝邀请")
            logging.info(f"群邀请已拒绝: {username} 拒绝群组 {group_id}")

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
                # 阶段 L1：群消息到达成员所有在线会话（会话级推送）
                delivered = self.server.broadcast_to_user(
                    member, msg_type, message,
                    extra_headers={"from": from_user, "group_id": str(group_id), **extra_headers})
                if delivered:
                    logging.info(f"向 {member} 发送群组消息: 类型={msg_type}, 群组ID={group_id}")
                    # 在线成员已实时收到，标记 offline_messages 为 delivered 避免下次登录误计未读
                    msg_id = extra_headers.get("message_id")
                    if msg_id:
                        self.server.db.update_message_status(f"{msg_id}_{member}", 'delivered')
        except Exception as e:
            logging.error(f"通知群组 {group_id} 成员失败: {e}")