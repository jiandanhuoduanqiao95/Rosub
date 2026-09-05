import sys
import os
import tkinter as tk

# 确保项目根目录和当前包目录在 Python 路径中
#   项目根：使 protocol / config / validation 可导入
#   当前包：使 gui_login_ui / gui_chat_ui 等同级模块可导入
_project_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_package_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _project_root)
sys.path.insert(0, _package_dir)

from gui_login_ui import LoginUI
from gui_chat_ui import ChatUI
from gui_admin_ui import AdminUI
from gui_group_ui import GroupUI
from gui_message_handler import MessageHandler
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
        self.processed_group_file_requests = set()  # Track processed group file requests
        self.pending_file_requests = []
        self.showing_file_dialog = False

        # Initialize handler and UI components in correct order
        self.message_handler = MessageHandler(self)
        self.group_ui = GroupUI(self)
        self.admin_ui = AdminUI(self)  # Initialize AdminUI before ChatUI
        self.login_ui = LoginUI(self)
        self.chat_ui = ChatUI(self)

        # Show login UI initially
        self.login_ui.show_login()

        # Bind window close event
        self.root.protocol("WM_DELETE_WINDOW", self.on_close)

    def show_login(self):
        self.login_ui.show_login()

    def show_chat(self):
        self.chat_ui.show_chat()

    def logout(self):
        self.message_handler.logout()

    def on_close(self):
        self.logout()
        self.root.destroy()


if __name__ == "__main__":
    app = ClientGUI()
    app.root.mainloop()