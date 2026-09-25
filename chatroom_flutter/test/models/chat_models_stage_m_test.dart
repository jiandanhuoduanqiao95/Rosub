// ============================================================
// chat_models.dart 阶段 M —— 群组治理 + 文件记录模型契约（TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§11 阶段 M / §13.3：
//   - M1/M3 Group 扩展：owner（created_by）/ avatar / historyVisible /
//     historyLimit（群主标识与历史可见性策略，list_groups 推送携带）
//   - M2 GroupInvite 模型：群邀请推送（group_invite 消息）
//   - M8 FileRecord 模型：文件收发管理页数据（file_list_response 消息）
//
// 实现前：本文件引用尚未实现的字段/类，编译失败或用例红，属 TDD 红。
// 实现后：全部转绿。
// ============================================================

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';

void main() {
  group('M1/M3 —— Group 群主与历史可见性扩展', () {
    test('fromJson 解析 created_by → owner（群主标识）', () {
      final group = Group.fromJson(const {
        'id': 1,
        'group_name': '开发组',
        'created_by': 'alice',
      });
      expect(group.owner, 'alice', reason: '群主应解析自 created_by');
    });

    test('fromJson 解析 avatar / history_visible / history_limit', () {
      final group = Group.fromJson(const {
        'id': 2,
        'group_name': '设计组',
        'created_by': 'bob',
        'avatar': 'data:image/png;base64,AAA',
        'history_visible': 0,
        'history_limit': 20,
      });
      expect(group.avatar, 'data:image/png;base64,AAA');
      expect(group.historyVisible, isFalse,
          reason: 'history_visible=0 → false');
      expect(group.historyLimit, 20);
    });

    test('缺少治理字段时优雅缺省（旧服务端兼容）', () {
      final group = Group.fromJson(const {
        'id': 3,
        'group_name': '旧群',
      });
      expect(group.owner, '', reason: '缺省群主为空串');
      expect(group.avatar, '');
      expect(group.historyVisible, isTrue, reason: '默认可见历史（P1-18）');
      expect(group.historyLimit, 50, reason: '默认最近 50 条');
    });

    test('history_visible 数字/字符串混用防御性解析', () {
      final g1 = Group.fromJson(const {
        'id': 4,
        'group_name': 'A',
        'history_visible': '1',
      });
      expect(g1.historyVisible, isTrue);
      final g2 = Group.fromJson(const {
        'id': 5,
        'group_name': 'B',
        'history_visible': '0',
      });
      expect(g2.historyVisible, isFalse);
    });

    test('history_limit 非数字防御性解析', () {
      final group = Group.fromJson(const {
        'id': 6,
        'group_name': 'C',
        'history_limit': 'abc',
      });
      expect(group.historyLimit, 50, reason: '非法 limit 回退默认值');
    });

    test('fromJson 解析 member_count（搜索结果人数）', () {
      final group = Group.fromJson(const {
        'id': 7,
        'group_name': '开发组',
        'member_count': 5,
      });
      expect(group.memberCount, 5);
      final missing = Group.fromJson(const {'id': 8, 'group_name': '旧群'});
      expect(missing.memberCount, 0, reason: '缺省人数为 0');
    });

    test('isOwner 判断当前用户是否群主', () {
      final group = Group.fromJson(const {
        'id': 7,
        'group_name': '开发组',
        'created_by': 'alice',
      });
      expect(group.isOwner('alice'), isTrue);
      expect(group.isOwner('bob'), isFalse);
    });

    test('owner 空串时 isOwner 恒 false（无群主防御）', () {
      final group = Group.fromJson(const {'id': 8, 'group_name': '旧群'});
      expect(group.isOwner('alice'), isFalse);
    });
  });

  group('M2 —— GroupInvite 群邀请模型', () {
    test('fromJson 解析群邀请推送（group_invite）', () {
      final invite = GroupInvite.fromJson(const {
        'group_id': 9,
        'group_name': '开发组',
        'from': 'alice',
      });
      expect(invite.groupId, 9);
      expect(invite.groupName, '开发组');
      expect(invite.inviter, 'alice');
    });

    test('缺少字段时优雅缺省', () {
      final invite = GroupInvite.fromJson(const {'group_id': 10});
      expect(invite.groupId, 10);
      expect(invite.groupName, '');
      expect(invite.inviter, '');
    });

    test('group_id 字符串/数字混用防御性解析', () {
      final invite = GroupInvite.fromJson(const {
        'group_id': '11',
        'group_name': '设计组',
      });
      expect(invite.groupId, 11);
    });
  });

  group('M8 —— FileRecord 文件收发记录模型', () {
    test('fromJson 解析文件记录（file_list_response）', () {
      final record = FileRecord.fromJson(const {
        'filename': '报告.pdf',
        'filesize': 1024,
        'sender': 'alice',
        'receiver': 'bob',
        'message_id': 'file-1',
        'timestamp': '2026-08-24 10:00:00',
        'group_id': 9,
        'status': 'sent',
      });
      expect(record.filename, '报告.pdf');
      expect(record.filesize, 1024);
      expect(record.sender, 'alice');
      expect(record.receiver, 'bob');
      expect(record.messageId, 'file-1');
      expect(record.timestamp, DateTime(2026, 8, 24, 10, 0, 0));
      expect(record.groupId, 9);
      expect(record.status, 'sent');
    });

    test('群文件无 receiver；私聊文件无 groupId', () {
      final groupFile = FileRecord.fromJson(const {
        'filename': 'g.pdf',
        'filesize': 10,
        'sender': 'alice',
        'receiver': '',
        'message_id': 'gf-1',
        'group_id': 3,
      });
      expect(groupFile.groupId, 3);
      expect(groupFile.isGroupFile, isTrue);
      final privateFile = FileRecord.fromJson(const {
        'filename': 'p.pdf',
        'filesize': 10,
        'sender': 'alice',
        'receiver': 'bob',
        'message_id': 'pf-1',
      });
      expect(privateFile.groupId, isNull);
      expect(privateFile.isGroupFile, isFalse);
    });

    test('filesize 字符串/缺失防御性解析', () {
      final f1 = FileRecord.fromJson(const {
        'filename': 'a',
        'filesize': '2048',
        'sender': 's',
        'receiver': 'r',
        'message_id': 'm1',
      });
      expect(f1.filesize, 2048);
      final f2 = FileRecord.fromJson(const {
        'filename': 'b',
        'sender': 's',
        'receiver': 'r',
        'message_id': 'm2',
      });
      expect(f2.filesize, 0);
    });

    test('timestamp 非法/缺失 → 回退当前时刻（不抛异常）', () {
      final f1 = FileRecord.fromJson(const {
        'filename': 'a',
        'filesize': 1,
        'sender': 's',
        'receiver': 'r',
        'message_id': 'm1',
        'timestamp': 'not-a-date',
      });
      expect(f1.timestamp, isA<DateTime>());
    });
  });
}
