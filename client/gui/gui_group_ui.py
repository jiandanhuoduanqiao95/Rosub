import tkinter as tk
from tkinter import ttk, messagebox
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
        if not group_name or not group_name.strip():
            messagebox.showwarning("警告", "群组名称不能为空！")
            return
        try:
            send_message(self.client_gui.ssock, "create_group", group_name)
            # 等待服务器响应（在 gui_message_handler.py 中处理）
            self.client_gui.chat_ui.append_chat("服务器", f"创建群组请求已发送: {group_name}")
        except Exception as e:
            self.client_gui.chat_ui.append_chat("服务器", f"创建群组失败: {str(e)}")
            logging.error(f"创建群组失败: {str(e)}")

    def join_group(self):
        group_id = tk.simpledialog.askstring("加入群组", "请输入群组ID:")
        if not group_id or not group_id.strip():
            messagebox.showwarning("警告", "群组ID不能为空！")
            return
        try:
            group_id = int(group_id)  # 确保输入是数字
            send_message(self.client_gui.ssock, "join_group", str(group_id))
            # 等待服务器响应（在 gui_message_handler.py 中处理）
            self.client_gui.chat_ui.append_chat("服务器", f"加入群组请求已发送: 群组ID {group_id}")
        except ValueError:
            messagebox.showerror("错误", "请输入有效的群组ID（数字）")
        except Exception as e:
            self.client_gui.chat_ui.append_chat("服务器", f"加入群组失败: {str(e)}")
            logging.error(f"加入群组失败: {str(e)}")