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
                    message_id TEXT UNIQUE NOT NULL,
                    sender TEXT NOT NULL,
                    receiver TEXT NOT NULL,
                    message_type TEXT NOT NULL,
                    content BLOB NOT NULL,
                    filename TEXT,
                    status TEXT DEFAULT 'sent',
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
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS file_requests (
                    id INTEGER PRIMARY KEY,
                    message_id TEXT UNIQUE NOT NULL,
                    sender TEXT NOT NULL,
                    receiver TEXT NOT NULL,
                    filename TEXT NOT NULL,
                    filesize INTEGER NOT NULL,
                    content BLOB NOT NULL,
                    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    FOREIGN KEY (sender) REFERENCES users(username),
                    FOREIGN KEY (receiver) REFERENCES users(username)
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

    def save_offline_message(self, sender, receiver, message_type, content, filename=None, message_id=None):
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute('''
                    INSERT INTO offline_messages (message_id, sender, receiver, message_type, content, filename, status)
                    VALUES (?, ?, ?, ?, ?, ?, 'sent')
                ''', (message_id, sender, receiver, message_type, content, filename))
                conn.commit()
                logging.info(f"已保存离线消息：{sender} -> {receiver}, 类型={message_type}, 消息ID={message_id}")
        except Exception as e:
            logging.error(f"保存离线消息失败: {e}")

    def get_offline_messages(self, receiver):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                SELECT sender, message_type, content, filename, message_id, status
                FROM offline_messages 
                WHERE receiver = ? AND status = 'sent'
            ''', (receiver,))
            messages = cursor.fetchall()
            cursor.execute('''
                UPDATE offline_messages 
                SET status = 'delivered'
                WHERE receiver = ? AND status = 'sent'
            ''', (receiver,))
            conn.commit()
            logging.info(f"获取离线消息: 接收者={receiver}, 消息数={len(messages)}")
            return messages

    def cleanup_delivered_messages(self, receiver):
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute('''
                    DELETE FROM offline_messages 
                    WHERE receiver = ? AND status = 'delivered'
                ''', (receiver,))
                deleted_count = cursor.rowcount
                conn.commit()
                logging.info(f"清理已送达消息: 接收者={receiver}, 删除消息数={deleted_count}")
                return deleted_count
        except sqlite3.Error as e:
            logging.error(f"清理已送达消息失败: {e}")
            return 0

    def get_all_users(self):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('SELECT username, is_admin FROM users')
            return cursor.fetchall()

    def delete_user(self, username):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('DELETE FROM friends WHERE user1 = ? OR user2 = ?', (username, username))
            cursor.execute('DELETE FROM file_requests WHERE sender = ? OR receiver = ?', (username, username))
            friends_deleted = cursor.rowcount
            cursor.execute('DELETE FROM users WHERE username = ?', (username,))
            users_deleted = cursor.rowcount
            conn.commit()
            return users_deleted > 0 or friends_deleted > 0

    def save_file_request(self, sender, receiver, filename, filesize, content, message_id):
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute('''
                    INSERT INTO file_requests (message_id, sender, receiver, filename, filesize, content)
                    VALUES (?, ?, ?, ?, ?, ?)
                ''', (message_id, sender, receiver, filename, filesize, content))
                conn.commit()
                logging.info(f"已保存文件请求：{sender} -> {receiver}, 文件名={filename}, 消息ID={message_id}")
        except Exception as e:
            logging.error(f"保存文件请求失败: {e}")

    def get_file_request(self, message_id):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                SELECT sender, receiver, filename, filesize, content
                FROM file_requests
                WHERE message_id = ?
            ''', (message_id,))
            return cursor.fetchone()

    def get_pending_file_requests(self, receiver):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                SELECT sender, filename, filesize, message_id
                FROM file_requests
                WHERE receiver = ?
            ''', (receiver,))
            return cursor.fetchall()

    def delete_file_request(self, message_id):
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute('''
                    DELETE FROM file_requests
                    WHERE message_id = ?
                ''', (message_id,))
                conn.commit()
                if cursor.rowcount > 0:
                    logging.info(f"文件请求已删除：消息ID={message_id}")
                    return True
                else:
                    logging.error(f"文件请求删除失败：消息ID={message_id} 不存在")
                    return False
        except sqlite3.Error as e:
            logging.error(f"文件请求删除失败: {e}")
            return False

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

    def update_message_status(self, message_id, status):
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute('''
                    UPDATE offline_messages
                    SET status = ?
                    WHERE message_id = ?
                ''', (status, message_id))
                conn.commit()
                if cursor.rowcount > 0:
                    logging.info(f"消息状态更新：{message_id} -> {status}")
                    return True
                else:
                    logging.error(f"消息状态更新失败：{message_id} 不存在")
                    return False
        except sqlite3.Error as e:
            logging.error(f"消息状态更新失败: {e}")
            return False

    def get_message_info(self, message_id):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                SELECT sender, receiver, message_type, content, filename, status, timestamp
                FROM offline_messages
                WHERE message_id = ?
            ''', (message_id,))
            return cursor.fetchone()