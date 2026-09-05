// ============================================================
// sidebar.dart 阶段 K —— 会话置顶分区 + 静音标识（已实现，全部转绿）
// ============================================================
// 覆盖 P1-11 / P1-13（《软件开发文档4.1.0.md》§11 阶段 K / §13.3）：
//   - Sidebar 新增 isPinned 判定参数（null = 无置顶分区，回归兼容）
//   - 置顶会话渲染在"置顶"分区（侧边栏最顶部，系统分区之上）
//   - 置顶 tile 显示图钉图标（Icons.push_pin）
//   - 置顶会话不重复出现在原分区（好友/群组/系统）
//   - 好友/群组/系统会话均可置顶
//   - Sidebar 新增 isMuted 判定参数：静音会话显示静音标识
//     （Icons.notifications_off_outlined，区分哪些会话被静音）
//
// Sidebar 接受纯参数（不依赖全局状态），便于直接 pump 验证。
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/widgets/sidebar.dart';

Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

Sidebar buildSidebar({
  List<ChatTarget>? targets,
  bool Function(String key)? isPinned,
  bool Function(String key)? isMuted,
  void Function(String key)? onSelect,
}) {
  return Sidebar(
    chatTargets: targets ??
        const [
          ChatTarget(key: 'bob', displayName: 'bob'),
          ChatTarget(key: 'carol', displayName: 'carol'),
        ],
    currentChat: null,
    onSelectChat: onSelect ?? (_) {},
    onAddFriend: () {},
    onCreateGroup: () {},
    onJoinGroup: () {},
    unreadOf: (_) => 0,
    isPinned: isPinned,
    isMuted: isMuted,
  );
}

