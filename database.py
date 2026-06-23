import sqlite3
from contextlib import contextmanager
from datetime import datetime
import os
import logging

class Database:
    def __init__(self, db_name=None):
        if db_name is None:
            from config import config
            db_name = config.get("database.path", "users.db")
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
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS groups (
                    id INTEGER PRIMARY KEY,
                    group_name TEXT UNIQUE NOT NULL,
                    created_by TEXT NOT NULL,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    FOREIGN KEY (created_by) REFERENCES users(username)
                )
            ''')
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS group_members (
                    group_id INTEGER NOT NULL,
                    username TEXT NOT NULL,
                    joined_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (group_id, username),
                    FOREIGN KEY (group_id) REFERENCES groups(id),
                    FOREIGN KEY (username) REFERENCES users(username)
                )
            ''')
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS group_file_requests (
                    id INTEGER PRIMARY KEY,
                    message_id TEXT UNIQUE NOT NULL,
                    group_id INTEGER NOT NULL,
                    sender TEXT NOT NULL,
                    filename TEXT NOT NULL,
                    filesize INTEGER NOT NULL,
                    content BLOB NOT NULL,
                    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    FOREIGN KEY (group_id) REFERENCES groups(id),
                    FOREIGN KEY (sender) REFERENCES users(username)
                )
            ''')
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS group_file_responses (
                    message_id TEXT NOT NULL,
                    group_id INTEGER NOT NULL,
                    username TEXT NOT NULL,
                    response TEXT NOT NULL,  -- 'accept' or 'reject'
                    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (message_id, group_id, username),
                    FOREIGN KEY (message_id) REFERENCES group_file_requests(message_id),
                    FOREIGN KEY (group_id) REFERENCES groups(id),
                    FOREIGN KEY (username) REFERENCES users(username)
                )
            ''')
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS message_history (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    message_id TEXT UNIQUE NOT NULL,
                    sender TEXT NOT NULL,
                    receiver TEXT NOT NULL,
                    message_type TEXT NOT NULL,
                    content BLOB NOT NULL,
                    filename TEXT,
                    group_id INTEGER,
                    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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
        """获取离线消息（接收到的 + 自己发出的）。
        
        接收方登录时看到的离线消息包括：
          1. 别人发给自己的消息（receiver = self）
          2. 自己发给别人的消息（sender = self），用于恢复会话上下文
        """
        with self._get_connection() as conn:
            cursor = conn.cursor()
            # 获取别人发给自己的离线消息
            cursor.execute('''
                SELECT sender, message_type, content, filename, message_id, status, receiver
                FROM offline_messages 
                WHERE receiver = ? AND status = 'sent'
            ''', (receiver,))
            received = cursor.fetchall()
            # 获取自己发出的离线消息（对方未接收的）
            cursor.execute('''
                SELECT sender, message_type, content, filename, message_id, status, receiver
                FROM offline_messages 
                WHERE sender = ? AND receiver != ? AND status = 'sent'
            ''', (receiver, receiver))
            sent = cursor.fetchall()

            # 将接收到的消息标记为已送达
            cursor.execute('''
                UPDATE offline_messages 
                SET status = 'delivered'
                WHERE receiver = ? AND status = 'sent'
            ''', (receiver,))
            conn.commit()

            messages = received + sent
            logging.info(f"获取离线消息: 用户={receiver}, 接收={len(received)}条, 发出={len(sent)}条, 合计={len(messages)}条")
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
            cursor.execute('DELETE FROM group_members WHERE username = ?', (username,))
            cursor.execute('DELETE FROM group_file_requests WHERE sender = ?', (username,))
            cursor.execute('DELETE FROM group_file_responses WHERE username = ?', (username,))
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

    def save_group_file_request(self, group_id, sender, filename, filesize, content, message_id):
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute('''
                    INSERT INTO group_file_requests (message_id, group_id, sender, filename, filesize, content)
                    VALUES (?, ?, ?, ?, ?, ?)
                ''', (message_id, group_id, sender, filename, filesize, content))
                conn.commit()
                logging.info(f"已保存群组文件请求：群组ID={group_id}, 发送者={sender}, 文件名={filename}, 消息ID={message_id}")
                return True
        except Exception as e:
            logging.error(f"保存群组文件请求失败: {e}")
            return False

    def get_group_file_request(self, message_id):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                SELECT group_id, sender, filename, filesize, content
                FROM group_file_requests
                WHERE message_id = ?
            ''', (message_id,))
            return cursor.fetchone()

    def get_pending_group_file_requests(self, group_id, username):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                SELECT sender, filename, filesize, message_id
                FROM group_file_requests
                WHERE group_id = ? AND message_id NOT IN (
                    SELECT message_id FROM group_file_responses WHERE username = ?
                )
            ''', (group_id, username))
            return cursor.fetchall()

    def delete_group_file_request(self, message_id):
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute('''
                    DELETE FROM group_file_requests
                    WHERE message_id = ?
                ''', (message_id,))
                cursor.execute('''
                    DELETE FROM group_file_responses
                    WHERE message_id = ?
                ''', (message_id,))
                conn.commit()
                if cursor.rowcount > 0:
                    logging.info(f"群组文件请求已删除：消息ID={message_id}")
                    return True
                else:
                    logging.error(f"群组文件请求删除失败：消息ID={message_id} 不存在")
                    return False
        except sqlite3.Error as e:
            logging.error(f"群组文件请求删除失败: {e}")
            return False

    def save_group_file_response(self, message_id, group_id, username, response):
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute('''
                    INSERT INTO group_file_responses (message_id, group_id, username, response)
                    VALUES (?, ?, ?, ?)
                ''', (message_id, group_id, username, response))
                conn.commit()
                logging.info(f"已保存群组文件响应：消息ID={message_id}, 群组ID={group_id}, 用户={username}, 响应={response}")
                return True
        except sqlite3.Error as e:
            logging.error(f"保存群组文件响应失败: {e}")
            return False

    def all_members_responded(self, message_id, group_id):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            # 获取发送者（发送者不需要响应自己的请求）
            cursor.execute('''
                SELECT sender FROM group_file_requests
                WHERE message_id = ?
            ''', (message_id,))
            sender_row = cursor.fetchone()
            sender = sender_row[0] if sender_row else None

            cursor.execute('''
                SELECT username
                FROM group_members
                WHERE group_id = ?
            ''', (group_id,))
            members = [row[0] for row in cursor.fetchall()]
            cursor.execute('''
                SELECT username
                FROM group_file_responses
                WHERE message_id = ? AND group_id = ?
            ''', (message_id, group_id))
            responded = [row[0] for row in cursor.fetchall()]
            # 排除发送者：发送者不需要响应自己的文件请求
            members_to_check = [m for m in members if m != sender]
            return set(members_to_check).issubset(set(responded))

    def add_friend_request(self, requester, target):
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                if requester == target:
                    logging.error(f"好友请求失败: 不能添加自己为好友")
                    return False
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

    def create_group(self, group_name, creator):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                INSERT INTO groups (group_name, created_by)
                VALUES (?, ?)
            ''', (group_name, creator))
            group_id = cursor.lastrowid
            cursor.execute('''
                INSERT INTO group_members (group_id, username)
                VALUES (?, ?)
            ''', (group_id, creator))
            conn.commit()
            logging.info(f"群组创建成功: {group_name}, ID={group_id}, 创建者={creator}")
            return group_id

    def join_group(self, group_id, username):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                INSERT OR IGNORE INTO group_members (group_id, username)
                VALUES (?, ?)
            ''', (group_id, username))
            conn.commit()
            logging.info(f"用户 {username} 加入群组: ID={group_id}")

    def get_user_groups(self, username):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                SELECT g.id, g.group_name
                FROM groups g
                JOIN group_members gm ON g.id = gm.group_id
                WHERE gm.username = ?
            ''', (username,))
            return cursor.fetchall()

    def get_group_members(self, group_id):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                SELECT username
                FROM group_members
                WHERE group_id = ?
            ''', (group_id,))
            return [row[0] for row in cursor.fetchall()]

    def is_group_member(self, group_id, username):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                SELECT 1
                FROM group_members
                WHERE group_id = ? AND username = ?
            ''', (group_id, username))
            return cursor.fetchone() is not None

    # ============================================================
    # 消息历史持久化
    # ============================================================

    def save_message_history(self, sender, receiver, message_type, content,
                             filename=None, group_id=None, message_id=None):
        """保存一条消息到 message_history 表（永久存储）"""
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute('''
                    INSERT OR IGNORE INTO message_history
                        (message_id, sender, receiver, message_type, content, filename, group_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                ''', (message_id, sender, receiver, message_type, content, filename, group_id))
                conn.commit()
                if cursor.rowcount > 0:
                    logging.info(f"消息已保存到历史: 类型={message_type}, 消息ID={message_id}")
                return cursor.rowcount > 0
        except sqlite3.Error as e:
            logging.error(f"保存消息历史失败: {e}")
            return False

    def get_message_history(self, user, with_user=None, group_id=None,
                            limit=50, offset=0):
        """分页拉取历史消息，按时间倒序（最新在前）"""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            if group_id is not None:
                cursor.execute('''
                    SELECT sender, receiver, message_type, content, message_id,
                           filename, timestamp, group_id
                    FROM message_history
                    WHERE group_id = ?
                    ORDER BY timestamp DESC, id DESC
                    LIMIT ? OFFSET ?
                ''', (group_id, limit, offset))
            elif with_user is not None:
                cursor.execute('''
                    SELECT sender, receiver, message_type, content, message_id,
                           filename, timestamp, group_id
                    FROM message_history
                    WHERE (sender = ? AND receiver = ?)
                       OR (sender = ? AND receiver = ?)
                    ORDER BY timestamp DESC, id DESC
                    LIMIT ? OFFSET ?
                ''', (user, with_user, with_user, user, limit, offset))
            else:
                cursor.execute('''
                    SELECT sender, receiver, message_type, content, message_id,
                           filename, timestamp, group_id
                    FROM message_history
                    WHERE sender = ? OR receiver = ?
                    ORDER BY timestamp DESC, id DESC
                    LIMIT ? OFFSET ?
                ''', (user, user, limit, offset))
            return cursor.fetchall()

    def search_message_history(self, user, keyword, with_user=None, limit=50):
        """按关键字搜索历史消息（在 content 中做 LIKE 匹配）"""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            like_pattern = f"%{keyword}%"
            if with_user is not None:
                cursor.execute('''
                    SELECT sender, receiver, message_type, content, message_id,
                           filename, timestamp, group_id
                    FROM message_history
                    WHERE ((sender = ? AND receiver = ?)
                       OR (sender = ? AND receiver = ?))
                      AND CAST(content AS TEXT) LIKE ?
                    ORDER BY timestamp DESC, id DESC
                    LIMIT ?
                ''', (user, with_user, with_user, user, like_pattern, limit))
            else:
                cursor.execute('''
                    SELECT sender, receiver, message_type, content, message_id,
                           filename, timestamp, group_id
                    FROM message_history
                    WHERE (sender = ? OR receiver = ?)
                      AND CAST(content AS TEXT) LIKE ?
                    ORDER BY timestamp DESC, id DESC
                    LIMIT ?
                ''', (user, user, like_pattern, limit))
            return cursor.fetchall()

    def get_message_history_count(self, user, with_user=None, group_id=None):
        """获取消息总数（用于分页计算）"""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            if group_id is not None:
                cursor.execute('''
                    SELECT COUNT(*) FROM message_history WHERE group_id = ?
                ''', (group_id,))
            elif with_user is not None:
                cursor.execute('''
                    SELECT COUNT(*) FROM message_history
                    WHERE (sender = ? AND receiver = ?)
                       OR (sender = ? AND receiver = ?)
                ''', (user, with_user, with_user, user))
            else:
                cursor.execute('''
                    SELECT COUNT(*) FROM message_history
                    WHERE sender = ? OR receiver = ?
                ''', (user, user))
            return cursor.fetchone()[0]

    # ============================================================
    # 离线文件过期清理
    # ============================================================

    def cleanup_expired_file_requests(self, expire_days=7):
        """清理过期的文件请求（私聊和群组），默认清理 7 天前的记录。"""
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                # 清理过期私聊文件请求
                cursor.execute('''
                    DELETE FROM file_requests
                    WHERE timestamp <= datetime('now', '-' || ? || ' days')
                ''', (expire_days,))
                private_deleted = cursor.rowcount

                # 清理过期群组文件请求及其响应
                cursor.execute('''
                    DELETE FROM group_file_responses
                    WHERE message_id IN (
                        SELECT message_id FROM group_file_requests
                        WHERE timestamp <= datetime('now', '-' || ? || ' days')
                    )
                ''', (expire_days,))
                cursor.execute('''
                    DELETE FROM group_file_requests
                    WHERE timestamp <= datetime('now', '-' || ? || ' days')
                ''', (expire_days,))
                group_deleted = cursor.rowcount

                conn.commit()
                total = private_deleted + group_deleted
                logging.info(f"清理过期文件请求: 私聊={private_deleted}, 群组={group_deleted}, 合计={total}")
                return total
        except sqlite3.Error as e:
            logging.error(f"清理过期文件请求失败: {e}")
            return 0