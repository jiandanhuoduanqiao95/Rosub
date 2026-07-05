import getpass
import os
import sys

import bcrypt

from database import Database
from validation import validate_password, validate_username


def _read_password():
    password = os.environ.get("CHATROOM_ADMIN_PASSWORD")
    if password:
        return password
    password = getpass.getpass("管理员密码: ")
    confirm = getpass.getpass("再次输入管理员密码: ")
    if password != confirm:
        print("两次输入的密码不一致", file=sys.stderr)
        sys.exit(1)
    return password


def main():
    username = os.environ.get("CHATROOM_ADMIN_USERNAME", "admin").strip()
    valid, error = validate_username(username)
    if not valid:
        print(f"管理员用户名无效: {error}", file=sys.stderr)
        sys.exit(1)

    password = _read_password()
    valid, error = validate_password(password)
    if not valid:
        print(f"管理员密码无效: {error}", file=sys.stderr)
        sys.exit(1)

    db = Database()
    password_hash = bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt())
    if db.user_exists(username):
        if db.set_admin(username, True):
            print(f"用户 {username} 已提升为管理员")
            return
        print(f"提升用户 {username} 失败", file=sys.stderr)
        sys.exit(1)

    if db.add_user(username, password_hash, is_admin=True):
        print(f"管理员 {username} 已创建")
        return
    print(f"管理员 {username} 创建失败", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()
