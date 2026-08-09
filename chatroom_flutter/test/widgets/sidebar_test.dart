// ============================================================
// sidebar.dart Widget 测试
// ============================================================
// 验证侧边栏的会话分组、未读徽标（阶段 E）、空状态与操作按钮。
// Sidebar 接受纯参数（不依赖全局状态），便于直接 pump 验证。
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/widgets/sidebar.dart';

Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('Sidebar 分组展示', () {
    testWidgets('无会话时显示空状态提示', (tester) async {
      await tester.pumpWidget(wrap(Sidebar(
        chatTargets: const [],
        currentChat: null,
        onSelectChat: (_) {},
        onAddFriend: () {},
        onCreateGroup: () {},
        onJoinGroup: () {},
        unreadOf: (_) => 0,
      )));
      expect(find.textContaining('暂无会话'), findsOneWidget);
    });

    testWidgets('好友与群组分组标题及成员展示', (tester) async {
      final targets = [
        const ChatTarget(key: 'bob', displayName: 'bob'),
        const ChatTarget(key: 'carol', displayName: 'carol'),
        const ChatTarget(key: 'group_1', displayName: '开发组 (ID:1)', isGroup: true),
      ];
      await tester.pumpWidget(wrap(Sidebar(
        chatTargets: targets,
        currentChat: 'bob',
        onSelectChat: (_) {},
        onAddFriend: () {},
        onCreateGroup: () {},
        onJoinGroup: () {},
        unreadOf: (_) => 0,
      )));
      expect(find.text('好友 (2)'), findsOneWidget);
      expect(find.text('群组 (1)'), findsOneWidget);
      expect(find.text('bob'), findsWidgets);
      expect(find.text('开发组 (ID:1)'), findsOneWidget);
    });

    testWidgets('系统会话仅在 服务器 目标存在时出现', (tester) async {
      final targets = [
        const ChatTarget(key: '服务器', displayName: '系统消息'),
      ];
      await tester.pumpWidget(wrap(Sidebar(
        chatTargets: targets,
        currentChat: '服务器',
        onSelectChat: (_) {},
        onAddFriend: () {},
        onCreateGroup: () {},
        onJoinGroup: () {},
        unreadOf: (_) => 0,
      )));
      expect(find.text('系统'), findsOneWidget);
      expect(find.text('系统消息'), findsOneWidget);
    });
  });

  group('未读徽标（阶段 E）', () {
    testWidgets('未读 > 0 时显示徽标数字', (tester) async {
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
        unreadOf: (key) => key == 'bob' ? 7 : 0,
      )));
      // 徽标 label 文本为 '7'
      expect(find.text('7'), findsOneWidget);
    });

    testWidgets('未读为 0 时不显示徽标', (tester) async {
      final targets = [
        const ChatTarget(key: 'bob', displayName: 'bob'),
      ];
      await tester.pumpWidget(wrap(Sidebar(
        chatTargets: targets,
        currentChat: 'bob',
        onSelectChat: (_) {},
        onAddFriend: () {},
        onCreateGroup: () {},
        onJoinGroup: () {},
        unreadOf: (_) => 0,
      )));
      expect(find.byType(Badge), findsNothing);
    });
  });

  group('点击与操作按钮', () {
    testWidgets('点击好友会话触发 onSelectChat', (tester) async {
      String? selected;
      final targets = [
        const ChatTarget(key: 'bob', displayName: 'bob'),
      ];
      await tester.pumpWidget(wrap(Sidebar(
        chatTargets: targets,
        currentChat: null,
        onSelectChat: (key) => selected = key,
        onAddFriend: () {},
        onCreateGroup: () {},
        onJoinGroup: () {},
        unreadOf: (_) => 0,
      )));
      await tester.tap(find.text('bob'));
      await tester.pump();
      expect(selected, 'bob');
    });

    testWidgets('工具栏三个按钮 tooltip 存在', (tester) async {
      bool add = false, create = false, join = false;
      await tester.pumpWidget(wrap(Sidebar(
        chatTargets: const [],
        currentChat: null,
        onSelectChat: (_) {},
        onAddFriend: () => add = true,
        onCreateGroup: () => create = true,
        onJoinGroup: () => join = true,
        unreadOf: (_) => 0,
      )));
      expect(find.byTooltip('添加好友'), findsOneWidget);
      expect(find.byTooltip('创建群组'), findsOneWidget);
      expect(find.byTooltip('加入群组'), findsOneWidget);

      await tester.tap(find.byTooltip('添加好友'));
      expect(add, isTrue);
      await tester.tap(find.byTooltip('创建群组'));
      expect(create, isTrue);
      await tester.tap(find.byTooltip('加入群组'));
      expect(join, isTrue);
    });
  });
}