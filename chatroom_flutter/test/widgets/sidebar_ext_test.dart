// ============================================================
// sidebar.dart 扩展攻击性测试（测试强化新增）
// ============================================================
// 覆盖既有测试未触达的分支：
//   - 好友长按 → onDeleteFriend 回调（阶段 F）
//   - 群组长按 → onGroupLongPress 回调（阶段 F）
//   - 超大未读数徽标
//   - 回调为 null 时的安全行为
//   - 选中态与混合分组渲染
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/widgets/sidebar.dart';

Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('长按回调（阶段 F）', () {
    testWidgets('长按好友触发 onDeleteFriend 且携带用户名', (tester) async {
      String? deleted;
      final targets = [
        const ChatTarget(key: 'bob', displayName: 'bob'),
        const ChatTarget(key: 'carol', displayName: 'carol'),
      ];
      await tester.pumpWidget(wrap(Sidebar(
        chatTargets: targets,
        currentChat: null,
        onSelectChat: (_) {},
        onAddFriend: () {},
        onCreateGroup: () {},
        onJoinGroup: () {},
        unreadOf: (_) => 0,
        onDeleteFriend: (name) => deleted = name,
      )));
      await tester.longPress(find.text('bob'));
      await tester.pump();
      expect(deleted, 'bob');
    });

    testWidgets('长按群组触发 onGroupLongPress 且携带目标', (tester) async {
      ChatTarget? pressed;
      final targets = [
        const ChatTarget(key: 'group_1', displayName: '开发组 (ID:1)', isGroup: true),
      ];
      await tester.pumpWidget(wrap(Sidebar(
        chatTargets: targets,
        currentChat: null,
        onSelectChat: (_) {},
        onAddFriend: () {},
        onCreateGroup: () {},
        onJoinGroup: () {},
        unreadOf: (_) => 0,
        onGroupLongPress: (t) => pressed = t,
      )));
      await tester.longPress(find.text('开发组 (ID:1)'));
      await tester.pump();
      expect(pressed?.key, 'group_1');
      expect(pressed?.isGroup, isTrue);
    });

    testWidgets('onDeleteFriend 为 null 时长按好友不崩溃', (tester) async {
      final targets = [
        const ChatTarget(key: 'bob', displayName: 'bob'),
      ];
      await tester.pumpWidget(wrap(Sidebar(
        chatTargets: targets,
        currentChat: null,
        onSelectChat: (_) {},
        onAddFriend: () {},
        onCreateGroup: () {},
        onJoinGroup: () {},
        unreadOf: (_) => 0,
      )));
      await tester.longPress(find.text('bob'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('onGroupLongPress 为 null 时长按群组不崩溃', (tester) async {
      final targets = [
        const ChatTarget(key: 'group_1', displayName: 'g', isGroup: true),
      ];
      await tester.pumpWidget(wrap(Sidebar(
        chatTargets: targets,
        currentChat: null,
        onSelectChat: (_) {},
        onAddFriend: () {},
        onCreateGroup: () {},
        onJoinGroup: () {},
        unreadOf: (_) => 0,
      )));
      await tester.longPress(find.text('g'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('未读徽标边界', () {
    testWidgets('超大未读数（99999）正常显示', (tester) async {
      final targets = [
        const ChatTarget(key: 'bob', displayName: 'bob'),
      ];
      await tester.pumpWidget(wrap(Sidebar(
        chatTargets: targets,
        currentChat: null,
        onSelectChat: (_) {},
        onAddFriend: () {},
        onCreateGroup: () {},
        onJoinGroup: () {},
        unreadOf: (key) => key == 'bob' ? 99999 : 0,
      )));
      expect(find.text('99999'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('负数未读不显示徽标（记录现状）', (tester) async {
      final targets = [
        const ChatTarget(key: 'bob', displayName: 'bob'),
      ];
      await tester.pumpWidget(wrap(Sidebar(
        chatTargets: targets,
        currentChat: null,
        onSelectChat: (_) {},
        onAddFriend: () {},
        onCreateGroup: () {},
        onJoinGroup: () {},
        unreadOf: (key) => key == 'bob' ? -1 : 0,
      )));
      expect(find.byType(Badge), findsNothing);
    });
  });

  group('选中与分组', () {
    testWidgets('选中会话高亮且标题加粗（不崩溃）', (tester) async {
      final targets = [
        const ChatTarget(key: 'bob', displayName: 'bob'),
        const ChatTarget(key: 'group_1', displayName: 'g (ID:1)', isGroup: true),
        const ChatTarget(key: '服务器', displayName: '系统消息'),
      ];
      await tester.pumpWidget(wrap(Sidebar(
        chatTargets: targets,
        currentChat: 'group_1',
        onSelectChat: (_) {},
        onAddFriend: () {},
        onCreateGroup: () {},
        onJoinGroup: () {},
        unreadOf: (_) => 0,
      )));
      expect(tester.takeException(), isNull);
      // 三个分组标题齐全
      expect(find.text('系统'), findsOneWidget);
      expect(find.textContaining('好友'), findsOneWidget);
      expect(find.textContaining('群组'), findsOneWidget);
    });

    testWidgets('只有群组时无"好友"标题', (tester) async {
      final targets = [
        const ChatTarget(key: 'group_1', displayName: 'g', isGroup: true),
      ];
      await tester.pumpWidget(wrap(Sidebar(
        chatTargets: targets,
        currentChat: null,
        onSelectChat: (_) {},
        onAddFriend: () {},
        onCreateGroup: () {},
        onJoinGroup: () {},
        unreadOf: (_) => 0,
      )));
      expect(find.textContaining('好友'), findsNothing);
      expect(find.textContaining('群组 (1)'), findsOneWidget);
    });

    testWidgets('超长会话名渲染省略（不溢出）', (tester) async {
      final longName = 'x' * 500;
      final targets = [
        ChatTarget(key: 'bob', displayName: longName),
      ];
      await tester.pumpWidget(wrap(Sidebar(
        chatTargets: targets,
        currentChat: null,
        onSelectChat: (_) {},
        onAddFriend: () {},
        onCreateGroup: () {},
        onJoinGroup: () {},
        unreadOf: (_) => 0,
      )));
      expect(tester.takeException(), isNull);
    });
  });
}
