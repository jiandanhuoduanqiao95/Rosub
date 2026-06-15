"""
============================================================
输入验证 —— 单元测试（TDD）
============================================================

【功能目标】
  新增用户名、密码格式验证函数，在注册/登录前校验输入合法性，
  防止 SQL 注入、空用户名、非法字符等问题。

【新增模块】
  validation.py（建议放在项目根目录）:
    - validate_username(username) -> (bool, str)
      返回 (是否合法, 错误消息)
    - validate_password(password) -> (bool, str)
      返回 (是否合法, 错误消息)

【验证规则】
  用户名:
    - 不能为空
    - 长度 3–32 个字符
    - 只能包含：字母（a-z, A-Z）、数字（0-9）、下划线（_）、连字符（-）
    - 不能以空格开头或结尾
    - 不允许包含单引号、双引号、分号等 SQL 敏感字符（纵深防御）

  密码:
    - 不能为空
    - 长度 6–128 个字符
    - 不能包含控制字符（如 \n, \r, \t）

【测试策略】
  - 纯函数测试，不依赖数据库
  - 覆盖：正常输入、边界值、非法输入、SQL 注入尝试
"""

import sys
import os
import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# 注意：validation.py 尚未创建，导入时会失败。
# 这是 TDD 预期的——先写测试，测试失败后实现功能使测试通过。
from validation import validate_username, validate_password


# ============================================================
# 第 1 组：合法用户名测试
# ============================================================

class TestValidUsernames:
    """【合法用户名测试】验证各种合法格式通过校验"""

    @pytest.mark.parametrize("username", [
        "alice",
        "bob",
        "user123",
        "test_user",
        "user-name",
        "Abc",         # 3 字符，边界最小值
        "a" * 32,      # 恰好 32 字符，边界最大值
        "Alice_Bob_123",
        "xYz_987-test",
        "UPPERCASE",
        "lowercase",
        "mixedCase",
        "12345678",     # 纯数字也可以
        "____",         # 纯下划线
        "name123_with-hyphen",
    ])
    def test_valid_username(self, username):
        """
        【VL-01】各种合法格式的用户名通过验证
        
        参数化测试：覆盖英文字母、数字、下划线、连字符的组合。
        """
        valid, error = validate_username(username)
        assert valid is True, f"'{username}' 应该合法，但返回错误: {error}"
        assert error == ""


# ============================================================
# 第 2 组：非法用户名测试
# ============================================================

class TestInvalidUsernames:
    """【非法用户名测试】验证各种非法输入被拒绝并返回有意义的错误消息"""

    def test_empty_username(self):
        """
        【VL-02】空字符串被拒绝

        验证点：返回错误消息中包含"空"或"不能为空"
        """
        valid, error = validate_username("")
        assert valid is False
        assert len(error) > 0, "错误消息不应为空"

    def test_whitespace_only_username(self):
        """
        【VL-03】纯空格用户名被拒绝

        验证点：空格不应被视为有效用户名
        """
        valid, error = validate_username("   ")
        assert valid is False

    def test_too_short_username(self):
        """
        【VL-04】短于 3 个字符的用户名被拒绝

        验证点：1-2 字符返回错误
        """
        for short in ["a", "ab"]:
            valid, error = validate_username(short)
            assert valid is False, f"'{short}' 太短，应被拒绝"

    def test_too_long_username(self):
        """
        【VL-05】长于 32 个字符的用户名被拒绝

        验证点：33 字符及以上返回错误
        """
        long_name = "a" * 33
        valid, error = validate_username(long_name)
        assert valid is False, f"'{long_name[:10]}...' (len={len(long_name)}) 太长，应被拒绝"

        # 极端长
        very_long = "a" * 256
        valid, error = validate_username(very_long)
        assert valid is False

    def test_special_characters(self):
        """
        【VL-06】包含特殊字符的用户名被拒绝

        验证点：空格、@、#、$、%、^、&、*、(、)、+、= 等均不合法
        """
        invalid_names = [
            "user name",     # 空格
            "user@domain",   # @
            "name#tag",      # #
            "price$dollar",  # $
            "percent%",      # %
            "caret^",        # ^
            "amp&ersand",    # &
            "star*",         # *
            "parens()",      # ( )
            "plus+",         # +
            "equals=",       # =
            "dot.dot",       # .
            "slash/slash",   # /
            "back\\slash",   # \
            "colon:test",    # :
            "semi;colon",    # ;
        ]
        for name in invalid_names:
            valid, error = validate_username(name)
            assert valid is False, f"'{name}' 包含非法字符，应被拒绝"

    def test_leading_trailing_spaces(self):
        """
        【VL-07】前后有空格的用户名被拒绝

        验证点：strip 后与原始不同的应拒绝
        """
        for name in [" alice", "alice ", " alice "]:
            valid, error = validate_username(name)
            assert valid is False, f"'{name}' 包含前后空格，应被拒绝"

    def test_sql_injection_attempts(self):
        """
        【VL-08】SQL 注入尝试被拒绝

        验证点：包含单引号、双引号、分号、注释符的用户名被拒绝
        """
        injection_attempts = [
            "alice'--",
            "bob'; DROP TABLE users; --",
            'username" OR "1"="1',
            "test'; SELECT * FROM users; --",
            "normal'name",
            'name"with"quotes',
        ]
        for name in injection_attempts:
            valid, error = validate_username(name)
            assert valid is False, f"SQL 注入尝试 '{name}' 应被拒绝"


