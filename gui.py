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

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')

class ClientGUI:
    def __init__(self):
        self.root = tk.Tk()
        self.root.title("网络通讯客户端")
        self.ssock = None
        self.username = ""
        self.is_admin = False
        self.client_map = {}
        self.message_status = {}
        self.message_lines = {}
        self.chat_windows = {}
        self.chat_histories = {}
        self.current_friend = None
        self.group_list = {}  # group_id -> group_name
        self.setup_login_ui()
        self.setup_chat_ui()
        self.show_login()
        self.root.protocol("WM_DELETE_WINDOW", self.on_close)

    def setup_login_ui(self):
        self.login_frame = ttk.Frame(self.root, padding=20)
        self.action_var = tk.StringVar(value="login")
        ttk.Radiobutton(self.login_frame, text="登录", variable=self.action_var, value="login").grid(row=0, column=0)
        ttk.Radiobutton(self.login_frame, text="注册", variable=self.action_var, value="register").grid(row=0, column=1)
        ttk.Label(self.login_frame, text="用户名:").grid(row=1, column=0, pady=5)
        self.username_entry = ttk.Entry(self.login_frame)
        self.username_entry.grid(row=1, column=1, pady=5)
        ttk.Label(self.login_frame, text="密码:").grid(row=2, column=0, pady=5)
        self.password_entry = ttk.Entry(self.login_frame, show="*")
        self.password_entry.grid(row=2, column=1, pady=5)
        self.login_btn = ttk.Button(self.login_frame, text="确定", command=self.do_auth)
        self.login_btn.grid(row=3, columnspan=2, pady=10)

    def setup_chat_ui(self):
        self.chat_frame = ttk.Frame(self.root)
        tree_frame = ttk.Frame(self.chat_frame)
        tree_frame.grid(row=0, column=0, rowspan=3, padx=5, pady=5, sticky='ns')
        self.user_list = ttk.Treeview(tree_frame, columns=('username', 'status'), show='headings', height=20)
        self.user_list.heading('username', text='好友/群组')
        self.user_list.heading('status', text='状态')
        self.user_list.column('username', width=150, anchor='center', minwidth=150)
        self.user_list.column('status', width=80, anchor='center', minwidth=80)
        style = ttk.Style()
        style.configure("Treeview", rowheight=25, font=('Arial', 10))
        self.user_list.pack(side='left', fill='both', expand=True)
        scrollbar = ttk.Scrollbar(tree_frame, orient='vertical', command=self.user_list.yview)
        scrollbar.pack(side='right', fill='y')
        self.user_list.configure(yscrollcommand=scrollbar.set)
        self.user_list.bind('<<TreeviewSelect>>', self.on_user_select)

        self.current_friend_label = ttk.Label(self.chat_frame, text="未选择好友")
        self.current_friend_label.grid(row=0, column=1, columnspan=2, pady=5, sticky='w')

        self.chat_container = ttk.Frame(self.chat_frame)
        self.chat_container.grid(row=1, column=1, columnspan=2, padx=5, pady=5, sticky='nsew')

        self.create_chat_window("服务器")
        self.chat_windows["服务器"].tag_configure("announcement", font=('Arial', 10, 'bold'), foreground="red")

        self.msg_entry = ttk.Entry(self.chat_frame, width=40)
        self.msg_entry.grid(row=2, column=1, padx=5, pady=5)
        self.file_btn = ttk.Button(self.chat_frame, text="发送文件", command=self.send_file)
        self.file_btn.grid(row=2, column=2, padx=5)
        self.send_btn = ttk.Button(self.chat_frame, text="发送", command=self.send_chat)
        self.send_btn.grid(row=3, column=1, columnspan=2, pady=5)
        self.recall_btn = ttk.Button(self.chat_frame, text="撤回消息", command=self.recall_message)
        self.recall_btn.grid(row=4, column=1, columnspan=2, pady=5)
        self.refresh_btn = ttk.Button(self.chat_frame, text="刷新好友", command=self.refresh_user_list)
        self.refresh_btn.grid(row=2, column=0, padx=5)
        self.add_friend_btn = ttk.Button(self.chat_frame, text="添加好友", command=self.add_friend)
        self.add_friend_btn.grid(row=3, column=0, padx=5)
        self.view_requests_btn = ttk.Button(self.chat_frame, text="查看好友请求", command=self.view_friend_requests)
        self.view_requests_btn.grid(row=4, column=0, padx=5)
        self.group_btn = ttk.Button(self.chat_frame, text="群组管理", command=self.group_management)
        self.group_btn.grid(row=5, column=0, padx=5)
        self.logout_btn = ttk.Button(self.chat_frame, text="退出", command=self.logout, width=12)
        self.logout_btn.grid(row=6, column=1, columnspan=2, pady=10)
        self.admin_btn = ttk.Button(self.chat_frame, text="管理面板", command=self.show_admin_panel)
        self.status_var = tk.StringVar()
        self.status_bar = ttk.Label(self.chat_frame, textvariable=self.status_var)
        self.status_bar.grid(row=7, columnspan=3, sticky='ew')

    def create_chat_window(self, friend):
        if friend not in self.chat_windows:
            chat_text = tk.Text(self.chat_container, width=50, height=20, state='disabled')
            chat_text.bind("<Button-1>", self.on_chat_text_click)
            self.chat_windows[friend] = chat_text
            self.chat_histories[friend] = []
            if friend in self.chat_histories:
                chat_text.config(state='normal')
                for msg in self.chat_histories[friend]:
                    chat_text.insert('end', msg['text'], msg.get('tag'))
                chat_text.config(state='disabled')
                chat_text.see('end')
        return self.chat_windows[friend]

    def switch_chat_window(self, friend):
        if friend == self.current_friend:
            return
        if self.current_friend and self.current_friend in self.chat_windows:
            self.chat_windows[self.current_friend].grid_forget()
        self.current_friend = friend
        self.current_friend_label.config(text=f"与 {friend} 的聊天")
        chat_window = self.create_chat_window(friend)
        chat_window.grid(row=0, column=0, sticky='nsew')
        chat_window.config(state='normal')
        chat_window.delete('1.0', 'end')
        for msg in self.chat_histories[friend]:
            line_number = int(float(chat_window.index('end-1c')))
            chat_window.insert('end', msg['text'], msg.get('tag'))
            if msg.get('tag', '').startswith("clickable_message_"):
                message_id = msg['tag'][len("clickable_message_"):]
                self.message_lines[message_id] = (friend, line_number)
        chat_window.config(state='disabled')
        chat_window.see('end')
        logging.info(f"切换到聊天窗口: {friend}")

    def on_user_select(self, event):
        selected = self.user_list.selection()
        if selected:
            friend = self.user_list.item(selected[0])['values'][0]
            self.switch_chat_window(friend)

    def show_login(self):
        self.chat_frame.grid_forget()
        self.login_frame.grid()
        self.root.geometry("300x200")

    def show_chat(self):
        self.username_entry.delete(0, 'end')
        self.password_entry.delete(0, 'end')
        self.login_frame.grid_forget()
        self.chat_frame.grid()
        if self.is_admin:
            self.admin_btn.grid(row=0, column=2, sticky='ne')
        self.root.geometry("800x500")
        self.root.title(f"聊天室 - {self.username}")
        self.refresh_user_list()

    def show_admin_panel(self):
        admin_win = tk.Toplevel(self.root)
        admin_win.title("管理员面板")
        ttk.Button(admin_win, text="查看所有用户", command=self.list_users).pack(pady=5)
        ttk.Button(admin_win, text="删除用户", command=self.delete_user).pack(pady=5)
        ttk.Button(admin_win, text="发送公告", command=self.send_announcement).pack(pady=5)

    def do_auth(self):
        action = self.action_var.get()
        username = self.username_entry.get()
        password = self.password_entry.get()
        try:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.load_verify_locations("SSL/tsetcn.crt")
            client_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            client_socket.connect(('127.0.0.1', 8090))
            self.ssock = context.wrap_socket(client_socket, server_hostname='tset.cn')
            send_message(self.ssock, action, username, extra_headers={"password": password})
            header, data = recv_message(self.ssock)
            if header.get("type") == "error":
                messagebox.showerror("错误", data.decode())
                return
            if header.get("type") == "admin_auth":
                self.is_admin = True
                messagebox.showinfo("成功", "管理员登录成功！")
            self.username = username
            self.show_chat()
            threading.Thread(target=self.listen_for_messages, daemon=True).start()
        except Exception as e:
            messagebox.showerror("连接错误", str(e))

    def listen_for_messages(self):
        while True:
            try:
                header, data = recv_message(self.ssock)
                if header is None:
                    self.update_status("服务器连接已断开")
                    self.root.after(0, self.logout)
                    break
                self.process_message(header, data)
            except ssl.SSLError as e:
                logging.error(f"SSL错误: {str(e)}")
                self.update_status(f"SSL错误: {str(e)}")
                self.root.after(0, self.logout)
                break
            except Exception as e:
                logging.error(f"接收消息错误: {str(e)}")
                self.update_status(f"接收错误: {str(e)}")
                self.root.after(0, self.append_chat, "服务器", f"接收错误: {str(e)}")
                continue

    def update_message_status_in_chat(self, message_id, new_status, sender=None):
        if message_id in self.message_lines:
            friend, line_number = self.message_lines[message_id]
            if friend not in self.chat_windows:
                logging.warning(f"更新消息状态失败: 窗口 {friend} 不存在")
                return
            chat_text = self.chat_windows[friend]
            chat_text.config(state='normal')
            if new_status == "recalled":
                new_content = f"{sender or '消息'}: 消息已被撤回 ({message_id})"
                chat_text.delete(f"{line_number}.0", f"{line_number}.end")
                chat_text.insert(f"{line_number}.0", new_content + "\n", f"clickable_message_{message_id}")
            else:
                line_content = chat_text.get(f"{line_number}.0", f"{line_number}.end")
                if "[sent]" in line_content:
                    new_content = line_content.replace("[sent]", f"[{new_status}]")
                elif "[delivered]" in line_content:
                    new_content = line_content.replace("[delivered]", f"[{new_status}]")
                else:
                    new_content = line_content
                chat_text.delete(f"{line_number}.0", f"{line_number}.end")
                chat_text.insert(f"{line_number}.0", new_content + "\n", f"clickable_message_{message_id}")
            chat_text.config(state='disabled')
            chat_text.see('end')
            logging.info(f"更新消息状态: {message_id} -> {new_status} 在 {friend} 的窗口")
        else:
            logging.warning(f"更新消息状态失败: 消息ID={message_id} 不存在于 message_lines")

    def on_chat_text_click(self, event):
        if not self.current_friend or self.current_friend not in self.chat_windows:
            logging.warning("点击消息失败: 未选择好友或聊天窗口不存在")
            return
        chat_text = self.chat_windows[self.current_friend]
        index = chat_text.index(f"@{event.x},{event.y}")
        line_number = int(float(index.split('.')[0]))
        tags = chat_text.tag_names(index)
        for tag in tags:
            if tag.startswith("clickable_message_"):
                message_id = tag[len("clickable_message_"):]
                line_content = chat_text.get(f"{line_number}.0", f"{line_number}.end")
                if line_content.startswith("我 ->") or line_content.startswith("已发送文件"):
                    if messagebox.askyesno("确认撤回", f"是否撤回消息 {message_id}？"):
                        self.recall_message(message_id)
                    return
                else:
                    messagebox.showwarning("提示", "只能撤回自己的消息")
                    return
        messagebox.showinfo("提示", "请点击一条消息以撤回")

    def process_message(self, header, data):
        msg_type = header.get("type")
        message_id = header.get("message_id", "")
        logging.info(f"处理消息: 类型={msg_type}, 消息ID={message_id}, 头信息={header}")
        if msg_type == "file_request":
            sender = header.get("from", "未知用户")
            filename = header.get("filename", "unknown_file")
            filesize = header.get("filesize", "未知大小")
            self.append_chat("服务器", f"收到文件传输请求: {sender} 希望发送文件 {filename} ({filesize} bytes)")
            threading.Thread(target=self.handle_file_request, args=(sender, filename, filesize, message_id), daemon=True).start()
        elif msg_type in ("chat", "file"):
            if "history" in header and message_id in self.message_lines:
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
                        self.append_chat("服务器", f"{tag}{sender}: {msg}", tag=tag_name)
                        if sender == "[系统公告]":
                            self.root.after(0, lambda: self.switch_chat_window("服务器"))
                            self.root.after(0, lambda: messagebox.showinfo("系统公告", f"收到新公告: {msg}"))
                    else:
                        self.message_status[message_id] = status
                        self.append_chat(sender, f"{tag}{sender}: {msg} [{status}] ({message_id})", tag=f"clickable_message_{message_id}")
                        if message_id and "history" not in header:
                            try:
                                send_message(self.ssock, "receipt", "", extra_headers={"message_id": message_id, "to": sender})
                                logging.info(f"发送回执: 消息ID={message_id}, 目标={sender}")
                            except Exception as e:
                                self.append_chat(sender, f"发送回执失败: {message_id} ({str(e)})")
                                logging.error(f"发送回执失败: 消息ID={message_id}, 错误={str(e)}")
                except UnicodeDecodeError:
                    logging.error(f"消息解码失败: 发送者={sender}, 消息ID={message_id}")
                    self.append_chat("服务器", f"消息解码失败: {message_id}")
            elif msg_type == "file":
                filename = header.get("filename", "unknown_file")
                file_path = f"files/recv_{filename}"
                os.makedirs("files", exist_ok=True)
                with open(file_path, 'wb') as f:
                    f.write(data)
                self.message_status[message_id] = status
                self.append_chat(sender, f"{tag}{sender}: 收到文件: {filename}，已保存至 {file_path} [{status}] ({message_id})", tag=f"clickable_message_{message_id}")
                if message_id and "history" not in header:
                    try:
                        send_message(self.ssock, "receipt", "", extra_headers={"message_id": message_id, "to": sender})
                        logging.info(f"发送回执: 消息ID={message_id}, 目标={sender}")
                    except Exception as e:
                        self.append_chat(sender, f"发送回执失败: {message_id} ({str(e)})")
                        logging.error(f"发送回执失败: 消息ID={message_id}, 错误={str(e)}")
        elif msg_type == "status_update":
            message_id = header.get("message_id")
            status = header.get("status")
            if message_id in self.message_status:
                self.message_status[message_id] = status
                self.update_message_status_in_chat(message_id, status)
                logging.info(f"消息状态更新: {message_id} -> {status} (发送者: {self.username})")
            else:
                logging.warning(f"状态更新失败: 消息ID={message_id} 不存在")
        elif msg_type == "friend_request":
            sender = header.get("from")
            self.append_chat("服务器", f"收到好友请求: {sender}")
        elif msg_type == "list_friend_requests":
            try:
                requests = json.loads(data.decode())
                self.show_friend_requests(requests)
            except json.JSONDecodeError:
                self.append_chat("服务器", "解析好友请求列表失败")
                logging.error("解析好友请求列表失败")
        elif msg_type == "admin_response":
            try:
                users = json.loads(data.decode())
                self.user_list.delete(*self.user_list.get_children())
                self.client_map.clear()
                response_type = header.get("response_type", "list_friends")
                if response_type == "list_friends":
                    self.user_list.insert('', 'end', values=("服务器", "始终在线"))
                    self.client_map["服务器"] = {'is_online': True, 'is_admin': False}
                    for user, is_online in users:
                        self.client_map[user] = {'is_online': is_online, 'is_admin': False}
                        status = '在线' if is_online else '离线'
                        self.user_list.insert('', 'end', values=(user, status))
                    self.append_chat("服务器", "好友列表已刷新")
                elif response_type == "list_users":
                    for user, is_online, is_admin in users:
                        self.client_map[user] = {'is_online': is_online, 'is_admin': is_admin}
                        status = '在线' if is_online else '离线'
                        admin_status = '是' if is_admin else '否'
                        self.user_list.insert('', 'end', values=(user, status))
                    action_result = header.get("action_result")
                    if action_result:
                        self.append_chat("服务器", action_result)
                    else:
                        self.append_chat("服务器", "用户列表已刷新")
            except json.JSONDecodeError:
                self.append_chat("服务器", "用户列表解析失败")
                logging.error("用户列表解析失败")
        elif msg_type == "recall":
            message_id = header.get("message_id")
            sender = header.get("from", "未知用户")
            if message_id in self.message_status:
                self.message_status[message_id] = "recalled"
                self.update_message_status_in_chat(message_id, "recalled", sender=sender)
                logging.info(f"处理撤回消息: {message_id} from {sender}")
                if self.current_friend != sender:
                    self.switch_chat_window(sender)
            else:
                logging.warning(f"撤回消息失败: 消息ID={message_id} 不存在")
                self.append_chat(sender, f"撤回消息失败: 消息ID {message_id} 不存在")
        elif msg_type == "error":
            try:
                error_msg = data.decode()
                self.append_chat("服务器", f"错误: {error_msg}")
                messagebox.showerror("错误", error_msg)
            except UnicodeDecodeError:
                self.append_chat("服务器", "错误: 无法解码服务器错误消息")
                logging.error("错误消息解码失败")
        elif msg_type == "group_chat":
            group_id = header.get("group_id")
            sender = header.get("from")
            try:
                if not group_id:
                    raise ValueError("缺少群组ID")
                msg = data.decode()
                group_name = self.group_list.get(group_id, f"群组 {group_id}")
                self.append_chat(f"群组 {group_id}", f"{sender}: {msg}")
                if self.current_friend != f"群组 {group_id}":
                    self.root.after(0, lambda: self.switch_chat_window(f"群组 {group_id}"))
                    self.root.after(0, lambda: messagebox.showinfo("群组消息", f"群组 {group_name} 收到新消息"))
                logging.info(f"收到群组消息: 群组ID={group_id}, 发送者={sender}, 消息={msg}")
            except UnicodeDecodeError:
                logging.error(f"群组消息解码失败: 群组ID={group_id}, 发送者={sender}")
                self.append_chat("服务器", f"群组 {group_id} 消息解码失败")
            except Exception as e:
                logging.error(f"处理群组消息失败: {str(e)}")
                self.append_chat("服务器", f"处理群组消息失败: {str(e)}")
        elif msg_type == "list_groups":
            try:
                groups = json.loads(data.decode())
                for group in groups:
                    self.group_list[str(group['id'])] = group['group_name']
                    self.user_list.insert('', 'end', values=(f"群组 {group['id']}", "群聊"))
                self.append_chat("服务器", "群组列表已刷新")
                logging.info("群组列表已刷新")
            except json.JSONDecodeError:
                self.append_chat("服务器", "解析群组列表失败")
                logging.error("解析群组列表失败")

    def handle_file_request(self, sender, filename, filesize, message_id):
        response = messagebox.askyesno("文件传输请求", f"{sender} 希望发送文件 {filename} ({filesize} bytes)，是否接受？")
        try:
            if response:
                send_message(self.ssock, "file_response", "", extra_headers={"message_id": message_id, "response": "accept", "to": sender})
                self.append_chat(sender, f"已接受 {sender} 的文件请求: {filename}")
                logging.info(f"接受文件请求: {filename}, 消息ID={message_id}, 发送者={sender}")
            else:
                send_message(self.ssock, "file_response", "", extra_headers={"message_id": message_id, "response": "reject", "to": sender})
                self.append_chat(sender, f"已拒绝 {sender} 的文件请求: {filename}")
                logging.info(f"拒绝文件请求: {filename}, 消息ID={message_id}, 发送者={sender}")
        except Exception as e:
            self.append_chat(sender, f"响应文件请求失败: {filename} ({str(e)})")
            logging.error(f"响应文件请求失败: 消息ID={message_id}, 错误={str(e)}")

    def show_all_users(self):
        users_win = tk.Toplevel(self.root)
        users_win.title("所有用户")
        users_win.geometry("300x400")
        ttk.Label(users_win, text="所有注册用户").pack(pady=5)
        tree = ttk.Treeview(users_win, columns=('username', 'status', 'admin'), show='headings')
        tree.heading('username', text='用户名')
        tree.heading('status', text='状态')
        tree.heading('admin', text='管理员')
        tree.column('username', width=100, anchor='center')
        tree.column('status', width=60, anchor='center')
        tree.column('admin', width=60, anchor='center')
        tree.pack(fill='both', expand=True, padx=5, pady=5)
        try:
            send_message(self.ssock, "admin_command", "", extra_headers={"action": "list_users"})
            self.root.after(100, lambda: self.populate_users(tree))
        except Exception as e:
            messagebox.showerror("失败", f"请求用户列表失败: {e}")

    def populate_users(self, tree):
        tree.delete(*tree.get_children())
        for user, info in self.client_map.items():
            status = '在线' if info['is_online'] else '离线'
            admin_status = '是' if info['is_admin'] else '否'
            tree.insert('', 'end', values=(user, status, admin_status))

    def show_friend_requests(self, requests):
        requests_win = tk.Toplevel(self.root)
        requests_win.title("好友请求")
        requests_win.geometry("300x400")
        ttk.Label(requests_win, text="待处理的好友请求").pack(pady=5)
        tree = ttk.Treeview(requests_win, columns=('action'), show='tree')
        tree.heading('#0', text='请求者')
        tree.pack(fill='both', expand=True, padx=5, pady=5)
        for requester in requests:
            tree.insert('', 'end', text=requester)
        def accept_selected():
            selected = tree.selection()
            if not selected:
                messagebox.showwarning("提示", "请选择一个请求者")
                return
            requester = tree.item(selected[0])['text']
            try:
                send_message(self.ssock, "accept_friend", "", extra_headers={"from": requester})
                self.append_chat("服务器", f"已接受 {requester} 的好友请求")
                tree.delete(selected[0])
                self.refresh_user_list()
            except Exception as e:
                messagebox.showerror("失败", f"接受好友请求失败: {e}")
        def reject_selected():
            selected = tree.selection()
            if not selected:
                messagebox.showwarning("提示", "请选择一个请求者")
                return
            requester = tree.item(selected[0])['text']
            try:
                send_message(self.ssock, "reject_friend", "", extra_headers={"from": requester})
                self.append_chat("服务器", f"已拒绝 {requester} 的好友请求")
                tree.delete(selected[0])
            except Exception as e:
                messagebox.showerror("失败", f"拒绝好友请求失败: {e}")
        ttk.Button(requests_win, text="接受", command=accept_selected).pack(pady=5)
        ttk.Button(requests_win, text="拒绝", command=reject_selected).pack(pady=5)

    def send_chat(self):
        msg = self.msg_entry.get()
        if not self.current_friend:
            messagebox.showwarning("提示", "请选择接收好友或群组")
            return
        if self.current_friend == "服务器":
            messagebox.showwarning("提示", "不能向服务器发送消息")
            return
        if self.current_friend.startswith("群组 "):
            group_id = self.current_friend.split(" ")[1]
            try:
                message_id = str(uuid.uuid4())
                send_message(self.ssock, "group_chat", msg, extra_headers={"group_id": group_id, "message_id": message_id})
                self.message_status[message_id] = "sent"
                #self.append_chat(self.current_friend, f"我: {msg} [sent] ({message_id})", tag=f"clickable_message_{message_id}")
                self.msg_entry.delete(0, 'end')
                logging.info(f"发送群组消息: {msg}, 群组ID={group_id}, 消息ID={message_id}")
            except Exception as e:
                messagebox.showerror("发送失败", str(e))
                logging.error(f"发送群组消息失败: {str(e)}")
        else:
            try:
                message_id = str(uuid.uuid4())
                send_message(self.ssock, "chat", msg, extra_headers={"to": self.current_friend, "message_id": message_id})
                self.message_status[message_id] = "sent"
                self.append_chat(self.current_friend, f"我 -> {self.current_friend}: {msg} [sent] ({message_id})", tag=f"clickable_message_{message_id}")
                self.msg_entry.delete(0, 'end')
                logging.info(f"发送聊天消息: {msg}, 消息ID={message_id}, 目标={self.current_friend}")
            except Exception as e:
                messagebox.showerror("发送失败", str(e))
                logging.error(f"发送聊天消息失败: {str(e)}")

    def send_file(self):
        filepath = filedialog.askopenfilename()
        if not filepath:
            return
        if not self.current_friend:
            messagebox.showwarning("提示", "请选择接收好友")
            return
        if self.current_friend == "服务器":
            messagebox.showwarning("提示", "不能向服务器发送文件")
            return
        filename = os.path.basename(filepath)
        try:
            with open(filepath, 'rb') as f:
                file_data = f.read()
                filesize = len(file_data)
                message_id = str(uuid.uuid4())
                send_message(self.ssock, 'file', file_data,
                             extra_headers={"filename": filename, "to": self.current_friend, "message_id": message_id, "filesize": filesize})
                self.message_status[message_id] = "sent"
                self.append_chat(self.current_friend, f"已发送文件: {filename} 给 {self.current_friend} [sent] ({message_id})", tag=f"clickable_message_{message_id}")
                logging.info(f"发送文件请求: {filename}, 消息ID={message_id}, 目标={self.current_friend}, 大小={filesize} bytes")
        except Exception as e:
            messagebox.showerror("发送失败", str(e))
            logging.error(f"发送文件请求失败: {str(e)}")

    def recall_message(self, message_id=None):
        if not message_id:
            messagebox.showinfo("提示", "请点击一条消息以撤回")
            return
        try:
            send_message(self.ssock, "recall", "", extra_headers={"message_id": message_id})
            self.append_chat(self.current_friend, f"已请求撤回消息 {message_id}")
            logging.info(f"请求撤回消息: {message_id}")
        except Exception as e:
            messagebox.showerror("失败", f"撤回消息失败: {e}")
            logging.error(f"撤回消息失败: {str(e)}")

    def add_friend(self):
        target = tk.simpledialog.askstring("添加好友", "输入要添加的好友用户名:")
        if not target:
            return
        if target == "服务器":
            messagebox.showwarning("提示", "不能添加服务器为好友")
            return
        try:
            send_message(self.ssock, "friend_request", "", extra_headers={"to": target})
            self.append_chat("服务器", f"已发送好友请求给 {target}")
            logging.info(f"发送好友请求: 目标={target}")
        except Exception as e:
            messagebox.showerror("失败", f"发送好友请求失败: {e}")
            logging.error(f"发送好友请求失败: {str(e)}")

    def view_friend_requests(self):
        try:
            send_message(self.ssock, "list_friend_requests", "")
            logging.info("请求好友请求列表")
        except Exception as e:
            messagebox.showerror("失败", f"获取好友请求失败: {e}")
            logging.error(f"获取好友请求失败: {str(e)}")

    def append_chat(self, friend, message, tag=None):
        self.create_chat_window(friend)
        chat_text = self.chat_windows[friend]
        chat_text.config(state='normal')
        line_number = int(float(chat_text.index('end-1c')))
        chat_text.insert('end', message + '\n', tag)
        chat_text.config(state='disabled')
        chat_text.see('end')
        if tag and tag.startswith("clickable_message_"):
            message_id = tag[len("clickable_message_"):]
            self.message_lines[message_id] = (friend, line_number)
        self.chat_histories[friend].append({'text': message + '\n', 'tag': tag})
        logging.info(f"消息追加到 {friend} 的窗口: {message}")

    def update_status(self, message):
        self.status_var.set(message)
        logging.info(f"状态栏更新: {message}")

    def run(self):
        self.root.mainloop()

    def refresh_user_list(self):
        try:
            send_message(self.ssock, "list_friends", "")
            send_message(self.ssock, "list_groups", "")
            logging.info("请求刷新好友和群组列表")
        except Exception as e:
            self.update_status(f"刷新好友和群组列表失败: {e}")
            logging.error(f"刷新好友和群组列表失败: {str(e)}")

    def list_users(self):
        try:
            send_message(self.ssock, "admin_command", "", extra_headers={"action": "list_users"})
            self.root.after(100, self.show_all_users)
            logging.info("请求列出所有用户")
        except Exception as e:
            messagebox.showerror("失败", f"请求用户列表失败: {e}")
            logging.error(f"请求用户列表失败: {str(e)}")

    def delete_user(self):
        target = tk.simpledialog.askstring("删除用户", "输入要删除的用户名:")
        if not target:
            return
        try:
            send_message(self.ssock, "admin_command", target, extra_headers={"action": "delete_user"})
            self.append_chat("服务器", f"已请求删除用户 {target}")
            logging.info(f"请求删除用户: {target}")
        except Exception as e:
            messagebox.showerror("失败", f"删除用户失败: {e}")
            logging.error(f"删除用户失败: {str(e)}")

    def send_announcement(self):
        content = tk.simpledialog.askstring("发送公告", "输入公告内容:")
        if not content:
            return
        try:
            send_message(self.ssock, "admin_command", content, extra_headers={"action": "announcement"})
            self.append_chat("服务器", "公告已送达", tag="announcement")
            self.switch_chat_window("服务器")
            logging.info("发送公告")
        except Exception as e:
            messagebox.showerror("失败", f"发送公告失败: {e}")
            logging.error(f"发送公告失败: {str(e)}")

    def logout(self):
        try:
            if self.ssock:
                send_message(self.ssock, "chat", "quit")
                self.ssock.close()
        except Exception:
            pass
        self.ssock = None
        self.username = ""
        self.is_admin = False
        self.client_map.clear()
        self.message_status.clear()
        self.message_lines.clear()
        self.chat_windows.clear()
        self.chat_histories.clear()
        self.current_friend = None
        self.group_list.clear()
        self.current_friend_label.config(text="未选择好友")
        self.user_list.delete(*self.user_list.get_children())
        self.admin_btn.grid_forget()
        self.chat_frame.grid_forget()
        self.update_status("已退出登录")
        self.show_login()
        logging.info("用户退出登录")

    def on_close(self):
        self.logout()
        self.root.destroy()

    def group_management(self):
        group_win = tk.Toplevel(self.root)
        group_win.title("群组管理")
        ttk.Button(group_win, text="创建群组", command=self.create_group).pack(pady=5)
        ttk.Button(group_win, text="加入群组", command=self.join_group).pack(pady=5)
        ttk.Button(group_win, text="查看我的群组", command=self.view_my_groups).pack(pady=5)

    def create_group(self):
        group_name = tk.simpledialog.askstring("创建群组", "输入群组名称:")
        if not group_name:
            return
        try:
            send_message(self.ssock, "create_group", group_name)
            logging.info(f"请求创建群组: {group_name}")
        except Exception as e:
            messagebox.showerror("失败", f"创建群组失败: {e}")

    def join_group(self):
        group_id = tk.simpledialog.askstring("加入群组", "输入群组ID:")
        if not group_id:
            return
        try:
            send_message(self.ssock, "join_group", group_id)
            logging.info(f"请求加入群组: {group_id}")
        except Exception as e:
            messagebox.showerror("失败", f"加入群组失败: {e}")
            logging.error(f"加入群组失败: {str(e)}")

    def view_my_groups(self):
        try:
            send_message(self.ssock, "list_groups", "")
            logging.info("请求我的群组列表")
        except Exception as e:
            messagebox.showerror("失败", f"获取群组列表失败: {e}")

    def show_my_groups(self, groups):
        groups_win = tk.Toplevel(self.root)
        groups_win.title("我的群组")
        tree = ttk.Treeview(groups_win, columns=('group_id', 'group_name'), show='headings')
        tree.heading('group_id', text='群组ID')
        tree.heading('group_name', text='群组名称')
        tree.pack(fill='both', expand=True)
        for group in groups:
            tree.insert('', 'end', values=(group['id'], group['group_name']))
        tree.bind('<<TreeviewSelect>>', self.on_group_select)

    def on_group_select(self, event):
        selected = event.widget.selection()
        if selected:
            group_id = event.widget.item(selected[0])['values'][0]
            self.switch_chat_window(f"群组 {group_id}")

if __name__ == "__main__":
    app = ClientGUI()
    app.run()