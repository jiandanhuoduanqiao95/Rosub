import json
import logging
from protocol import send_message

class AdminHandler:
    def __init__(self, server):
        self.server = server

    def handle_admin_command(self, username, ssock, header, data):
        """处理管理员命令"""
        if not self.server.db.get_user(username)[1]:
            send_message(ssock, "error", "无管理员权限")
            logging.warning(f"管理员命令失败: 用户 {username} 无权限")
            return
        command = header.get("action")
        if command == "list_users":
            users = self.server.db.get_all_users()
            with self.server.client_map_lock:
                users_list = [[user, user in self.server.client_map, is_admin] for user, is_admin in users]
            send_message(ssock, "admin_response", json.dumps(users_list), extra_headers={"response_type": "list_users"})
            logging.info(f"列出所有用户: 用户={username}")
        elif command == "delete_user":
            target_user = data.decode("utf-8").strip()
            if self.server.db.delete_user(target_user):
                users = self.server.db.get_all_users()
                with self.server.client_map_lock:
                    users_list = [[user, user in self.server.client_map, is_admin] for user, is_admin in users]
                send_message(ssock, "admin_response", json.dumps(users_list),
                             extra_headers={"response_type": "list_users", "action_result": f"删除用户 {target_user} 成功"})
                logging.info(f"管理员 {username} 删除用户: {target_user}")
                # 通知被删除的用户（如果在线）
                with self.server.client_map_lock:
                    target_socket = self.server.client_map.get(target_user)
                    if target_socket:
                        try:
                            send_message(target_socket, "error", "您的账户已被管理员删除")
                            logging.info(f"通知用户 {target_user} 账户被删除")
                            target_socket.close()
                            self.server.client_map.pop(target_user, None)
                        except Exception as e:
                            logging.error(f"通知用户 {target_user} 失败: {e}")
                            self.server.client_map.pop(target_user, None)
            else:
                send_message(ssock, "error", f"删除用户 {target_user} 失败")
                logging.error(f"删除用户失败: {target_user}")
        elif command == "announcement":
            announcement_msg = data.decode("utf-8").strip()
            with self.server.client_map_lock:
                invalid_clients = []
                for user, sock in self.server.client_map.items():
                    try:
                        send_message(sock, "chat", announcement_msg,
                                     extra_headers={"from": "[系统公告]"})
                        logging.info(f"向用户 {user} 发送公告")
                    except Exception as e:
                        logging.error(f"向用户 {user} 发送公告失败: {e}")
                        invalid_clients.append(user)
                for user in invalid_clients:
                    self.server.client_map.pop(user, None)
                send_message(ssock, "chat", "公告发送成功")
                logging.info(f"管理员 {username} 发送公告成功")
        elif command == "exit":
            send_message(ssock, "admin_response", "退出成功")
            logging.info(f"管理员 {username} 退出")