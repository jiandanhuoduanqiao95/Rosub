// ============================================================
// chat_view.dart 文件撤回气泡回归 —— 用户实测缺陷回归锁定（TDD：修复前预期红）
// ============================================================
// 缺陷（2026-08-19 用户实测发现）：
//   文件撤回操作不完整——成功撤回文件后气泡被整体替换为
//   "[消息已撤回]"，文件信息消失。
// 契约（修复后须满足）：
//   - 撤回的文件消息气泡：显示原文消息体 + " [已撤回]" 标志
//     （附加在消息体后），不再替换为 "[消息已撤回]"
//   - 撤回的文本消息气泡：维持 "[消息已撤回]" 占位（回归不破坏）
//   - 已撤回消息（含文件）长按不弹消息菜单（既有规则回归）
//   - 发送方 / 接收方视角的文件撤回展示一致
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/widgets/chat_view.dart';

Widget wrap(Widget child) => MaterialApp(
    home: Scaffold(body: SizedBox(width: 600, height: 800, child: child)));

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

ChatMessage textMsg(String sender, String content, String id,
    {String status = 'sent'}) {
  return ChatMessage(
    sender: sender,
    content: content,
    messageId: id,
    status: status,
  );
}

ChatView view(List<ChatMessage> messages) {
  return ChatView(
    chatKey: 'bob',
    chatTitle: 'bob',
    messages: messages,
    username: 'alice',
    inputCtrl: TextEditingController(),
    onSend: () {},
    onSendFile: () {},
    onRecall: (_) {},
    onLoadHistory: (_) async {},
    hasMoreHistory: (_) => false,
  );
}

void main() {
  group('文件撤回气泡 —— 消息体后附加"已撤回"标志（P-48 缺陷回归锁定）', () {
    testWidgets('自己撤回的文件消息：显示文件体 + [已撤回]，不再替换为 [消息已撤回]',
        (tester) async {
      await tester.pumpWidget(wrap(view([
        fileMsg('alice', 'f1', filename: '报告.pdf', status: 'recalled'),
      ])));
      expect(find.text('[文件] 报告.pdf [已撤回]'), findsOneWidget,
          reason: '消息体后附加"已撤回"标志');
      expect(find.textContaining('[消息已撤回]'), findsNothing,
          reason: '文件消息不得替换为 [消息已撤回]');
      expect(find.textContaining('报告.pdf'), findsOneWidget,
          reason: '文件信息必须保留');
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('对方撤回的文件消息（接收侧）：同样显示文件体 + [已撤回]', (tester) async {
      await tester.pumpWidget(wrap(view([
        fileMsg('bob', 'f2',
            content: '[收到文件] 资料.zip',
            filename: '资料.zip',
            status: 'recalled'),
      ])));
      expect(find.text('[收到文件] 资料.zip [已撤回]'), findsOneWidget);
      expect(find.textContaining('[消息已撤回]'), findsNothing);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('撤回的文本消息维持 [消息已撤回] 占位（回归保护）', (tester) async {
      await tester.pumpWidget(wrap(view([
        textMsg('alice', '原始文本', 'm1', status: 'recalled'),
      ])));
      expect(find.textContaining('[消息已撤回]'), findsOneWidget);
      expect(find.text('原始文本'), findsNothing);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('撤回的群聊消息维持 [消息已撤回] 占位（回归保护）', (tester) async {
      await tester.pumpWidget(wrap(view([
        ChatMessage(
          sender: 'bob',
          content: '群文本',
          type: 'group_chat',
          messageId: 'g1',
          status: 'recalled',
        ),
      ])));
      expect(find.textContaining('[消息已撤回]'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('未撤回的文件消息不显示已撤回标志（回归保护）', (tester) async {
      await tester.pumpWidget(wrap(view([
        fileMsg('alice', 'f3', filename: '正常.pdf'),
      ])));
      expect(find.text('[文件] 正常.pdf'), findsOneWidget);
      expect(find.textContaining('已撤回'), findsNothing);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('已撤回的文件消息长按不弹菜单（系统/已撤回消息不弹菜单回归）',
        (tester) async {
      await tester.pumpWidget(wrap(view([
        fileMsg('alice', 'f4', filename: '报告.pdf', status: 'recalled'),
      ])));
      await tester.longPress(find.text('[文件] 报告.pdf [已撤回]'));
      await tester.pumpAndSettle();
      expect(find.text('撤回'), findsNothing, reason: '已撤回消息不弹菜单');
      expect(find.text('引用回复'), findsNothing);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('撤回的文件消息不显示表情回应 chips（回归保护）', (tester) async {
      await tester.pumpWidget(wrap(view([
        ChatMessage(
          sender: 'alice',
          content: '[文件] a.pdf',
          type: 'file',
          messageId: 'f5',
          filename: 'a.pdf',
          status: 'recalled',
          reactions: const {'👍': ['bob']},
        ),
      ])));
      expect(find.text('[文件] a.pdf [已撤回]'), findsOneWidget);
      expect(find.textContaining('👍'), findsNothing,
          reason: '已撤回消息不渲染表情回应');
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
