// ============================================================
// state_manager.dart 单元测试
// ============================================================
// 覆盖 AppState（ChangeNotifier 单例）的全部公开状态逻辑：
//   - 登录/登出状态切换与清理
//   - 好友/群组/好友请求列表管理
//   - 消息添加、messageId 去重
//   - 未读计数（阶段 E）：收消息累加、切会话清零、自身/已读不计数
//   - 历史分页 prependHistoryMessages 去重 + 时间排序
//   - 文件请求队列 + 群文件去重
//   - 历史"无更多"标记
//   - chatTargets 分组、displayNameForChat、getGroupName
//   - 状态日志截断、通知队列
//   - 重连状态（阶段 D）
//
// 注意：AppState 是单例，测试间需通过 setLoggedOut() 复位。
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

  group('登录与连接状态', () {
    test('setLoggedIn 设置用户名/管理员/连接状态并清零重连计数', () {
      state.setLoggedIn('alice', false);
      expect(state.isLoggedIn, isTrue);
      expect(state.username, 'alice');
      expect(state.isAdmin, isFalse);
      expect(state.connectionStatus, ConnectionStatus.connected);
      expect(state.reconnectAttempts, 0);
    });

    test('setLoggedOut 清空所有会话状态', () {
      state.setLoggedIn('alice', true);
      state.setFriends(['bob']);
      state.addMessage('bob',
          ChatMessage(sender: 'bob', content: 'hi', messageId: 'm1', status: 'sent'));
      state.selectChat('bob');

      state.setLoggedOut();

      expect(state.isLoggedIn, isFalse);
      expect(state.username, isNull);
      expect(state.friends, isEmpty);
      expect(state.groups, isEmpty);
      expect(state.messages, isEmpty);
      expect(state.currentChat, isNull);
      expect(state.totalUnread, 0);
      expect(state.connectionStatus, ConnectionStatus.disconnected);
    });

    test('setReconnecting / setReconnectAttempt（阶段 D）', () {
      state.setReconnecting();
      expect(state.connectionStatus, ConnectionStatus.reconnecting);
      state.setReconnectAttempt(3);
      expect(state.reconnectAttempts, 3);
    });

    test('setConnectionStatus', () {
      state.setConnectionStatus(ConnectionStatus.connecting);
      expect(state.connectionStatus, ConnectionStatus.connecting);
    });
  });

  group('好友/群组/好友请求列表', () {
    test('setFriends 替换列表且去重添加', () {
      state.setFriends(['bob', 'carol']);
      expect(state.friends, ['bob', 'carol']);
      state.setFriends(['dave']);
      expect(state.friends, ['dave']);
    });

    test('addFriend 去重', () {
      state.addFriend('bob');
      state.addFriend('bob');
      expect(state.friends, ['bob']);
    });

    test('removeFriend 移除消息并重置当前会话', () {
      state.setLoggedIn('alice', false);
      state.addFriend('bob');
      state.addMessage('bob',
          ChatMessage(sender: 'bob', content: 'x', messageId: 'm1'));
      state.selectChat('bob');
      expect(state.currentChat, 'bob');

      state.removeFriend('bob');

      expect(state.friends, isEmpty);
      expect(state.getMessages('bob'), isEmpty);
      expect(state.currentChat, isNull);
    });

    test('setGroups / addGroup 去重', () {
      state.setGroups([Group(id: 1, name: 'g1')]);
      state.addGroup(Group(id: 1, name: 'g1')); // 同 id 去重
      state.addGroup(Group(id: 2, name: 'g2'));
      expect(state.groups.length, 2);
      expect(state.groups.firstWhere((g) => g.id == 1).name, 'g1');
    });

    test('addPendingRequest / removePendingRequest 去重', () {
      state.addPendingRequest('alice');
      state.addPendingRequest('alice'); // 去重
      state.addPendingRequest('bob');
      expect(state.pendingRequests, ['alice', 'bob']);
      state.removePendingRequest('alice');
      expect(state.pendingRequests, ['bob']);
    });
  });

  group('未读消息徽标（阶段 E）', () {
    setUp(() => state.setLoggedIn('alice', false));

    test('收到对方未读消息累加计数', () {
      state.addMessage('bob',
          ChatMessage(sender: 'bob', content: '1', messageId: 'm1', status: 'sent'));
      state.addMessage('bob',
          ChatMessage(sender: 'bob', content: '2', messageId: 'm2', status: 'sent'));
      expect(state.unreadOf('bob'), 2);
      expect(state.totalUnread, 2);
    });

    test('切换到该会话清零未读', () {
      state.addMessage('bob',
          ChatMessage(sender: 'bob', content: 'hi', messageId: 'm1', status: 'sent'));
      expect(state.unreadOf('bob'), 1);
      state.selectChat('bob');
      expect(state.unreadOf('bob'), 0);
      expect(state.totalUnread, 0);
    });

    test('当前会话收到消息不计未读', () {
      state.selectChat('bob');
      state.addMessage('bob',
          ChatMessage(sender: 'bob', content: 'live', messageId: 'm1', status: 'sent'));
      expect(state.unreadOf('bob'), 0);
    });

    test('自身发送的消息不计未读', () {
      state.addMessage('bob',
          ChatMessage(sender: 'alice', content: 'me', messageId: 'm1', status: 'sent'));
      expect(state.unreadOf('bob'), 0);
    });

    test('已读历史（delivered）不计未读', () {
      state.addMessage('bob',
          ChatMessage(sender: 'bob', content: 'history', messageId: 'm1', status: 'delivered'));
      expect(state.unreadOf('bob'), 0);
      expect(state.totalUnread, 0);
    });

    test('不同会话未读独立', () {
      state.addFriend('bob');
      state.addFriend('carol');
      state.addMessage('bob',
          ChatMessage(sender: 'bob', content: 'b', messageId: 'm1', status: 'sent'));
      state.addMessage('carol',
          ChatMessage(sender: 'carol', content: 'c', messageId: 'm2', status: 'sent'));
      expect(state.unreadOf('bob'), 1);
      expect(state.unreadOf('carol'), 1);
      expect(state.totalUnread, 2);
      state.selectChat('bob');
      expect(state.unreadOf('bob'), 0);
      expect(state.unreadOf('carol'), 1);
      expect(state.totalUnread, 1);
    });
  });

  group('消息去重与历史分页', () {
    setUp(() => state.setLoggedIn('alice', false));

    test('addMessage 按 messageId 去重，仅更新状态', () {
      state.addMessage('bob',
          ChatMessage(sender: 'bob', content: 'hi', messageId: 'm1', status: 'sent'));
      state.addMessage('bob',
          ChatMessage(sender: 'bob', content: 'hi', messageId: 'm1', status: 'delivered'));
      expect(state.getMessages('bob').length, 1);
      expect(state.getMessages('bob').first.status, 'delivered');
    });

    test('updateMessageStatus / recallMessage 更新状态', () {
      state.addMessage('bob',
          ChatMessage(sender: 'bob', content: 'hi', messageId: 'm1'));
      state.recallMessage('m1');
      expect(state.getMessages('bob').first.isRecalled, isTrue);
      state.updateMessageStatus('m1', 'delivered');
      expect(state.getMessages('bob').first.status, 'delivered');
    });

    test('prependHistoryMessages 去重', () {
      state.addMessage('bob',
          ChatMessage(sender: 'bob', content: 'existing', messageId: 'm1'));
      state.prependHistoryMessages('bob', [
        ChatMessage(sender: 'bob', content: 'existing', messageId: 'm1'), // 重复，跳过
        ChatMessage(sender: 'bob', content: 'old', messageId: 'm2'),
      ]);
      final msgs = state.getMessages('bob');
      expect(msgs.length, 2);
      expect(msgs.any((m) => m.content == 'old'), isTrue);
    });

    test('prependHistoryMessages 按 timestamp 升序排序', () {
      final t1 = DateTime(2026, 1, 1, 10);
      final t2 = DateTime(2026, 1, 1, 9); // 更早
      state.prependHistoryMessages('bob', [
        ChatMessage(sender: 'bob', content: 'later', messageId: 'a', timestamp: t1),
        ChatMessage(sender: 'bob', content: 'earlier', messageId: 'b', timestamp: t2),
      ]);
      final msgs = state.getMessages('bob');
      expect(msgs.first.content, 'earlier');
      expect(msgs.last.content, 'later');
    });

    test('prependHistoryMessages 空列表为 no-op', () {
      state.prependHistoryMessages('bob', []);
      expect(state.getMessages('bob'), isEmpty);
    });

    test('hasMoreHistory / setNoMoreHistory', () {
      expect(state.hasMoreHistory('bob'), isTrue);
      state.setNoMoreHistory('bob');
      expect(state.hasMoreHistory('bob'), isFalse);
    });
  });

  group('文件请求队列', () {
    test('addFileRequest 去重', () {
      state.addFileRequest(FileRequest(
          messageId: 'f1', sender: 'bob', filename: 'a.txt', filesize: 10));
      state.addFileRequest(FileRequest(
          messageId: 'f1', sender: 'bob', filename: 'a.txt', filesize: 10));
      expect(state.pendingFileRequests.length, 1);
      expect(state.hasPendingFileRequests, isTrue);
    });

    test('removeFileRequest', () {
      state.addFileRequest(FileRequest(
          messageId: 'f1', sender: 'bob', filename: 'a.txt', filesize: 10));
      state.removeFileRequest('f1');
      expect(state.pendingFileRequests, isEmpty);
      expect(state.hasPendingFileRequests, isFalse);
    });

    test('markGroupFileProcessed 首次返回 true，再次返回 false', () {
      expect(state.markGroupFileProcessed('g1'), isTrue);
      expect(state.markGroupFileProcessed('g1'), isFalse);
    });
  });

  group('chatTargets 分组与显示名', () {
    test('空状态下无会话', () {
      expect(state.chatTargets, isEmpty);
    });

    test('好友与群组混合分组', () {
      state.setFriends(['bob', 'carol']);
      state.setGroups([Group(id: 1, name: '开发组')]);
      final targets = state.chatTargets;
      final keys = targets.map((t) => t.key).toList();
      expect(keys, containsAll(['bob', 'carol', 'group_1']));
      final grp = targets.firstWhere((t) => t.key == 'group_1');
      expect(grp.isGroup, isTrue);
      expect(grp.displayName, '开发组 (ID:1)');
    });

    test('系统消息会话仅在 服务器 有消息时出现', () {
      state.setLoggedIn('alice', false);
      expect(state.chatTargets.any((t) => t.key == '服务器'), isFalse);
      state.addMessage('服务器',
          ChatMessage(sender: '服务器', content: '公告', messageId: 's1', type: 'system'));
      expect(state.chatTargets.any((t) => t.key == '服务器'), isTrue);
    });

    test('displayNameForChat 各种 key', () {
      state.setGroups([Group(id: 1, name: '开发组')]);
      expect(state.displayNameForChat('服务器'), '系统消息');
      expect(state.displayNameForChat('group_1'), '开发组 (ID:1)');
      expect(state.displayNameForChat('group_99'), '群组 99');
      expect(state.displayNameForChat('bob'), 'bob');
    });

    test('getGroupName', () {
      state.setGroups([Group(id: 2, name: '二号群')]);
      expect(state.getGroupName(2), '二号群');
      expect(state.getGroupName(999), isNull);
    });
  });

  group('状态日志与通知队列', () {
    test('log 追加到 statusLog 且截断', () {
      for (int i = 0; i < 510; i++) {
        state.log('msg $i');
      }
      expect(state.statusLog.length, lessThanOrEqualTo(500));
    });

    test('showNotice / consumeNotice 队列', () {
      state.showNotice('a');
      state.showNotice('b');
      expect(state.noticeQueue, ['a', 'b']);
      state.consumeNotice();
      expect(state.noticeQueue, ['b']);
      state.consumeNotice();
      expect(state.noticeQueue, isEmpty);
    });
  });

  group('getMessages 对未知 key 返回空', () {
    test('unknown key returns empty list', () {
      expect(state.getMessages('nobody'), isEmpty);
    });
  });
}