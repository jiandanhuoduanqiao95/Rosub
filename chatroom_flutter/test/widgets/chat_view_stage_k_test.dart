// ============================================================
// chat_view.dart 阶段 K —— 草稿回调 / 消息操作 UI（已实现，全部转绿）
// ============================================================
// 覆盖 P1-12 / P1-2 / P1-3 / P1-4（《软件开发文档4.1.0.md》§11 阶段 K / §13.3）：
//   - K2 输入监听：onInputChanged 回调（逐会话草稿的数据源）
//   - K5 引用回复：原文缩略块 + 点击跳转（onJumpToMessage）
//   - K5 表情回应：emoji 计数 chips + 点击触发 onAddReaction
//   - K5 消息菜单：长按（提供 K5 回调时）→ 引用回复/转发/表情回应/撤回/仅我删除
//     ＊未提供 K5 回调时保持既有行为：长按直接触发 onRecall（回归）
//
// 用户决策修订：P1-1 编辑、P1-3 转发来源标注、P1-15 通知中心已移除。
// ChatView 接受纯参数，便于直接 pump 验证。
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/widgets/chat_view.dart';
import 'package:chatroom_flutter/widgets/raw_text_field.dart';

Widget wrap(Widget child) => MaterialApp(
    home: Scaffold(body: SizedBox(width: 600, height: 800, child: child)));

ChatMessage msg(
  String sender,
  String content,
  String id, {
  String status = 'sent',
  String type = 'chat',
  String? replyTo,
  String? replyPreview,
  Map<String, List<String>> reactions = const {},
}) =>
    ChatMessage(
      sender: sender,
      content: content,
      messageId: id,
      status: status,
      type: type,
      replyTo: replyTo,
      replyPreview: replyPreview,
      reactions: reactions,
    );

ChatView view(
  List<ChatMessage> messages, {
  String username = 'alice',
  String chatKey = 'bob',
  ValueChanged<String>? onInputChanged,
  ValueChanged<String>? onReplyMessage,
  ValueChanged<String>? onForwardMessage,
  void Function(String messageId, String emoji)? onAddReaction,
  ValueChanged<String>? onDeleteMessage,
  ValueChanged<String>? onJumpToMessage,
  ValueChanged<String>? onRecall,
  Future<void> Function(String? beforeMessageId)? onLoadHistory,
  bool Function(String key)? hasMoreHistory,
  ValueChanged<ChatMessage>? onForwardFile,
}) {
  return ChatView(
    chatKey: chatKey,
    chatTitle: chatKey,
    messages: messages,
    username: username,
    inputCtrl: TextEditingController(),
    canSend: chatKey != '服务器',
    onSend: () {},
    onSendFile: () {},
    onRecall: onRecall ?? (_) {},
    onLoadHistory: onLoadHistory ?? (_) async {},
    hasMoreHistory: hasMoreHistory ?? (_) => false,
    onInputChanged: onInputChanged,
    onReplyMessage: onReplyMessage,
    onForwardMessage: onForwardMessage,
    onAddReaction: onAddReaction,
    onDeleteMessage: onDeleteMessage,
    onJumpToMessage: onJumpToMessage,
    onForwardFile: onForwardFile,
  );
}

Future<void> typeChars(WidgetTester tester, String text) async {
  await tester.tap(find.byType(RawTextField));
  await tester.pump();
  for (final ch in text.split('')) {
    final key = const {
      'a': LogicalKeyboardKey.keyA,
      'b': LogicalKeyboardKey.keyB,
      'c': LogicalKeyboardKey.keyC,
      'd': LogicalKeyboardKey.keyD,
      'e': LogicalKeyboardKey.keyE,
      'f': LogicalKeyboardKey.keyF,
      'g': LogicalKeyboardKey.keyG,
      'h': LogicalKeyboardKey.keyH,
      'i': LogicalKeyboardKey.keyI,
      'j': LogicalKeyboardKey.keyJ,
      'k': LogicalKeyboardKey.keyK,
      'l': LogicalKeyboardKey.keyL,
      'm': LogicalKeyboardKey.keyM,
      'n': LogicalKeyboardKey.keyN,
      'o': LogicalKeyboardKey.keyO,
      'p': LogicalKeyboardKey.keyP,
      'q': LogicalKeyboardKey.keyQ,
      'r': LogicalKeyboardKey.keyR,
      's': LogicalKeyboardKey.keyS,
      't': LogicalKeyboardKey.keyT,
      'u': LogicalKeyboardKey.keyU,
      'v': LogicalKeyboardKey.keyV,
      'w': LogicalKeyboardKey.keyW,
      'x': LogicalKeyboardKey.keyX,
      'y': LogicalKeyboardKey.keyY,
      'z': LogicalKeyboardKey.keyZ,
    }[ch.toLowerCase()]!;
    await tester.sendKeyEvent(key);
    await tester.pump();
  }
}

