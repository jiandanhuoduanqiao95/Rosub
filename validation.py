"""
============================================================
输入验证模块
============================================================

提供用户名和密码的格式验证，在注册/登录前校验输入合法性，
防止 SQL 注入、空用户名、非法字符等问题。

validate_username(username) -> (bool, str)
  - 返回 (是否合法, 错误消息)

validate_password(password) -> (bool, str)
  - 返回 (是否合法, 错误消息)
"""

import re

# 用户名规则：字母、数字、下划线、连字符，长度 3–32
_USERNAME_PATTERN = re.compile(r'^[a-zA-Z0-9_-]{3,32}$')

# 密码最小/最大长度
_PASSWORD_MIN_LEN = 6
_PASSWORD_MAX_LEN = 128


def validate_username(username):
    """
    验证用户名格式。

    规则：
      - 不能为空
      - 长度 3–32 个字符
      - 只能包含：字母（a-z, A-Z）、数字（0-9）、下划线（_）、连字符（-）
      - 不能以空格开头或结尾（正则已覆盖——空格不在允许字符集中）
      - 不允许包含单引号、双引号、分号等 SQL 敏感字符（正则已覆盖）

    返回: (bool, str)
    """
    if not username:
        return False, "用户名不能为空"

    # 检查前后空格
    if username != username.strip():
        return False, "用户名不能包含前后空格"

    if len(username) < 3:
        return False, "用户名长度不能少于 3 个字符"

    if len(username) > 32:
        return False, "用户名长度不能超过 32 个字符"

    if not _USERNAME_PATTERN.match(username):
        return False, "用户名只能包含字母、数字、下划线和连字符"

    # SQL 注入纵深防御（正则应已过滤，但再检查一次特殊字符）
    dangerous_chars = {"'", '"', ';', '\\', '--', '/*', '*/'}
    for char in dangerous_chars:
        if char in username:
            return False, "用户名包含非法字符"

    return True, ""


def validate_password(password):
    """
    验证密码格式。

    规则：
      - 不能为空
      - 长度 6–128 个字符
      - 不能包含控制字符（如 \\n, \\r, \\t, \\x00-\\x1f）

    返回: (bool, str)
    """
    if not password:
        return False, "密码不能为空"

    if len(password) < _PASSWORD_MIN_LEN:
        return False, f"密码长度不能少于 {_PASSWORD_MIN_LEN} 个字符"

    if len(password) > _PASSWORD_MAX_LEN:
        return False, f"密码长度不能超过 {_PASSWORD_MAX_LEN} 个字符"

    # 检查控制字符（ASCII 0x00–0x1f，不含 0x7f DEL）
    for ch in password:
        if ord(ch) < 0x20:
            return False, "密码不能包含控制字符"

    return True, ""
