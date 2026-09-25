// ============================================================
// state_manager.dart 消息搜索状态测试（阶段 H5 —— 客户端状态）
// ============================================================
// 契约（待实现，TDD 红）：
//   AppState 新增搜索状态（按会话隔离，key = 用户名 / group_N）：
//     - setSearchResults(chatKey, msgs) ：设置/替换搜索结果并通知
//     - searchResults(chatKey)          ：未设置返回空列表
//     - isSearchMode(chatKey)           ：是否处于搜索模式（有结果）
//     - clearSearchResults(chatKey)     ：退出搜索模式
//   约束：
//     - 搜索结果与正常消息列表相互独立（不进入 _messages / _messageMap）
//     - 搜索结果不计未读
//     - setLoggedOut / removeFriend / leaveGroup 清理对应搜索状态
//     - selectChat 不影响搜索状态
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

ChatMessage m(String id, String content, {String sender = 'bob'}) =>
    ChatMessage(sender: sender, content: content, messageId: id);

void main() {
  setUp(resetState);

  group('H5 搜索结果状态', () {
    test('setSearchResults → searchResults 返回结果', () {
      state.setLoggedIn('alice', false);
      state.setSearchResults('bob', [m('s1', '包含关键字的消息')]);
      final results = state.searchResults('bob');
      expect(results.length, 1);
      expect(results.first.content, '包含关键字的消息');
    });

    test('再次 setSearchResults → 替换旧结果', () {
      state.setLoggedIn('alice', false);
      state.setSearchResults('bob', [m('s1', '第一条')]);
      state.setSearchResults('bob', [m('s2', '第二条'), m('s3', '第三条')]);
      expect(state.searchResults('bob').length, 2);
    });

    test('isSearchMode：设置后 true、清除后 false、未设置 false', () {
      state.setLoggedIn('alice', false);
      expect(state.isSearchMode('bob'), isFalse);
      state.setSearchResults('bob', [m('s1', 'x')]);
      expect(state.isSearchMode('bob'), isTrue);
      state.clearSearchResults('bob');
      expect(state.isSearchMode('bob'), isFalse);
    });

    test('clearSearchResults → 结果清空', () {
      state.setLoggedIn('alice', false);
      state.setSearchResults('bob', [m('s1', 'x')]);
      state.clearSearchResults('bob');
      expect(state.searchResults('bob'), isEmpty);
      expect(state.isSearchMode('bob'), isFalse);
    });

    test('未设置 key → searchResults 返回空列表', () {
      state.setLoggedIn('alice', false);
      expect(state.searchResults('bob'), isEmpty);
      expect(state.isSearchMode('bob'), isFalse);
    });

    test('不同会话搜索结果相互独立', () {
      state.setLoggedIn('alice', false);
      state.setSearchResults('bob', [m('s1', 'bob 结果')]);
      state.setSearchResults('group_1', [m('s2', '群结果')]);
      expect(state.searchResults('bob').first.content, 'bob 结果');
      expect(state.searchResults('group_1').first.content, '群结果');
      state.clearSearchResults('bob');
      expect(state.isSearchMode('group_1'), isTrue);
    });

    test('搜索结果与正常消息列表相互独立', () {
      state.setLoggedIn('alice', false);
      state.addMessage('bob', m('m1', '正常消息'));
      state.setSearchResults('bob', [m('s1', '搜索结果')]);
      expect(state.getMessages('bob').length, 1);
      expect(state.getMessages('bob').first.content, '正常消息');
      expect(state.searchResults('bob').first.content, '搜索结果');
    });

    test('搜索结果不计未读', () {
      state.setLoggedIn('alice', false);
      state.setSearchResults('bob', [
        ChatMessage(
            sender: 'bob', content: 'x', messageId: 's1', status: 'sent'),
      ]);
      expect(state.totalUnread, 0);
    });

    test('setLoggedOut 清空全部搜索结果', () {
      state.setLoggedIn('alice', false);
      state.setSearchResults('bob', [m('s1', 'x')]);
      state.setSearchResults('group_1', [m('s2', 'y')]);
      state.setLoggedOut();
      expect(state.isSearchMode('bob'), isFalse);
      expect(state.isSearchMode('group_1'), isFalse);
      expect(state.searchResults('bob'), isEmpty);
    });

    test('removeFriend 清理该会话搜索结果', () {
      state.setLoggedIn('alice', false);
      state.setSearchResults('bob', [m('s1', 'x')]);
      state.setSearchResults('group_1', [m('s2', 'y')]);
      state.removeFriend('bob');
      expect(state.isSearchMode('bob'), isFalse);
      expect(state.isSearchMode('group_1'), isTrue);
    });

    test('leaveGroup 清理该群搜索结果', () {
      state.setLoggedIn('alice', false);
      state.setSearchResults('bob', [m('s1', 'x')]);
      state.setSearchResults('group_1', [m('s2', 'y')]);
      state.leaveGroup(1);
      expect(state.isSearchMode('group_1'), isFalse);
      expect(state.isSearchMode('bob'), isTrue);
    });

    test('selectChat 不影响搜索状态', () {
      state.setLoggedIn('alice', false);
      state.setSearchResults('bob', [m('s1', 'x')]);
      state.selectChat('bob');
      state.selectChat('group_1');
      expect(state.isSearchMode('bob'), isTrue);
    });

    test('clearSearchResults 对未搜索会话调用不抛异常', () {
      state.setLoggedIn('alice', false);
      expect(() => state.clearSearchResults('nobody'), returnsNormally);
    });

    test('setSearchResults 携带 query → searchQueryOf 返回；未设置返回空串', () {
      state.setLoggedIn('alice', false);
      expect(state.searchQueryOf('bob'), '');
      state.setSearchResults('bob', [m('s1', 'x')], query: 'flutter');
      expect(state.searchQueryOf('bob'), 'flutter');
      state.clearSearchResults('bob');
      expect(state.searchQueryOf('bob'), '');
    });

    test('setLoggedOut 清空搜索关键字', () {
      state.setLoggedIn('alice', false);
      state.setSearchResults('bob', [m('s1', 'x')], query: 'flutter');
      state.setLoggedOut();
      expect(state.searchQueryOf('bob'), '');
    });
  });
}
