// ============================================================
// chat_models.dart 文件撤回显示回归 —— 用户实测缺陷回归锁定（TDD：修复前预期红）
// ============================================================
// 缺陷（2026-08-19 用户实测发现）：
//   文件撤回操作不完整——成功撤回文件后，消息体被整体替换为
//   "[消息已撤回]"，文件信息（[文件] xxx.pdf）随之消失。
// 契约（修复后须满足）：
//   - 撤回的**文件**消息：displayText = 原文消息体 + " [已撤回]" 标志
//     （消息体后附加，不替换消息体）
//   - 撤回的**文本/群聊/系统**消息：维持 "[消息已撤回]" 占位（回归不破坏）
//   - isRecalled 状态判定不回归
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:chatroom_flutter/models/chat_models.dart';

ChatMessage fileMsg(
  String sender,
  String id, {
  String content = '',
  String? filename,
  String status = 'sent',
}) {
  return ChatMessage(
    sender: sender,
    content: content.isEmpty ? '[文件] ${filename ?? 'a.pdf'}' : content,
    type: 'file',
    messageId: id,
    filename: filename ?? 'a.pdf',
    status: status,
  );
}

void main() {
  group('文件撤回 —— 消息体后附加"已撤回"标志（P-48 缺陷回归锁定）', () {
    test('撤回的文件消息：displayText 保留文件体并附加 [已撤回]', () {
      final m = fileMsg('alice', 'f1', filename: '报告.pdf', status: 'recalled');
      expect(m.isRecalled, isTrue);
      expect(m.displayText, 'alice: [文件] 报告.pdf [已撤回]',
          reason: '消息体后附加"已撤回"标志，不得替换消息体');
      expect(m.displayText, isNot(contains('[消息已撤回]')));
    });

    test('撤回的接收文件消息（[收到文件] 体）同样附加 [已撤回]', () {
      final m = ChatMessage(
        sender: 'bob',
        content: '[收到文件] b.pdf',
        type: 'file',
        messageId: 'f2',
        filename: 'b.pdf',
        status: 'recalled',
      );
      expect(m.displayText, 'bob: [收到文件] b.pdf [已撤回]');
      expect(m.displayText, isNot(contains('[消息已撤回]')));
    });

    test('撤回的文本消息维持 [消息已撤回] 占位（回归保护）', () {
      final m = ChatMessage(
        sender: 'alice',
        content: '原始文本',
        messageId: 'm1',
        status: 'recalled',
      );
      expect(m.displayText, 'alice: [消息已撤回]');
    });

    test('撤回的群聊消息维持 [消息已撤回] 占位（回归保护）', () {
      final m = ChatMessage(
        sender: 'bob',
        content: '群文本',
        type: 'group_chat',
        messageId: 'g1',
        status: 'recalled',
      );
      expect(m.displayText, 'bob: [消息已撤回]');
    });

    test('未撤回的文件消息不附加已撤回标志（回归保护）', () {
      final m = fileMsg('alice', 'f3', filename: '正常.pdf');
      expect(m.isRecalled, isFalse);
      expect(m.displayText, 'alice: [文件] 正常.pdf');
      expect(m.displayText, isNot(contains('已撤回')));
    });

    test('撤回状态切换仍为 status 驱动（displayText 实时反映）', () {
      final m = fileMsg('alice', 'f4', filename: '变化.pdf');
      expect(m.displayText, isNot(contains('已撤回')));
      m.status = 'recalled';
      expect(m.displayText, 'alice: [文件] 变化.pdf [已撤回]');
    });
  });
}
