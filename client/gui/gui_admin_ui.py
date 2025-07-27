import tkinter as tk
from tkinter import ttk
import json
from protocol import send_message
import logging

class AdminUI:
    def __init__(self, client_gui):
        self.client_gui = client_gui

    def show_admin_panel(self):
        admin_win = tk.Toplevel(self.client_gui.root)
        admin_win.title("管理员面板")
        ttk.Button(admin_win, text="查看所有用户", command=self.list_users).pack(pady=5)
        ttk.Button(admin_win, text="删除用户", command=self.delete_user).pack(pady=5)
        ttk.Button(admin_win, text="发送公告", command=self.send_announcement).pack(pady=5)

    def list_users(self):
        try:
            send_message(self.client_gui.ssock, "admin_command", "", extra_headers={"action": "list_users"})
        except Exception as e:
            self.client_gui.chat_ui.append_chat("服务器", f"获取用户列表失败: {str(e)}")
            logging.error(f"获取用户列表失败: {str(e)}")

    def show_users(self, users):
        win = tk.Toplevel(self.client_gui.root)
        win.title("用户列表")
        tree = ttk.Treeview(win, columns=('username', 'status', 'admin'), show='headings')
        tree.heading('username', text='用户名')
        tree.heading('status', text='状态')
        tree.heading('admin', text='管理员')
        tree.pack(fill='both', expand=True)
        for user, online, is_admin in users:
            status = "在线" if online else "离线"
            admin_status = "是" if is_admin else "否"
            tree.insert("", "end", values=(user, status, admin_status))

    def delete_user(self):
        username = tk.simpledialog.askstring("删除用户", "请输入要删除的用户名:")
        if username:
            try:
                send_message(self.client_gui.ssock, "admin_command", username, extra_headers={"action": "delete_user"})
            except Exception as e:
                self.client_gui.chat_ui.append_chat("服务器", f"删除用户失败: {str(e)}")
                logging.error(f"删除用户失败: {str(e)}")

    def send_announcement(self):
        msg = tk.simpledialog.askstring("发送公告", "请输入公告内容:")
        if msg:
            try:
                send_message(self.client_gui.ssock, "admin_command", msg, extra_headers={"action": "announcement"})
            except Exception as e:
                self.client_gui.chat_ui.append_chat("服务器", f"发送公告失败: {str(e)}")
                logging.error(f"发送公告失败: {str(e)}")