import sqlite3
from contextlib import contextmanager
from datetime import datetime

class Database:
    def __init__(self,db_name="users.db"):
        self.db_name=db_name
        self._init_db()

    @contextmanager
    def _get_connection(self):
        conn=sqlite3.connect(self.db_name)
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
                        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            ''')
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

    def get_user(self,username):
        with self._get_connection() as conn:
            cursor=conn.cursor()
            cursor.execute('''
                SELECT password_hash FROM users WHERE username = ?
            ''',(username,))
            return cursor.fetchone()# 返回 (password_hash,) 或 None

    def user_exists(self,username):
        return self.get_user(username)