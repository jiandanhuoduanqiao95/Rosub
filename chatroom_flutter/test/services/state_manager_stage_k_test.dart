// ============================================================
// state_manager.dart 阶段 K —— 会话体验状态（已实现，全部转绿）
// ============================================================
// 覆盖 P1-11~P1-14 / P1-2 / P1-4（《软件开发文档4.1.0.md》§11 阶段 K / §13.3）：
//   - K1 会话置顶：pinnedChatTargets / unpinnedChatTargets（置顶在前）
//   - K2 逐会话草稿：多会话草稿互不泄漏（bug 级缺陷回归锁定）
//   - K1-K3 登录推送：setConversationMetaList 批量替换会话元数据
//   - K5 消息操作：引用 / 表情回应状态 + 仅我删除（本地）
//
// 用户决策修订：P1-1 编辑、P1-3 转发来源标注、P1-15 系统消息分类已移除。
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

ChatMessage _systemMsg(String id, String content, {String sender = '系统'}) {
  return ChatMessage(
    sender: sender,
    content: content,
    type: 'system',
    messageId: id,
  );
}

ChatMessage _chatMsg(String id, String sender, String content) {
  return ChatMessage(
    sender: sender,
    content: content,
    messageId: id,
  );
}

void main() {
  setUp(resetState);

  group('K1 —— 会话置顶', () {
    test('无置顶时 pinnedChatTargets 为空', () {
      state.setLoggedIn('alice', false);
      state.setFriends(['bob', 'carol']);
      expect(state.pinnedChatTargets, isEmpty);
      expect(state.unpinnedChatTargets.length, 2);
    });

    test('置顶好友进入 pinnedChatTargets，且不在 unpinned 中', () {
      state.setLoggedIn('alice', false);
      state.setFriends(['bob', 'carol']);
      state.setConversationPinned('bob', true);
      final pinned = state.pinnedChatTargets;
      expect(pinned.map((t) => t.key), ['bob']);
      expect(state.unpinnedChatTargets.map((t) => t.key), ['carol']);
    });

    test('多个置顶保持原顺序（稳定排序）', () {
      state.setLoggedIn('alice', false);
      state.setFriends(['bob', 'carol', 'dave']);
      state.addGroup(Group(id: 1, name: '开发组'));
      state.setConversationPinned('dave', true);
      state.setConversationPinned('bob', true);
      state.setConversationPinned('group_1', true);
      expect(state.pinnedChatTargets.map((t) => t.key),
          ['bob', 'dave', 'group_1']);
      expect(state.unpinnedChatTargets.map((t) => t.key), ['carol']);
    });

    test('取消置顶移出 pinnedChatTargets', () {
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.setConversationPinned('bob', true);
      state.setConversationPinned('bob', false);
      expect(state.pinnedChatTargets, isEmpty);
      expect(state.unpinnedChatTargets.map((t) => t.key), ['bob']);
    });

    test('系统会话可置顶（防御，K1 分区含系统会话）', () {
      state.setLoggedIn('alice', false);
      state.addMessage('服务器', _systemMsg('s1', '公告', sender: '[系统公告]'));
      state.setConversationPinned('服务器', true);
      expect(state.pinnedChatTargets.map((t) => t.key), ['服务器']);
      expect(state.unpinnedChatTargets, isEmpty);
    });

    test('置顶与未读计数互不影响', () {
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.setConversationPinned('bob', true);
      expect(state.totalUnread, 0);
      state.addMessage('carol', _chatMsg('m1', 'carol', 'hi'));
      expect(state.totalUnread, 1);
      expect(state.pinnedChatTargets.map((t) => t.key), ['bob']);
    });
  });

  group('K2 —— 逐会话草稿（跨会话泄漏回归锁定）', () {
    test('A 会话草稿不泄漏到 B 会话', () {
      state.setConversationDraft('bob', '给 bob 的半句');
      expect(state.draftOf('carol'), '');
      expect(state.draftOf('bob'), '给 bob 的半句');
    });

    test('多会话草稿并存', () {
      state.setConversationDraft('bob', 'b 草稿');
      state.setConversationDraft('carol', 'c 草稿');
      state.setConversationDraft('group_1', '群草稿');
      expect(state.draftOf('bob'), 'b 草稿');
      expect(state.draftOf('carol'), 'c 草稿');
      expect(state.draftOf('group_1'), '群草稿');
    });

    test('清空草稿后 draftOf 返回空串', () {
      state.setConversationDraft('bob', '先写点');
      state.setConversationDraft('bob', '');
      expect(state.draftOf('bob'), '');
    });

    test('切换当前会话不影响草稿', () {
      state.setLoggedIn('alice', false);
      state.setFriends(['bob', 'carol']);
      state.setConversationDraft('bob', 'b 草稿');
      state.selectChat('carol');
      state.selectChat('bob');
      expect(state.draftOf('bob'), 'b 草稿');
    });
  });

  group('K1-K3 —— setConversationMetaList（登录推送批量替换）', () {
    test('批量写入并覆盖旧元数据', () {
      state.setConversationPinned('bob', true);
      state.setConversationDraft('carol', '旧草稿');
      state.setConversationMetaList(const [
        ConversationMeta(peerKey: 'bob', pinned: false, muted: true),
      ]);
      expect(state.isPinned('bob'), isFalse);
      expect(state.isMuted('bob'), isTrue);
      expect(state.draftOf('carol'), '', reason: '未推送的会话元数据应被清空');
    });

    test('空列表清空全部元数据', () {
      state.setConversationPinned('bob', true);
      state.setConversationMetaList(const []);
      expect(state.isPinned('bob'), isFalse);
    });

    test('批量替换触发监听通知', () {
      var notified = 0;
      state.addListener(() => notified++);
      state.setConversationMetaList(const []);
      expect(notified, greaterThan(0));
    });
  });

  group('K5 —— 引用状态（P1-2）', () {
    test('setMessageQuote 设置引用', () {
      state.setLoggedIn('alice', false);
      state.addMessage('bob', _chatMsg('m1', 'bob', '回复'));
      state.setMessageQuote('m1', replyTo: 'orig', replyPreview: '原文');
      final msg = state.messageById('m1')!;
      expect(msg.replyTo, 'orig');
      expect(msg.replyPreview, '原文');
    });

    test('setMessageQuote 清除引用', () {
      state.setLoggedIn('alice', false);
      state.addMessage('bob', _chatMsg('m1', 'bob', '回复'));
      state.setMessageQuote('m1', replyTo: 'orig');
      state.setMessageQuote('m1');
      expect(state.messageById('m1')!.hasQuote, isFalse);
    });

    test('对不存在消息设置引用静默不崩溃', () {
      expect(
          () => state.setMessageQuote('ghost', replyTo: 'x'), returnsNormally);
    });
  });

  group('K5 —— 仅我删除（本地，微信式）', () {
    test('removeMessageLocally 移除消息并清空映射', () {
      state.setLoggedIn('alice', false);
      state.addMessage('bob', _chatMsg('m1', 'alice', '自己的消息'));
      state.addMessage('bob', _chatMsg('m2', 'bob', '对方消息'));
      state.removeMessageLocally('bob', 'm1');
      expect(state.getMessages('bob').map((m) => m.messageId), ['m2']);
      expect(state.messageById('m1'), isNull);
    });

    test('removeMessageLocally 对不存在消息静默不崩溃', () {
      state.setLoggedIn('alice', false);
      state.addMessage('bob', _chatMsg('m1', 'alice', 'x'));
      expect(
          () => state.removeMessageLocally('bob', 'ghost'), returnsNormally);
      expect(state.getMessages('bob').length, 1);
    });

    test('removeMessageLocally 对未知会话静默不崩溃', () {
      expect(
          () => state.removeMessageLocally('ghost', 'm1'), returnsNormally);
    });

    test('removeMessageLocally 触发监听通知', () {
      state.setLoggedIn('alice', false);
      state.addMessage('bob', _chatMsg('m1', 'alice', 'x'));
      var notified = 0;
      state.addListener(() => notified++);
      state.removeMessageLocally('bob', 'm1');
      expect(notified, greaterThan(0));
    });
  });

  group('K5 —— 表情回应状态（P1-4）', () {
    test('updateMessageReactions 整体替换', () {
      state.setLoggedIn('alice', false);
      state.addMessage('bob', _chatMsg('m1', 'bob', '内容'));
      state.updateMessageReactions('m1', const {
        '👍': ['alice', 'carol'],
      });
      expect(state.messageById('m1')!.reactions['👍'], ['alice', 'carol']);
      state.updateMessageReactions('m1', const {
        '😂': ['dave'],
      });
      expect(state.messageById('m1')!.reactions, {
        '😂': ['dave']
      });
    });

    test('toggleReaction 添加新反应', () {
      state.setLoggedIn('alice', false);
      state.addMessage('bob', _chatMsg('m1', 'bob', '内容'));
      state.toggleReaction('m1', '👍', 'alice');
      expect(state.messageById('m1')!.reactions['👍'], ['alice']);
    });

    test('toggleReaction 同用户同 emoji 再次触发移除', () {
      state.setLoggedIn('alice', false);
      state.addMessage('bob', _chatMsg('m1', 'bob', '内容'));
      state.toggleReaction('m1', '👍', 'alice');
      state.toggleReaction('m1', '👍', 'alice');
      expect(state.messageById('m1')!.reactions, isEmpty,
          reason: '移除后该 emoji 键应删除');
    });

    test('toggleReaction 多用户多表情', () {
      state.setLoggedIn('alice', false);
      state.addMessage('bob', _chatMsg('m1', 'bob', '内容'));
      state.toggleReaction('m1', '👍', 'alice');
      state.toggleReaction('m1', '👍', 'bob');
      state.toggleReaction('m1', '😂', 'alice');
      final reactions = state.messageById('m1')!.reactions;
      expect(reactions['👍'], ['alice', 'bob']);
      expect(reactions['😂'], ['alice']);
    });

    test('toggleReaction 同用户换 emoji 不误删他人反应', () {
      state.setLoggedIn('alice', false);
      state.addMessage('bob', _chatMsg('m1', 'bob', '内容'));
      state.toggleReaction('m1', '👍', 'alice');
      state.toggleReaction('m1', '👍', 'bob');
      state.toggleReaction('m1', '👍', 'alice');
      expect(state.messageById('m1')!.reactions['👍'], ['bob']);
    });

    test('反应状态按消息隔离', () {
      state.setLoggedIn('alice', false);
      state.addMessage('bob', _chatMsg('m1', 'bob', '一'));
      state.addMessage('bob', _chatMsg('m2', 'bob', '二'));
      state.toggleReaction('m1', '👍', 'alice');
      expect(state.messageById('m2')!.reactions, isEmpty);
    });

    test('对不存在消息 toggleReaction 静默不崩溃', () {
      expect(
          () => state.toggleReaction('ghost', '👍', 'alice'), returnsNormally);
    });
  });
}
