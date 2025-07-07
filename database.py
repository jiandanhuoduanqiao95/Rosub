import sqlite3
from contextlib import contextmanager
from datetime import datetime
import os
import logging

class Database:
    def __init__(self, db_name="users.db"):
        self.db_name = db_name
        print(f"数据库路径: {os.path.abspath(self.db_name)}")
        self._init_db()

    @contextmanager
    def _get_connection(self):
        conn = sqlite3.connect(self.db_name, check_same_thread=False)
        try:
            yield conn
        finally:
            conn.close()

    def _init_db(self):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS users (
                    id INTEGER PRIMARY KEY,
                    username TEXT UNIQUE NOT NULL,
                    password_hash TEXT NOT NULL,
                    is_admin BOOLEAN DEFAULT FALSE,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            ''')
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS offline_messages (
                    id INTEGER PRIMARY KEY,
                    sender TEXT NOT NULL,
                    receiver TEXT NOT NULL,
                    message_type TEXT NOT NULL,
                    content BLOB NOT NULL,
                    filename TEXT,
                    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            ''')
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS friends (
                    user1 TEXT NOT NULL,
                    user2 TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'pending',
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (user1, user2),
                    FOREIGN KEY (user1) REFERENCES users(username),
                    FOREIGN KEY (user2) REFERENCES users(username)
                )
            ''')
            conn.commit()

    def add_user(self, username, password_hash):
        with self._get_connection() as conn:
            try:
                cursor = conn.cursor()
                cursor.execute('''
                    INSERT INTO users (username, password_hash)
                    VALUES (?, ?)
                ''', (username, password_hash))
                conn.commit()
                return True
            except sqlite3.IntegrityError as e:
                logging.error(f"添加用户失败: {username}, 错误: {e}")
                return False

    def get_user(self, username):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                SELECT password_hash, is_admin FROM users WHERE username = ?
            ''', (username,))
            return cursor.fetchone()

    def user_exists(self, username):
        return self.get_user(username) is not None

    def save_offline_message(self, sender, receiver, message_type, content, filename=None):
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
            logging.error(f"保存离线消息失败: {e}")

    def get_offline_messages(self, receiver):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                SELECT sender, message_type, content, filename 
                FROM offline_messages 
                WHERE receiver = ?
            ''', (receiver,))
            messages = cursor.fetchall()
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
            cursor.execute('DELETE FROM friends WHERE user1 = ? OR user2 = ?', (username, username))
            friends_deleted = cursor.rowcount
            cursor.execute('DELETE FROM users WHERE username = ?', (username,))
            users_deleted = cursor.rowcount
            conn.commit()
            return users_deleted > 0 or friends_deleted > 0


    def add_friend_request(self, requester, target):
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                if not (self.user_exists(requester) and self.user_exists(target)):
                    logging.error(f"好友请求失败：用户 {requester} 或 {target} 不存在")
                    return False
                cursor.execute('''
                    SELECT 1 FROM friends 
                    WHERE (user1 = ? AND user2 = ?) OR (user1 = ? AND user2 = ?)
                ''', (requester, target, target, requester))
                if cursor.fetchone():
                    logging.error(f"好友请求已存在或已是好友：{requester} -> {target}")
                    return False
                cursor.execute('''
                    INSERT INTO friends (user1, user2, status)
                    VALUES (?, ?, 'pending')
                ''', (requester, target))
                conn.commit()
                logging.info(f"好友请求已保存：{requester} -> {target}")
                return True
        except sqlite3.Error as e:
            logging.error(f"添加好友请求失败: {e}")
            return False

    def accept_friend_request(self, requester, target):
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute('''
                    UPDATE friends
                    SET status = 'accepted'
                    WHERE user1 = ? AND user2 = ?
                ''', (requester, target))
                if cursor.rowcount == 0:
                    logging.error(f"没有找到好友请求：{requester} -> {target}")
                    return False
                cursor.execute('''
                    SELECT 1 FROM friends WHERE user1 = ? AND user2 = ?
                ''', (target, requester))
                if not cursor.fetchone():
                    cursor.execute('''
                        INSERT INTO friends (user1, user2, status)
                        VALUES (?, ?, 'accepted')
                    ''', (target, requester))
                conn.commit()
                logging.info(f"好友请求已接受：{requester} <-> {target}")
                return True
        except sqlite3.Error as e:
            logging.error(f"接受好友请求失败: {e}")
            return False

    def reject_friend_request(self, requester, target):
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute('''
                    DELETE FROM friends WHERE user1 = ? AND user2 = ? AND status = 'pending'
                ''', (requester, target))
                conn.commit()
                if cursor.rowcount > 0:
                    logging.info(f"好友请求已拒绝：{requester} -> {target}")
                    return True
                else:
                    logging.error(f"没有找到好友请求：{requester} -> {target}")
                    return False
        except sqlite3.Error as e:
            logging.error(f"拒绝好友请求失败: {e}")
            return False

    def get_friends(self, username):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                SELECT user2 AS friend FROM friends 
                WHERE user1 = ? AND status = 'accepted'
                UNION
                SELECT user1 AS friend FROM friends 
                WHERE user2 = ? AND status = 'accepted'
            ''', (username, username))
            return [row[0] for row in cursor.fetchall()]

    def get_pending_friend_requests(self, username):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                SELECT user1 FROM friends 
                WHERE user2 = ? AND status = 'pending'
            ''', (username,))
            return [row[0] for row in cursor.fetchall()]

    def is_friend(self, user1, user2):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                SELECT 1 FROM friends 
                WHERE ((user1 = ? AND user2 = ?) OR (user1 = ? AND user2 = ?))
                AND status = 'accepted'
            ''', (user1, user2, user2, user1))
            return cursor.fetchone() is not None

    def has_pending_request(self, requester, target):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                SELECT 1 FROM friends 
                WHERE user1 = ? AND user2 = ? AND status = 'pending'
            ''', (requester, target))
            return cursor.fetchone() is not None