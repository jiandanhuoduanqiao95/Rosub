// ============================================================
// chat_models.dart 攻击性 / 边界 / 属性测试（测试强化新增）
// ============================================================
// 以"破坏者"视角对数据模型做穷尽式边界打击：
//   - Group.fromJson 的畸形 JSON（类型不符 → 潜在崩溃点）
//   - ChatMessage 各 type/status 组合的 displayText / header
//   - TransferProgress 数值极端（负数、超量、total=0）
//   - InputValidator 随机模糊（属性测试：与参考实现对照）
//
// 本文件新增依赖：faker（随机数据生成）。
// ============================================================

import 'package:faker/faker.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';

void main() {
  // ----------------------------------------------------------
  // Group.fromJson —— 畸形输入攻击
  // ----------------------------------------------------------
  group('Group.fromJson 畸形输入攻击', () {
    test('【已修复】group_name 为数字类型时优雅降级（回归锁定）', () {
      // 正确行为：类型不符的字段应降级（toString / 空串），不抛异常。
      // 当前实现：`json['group_name'] as String?` 直接 TypeError。
      expect(
          () => Group.fromJson({'id': 1, 'group_name': 123}), returnsNormally,
          reason: '修复后不应再抛 TypeError');
    });

    test('【已修复】id 为字符串类型时优雅降级（回归锁定）', () {
      expect(
          () => Group.fromJson({'id': '1', 'group_name': 'g'}), returnsNormally,
          reason: '修复后不应再抛 TypeError');
    });

    test('【已修复】id 为 double 时优雅降级（回归锁定）', () {
      expect(
          () => Group.fromJson({'id': 1.5, 'group_name': 'g'}), returnsNormally,
          reason: '修复后不应再抛 TypeError');
    });

    test('【已修复】members 为字符串时优雅降级（回归锁定）', () {
      expect(
          () =>
              Group.fromJson({'id': 1, 'group_name': 'g', 'members': 'alice'}),
          returnsNormally,
          reason: '修复后不应再抛 TypeError');
    });

    test('【已修复】空 JSON / 缺 id 时优雅降级（id=0，不抛出）', () {
      // 修复前：缺必需字段抛 TypeError（契约违反）；修复后：防御性降级
      final g = Group.fromJson({});
      expect(g.id, 0);
      expect(g.name, '');
      expect(g.members, isEmpty);
    });

    test('group_name 为 null 且 name 为 null 时回退空串', () {
      final g = Group.fromJson({'id': 1, 'group_name': null, 'name': null});
      expect(g.name, '');
    });

    test('group_name 存在但 name 不存在时优先 group_name', () {
      final g = Group.fromJson({'id': 1, 'group_name': 'A', 'name': 'B'});
      expect(g.name, 'A');
    });

    test('members 含非字符串元素时 toString 转换', () {
      final g = Group.fromJson({
        'id': 1,
        'group_name': 'g',
        'members': [1, 2, true],
      });
      expect(g.members, ['1', '2', 'true']);
    });

    test('members 为 null 时回退空列表', () {
      final g = Group.fromJson({'id': 1, 'group_name': 'g', 'members': null});
      expect(g.members, isEmpty);
    });
  });

  // ----------------------------------------------------------
  // ChatMessage —— type/status 组合矩阵
  // ----------------------------------------------------------
  group('ChatMessage 组合矩阵', () {
    test('group_chat 类型 displayText 为 sender: content', () {
      final m = ChatMessage(
          sender: 'bob', content: '大家好', messageId: 'm1', type: 'group_chat');
      expect(m.displayText, 'bob: 大家好');
    });

    test('file 类型 filename 为 null 时回退 content', () {
      final m = ChatMessage(
        sender: 'bob',
        content: '[文件]',
        messageId: 'm2',
        type: 'file',
      );
      expect(m.displayText, 'bob: [文件]');
    });

    test('已撤回的 system 消息优先显示撤回占位', () {
      final m = ChatMessage(
        sender: '系统',
        content: '公告',
        messageId: 'm3',
        type: 'system',
        status: 'recalled',
      );
      expect(m.isRecalled, isTrue);
      expect(m.displayText, '系统: [消息已撤回]');
    });

    test('system 类型但 sender 为普通名的 displayText', () {
      final m = ChatMessage(
        sender: 'alice',
        content: 'x',
        messageId: 'm4',
        type: 'system',
      );
      expect(m.displayText, 'x');
    });

    test('header 对任意 status 均返回 "sender "（含尾随空格，记录现状）', () {
      for (final s in ['sent', 'delivered', 'recalled', 'unknown_status']) {
        final m = ChatMessage(
            sender: 'alice', content: 'c', messageId: 'm5', status: s);
        // 现状：'$sender $statusStr' 拼接出一个尾随空格；UI 未使用该字段
        expect(m.header, 'alice ', reason: 'status=$s');
      }
    });

    test('displayText 对空 content 与空 sender', () {
      final m = ChatMessage(sender: '', content: '', messageId: 'm6');
      expect(m.displayText, ': ');
    });

    test('默认参数：isHistory=false / filename=null / groupId=null', () {
      final m = ChatMessage(sender: 'a', content: 'b', messageId: 'm7');
      expect(m.isHistory, isFalse);
      expect(m.filename, isNull);
      expect(m.fileData, isNull);
      expect(m.groupId, isNull);
      expect(m.type, 'chat');
    });

    test('status 可外部修改（非 final，mutable）', () {
      final m = ChatMessage(sender: 'a', content: 'b', messageId: 'm8');
      m.status = 'delivered';
      expect(m.status, 'delivered');
    });
  });

  // ----------------------------------------------------------
  // TransferProgress —— 数值极端
  // ----------------------------------------------------------
  group('TransferProgress 数值极端', () {
    test('total 为负数时 fraction 为 0', () {
      const p = TransferProgress(messageId: 'x', total: -100, transferred: 50);
      expect(p.fraction, 0);
      expect(p.done, isFalse);
    });

    test('transferred 为负数时 fraction 收敛为 0（不越界）', () {
      const p = TransferProgress(messageId: 'x', total: 100, transferred: -50);
      expect(p.fraction, 0);
    });

    test('transferred 超过 total 时 fraction 收敛为 1.0 且 done', () {
      const p = TransferProgress(messageId: 'x', total: 100, transferred: 150);
      expect(p.fraction, 1.0);
      expect(p.done, isTrue);
    });

    test('total=0 但 transferred>0 时 done=false（非对称边界，记录行为）', () {
      const p = TransferProgress(messageId: 'x', total: 0, transferred: 100);
      expect(p.fraction, 0);
      expect(p.done, isFalse);
    });

    test('超大体量的进度不溢出（int64 上限）', () {
      const p = TransferProgress(
          messageId: 'x', total: 9223372036854775807, transferred: 1);
      expect(p.fraction, closeTo(0.0, 1e-9));
      expect(p.done, isFalse);
    });

    test('total=1 transferred=1 最小完成态', () {
      const p = TransferProgress(messageId: 'x', total: 1, transferred: 1);
      expect(p.done, isTrue);
      expect(p.fraction, 1.0);
    });
  });

  // ----------------------------------------------------------
  // InputValidator —— 模糊属性测试（faker 驱动）
  // ----------------------------------------------------------
  group('InputValidator 模糊属性测试', () {
    final faker = Faker();
    final prng = _SeededRandom(20260809);
    const seedChars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-';

    String randomString(int maxLen) {
      final len = prng.nextInt(maxLen + 1);
      return String.fromCharCodes(
        List.generate(
            len, (_) => seedChars.codeUnitAt(prng.nextInt(seedChars.length))),
      );
    }

    test('2000 次随机用户名：与参考实现逐条对照（属性测试）', () {
      for (var i = 0; i < 2000; i++) {
        final input = switch (i % 4) {
          0 => randomString(40), // 纯合法字符随机串
          1 => faker.lorem.sentence(), // 含空格/标点的自然文本
          2 => faker.internet.userName(), // 半合法用户名
          _ => String.fromCharCodes(
              List.generate(
                  prng.nextInt(50), (_) => prng.nextInt(0x100)), // 任意 ASCII 字节
            ),
        };

        final expected = _referenceValidateUsername(input);
        final actual = InputValidator.validateUsername(input);
        expect(actual.valid, expected,
            reason:
                'input="${input.length > 60 ? input.substring(0, 60) : input}"'
                ' (len=${input.length}) 期望 valid=$expected 实际=${actual.valid}');
      }
    });

    test('1000 次随机密码：6-128 位且无控制字符即合法（属性测试，对齐服务端 P-17）', () {
      bool noControl(String s) =>
          !s.codeUnits.any((u) => u < 0x20 || (u >= 0x7F && u <= 0x9F));
      for (var i = 0; i < 1000; i++) {
        final len = prng.nextInt(30);
        final input = String.fromCharCodes(
            List.generate(len, (_) => prng.nextInt(0x100)));
        final expected = len >= 6 && len <= 128 && noControl(input);
        final actual = InputValidator.validatePassword(input);
        expect(actual.valid, expected, reason: 'len=$len');
      }
    });

    test('用户名含控制字符/换行/制表符被拒', () {
      for (final n in ['a\tbc', 'ab\ncd', 'ab\x00cd', 'ab\x7Fcd', 'abc\r']) {
        expect(InputValidator.validateUsername(n).valid, isFalse,
            reason: '$n 应被拒');
      }
    });

    test('用户名 3-32 边界矩阵', () {
      for (final n in [
        'abc',
        'abcd',
        'a' * 32,
        'a' * 31,
        'a' * 33,
        'ab',
        'a'
      ]) {
        final expected = n.length >= 3 && n.length <= 32;
        expect(InputValidator.validateUsername(n).valid, expected,
            reason: 'len=${n.length}');
      }
    });

    test('错误信息覆盖三种拒绝原因', () {
      final tooShort = InputValidator.validateUsername('ab');
      final tooLong = InputValidator.validateUsername('a' * 33);
      final badChar = InputValidator.validateUsername('中文名');
      expect(tooShort.error, contains('少于 3'));
      expect(tooLong.error, contains('32'));
      expect(badChar.error, contains('字母、数字、下划线和连字符'));
    });
  });

  // ----------------------------------------------------------
  // ValidationResult
  // ----------------------------------------------------------
  group('ValidationResult', () {
    test('fail 可带任意错误信息（含空串与 null 语义）', () {
      final r = ValidationResult.fail('');
      expect(r.valid, isFalse);
      expect(r.error, '');
    });
  });
}

/// 参考实现：与 chat_models.dart 中 validateUsername 相同的判定逻辑，
/// 独立重写以验证被测实现的一致性（属性测试对偶）。
bool _referenceValidateUsername(String username) {
  if (username.length < 3) return false;
  if (username.length > 32) return false;
  return RegExp(r'^[a-zA-Z0-9_\-]+$').hasMatch(username);
}

/// 确定性伪随机数生成器（可复现种子），避免依赖全局 Random 的偶发失败。
class _SeededRandom {
  int _state;
  _SeededRandom(this._state);

  int nextInt(int max) {
    _state = (_state * 1103515245 + 12345) & 0x7FFFFFFF;
    return _state % max;
  }
}
