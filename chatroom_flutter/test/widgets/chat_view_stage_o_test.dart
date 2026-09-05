// ============================================================
// chat_view.dart 阶段 O —— 群组与消息增强渲染契约（TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 O 的聊天视图侧：
//
//   O1 群公告（展示）：
//     - ChatView 新增可选参数 announcement（String?）：非空时消息区顶部
//       显示 📢 公告横幅（数据源 ChatScreen 从 Group.announcement 传入）
//     - type='group_announcement' 的消息以居中胶囊样式渲染（含 📢 前缀）
//   O2 群置顶（展示 + 入口）：
//     - 新增可选参数 pinnedPreview（String?）：非空时顶部显示 📌 置顶横幅
//     - 新增可选回调 onPinMessage（ValueChanged<String>?）：提供即群消息
//       长按菜单新增"置顶"入口（私聊消息不出现；ChatScreen 仅对
//       "群主 + 群会话"传入），点击回调 messageId
//   O4 快捷回复（入口）：
//     - 新增可选回调 onQuickReply（VoidCallback?）：提供即输入行显示
//       tooltip '快捷回复' 入口，点击回调
//   O5 定时消息（入口）：
//     - 新增可选回调 onScheduleMessage（VoidCallback?）：提供即输入行
//       显示 tooltip '定时发送' 入口，点击回调
//
// 实现前：本文件引用尚未实现的参数/行为，编译失败或用例红，属 TDD 红。
// 实现后：全部转绿。
// ============================================================

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/widgets/chat_view.dart';

Widget wrap(Widget child) => MaterialApp(
    home: Scaffold(body: SizedBox(width: 600, height: 800, child: child)));

ChatMessage msg(
  String sender,
  String content,
  String id, {
  String status = 'sent',
  String type = 'chat',
}) =>
    ChatMessage(
      sender: sender,
      content: content,
      messageId: id,
      status: status,
      type: type,
    );

ChatView view(
  List<ChatMessage> messages, {
  String username = 'alice',
  String? announcement,
  List<String>? announcements,
  List<GroupAnnouncement>? announcementItems,
  ValueChanged<String>? onDeleteAnnouncement,
  String? pinnedPreview,
  List<GroupPinnedItem>? pinnedItems,
  ValueChanged<String>? onUnpinMessage,
  String? pinnedMessageId,
  ValueChanged<String>? onPinMessage,
  VoidCallback? onQuickReply,
  VoidCallback? onScheduleMessage,
  VoidCallback? onShareCard,
}) {
  return ChatView(
    chatKey: 'group_1',
    chatTitle: '开发组',
    messages: messages,
    username: username,
    inputCtrl: TextEditingController(),
    canSend: true,
    onSend: () {},
    onSendFile: () {},
    onRecall: (_) {},
    onLoadHistory: (_) async {},
    hasMoreHistory: (_) => false,
    onReplyMessage: (_) {},
    onForwardMessage: (_) {},
    onAddReaction: (_, __) {},
    onDeleteMessage: (_) {},
    onDeletePermanently: (_) {},
    onJumpToMessage: (_) {},
    announcement: announcement,
    announcements: announcements,
    announcementItems: announcementItems,
    onDeleteAnnouncement: onDeleteAnnouncement,
    pinnedPreview: pinnedPreview,
    pinnedItems: pinnedItems,
    onUnpinMessage: onUnpinMessage,
    pinnedMessageId: pinnedMessageId,
    onPinMessage: onPinMessage,
    onQuickReply: onQuickReply,
    onScheduleMessage: onScheduleMessage,
    onShareCard: onShareCard,
  );
}

