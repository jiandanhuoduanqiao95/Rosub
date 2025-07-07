import tkinter as tk
from tkinter import ttk, messagebox, filedialog
import socket
import ssl
import os
import threading
from protocol import send_message, recv_message
import json

class ClientGUI:
    def __init__(self):
        self.root = tk.Tk()
        self.root.title("网络通讯客户端")
        self.ssock = None
        self.username = ""
        self.is_admin = False
        self.client_map = {}
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
        self.user_list.heading('username', text='好友')
        self.user_list.heading('status', text='状态')
        self.user_list.column('username', width=150, anchor='center', minwidth=150)
        self.user_list.column('status', width=80, anchor='center', minwidth=80)
        style = ttk.Style()
        style.configure("Treeview", rowheight=25, font=('Arial', 10))
        self.user_list.pack(side='left', fill='both', expand=True)
        scrollbar = ttk.Scrollbar(tree_frame, orient='vertical', command=self.user_list.yview)
        scrollbar.pack(side='right', fill='y')
        self.user_list.configure(yscrollcommand=scrollbar.set)
        self.chat_text = tk.Text(self.chat_frame, width=50, height=20, state='disabled')
        self.chat_text.grid(row=0, column=1, columnspan=2, padx=5, pady=5)
        self.msg_entry = ttk.Entry(self.chat_frame, width=40)
        self.msg_entry.grid(row=1, column=1, padx=5, pady=5)
        self.file_btn = ttk.Button(self.chat_frame, text="发送文件", command=self.send_file)
        self.file_btn.grid(row=1, column=2, padx=5)
        self.send_btn = ttk.Button(self.chat_frame, text="发送", command=self.send_chat)
        self.send_btn.grid(row=2, column=1, columnspan=2, pady=5)
        self.refresh_btn = ttk.Button(self.chat_frame, text="刷新好友", command=self.refresh_user_list)
        self.refresh_btn.grid(row=2, column=0, padx=5)
        self.add_friend_btn = ttk.Button(self.chat_frame, text="添加好友", command=self.add_friend)
        self.add_friend_btn.grid(row=3, column=0, padx=5)
        self.view_requests_btn = ttk.Button(self.chat_frame, text="查看好友请求", command=self.view_friend_requests)
        self.view_requests_btn.grid(row=4, column=0, padx=5)
        self.logout_btn = ttk.Button(self.chat_frame, text="退出", command=self.logout, width=12)
        self.logout_btn.grid(row=5, column=1, columnspan=2, pady=10)
        self.admin_btn = ttk.Button(self.chat_frame, text="管理面板", command=self.show_admin_panel)
        self.status_var = tk.StringVar()
        self.status_bar = ttk.Label(self.chat_frame, textvariable=self.status_var)
        self.status_bar.grid(row=6, columnspan=3, sticky='ew')

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
                    break
                self.process_message(header, data)
            except Exception as e:
                self.update_status(f"接收错误: {str(e)}")
                break

    def process_message(self, header, data):
        msg_type = header.get("type")
        if msg_type == "chat":
            sender = header.get("from", "服务器")
            tag = "[历史]" if "history" in header else ""
            msg = data.decode()
            self.append_chat(f"{sender}: {msg}")
        elif msg_type == "file":
            filename = header.get("filename", "unknown_file")
            tag = "[历史]" if "history" in header else ""
            file_path = f"files/recv_{filename}"
            os.makedirs("files", exist_ok=True)
            with open(file_path, 'wb') as f:
                f.write(data)
            self.append_chat(f"{tag}收到文件: {filename}，已保存至 {file_path}")
        elif msg_type == "friend_request":
            sender = header.get("from")
            self.append_chat(f"收到好友请求: {sender}")
        elif msg_type == "list_friend_requests":
            try:
                requests = json.loads(data.decode())
                self.show_friend_requests(requests)
            except json.JSONDecodeError:
                self.append_chat("解析好友请求列表失败")
        elif msg_type == "admin_response":
            try:
                users = json.loads(data.decode())
                self.user_list.delete(*self.user_list.get_children())
                self.client_map.clear()
                response_type = header.get("response_type", "list_friends")
                if response_type == "list_friends":
                    for user, is_online in users:
                        self.client_map[user] = {'is_online': is_online, 'is_admin': False}
                        status = '在线' if is_online else '离线'
                        self.user_list.insert('', 'end', values=(user, status))
                    self.append_chat("好友列表已刷新")
                elif response_type == "list_users":
                    for user, is_online, is_admin in users:
                        self.client_map[user] = {'is_online': is_online, 'is_admin': is_admin}
                        status = '在线' if is_online else '离线'
                        admin_status = '是' if is_admin else '否'
                        self.user_list.insert('', 'end', values=(user, status))
                    action_result = header.get("action_result")
                    if action_result:
                        self.append_chat(action_result)
                    else:
                        self.append_chat("用户列表已刷新")
            except json.JSONDecodeError:
                self.append_chat("用户列表解析失败")
        elif msg_type == "error":
            self.append_chat(f"错误: {data.decode()}")

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
                self.append_chat(f"已接受 {requester} 的好友请求")
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
                self.append_chat(f"已拒绝 {requester} 的好友请求")
                tree.delete(selected[0])
            except Exception as e:
                messagebox.showerror("失败", f"拒绝好友请求失败: {e}")
        ttk.Button(requests_win, text="接受", command=accept_selected).pack(pady=5)
        ttk.Button(requests_win, text="拒绝", command=reject_selected).pack(pady=5)

    def send_chat(self):
        msg = self.msg_entry.get()
        selected = self.user_list.selection()
        if not selected:
            messagebox.showwarning("提示", "请选择接收好友")
            return
        target = self.user_list.item(selected[0])['values'][0]
        try:
            send_message(self.ssock, "chat", msg, extra_headers={"to": target})
            self.append_chat(f"我 -> {target}: {msg}")
            self.msg_entry.delete(0, 'end')
        except Exception as e:
            messagebox.showerror("发送失败", str(e))

    def send_file(self):
        filepath = filedialog.askopenfilename()
        if not filepath:
            return
        selected = self.user_list.selection()
        if not selected:
            messagebox.showwarning("提示", "请选择接收好友")
            return
        target = self.user_list.item(selected[0])['values'][0]
        filename = os.path.basename(filepath)
        try:
            with open(filepath, 'rb') as f:
                file_data = f.read()
                send_message(self.ssock, 'file', file_data,
                             extra_headers={"filename": filename, "to": target})
                self.append_chat(f"已发送文件: {filename} 给 {target}")
        except Exception as e:
            messagebox.showerror("发送失败", str(e))

    def add_friend(self):
        target = tk.simpledialog.askstring("添加好友", "输入要添加的好友用户名:")
        if not target:
            return
        try:
            send_message(self.ssock, "friend_request", "", extra_headers={"to": target})
            self.append_chat(f"已发送好友请求给 {target}")
        except Exception as e:
            messagebox.showerror("失败", f"发送好友请求失败: {e}")

    def view_friend_requests(self):
        try:
            send_message(self.ssock, "list_friend_requests", "")
        except Exception as e:
            messagebox.showerror("失败", f"获取好友请求失败: {e}")

    def append_chat(self, message):
        self.chat_text.config(state='normal')
        self.chat_text.insert('end', message + '\n')
        self.chat_text.config(state='disabled')
        self.chat_text.see('end')

    def update_status(self, message):
        self.status_var.set(message)

    def run(self):
        self.root.mainloop()

    def refresh_user_list(self):
        try:
            send_message(self.ssock, "list_friends", "")
        except Exception as e:
            self.update_status(f"刷新好友列表失败: {e}")

    def list_users(self):
        try:
            send_message(self.ssock, "admin_command", "", extra_headers={"action": "list_users"})
            self.root.after(100, self.show_all_users)
        except Exception as e:
            messagebox.showerror("失败", f"请求用户列表失败: {e}")

    def delete_user(self):
        target = tk.simpledialog.askstring("删除用户", "输入要删除的用户名:")
        if not target:
            return
        try:
            send_message(self.ssock, "admin_command", target, extra_headers={"action": "delete_user"})
            self.append_chat(f"已请求删除用户 {target}")
        except Exception as e:
            messagebox.showerror("失败", f"删除用户失败: {e}")

    def send_announcement(self):
        content = tk.simpledialog.askstring("发送公告", "输入公告内容:")
        if not content:
            return
        try:
            send_message(self.ssock, "admin_command", content, extra_headers={"action": "announcement"})
            self.append_chat("公告已发送")
        except Exception as e:
            messagebox.showerror("失败", f"发送公告失败: {e}")

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
        self.chat_text.config(state='normal')
        self.chat_text.delete('1.0', 'end')
        self.chat_text.config(state='disabled')
        self.user_list.delete(*self.user_list.get_children())
        self.admin_btn.grid_forget()
        self.chat_frame.grid_forget()
        self.update_status("已退出登录")
        self.show_login()

    def on_close(self):
        self.logout()
        self.root.destroy()

if __name__ == "__main__":
    app = ClientGUI()
    app.run()