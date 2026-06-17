from database import Database
import bcrypt
db = Database()
pw = bcrypt.hashpw(b'admin123', bcrypt.gensalt())
db.add_user('admin', pw)
import sqlite3
conn = sqlite3.connect('users.db')
conn.execute("UPDATE users SET is_admin = 1 WHERE username = 'admin'")
conn.commit()
conn.close()
print('管理员 admin 已创建，密码 admin123')