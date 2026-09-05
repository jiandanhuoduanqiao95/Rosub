// ============================================================
// chat_models.dart 阶段 J —— 用户资料 / 好友元数据模型（TDD 契约，待实现）
// ============================================================
// 覆盖 P0-2 / P1-8（《软件开发文档4.1.0.md》§13.2 / §13.3）：
//   - UserProfile：用户名/昵称/头像/签名/last_seen/is_admin，
//     fromJson 防御性解析（缺失字段/类型漂移不抛异常）
//   - FriendMeta：好友备注名 + 分组
//
// 注意：本文件测试只依赖 chat_models.dart，不触网。
// ============================================================

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';

void main() {
  group('UserProfile —— 构造与展示', () {
    test('全字段构造', () {
      final p = UserProfile(
        username: 'alice',
        nickname: '爱丽丝',
        avatar: 'ava.png',
        signature: '你好',
        lastSeen: DateTime(2026, 8, 13, 10, 30),
        isAdmin: true,
      );
      expect(p.username, 'alice');
      expect(p.nickname, '爱丽丝');
      expect(p.avatar, 'ava.png');
      expect(p.signature, '你好');
      expect(p.lastSeen, DateTime(2026, 8, 13, 10, 30));
      expect(p.isAdmin, isTrue);
    });

    test('缺省值：昵称/头像/签名为空串，lastSeen 为 null', () {
      final p = UserProfile(username: 'bob');
      expect(p.nickname, '');
      expect(p.avatar, '');
      expect(p.signature, '');
      expect(p.lastSeen, isNull);
      expect(p.isAdmin, isFalse);
    });

    test('displayName：有昵称用昵称，否则用用户名', () {
      expect(
          UserProfile(username: 'alice', nickname: '爱丽丝').displayName, '爱丽丝');
      expect(UserProfile(username: 'alice').displayName, 'alice');
      expect(
          UserProfile(username: 'alice', nickname: '  ').displayName, 'alice',
          reason: '纯空白昵称视为未设置');
    });

    test('hasProfile：任一字段非空即为有资料', () {
      expect(UserProfile(username: 'a').hasProfile, isFalse);
      expect(UserProfile(username: 'a', nickname: 'n').hasProfile, isTrue);
      expect(UserProfile(username: 'a', avatar: 'x').hasProfile, isTrue);
      expect(UserProfile(username: 'a', signature: 's').hasProfile, isTrue);
    });
  });

  group('UserProfile.fromJson —— 防御性解析', () {
    test('完整 JSON 解析', () {
      final p = UserProfile.fromJson({
        'username': 'alice',
        'nickname': '爱丽丝',
        'avatar': 'a.png',
        'signature': '签名',
        'last_seen': '2026-08-13 10:30:00',
        'is_admin': 1,
      });
      expect(p.username, 'alice');
      expect(p.nickname, '爱丽丝');
      expect(p.avatar, 'a.png');
      expect(p.signature, '签名');
      expect(p.lastSeen, isNotNull);
      expect(p.isAdmin, isTrue);
    });

    test('缺失字段不抛异常', () {
      final p = UserProfile.fromJson({'username': 'bob'});
      expect(p.username, 'bob');
      expect(p.nickname, '');
      expect(p.avatar, '');
      expect(p.signature, '');
      expect(p.lastSeen, isNull);
      expect(p.isAdmin, isFalse);
    });

    test('username 缺失回退空串', () {
      final p = UserProfile.fromJson(const {});
      expect(p.username, '');
      expect(() => p.displayName, returnsNormally);
    });

    test('null 字段回退默认值', () {
      final p = UserProfile.fromJson({
        'username': 'alice',
        'nickname': null,
        'avatar': null,
        'signature': null,
        'last_seen': null,
      });
      expect(p.nickname, '');
      expect(p.lastSeen, isNull);
    });

    test('类型漂移防御：数字昵称/布尔管理员', () {
      final p = UserProfile.fromJson({
        'username': 'alice',
        'nickname': 123,
        'is_admin': 'true',
      });
      expect(p.nickname, '123', reason: '数字昵称转字符串而非崩溃');
      expect(p.isAdmin, isTrue, reason: 'is_admin 布尔化解析');
    });

    test('last_seen 无效格式回退 null 不抛异常', () {
      final p = UserProfile.fromJson({
        'username': 'alice',
        'last_seen': 'not-a-date',
      });
      expect(p.lastSeen, isNull);
      expect(
          () => UserProfile.fromJson({'username': 'a', 'last_seen': 'garbage'}),
          returnsNormally);
    });

    test('last_seen 解析为本地时间', () {
      final p = UserProfile.fromJson({
        'username': 'alice',
        'last_seen': '2026-08-13 10:30:00',
      });
      expect(p.lastSeen!.isBefore(DateTime.now().add(const Duration(days: 1))),
          isTrue);
    });

    test('toJson 往返一致', () {
      final p = UserProfile(
        username: 'alice',
        nickname: '爱丽丝',
        avatar: 'a.png',
        signature: 's',
        lastSeen: DateTime(2026, 8, 13, 10, 30),
        isAdmin: true,
      );
      final back = UserProfile.fromJson(p.toJson());
      expect(back.username, p.username);
      expect(back.nickname, p.nickname);
      expect(back.avatar, p.avatar);
      expect(back.signature, p.signature);
      expect(back.isAdmin, p.isAdmin);
    });
  });

  group('FriendMeta —— 好友备注/分组', () {
    test('构造与默认值', () {
      const m = FriendMeta(username: 'bob');
      expect(m.username, 'bob');
      expect(m.note, '');
      expect(m.groupName, '');
      const m2 = FriendMeta(username: 'bob', note: '阿波', groupName: '家人');
      expect(m2.note, '阿波');
      expect(m2.groupName, '家人');
    });

    test('fromJson 完整解析', () {
      final m = FriendMeta.fromJson({
        'username': 'bob',
        'note': '阿波',
        'group_name': '同事',
      });
      expect(m.username, 'bob');
      expect(m.note, '阿波');
      expect(m.groupName, '同事');
    });

    test('fromJson 缺失/类型漂移防御', () {
      expect(() => FriendMeta.fromJson(const {}), returnsNormally);
      final m = FriendMeta.fromJson({
        'username': null,
        'note': 123,
        'group_name': 456,
      });
      expect(m.note, '123');
      expect(m.groupName, '456');
    });
  });
}
