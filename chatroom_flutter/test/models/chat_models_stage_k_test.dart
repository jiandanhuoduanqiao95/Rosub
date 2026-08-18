// ============================================================
// chat_models.dart 阶段 K —— 消息操作扩展（已实现，全部转绿）
// ============================================================
// 覆盖 P1-2 / P1-4（《软件开发文档4.1.0.md》§11 阶段 K / §13.3）：
//   - K5 P1-2 引用：replyTo / replyPreview 字段 + hasQuote（原文缩略）
//   - K5 P1-4 表情：reactions 映射（emoji → 用户列表）+ defaultReactionEmojis
//     （Telegram 风格彩色 emoji 表情盘）
//   - ConversationMeta.fromJson：服务端 list_conversations 推送解析（防御性）
//
// 用户决策修订：P1-1 消息编辑、P1-3 转发来源标注、P1-15 系统消息分类已移除。
// 既有字段语义不回归（sent/delivered/recalled/sending/failed）。
// ============================================================

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';

void main() {
  group('K5 —— 引用回复（P1-2）', () {
    test('replyTo / replyPreview 默认 null，hasQuote=false', () {
      final m = ChatMessage(sender: 'alice', content: 'x', messageId: 'm1');
      expect(m.replyTo, isNull);
      expect(m.replyPreview, isNull);
      expect(m.hasQuote, isFalse);
    });

    test('携带引用时 hasQuote=true', () {
      final m = ChatMessage(
        sender: 'bob',
        content: '回复内容',
        messageId: 'm1',
        replyTo: 'orig-1',
        replyPreview: '原文缩略',
      );
      expect(m.hasQuote, isTrue);
      expect(m.replyTo, 'orig-1');
      expect(m.replyPreview, '原文缩略');
    });

    test('仅 replyTo 无 preview 时 hasQuote 仍为 true（防御）', () {
      final m = ChatMessage(
          sender: 'bob', content: 'x', messageId: 'm1', replyTo: 'orig-1');
      expect(m.hasQuote, isTrue);
    });
  });

  group('K5 —— 表情回应（P1-4）', () {
    test('reactions 默认空映射', () {
      final m = ChatMessage(sender: 'alice', content: 'x', messageId: 'm1');
      expect(m.reactions, isEmpty);
    });

    test('reactions 持有 emoji → 用户列表', () {
      final m = ChatMessage(
        sender: 'alice',
        content: 'x',
        messageId: 'm1',
        reactions: const {
          '👍': ['bob', 'carol'],
          '😂': ['dave'],
        },
      );
      expect(m.reactions['👍'], ['bob', 'carol']);
      expect(m.reactions['😂'], ['dave']);
    });

    test('defaultReactionEmojis 为 Telegram 风格彩色表情盘（≥10 个）', () {
      expect(defaultReactionEmojis.length, greaterThanOrEqualTo(10));
      expect(defaultReactionEmojis, contains('👍'));
      expect(defaultReactionEmojis, contains('😂'));
      expect(defaultReactionEmojis, contains('❤️'));
      expect(defaultReactionEmojis, isNot(contains('收到')),
          reason: '纯文字令牌已移除（黑白渲染），全部为彩色 emoji');
    });
  });

  group('K5 —— 与既有状态共存（回归）', () {
    test('撤回优先：recalled 的 isRecalled 不受新字段影响', () {
      final m = ChatMessage(
        sender: 'alice',
        content: 'x',
        messageId: 'm1',
        status: 'recalled',
        replyTo: 'r1',
      );
      expect(m.isRecalled, isTrue);
      expect(m.displayText, contains('已撤回'));
    });

    test('发送状态（sending/failed）与引用字段互不影响', () {
      final m = ChatMessage(
        sender: 'alice',
        content: 'x',
        messageId: 'm1',
        status: 'sending',
        replyTo: 'r1',
      );
      expect(m.isSending, isTrue);
      expect(m.isFailed, isFalse);
      expect(m.hasQuote, isTrue);
    });
  });

  group('K —— ConversationMeta.fromJson（登录推送解析）', () {
    test('完整字段解析', () {
      final meta = ConversationMeta.fromJson(const {
        'peer_key': 'bob',
        'pinned': 1,
        'muted': 0,
        'draft': '草稿',
        'cleared_at': '2026-08-15 10:00:00',
      });
      expect(meta.peerKey, 'bob');
      expect(meta.pinned, isTrue);
      expect(meta.muted, isFalse);
      expect(meta.draft, '草稿');
      expect(meta.clearedAt, isNotNull);
    });

    test('缺失字段使用默认值（防御）', () {
      final meta = ConversationMeta.fromJson(const {'peer_key': 'bob'});
      expect(meta.peerKey, 'bob');
      expect(meta.pinned, isFalse);
      expect(meta.muted, isFalse);
      expect(meta.draft, '');
      expect(meta.clearedAt, isNull);
    });

    test('类型漂移防御：pinned/muted 为字符串或 null', () {
      final meta = ConversationMeta.fromJson(const {
        'peer_key': 'group_1',
        'pinned': 'true',
        'muted': null,
        'draft': 123,
      });
      expect(meta.peerKey, 'group_1');
      expect(meta.pinned, isTrue);
      expect(meta.muted, isFalse);
      expect(meta.draft, '123');
    });

    test('cleared_at 为空串/非法值 → null（防御）', () {
      for (final v in ['', 'not-a-date']) {
        final meta =
            ConversationMeta.fromJson({'peer_key': 'bob', 'cleared_at': v});
        expect(meta.clearedAt, isNull, reason: 'cleared_at=$v');
      }
    });

    test('空映射/畸形输入不抛异常', () {
      final meta = ConversationMeta.fromJson(const {});
      expect(meta.peerKey, '');
      expect(meta.pinned, isFalse);
      expect(meta.draft, '');
    });
  });
}
