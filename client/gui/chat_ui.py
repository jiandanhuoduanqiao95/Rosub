import tkinter as tk
from tkinter import ttk
import logging

class ChatUI:
     def __init__(self, client_gui):
         self.client_gui = client_gui
         self.chat_frame = None
         self.user_list = None
         self.current_friend_label = None
         self.chat_container = None
         self.msg_entry = None
         self.file_btn = None
         self.send_btn = None
         self.recall_btn = None
         self.refresh_btn = None
         self.add_friend_btn = None
         self.view_requests_btn = None
         self.group_btn = None
         self.logout_btn = None
         self.admin_btn = None
         self.status_var = None
         self.status_bar = None
         self.setup_chat_ui()

     def setup_chat_ui(self):
         self.chat_frame = ttk.Frame(self.client_gui.root)
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
         self.client_gui.chat_windows["服务器"].tag_configure("announcement", font=('Arial', 10, 'bold'), foreground="red")

         self.msg_entry = ttk.Entry(self.chat_frame, width=40)
         self.msg_entry.grid(row=2, column=1, padx=5, pady=5)
         self.file_btn = ttk.Button(self.chat_frame, text="发送文件", command=self.client_gui.message_handler.send_file)
         self.file_btn.grid(row=2, column=2, padx=5)
         self.send_btn = ttk.Button(self.chat_frame, text="发送", command=self.client_gui.message_handler.send_chat)
         self.send_btn.grid(row=3, column=1, columnspan=2, pady=5)
         self.recall_btn = ttk.Button(self.chat_frame, text="撤回消息", command=self.client_gui.message_handler.recall_message)
         self.recall_btn.grid(row=4, column=1, columnspan=2, pady=5)
         self.refresh_btn = ttk.Button(self.chat_frame, text="刷新好友", command=self.client_gui.message_handler.refresh_user_list)
         self.refresh_btn.grid(row=2, column=0, padx=5)
         self.add_friend_btn = ttk.Button(self.chat_frame, text="添加好友", command=self.client_gui.message_handler.add_friend)
         self.add_friend_btn.grid(row=3, column=0, padx=5)
         self.view_requests_btn = ttk.Button(self.chat_frame, text="查看好友请求", command=self.client_gui.message_handler.view_friend_requests)
         self.view_requests_btn.grid(row=4, column=0, padx=5)
         self.group_btn = ttk.Button(self.chat_frame, text="群组管理", command=self.client_gui.group_ui.group_management)
         self.group_btn.grid(row=5, column=0, padx=5)
         self.logout_btn = ttk.Button(self.chat_frame, text="退出", command=self.client_gui.logout, width=12)
         self.logout_btn.grid(row=6, column=1, columnspan=2, pady=10)
         self.admin_btn = ttk.Button(self.chat_frame, text="管理面板", command=self.client_gui.admin_ui.show_admin_panel)
         self.status_var = tk.StringVar()
         self.status_bar = ttk.Label(self.chat_frame, textvariable=self.status_var)
         self.status_bar.grid(row=7, columnspan=3, sticky='ew')

     def create_chat_window(self, friend):
         if friend not in self.client_gui.chat_windows:
             chat_text = tk.Text(self.chat_container, width=50, height=20, state='disabled')
             chat_text.bind("<Button-1>", self.client_gui.message_handler.on_chat_text_click)
             self.client_gui.chat_windows[friend] = chat_text
             self.client_gui.chat_histories[friend] = []
             if friend in self.client_gui.chat_histories:
                 chat_text.config(state='normal')
                 for msg in self.client_gui.chat_histories[friend]:
                     chat_text.insert('end', msg['text'], msg.get('tag'))
                 chat_text.config(state='disabled')
                 chat_text.see('end')
         return self.client_gui.chat_windows[friend]

     def switch_chat_window(self, friend):
         if friend == self.client_gui.current_friend:
             return
         if self.client_gui.current_friend and self.client_gui.current_friend in self.client_gui.chat_windows:
             self.client_gui.chat_windows[self.client_gui.current_friend].grid_forget()
         self.client_gui.current_friend = friend
         self.current_friend_label.config(text=f"与 {friend} 的聊天")
         chat_window = self.create_chat_window(friend)
         chat_window.grid(row=0, column=0, sticky='nsew')
         chat_window.config(state='normal')
         chat_window.delete('1.0', 'end')
         for msg in self.client_gui.chat_histories[friend]:
             line_number = int(float(chat_window.index('end-1c')))
             chat_text = chat_window
             chat_text.insert('end', msg['text'], msg.get('tag'))
             if msg.get('tag', '').startswith("clickable_message_"):
                 message_id = msg['tag'][len("clickable_message_"):]
                 self.client_gui.message_lines[message_id] = (friend, line_number)
         chat_window.config(state='disabled')
         chat_window.see('end')
         logging.info(f"切换到聊天窗口: {friend}")

     def on_user_select(self, event):
         selected = self.user_list.selection()
         if selected:
             friend = self.user_list.item(selected[0])['values'][0]
             self.switch_chat_window(friend)

     def show_chat(self):
         self.client_gui.login_ui.username_entry.delete(0, 'end')
         self.client_gui.login_ui.password_entry.delete(0, 'end')
         self.client_gui.login_ui.login_frame.grid_forget()
         self.chat_frame.grid()
         if self.client_gui.is_admin:
             self.admin_btn.grid(row=0, column=2, sticky='ne')
         self.client_gui.root.geometry("800x500")
         self.client_gui.root.title(f"聊天室 - {self.client_gui.username}")
         self.client_gui.message_handler.refresh_user_list()

     def append_chat(self, friend, message, tag=None):
         self.client_gui.root.after(0, self._append_chat, friend, message, tag)

     def _append_chat(self, friend, message, tag=None):
         if friend not in self.client_gui.chat_windows:
             self.create_chat_window(friend)
         chat_text = self.client_gui.chat_windows[friend]
         chat_text.config(state='normal')
         line_number = int(float(chat_text.index('end-1c')))
         chat_text.insert('end', message + '\n', tag)
         if tag and tag.startswith("clickable_message_"):
             message_id = tag[len("clickable_message_"):]
             self.client_gui.message_lines[message_id] = (friend, line_number)
         self.client_gui.chat_histories[friend].append({"text": message + "\n", "tag": tag})
         chat_text.config(state='disabled')
         chat_text.see('end')
         if friend == self.client_gui.current_friend:
             chat_text.see('end')

     def update_status(self, msg):
         self.status_var.set(msg)