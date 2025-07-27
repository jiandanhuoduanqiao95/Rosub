import tkinter as tk
from tkinter import ttk, messagebox
import socket
import ssl
from protocol import send_message, recv_message
import threading
import logging

class LoginUI:
    def __init__(self, client_gui):
        self.client_gui = client_gui
        self.login_frame = None
        self.action_var = None
        self.username_entry = None
        self.password_entry = None
        self.setup_login_ui()

    def setup_login_ui(self):
        self.login_frame = ttk.Frame(self.client_gui.root, padding=20)
        self.action_var = tk.StringVar(value="login")
        ttk.Radiobutton(self.login_frame, text="登录", variable=self.action_var, value="login").grid(row=0, column=0)
        ttk.Radiobutton(self.login_frame, text="注册", variable=self.action_var, value="register").grid(row=0, column=1)
        ttk.Label(self.login_frame, text="用户名:").grid(row=1, column=0, pady=5)
        self.username_entry = ttk.Entry(self.login_frame)
        self.username_entry.grid(row=1, column=1, pady=5)
        ttk.Label(self.login_frame, text="密码:").grid(row=2, column=0, pady=5)
        self.password_entry = ttk.Entry(self.login_frame, show="*")
        self.password_entry.grid(row=2, column=1, pady=5)
        login_btn = ttk.Button(self.login_frame, text="确定", command=self.do_auth)
        login_btn.grid(row=3, columnspan=2, pady=10)

    def do_auth(self):
        action = self.action_var.get()
        username = self.username_entry.get()
        password = self.password_entry.get()
        try:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.load_verify_locations("SSL/tsetcn.crt")
            client_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            client_socket.connect(('127.0.0.1', 8090))
            self.client_gui.ssock = context.wrap_socket(client_socket, server_hostname='tset.cn')
            send_message(self.client_gui.ssock, action, username, extra_headers={"password": password})
            header, data = recv_message(self.client_gui.ssock)
            if header.get("type") == "error":
                messagebox.showerror("错误", data.decode())
                return
            if header.get("type") == "admin_auth":
                self.client_gui.is_admin = True
                messagebox.showinfo("成功", "管理员登录成功！")
            self.client_gui.username = username
            self.client_gui.show_chat()
            threading.Thread(target=self.client_gui.message_handler.listen_for_messages, daemon=True).start()
        except Exception as e:
            messagebox.showerror("连接错误", str(e))

    def show_login(self):
        self.client_gui.chat_ui.chat_frame.grid_forget()
        self.login_frame.grid()
        self.client_gui.root.geometry("300x200")