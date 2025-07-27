import tkinter as tk
from tkinter import ttk
from protocol import send_message
import logging

class GroupUI:
    def __init__(self, client_gui):
        self.client_gui = client_gui

    def group_management(self):
        win = tk.Toplevel(self.client_gui.root)
        win.title("群组管理")
        ttk.Button(win, text="创建群组", command=self.create_group).pack(pady=5)
        ttk.Button(win, text="加入群组", command=self.join_group).pack(pady=5)

    def create_group(self):
        group_name = tk.simpledialog.askstring("创建群组", "请输入群组名称:")
        if group_name:
            try:
                send_message(self.client_gui.ssock, "create_group", group_name)
            except Exception as e:
                self.client_gui.chat_ui.append_chat("服务器", f"创建群组失败: {str(e)}")
                logging.error(f"创建群组失败: {str(e)}")

    def join_group(self):
        group_id = tk.simpledialog.askstring("加入群组", "请输入群组ID:")
        if group_id:
            try:
                send_message(self.client_gui.ssock, "join_group", group_id)
            except Exception as e:
                self.client_gui.chat_ui.append_chat("服务器", f"加入群组失败: {str(e)}")
                logging.error(f"加入群组失败: {str(e)}")