void main() {
  group('K1 —— 置顶分区', () {
    testWidgets('未提供 isPinned 时无置顶分区（回归兼容）', (tester) async {
      await tester.pumpWidget(wrap(buildSidebar()));
      expect(find.text('置顶'), findsNothing);
      expect(find.text('好友 (2)'), findsOneWidget);
    });

    testWidgets('isPinned 提供但无置顶会话时不渲染置顶分区', (tester) async {
      await tester.pumpWidget(wrap(buildSidebar(isPinned: (_) => false)));
      expect(find.text('置顶'), findsNothing);
    });

    testWidgets('置顶好友渲染在"置顶"分区且带图钉图标', (tester) async {
      await tester.pumpWidget(wrap(buildSidebar(
        isPinned: (key) => key == 'bob',
      )));
      expect(find.text('置顶'), findsOneWidget);
      expect(find.byIcon(Icons.push_pin), findsOneWidget);
    });

    testWidgets('置顶分区位于侧边栏最顶部（系统/好友分区之上）', (tester) async {
      final targets = [
        const ChatTarget(key: '服务器', displayName: '系统消息'),
        const ChatTarget(key: 'bob', displayName: 'bob'),
        const ChatTarget(key: 'carol', displayName: 'carol'),
      ];
      await tester.pumpWidget(wrap(buildSidebar(
        targets: targets,
        isPinned: (key) => key == 'bob',
      )));
      final pinnedY = tester.getTopLeft(find.text('置顶')).dy;
      final systemY = tester.getTopLeft(find.text('系统')).dy;
      expect(pinnedY, lessThan(systemY), reason: '置顶分区应在系统分区之上');
    });

    testWidgets('置顶会话不出现在原分区（不重复渲染）', (tester) async {
      await tester.pumpWidget(wrap(buildSidebar(
        isPinned: (key) => key == 'bob',
      )));
      expect(find.text('bob'), findsOneWidget, reason: '置顶后仅渲染一次');
    });

    testWidgets('多个置顶会话保持传入顺序', (tester) async {
      await tester.pumpWidget(wrap(buildSidebar(
        isPinned: (key) => key == 'bob' || key == 'dave',
        targets: const [
          ChatTarget(key: 'bob', displayName: 'bob'),
          ChatTarget(key: 'carol', displayName: 'carol'),
          ChatTarget(key: 'dave', displayName: 'dave'),
        ],
      )));
      final bobY = tester.getTopLeft(find.text('bob')).dy;
      final daveY = tester.getTopLeft(find.text('dave')).dy;
      expect(bobY, lessThan(daveY), reason: '置顶分区内保持原顺序');
      expect(find.text('carol'), findsOneWidget);
      expect(find.text('好友 (1)'), findsOneWidget, reason: 'carol 留在好友分区');
    });

    testWidgets('群组会话可置顶', (tester) async {
      await tester.pumpWidget(wrap(buildSidebar(
        targets: const [
          ChatTarget(key: 'group_1', displayName: '开发组 (ID:1)', isGroup: true),
        ],
        isPinned: (key) => key == 'group_1',
      )));
      expect(find.text('置顶'), findsOneWidget);
      expect(find.byIcon(Icons.push_pin), findsOneWidget);
      expect(find.text('开发组 (ID:1)'), findsOneWidget);
    });

    testWidgets('系统会话可置顶（防御）', (tester) async {
      await tester.pumpWidget(wrap(buildSidebar(
        targets: const [
          ChatTarget(key: '服务器', displayName: '系统消息'),
          ChatTarget(key: 'bob', displayName: 'bob'),
        ],
        isPinned: (key) => key == '服务器',
      )));
      expect(find.text('置顶'), findsOneWidget);
      expect(find.text('系统消息'), findsOneWidget);
      expect(find.text('系统'), findsNothing, reason: '置顶后不重复出现系统分区');
    });

    testWidgets('置顶会话点击仍触发 onSelectChat', (tester) async {
      String? selected;
      await tester.pumpWidget(wrap(buildSidebar(
        isPinned: (key) => key == 'bob',
        onSelect: (key) => selected = key,
      )));
      await tester.tap(find.text('bob'));
      expect(selected, 'bob');
    });

    testWidgets('取消置顶后回到原分区', (tester) async {
      await tester.pumpWidget(wrap(buildSidebar(
        isPinned: (key) => false,
      )));
      expect(find.text('置顶'), findsNothing);
      expect(find.text('好友 (2)'), findsOneWidget);
    });
  });

  group('K3 —— 静音标识', () {
    testWidgets('未提供 isMuted 时不渲染静音标识（回归兼容）', (tester) async {
      await tester.pumpWidget(wrap(buildSidebar()));
      expect(find.byIcon(Icons.notifications_off_outlined), findsNothing);
    });

    testWidgets('静音好友会话显示静音标识', (tester) async {
      await tester.pumpWidget(wrap(buildSidebar(
        isMuted: (key) => key == 'bob',
      )));
      expect(find.byIcon(Icons.notifications_off_outlined), findsOneWidget);
    });

    testWidgets('未静音会话不显示静音标识', (tester) async {
      await tester.pumpWidget(wrap(buildSidebar(
        isMuted: (_) => false,
      )));
      expect(find.byIcon(Icons.notifications_off_outlined), findsNothing);
    });

    testWidgets('静音群组会话显示静音标识', (tester) async {
      await tester.pumpWidget(wrap(buildSidebar(
        targets: const [
          ChatTarget(
              key: 'group_1', displayName: '开发组 (ID:1)', isGroup: true),
        ],
        isMuted: (key) => key == 'group_1',
      )));
      expect(find.byIcon(Icons.notifications_off_outlined), findsOneWidget);
    });

    testWidgets('置顶分区中的静音会话同样显示标识', (tester) async {
      await tester.pumpWidget(wrap(buildSidebar(
        isPinned: (key) => key == 'bob',
        isMuted: (key) => key == 'bob',
      )));
      expect(find.byIcon(Icons.notifications_off_outlined), findsOneWidget);
      expect(find.text('置顶'), findsOneWidget);
    });

    testWidgets('静音标识与未读徽标共存', (tester) async {
      await tester.pumpWidget(wrap(Sidebar(
        chatTargets: const [
          ChatTarget(key: 'bob', displayName: 'bob'),
        ],
        currentChat: null,
        onSelectChat: (_) {},
        onAddFriend: () {},
        onCreateGroup: () {},
        onJoinGroup: () {},
        unreadOf: (key) => key == 'bob' ? 3 : 0,
        isMuted: (key) => key == 'bob',
      )));
      expect(find.byIcon(Icons.notifications_off_outlined), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    });
  });
}
