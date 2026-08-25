import json
import logging
import socket
import bcrypt
from protocol import send_message
from validation import validate_password

class AdminHandler:
    def __init__(self, server):
        self.server = server

    def handle_admin_command(self, username, ssock, header, data):
        """处理管理员命令"""
        user_data = self.server.db.get_user(username)
        if not user_data or not user_data[1]:
            self.server.guarded_send(ssock, "error", "无管理员权限")
            logging.warning(f"管理员命令失败: 用户 {username} 无权限")
            return
        command = header.get("action")
        if command == "list_users":
            users = self.server.db.get_all_users()
            # has_any_session 内部取锁（非重入锁，此处不得再持锁）
            users_list = [[user, self.server.has_any_session(user), bool(is_admin)] for user, is_admin in users]
            self.server.guarded_send(ssock, "admin_response", json.dumps(users_list), extra_headers={"response_type": "list_users"})
            logging.info(f"列出所有用户: 用户={username}")
        elif command == "delete_user":
            target_user = data.decode("utf-8").strip()
            if target_user == username:
                self.server.guarded_send(ssock, "error", "不能删除当前登录的管理员账号")
                logging.warning(f"管理员 {username} 尝试删除自己的账号")
                return
            if self.server.db.delete_user(target_user):
                users = self.server.db.get_all_users()
                # has_any_session 内部取锁（非重入锁，此处不得再持锁）
                users_list = [[user, self.server.has_any_session(user), bool(is_admin)] for user, is_admin in users]
                self.server.guarded_send(ssock, "admin_response", json.dumps(users_list),
                             extra_headers={"response_type": "list_users", "action_result": f"删除用户 {target_user} 成功"})
                logging.info(f"管理员 {username} 删除用户: {target_user}")
                # 通知被删除的用户（如果在线）——锁外发送（guarded_send 需取锁）
                # 阶段 L1：强制下线该用户所有在线会话
                for target_socket in self.server.sessions_of(target_user):
                    try:
                        self.server.guarded_send(target_socket, "error", "您的账户已被管理员删除")
                        logging.info(f"通知用户 {target_user} 账户被删除")
                    except Exception as e:
                        logging.error(f"通知用户 {target_user} 失败: {e}")
                    # shutdown 唤醒阻塞在 recv 的目标线程（P-07 修复：不 close——
                    # close 释放 fd 与并发发送竞态会把 SSL 字节写进数据库文件），
                    # 由 handle_client 的 finally 在锁内清理并关闭
                    try:
                        target_socket.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
            else:
                self.server.guarded_send(ssock, "error", f"删除用户 {target_user} 失败")
                logging.error(f"删除用户失败: {target_user}")
        elif command == "announcement":
            announcement_msg = data.decode("utf-8").strip()
            # 获取所有用户列表，用于离线用户持久化
            all_users = self.server.db.get_all_users()
            all_usernames = [u[0] for u in all_users]
            online_users = set()
            # 阶段 L1：遍历所有在线会话（多设备并存），按用户名聚合在线集合
            with self.server.client_map_lock:
                sessions = list(self.server.client_map.items())
            for (user, _device), sock in sessions:
                try:
                    self.server.guarded_send(sock, "chat", announcement_msg,
                                 extra_headers={"from": "[系统公告]"})
                    online_users.add(user)
                    logging.info(f"向用户 {user} 发送公告")
                except Exception as e:
                    logging.error(f"向用户 {user} 发送公告失败: {e}")
                    self.server.discard_socket(sock)
            # 对离线用户保存离线公告消息，上线后可见
            import uuid as _uuid
            for username in all_usernames:
                if username not in online_users:
                    ann_msg_id = str(_uuid.uuid4())
                    self.server.db.save_offline_message(
                        "[系统公告]", username, "chat", announcement_msg.encode('utf-8'),
                        message_id=ann_msg_id)
                    self.server.db.save_message_history(
                        "[系统公告]", username, "chat", announcement_msg.encode('utf-8'),
                        message_id=str(_uuid.uuid4()))
                    logging.info(f"离线用户 {username} 的公告已持久化")
            self.server.guarded_send(ssock, "chat", "公告发送成功")
            logging.info(f"管理员 {username} 发送公告成功")
        elif command == "exit":
            self.server.guarded_send(ssock, "admin_response", "退出成功")
            logging.info(f"管理员 {username} 退出")
        elif command == "server_status":
            # 服务端状态面板（阶段 M4：P1-19）
            status = self.server.get_server_status()
            self.server.guarded_send(ssock, "admin_response", json.dumps(status),
                         extra_headers={"response_type": "server_status"})
            logging.info(f"服务端状态查询: 管理员={username}, "
                         f"在线用户={status['online_users']}, "
                         f"文件占用={status['storage']['file_store_bytes']} 字节")
        elif command == "storage_cleanup":
            # 存储治理（阶段 M6：P1-21）：过期文件/已读消息清理
            try:
                days_file = int(header.get("days_file", "")) if header.get("days_file") else None
            except (TypeError, ValueError):
                days_file = None
            try:
                days_delivered = int(header.get("days_delivered", "")) if header.get("days_delivered") else None
            except (TypeError, ValueError):
                days_delivered = None
            result = self.server.run_storage_cleanup(
                days_file=days_file if days_file is not None else 7,
                days_delivered=days_delivered if days_delivered is not None else 30)
            self.server.guarded_send(ssock, "admin_response", json.dumps(result),
                         extra_headers={"response_type": "storage_cleanup"})
            logging.info(f"存储清理执行: 管理员={username}, 结果={result}")
        elif command == "reset_password":
            # 管理员重置密码（阶段 J：P0-5）
            target_user = data.decode("utf-8").strip()
            new_password = header.get("new_password") or ""
            valid, error = validate_password(new_password)
            if not valid:
                self.server.guarded_send(ssock, "error", error)
                logging.warning(f"重置密码失败: 管理员={username}, 目标={target_user}, 新密码格式不合法: {error}")
                return
            if not self.server.db.user_exists(target_user):
                self.server.guarded_send(ssock, "error", f"用户 {target_user} 不存在")
                logging.warning(f"重置密码失败: 管理员={username}, 目标={target_user} 不存在")
                return
            new_hash = bcrypt.hashpw(new_password.encode('utf-8'), bcrypt.gensalt())
            if self.server.db.admin_reset_password(target_user, new_hash):
                # 先回执管理员（若目标即管理员本人，后续关闭其会话不丢回执）
                self.server.guarded_send(ssock, "admin_response",
                             f"已将用户 {target_user} 的密码重置",
                             extra_headers={"response_type": "reset_password"})
                logging.info(f"管理员 {username} 重置用户 {target_user} 密码成功")
                # 通知在线目标用户并强制下线：密码已失效的旧会话立即关闭，
                    # 防止其继续以旧凭据收发消息（阶段 J 修复）。shutdown 唤醒
                    # 阻塞在 recv 的目标线程（P-07 修复：不 close——close 释放
                    # fd 与并发发送竞态会把 SSL 字节写进数据库文件），由
                    # handle_client 的 finally 清理 client_map / transfer_sockets
                    # 并广播 presence 下线。阶段 L1：强制下线该用户所有在线会话。
                for target_socket in self.server.sessions_of(target_user):
                    try:
                        self.server.guarded_send(target_socket, "chat",
                                     "您的密码已被管理员重置，请重新登录",
                                     extra_headers={"from": "系统"})
                        logging.info(f"已通知用户 {target_user} 密码被管理员重置")
                    except Exception as e:
                        logging.error(f"通知用户 {target_user} 密码被重置失败: {e}")
                    try:
                        target_socket.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
                    logging.info(f"强制下线用户 {target_user}（密码已被管理员重置）")
            else:
                self.server.guarded_send(ssock, "error", f"重置用户 {target_user} 密码失败")
                logging.error(f"管理员 {username} 重置用户 {target_user} 密码失败")
