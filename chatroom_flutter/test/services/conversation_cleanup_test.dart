// opt8 #8 —— 删除好友/退出群集中会话清理（内存 + 全局映射 + 本地缓存）
//
// 契约：
//   - removeFriend / leaveGroup / removeGroup 走 _removeConversation：
//     _messages + _messageMap/_messageChatKey（归属校验）+ unread +
//     noMoreHistory + search + MessageCache.clearConversation，只 notify 一次；
//   - 不清理 _pendingMessages（阶段 I 契约，state_manager_stage_i_test 锁定）；
//   - 不清理 _conversationMeta（范围外）；
//   - 重加好友/回群后 prepend 同 ID 历史消息恢复显示（修复前 _messageMap
//     残留导致去重丢弃）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/message_cache.dart';
import 'package:chatroom_flutter/services/state_manager.dart';

AppState get state => AppState.instance;

ChatMessage _msg(String id, String sender, String content,
    {String status = 'sent', int? groupId}) {
  return ChatMessage(
    sender: sender,
    content: content,
    type: groupId != null ? 'group_chat' : 'chat',
    messageId: id,
    timestamp: DateTime(2026, 1, 1, 12),
    status: status,
    groupId: groupId,
  );
}

Group _group(int id, String name) {
  return Group(id: id, name: name, members: const ['alice', 'bob']);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Directory? tmpDir;

  setUp(() async {
    state.setLoggedOut();
    await MessageCache.resetForTest();
  });

  tearDown(() async {
    await MessageCache.resetForTest();
    final dir = tmpDir;
    if (dir != null && dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    tmpDir = null;
  });

  group('#8 —— 集中会话清理（opt8）', () {
    test('removeFriend → addFriend → prepend 同 id，消息恢复出现', () {
      state.setLoggedIn('alice', false);
      state.addFriend('bob');
      state.addMessage('bob', _msg('m1', 'bob', '历史消息'));
      expect(state.messageById('m1'), isNotNull);

      state.removeFriend('bob');
      expect(state.getMessages('bob'), isEmpty);
      expect(state.messageById('m1'), isNull);

      state.addFriend('bob');
      state.prependHistoryMessages('bob', [
        _msg('m1', 'bob', '历史消息', status: 'delivered'),
      ]);
      final msgs = state.getMessages('bob');
      expect(msgs.length, 1, reason: '重加好友后同 id 历史不得被去重丢弃');
      expect(msgs.first.status, 'delivered');
      expect(state.messageById('m1'), isNotNull);
    });

    test('leaveGroup → addGroup → prepend 同 id，消息恢复出现', () {
      state.setLoggedIn('alice', false);
      state.addGroup(_group(1, '开发组'));
      state.addMessage('group_1', _msg('g1', 'bob', '群历史', groupId: 1));

      state.leaveGroup(1);
      expect(state.getMessages('group_1'), isEmpty);
      expect(state.messageById('g1'), isNull);

      state.addGroup(_group(1, '开发组'));
      state.prependHistoryMessages('group_1', [
        _msg('g1', 'bob', '群历史', status: 'delivered', groupId: 1),
      ]);
      expect(state.getMessages('group_1').length, 1);
      expect(state.messageById('g1'), isNotNull);
    });

    test('removeGroup → addGroup → prepend 同 id，消息恢复出现', () {
      state.setLoggedIn('alice', false);
      state.addGroup(_group(2, '被解散组'));
      state.addMessage('group_2', _msg('g2', 'bob', '群历史', groupId: 2));

      state.removeGroup(2);
      expect(state.getMessages('group_2'), isEmpty);
      expect(state.messageById('g2'), isNull);

      state.addGroup(_group(2, '被解散组'));
      state.prependHistoryMessages('group_2', [
        _msg('g2', 'bob', '群历史', status: 'delivered', groupId: 2),
      ]);
      expect(state.getMessages('group_2').length, 1);
      expect(state.messageById('g2'), isNotNull);
    });

    test('removeFriend 不影响其他会话（内存语义）', () {
      state.setLoggedIn('alice', false);
      state.addFriend('bob');
      state.addFriend('carol');
      state.addMessage('bob', _msg('m1', 'bob', '与 bob'));
      state.addMessage('carol', _msg('c1', 'carol', '与 carol'));

      state.removeFriend('bob');
      expect(state.getMessages('carol').length, 1);
      expect(state.messageById('c1'), isNotNull);
      expect(state.friends, ['carol']);
    });

    test('unread / noMoreHistory / search 随会话清理', () {
      state.setLoggedIn('alice', false);
      state.addFriend('bob');
      state.addMessage('bob', _msg('m1', 'bob', '未读', status: 'sent'));
      state.setNoMoreHistory('bob');
      state.setSearchResults('bob', [_msg('m2', 'bob', '结果')],
          query: '关键');
      expect(state.unreadOf('bob'), 1);
      expect(state.hasMoreHistory('bob'), isFalse);
      expect(state.isSearchMode('bob'), isTrue);

      state.removeFriend('bob');
      expect(state.unreadOf('bob'), 0);
      expect(state.hasMoreHistory('bob'), isTrue);
      expect(state.isSearchMode('bob'), isFalse);
      expect(state.searchQueryOf('bob'), '');
    });

    test('leaveGroup 同步清理 unread / noMoreHistory / search', () {
      state.setLoggedIn('alice', false);
      state.addGroup(_group(3, '清理组'));
      state.addMessage('group_3',
          _msg('g3', 'bob', '未读', status: 'sent', groupId: 3));
      state.setNoMoreHistory('group_3');
      state.setSearchResults('group_3', [_msg('g4', 'bob', '结果')],
          query: '关键');
      expect(state.unreadOf('group_3'), 1);

      state.leaveGroup(3);
      expect(state.unreadOf('group_3'), 0);
      expect(state.hasMoreHistory('group_3'), isTrue);
      expect(state.isSearchMode('group_3'), isFalse);
    });

    test('缓存会话清理：removeFriend 后该会话缓存清空，其他会话保留',
        () async {
      tmpDir = await Directory.systemTemp.createTemp('chatroom_cleanup_test');
      await MessageCache.init(dbPath: '${tmpDir!.path}/cache.db');
      state.setLoggedIn('alice', false);
      state.addFriend('bob');
      state.addFriend('carol');
      state.addMessage('bob', _msg('m1', 'bob', '与 bob'));
      state.addMessage('carol', _msg('c1', 'carol', '与 carol'));
      await MessageCache.flush();
      expect((await MessageCache.store!.loadMessages('bob')).length, 1);

      state.removeFriend('bob');
      await MessageCache.flush();
      expect(await MessageCache.store!.loadMessages('bob'), isEmpty);
      expect(
          (await MessageCache.store!.loadMessages('carol')).length, 1);
      final convs = await MessageCache.store!.conversations();
      expect(convs.contains('bob'), isFalse);
      expect(convs.contains('carol'), isTrue);
    });

    test('removeFriend 保留 pendingMessages（阶段 I 契约不回归）', () {
      state.setLoggedIn('alice', false);
      state.addFriend('bob');
      state.enqueuePendingMessage('bob', _msg('p1', 'alice', '断线待发'));
      state.removeFriend('bob');
      expect(state.pendingCount, 1);
      expect(state.pendingMessages.single.message.messageId, 'p1');
    });

    test('removeFriend 清理 conversationMeta（防重加后旧置顶/草稿复活）', () {
      state.setLoggedIn('alice', false);
      state.addFriend('bob');
      state.setConversationPinned('bob', true);
      state.setConversationDraft('bob', '草稿');
      state.setConversationMuted('bob', true);
      state.removeFriend('bob');
      expect(state.isPinned('bob'), isFalse);
      expect(state.draftOf('bob'), '');
      expect(state.isMuted('bob'), isFalse);
      expect(state.conversationMetaOf('bob'), isNull);
    });

    test('removeMessageLocally 清理归属映射，updateMessageStatus 不再命中',
        () {
      state.setLoggedIn('alice', false);
      state.addFriend('bob');
      state.addMessage('bob', _msg('m1', 'bob', '会被删除'));
      state.removeMessageLocally('bob', 'm1');
      expect(state.messageById('m1'), isNull);
      state.updateMessageStatus('m1', 'delivered');
      expect(state.messageById('m1'), isNull, reason: '消息已删，no-op 不复活');
    });
  });
}
