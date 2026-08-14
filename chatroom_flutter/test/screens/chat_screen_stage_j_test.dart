// ============================================================
// chat_screen.dart 阶段 J —— 接线契约（TDD 契约，待实现）
// ============================================================
// 覆盖 P0-2/P0-3/P1-9/P1-10（《软件开发文档4.1.0.md》§13.2/§13.3）：
//   - ChatScreen 将 state.isOnline 传入 Sidebar → 在线好友显示在线点
//   - 添加好友按钮 → 用户搜索对话框 → 搜索/添加接线到 socketService
//   - 长按好友 → 好友菜单含"拉黑" → 确认后 socketService.blockUser
//
// 网络层用 mocktail 隔离（SocketService mock），不触网。
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/screens/chat_screen.dart';
import 'package:chatroom_flutter/services/socket_service.dart';
import 'package:chatroom_flutter/services/state_manager.dart';
import 'package:chatroom_flutter/widgets/raw_text_field.dart';

class MockSocketService extends Mock implements SocketService {}

AppState get state => AppState.instance;

void resetState() {
  state
    ..setLoggedOut()
    ..setConnectionStatus(ConnectionStatus.disconnected);
}

MockSocketService buildService() {
  final s = MockSocketService();
  when(() => s.blockUser(any())).thenAnswer((_) async {});
  when(() => s.addFriend(any())).thenAnswer((_) async {});
  when(() => s.addFriend(any(), message: any(named: 'message')))
      .thenAnswer((_) async {});
  when(() => s.searchUsers(any())).thenAnswer((_) async {});
  when(() => s.fetchProfile(any())).thenAnswer((_) async {});
  when(() => s.acceptFriend(any())).thenAnswer((_) async {});
  when(() => s.rejectFriend(any())).thenAnswer((_) async {});
  when(() => s.setFriendNote(any(), any())).thenAnswer((_) async {});
  return s;
}

Future<void> pumpScreen(WidgetTester tester, MockSocketService socket) async {
  await tester.pumpWidget(MaterialApp(
    home: ChatScreen(socketService: socket),
    routes: {'/login': (_) => const Scaffold(body: Text('LOGIN'))},
  ));
  await tester.pump();
}

Finder greenDot() => find.byWidgetPredicate(
    (w) => w is Icon && w.icon == Icons.circle && w.color == Colors.green);

