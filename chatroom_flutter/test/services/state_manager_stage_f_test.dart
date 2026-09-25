// ============================================================
// 阶段 F 客户端逻辑层 TDD 测试（F3 / F6 / F8）
// ============================================================
// 本文件覆盖阶段 F 中"无需修改生产代码即可验证"的客户端状态侧分支：
//   - AppState.removeFriend 的全部副作用（为 F3 提供状态机后置保证）
//   - 群组移除后状态清理（为 F6 提供规约，依赖 AppState 新增 leaveGroup
//     方法，目前未有，故该部分以规约注释形式记录，待生产侧落地后补测试）
//
// 注：F3/F6/F8 涉及用户交互（长按、群组菜单、群信息对话框），
// 对应 UI 元素尚未存在于 sidebar.dart / dialogs.dart，引用未导出的
// 符号会导致 Dart 文件无法编译。因此 UI 交互测试不在此写代码，
// 而在 TESTING_GUIDE_FLUTTER.md 阶段 F 章节以规约+预期清单形式记录，
// 待生产代码落地时与对应 widget 测试一并补齐。
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/state_manager.dart';

AppState get state => AppState.instance;

void resetState() {
  state
    ..setLoggedOut()
    ..setConnectionStatus(ConnectionStatus.disconnected);
}

void main() {
  setUp(resetState);

  // ----------------------------------------------------------
  // F3 客户端状态侧：删除好友后 AppState 同步
  // ----------------------------------------------------------
  group('F3 AppState.removeFriend 副作用', () {
    test('删除好友后该好友从 friends 列表消失且消息清空', () {
      state.setLoggedIn('alice', false);
      state.addFriend('bob');
      state.addMessage(
          'bob', ChatMessage(sender: 'bob', content: 'hi', messageId: 'm1'));
      state.addMessage('bob',
          ChatMessage(sender: 'alice', content: 'reply', messageId: 'm2'));
      expect(state.getMessages('bob').length, 2);

      state.removeFriend('bob');

      expect(state.friends.contains('bob'), isFalse);
      expect(state.getMessages('bob'), isEmpty);
    });

    test('删除当前会话为该好友时 currentChat 被重置', () {
      state.setLoggedIn('alice', false);
      state.addFriend('bob');
      state.addMessage(
          'bob', ChatMessage(sender: 'bob', content: 'c', messageId: 'm1'));
      state.selectChat('bob');
      expect(state.currentChat, 'bob');

      state.removeFriend('bob');

      expect(state.currentChat, isNull);
    });

    test('删除好友后该会话未读计数也清除', () {
      // TDD 红规约：F3 实现时需扩展 AppState.removeFriend 顺带清未读。
      // 现有 removeFriend 实现不会清 unreadCount（message_history 共享但
      // unread 是会话级独立 Map），故此测试当前为红，待 F3 一并修复。
      state.setLoggedIn('alice', false);
      state.addFriend('bob');
      state.addMessage(
          'bob',
          ChatMessage(
              sender: 'bob', content: 'new', messageId: 'm1', status: 'sent'));
      state.addMessage(
          'bob',
          ChatMessage(
              sender: 'bob', content: 'new2', messageId: 'm2', status: 'sent'));
      expect(state.unreadOf('bob'), 2);

      state.removeFriend('bob');

      expect(state.unreadOf('bob'), 0);
      expect(state.totalUnread, 0);
    });

    test('删除好友不影响其它会话状态', () {
      state.setLoggedIn('alice', false);
      state.addFriend('bob');
      state.addFriend('carol');
      state.addMessage(
          'bob', ChatMessage(sender: 'bob', content: 'b', messageId: 'm1'));
      state.addMessage(
          'carol', ChatMessage(sender: 'carol', content: 'c', messageId: 'm2'));

      state.removeFriend('bob');

      expect(state.friends.contains('carol'), isTrue);
      expect(state.getMessages('carol').length, 1);
    });

    test('删除未添加的好友不抛异常（idempotent）', () {
      state.setLoggedIn('alice', false);
      expect(() => state.removeFriend('nonexistent_friend'), returnsNormally);
    });

    test('删除其它组的好友后 chatTargets 重新分组', () {
      state.setLoggedIn('alice', false);
      state.addFriend('bob');
      state.addGroup(Group(id: 1, name: 'g'));
      final before = state.chatTargets.map((t) => t.key).toSet();

      state.removeFriend('bob');

      final after = state.chatTargets.map((t) => t.key).toSet();
      expect(after.contains('bob'), isFalse);
      expect(after.contains('group_1'), isTrue);
      expect(before.contains('bob'), isTrue);
      expect(before.contains('group_1'), isTrue);
    });
  });

  // ----------------------------------------------------------
  // F6 AppState.leaveGroup 副作用（已实现）
  // ----------------------------------------------------------
  group('F6 AppState.leaveGroup 副作用', () {
    test('离开群组后群组从列表消失且消息清空', () {
      state.setLoggedIn('alice', false);
      state.addGroup(Group(id: 1, name: 'g'));
      state.addMessage('group_1',
          ChatMessage(sender: 'bob', content: 'hi', messageId: 'm1'));
      expect(state.groups.any((g) => g.id == 1), isTrue);

      state.leaveGroup(1);

      expect(state.groups.any((g) => g.id == 1), isFalse);
      expect(state.getMessages('group_1'), isEmpty);
    });

    test('current 为该群组时被重置', () {
      state.setLoggedIn('alice', false);
      state.addGroup(Group(id: 1, name: 'g'));
      state.selectChat('group_1');
      expect(state.currentChat, 'group_1');

      state.leaveGroup(1);

      expect(state.currentChat, isNull);
    });

    test('离开群组后群组会话未读计数清零', () {
      state.setLoggedIn('alice', false);
      state.addGroup(Group(id: 1, name: 'g'));
      state.addMessage(
          'group_1',
          ChatMessage(
              sender: 'bob', content: 'new', messageId: 'm1', status: 'sent'));
      expect(state.unreadOf('group_1'), 1);

      state.leaveGroup(1);

      expect(state.unreadOf('group_1'), 0);
      expect(state.totalUnread, 0);
    });
  });

  // ----------------------------------------------------------
  // F8 AppState.updateGroupMembers 副作用（已实现）
  // ----------------------------------------------------------
  group('F8 AppState.updateGroupMembers', () {
    test('更新已存在群组的成员列表', () {
      state.setLoggedIn('alice', false);
      state.addGroup(Group(id: 1, name: 'g'));
      expect(state.groups.first.members, isEmpty);

      state.updateGroupMembers(1, ['alice', 'bob']);

      expect(state.groups.first.members, ['alice', 'bob']);
      expect(state.groups.length, 1);
    });

    test('不存在的群组不产生副作用', () {
      state.setLoggedIn('alice', false);
      state.addGroup(Group(id: 1, name: 'g'));
      state.updateGroupMembers(99, ['x']);
      expect(state.groups.length, 1);
      expect(state.groups.first.members, isEmpty);
    });

    test('保留群组名称与 ID', () {
      state.setLoggedIn('alice', false);
      state.addGroup(Group(id: 5, name: '开发组'));
      state.updateGroupMembers(5, ['alice']);
      expect(state.groups.first.id, 5);
      expect(state.groups.first.name, '开发组');
    });
  });
}
