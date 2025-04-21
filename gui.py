import tkinter as tk
from tkinter import ttk, messagebox, filedialog,simpledialog
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
        self.setup_login_ui()
        self.setup_chat_ui()
        self.show_login()
        self.root.protocol("WM_DELETE_WINDOW", self.on_close)

    def setup_login_ui(self):
        """登录/注册界面"""
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
        """主聊天界面"""
        self.chat_frame = ttk.Frame(self.root)

        # 用户列表
        self.user_list = ttk.Treeview(self.chat_frame, columns=('status'), show='tree')
        self.user_list.heading('#0', text='在线用户')
        self.user_list.heading('status', text='状态')
        self.user_list.grid(row=0, column=0, rowspan=3, padx=5, pady=5, sticky='ns')

        # 聊天显示区域
        self.chat_text = tk.Text(self.chat_frame, width=50, height=20, state='disabled')
        self.chat_text.grid(row=0, column=1, columnspan=2, padx=5, pady=5)

        # 消息输入
        self.msg_entry = ttk.Entry(self.chat_frame, width=40)
        self.msg_entry.grid(row=1, column=1, padx=5, pady=5)

        # 按钮区域
        self.file_btn = ttk.Button(self.chat_frame, text="发送文件", command=self.send_file)
        self.file_btn.grid(row=1, column=2, padx=5)

        self.send_btn = ttk.Button(self.chat_frame, text="发送", command=self.send_chat)
        self.send_btn.grid(row=2, column=1, columnspan=2, pady=5)

        self.refresh_btn = ttk.Button(self.chat_frame, text="刷新用户", command=self.refresh_user_list)
        self.refresh_btn.grid(row=2, column=0, padx=5)

        self.logout_btn = ttk.Button(self.chat_frame, text="退出", command=self.logout, width=12)
        self.logout_btn.grid(row=4, column=1, columnspan=2, pady=10)

        # 管理员按钮
        self.admin_btn = ttk.Button(self.chat_frame, text="管理面板", command=self.show_admin_panel)

        # 状态栏
        self.status_var = tk.StringVar()
        self.status_bar = ttk.Label(self.chat_frame, textvariable=self.status_var)
        self.status_bar.grid(row=3, columnspan=3, sticky='ew')

    def show_login(self):
        """显示登录界面"""
        self.chat_frame.grid_forget()
        self.login_frame.grid()
        self.root.geometry("300x200")

    def show_chat(self):
        """显示主聊天界面"""
        # 清空登录输入框内容
        self.username_entry.delete(0, 'end')
        self.password_entry.delete(0, 'end')

        # 隐藏登录界面，显示主界面
        self.login_frame.grid_forget()
        self.chat_frame.grid()

        if self.is_admin:
            self.admin_btn.grid(row=0, column=2, sticky='ne')

        self.root.geometry("800x500")
        self.root.title(f"聊天室 - {self.username}")

    def show_admin_panel(self):
        """管理员面板"""
        admin_win = tk.Toplevel(self.root)
        admin_win.title("管理员面板")

        ttk.Button(admin_win, text="查看用户列表", command=self.list_users).pack(pady=5)
        ttk.Button(admin_win, text="删除用户", command=self.delete_user).pack(pady=5)
        ttk.Button(admin_win, text="发送公告", command=self.send_announcement).pack(pady=5)

    def do_auth(self):
        """执行登录/注册"""
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
        """监听服务器消息"""
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
        """处理接收到的消息"""
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

        elif msg_type == "admin_response":
            try:
                users = json.loads(data.decode())
                self.user_list.delete(*self.user_list.get_children())  # 清空旧数据
                for user in users:
                    self.user_list.insert('', 'end', text=user[0], values=('管理员' if user[1] else '普通用户'))
            except json.JSONDecodeError:
                self.append_chat("用户列表解析失败")

    def send_chat(self):
        """发送聊天消息"""
        msg = self.msg_entry.get()
        selected = self.user_list.selection()

        if not selected:
            messagebox.showwarning("提示", "请选择接收用户")
            return

        target = self.user_list.item(selected[0])['text']

        try:
            send_message(self.ssock, "chat", msg, extra_headers={"to": target})
            self.append_chat(f"我 -> {target}: {msg}")
            self.msg_entry.delete(0, 'end')
        except Exception as e:
            messagebox.showerror("发送失败", str(e))

    def send_file(self):
        """发送文件"""
        filepath = filedialog.askopenfilename()
        if not filepath:
            return

        selected = self.user_list.selection()
        if not selected:
            messagebox.showwarning("提示", "请选择接收用户")
            return

        target = self.user_list.item(selected[0])['text']
        filename = os.path.basename(filepath)

        try:
            with open(filepath, 'rb') as f:
                file_data = f.read()
                send_message(self.ssock, 'file', file_data,
                             extra_headers={"filename": filename, "to": target})
                self.append_chat(f"已发送文件: {filename} 给 {target}")
        except Exception as e:
            messagebox.showerror("发送失败", str(e))

    def append_chat(self, message):
        """添加聊天消息到显示区域"""
        self.chat_text.config(state='normal')
        self.chat_text.insert('end', message + '\n')
        self.chat_text.config(state='disabled')
        self.chat_text.see('end')

    def update_status(self, message):
        """更新状态栏"""
        self.status_var.set(message)

    def run(self):
        self.root.mainloop()

    def refresh_user_list(self):
        try:
            send_message(self.ssock, "admin_command", "list_users", extra_headers={"action": "list_users"})
        except Exception as e:
            self.update_status(f"刷新用户列表失败: {e}")

    #实现管理员功能
    def list_users(self):
        try:
            send_message(self.ssock, "admin_command", "list_users", extra_headers={"action": "list_users"})
        except Exception as e:
            messagebox.showerror("失败", f"请求用户列表失败: {e}")

    def delete_user(self):
        target = tk.simpledialog.askstring("删除用户", "输入要删除的用户名:")
        if not target:
            return
        send_message(self.ssock, "admin_command", target, extra_headers={"action": "delete_user"})

    def send_announcement(self):
        content = tk.simpledialog.askstring("发送公告", "输入公告内容:")
        if not content:
            return
        send_message(self.ssock, "admin_command", content, extra_headers={"action": "announcement"})

    def logout(self):
        """退出登录"""
        try:
            if self.ssock:
                send_message(self.ssock, "chat", "quit")
                self.ssock.close()
        except Exception:
            pass
        self.ssock = None
        self.username = ""
        self.is_admin = False
        self.chat_text.config(state='normal')
        self.chat_text.delete('1.0', 'end')
        self.chat_text.config(state='disabled')
        self.user_list.delete(*self.user_list.get_children())
        self.admin_btn.grid_forget()
        self.update_status("已退出登录")
        #self.show_login()
        self.root.destroy()

    def on_close(self):
        """关闭窗口时释放资源"""
        self.logout()
        self.root.destroy()


if __name__ == "__main__":
    app = ClientGUI()
    app.run()