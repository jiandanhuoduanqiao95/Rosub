// ============================================================
// state_manager.dart 阶段 O —— 群组与消息增强状态契约（TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 O 的客户端状态侧：
//   - O5（P2-5）定时消息列表：scheduledMessages / setScheduledMessages
//     （scheduled_list_response 推送 → 管理入口渲染；登出清空）
//
// O1/O2 群公告/群置顶经既有 setGroups 链路（Group 模型扩展字段，模型侧
// 契约见 chat_models_stage_o_test.dart），无新增 AppState API。
// O7 主题设置为独立 ThemeSettings（见 theme_settings_stage_o_test.dart）。
//
// 实现前：本文件引用尚未实现的 AppState 方法/字段，编译失败或用例红，
// 属 TDD 红。实现后：全部转绿。
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/state_manager.dart';

AppState get state => AppState.instance;

void resetState() {
  state.setLoggedOut();
}

ScheduledMessageInfo scheduled(
  String messageId,
  String content, {
  String? receiver,
  int? groupId,
  DateTime? at,
  String status = 'pending',
}) {
  return ScheduledMessageInfo(
    messageId: messageId,
    receiver: receiver ?? '',
    groupId: groupId,
    content: content,
    scheduleAt: at ?? DateTime(2026, 9, 1, 9),
    status: status,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  setUp(resetState);

  group('O5 —— 定时消息列表（scheduledMessages）', () {
    test('缺省为空列表', () {
      expect(state.scheduledMessages, isEmpty);
    });

    test('setScheduledMessages 覆盖更新并通知监听者', () {
      var notified = 0;
      state.addListener(() => notified++);
      state.setScheduledMessages([
        scheduled('a', '第一条', receiver: 'bob'),
        scheduled('b', '第二条', groupId: 1),
      ]);
      expect(notified, greaterThan(0), reason: 'setScheduledMessages 应通知');
      expect(state.scheduledMessages.length, 2);
      expect(state.scheduledMessages.first.messageId, 'a');
      expect(state.scheduledMessages.last.groupId, 1);
    });

    test('setScheduledMessages 重复调用替换旧列表（不追加）', () {
      state.setScheduledMessages([scheduled('a', 'x')]);
      state.setScheduledMessages([scheduled('b', 'y')]);
      expect(state.scheduledMessages.length, 1);
      expect(state.scheduledMessages.first.messageId, 'b');
    });

    test('退出登录清空定时消息（防跨账号泄漏）', () {
      state.setLoggedIn('alice', false);
      state.setScheduledMessages([scheduled('a', 'x', receiver: 'bob')]);
      state.setLoggedOut();
      expect(state.scheduledMessages, isEmpty);
    });

    test('列表不可修改（只读视图）', () {
      state.setScheduledMessages([scheduled('a', 'x')]);
      expect(() => state.scheduledMessages.add(scheduled('b', 'y')),
          throwsUnsupportedError);
    });
  });

  group('O1 公告管理 —— 群公告历史列表（groupAnnouncements）', () {
    test('缺省为空列表，set 后覆盖更新并通知', () {
      expect(state.groupAnnouncements, isEmpty);
      var notified = 0;
      state.addListener(() => notified++);
      state.setGroupAnnouncements([
        const GroupAnnouncement(
            messageId: 'a-1', sender: 'alice', content: '公告一'),
      ]);
      expect(notified, greaterThan(0));
      expect(state.groupAnnouncements.single.content, '公告一');
    });

    test('重复调用替换旧列表', () {
      state.setGroupAnnouncements([
        const GroupAnnouncement(messageId: 'a-1', content: 'x'),
      ]);
      state.setGroupAnnouncements([
        const GroupAnnouncement(messageId: 'a-2', content: 'y'),
      ]);
      expect(state.groupAnnouncements.single.messageId, 'a-2');
    });

    test('退出登录清空', () {
      state.setLoggedIn('alice', false);
      state.setGroupAnnouncements([
        const GroupAnnouncement(messageId: 'a-1', content: 'x'),
      ]);
      state.setLoggedOut();
      expect(state.groupAnnouncements, isEmpty);
    });
  });

  group('O1 修订（R-O12）—— 公告对账 syncGroupAnnouncements', () {
    test('设置列表并从聊天流移除服务端已不存在的公告气泡', () {
      state.setLoggedIn('alice', false);
      state.setGroups([Group(id: 1, name: '开发组', owner: 'alice')]);
      state.selectChat('group_1');
      // 聊天流两条公告：a-1 仍存在、a-2 已被删除
      state.addMessage(
          'group_1',
          ChatMessage(
              sender: 'alice',
              content: '保留公告',
              type: 'group_announcement',
              messageId: 'a-1',
              groupId: 1));
      state.addMessage(
          'group_1',
          ChatMessage(
              sender: 'alice',
              content: '被删公告',
              type: 'group_announcement',
              messageId: 'a-2',
              groupId: 1));

      final removed = state.syncGroupAnnouncements(1, [
        const GroupAnnouncement(messageId: 'a-1', content: '保留公告'),
      ]);

      expect(removed, ['a-2'], reason: '对账移除已删除公告');
      expect(state.getMessages('group_1').map((m) => m.messageId), ['a-1']);
      expect(state.groupAnnouncements.single.messageId, 'a-1');
    });

    test('聊天流中的普通消息不受对账影响', () {
      state.setLoggedIn('alice', false);
      state.setGroups([Group(id: 2, name: '组', owner: 'alice')]);
      state.selectChat('group_2');
      state.addMessage(
          'group_2',
          ChatMessage(
              sender: 'bob',
              content: '普通群聊',
              type: 'group_chat',
              messageId: 'm-1',
              groupId: 2));

      state.syncGroupAnnouncements(2, const []);

      expect(state.getMessages('group_2').map((m) => m.messageId), ['m-1']);
    });
  });
}
