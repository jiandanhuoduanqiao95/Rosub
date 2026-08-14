// ============================================================
// socket_service.dart 阶段 J —— 新协议方法契约（TDD 契约，待实现）
// ============================================================
// 覆盖 P0-2/P0-3/P1-8/P1-9/P1-10（《软件开发文档4.1.0.md》§13.2/§13.3）：
//   - J1 fetchProfile / updateMyProfile
//   - J4 searchUsers / setFriendNote / setFriendGroup / blockUser /
//     unblockUser / fetchBlockedList / fetchFriendsMeta
//   - addFriend 扩展可选验证消息参数
// 未连接（_socket == null）时全部方法：静默无副作用、不崩溃。
//
// 注意：本文件所有测试绝不触发真实网络连接（_socket 恒为 null）。
// ============================================================

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/socket_service.dart';
import 'package:chatroom_flutter/services/state_manager.dart';

AppState get state => AppState.instance;

void resetState() {
  state
    ..setLoggedOut()
    ..setConnectionStatus(ConnectionStatus.disconnected);
}

void main() {
  setUp(resetState);

  group('J —— 未连接时的公开 API 契约', () {
    final service = SocketService();

    test('fetchProfile 未连接不崩溃、无副作用', () async {
      await service.fetchProfile('bob');
      expect(state.profileOf('bob'), isNull);
    });

    test('updateMyProfile 未连接不崩溃、无副作用', () async {
      await service.updateMyProfile(nickname: 'x', signature: 'y');
      expect(state.profileOf('alice'), isNull);
    });

    test('searchUsers 未连接不崩溃、结果为空', () async {
      await service.searchUsers('bob');
      expect(state.userSearchResults, isEmpty);
    });

    test('setFriendNote 未连接不崩溃、无副作用', () async {
      await service.setFriendNote('bob', '阿波');
      expect(state.friendNoteOf('bob'), isNull);
    });

    test('setFriendGroup 未连接不崩溃、无副作用', () async {
      await service.setFriendGroup('bob', '家人');
      expect(state.friendGroupOf('bob'), isNull);
    });

    test('blockUser 未连接不崩溃、无副作用', () async {
      await service.blockUser('bob');
      expect(state.isBlocked('bob'), isFalse);
    });

    test('unblockUser 未连接不崩溃、无副作用', () async {
      await service.unblockUser('bob');
      expect(state.isBlocked('bob'), isFalse);
    });

    test('fetchBlockedList 未连接不崩溃、无副作用', () async {
      await service.fetchBlockedList();
      expect(state.blockedUsers, isEmpty);
    });

    test('fetchFriendsMeta 未连接不崩溃、无副作用', () async {
      await service.fetchFriendsMeta();
      expect(state.friendMetaOf('bob'), isNull);
    });

    test('addFriend 未连接不崩溃（带验证消息参数）', () async {
      state.setLoggedIn('alice', false);
      final before = state.pendingRequests.length;
      await service.addFriend('bob', message: '我是 alice');
      expect(state.pendingRequests.length, before);
    });

    test('全部新方法在未登录未连接时均静默失败', () async {
      final beforeLog = state.statusLog.length;
      await service.fetchProfile('bob');
      await service.updateMyProfile(nickname: 'x');
      await service.searchUsers('x');
      await service.setFriendNote('bob', 'n');
      await service.setFriendGroup('bob', 'g');
      await service.blockUser('bob');
      await service.unblockUser('bob');
      await service.fetchBlockedList();
      await service.fetchFriendsMeta();
      await service.addFriend('bob', message: 'hi');
      expect(state.statusLog.length, beforeLog, reason: '不应产生错误日志');
      expect(state.noticeQueue, isEmpty);
    });
  });
}
