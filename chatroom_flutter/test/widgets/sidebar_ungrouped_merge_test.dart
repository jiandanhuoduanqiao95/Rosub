// ============================================================
// opt1 回归 —— 好友列表"未分组"双头修复
// ============================================================
// 现象：好友 meta 中 groupName 为空（friendsByGroup 产生 '未分组' 键）
// 与无 meta 记录的新好友（addFriend 未写 meta）同时存在时，sidebar
// 两条渲染路径各画一个"未分组"分区头。
// 修复：sidebar 渲染时跳过 friendGroups 中的 '未分组' 键，全部未分组
// 好友统一由 _renderUngroupedFriends 收进单一分区；AppState.addFriend
// 同步补默认 meta 消除数据层双源。
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/state_manager.dart';
import 'package:chatroom_flutter/widgets/sidebar.dart';

Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

Sidebar buildSidebar({
  required List<ChatTarget> targets,
  Map<String, List<String>>? friendGroups,
}) {
  return Sidebar(
    chatTargets: targets,
    currentChat: null,
    onSelectChat: (_) {},
    onAddFriend: () {},
    onCreateGroup: () {},
    onJoinGroup: () {},
    unreadOf: (_) => 0,
    friendGroups: friendGroups,
  );
}

void main() {
  group('opt1 —— 未分组单一分区头', () {
    testWidgets('空 meta 组 + 无 meta 好友 → 恰好一个"未分组"头，两人都在其下',
        (tester) async {
      final targets = [
        const ChatTarget(key: 'alice', displayName: 'alice'),
        const ChatTarget(key: 'stranger', displayName: 'Stranger'),
      ];
      await tester.pumpWidget(wrap(buildSidebar(
        targets: targets,
        friendGroups: const {
          AppState.ungroupedLabel: ['alice'],
        },
      )));
      expect(find.text(AppState.ungroupedLabel), findsOneWidget,
          reason: '空 meta 的 alice 与无 meta 的 Stranger 必须合并为单一分区');
      expect(find.text('alice'), findsOneWidget);
      expect(find.text('Stranger'), findsOneWidget);
    });

    testWidgets('具名分组 + 未分组混合 → 各一个分区头', (tester) async {
      final targets = [
        const ChatTarget(key: 'bob', displayName: 'bob'),
        const ChatTarget(key: 'alice', displayName: 'alice'),
        const ChatTarget(key: 'stranger', displayName: 'Stranger'),
      ];
      await tester.pumpWidget(wrap(buildSidebar(
        targets: targets,
        friendGroups: const {
          '家人': ['bob'],
          AppState.ungroupedLabel: ['alice'],
        },
      )));
      expect(find.text('家人'), findsOneWidget);
      expect(find.text(AppState.ungroupedLabel), findsOneWidget);
      expect(find.text('bob'), findsOneWidget);
      expect(find.text('alice'), findsOneWidget);
      expect(find.text('Stranger'), findsOneWidget);
    });

    testWidgets('仅空 meta 组、无散落好友 → 单一头（回归）', (tester) async {
      final targets = [const ChatTarget(key: 'alice', displayName: 'alice')];
      await tester.pumpWidget(wrap(buildSidebar(
        targets: targets,
        friendGroups: const {
          AppState.ungroupedLabel: ['alice'],
        },
      )));
      expect(find.text(AppState.ungroupedLabel), findsOneWidget);
      expect(find.text('alice'), findsOneWidget);
    });

    testWidgets('无未分组成员时不渲染分区头（回归）', (tester) async {
      final targets = [const ChatTarget(key: 'bob', displayName: 'bob')];
      await tester.pumpWidget(wrap(buildSidebar(
        targets: targets,
        friendGroups: const {
          '家人': ['bob'],
        },
      )));
      expect(find.text(AppState.ungroupedLabel), findsNothing);
    });
  });

  group('opt1 —— AppState.addFriend 补默认 meta', () {
    final state = AppState.instance;

    setUp(() {
      state
        ..setLoggedOut()
        ..setFriendMetaList(const []);
    });

    test('新好友进入 friendsByGroup 的未分组键', () {
      state.addFriend('newbie');
      expect(state.friendsByGroup[AppState.ungroupedLabel], ['newbie']);
      expect(state.friendMetaOf('newbie'), isNotNull);
      expect(state.friendGroupOf('newbie'), isEmpty);
    });

    test('已有 meta 时不覆盖（putIfAbsent 语义）', () {
      state.updateFriendMeta('bob', groupName: '家人', note: '备注');
      state.addFriend('bob');
      expect(state.friendGroupOf('bob'), '家人');
      expect(state.friendNoteOf('bob'), '备注');
    });

    test('登录全量推送仍覆盖 addFriend 的默认 meta', () {
      state.addFriend('carol');
      state.setFriendMetaList([
        const FriendMeta(username: 'carol', note: 'n', groupName: '同事'),
      ]);
      expect(state.friendGroupOf('carol'), '同事');
      expect(state.friendsByGroup[AppState.ungroupedLabel], isNull);
    });
  });
}