void main() {
  group('K2 —— 输入监听（逐会话草稿数据源）', () {
    testWidgets('输入文字触发 onInputChanged 并携带当前文本', (tester) async {
      final changes = <String>[];
      await tester.pumpWidget(wrap(view(
        [msg('bob', '旧消息', 'm1')],
        onInputChanged: changes.add,
      )));
      await typeChars(tester, 'hi');
      expect(changes, isNotEmpty);
      expect(changes.last, 'hi');
      await tester.pump(const Duration(seconds: 3)); // 冲刷 RawTextField 光标 Timer
    });

    testWidgets('未提供 onInputChanged 时输入不崩溃（回归）', (tester) async {
      await tester.pumpWidget(wrap(view([msg('bob', '旧消息', 'm1')])));
      await typeChars(tester, 'ok');
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 3)); // 冲刷 RawTextField 光标 Timer
    });
  });

  group('K5 —— 引用回复（P1-2）', () {
    testWidgets('引用消息显示原文缩略块', (tester) async {
      await tester.pumpWidget(wrap(view([
        msg('bob', '回复内容', 'm2', replyTo: 'm1', replyPreview: '原文缩略'),
      ])));
      expect(find.text('原文缩略'), findsOneWidget);
      expect(find.text('回复内容'), findsOneWidget);
    });

    testWidgets('点击引用块触发 onJumpToMessage(replyTo)', (tester) async {
      final jumped = <String>[];
      await tester.pumpWidget(wrap(view(
        [
          msg('bob', '回复内容', 'm2', replyTo: 'orig-1', replyPreview: '缩略'),
        ],
        onJumpToMessage: jumped.add,
      )));
      await tester.tap(find.text('缩略'));
      expect(jumped, ['orig-1']);
    });

    testWidgets('点击引用块滚动定位到被引用原消息并高亮（P-30 修复）', (tester) async {
      final messages = <ChatMessage>[
        for (var i = 0; i < 30; i++) msg('bob', '消息$i', 'm$i'),
      ];
      messages.add(
          msg('alice', '回复', 'reply-1', replyTo: 'm3', replyPreview: '消息3'));
      await tester.pumpWidget(wrap(view(messages)));
      // 点击引用缩略块（m3 的正文与缩略块文本相同，取第一个）
      await tester.tap(find.text('消息3').first);
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate((w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).color ==
                Colors.amber.withValues(alpha: 0.25)),
        findsOneWidget,
        reason: '跳转后目标消息高亮闪烁（P-30）',
      );
      await tester.pump(const Duration(seconds: 3)); // 冲刷高亮 Timer
    });

    testWidgets('引用目标未加载时翻页加载历史直至找到并跳转（P-30 长会话修复）', (tester) async {
      final messages = <ChatMessage>[
        for (var i = 0; i < 5; i++) msg('bob', '消息$i', 'm$i'),
      ];
      messages.add(
          msg('alice', '回复', 'reply-1', replyTo: 'm-old', replyPreview: '旧消息'));
      final loads = <String>[];
      var hasMore = true;
      await tester.pumpWidget(wrap(view(
        messages,
        onLoadHistory: (beforeId) async {
          loads.add(beforeId ?? '');
          hasMore = false;
          // 模拟历史分页返回：注入被引用的更早消息
          messages.insert(0, msg('bob', '旧消息', 'm-old'));
        },
        hasMoreHistory: (_) => hasMore,
      )));
      await tester.tap(find.text('旧消息'));
      await tester.pumpAndSettle();
      expect(loads, isNotEmpty, reason: '目标未加载时应先翻页加载历史');
      expect(loads.first, 'm0', reason: '以最旧消息为分页游标');
      expect(
        find.byWidgetPredicate((w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).color ==
                Colors.amber.withValues(alpha: 0.25)),
        findsOneWidget,
        reason: '加载到目标后跳转并高亮',
      );
      await tester.pump(const Duration(seconds: 3)); // 冲刷高亮 Timer
    });

    testWidgets('无引用消息不渲染引用块（回归）', (tester) async {
      await tester.pumpWidget(wrap(view([msg('bob', '普通消息', 'm1')])));
      expect(find.textContaining('回复内容'), findsNothing);
    });
  });

  group('K5 —— 表情回应（P1-4）', () {
    testWidgets('消息显示 emoji 计数 chips', (tester) async {
      await tester.pumpWidget(wrap(view([
        msg('bob', '收到', 'm1', reactions: const {
          '👍': ['alice', 'carol'],
          '😂': ['dave'],
        }),
      ])));
      expect(find.text('👍 2'), findsOneWidget);
      expect(find.text('😂 1'), findsOneWidget);
    });

    testWidgets('点击 emoji chip 触发 onAddReaction(messageId, emoji)',
        (tester) async {
      final reacted = <(String, String)>[];
      await tester.pumpWidget(wrap(view(
        [
          msg('bob', '收到', 'm1', reactions: const {
            '👍': ['alice'],
          }),
        ],
        onAddReaction: (id, emoji) => reacted.add((id, emoji)),
      )));
      await tester.tap(find.text('👍 1'));
      expect(reacted, [('m1', '👍')]);
    });

    testWidgets('无反应消息不渲染 chips', (tester) async {
      await tester.pumpWidget(wrap(view([msg('bob', '收到', 'm1')])));
      expect(find.textContaining('👍'), findsNothing);
    });
  });

  group('K5 —— 消息菜单（长按 → 引用回复/转发/表情回应/撤回/仅我删除）', () {
    testWidgets('提供 K5 回调时，长按自己的消息弹出菜单', (tester) async {
      await tester.pumpWidget(wrap(view(
        [msg('alice', '自己的消息', 'm1')],
        onReplyMessage: (_) {},
        onForwardMessage: (_) {},
        onAddReaction: (_, __) {},
        onDeleteMessage: (_) {},
      )));
      await tester.longPress(find.text('自己的消息'));
      await tester.pumpAndSettle();
      expect(find.text('引用回复'), findsOneWidget);
      expect(find.text('转发'), findsOneWidget);
      expect(find.text('表情回应'), findsOneWidget);
      expect(find.text('撤回'), findsOneWidget);
      expect(find.text('仅我删除'), findsOneWidget);
      expect(find.text('编辑'), findsNothing, reason: 'P1-1 编辑已移除');
    });

    testWidgets('菜单"引用回复"触发 onReplyMessage(messageId)', (tester) async {
      final replies = <String>[];
      await tester.pumpWidget(wrap(view(
        [msg('alice', '自己的消息', 'm-reply-1')],
        onReplyMessage: replies.add,
        onForwardMessage: (_) {},
        onAddReaction: (_, __) {},
        onDeleteMessage: (_) {},
      )));
      await tester.longPress(find.text('自己的消息'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('引用回复'));
      await tester.pumpAndSettle();
      expect(replies, ['m-reply-1']);
    });

    testWidgets('菜单"转发"触发 onForwardMessage(messageId)', (tester) async {
      final forwards = <String>[];
      await tester.pumpWidget(wrap(view(
        [msg('alice', '自己的消息', 'm-fwd-1')],
        onReplyMessage: (_) {},
        onForwardMessage: forwards.add,
        onAddReaction: (_, __) {},
        onDeleteMessage: (_) {},
      )));
      await tester.longPress(find.text('自己的消息'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('转发'));
      await tester.pumpAndSettle();
      expect(forwards, ['m-fwd-1']);
    });

    testWidgets('菜单"表情回应"展开表情盘 → 点击触发 onAddReaction', (tester) async {
      final reacted = <(String, String)>[];
      await tester.pumpWidget(wrap(view(
        [msg('alice', '自己的消息', 'm-react-1')],
        onReplyMessage: (_) {},
        onForwardMessage: (_) {},
        onAddReaction: (id, emoji) => reacted.add((id, emoji)),
        onDeleteMessage: (_) {},
      )));
      await tester.longPress(find.text('自己的消息'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('表情回应'));
      await tester.pumpAndSettle();
      expect(find.text('👍'), findsWidgets, reason: '表情盘含默认表情');
      await tester.tap(find.text('👍').last);
      await tester.pumpAndSettle();
      expect(reacted, [('m-react-1', '👍')]);
    });

    testWidgets('菜单"撤回"仍触发 onRecall', (tester) async {
      final recalled = <String>[];
      await tester.pumpWidget(wrap(view(
        [msg('alice', '自己的消息', 'm-rec-1')],
        onReplyMessage: (_) {},
        onForwardMessage: (_) {},
        onAddReaction: (_, __) {},
        onDeleteMessage: (_) {},
        onRecall: recalled.add,
      )));
      await tester.longPress(find.text('自己的消息'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('撤回'));
      await tester.pumpAndSettle();
      expect(recalled, ['m-rec-1']);
    });

    testWidgets('菜单"仅我删除"触发 onDeleteMessage(messageId)', (tester) async {
      final deleted = <String>[];
      await tester.pumpWidget(wrap(view(
        [msg('alice', '自己的消息', 'm-del-1')],
        onReplyMessage: (_) {},
        onForwardMessage: (_) {},
        onAddReaction: (_, __) {},
        onDeleteMessage: deleted.add,
      )));
      await tester.longPress(find.text('自己的消息'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('仅我删除'));
      await tester.pumpAndSettle();
      expect(deleted, ['m-del-1']);
    });

    testWidgets('对方消息菜单无"撤回/仅我删除"入口', (tester) async {
      await tester.pumpWidget(wrap(view(
        [msg('bob', '对方的消息', 'm1')],
        onReplyMessage: (_) {},
        onForwardMessage: (_) {},
        onAddReaction: (_, __) {},
        onDeleteMessage: (_) {},
      )));
      await tester.longPress(find.text('对方的消息'));
      await tester.pumpAndSettle();
      expect(find.text('撤回'), findsNothing);
      expect(find.text('仅我删除'), findsNothing);
      expect(find.text('引用回复'), findsOneWidget);
      expect(find.text('转发'), findsOneWidget);
    });

    testWidgets('未提供 K5 回调时保持既有行为：长按直接 onRecall（回归）', (tester) async {
      final recalled = <String>[];
      await tester.pumpWidget(wrap(view(
        [msg('alice', '可撤回', 'm1')],
        onRecall: recalled.add,
      )));
      await tester.longPress(find.text('可撤回'));
      await tester.pumpAndSettle();
      expect(recalled, ['m1']);
      expect(find.text('引用回复'), findsNothing);
    });

    testWidgets('文件消息长按弹菜单：仅"撤回"入口（P-33 修订：新交互）', (tester) async {
      final recalled = <String>[];
      await tester.pumpWidget(wrap(view(
        [
          ChatMessage(
            sender: 'alice',
            content: '[发送文件] a.pdf',
            messageId: 'f1',
            type: 'file',
            filename: 'a.pdf',
          ),
        ],
        onReplyMessage: (_) {},
        onForwardMessage: (_) {},
        onAddReaction: (_, __) {},
        onDeleteMessage: (_) {},
        onRecall: recalled.add,
      )));
      await tester.longPress(find.text('[发送文件] a.pdf'));
      await tester.pumpAndSettle();
      // 新交互：文件消息也弹菜单，但仅提供"撤回"入口
      expect(find.text('撤回'), findsOneWidget);
      expect(find.text('引用回复'), findsNothing);
      expect(find.text('转发'), findsNothing);
      expect(find.text('表情回应'), findsNothing);
      expect(find.text('仅我删除'), findsNothing);
      await tester.tap(find.text('撤回'));
      await tester.pumpAndSettle();
      expect(recalled, ['f1']);
    });

    testWidgets('对方文件消息长按弹菜单但无"撤回"（仅自己的文件可撤回）', (tester) async {
      await tester.pumpWidget(wrap(view(
        [
          ChatMessage(
            sender: 'bob',
            content: '[收到文件] b.pdf',
            messageId: 'f2',
            type: 'file',
            filename: 'b.pdf',
          ),
        ],
        onReplyMessage: (_) {},
        onForwardMessage: (_) {},
        onAddReaction: (_, __) {},
        onDeleteMessage: (_) {},
        onRecall: (_) {},
      )));
      await tester.longPress(find.text('[收到文件] b.pdf'));
      await tester.pumpAndSettle();
      expect(find.text('撤回'), findsNothing, reason: '对方文件不可撤回');
      expect(find.text('引用回复'), findsNothing);
    });

    testWidgets('Q1 三轮问题8：提供 onForwardFile 时文件菜单出现"转发"，点击回调携带消息',
        (tester) async {
      final forwarded = <ChatMessage>[];
      await tester.pumpWidget(wrap(view(
        [
          ChatMessage(
            sender: 'bob',
            content: '[收到文件] b.pdf',
            messageId: 'f3',
            type: 'file',
            filename: 'b.pdf',
          ),
        ],
        onRecall: (_) {},
        onForwardFile: forwarded.add,
      )));
      await tester.longPress(find.text('[收到文件] b.pdf'));
      await tester.pumpAndSettle();

      expect(find.text('转发'), findsOneWidget,
          reason: '文件转发入口（本地重发通道，服务端 forward 协议不适用）');
      expect(find.text('引用回复'), findsNothing, reason: '文件不支持引用（语义不变）');

      await tester.tap(find.text('转发'));
      await tester.pumpAndSettle();
      expect(forwarded.single.messageId, 'f3');
    });
  });
}
