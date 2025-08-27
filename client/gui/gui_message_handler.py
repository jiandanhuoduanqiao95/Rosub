import tkinter as tk
from tkinter import ttk, messagebox, filedialog
import socket
import ssl
import os
import threading
from protocol import send_message, recv_message
import json
import uuid
import logging

class MessageHandler:
    def __init__(self, client_gui):
        self.client_gui = client_gui

    def listen_for_messages(self):
        while True:
            try:
                header, data = recv_message(self.client_gui.ssock)
                if header is None:
                    self.client_gui.chat_ui.update_status("服务器连接已断开")
                    self.client_gui.root.after(0, self.client_gui.logout)
                    break
                self.process_message(header, data)
            except ssl.SSLError as e:
                logging.error(f"SSL错误: {str(e)}")
                self.client_gui.chat_ui.update_status(f"SSL错误: {str(e)}")
                self.client_gui.root.after(0, self.client_gui.logout)
                break
            except Exception as e:
                logging.error(f"接收消息错误: {str(e)}")
                self.client_gui.chat_ui.update_status(f"接收错误: {str(e)}")
                self.client_gui.root.after(0, self.client_gui.chat_ui.append_chat, "服务器", f"接收错误: {str(e)}")
                continue

    def process_message(self, header, data):
        msg_type = header.get("type")
        message_id = header.get("message_id", "")
        logging.info(f"处理消息: 类型={msg_type}, 消息ID={message_id}, 头信息={header}")
        if msg_type == "file_request":
            sender = header.get("from", "未知用户")
            filename = header.get("filename", "unknown_file")
            filesize = header.get("filesize", "未知大小")
            self.client_gui.chat_ui.append_chat("服务器", f"收到文件传输请求: {sender} 希望发送文件 {filename} ({filesize} bytes)")
            threading.Thread(target=self.handle_file_request, args=(sender, filename, filesize, message_id), daemon=True).start()
        elif msg_type == "group_file_request":
            sender = header.get("from", "未知用户")
            filename = header.get("filename", "unknown_file")
            filesize = header.get("filesize", "未知大小")
            group_id = header.get("group_id")
            group_name = self.client_gui.group_list.get(group_id, f"群组 {group_id}")
            if message_id in self.client_gui.processed_group_file_requests:
                logging.info(f"跳过已处理的群组文件请求: 消息ID={message_id}")
                return
            self.client_gui.processed_group_file_requests.add(message_id)
            self.client_gui.chat_ui.append_chat(f"群组 {group_id}", f"收到群组文件传输请求: {sender} 希望发送文件 {filename} ({filesize} bytes)", tag=f"clickable_message_{message_id}")
            threading.Thread(target=self.handle_group_file_request, args=(sender, filename, filesize, message_id, group_id), daemon=True).start()
        elif msg_type in ("chat", "file"):
            if "history" in header and message_id in self.client_gui.message_lines:
                logging.info(f"跳过重复历史消息: 消息ID={message_id}")
                return
            sender = header.get("from", "服务器")
            tag = "[历史]" if "history" in header else ""
            status = "delivered" if sender != "服务器" and sender != "[系统公告]" else ""
            if msg_type == "chat":
                try:
                    msg = data.decode()
                    if sender == "服务器" or sender == "[系统公告]":
                        tag_name = "announcement" if sender == "[系统公告]" else None
                        self.client_gui.chat_ui.append_chat("服务器", f"{tag}{sender}: {msg}", tag=tag_name)
                        if sender == "[系统公告]":
                            self.client_gui.root.after(0, lambda: self.client_gui.chat_ui.switch_chat_window("服务器"))
                            self.client_gui.root.after(0, lambda: messagebox.showinfo("系统公告", f"收到新公告: {msg}"))
                    else:
                        self.client_gui.message_status[message_id] = status
                        self.client_gui.chat_ui.append_chat(sender, f"{tag}{sender}: {msg} [{status}] ({message_id})", tag=f"clickable_message_{message_id}")
                        if message_id and "history" not in header:
                            try:
                                send_message(self.client_gui.ssock, "receipt", "", extra_headers={"message_id": message_id, "to": sender})
                                logging.info(f"发送回执: 消息ID={message_id}, 目标={sender}")
                            except Exception as e:
                                self.client_gui.chat_ui.append_chat(sender, f"发送回执失败: {message_id} ({str(e)})")
                                logging.error(f"发送回执失败: 消息ID={message_id}, 错误={str(e)}")
                except UnicodeDecodeError:
                    logging.error(f"消息解码失败: 发送者={sender}, 消息ID={message_id}")
                    self.client_gui.chat_ui.append_chat("服务器", f"消息解码失败: {message_id}")
            elif msg_type == "file":
                filename = header.get("filename", "unknown_file")
                file_path = f"files/recv_{filename}"
                os.makedirs("files", exist_ok=True)
                with open(file_path, 'wb') as f:
                    f.write(data)
                self.client_gui.message_status[message_id] = status
                self.client_gui.chat_ui.append_chat(sender, f"{tag}{sender}: 收到文件: {filename}，已保存至 {file_path} [{status}] ({message_id})", tag=f"clickable_message_{message_id}")
                if message_id and "history" not in header:
                    try:
                        send_message(self.client_gui.ssock, "receipt", "", extra_headers={"message_id": message_id, "to": sender})
                        logging.info(f"发送回执: 消息ID={message_id}, 目标={sender}")
                    except Exception as e:
                        self.client_gui.chat_ui.append_chat(sender, f"发送回执失败: {message_id} ({str(e)})")
                        logging.error(f"发送回执失败: 消息ID={message_id}, 错误={str(e)}")
        elif msg_type == "status_update":
            message_id = header.get("message_id")
            status = header.get("status")
            if message_id in self.client_gui.message_status:
                self.client_gui.message_status[message_id] = status
                self.update_message_status_in_chat(message_id, status)
                logging.info(f"消息状态更新: {message_id} -> {status} (发送者: {self.client_gui.username})")
            else:
                logging.warning(f"状态更新失败: 消息ID={message_id} 不存在")
        elif msg_type == "friend_request":
            sender = header.get("from")
            self.client_gui.chat_ui.append_chat("服务器", f"收到好友请求: {sender}")
        elif msg_type == "list_friend_requests":
            try:
                requests = json.loads(data.decode())
                self.show_friend_requests(requests)
            except json.JSONDecodeError:
                self.client_gui.chat_ui.append_chat("服务器", "解析好友请求列表失败")
                logging.error("解析好友请求列表失败")
        elif msg_type == "admin_response":
            response_type = header.get("response_type")
            if response_type == "list_users":
                try:
                    users = json.loads(data.decode())
                    self.client_gui.admin_ui.show_users(users)
                except json.JSONDecodeError:
                    self.client_gui.chat_ui.append_chat("服务器", "解析用户列表失败")
                    logging.error("解析用户列表失败")
            elif response_type == "list_friends":
                try:
                    friends = json.loads(data.decode())
                    for item in self.client_gui.chat_ui.user_list.get_children():
                        self.client_gui.chat_ui.user_list.delete(item)
                    for friend, online in friends:
                        status = "在线" if online else "离线"
                        self.client_gui.chat_ui.user_list.insert("", "end", values=(friend, status))
                    if header.get("action_result"):
                        self.client_gui.chat_ui.append_chat("服务器", header.get("action_result"))
                except json.JSONDecodeError:
                    self.client_gui.chat_ui.append_chat("服务器", "解析好友列表失败")
                    logging.error("解析好友列表失败")
        elif msg_type == "recall":
            sender = header.get("from", "未知用户")
            message_id = header.get("message_id")
            group_id = header.get("group_id")
            if group_id:
                group_name = self.client_gui.group_list.get(group_id, f"群组 {group_id}")
                chat_window_name = f"群组 {group_id}"
                # Update all variant message IDs for group messages
                self.update_message_status_in_chat(message_id, "recalled", sender, chat_window_name)
            else:
                self.update_message_status_in_chat(message_id, "recalled", sender)
        elif msg_type == "list_groups":
            try:
                groups = json.loads(data.decode())
                self.client_gui.group_list = {str(g["id"]): g["group_name"] for g in groups}
                for item in self.client_gui.chat_ui.user_list.get_children():
                    if item.startswith("group_"):
                        self.client_gui.chat_ui.user_list.delete(item)
                for group in groups:
                    group_id = str(group["id"])
                    group_name = group["group_name"]
                    self.client_gui.chat_ui.user_list.insert("", "end", values=(f"群组 {group_id}", ""), iid=f"group_{group_id}")
                self.client_gui.chat_ui.append_chat("服务器", "群组列表已更新")
            except json.JSONDecodeError:
                self.client_gui.chat_ui.append_chat("服务器", "解析群组列表失败")
                logging.error("解析群组列表失败")
        elif msg_type == "group_chat":
            sender = header.get("from", "未知用户")
            group_id = header.get("group_id")
            group_name = self.client_gui.group_list.get(group_id, f"群组 {group_id}")
            if sender == self.client_gui.username and "history" not in header:
                logging.info(f"跳过显示自己刚发送的群组消息: 消息ID={message_id}")
                return
            try:
                msg = data.decode()
                tag = "[历史]" if "history" in header else ""
                chat_window_name = f"群组 {group_id}"
                self.client_gui.chat_ui.append_chat(chat_window_name,
                                                    f"{tag}{sender}: {msg}",
                                                    tag=f"clickable_message_{message_id}")
            except UnicodeDecodeError:
                logging.error(f"群组消息解码失败: 发送者={sender}, 群组ID={group_id}")
                self.client_gui.chat_ui.append_chat(f"群组 {group_id}", f"消息解码失败")
        elif msg_type == "chat":
            try:
                msg = data.decode()
                if header.get("from") == "服务器":
                    self.client_gui.chat_ui.append_chat("服务器", msg)
                    if "群组" in msg and ("创建成功" in msg or "已加入" in msg):
                        self.refresh_user_list()
                        messagebox.showinfo("成功", msg)
            except UnicodeDecodeError:
                logging.error(f"消息解码失败: {header}")
                self.client_gui.chat_ui.append_chat("服务器", "消息解码失败")

    def update_message_status_in_chat(self, message_id, new_status, sender=None, group_name=None):
        # Find all variant message IDs (original and suffixed)
        target_message_ids = []
        for msg_id in list(self.client_gui.message_lines.keys()):
            if msg_id == message_id or msg_id.startswith(f"{message_id}_") or message_id.startswith(f"{msg_id}_"):
                target_message_ids.append(msg_id)

        if not target_message_ids:
            logging.warning(f"更新消息状态失败: 消息ID {message_id} 不在消息行中")
            return

        updated = False
        for target_message_id in target_message_ids:
            if target_message_id not in self.client_gui.message_lines:
                logging.warning(f"更新消息状态失败: 消息ID {target_message_id} 不在消息行中")
                continue

            friend, line_number = self.client_gui.message_lines[target_message_id]
            if friend not in self.client_gui.chat_histories:
                logging.warning(f"更新消息状态失败: 历史记录 {friend} 不存在")
                continue

            # Update chat history
            for msg in self.client_gui.chat_histories[friend]:
                if msg.get('tag', '') == f"clickable_message_{target_message_id}":
                    current_text = msg['text'].rstrip('\n')
                    if new_status == "recalled":
                        new_content = f"{sender or self.client_gui.username}: [消息已撤回] ({target_message_id})"
                        msg['text'] = new_content + "\n"
                    else:
                        updated_text = current_text.rsplit("[", 1)[0].rstrip() + f"[{new_status}] ({target_message_id})"
                        msg['text'] = updated_text + "\n"
                    updated = True
                    break

            if not updated:
                logging.warning(f"更新历史记录失败: 未找到消息ID {target_message_id} 在 {friend} 的历史中")
                continue

            logging.info(f"历史记录更新: 消息ID={target_message_id}, 新状态={new_status} 在 {friend}")

            # Update current chat window
            if friend == self.client_gui.current_friend and friend in self.client_gui.chat_windows:
                chat_text = self.client_gui.chat_windows[friend]
                chat_text.config(state='normal')
                if new_status == "recalled":
                    new_content = f"{sender or self.client_gui.username}: [消息已撤回] ({target_message_id})"
                    chat_text.delete(f"{line_number}.0", f"{line_number + 1}.0")
                    chat_text.insert(f"{line_number}.0", new_content + "\n", f"clickable_message_{target_message_id}")
                else:
                    start_idx = f"{line_number}.0"
                    end_idx = chat_text.index(f"{start_idx} lineend")
                    current_text = chat_text.get(start_idx, end_idx)
                    updated_text = current_text.rsplit("[", 1)[0].rstrip() + f"[{new_status}] ({target_message_id})"
                    chat_text.delete(start_idx, end_idx)
                    chat_text.insert(start_idx, updated_text + "\n")
                chat_text.config(state='disabled')
                chat_text.see('end')
                logging.info(f"当前聊天窗口更新: 消息ID={target_message_id}, 新状态={new_status}")

        if updated:
            # Clean up message lines for recalled messages
            if new_status == "recalled":
                for target_message_id in target_message_ids:
                    self.client_gui.message_status.pop(target_message_id, None)
                    self.client_gui.message_lines.pop(target_message_id, None)

    def on_chat_text_click(self, event):
        if not self.client_gui.current_friend or self.client_gui.current_friend not in self.client_gui.chat_windows:
            logging.warning("点击消息失败: 未选择好友或聊天窗口不存在")
            return
        chat_text = self.client_gui.chat_windows[self.client_gui.current_friend]
        index = chat_text.index(f"@{event.x},{event.y}")
        line_number = int(float(index.split('.')[0]))
        tags = chat_text.tag_names(index)
        for tag in tags:
            if tag.startswith("clickable_message_"):
                message_id = tag[len("clickable_message_"):]
                line_content = chat_text.get(f"{line_number}.0", f"{line_number}.end")
                if line_content.startswith(f"{self.client_gui.username}:") or line_content.startswith("已发送文件"):
                    if messagebox.askyesno("确认撤回", f"是否撤回消息 {message_id}？"):
                        self.recall_message(message_id)
                    return
                else:
                    messagebox.showwarning("提示", "只能撤回自己的消息")
                    return
        messagebox.showinfo("提示", "请点击一条消息以撤回")

    def send_chat(self):
        if not self.client_gui.current_friend:
            messagebox.showwarning("警告", "请先选择一个好友或群组")
            return
        msg = self.client_gui.chat_ui.msg_entry.get()
        if not msg:
            return
        message_id = str(uuid.uuid4())
        try:
            if self.client_gui.current_friend.startswith("群组 "):
                group_id = self.client_gui.current_friend.split(" ")[1]
                send_message(self.client_gui.ssock, "group_chat", msg, extra_headers={"group_id": group_id, "message_id": message_id})
                self.client_gui.chat_ui.append_chat(self.client_gui.current_friend, f"{self.client_gui.username}: {msg}", tag=f"clickable_message_{message_id}")
                self.client_gui.message_status[message_id] = "sent"
            else:
                send_message(self.client_gui.ssock, "chat", msg, extra_headers={"to": self.client_gui.current_friend, "message_id": message_id})
                self.client_gui.chat_ui.append_chat(self.client_gui.current_friend, f"{self.client_gui.username}: {msg} [sent] ({message_id})", tag=f"clickable_message_{message_id}")
                self.client_gui.message_status[message_id] = "sent"
            self.client_gui.chat_ui.msg_entry.delete(0, 'end')
        except Exception as e:
            self.client_gui.chat_ui.append_chat("服务器", f"发送消息失败: {str(e)}")
            logging.error(f"发送消息失败: {str(e)}")

    def send_file(self):
        if not self.client_gui.current_friend:
            messagebox.showwarning("警告", "请先选择一个好友或群组")
            return
        file_path = filedialog.askopenfilename()
        if not file_path:
            return
        filename = os.path.basename(file_path)
        filesize = os.path.getsize(file_path)
        message_id = str(uuid.uuid4())
        try:
            with open(file_path, 'rb') as f:
                file_data = f.read()
            if self.client_gui.current_friend.startswith("群组 "):
                group_id = self.client_gui.current_friend.split(" ")[1]
                send_message(self.client_gui.ssock, "file", file_data,
                             extra_headers={"to": f"群组 {group_id}", "filename": filename, "filesize": filesize, "message_id": message_id})
            else:
                send_message(self.client_gui.ssock, "file", file_data,
                             extra_headers={"to": self.client_gui.current_friend, "filename": filename, "filesize": filesize, "message_id": message_id})
            self.client_gui.chat_ui.append_chat(self.client_gui.current_friend, f"已发送文件: {filename} ({filesize} bytes) [sent] ({message_id})", tag=f"clickable_message_{message_id}")
            self.client_gui.message_status[message_id] = "sent"
        except Exception as e:
            self.client_gui.chat_ui.append_chat("服务器", f"发送文件失败: {str(e)}")
            logging.error(f"发送文件失败: {str(e)}")

    def handle_file_request(self, sender, filename, filesize, message_id):
        response = messagebox.askyesno("文件传输请求", f"{sender} 希望发送文件 {filename} ({filesize} bytes)，是否接受？")
        try:
            if response:
                send_message(self.client_gui.ssock, "file_response", "", extra_headers={"message_id": message_id, "response": "accept", "to": sender})
                self.client_gui.chat_ui.append_chat("服务器", f"已接受来自 {sender} 的文件请求: {filename}")
            else:
                send_message(self.client_gui.ssock, "file_response", "", extra_headers={"message_id": message_id, "response": "reject", "to": sender})
                self.client_gui.chat_ui.append_chat("服务器", f"已拒绝来自 {sender} 的文件请求: {filename}")
        except Exception as e:
            self.client_gui.chat_ui.append_chat("服务器", f"响应文件请求失败: {str(e)}")
            logging.error(f"响应文件请求失败: {str(e)}")

    def handle_group_file_request(self, sender, filename, filesize, message_id, group_id):
        group_name = self.client_gui.group_list.get(group_id, f"群组 {group_id}")
        response = messagebox.askyesno("群组文件传输请求", f"{sender} 在群组 {group_name} 发送文件 {filename} ({filesize} bytes)，是否接受？")
        try:
            if response:
                send_message(self.client_gui.ssock, "group_file_response", "", extra_headers={"message_id": message_id, "response": "accept", "group_id": group_id, "to": sender})
                self.client_gui.chat_ui.append_chat(f"群组 {group_id}", f"已接受来自 {sender} 的群组文件请求: {filename}")
            else:
                send_message(self.client_gui.ssock, "group_file_response", "", extra_headers={"message_id": message_id, "response": "reject", "group_id": group_id, "to": sender})
                self.client_gui.chat_ui.append_chat(f"群组 {group_id}", f"已拒绝来自 {sender} 的群组文件请求: {filename}")
            self.client_gui.processed_group_file_requests.add(message_id)
        except Exception as e:
            self.client_gui.chat_ui.append_chat("服务器", f"响应群组文件请求失败: {str(e)}")
            logging.error(f"响应群组文件请求失败: {str(e)}")

    def refresh_user_list(self):
        try:
            send_message(self.client_gui.ssock, "list_friends", "")
            send_message(self.client_gui.ssock, "list_groups", "")
        except Exception as e:
            self.client_gui.chat_ui.append_chat("服务器", f"刷新好友/群组列表失败: {str(e)}")
            logging.error(f"刷新好友/群组列表失败: {str(e)}")

    def add_friend(self):
        friend = tk.simpledialog.askstring("添加好友", "请输入好友用户名:")
        if friend:
            try:
                send_message(self.client_gui.ssock, "friend_request", "", extra_headers={"to": friend})
            except Exception as e:
                self.client_gui.chat_ui.append_chat("服务器", f"发送好友请求失败: {str(e)}")
                logging.error(f"发送好友请求失败: {str(e)}")

    def view_friend_requests(self):
        try:
            send_message(self.client_gui.ssock, "list_friend_requests", "")
        except Exception as e:
            self.client_gui.chat_ui.append_chat("服务器", f"获取好友请求失败: {str(e)}")
            logging.error(f"获取好友请求失败: {str(e)}")

    def show_friend_requests(self, requests):
        win = tk.Toplevel(self.client_gui.root)
        win.title("好友请求")
        for requester in requests:
            frame = ttk.Frame(win)
            frame.pack(fill='x', padx=5, pady=2)
            ttk.Label(frame, text=f"来自 {requester} 的好友请求").pack(side='left')
            ttk.Button(frame, text="接受", command=lambda r=requester: self.accept_friend(r, win)).pack(side='left', padx=5)
            ttk.Button(frame, text="拒绝", command=lambda r=requester: self.reject_friend(r, win)).pack(side='left', padx=5)

    def accept_friend(self, requester, win):
        try:
            send_message(self.client_gui.ssock, "accept_friend", "", extra_headers={"from": requester})
            self.client_gui.chat_ui.append_chat("服务器", f"已接受 {requester} 的好友请求")
            win.destroy()
            self.refresh_user_list()
        except Exception as e:
            self.client_gui.chat_ui.append_chat("服务器", f"接受好友请求失败: {str(e)}")
            logging.error(f"接受好友请求失败: {str(e)}")

    def reject_friend(self, requester, win):
        try:
            send_message(self.client_gui.ssock, "reject_friend", "", extra_headers={"from": requester})
            self.client_gui.chat_ui.append_chat("服务器", f"已拒绝 {requester} 的好友请求")
            win.destroy()
        except Exception as e:
            self.client_gui.chat_ui.append_chat("服务器", f"拒绝好友请求失败: {str(e)}")
            logging.error(f"拒绝好友请求失败: {str(e)}")

    def recall_message(self, message_id=None):
        if not message_id:
            messagebox.showwarning("警告", "请点击一条消息以撤回")
            return
        try:
            send_message(self.client_gui.ssock, "recall", "", extra_headers={"message_id": message_id})
        except Exception as e:
            self.client_gui.chat_ui.append_chat("服务器", f"撤回消息失败: {str(e)}")
            logging.error(f"撤回消息失败: {str(e)}")

    def logout(self):
        if self.client_gui.ssock:
            try:
                if self.client_gui.is_admin:
                    send_message(self.client_gui.ssock, "admin_command", "", extra_headers={"action": "exit"})
                self.client_gui.ssock.close()
            except Exception:
                pass
        self.client_gui.ssock = None
        self.client_gui.username = ""
        self.client_gui.is_admin = False
        self.client_gui.current_friend = None
        self.client_gui.chat_windows.clear()
        self.client_gui.chat_histories.clear()
        self.client_gui.message_status.clear()
        self.client_gui.message_lines.clear()
        self.client_gui.group_list.clear()
        self.client_gui.processed_group_file_requests.clear()
        self.client_gui.chat_ui.user_list.delete(*self.client_gui.chat_ui.user_list.get_children())
        self.client_gui.show_login()