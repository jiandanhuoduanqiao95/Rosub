// ============================================================
// chat_models.dart 阶段 O —— 群组与消息增强模型契约（TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 O：
//   - O1（用户已规划）群公告：Group.announcement（list_groups 推送新字段）
//   - O2（用户已规划）群置顶：Group.pinnedMessageId / pinnedPreview
//     （list_groups 推送新字段 pinned_message_id / pinned_preview）
//   - O5（P2-5）定时消息：ScheduledMessageInfo 模型
//     （scheduled_list_response 消息）
//
// 2026-08-30 用户反馈修订：O3 历史/在线区分与 O9 名片/位置/日程卡片已按
// 用户决策移除，相关模型契约（cardData 等）一并删除。
//
// 实现前：本文件引用尚未实现的类/字段，编译失败或用例红，属 TDD 红。
// 实现后：全部转绿。
// ============================================================

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';

Group grp(Map<String, dynamic> json) => Group.fromJson(json);

void main() {
  group('O1 —— Group.announcement 群公告字段（list_groups 扩展）', () {
    test('fromJson 解析 announcement', () {
      final g = grp({
        'id': 1,
        'group_name': '公告组',
        'created_by': 'alice',
        'announcement': '周五 18:00 团建',
      });
      expect(g.announcement, '周五 18:00 团建');
    });

    test('缺失 announcement → 空字符串（旧服务端推送兼容）', () {
      final g = grp({'id': 2, 'group_name': '旧推送组'});
      expect(g.announcement, '');
    });

    test('announcement 类型漂移（数字/null）→ 空字符串不抛异常', () {
      expect(grp({'id': 1, 'announcement': 123}).announcement, '123');
      expect(grp({'id': 1, 'announcement': null}).announcement, '');
    });
  });

  group('O2 —— Group.pinnedMessageId / pinnedPreview 群置顶字段', () {
    test('fromJson 解析 pinned_message_id / pinned_preview', () {
      final g = grp({
        'id': 1,
        'group_name': '置顶组',
        'pinned_message_id': 'm-001',
        'pinned_preview': '重要通知',
      });
      expect(g.pinnedMessageId, 'm-001');
      expect(g.pinnedPreview, '重要通知');
    });

    test('缺失置顶字段 → 空字符串（未置顶语义）', () {
      final g = grp({'id': 2, 'group_name': '未置顶组'});
      expect(g.pinnedMessageId, '');
      expect(g.pinnedPreview, '');
    });

    test('置顶字段类型漂移（数字/null）→ 防御性降级不抛异常', () {
      final g = grp({'id': 1, 'pinned_message_id': 42, 'pinned_preview': null});
      expect(g.pinnedMessageId, '42');
      expect(g.pinnedPreview, '');
    });
  });

  group('O2 修订（2026-08-31 多置顶并存）—— Group.pinnedMessages', () {
    test('fromJson 解析 pinned_messages 全量列表', () {
      final g = grp({
        'id': 1,
        'pinned_messages': [
          {'message_id': 'm-1', 'preview': '第一条', 'pinned_by': 'alice'},
          {'message_id': 'm-2', 'preview': '第二条', 'pinned_by': 'alice'},
        ],
      });
      expect(g.pinnedMessages.length, 2);
      expect(g.pinnedMessages[0].messageId, 'm-1');
      expect(g.pinnedMessages[1].preview, '第二条');
    });

    test('缺失 pinned_messages → 空列表（旧服务端兼容）', () {
      expect(grp({'id': 2}).pinnedMessages, isEmpty);
    });

    test('pinned_messages 类型漂移（非数组）→ 空列表不抛异常', () {
      expect(grp({'id': 1, 'pinned_messages': 'x'}).pinnedMessages, isEmpty);
    });
  });

  group('O5 —— ScheduledMessageInfo 定时消息模型（scheduled_list_response）', () {
    test('fromJson 解析完整字段（schedule_at epoch 秒）', () {
      final s = ScheduledMessageInfo.fromJson(const {
        'message_id': 'o5-1',
        'receiver': 'bob',
        'content': '下午 3 点提醒',
        'schedule_at': '1790000000',
        'status': 'pending',
      });
      expect(s.messageId, 'o5-1');
      expect(s.receiver, 'bob');
      expect(s.groupId, isNull);
      expect(s.content, '下午 3 点提醒');
      expect(
        s.scheduleAt,
        DateTime.fromMillisecondsSinceEpoch(1790000000 * 1000),
        reason: 'schedule_at 为 epoch 秒 → 毫秒转换',
      );
      expect(s.status, 'pending');
    });

    test('fromJson 群定时：group_id 数字/字符串均可解析', () {
      expect(
        ScheduledMessageInfo.fromJson(
                const {'message_id': 'a', 'group_id': 7, 'schedule_at': '1'})
            .groupId,
        7,
      );
      expect(
        ScheduledMessageInfo.fromJson(
                const {'message_id': 'a', 'group_id': '7', 'schedule_at': '1'})
            .groupId,
        7,
      );
    });

    test('fromJson 缺失/非法字段防御（不抛异常）', () {
      final s = ScheduledMessageInfo.fromJson(const {
        'message_id': 123,
        'schedule_at': 'abc',
        'status': 0,
      });
      expect(s.messageId, '123');
      expect(s.receiver, '');
      expect(s.content, '');
      expect(
        s.scheduleAt,
        DateTime.fromMillisecondsSinceEpoch(0),
        reason: '非法 schedule_at → epoch 0',
      );
      expect(s.status, 'pending', reason: '缺失 status → pending');
    });

    test('构造器缺省：status 默认 pending、groupId 可空', () {
      final s = ScheduledMessageInfo(
        messageId: 'm1',
        content: 'x',
        scheduleAt: DateTime(2026, 9, 1, 9),
      );
      expect(s.status, 'pending');
      expect(s.groupId, isNull);
      expect(s.isGroupMessage, isFalse);
    });

    test('isGroupMessage：group_id 非空即群定时', () {
      final s = ScheduledMessageInfo(
        messageId: 'm2',
        content: 'x',
        scheduleAt: DateTime(2026, 9, 1, 9),
        groupId: 3,
      );
      expect(s.isGroupMessage, isTrue);
    });
  });
}
