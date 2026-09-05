// ============================================================
// chat_models.dart 阶段 I1 —— 消息发送队列状态（TDD 契约，待实现）
// ============================================================
// 覆盖 P0-1（《软件开发文档4.1.0.md》§13.2）新增的消息状态：
//   - status 新增 'sending'（发送中）/ 'failed'（发送失败）
//   - isSending / isFailed 判定
//   - header 显示发送中/失败标记（UI 气泡旁文本）
//   - displayText 对 sending/failed 保留原文（不替换内容）
//   - PendingMessage 队列条目（chatKey + message）
//
// 注意：'sent' / 'delivered' / 'recalled' 既有语义不回归（阶段 D/E 锁定）。
// ============================================================

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';

void main() {
  group('ChatMessage 发送状态（阶段 I1）', () {
    test('默认状态仍为 sent（既有行为不回归）', () {
      final m = ChatMessage(sender: 'alice', content: 'hi', messageId: 'm1');
      expect(m.status, 'sent');
      expect(m.isSending, isFalse);
      expect(m.isFailed, isFalse);
    });

    test('status=sending 时 isSending=true', () {
      final m = ChatMessage(
          sender: 'alice', content: 'hi', messageId: 'm1', status: 'sending');
      expect(m.isSending, isTrue);
      expect(m.isFailed, isFalse);
      expect(m.isRecalled, isFalse);
    });

    test('status=failed 时 isFailed=true', () {
      final m = ChatMessage(
          sender: 'alice', content: 'hi', messageId: 'm1', status: 'failed');
      expect(m.isFailed, isTrue);
      expect(m.isSending, isFalse);
      expect(m.isRecalled, isFalse);
    });

    test('发送中/失败不视为已撤回', () {
      for (final s in ['sending', 'failed']) {
        final m = ChatMessage(
            sender: 'alice', content: 'x', messageId: 'm1', status: s);
        expect(m.isRecalled, isFalse, reason: 'status=$s');
      }
    });

    test('displayText 保留原文（发送中/失败不替换内容）', () {
      final sending = ChatMessage(
          sender: 'alice', content: '在途消息', messageId: 'm1', status: 'sending');
      final failed = ChatMessage(
          sender: 'alice', content: '失败消息', messageId: 'm2', status: 'failed');
      expect(sending.displayText, contains('在途消息'));
      expect(failed.displayText, contains('失败消息'));
    });

    test('header 发送中显示（发送中）标记', () {
      final m = ChatMessage(
          sender: 'alice', content: 'x', messageId: 'm1', status: 'sending');
      expect(m.header, contains('发送中'));
    });

    test('header 发送失败显示（发送失败）标记', () {
      final m = ChatMessage(
          sender: 'alice', content: 'x', messageId: 'm1', status: 'failed');
      expect(m.header, contains('发送失败'));
    });

    test('header sent/delivered/recalled 无标记（既有行为不回归）', () {
      for (final s in ['sent', 'delivered', 'recalled']) {
        final m = ChatMessage(
            sender: 'alice', content: 'x', messageId: 'm1', status: s);
        expect(m.header.contains('发送中'), isFalse, reason: 'status=$s');
        expect(m.header.contains('发送失败'), isFalse, reason: 'status=$s');
      }
    });

    test('system 消息 header 恒为空（含 sending/failed 防御）', () {
      final m = ChatMessage(
          sender: '系统',
          content: 'x',
          messageId: 'm1',
          type: 'system',
          status: 'failed');
      expect(m.header, isEmpty);
    });

    test('状态流转 sending→sent→delivered→recalled（status 可变更）', () {
      final m = ChatMessage(
          sender: 'alice', content: 'x', messageId: 'm1', status: 'sending');
      expect(m.isSending, isTrue);
      m.status = 'sent';
      expect(m.isSending, isFalse);
      expect(m.isFailed, isFalse);
      m.status = 'delivered';
      m.status = 'recalled';
      expect(m.isRecalled, isTrue);
    });

    test('failed 后重试置回 sending（重试路径状态复位）', () {
      final m = ChatMessage(
          sender: 'alice', content: 'x', messageId: 'm1', status: 'failed');
      expect(m.isFailed, isTrue);
      m.status = 'sending';
      expect(m.isSending, isTrue);
      expect(m.isFailed, isFalse);
    });
  });

  group('PendingMessage 队列条目（阶段 I1）', () {
    test('持有会话 key 与消息本体', () {
      final msg = ChatMessage(
          sender: 'alice', content: 'hi', messageId: 'm1', status: 'sending');
      final entry = PendingMessage(chatKey: 'bob', message: msg);
      expect(entry.chatKey, 'bob');
      expect(entry.message.messageId, 'm1');
      expect(entry.message.content, 'hi');
    });

    test('群聊条目使用 group_N 会话 key', () {
      final msg = ChatMessage(
          sender: 'alice',
          content: 'hi',
          messageId: 'm2',
          status: 'sending',
          type: 'group_chat',
          groupId: 7);
      final entry = PendingMessage(chatKey: 'group_7', message: msg);
      expect(entry.chatKey, 'group_7');
      expect(entry.message.groupId, 7);
    });
  });
}