void main() {
  group('O1 —— 群公告展示', () {
    testWidgets('announcement 非空 → 顶部显示 📢 公告横幅', (tester) async {
      await tester.pumpWidget(wrap(view(
        [msg('bob', '早上好', 'm1', type: 'group_chat')],
        announcement: '周五 18:00 团建',
      )));
      expect(find.textContaining('📢'), findsOneWidget, reason: '公告横幅带 📢 标识');
      expect(find.textContaining('周五 18:00 团建'), findsOneWidget);
    });

    testWidgets('announcement 为空 → 不显示公告横幅', (tester) async {
      await tester.pumpWidget(wrap(view([msg('bob', '早上好', 'm1')])));
      expect(find.textContaining('📢'), findsNothing);
    });

    testWidgets('group_announcement 消息渲染为居中胶囊（📢 + 文本）', (tester) async {
      await tester.pumpWidget(wrap(view([
        msg('alice', '国庆假期通知', 'ann-1', type: 'group_announcement'),
      ])));
      expect(find.textContaining('📢'), findsOneWidget);
      expect(find.textContaining('国庆假期通知'), findsOneWidget);
    });
  });

  group('O2 —— 群置顶展示与入口', () {
    testWidgets('pinnedPreview 非空 → 顶部显示 📌 置顶横幅', (tester) async {
      await tester.pumpWidget(wrap(view(
        [msg('bob', '普通消息', 'm1', type: 'group_chat')],
        pinnedPreview: '重要通知',
      )));
      expect(find.textContaining('📌'), findsOneWidget, reason: '置顶横幅带 📌 标识');
      expect(find.textContaining('重要通知'), findsOneWidget);
    });

    testWidgets('pinnedPreview 为空 → 不显示置顶横幅', (tester) async {
      await tester.pumpWidget(wrap(view([msg('bob', '普通消息', 'm1')])));
      expect(find.textContaining('📌'), findsNothing);
    });

    testWidgets('提供 onPinMessage → 群消息菜单出现"置顶"入口', (tester) async {
      await tester.pumpWidget(wrap(view(
        [msg('bob', '值得置顶', 'pin-1', type: 'group_chat')],
        onPinMessage: (_) {},
      )));
      await tester.longPress(find.text('值得置顶'));
      await tester.pumpAndSettle();
      expect(find.text('置顶'), findsOneWidget);
    });

    testWidgets('点击"置顶" → onPinMessage 收到 messageId', (tester) async {
      String? pinnedId;
      await tester.pumpWidget(wrap(view(
        [msg('bob', '值得置顶', 'pin-2', type: 'group_chat')],
        onPinMessage: (id) => pinnedId = id,
      )));
      await tester.longPress(find.text('值得置顶'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('置顶'));
      await tester.pumpAndSettle();
      expect(pinnedId, 'pin-2');
    });

    testWidgets('未提供 onPinMessage → 菜单无"置顶"入口（回归）', (tester) async {
      await tester.pumpWidget(
          wrap(view([msg('bob', '普通群消息', 'm2', type: 'group_chat')])));
      await tester.longPress(find.text('普通群消息'));
      await tester.pumpAndSettle();
      expect(find.text('置顶'), findsNothing);
    });

    testWidgets('已置顶消息菜单显示"取消置顶"（用户反馈 #3）', (tester) async {
      await tester.pumpWidget(wrap(view(
        [msg('bob', '已置顶的消息', 'pin-3', type: 'group_chat')],
        pinnedMessageId: 'pin-3',
        onPinMessage: (_) {},
      )));
      await tester.longPress(find.text('已置顶的消息'));
      await tester.pumpAndSettle();
      expect(find.text('取消置顶'), findsOneWidget);
      expect(find.text('置顶'), findsNothing);
    });

    testWidgets('未置顶消息仍显示"置顶"（pinnedMessageId 不匹配）', (tester) async {
      await tester.pumpWidget(wrap(view(
        [msg('bob', '未置顶的消息', 'pin-4', type: 'group_chat')],
        pinnedMessageId: 'other-id',
        onPinMessage: (_) {},
      )));
      await tester.longPress(find.text('未置顶的消息'));
      await tester.pumpAndSettle();
      expect(find.text('置顶'), findsOneWidget);
      expect(find.text('取消置顶'), findsNothing);
    });

    testWidgets('私聊消息菜单不出现"置顶"入口（群置顶为新语义，不混入私聊）', (tester) async {
      await tester.pumpWidget(wrap(view(
        [msg('bob', '私聊消息', 'm3')],
        onPinMessage: (_) {},
      )));
      await tester.longPress(find.text('私聊消息'));
      await tester.pumpAndSettle();
      expect(find.text('置顶'), findsNothing);
    });
  });

  group('O2 修订（2026-08-31 多公告/多置顶并存）', () {
    testWidgets('announcements 多条 → 横幅逐条显示', (tester) async {
      await tester.pumpWidget(wrap(view(
        [msg('bob', 'hi', 'm9')],
        announcements: ['公告一', '公告二'],
      )));
      expect(find.textContaining('📢 公告一'), findsOneWidget);
      expect(find.textContaining('📢 公告二'), findsOneWidget);
    });

    testWidgets(
        'announcementItems + onDeleteAnnouncement → 公告横幅带 ✕ 删除按钮（R-O12）',
        (tester) async {
      String? deletedId;
      await tester.pumpWidget(wrap(view(
        [msg('bob', 'hi', 'm12')],
        announcementItems: const [
          GroupAnnouncement(messageId: 'a-9', content: '待删公告'),
        ],
        onDeleteAnnouncement: (id) => deletedId = id,
      )));
      expect(find.textContaining('📢 待删公告'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('announcement_delete_a-9')));
      await tester.pumpAndSettle();
      expect(deletedId, 'a-9');
    });

    testWidgets('未提供 onDeleteAnnouncement（非群主）→ 无删除按钮（R-O12）', (tester) async {
      await tester.pumpWidget(wrap(view(
        [msg('bob', 'hi', 'm13')],
        announcementItems: const [
          GroupAnnouncement(messageId: 'a-8', content: '普通公告'),
        ],
      )));
      expect(find.textContaining('📢 普通公告'), findsOneWidget);
      expect(find.byTooltip('删除公告'), findsNothing);
    });

    testWidgets('pinnedItems 多条 → 置顶横幅逐条显示', (tester) async {
      await tester.pumpWidget(wrap(view(
        [msg('bob', 'hi', 'm10')],
        pinnedItems: const [
          GroupPinnedItem(messageId: 'p1', preview: '置顶一'),
          GroupPinnedItem(messageId: 'p2', preview: '置顶二'),
        ],
      )));
      expect(find.textContaining('📌 置顶一'), findsOneWidget);
      expect(find.textContaining('📌 置顶二'), findsOneWidget);
    });

    testWidgets('点击置顶条目 → 定位原消息（不崩溃，走引用跳转链路）', (tester) async {
      await tester.pumpWidget(wrap(view(
        [msg('bob', '被置顶的消息', 'pin-jump', type: 'group_chat')],
        pinnedItems: const [
          GroupPinnedItem(messageId: 'pin-jump', preview: '被置顶的消息'),
        ],
      )));
      await tester.tap(find.textContaining('📌 被置顶的消息'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('被置顶的消息'), findsOneWidget);
    });

    testWidgets('置顶条目取消按钮 → onUnpinMessage 回调该条 id', (tester) async {
      String? unpinId;
      await tester.pumpWidget(wrap(view(
        [msg('bob', 'hi', 'm11')],
        pinnedItems: const [
          GroupPinnedItem(messageId: 'p9', preview: '待取消'),
        ],
        onUnpinMessage: (id) => unpinId = id,
      )));
      await tester.tap(find.byTooltip('取消置顶'));
      await tester.pumpAndSettle();
      expect(unpinId, 'p9');
    });
  });

  group('O4 —— 快捷回复入口', () {
    testWidgets('提供 onQuickReply → 输入行显示"快捷回复"入口', (tester) async {
      var tapped = false;
      await tester.pumpWidget(wrap(view(
        [msg('bob', 'hi', 'm4')],
        onQuickReply: () => tapped = true,
      )));
      expect(find.byTooltip('快捷回复'), findsOneWidget);
      await tester.tap(find.byTooltip('快捷回复'));
      expect(tapped, isTrue);
    });

    testWidgets('未提供 onQuickReply → 不显示入口（回归）', (tester) async {
      await tester.pumpWidget(wrap(view([msg('bob', 'hi', 'm5')])));
      expect(find.byTooltip('快捷回复'), findsNothing);
    });
  });

  group('O5 —— 定时发送入口', () {
    testWidgets('提供 onScheduleMessage → 输入行显示"定时发送"入口', (tester) async {
      var tapped = false;
      await tester.pumpWidget(wrap(view(
        [msg('bob', 'hi', 'm6')],
        onScheduleMessage: () => tapped = true,
      )));
      expect(find.byTooltip('定时发送'), findsOneWidget);
      await tester.tap(find.byTooltip('定时发送'));
      expect(tapped, isTrue);
    });

    testWidgets('未提供 onScheduleMessage → 不显示入口（回归）', (tester) async {
      await tester.pumpWidget(wrap(view([msg('bob', 'hi', 'm7')])));
      expect(find.byTooltip('定时发送'), findsNothing);
    });
  });
}
