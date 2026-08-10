// ============================================================
// socket_service.dart 搜索 API 未连接契约测试（阶段 H5）
// ============================================================
// 契约（已实现）：
//   SocketService.searchHistory(keyword, {to, groupId, limit=50})
//   发送 type=search_history，headers: keyword/to/group_id/limit。
//   未连接（_socket == null）时静默返回，无任何副作用。
//   （search_history 响应解析在私有 _handleMessage，见文档"未覆盖风险"）
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

  group('searchHistory 未连接契约（H5）', () {
    test('未连接时调用不抛异常且无副作用', () async {
      final service = SocketService();
      state.setLoggedIn('alice', false);
      final beforeMsgs = state.messages.length;

      await service.searchHistory('关键字');
      await service.searchHistory('关键字', to: 'bob');
      await service.searchHistory('关键字', groupId: 1);

      expect(state.messages.length, beforeMsgs);
      expect(state.noticeQueue, isEmpty);
      expect(state.searchResults('bob'), isEmpty);
      expect(state.searchResults('group_1'), isEmpty);
      expect(state.isSearchMode('bob'), isFalse);
      expect(state.isSearchMode('group_1'), isFalse);
    });

    test('未连接时多次调用安全（幂等）', () async {
      final service = SocketService();
      for (var i = 0; i < 5; i++) {
        await service.searchHistory('x', to: 'bob', limit: 50);
      }
      expect(state.isSearchMode('bob'), isFalse);
    });
  });
}
