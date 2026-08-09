// ============================================================
// chat_models.dart 单元测试
// ============================================================
// 纯 Dart 逻辑测试，不依赖 widget，覆盖：
//   - ChatMessage 的 displayText / isRecalled / header / timestamp
//   - Group.fromJson 各字段分支与 displayName / chatKey
//   - FileRequest.isGroupFile
//   - ChatTarget 字段
//   - InputValidator 用户名/密码校验与 ValidationResult
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:chatroom_flutter/models/chat_models.dart';

void main() {
  // ----------------------------------------------------------
  // ChatMessage
  // ----------------------------------------------------------
  group('ChatMessage', () {
    test('displayText for normal chat message', () {
      final m = ChatMessage(sender: 'alice', content: '你好', messageId: 'm1');
      expect(m.displayText, 'alice: 你好');
      expect(m.isRecalled, isFalse);
    });

    test('displayText for recalled message shows placeholder', () {
      final m = ChatMessage(
        sender: 'alice',
        content: 'secret',
        messageId: 'm2',
        status: 'recalled',
      );
      expect(m.isRecalled, isTrue);
      expect(m.displayText, 'alice: [消息已撤回]');
    });

    test('displayText for system message returns raw content', () {
      final m = ChatMessage(
        sender: '[系统公告]',
        content: '系统维护通知',
        messageId: 'm3',
        type: 'system',
      );
      expect(m.displayText, '系统维护通知');
    });

    test('displayText for file message shows filename', () {
      final m = ChatMessage(
        sender: 'bob',
        content: '[文件] report.pdf',
        messageId: 'm4',
        type: 'file',
        filename: 'report.pdf',
      );
      expect(m.displayText, 'bob: [文件] report.pdf');
    });

    test('default timestamp is now-ish and status defaults to sent', () {
      final before = DateTime.now();
      final m = ChatMessage(sender: 'a', content: 'x', messageId: 'm5');
      final after = DateTime.now();
      expect(m.timestamp.isAfter(before.subtract(const Duration(seconds: 1))), isTrue);
      expect(m.timestamp.isBefore(after.add(const Duration(seconds: 1))), isTrue);
      expect(m.status, 'sent');
      expect(m.isHistory, isFalse);
    });

    test('header is sender name for non-system messages', () {
      final m = ChatMessage(sender: 'alice', content: 'hi', messageId: 'm6');
      expect(m.header, contains('alice'));
    });

    test('header is empty for system messages', () {
      final m = ChatMessage(
        sender: '系统',
        content: 'c',
        messageId: 'm7',
        type: 'system',
      );
      expect(m.header, '');
    });
  });

  // ----------------------------------------------------------
  // Group
  // ----------------------------------------------------------
  group('Group', () {
    test('chatKey and displayName', () {
      final g = Group(id: 1, name: '开发小组', members: const ['alice', 'bob']);
      expect(g.chatKey, 'group_1');
      expect(g.displayName, '开发小组 (ID:1)');
    });

    test('fromJson with group_name field', () {
      final g = Group.fromJson({
        'id': 5,
        'group_name': '测试群',
      });
      expect(g.id, 5);
      expect(g.name, '测试群');
      expect(g.members, isEmpty);
    });

    test('fromJson with name field fallback', () {
      final g = Group.fromJson({'id': 7, 'name': '备用名'});
      expect(g.name, '备用名');
    });

    test('fromJson parses members list', () {
      final g = Group.fromJson({
        'id': 2,
        'group_name': '带成员',
        'members': ['alice', 'bob', 'carol'],
      });
      expect(g.members, ['alice', 'bob', 'carol']);
    });

    test('fromJson handles numeric/string ids gracefully', () {
      final g = Group.fromJson({'id': 9, 'group_name': '九号群'});
      expect(g.id, 9);
    });
  });

  // ----------------------------------------------------------
  // FileRequest
  // ----------------------------------------------------------
  group('FileRequest', () {
    test('private file is not group file', () {
      final r = FileRequest(
        messageId: 'f1',
        sender: 'alice',
        filename: 'a.txt',
        filesize: 100,
      );
      expect(r.isGroupFile, isFalse);
    });

    test('group file isGroupFile true', () {
      final r = FileRequest(
        messageId: 'f2',
        sender: 'bob',
        filename: 'b.png',
        filesize: 200,
        groupId: 3,
      );
      expect(r.isGroupFile, isTrue);
      expect(r.groupId, 3);
    });
  });

  // ----------------------------------------------------------
  // ChatTarget
  // ----------------------------------------------------------
  group('ChatTarget', () {
    test('default isGroup false', () {
      const t = ChatTarget(key: 'alice', displayName: 'alice');
      expect(t.isGroup, isFalse);
      expect(t.key, 'alice');
    });

    test('group target isGroup true', () {
      const t = ChatTarget(key: 'group_1', displayName: 'g', isGroup: true);
      expect(t.isGroup, isTrue);
    });
  });

  // ----------------------------------------------------------
  // InputValidator / ValidationResult
  // ----------------------------------------------------------
  group('InputValidator', () {
    test('validateUsername accepts valid names', () {
      for (final n in ['alice', 'user123', 'Ab', 'a' * 32, 'name_123-xy']) {
        final r = InputValidator.validateUsername(n.length < 3 ? '${n}abc' : n);
        expect(r.valid, isTrue, reason: '$n should be valid');
      }
    });

    test('validateUsername rejects too short', () {
      expect(InputValidator.validateUsername('a').valid, isFalse);
      expect(InputValidator.validateUsername('ab').valid, isFalse);
    });

    test('validateUsername rejects too long', () {
      expect(InputValidator.validateUsername('a' * 33).valid, isFalse);
    });

    test('validateUsername rejects invalid chars', () {
      final invalids = [
        'user name',
        'user@domain',
        "bob'; DROP--",
        '中文用户',
        'user.dot',
      ];
      for (final n in invalids) {
        final r = InputValidator.validateUsername(n);
        expect(r.valid, isFalse, reason: '$n should be rejected');
        expect(r.error, isNotNull);
      }
    });

    test('validateUsername boundary 3 and 32 pass', () {
      expect(InputValidator.validateUsername('abc').valid, isTrue);
      expect(InputValidator.validateUsername('a' * 32).valid, isTrue);
      expect(InputValidator.validateUsername('a' * 31).valid, isTrue);
    });

    test('validatePassword rejects short', () {
      for (final p in ['', 'a', 'abcde']) {
        expect(InputValidator.validatePassword(p).valid, isFalse,
            reason: '$p should be too short');
      }
    });

    test('validatePassword accepts >=6', () {
      expect(InputValidator.validatePassword('123456').valid, isTrue);
      expect(InputValidator.validatePassword('longpassword99').valid, isTrue);
    });

    test('ValidationResult.ok / fail', () {
      expect(ValidationResult.ok().valid, isTrue);
      expect(ValidationResult.ok().error, isNull);
      expect(ValidationResult.fail('msg').valid, isFalse);
      expect(ValidationResult.fail('msg').error, 'msg');
    });
  });
}