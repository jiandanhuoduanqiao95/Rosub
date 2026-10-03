// ============================================================
// opt1 —— 严格密码规则（注册/修改密码收紧，登录保持宽松）
// ============================================================
// 与服务端 validation.py validate_password_strict 逐字镜像：
//   - 非空；仅可见 ASCII（U+0021–U+007E，不含空格）；长度 6–32
//   - 错误文案两端逐字一致
// 宽松 validatePassword 不动（登录路径，存量中文口令可登录）。
// ============================================================

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';

void main() {
  group('opt1 —— validatePasswordStrict（镜像 validate_password_strict）', () {
    test('合规密码通过', () {
      for (final pw in ['123456', 'a' * 32, 'P@ssw0rd!', 'abc-DEF_123']) {
        expect(InputValidator.validatePasswordStrict(pw).valid, isTrue,
            reason: '$pw 应合法');
      }
    });

    test('中文密码拒绝且文案与服务端逐字一致', () {
      for (final pw in ['中文密码密码', 'pass中文', '密码123456']) {
        final r = InputValidator.validatePasswordStrict(pw);
        expect(r.valid, isFalse);
        expect(r.error, '密码仅支持字母、数字和半角符号（不含空格与中文）');
      }
    });

    test('全角/emoji 拒绝', () {
      for (final pw in ['１２３４５６', 'pass😀', 'ｐａｓｓword']) {
        expect(InputValidator.validatePasswordStrict(pw).valid, isFalse);
      }
    });

    test('含空格拒绝', () {
      for (final pw in ['pass word', ' passwo', 'password ']) {
        expect(InputValidator.validatePasswordStrict(pw).valid, isFalse);
      }
    });

    test('长度边界 5/33 拒绝、6/32 通过', () {
      expect(InputValidator.validatePasswordStrict('a' * 5).valid, isFalse);
      expect(InputValidator.validatePasswordStrict('a' * 33).valid, isFalse);
      expect(InputValidator.validatePasswordStrict('a' * 6).valid, isTrue);
      expect(InputValidator.validatePasswordStrict('a' * 32).valid, isTrue);
    });

    test('空密码文案', () {
      final r = InputValidator.validatePasswordStrict('');
      expect(r.valid, isFalse);
      expect(r.error, '密码不能为空');
    });

    test('长度错误文案', () {
      final r = InputValidator.validatePasswordStrict('abc');
      expect(r.error, '密码长度需为 6-32 个字符');
    });

    test('宽松 validatePassword 行为不变（登录兼容存量中文口令）', () {
      expect(InputValidator.validatePassword('中文密码密码').valid, isTrue);
      expect(InputValidator.validatePassword('a' * 128).valid, isTrue);
      expect(InputValidator.validatePasswordStrict('a' * 128).valid, isFalse);
      expect(InputValidator.validatePassword('a' * 5).valid, isFalse);
    });
  });
}
