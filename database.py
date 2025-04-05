import sqlite3
from contextlib import contextmanager
from datetime import datetime
import os
import logging

class Database:
    def __init__(self,db_name="users.db"):
        self.db_name=db_name
        print(f"数据库路径: {os.path.abspath(self.db_name)}")#用于确认数据库位置
        self._init_db()

    @contextmanager
    def _get_connection(self):
        conn=sqlite3.connect(self.db_name,check_same_thread=False)#启用多线程
        try:
            yield conn
        finally:
            conn.close()

    def _init_db(self):
        with self._get_connection() as conn:
            cursor=conn.cursor()
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS users (
                        id INTEGER PRIMARY KEY,
                        username TEXT UNIQUE NOT NULL,
                        password_hash TEXT NOT NULL,
                        is_admin BOOLEAN DEFAULT FALSE,  -- 新增管理员标识
                        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            ''')

            cursor.execute('''
                CREATE TABLE IF NOT EXISTS offline_messages (
                        id INTEGER PRIMARY KEY,
                        sender TEXT NOT NULL,
                        receiver TEXT NOT NULL,
                        message_type TEXT NOT NULL,  -- 'chat' 或 'file'
                        content BLOB NOT NULL,
                        filename TEXT,               -- 仅文件类型需要
                        timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                    )
                ''')  # 新增离线消息表
            conn.commit()

    def add_user(self,username,password_hash):
        with self._get_connection() as conn:
            try:
                cursor=conn.cursor()
                cursor.execute('''
                    INSERT INTO users (username, password_hash)
                    VALUES (?, ?)
                ''',(username,password_hash))
                conn.commit()
                return True
            except sqlite3.IntegrityError:
                return False#用户名重复

    def get_user(self, username):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                SELECT password_hash, is_admin FROM users WHERE username = ?
            ''', (username,))
            return cursor.fetchone()  # 返回 (password_hash, is_admin) 或 None

    def user_exists(self,username):
        return self.get_user(username)

    def save_offline_message(self, sender, receiver, message_type, content, filename=None):
        """保存离线消息"""
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute('''
                    INSERT INTO offline_messages (sender, receiver, message_type, content, filename)
                    VALUES (?, ?, ?, ?, ?)
                ''', (sender, receiver, message_type, content, filename))
                conn.commit()
                logging.info(f"已保存离线消息：{sender} -> {receiver}, 类型={message_type}")
        except Exception as e:
            logging.info(f"保存离线消息失败: {e}")  # 捕获并打印异常

    def get_offline_messages(self, receiver):
        """获取指定用户的离线消息并删除已读消息"""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            # 查询消息
            cursor.execute('''
                SELECT sender, message_type, content, filename 
                FROM offline_messages 
                WHERE receiver = ?
            ''', (receiver,))
            messages = cursor.fetchall()
            # 删除已读消息
            cursor.execute('''
                DELETE FROM offline_messages 
                WHERE receiver = ?
            ''', (receiver,))
            conn.commit()
            return messages

    def get_all_users(self):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('SELECT username, is_admin FROM users')
            return cursor.fetchall()

    def delete_user(self, username):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('DELETE FROM users WHERE username = ?', (username,))
            conn.commit()