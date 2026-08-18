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

    # ---- 大文件磁盘存储（阶段 G）：文件内容不落 SQLite（BLOB 上限 ~1GB），存磁盘路径 ----

    def _file_store_dir(self):
        """文件存储根目录（位于数据库文件同级的 file_store 下，测试隔离）。"""
        base = os.path.dirname(os.path.abspath(self.db_name))
        d = os.path.join(base, "file_store")
        os.makedirs(d, exist_ok=True)
        return d

    def _pending_dir(self):
        d = os.path.join(self._file_store_dir(), "pending")
        os.makedirs(d, exist_ok=True)
        return d

    def _history_dir(self):
        d = os.path.join(self._file_store_dir(), "history")
        os.makedirs(d, exist_ok=True)
        return d

    def _delete_disk_file(self, file_path):
        if not file_path:
            return
        try:
            if os.path.exists(file_path):
                os.remove(file_path)
        except OSError as e:
            logging.warning(f"删除磁盘文件失败: {file_path}, {e}")

    def promote_file_to_history(self, file_path, message_id):
        """把待处理（pending）文件转入历史区，返回历史路径。

        使用原子 rename（同文件系统 O(1)），5GB 大文件无需复制；
        目标已存在（如群文件多个成员接受）时直接删除来源并复用。
        """
        if not file_path or not os.path.exists(file_path):
            return file_path
        dest = os.path.join(self._history_dir(), os.path.basename(file_path))
        try:
            if os.path.exists(dest):
                self._delete_disk_file(file_path)
                return dest
            os.rename(file_path, dest)
            return dest
        except OSError as e:
            logging.warning(f"文件转入历史区失败: {file_path}, {e}")
            return file_path

    def _init_db(self):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS users (
                    id INTEGER PRIMARY KEY,
                    username TEXT UNIQUE NOT NULL,
                    password_hash TEXT NOT NULL,
                    is_admin BOOLEAN DEFAULT FALSE,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    nickname TEXT DEFAULT '',
                    avatar TEXT DEFAULT '',
                    signature TEXT DEFAULT '',
                    last_seen TEXT
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
                    file_path TEXT,
                    status TEXT DEFAULT 'sent',
                    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    reply_to TEXT,
                    reply_preview TEXT
                )
            ''')
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS friends (
                    user1 TEXT NOT NULL,
                    user2 TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'pending',
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    note TEXT DEFAULT '',
                    group_name TEXT DEFAULT '',
                    request_message TEXT DEFAULT '',
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
                    file_path TEXT,
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
                    file_path TEXT,
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
                    file_path TEXT,
                    group_id INTEGER,
                    status TEXT DEFAULT 'sent',
                    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    reply_to TEXT
                )
            ''')
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS conversations (
                    username TEXT NOT NULL,
                    peer_key TEXT NOT NULL,
                    pinned INTEGER NOT NULL DEFAULT 0,
                    muted INTEGER NOT NULL DEFAULT 0,
                    draft TEXT NOT NULL DEFAULT '',
                    cleared_at TEXT,
                    PRIMARY KEY (username, peer_key)
                )
            ''')
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS blocked_users (
                    blocker TEXT NOT NULL,
                    blocked TEXT NOT NULL,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (blocker, blocked),
                    FOREIGN KEY (blocker) REFERENCES users(username),
                    FOREIGN KEY (blocked) REFERENCES users(username)
                )
            ''')
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS reactions (
                    message_id TEXT NOT NULL,
                    username TEXT NOT NULL,
                    emoji TEXT NOT NULL,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (message_id, username)
                )
            ''')

            # 迁移：为旧版 message_history 表添加 status 列
            try:
                cursor.execute("SELECT status FROM message_history LIMIT 1")
            except sqlite3.OperationalError:
                cursor.execute("ALTER TABLE message_history ADD COLUMN status TEXT DEFAULT 'sent'")
                logging.info("message_history 表已迁移：新增 status 列")

            # 迁移：message_history 表新增阶段 K 列（K5 引用回复）
            try:
                cursor.execute("SELECT reply_to FROM message_history LIMIT 1")
            except sqlite3.OperationalError:
                cursor.execute("ALTER TABLE message_history ADD COLUMN reply_to TEXT")
                logging.info("message_history 表已迁移：新增 reply_to 列")

            # 迁移：offline_messages 表新增阶段 K 列（K5 引用的离线投递元数据）
            for col in ("reply_to", "reply_preview"):
                try:
                    cursor.execute(f"SELECT {col} FROM offline_messages LIMIT 1")
                except sqlite3.OperationalError:
                    cursor.execute(f"ALTER TABLE offline_messages ADD COLUMN {col} TEXT")
                    logging.info(f"offline_messages 表已迁移：新增 {col} 列")

            # 迁移：为各表添加 file_path 列（阶段 G 大文件磁盘存储）
            for table in ("file_requests", "group_file_requests",
                          "offline_messages", "message_history"):
                try:
                    cursor.execute(f"SELECT file_path FROM {table} LIMIT 1")
                except sqlite3.OperationalError:
                    cursor.execute(f"ALTER TABLE {table} ADD COLUMN file_path TEXT")
                    logging.info(f"{table} 表已迁移：新增 file_path 列")

            # 迁移：users 表新增资料列（阶段 J：P0-2 用户资料）
            for col in ("nickname", "avatar", "signature"):
                try:
                    cursor.execute(f"SELECT {col} FROM users LIMIT 1")
                except sqlite3.OperationalError:
                    cursor.execute(f"ALTER TABLE users ADD COLUMN {col} TEXT DEFAULT ''")
                    logging.info(f"users 表已迁移：新增 {col} 列")
            try:
                cursor.execute("SELECT last_seen FROM users LIMIT 1")
            except sqlite3.OperationalError:
                cursor.execute("ALTER TABLE users ADD COLUMN last_seen TEXT")
                logging.info("users 表已迁移：新增 last_seen 列")

            # 迁移：friends 表新增好友备注/分组/验证消息列（阶段 J：P1-8/P1-10）
            for col in ("note", "group_name", "request_message"):
                try:
                    cursor.execute(f"SELECT {col} FROM friends LIMIT 1")
                except sqlite3.OperationalError:
                    cursor.execute(f"ALTER TABLE friends ADD COLUMN {col} TEXT DEFAULT ''")
                    logging.info(f"friends 表已迁移：新增 {col} 列")

            conn.commit()

    def add_user(self, username, password_hash, is_admin=False):
        with self._get_connection() as conn:
            try:
                cursor = conn.cursor()
                cursor.execute('''
                    INSERT INTO users (username, password_hash, is_admin)
                    VALUES (?, ?, ?)
                ''', (username, password_hash, 1 if is_admin else 0))
                conn.commit()
                return True
            except sqlite3.IntegrityError as e:
                logging.error(f"添加用户失败: {username}, 错误: {e}")
                return False

    def set_admin(self, username, is_admin=True):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                UPDATE users SET is_admin = ? WHERE username = ?
            ''', (1 if is_admin else 0, username))
            conn.commit()
            return cursor.rowcount > 0

    def update_password(self, username, old_hash, new_hash):
        """修改用户密码（阶段 G2）。

        old_hash 必须与数据库当前存储哈希按字节相等，匹配才允许替换。
        返回 True 表示替换成功；用户不存在或哈希不匹配返回 False。
        """
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('SELECT password_hash FROM users WHERE username = ?', (username,))
            row = cursor.fetchone()
            if not row or row[0] != old_hash:
                return False
            cursor.execute('''
                UPDATE users SET password_hash = ? WHERE username = ?
            ''', (new_hash, username))
            conn.commit()
            return cursor.rowcount > 0

    def get_user(self, username):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                SELECT password_hash, is_admin FROM users WHERE username = ?
            ''', (username,))
            return cursor.fetchone()

    def user_exists(self, username):
        return self.get_user(username) is not None

    # ============================================================
    # 用户资料（阶段 J：P0-2）
    # ============================================================

    def set_profile(self, username, nickname=None, avatar=None, signature=None):
        """部分更新用户资料：仅更新传入的非 None 字段；传 '' 表示清除。"""
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute("SELECT 1 FROM users WHERE username = ?", (username,))
                if cursor.fetchone() is None:
                    return False
                sets = []
                params = []
                if nickname is not None:
                    sets.append("nickname = ?")
                    params.append(nickname)
                if avatar is not None:
                    sets.append("avatar = ?")
                    params.append(avatar)
                if signature is not None:
                    sets.append("signature = ?")
                    params.append(signature)
                if not sets:
                    return True
                params.append(username)
                cursor.execute(f"UPDATE users SET {', '.join(sets)} WHERE username = ?", params)
                conn.commit()
                return True
        except sqlite3.Error as e:
            logging.error(f"设置用户资料失败: {username}, {e}")
            return False

    def get_profile(self, username):
        """查询用户资料；不存在返回 None。"""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                SELECT username, nickname, avatar, signature, last_seen, is_admin, created_at
                FROM users WHERE username = ?
            ''', (username,))
            row = cursor.fetchone()
            if not row:
                return None
            return {
                "username": row[0],
                "nickname": row[1] or "",
                "avatar": row[2] or "",
                "signature": row[3] or "",
                "last_seen": row[4],
                "is_admin": row[5],
                "created_at": row[6],
            }

    def update_last_seen(self, username):
        """更新最后在线时间为当前时间；用户不存在返回 False。"""
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute(
                    "UPDATE users SET last_seen = CURRENT_TIMESTAMP WHERE username = ?",
                    (username,))
                conn.commit()
                return cursor.rowcount > 0
        except sqlite3.Error as e:
            logging.error(f"更新最后在线时间失败: {username}, {e}")
            return False

    # ============================================================
    # 管理员重置密码（阶段 J：P0-5）
    # ============================================================

    def admin_reset_password(self, username, new_hash):
        """管理员直接覆写用户密码哈希（不校验旧密码）；用户不存在返回 False。"""
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute('''
                    UPDATE users SET password_hash = ? WHERE username = ?
                ''', (new_hash, username))
                conn.commit()
                return cursor.rowcount > 0
        except sqlite3.Error as e:
            logging.error(f"管理员重置密码失败: {username}, {e}")
            return False

    def save_offline_message(self, sender, receiver, message_type, content,
                             filename=None, message_id=None, file_path=None,
                             reply_to=None, reply_preview=None):
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute('''
                    INSERT INTO offline_messages
                        (message_id, sender, receiver, message_type, content,
                         filename, file_path, status, reply_to, reply_preview)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 'sent', ?, ?)
                ''', (message_id, sender, receiver, message_type, content,
                      filename, file_path, reply_to, reply_preview))
                conn.commit()
                logging.info(f"已保存离线消息：{sender} -> {receiver}, 类型={message_type}, 消息ID={message_id}")
        except Exception as e:
            logging.error(f"保存离线消息失败: {e}")

    def get_offline_messages(self, receiver):
        """获取用户的聊天消息（未读 + 最近已读历史）。

        返回 status='sent'（未读）的消息；status='delivered'（已读历史）的
        chat 消息也返回（作为最近消息保留，更早的通过 fetch_history 拉取）。
        已读的 file 消息不重复下发：否则每次登录/重连都会重发并覆写
        received_files 中的文件。
        返回元组包含 timestamp 字段（最后一列）。
        """
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                SELECT sender, message_type, content, filename, message_id, status, receiver, timestamp, file_path
                FROM offline_messages
                WHERE (receiver = ? OR (sender = ? AND receiver != ?))
                  AND (status = 'sent' OR (status = 'delivered' AND message_type != 'file'))
                ORDER BY timestamp ASC
                LIMIT 500
            ''', (receiver, receiver, receiver))
            messages = cursor.fetchall()

            # 将接收到的未读消息标记为已送达
            cursor.execute('''
                UPDATE offline_messages
                SET status = 'delivered'
                WHERE receiver = ? AND status = 'sent'
            ''', (receiver,))
            conn.commit()

            logging.info(f"获取聊天消息: 用户={receiver}, 共={len(messages)}条")
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
            cursor.execute('SELECT file_path FROM file_requests WHERE sender = ? OR receiver = ?',
                           (username, username))
            private_paths = [r[0] for r in cursor.fetchall() if r[0]]
            cursor.execute('SELECT file_path FROM group_file_requests WHERE sender = ?', (username,))
            group_paths = [r[0] for r in cursor.fetchall() if r[0]]
            cursor.execute('DELETE FROM friends WHERE user1 = ? OR user2 = ?', (username, username))
            cursor.execute('DELETE FROM file_requests WHERE sender = ? OR receiver = ?', (username, username))
            cursor.execute('DELETE FROM group_members WHERE username = ?', (username,))
            cursor.execute('DELETE FROM group_file_requests WHERE sender = ?', (username,))
            cursor.execute('DELETE FROM group_file_responses WHERE username = ?', (username,))
            cursor.execute('DELETE FROM blocked_users WHERE blocker = ? OR blocked = ?', (username, username))
            friends_deleted = cursor.rowcount
            cursor.execute('DELETE FROM users WHERE username = ?', (username,))
            users_deleted = cursor.rowcount
            conn.commit()
            for p in private_paths + group_paths:
                self._delete_disk_file(p)
            return users_deleted > 0 or friends_deleted > 0

    def save_file_request(self, sender, receiver, filename, filesize, content, message_id, file_path=None):
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute('''
                    INSERT INTO file_requests (message_id, sender, receiver, filename, filesize, content, file_path)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                ''', (message_id, sender, receiver, filename, filesize, content, file_path))
                conn.commit()
                logging.info(f"已保存文件请求：{sender} -> {receiver}, 文件名={filename}, 消息ID={message_id}")
        except Exception as e:
            logging.error(f"保存文件请求失败: {e}")

    def get_file_request(self, message_id):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                SELECT sender, receiver, filename, filesize, content, file_path
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
                    SELECT file_path FROM file_requests WHERE message_id = ?
                ''', (message_id,))
                row = cursor.fetchone()
                cursor.execute('''
                    DELETE FROM file_requests
                    WHERE message_id = ?
                ''', (message_id,))
                conn.commit()
                if cursor.rowcount > 0:
                    self._delete_disk_file(row[0] if row else None)
                    logging.info(f"文件请求已删除：消息ID={message_id}")
                    return True
                else:
                    logging.error(f"文件请求删除失败：消息ID={message_id} 不存在")
                    return False
        except sqlite3.Error as e:
            logging.error(f"文件请求删除失败: {e}")
            return False

    def save_group_file_request(self, group_id, sender, filename, filesize, content, message_id, file_path=None):
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute('''
                    INSERT INTO group_file_requests (message_id, group_id, sender, filename, filesize, content, file_path)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                ''', (message_id, group_id, sender, filename, filesize, content, file_path))
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
                SELECT group_id, sender, filename, filesize, content, file_path
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
                    SELECT file_path FROM group_file_requests WHERE message_id = ?
                ''', (message_id,))
                row = cursor.fetchone()
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
                    self._delete_disk_file(row[0] if row else None)
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

    def add_friend_request(self, requester, target, message=None):
        """添加好友请求；message 为可选验证消息（阶段 J：P1-10）。"""
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                if requester == target:
                    logging.error(f"好友请求失败: 不能添加自己为好友")
                    return False
                if not (self.user_exists(requester) and self.user_exists(target)):
                    logging.error(f"好友请求失败：用户 {requester} 或 {target} 不存在")
                    return False
                # 仅在已有 pending 请求或 accepted 好友关系时阻止
                cursor.execute('''
                    SELECT 1 FROM friends
                    WHERE ((user1 = ? AND user2 = ?) OR (user1 = ? AND user2 = ?))
                      AND status IN ('pending', 'accepted')
                ''', (requester, target, target, requester))
                if cursor.fetchone():
                    logging.error(f"好友请求已存在或已是好友：{requester} -> {target}")
                    return False
                cursor.execute('''
                    INSERT INTO friends (user1, user2, status, request_message)
                    VALUES (?, ?, 'pending', ?)
                ''', (requester, target, message or ""))
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
                # 删除该方向的所有记录 + 反方向的 pending 记录
                # 确保拒绝后双方都可重新发送请求
                cursor.execute('''
                    DELETE FROM friends
                    WHERE (user1 = ? AND user2 = ?)
                       OR (user1 = ? AND user2 = ? AND status = 'pending')
                ''', (requester, target, target, requester))
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

    def get_pending_friend_requests_detail(self, username):
        """查询待处理好友请求（含验证消息），按创建时间排序。"""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                SELECT user1, request_message FROM friends
                WHERE user2 = ? AND status = 'pending'
                ORDER BY created_at ASC
            ''', (username,))
            return [(row[0], row[1] or "") for row in cursor.fetchall()]

    # ============================================================
    # 好友备注名 / 分组（阶段 J：P1-8）
    # ============================================================

    def set_friend_note(self, username, friend, note):
        """设置好友备注名（本视图方向）；非好友关系返回 False。"""
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute('''
                    UPDATE friends SET note = ?
                    WHERE user1 = ? AND user2 = ? AND status = 'accepted'
                ''', (note or "", username, friend))
                conn.commit()
                return cursor.rowcount > 0
        except sqlite3.Error as e:
            logging.error(f"设置好友备注失败: {username} -> {friend}, {e}")
            return False

    def set_friend_group(self, username, friend, group_name):
        """设置好友分组名（本视图方向）；非好友关系返回 False。"""
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute('''
                    UPDATE friends SET group_name = ?
                    WHERE user1 = ? AND user2 = ? AND status = 'accepted'
                ''', (group_name or "", username, friend))
                conn.commit()
                return cursor.rowcount > 0
        except sqlite3.Error as e:
            logging.error(f"设置好友分组失败: {username} -> {friend}, {e}")
            return False

    def get_friends_meta(self, username):
        """查询好友元数据（备注/分组），返回 [{username, note, group_name}]。

        备注/分组均为"本视图方向"（user1 = username 的行）；
        对仅有反向行的旧数据（防御），备注/分组取空串。
        """
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                SELECT f.user2 AS friend, f.note, f.group_name
                FROM friends f
                WHERE f.user1 = ? AND f.status = 'accepted'
                UNION
                SELECT f.user1 AS friend, '', ''
                FROM friends f
                WHERE f.user2 = ? AND f.status = 'accepted'
                  AND NOT EXISTS (
                      SELECT 1 FROM friends g
                      WHERE g.user1 = ? AND g.user2 = f.user1
                        AND g.status = 'accepted'
                  )
            ''', (username, username, username))
            return [
                {"username": r[0], "note": r[1] or "", "group_name": r[2] or ""}
                for r in cursor.fetchall()
            ]

    # ============================================================
    # 黑名单（阶段 J：P1-9）
    # ============================================================

    def block_user(self, blocker, blocked):
        """拉黑用户（单向，INSERT OR IGNORE 幂等）；不能拉黑自己。"""
        if not blocker or not blocked or blocker == blocked:
            return False
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute('''
                    INSERT OR IGNORE INTO blocked_users (blocker, blocked)
                    VALUES (?, ?)
                ''', (blocker, blocked))
                conn.commit()
                return True
        except sqlite3.Error as e:
            logging.error(f"拉黑失败: {blocker} -> {blocked}, {e}")
            return False

    def unblock_user(self, blocker, blocked):
        """解除拉黑；不存在返回 False。"""
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute('''
                    DELETE FROM blocked_users
                    WHERE blocker = ? AND blocked = ?
                ''', (blocker, blocked))
                conn.commit()
                return cursor.rowcount > 0
        except sqlite3.Error as e:
            logging.error(f"解除拉黑失败: {blocker} -> {blocked}, {e}")
            return False

    def is_blocked(self, blocker, blocked):
        """单向语义：仅当 blocker 拉黑了 blocked 时为 True。"""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                SELECT 1 FROM blocked_users
                WHERE blocker = ? AND blocked = ?
            ''', (blocker, blocked))
            return cursor.fetchone() is not None

    def get_blocked_users(self, blocker):
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                SELECT blocked FROM blocked_users WHERE blocker = ?
            ''', (blocker,))
            return [row[0] for row in cursor.fetchall()]

    # ============================================================
    # 用户搜索（阶段 J：P1-10）
    # ============================================================

    def search_users(self, keyword, exclude=None, limit=50):
        """按用户名 LIKE 模糊搜索（不区分大小写）；空关键字返回 []。"""
        if not keyword:
            return []
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                like_pattern = f"%{keyword}%"
                if exclude:
                    cursor.execute('''
                        SELECT username FROM users
                        WHERE username LIKE ? AND username != ?
                        ORDER BY username ASC LIMIT ?
                    ''', (like_pattern, exclude, limit))
                else:
                    cursor.execute('''
                        SELECT username FROM users
                        WHERE username LIKE ?
                        ORDER BY username ASC LIMIT ?
                    ''', (like_pattern, limit))
                return [row[0] for row in cursor.fetchall()]
        except sqlite3.Error as e:
            logging.error(f"搜索用户失败: keyword={keyword}, {e}")
            return []

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
                # SQLite rowcount 仅统计实际变更的行，状态未变时返回 0。
                # 补充查询确认行存在，避免误报"不存在"。
                cursor.execute('SELECT 1 FROM offline_messages WHERE message_id = ?', (message_id,))
                if cursor.fetchone() is not None:
                    logging.info(f"消息状态更新：{message_id} -> {status}")
                    return True
                else:
                    logging.error(f"消息状态更新失败: {message_id} 不存在")
                    return False
        except sqlite3.Error as e:
            logging.error(f"消息状态更新失败: {e}")
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

    def message_id_exists(self, message_id, sender=None):
        """判断消息是否已写入永久历史（阶段 I：重发幂等去重）。

        客户端断线补发/手动重试会复用原 message_id，若消息此前已被服务端
        接收并入库（即便客户端认为发送失败），此处判定为重复 → 服务端跳过，
        避免"已送达消息被二次下发"。message_history 为永久表，不受
        offline_messages 清理影响。可选限定 sender，防止不同用户 message_id 撞车。
        """
        with self._get_connection() as conn:
            cursor = conn.cursor()
            if sender is None:
                cursor.execute(
                    "SELECT 1 FROM message_history WHERE message_id = ?",
                    (message_id,))
            else:
                cursor.execute(
                    "SELECT 1 FROM message_history WHERE message_id = ? AND sender = ?",
                    (message_id, sender))
            return cursor.fetchone() is not None

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

    def get_message_history_timestamp(self, message_id):
        """查询某条历史消息的 (timestamp, id)，用作分页游标。

        返回 (timestamp, id) 元组，或 None。
        同一秒内的消息 timestamp 相同，用 id 作为二级游标确保正确分页。
        """
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute(
                "SELECT timestamp, id FROM message_history WHERE message_id = ?",
                (message_id,))
            row = cursor.fetchone()
            return (row[0], row[1]) if row else None

    def update_message_history_status(self, message_id, status):
        """更新历史消息的状态（如撤回时标记为 'recalled'）"""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute(
                "UPDATE message_history SET status = ? WHERE message_id = ? OR message_id LIKE ?",
                (status, message_id, f"{message_id}_%"))
            conn.commit()
            return cursor.rowcount > 0

    # ============================================================
    # 阶段 K（K5 消息编辑/引用/转发/表情回应）数据层扩展
    # ============================================================

    def get_offline_extras(self, message_id):
        """查询离线消息的 K5 引用元数据，供登录推送组装 headers。

        返回 {reply_to, reply_preview}；不存在返回 None。
        不改动 get_offline_messages 的既有元组形态。
        """
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute(
                "SELECT reply_to, reply_preview "
                "FROM offline_messages WHERE message_id = ?",
                (message_id,))
            row = cursor.fetchone()
        if not row:
            return None
        return {
            "reply_to": row[0],
            "reply_preview": row[1],
        }

    @staticmethod
    def _history_row_dict(row):
        """把 message_history 行（含 K 扩展列）转为 dict。"""
        content = row[4]
        try:
            text = content.decode("utf-8") if isinstance(content, bytes) else str(content)
        except Exception:
            text = ""
        return {
            "sender": row[1],
            "receiver": row[2],
            "message_type": row[3],
            "content": text,
            "message_id": row[0],
            "filename": row[5],
            "timestamp": row[6],
            "group_id": row[7],
            "status": row[8] or "sent",
            "reply_to": row[9],
        }

    _HISTORY_ROW_COLUMNS = (
        "message_id, sender, receiver, message_type, content, filename, "
        "timestamp, group_id, status, reply_to"
    )

    def get_history_message(self, message_id):
        """按 message_id 查询单条历史消息；不存在返回 None。

        返回 dict：{sender, receiver, message_type, content(str), filename,
        group_id, status, reply_to}。
        """
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute(
                f"SELECT {self._HISTORY_ROW_COLUMNS} FROM message_history "
                "WHERE message_id = ?",
                (message_id,))
            row = cursor.fetchone()
        return self._history_row_dict(row) if row else None

    def get_message_history_rows(self, user, with_user=None, group_id=None,
                                 limit=50, before=None):
        """分页拉取历史消息（dict 行，含 K 扩展字段），时间倒序（最新在前）。

        范围/排序与既有 get_message_history 完全一致；供服务端
        history_response 组装（携带 reply_to）。
        """
        columns = self._HISTORY_ROW_COLUMNS
        with self._get_connection() as conn:
            cursor = conn.cursor()
            if group_id is not None:
                if before is not None:
                    ts, rid = before
                    cursor.execute(f'''
                        SELECT {columns} FROM message_history
                        WHERE group_id = ?
                          AND (timestamp < ? OR (timestamp = ? AND id < ?))
                        ORDER BY timestamp DESC, id DESC
                        LIMIT ?
                    ''', (group_id, ts, ts, rid, limit))
                else:
                    cursor.execute(f'''
                        SELECT {columns} FROM message_history
                        WHERE group_id = ?
                        ORDER BY timestamp DESC, id DESC
                        LIMIT ? OFFSET 0
                    ''', (group_id, limit))
            elif with_user is not None:
                if before is not None:
                    ts, rid = before
                    cursor.execute(f'''
                        SELECT {columns} FROM message_history
                        WHERE ((sender = ? AND receiver = ?)
                           OR (sender = ? AND receiver = ?))
                          AND (timestamp < ? OR (timestamp = ? AND id < ?))
                        ORDER BY timestamp DESC, id DESC
                        LIMIT ?
                    ''', (user, with_user, with_user, user, ts, ts, rid, limit))
                else:
                    cursor.execute(f'''
                        SELECT {columns} FROM message_history
                        WHERE (sender = ? AND receiver = ?)
                           OR (sender = ? AND receiver = ?)
                        ORDER BY timestamp DESC, id DESC
                        LIMIT ? OFFSET 0
                    ''', (user, with_user, with_user, user, limit))
            else:
                if before is not None:
                    ts, rid = before
                    cursor.execute(f'''
                        SELECT {columns} FROM message_history
                        WHERE (sender = ? OR receiver = ?)
                          AND (timestamp < ? OR (timestamp = ? AND id < ?))
                        ORDER BY timestamp DESC, id DESC
                        LIMIT ?
                    ''', (user, user, ts, ts, rid, limit))
                else:
                    cursor.execute(f'''
                        SELECT {columns} FROM message_history
                        WHERE sender = ? OR receiver = ?
                        ORDER BY timestamp DESC, id DESC
                        LIMIT ? OFFSET 0
                    ''', (user, user, limit))
            rows = cursor.fetchall()
        return [self._history_row_dict(r) for r in rows]

    def set_reaction(self, message_id, username, emoji):
        """设置用户对消息的表情回应（upsert：同用户换 emoji 替换）。"""
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute('''
                    INSERT INTO reactions (message_id, username, emoji)
                    VALUES (?, ?, ?)
                    ON CONFLICT(message_id, username)
                    DO UPDATE SET emoji = excluded.emoji
                ''', (message_id, username, emoji))
                conn.commit()
                return cursor.rowcount > 0
        except sqlite3.Error as e:
            logging.error(f"设置表情回应失败: {message_id}/{username}, {e}")
            return False

    def remove_reaction(self, message_id, username):
        """移除用户对消息的表情回应；不存在返回 False（幂等）。"""
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute(
                    "DELETE FROM reactions WHERE message_id = ? AND username = ?",
                    (message_id, username))
                conn.commit()
                return cursor.rowcount > 0
        except sqlite3.Error as e:
            logging.error(f"移除表情回应失败: {message_id}/{username}, {e}")
            return False

    def get_reactions(self, message_id):
        """查询消息的全部表情回应：[{username, emoji}]，按 created_at 升序。"""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute(
                "SELECT username, emoji FROM reactions "
                "WHERE message_id = ? ORDER BY created_at ASC, rowid ASC",
                (message_id,))
            rows = cursor.fetchall()
        return [{"username": r[0], "emoji": r[1]} for r in rows]

    def save_message_history(self, sender, receiver, message_type, content,
                             filename=None, group_id=None, message_id=None,
                             file_path=None, reply_to=None):
        """保存一条消息到 message_history 表（永久存储）

        阶段 K 扩展：reply_to（K5 引用回复，原消息 id）。
        """
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute('''
                    INSERT OR IGNORE INTO message_history
                        (message_id, sender, receiver, message_type, content,
                         filename, group_id, file_path, reply_to)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ''', (message_id, sender, receiver, message_type, content,
                      filename, group_id, file_path, reply_to))
                conn.commit()
                if cursor.rowcount > 0:
                    logging.info(f"消息已保存到历史: 类型={message_type}, 消息ID={message_id}")
                return cursor.rowcount > 0
        except sqlite3.Error as e:
            logging.error(f"保存消息历史失败: {e}")
            return False

    def get_message_history(self, user, with_user=None, group_id=None,
                            limit=50, offset=0, before=None):
        """分页拉取历史消息，按时间倒序（最新在前）。

        支持两种分页方式：
        - 游标分页（推荐）：before 为 (timestamp, id) 元组，返回该消息之前的消息。
          用 (timestamp, id) 组合游标，同一秒内的消息也能正确分页。
        - offset 分页：提供 offset，传统分页。向后兼容旧调用。
        """
        with self._get_connection() as conn:
            cursor = conn.cursor()
            if group_id is not None:
                if before is not None:
                    ts, rid = before
                    cursor.execute('''
                        SELECT sender, receiver, message_type, content, message_id,
                               filename, timestamp, group_id, status
                        FROM message_history
                        WHERE group_id = ?
                          AND (timestamp < ? OR (timestamp = ? AND id < ?))
                        ORDER BY timestamp DESC, id DESC
                        LIMIT ?
                    ''', (group_id, ts, ts, rid, limit))
                else:
                    cursor.execute('''
                        SELECT sender, receiver, message_type, content, message_id,
                               filename, timestamp, group_id, status
                        FROM message_history
                        WHERE group_id = ?
                        ORDER BY timestamp DESC, id DESC
                        LIMIT ? OFFSET ?
                    ''', (group_id, limit, offset))
            elif with_user is not None:
                if before is not None:
                    ts, rid = before
                    cursor.execute('''
                        SELECT sender, receiver, message_type, content, message_id,
                               filename, timestamp, group_id, status
                        FROM message_history
                        WHERE ((sender = ? AND receiver = ?)
                           OR (sender = ? AND receiver = ?))
                          AND (timestamp < ? OR (timestamp = ? AND id < ?))
                        ORDER BY timestamp DESC, id DESC
                        LIMIT ?
                    ''', (user, with_user, with_user, user, ts, ts, rid, limit))
                else:
                    cursor.execute('''
                        SELECT sender, receiver, message_type, content, message_id,
                               filename, timestamp, group_id, status
                        FROM message_history
                        WHERE (sender = ? AND receiver = ?)
                           OR (sender = ? AND receiver = ?)
                        ORDER BY timestamp DESC, id DESC
                        LIMIT ? OFFSET ?
                    ''', (user, with_user, with_user, user, limit, offset))
            else:
                if before is not None:
                    ts, rid = before
                    cursor.execute('''
                        SELECT sender, receiver, message_type, content, message_id,
                               filename, timestamp, group_id, status
                        FROM message_history
                        WHERE (sender = ? OR receiver = ?)
                          AND (timestamp < ? OR (timestamp = ? AND id < ?))
                        ORDER BY timestamp DESC, id DESC
                        LIMIT ?
                    ''', (user, user, ts, ts, rid, limit))
                else:
                    cursor.execute('''
                        SELECT sender, receiver, message_type, content, message_id,
                               filename, timestamp, group_id, status
                        FROM message_history
                        WHERE sender = ? OR receiver = ?
                        ORDER BY timestamp DESC, id DESC
                        LIMIT ? OFFSET ?
                    ''', (user, user, limit, offset))
            return cursor.fetchall()

    def search_message_history(self, user, keyword, with_user=None, group_id=None,
                               limit=50):
        """按关键字搜索历史消息（在 content 中做 LIKE 匹配）。

        范围（互斥，group_id 优先）：
        - group_id：群聊消息（群组内全部历史，与 fetch_history 的 group 分支一致）
        - with_user：与指定用户的私聊（双向）
        - 缺省：该用户参与的全部消息（全局）
        """
        with self._get_connection() as conn:
            cursor = conn.cursor()
            like_pattern = f"%{keyword}%"
            if group_id is not None:
                cursor.execute('''
                    SELECT sender, receiver, message_type, content, message_id,
                           filename, timestamp, group_id, status
                    FROM message_history
                    WHERE group_id = ?
                      AND CAST(content AS TEXT) LIKE ?
                    ORDER BY timestamp DESC, id DESC
                    LIMIT ?
                ''', (group_id, like_pattern, limit))
            elif with_user is not None:
                cursor.execute('''
                    SELECT sender, receiver, message_type, content, message_id,
                           filename, timestamp, group_id, status
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
                           filename, timestamp, group_id, status
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
        """清理过期的文件请求（私聊和群组），默认清理 7 天前的记录，连带删除磁盘文件。"""
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                # 清理过期私聊文件请求
                cursor.execute('''
                    SELECT file_path FROM file_requests
                    WHERE timestamp <= datetime('now', '-' || ? || ' days')
                ''', (expire_days,))
                private_paths = [r[0] for r in cursor.fetchall() if r[0]]
                cursor.execute('''
                    DELETE FROM file_requests
                    WHERE timestamp <= datetime('now', '-' || ? || ' days')
                ''', (expire_days,))
                private_deleted = cursor.rowcount

                # 清理过期群组文件请求及其响应
                cursor.execute('''
                    SELECT file_path FROM group_file_requests
                    WHERE timestamp <= datetime('now', '-' || ? || ' days')
                ''', (expire_days,))
                group_paths = [r[0] for r in cursor.fetchall() if r[0]]
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
                for p in private_paths + group_paths:
                    self._delete_disk_file(p)
                total = private_deleted + group_deleted
                logging.info(f"清理过期文件请求: 私聊={private_deleted}, 群组={group_deleted}, 合计={total}")
                return total
        except sqlite3.Error as e:
            logging.error(f"清理过期文件请求失败: {e}")
            return 0

    def remove_friend(self, user1, user2):
        """删除好友关系（双向），清除双向 friends 记录。

        幂等：即使当前不是好友也返回 True（用于残留清理）。
        """
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute('''
                    DELETE FROM friends
                    WHERE (user1 = ? AND user2 = ?)
                       OR (user1 = ? AND user2 = ?)
                ''', (user1, user2, user2, user1))
                conn.commit()
                logging.info(f"好友关系已清除: {user1} <-> {user2} (rowcount={cursor.rowcount})")
                return True
        except sqlite3.Error as e:
            logging.error(f"删除好友关系失败: {e}")
            return False

    def leave_group(self, group_id, username):
        """用户离开群组，从 group_members 表中删除对应行。"""
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute('''
                    DELETE FROM group_members
                    WHERE group_id = ? AND username = ?
                ''', (group_id, username))
                conn.commit()
                if cursor.rowcount > 0:
                    logging.info(f"用户 {username} 已离开群组 {group_id}")
                    return True
                else:
                    logging.info(f"用户 {username} 不在群组 {group_id} 中")
                    return False
        except sqlite3.Error as e:
            logging.error(f"离开群组失败: {e}")
            return False

    def delete_group(self, group_id):
        """删除群组及其所有关联数据（成员、历史、离线消息、文件请求、响应），连带磁盘文件。"""
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute("SELECT file_path FROM group_file_requests WHERE group_id = ?", (group_id,))
                paths = [r[0] for r in cursor.fetchall() if r[0]]
                cursor.execute("DELETE FROM group_file_responses WHERE group_id = ?", (group_id,))
                cursor.execute("DELETE FROM group_file_requests WHERE group_id = ?", (group_id,))
                cursor.execute("DELETE FROM message_history WHERE group_id = ?", (group_id,))
                cursor.execute("DELETE FROM group_members WHERE group_id = ?", (group_id,))
                # 清除离线群聊消息（内容为 {"text":...,"group_id": N} 的 JSON）
                # 精确匹配结尾 "group_id": N}，避免误删 group_id=10/11 等
                cursor.execute(
                    "DELETE FROM offline_messages WHERE message_type = 'group_chat' "
                    "AND CAST(content AS TEXT) LIKE ?",
                    (f'%"group_id": {group_id}}}',))
                cursor.execute("DELETE FROM groups WHERE id = ?", (group_id,))
                conn.commit()
                for p in paths:
                    self._delete_disk_file(p)
                logging.info(f"群组 {group_id} 已删除（含历史、离线消息和文件请求）")
                return True
        except sqlite3.Error as e:
            logging.error(f"删除群组 {group_id} 失败: {e}")
            return False

    # ============================================================
    # conversations 会话元数据表（阶段 I：P0-8）
    # 支撑会话置顶/静音/草稿/清空标记；主键 (username, peer_key)，
    # peer_key 为好友用户名或 'group_N'。
    # ============================================================

    def upsert_conversation(self, username, peer_key, pinned=None, muted=None,
                            draft=None, cleared_at=None):
        """插入或更新会话元数据（仅更新传入的非 None 字段，部分更新语义）。

        pinned/muted 传 True/False 均可（0/1 归一）；
        cleared_at 传 None 表示不清空（保持原值），传 '' 表示清除（回 NULL）。
        """
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute(
                    "SELECT 1 FROM conversations WHERE username=? AND peer_key=?",
                    (username, peer_key))
                exists = cursor.fetchone() is not None
                if not exists:
                    cursor.execute(
                        "INSERT INTO conversations "
                        "(username, peer_key, pinned, muted, draft, cleared_at) "
                        "VALUES (?, ?, ?, ?, ?, ?)",
                        (username, peer_key,
                         1 if pinned else 0,
                         1 if muted else 0,
                         draft if draft is not None else "",
                         cleared_at or None))
                else:
                    sets = []
                    params = []
                    if pinned is not None:
                        sets.append("pinned = ?")
                        params.append(1 if pinned else 0)
                    if muted is not None:
                        sets.append("muted = ?")
                        params.append(1 if muted else 0)
                    if draft is not None:
                        sets.append("draft = ?")
                        params.append(draft)
                    if cleared_at is not None:
                        sets.append("cleared_at = ?")
                        params.append(cleared_at or None)
                    if sets:
                        params.extend([username, peer_key])
                        cursor.execute(
                            f"UPDATE conversations SET {', '.join(sets)} "
                            "WHERE username=? AND peer_key=?",
                            params)
                conn.commit()
                return True
        except sqlite3.Error as e:
            logging.error(f"upsert 会话元数据失败: {username}/{peer_key}, {e}")
            return False

    @staticmethod
    def _conversation_row(row):
        return {
            "username": row[0],
            "peer_key": row[1],
            "pinned": bool(row[2]),
            "muted": bool(row[3]),
            "draft": row[4] or "",
            "cleared_at": row[5],
        }

    def get_conversation(self, username, peer_key):
        """查询单个会话元数据；不存在返回 None。"""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute(
                "SELECT username, peer_key, pinned, muted, draft, cleared_at "
                "FROM conversations WHERE username=? AND peer_key=?",
                (username, peer_key))
            row = cursor.fetchone()
        return self._conversation_row(row) if row else None

    def get_conversations(self, username):
        """查询该用户全部会话元数据（无会话返回空列表）。"""
        with self._get_connection() as conn:
            cursor = conn.cursor()
            cursor.execute(
                "SELECT username, peer_key, pinned, muted, draft, cleared_at "
                "FROM conversations WHERE username=?",
                (username,))
            rows = cursor.fetchall()
        return [self._conversation_row(r) for r in rows]

    def reset_conversation(self, username, peer_key):
        """删除会话元数据行（CRUD 的 D）；不存在返回 False。"""
        try:
            with self._get_connection() as conn:
                cursor = conn.cursor()
                cursor.execute(
                    "DELETE FROM conversations WHERE username=? AND peer_key=?",
                    (username, peer_key))
                conn.commit()
                return cursor.rowcount > 0
        except sqlite3.Error as e:
            logging.error(f"删除会话元数据失败: {username}/{peer_key}, {e}")
            return False
