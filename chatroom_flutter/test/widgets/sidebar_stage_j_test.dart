// ============================================================
// sidebar.dart 阶段 J —— 在线标记 + 好友分组渲染（TDD 契约，待实现）
// ============================================================
// 覆盖 P0-3 / P1-8（《软件开发文档4.1.0.md》§13.2/§13.3）：
//   - 好友行在线标记：isOnline 回调返回 true → 绿色在线点；false → 灰点
//   - 群组/服务器会话不显示在线标记
//   - friendGroups 提供时按分组渲染好友分区（未分组归"未分组"）
//   - 未提供分组参数时保持原有扁平渲染（回归）
//
// Sidebar 接受纯参数（不依赖全局状态），便于直接 pump 验证。
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/state_manager.dart';
import 'package:chatroom_flutter/widgets/sidebar.dart';

Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

Sidebar buildSidebar({
  List<ChatTarget>? targets,
  bool Function(String key)? isOnline,
  Map<String, List<String>>? friendGroups,
}) {
  return Sidebar(
    chatTargets: targets ??
        const [
          ChatTarget(key: 'bob', displayName: 'bob'),
          ChatTarget(key: 'carol', displayName: 'carol'),
        ],
    currentChat: null,
    onSelectChat: (_) {},
    onAddFriend: () {},
    onCreateGroup: () {},
    onJoinGroup: () {},
    unreadOf: (_) => 0,
    isOnline: isOnline,
    friendGroups: friendGroups,
  );
}

void main() {
  group('J2 —— 在线标记', () {
    testWidgets('在线好友显示绿色在线点', (tester) async {
      await tester.pumpWidget(wrap(buildSidebar(
        isOnline: (key) => key == 'bob',
      )));
      // 在线好友行内应有绿色圆点（在线标记）
      expect(
        find.byWidgetPredicate((w) =>
            w is Icon && w.icon == Icons.circle && w.color == Colors.green),
        findsOneWidget,
      );
    });

    testWidgets('离线好友显示灰点', (tester) async {
      await tester.pumpWidget(wrap(buildSidebar(
        isOnline: (key) => false,
      )));
      expect(
        find.byWidgetPredicate((w) =>
            w is Icon && w.icon == Icons.circle && w.color == Colors.grey),
        findsNWidgets(2),
        reason: 'bob 与 carol 均离线 → 各显示一个灰点',
      );
    });

    testWidgets('在线+离线混合渲染', (tester) async {
      await tester.pumpWidget(wrap(buildSidebar(
        isOnline: (key) => key == 'bob',
      )));
      expect(
        find.byWidgetPredicate((w) =>
            w is Icon && w.icon == Icons.circle && w.color == Colors.green),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate((w) =>
            w is Icon && w.icon == Icons.circle && w.color == Colors.grey),
        findsOneWidget,
      );
    });

    testWidgets('未提供 isOnline 时不渲染任何在线点（回归）', (tester) async {
      await tester.pumpWidget(wrap(buildSidebar()));
      expect(
        find.byIcon(Icons.circle),
        findsNothing,
        reason: '旧调用方不传 isOnline → 保持原样无标记',
      );
    });

    testWidgets('群组与会话不显示在线标记', (tester) async {
      final targets = [
        const ChatTarget(key: 'bob', displayName: 'bob'),
        const ChatTarget(
            key: 'group_1', displayName: '开发组 (ID:1)', isGroup: true),
        const ChatTarget(key: '服务器', displayName: '系统消息'),
      ];
      await tester.pumpWidget(wrap(Sidebar(
        chatTargets: targets,
        currentChat: null,
        onSelectChat: (_) {},
        onAddFriend: () {},
        onCreateGroup: () {},
        onJoinGroup: () {},
        unreadOf: (_) => 0,
        isOnline: (key) => key != 'group_1' && key != '服务器',
      )));
      expect(
        find.byWidgetPredicate((w) =>
            w is Icon && w.icon == Icons.circle && w.color == Colors.green),
        findsOneWidget,
        reason: '仅 bob 在线；群组/系统会话无在线点',
      );
    });
  });

  group('J4 —— 好友分组渲染', () {
    testWidgets('提供 friendGroups 时按分组渲染分区', (tester) async {
      final targets = [
        const ChatTarget(key: 'bob', displayName: 'bob'),
        const ChatTarget(key: 'carol', displayName: 'carol'),
        const ChatTarget(key: 'dave', displayName: 'dave'),
      ];
      await tester.pumpWidget(wrap(Sidebar(
        chatTargets: targets,
        currentChat: null,
        onSelectChat: (_) {},
        onAddFriend: () {},
        onCreateGroup: () {},
        onJoinGroup: () {},
        unreadOf: (_) => 0,
        friendGroups: const {
          '家人': ['bob'],
          '同事': ['carol'],
        },
      )));
      expect(find.text('家人'), findsOneWidget);
      expect(find.text('同事'), findsOneWidget);
      expect(find.text('dave'), findsWidgets, reason: '未分组好友仍可见');
    });

    testWidgets('未分组好友归入"未分组"分区', (tester) async {
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
        friendGroups: const {
          '家人': ['bob'],
        },
      )));
      expect(find.text(AppState.ungroupedLabel), findsOneWidget);
      expect(find.text('carol'), findsWidgets);
    });

    testWidgets('分组模式下点击好友仍触发 onSelectChat', (tester) async {
      String? selected;
      final targets = [const ChatTarget(key: 'bob', displayName: 'bob')];
      await tester.pumpWidget(wrap(Sidebar(
        chatTargets: targets,
        currentChat: null,
        onSelectChat: (key) => selected = key,
        onAddFriend: () {},
        onCreateGroup: () {},
        onJoinGroup: () {},
        unreadOf: (_) => 0,
        friendGroups: const {
          '家人': ['bob'],
        },
      )));
      await tester.tap(find.text('bob'));
      expect(selected, 'bob');
    });

    testWidgets('未提供 friendGroups 时保持扁平好友列表（回归）', (tester) async {
      await tester.pumpWidget(wrap(buildSidebar()));
      expect(find.text('好友 (2)'), findsOneWidget);
      expect(find.text('家人'), findsNothing);
    });
  });

  group('J4 —— 在线标记与分组组合', () {
    testWidgets('分组模式下在线好友仍显示在线点', (tester) async {
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
        isOnline: (key) => key == 'bob',
        friendGroups: const {
          '家人': ['bob'],
          '同事': ['carol'],
        },
      )));
      expect(
        find.byWidgetPredicate((w) =>
            w is Icon && w.icon == Icons.circle && w.color == Colors.green),
        findsOneWidget,
      );
    });
  });
}