# ============================================================
# 第 3 组：边界值测试
# ============================================================

class TestUsernameBoundary:
    """【边界值测试】验证长度和内容的边界行为"""

    def test_exactly_three_characters(self):
        """
        【VL-09】恰好 3 个字符的用户名合法

        边界：最小值 3
        """
        valid, error = validate_username("abc")
        assert valid is True

    def test_exactly_thirty_two_characters(self):
        """
        【VL-10】恰好 32 个字符的用户名合法

        边界：最大值 32
        """
        name = "a" * 32
        valid, error = validate_username(name)
        assert valid is True

    def test_thirty_one_characters(self):
        """
        【VL-11】31 个字符的用户名合法（在边界内）
        """
        name = "b" * 31
        valid, error = validate_username(name)
        assert valid is True


# ============================================================
# 第 4 组：密码验证测试
# ============================================================

class TestPasswordValidation:
    """【密码验证测试】验证密码格式校验"""

    def test_valid_password(self):
        """
        【VL-12】合法密码通过验证

        验证点：6-128 字符，无控制字符
        """
        valid_passwords = [
            "123456",           # 恰好 6 字符
            "password123",
            "a" * 128,          # 恰好 128 字符
            "P@ssw0rd!",
            "correct-horse-battery-staple",
        ]
        for pw in valid_passwords:
            valid, error = validate_password(pw)
            assert valid is True, f"'{pw[:10]}...' 应该合法，但返回错误: {error}"

    def test_empty_password(self):
        """
        【VL-13】空密码被拒绝
        """
        valid, error = validate_password("")
        assert valid is False
        assert len(error) > 0

    def test_too_short_password(self):
        """
        【VL-14】短于 6 字符的密码被拒绝
        """
        for short in ["a", "ab", "abc", "abcd", "abcde"]:
            valid, error = validate_password(short)
            assert valid is False, f"密码'{short}' (len={len(short)}) 太短，应被拒绝"

    def test_too_long_password(self):
        """
        【VL-15】长于 128 字符的密码被拒绝
        """
        long_pw = "a" * 129
        valid, error = validate_password(long_pw)
        assert valid is False

    def test_password_with_control_characters(self):
        """
        【VL-16】包含控制字符的密码被拒绝

        控制字符：\x00-\x1f（含 \n, \r, \t）
        """
        control_chars = ["pass\nword", "pass\rword", "pass\tword", "pass\x00word"]
        for pw in control_chars:
            valid, error = validate_password(pw)
            assert valid is False, f"密码包含控制字符，应被拒绝: {repr(pw)}"


# ============================================================
# 第 5 组：与数据库集成的验证点
# ============================================================

class TestValidationIntegration:
    """
    【集成验证测试】验证 validate_username 的输出可直接用于注册流程
    
    这些测试确保验证函数的返回值格式便于在 register/login 流程中使用。
    """

    def test_valid_returns_tuple(self):
        """
        【VL-17】validate_username 返回 (bool, str) 元组
        
        验证点：返回值格式正确，便于 if 判断
        """
        result = validate_username("alice")
        assert isinstance(result, tuple)
        assert len(result) == 2
        assert isinstance(result[0], bool)
        assert isinstance(result[1], str)

    def test_invalid_error_message_is_descriptive(self):
        """
        【VL-18】非法输入时返回有意义的错误消息
        
        验证点：错误消息非空，可以展示给用户
        """
        _, error = validate_username("")
        assert len(error) > 0, "错误消息不应为空"

        _, error = validate_username("a")
        assert len(error) > 0

    def test_password_returns_tuple(self):
        """
        【VL-19】validate_password 也返回 (bool, str) 元组
        """
        result = validate_password("123456")
        assert isinstance(result, tuple)
        assert len(result) == 2
        assert isinstance(result[0], bool)
        assert isinstance(result[1], str)


# ============================================================
# 运行方式
# ============================================================
"""
运行输入验证测试:
  .venv/bin/python -m pytest tests/test_input_validation.py -v

运行参数化测试（查看所有参数）:
  .venv/bin/python -m pytest tests/test_input_validation.py -v --tb=short
"""
