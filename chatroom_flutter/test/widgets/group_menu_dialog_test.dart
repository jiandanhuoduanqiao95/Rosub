// ============================================================
// dialogs.dart 群组菜单对话框 widget 测试（阶段 F 瑕疵回归）
// ============================================================
// 回归：第一次长按群聊时菜单人数显示"0人"的缺陷。
// 修复后：打开菜单即预取成员，对话框监听 AppState——
//   成员为空（加载中）→ 显示"加载中…"
//   成员到达（updateGroupMembers）→ 实时更新为"N人"
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/state_manager.dart';
import 'package:chatroom_flutter/widgets/dialogs.dart';

AppState get state => AppState.instance;

void resetState() {
  state
    ..setLoggedOut()
    ..setConnectionStatus(ConnectionStatus.disconnected);
}

void main() {
  setUp(resetState);

  testWidgets('成员为空时菜单显示"加载中…"而非 0人', (tester) async {
    state.setLoggedIn('alice', false);
    state.addGroup(Group(id: 1, name: '开发组'));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) {
          return ElevatedButton(
            onPressed: () {
              showGroupMenuDialog(context, state.groups.first, (g) {}, (gid) {});
            },
            child: const Text('open'),
          );
        }),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // members 尚未加载：显示"加载中…"而非错误的"0 人"
    expect(find.text('加载中…'), findsOneWidget);
    expect(find.text('0 人'), findsNothing);
  });

  testWidgets('成员更新后菜单人数实时变为 N人', (tester) async {
    state.setLoggedIn('alice', false);
    state.addGroup(Group(id: 1, name: '开发组'));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) {
          return ElevatedButton(
            onPressed: () {
              showGroupMenuDialog(context, state.groups.first, (g) {}, (gid) {});
            },
            child: const Text('open'),
          );
        }),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('加载中…'), findsOneWidget);

    // 模拟 fetchGroupMembers 响应到达：AppState 更新成员
    state.updateGroupMembers(1, ['alice', 'bob', 'carol']);
    await tester.pumpAndSettle();

    expect(find.text('3 人'), findsOneWidget);
    expect(find.text('加载中…'), findsNothing);
  });

  testWidgets('已有成员缓存时菜单直接显示人数', (tester) async {
    state.setLoggedIn('alice', false);
    state.addGroup(Group(id: 1, name: '开发组'));
    state.updateGroupMembers(1, ['alice', 'bob']);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) {
          return ElevatedButton(
            onPressed: () {
              showGroupMenuDialog(context, state.groups.first, (g) {}, (gid) {});
            },
            child: const Text('open'),
          );
        }),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 已有缓存：直接显示人数，无加载状态
    expect(find.text('2 人'), findsOneWidget);
    expect(find.text('加载中…'), findsNothing);
  });

  testWidgets('菜单保留退出群组与群成员入口', (tester) async {
    state.setLoggedIn('alice', false);
    state.addGroup(Group(id: 1, name: '开发组'));
    state.updateGroupMembers(1, ['alice']);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) {
          return ElevatedButton(
            onPressed: () {
              showGroupMenuDialog(context, state.groups.first, (g) {}, (gid) {});
            },
            child: const Text('open'),
          );
        }),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('群成员'), findsOneWidget);
    expect(find.text('退出群组'), findsOneWidget);
  });
}