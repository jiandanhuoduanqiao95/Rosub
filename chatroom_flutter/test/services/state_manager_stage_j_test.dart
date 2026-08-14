// ============================================================
// state_manager.dart 阶段 J —— 在线状态/资料/备注分组/黑名单状态（TDD 契约，待实现）
// ============================================================
// 覆盖 P0-2/P0-3/P1-8/P1-9/P1-10（《软件开发文档4.1.0.md》§13.2/§13.3）：
//   - J1 资料缓存：updateProfile / profileOf / 登出清理
//   - J2 在线集合：setOnlineUsers / updatePresence / isOnline / 登出清理
//   - J4 好友备注/分组：updateFriendMeta / friendsByGroup / setFriendMetaList
//   - J4 黑名单：addBlockedUser / removeBlockedUser / isBlocked /
//     setBlockedUsers + 消息不落地防御（黑名单后不接收消息）
//   - J4 验证消息：addPendingRequest 扩展 message
//   - J4 用户搜索：setUserSearchResults / clearUserSearchResults
//
// 注意：本文件所有测试为纯状态单元测试，不触网。
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

  group('J2 —— 在线状态集合', () {
    test('初始：无人在线', () {
      expect(state.onlineUsers, isEmpty);
      expect(state.isOnline('bob'), isFalse);
    });

    test('setOnlineUsers 批量设置', () {
      state.setOnlineUsers(['alice', 'bob']);
      expect(state.isOnline('alice'), isTrue);
      expect(state.isOnline('bob'), isTrue);
      expect(state.isOnline('carol'), isFalse);
    });

    test('setOnlineUsers 整体替换', () {
      state.setOnlineUsers(['alice']);
      state.setOnlineUsers(['bob']);
      expect(state.isOnline('alice'), isFalse);
      expect(state.isOnline('bob'), isTrue);
    });

    test('updatePresence 上线', () {
      state.updatePresence('bob', true);
      expect(state.isOnline('bob'), isTrue);
    });

    test('updatePresence 下线', () {
      state.updatePresence('bob', true);
      state.updatePresence('bob', false);
      expect(state.isOnline('bob'), isFalse);
    });

    test('updatePresence 重复上线幂等', () {
      state.updatePresence('bob', true);
      state.updatePresence('bob', true);
      expect(state.onlineUsers.length, 1);
    });

    test('登出清空在线集合', () {
      state.setLoggedIn('alice', false);
      state.updatePresence('bob', true);
      state.setLoggedOut();
      expect(state.onlineUsers, isEmpty);
      expect(state.isOnline('bob'), isFalse);
    });

    test('状态切换不影响在线集合（重连保留）', () {
      state.setLoggedIn('alice', false);
      state.updatePresence('bob', true);
      state.setReconnecting();
      expect(state.isOnline('bob'), isTrue, reason: '重连期间不丢在线状态');
    });

    test('在线状态不产生未读计数', () {
      state.setLoggedIn('alice', false);
      state.updatePresence('bob', true);
      expect(state.totalUnread, 0);
    });
  });

  group('J1 —— 用户资料缓存', () {
    test('初始 profileOf 返回 null', () {
      expect(state.profileOf('bob'), isNull);
    });

    test('updateProfile 保存并读取', () {
      final p = UserProfile(username: 'bob', nickname: '阿波');
      state.updateProfile(p);
      expect(state.profileOf('bob')?.nickname, '阿波');
    });

    test('updateProfile 覆盖更新', () {
      state.updateProfile(UserProfile(username: 'bob', nickname: '旧'));
      state.updateProfile(UserProfile(username: 'bob', nickname: '新'));
      expect(state.profileOf('bob')?.nickname, '新');
    });

    test('资料按用户隔离', () {
      state.updateProfile(UserProfile(username: 'bob', nickname: 'B'));
      expect(state.profileOf('alice'), isNull);
    });

    test('登出清空资料缓存', () {
      state.setLoggedIn('alice', false);
      state.updateProfile(UserProfile(username: 'bob', nickname: 'B'));
      state.setLoggedOut();
      expect(state.profileOf('bob'), isNull);
    });
  });

  group('J4 —— 好友备注/分组状态', () {
    test('初始 friendMetaOf 返回 null', () {
      expect(state.friendMetaOf('bob'), isNull);
      expect(state.friendNoteOf('bob'), isNull);
      expect(state.friendGroupOf('bob'), isNull);
    });

    test('updateFriendMeta 设置备注', () {
      state.updateFriendMeta('bob', note: '阿波');
      expect(state.friendNoteOf('bob'), '阿波');
    });

    test('updateFriendMeta 设置分组', () {
      state.updateFriendMeta('bob', groupName: '家人');
      expect(state.friendGroupOf('bob'), '家人');
    });

    test('updateFriendMeta 部分更新互不覆盖', () {
      state.updateFriendMeta('bob', note: '阿波', groupName: '家人');
      state.updateFriendMeta('bob', note: '阿波2');
      expect(state.friendNoteOf('bob'), '阿波2');
      expect(state.friendGroupOf('bob'), '家人', reason: '未传字段保持原值');
    });

    test('updateFriendMeta 清空备注/分组', () {
      state.updateFriendMeta('bob', note: 'x', groupName: '家人');
      state.updateFriendMeta('bob', note: '', groupName: '');
      expect(state.friendNoteOf('bob'), '');
      expect(state.friendGroupOf('bob'), '');
    });

    test('setFriendMetaList 批量替换', () {
      state.setFriendMetaList([
        const FriendMeta(username: 'bob', note: 'B', groupName: '家人'),
        const FriendMeta(username: 'carol', note: 'C'),
      ]);
      expect(state.friendNoteOf('bob'), 'B');
      expect(state.friendGroupOf('bob'), '家人');
      expect(state.friendNoteOf('carol'), 'C');
      expect(state.friendNoteOf('alice'), isNull);
    });

    test('friendsByGroup 分组视图（空分组归"未分组"）', () {
      state.setFriendMetaList([
        const FriendMeta(username: 'bob', groupName: '家人'),
        const FriendMeta(username: 'carol', groupName: '家人'),
        const FriendMeta(username: 'dave'),
      ]);
      final groups = state.friendsByGroup;
      expect(groups['家人'], containsAll(['bob', 'carol']));
      expect(groups[AppState.ungroupedLabel], ['dave']);
    });

    test('removeFriend 连带清理备注元数据', () {
      state.setLoggedIn('alice', false);
      state.updateFriendMeta('bob', note: 'B');
      state.removeFriend('bob');
      expect(state.friendMetaOf('bob'), isNull);
    });

    test('登出清空备注/分组', () {
      state.setLoggedIn('alice', false);
      state.updateFriendMeta('bob', note: 'B', groupName: '家人');
      state.setLoggedOut();
      expect(state.friendMetaOf('bob'), isNull);
      expect(state.friendsByGroup, isEmpty);
    });
  });

  group('J4 —— 黑名单状态', () {
    test('初始 isBlocked 为 false', () {
      expect(state.isBlocked('bob'), isFalse);
      expect(state.blockedUsers, isEmpty);
    });

    test('addBlockedUser / removeBlockedUser', () {
      state.addBlockedUser('bob');
      expect(state.isBlocked('bob'), isTrue);
      state.removeBlockedUser('bob');
      expect(state.isBlocked('bob'), isFalse);
    });

    test('addBlockedUser 重复幂等', () {
      state.addBlockedUser('bob');
      state.addBlockedUser('bob');
      expect(state.blockedUsers.length, 1);
    });

    test('setBlockedUsers 批量替换', () {
      state.setBlockedUsers(['bob', 'carol']);
      expect(state.isBlocked('bob'), isTrue);
      expect(state.isBlocked('carol'), isTrue);
      state.setBlockedUsers(['bob']);
      expect(state.isBlocked('carol'), isFalse);
    });

    test('登出清空黑名单', () {
      state.setLoggedIn('alice', false);
      state.addBlockedUser('bob');
      state.setLoggedOut();
      expect(state.blockedUsers, isEmpty);
    });

    test('拉黑用户的消息不落地（黑名单后不接收消息防御）', () {
      state.setLoggedIn('alice', false);
      state.addBlockedUser('bob');
      state.addMessage(
        'bob',
        ChatMessage(
          sender: 'bob',
          content: '骚扰消息',
          messageId: 'm1',
          status: 'sent',
        ),
      );
      expect(state.getMessages('bob'), isEmpty, reason: '拉黑后消息不落地');
      expect(state.totalUnread, 0, reason: '拉黑后消息不计未读');
    });

    test('自己的消息不受黑名单防御影响', () {
      state.setLoggedIn('alice', false);
      state.addBlockedUser('bob');
      state.addMessage(
        'bob',
        ChatMessage(
          sender: 'alice',
          content: '我发给拉黑对象的旧消息',
          messageId: 'm2',
          status: 'sent',
        ),
      );
      expect(state.getMessages('bob').length, 1);
    });

    test('黑名单不影响非拉黑用户消息', () {
      state.setLoggedIn('alice', false);
      state.addBlockedUser('bob');
      state.addMessage(
        'carol',
        ChatMessage(
          sender: 'carol',
          content: '正常消息',
          messageId: 'm3',
          status: 'sent',
        ),
      );
      expect(state.getMessages('carol').length, 1);
    });
  });

  group('J4 —— 好友请求验证消息', () {
    test('addPendingRequest 携带验证消息', () {
      state.addPendingRequest('bob', message: '我是 alice');
      expect(state.pendingRequestMessageOf('bob'), '我是 alice');
    });

    test('无验证消息时返回空串', () {
      state.addPendingRequest('bob');
      expect(state.pendingRequestMessageOf('bob'), '');
    });

    test('removePendingRequest 清理验证消息', () {
      state.addPendingRequest('bob', message: 'x');
      state.removePendingRequest('bob');
      expect(state.pendingRequestMessageOf('bob'), isNull);
    });

    test('登出清理验证消息', () {
      state.setLoggedIn('alice', false);
      state.addPendingRequest('bob', message: 'x');
      state.setLoggedOut();
      expect(state.pendingRequestMessageOf('bob'), isNull);
    });
  });

  group('J4 —— 发送请求时预填的备注名（pending note）', () {
    test('setPendingFriendNote / pendingFriendNoteOf', () {
      state.setPendingFriendNote('bob', '阿波');
      expect(state.pendingFriendNoteOf('bob'), '阿波');
    });

    test('空备注不存储', () {
      state.setPendingFriendNote('bob', '');
      expect(state.pendingFriendNoteOf('bob'), isNull);
    });

    test('takePendingFriendNote 取出并移除（仅消费一次）', () {
      state.setPendingFriendNote('bob', '阿波');
      expect(state.takePendingFriendNote('bob'), '阿波');
      expect(state.pendingFriendNoteOf('bob'), isNull);
      expect(state.takePendingFriendNote('bob'), isNull);
    });

    test('未设置时返回 null', () {
      expect(state.pendingFriendNoteOf('bob'), isNull);
      expect(state.takePendingFriendNote('bob'), isNull);
    });

    test('登出清空 pending note', () {
      state.setLoggedIn('alice', false);
      state.setPendingFriendNote('bob', '阿波');
      state.setLoggedOut();
      expect(state.pendingFriendNoteOf('bob'), isNull);
    });
  });

  group('J4 —— 用户搜索结果', () {
    test('setUserSearchResults 设置并读取', () {
      state.setUserSearchResults(['bob', 'carol']);
      expect(state.userSearchResults, ['bob', 'carol']);
    });

    test('重复设置整体替换', () {
      state.setUserSearchResults(['bob']);
      state.setUserSearchResults(['carol']);
      expect(state.userSearchResults, ['carol']);
    });

    test('clearUserSearchResults 清空', () {
      state.setUserSearchResults(['bob']);
      state.clearUserSearchResults();
      expect(state.userSearchResults, isEmpty);
    });

    test('登出清空搜索结果', () {
      state.setLoggedIn('alice', false);
      state.setUserSearchResults(['bob']);
      state.setLoggedOut();
      expect(state.userSearchResults, isEmpty);
    });

    test('搜索结果不产生未读', () {
      state.setLoggedIn('alice', false);
      state.setUserSearchResults(['bob']);
      expect(state.totalUnread, 0);
    });
  });
}