LogicalKeyboardKey _charKey(String ch) {
  if (ch == ' ') return LogicalKeyboardKey.space;
  if ('0123456789'.contains(ch)) {
    return const {
      '0': LogicalKeyboardKey.digit0,
      '1': LogicalKeyboardKey.digit1,
      '2': LogicalKeyboardKey.digit2,
      '3': LogicalKeyboardKey.digit3,
      '4': LogicalKeyboardKey.digit4,
      '5': LogicalKeyboardKey.digit5,
      '6': LogicalKeyboardKey.digit6,
      '7': LogicalKeyboardKey.digit7,
      '8': LogicalKeyboardKey.digit8,
      '9': LogicalKeyboardKey.digit9,
    }[ch]!;
  }
  return const {
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
}

/// 向最上层（对话框内）的 RawTextField 键入文本（同 dialogs_test.dart 惯例）。
/// 取 .last：ChatScreen 底部输入栏的 RawTextField 位于对话框字段之前。
/// [index] 指定 RawTextField 序号（可精确聚焦对话框内的某一输入框）。
Future<void> typeInto(WidgetTester tester, String text, {int? index}) async {
  final target = index != null
      ? find.byType(RawTextField).at(index)
      : find.byType(RawTextField).last;
  await tester.tap(target);
  await tester.pump();
  for (final ch in text.split('')) {
    await tester.sendKeyEvent(_charKey(ch));
    await tester.pump();
  }
}

void main() {
  setUp(resetState);

  group('J2 —— 在线标记接线', () {
    testWidgets('presence 更新后侧边栏显示在线点', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');
      await pumpScreen(tester, socket);

      expect(greenDot(), findsNothing);
      state.updatePresence('bob', true);
      await tester.pumpAndSettle();
      expect(greenDot(), findsOneWidget, reason: '在线好友应有绿色标记');

      state.updatePresence('bob', false);
      await tester.pumpAndSettle();
      expect(greenDot(), findsNothing, reason: '下线后标记消失');
    });

    testWidgets('群组会话不显示在线点', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.addGroup(Group(id: 1, name: '开发组'));
      state.selectChat('group_1');
      await pumpScreen(tester, socket);

      state.updatePresence('alice', true);
      state.updatePresence('bob', true);
      await tester.pumpAndSettle();
      expect(greenDot(), findsNothing, reason: '群组/系统会话无在线点');
    });
  });

  group('J4 —— 拉黑接线', () {
    testWidgets('长按好友 → 菜单含拉黑 → 确认 → blockUser', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');
      await pumpScreen(tester, socket);

      await tester.longPress(find.text('bob'));
      await tester.pumpAndSettle();
      expect(find.text('拉黑'), findsOneWidget, reason: '好友菜单应含拉黑入口');

      await tester.tap(find.text('拉黑'));
      await tester.pumpAndSettle();
      // 确认对话框
      await tester.tap(find.text('拉黑').last);
      await tester.pumpAndSettle();

      verify(() => socket.blockUser('bob')).called(1);
    });

    testWidgets('取消拉黑不调用 blockUser', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');
      await pumpScreen(tester, socket);

      await tester.longPress(find.text('bob'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('拉黑'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      verifyNever(() => socket.blockUser(any()));
    });
  });

  group('J4 —— 用户搜索接线', () {
    testWidgets('添加好友 → 搜索 → 带验证消息添加 → addFriend', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');
      await pumpScreen(tester, socket);

      // 点击添加好友按钮 → 用户搜索对话框
      await tester.tap(find.byTooltip('添加好友'));
      await tester.pumpAndSettle();
      expect(find.text('搜索'), findsOneWidget, reason: '打开用户搜索对话框');

      // 输入关键字并搜索
      await typeInto(tester, 'carol');
      await tester.tap(find.text('搜索'));
      await tester.pump();
      verify(() => socket.searchUsers('carol')).called(1);

      // 服务端结果到达 → 点击结果 → 填验证消息（index=3，备注名框留空）→ 确定
      state.setUserSearchResults(['carol']);
      await tester.pumpAndSettle();
      await tester.tap(find.text('carol'));
      await tester.pumpAndSettle();
      await typeInto(tester, 'hello from alice', index: 3);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      verify(() => socket.addFriend('carol', message: 'hello from alice'))
          .called(1);
      expect(state.pendingFriendNoteOf('carol'), isNull,
          reason: '备注名留空 → 不存 pending note');
    });

    testWidgets('添加好友时填写备注名 → addFriend + pendingFriendNote 暂存',
        (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');
      await pumpScreen(tester, socket);

      await tester.tap(find.byTooltip('添加好友'));
      await tester.pumpAndSettle();
      await typeInto(tester, 'carol');
      await tester.tap(find.text('搜索'));
      await tester.pump();
      state.setUserSearchResults(['carol']);
      await tester.pumpAndSettle();
      await tester.tap(find.text('carol'));
      await tester.pumpAndSettle();

      // 备注名框（index=2，对话框内第 1 个字段）输入备注 → 确定
      await typeInto(tester, 'LittleC', index: 2);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      verify(() => socket.addFriend('carol', message: '')).called(1);
      expect(state.pendingFriendNoteOf('carol'), 'littlec',
          reason: '发送请求时询问的备注名应暂存，待接受后自动设置（测试键入为小写）');
    });

    testWidgets('接受好友请求填备注 → acceptFriend + setFriendNote', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.addPendingRequest('bob', message: '我是 bob');
      await pumpScreen(tester, socket);

      await tester.tap(find.byTooltip('待处理好友请求'));
      await tester.pumpAndSettle();
      // 验证消息可见
      expect(find.textContaining('我是 bob'), findsOneWidget);
      await tester.tap(find.byTooltip('接受').first);
      await tester.pumpAndSettle();
      // 备注询问框：跳过 → 仅 acceptFriend
      await tester.tap(find.text('跳过'));
      await tester.pumpAndSettle();
      verify(() => socket.acceptFriend('bob')).called(1);
      verifyNever(() => socket.setFriendNote(any(), any()));
    });

    testWidgets('接受好友请求并填写备注 → acceptFriend + setFriendNote(note)',
        (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.addPendingRequest('bob');
      await pumpScreen(tester, socket);

      await tester.tap(find.byTooltip('待处理好友请求'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('接受').first);
      await tester.pumpAndSettle();
      // 备注询问框：输入备注 → 确定
      await typeInto(tester, 'ahbo');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      verify(() => socket.acceptFriend('bob')).called(1);
      verify(() => socket.setFriendNote('bob', 'ahbo')).called(1);
    });
  });
}
