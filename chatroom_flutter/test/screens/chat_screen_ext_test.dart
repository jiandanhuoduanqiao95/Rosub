// ============================================================
// chat_screen.dart 交互全流程测试（mocktail mock 网络层）
// ============================================================
// 以真实 UI 操作驱动 ChatScreen，验证网络方法接线正确性：
//   - 选择会话 → 输入 → 发送（私聊 / 群聊）
//   - 通知队列 → SnackBar
//   - 强制下线 → 回登录页
//   - 好友请求对话框 接受/拒绝
//   - 文件请求对话框（私聊 / 群文件）
//   - 删除好友（长按 → 确认框）
//   - 群组菜单 → 退出群组
//   - 首次进入会话触发 fetchHistory
//   - 管理面板 list_users
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
  when(() => s.sendChat(any(), any())).thenAnswer((_) async => true);
  when(() => s.saveConversationDraft(any(), any())).thenAnswer((_) async {});
  when(() => s.sendGroupChat(any(), any())).thenAnswer((_) async => true);
  when(() => s.sendFile(any(), any(), any())).thenAnswer((_) async => true);
  when(() => s.changePassword(any(), any())).thenAnswer((_) async => true);
  when(() => s.fetchHistory(
      to: any(named: 'to'),
      groupId: any(named: 'groupId'),
      beforeMessageId: any(named: 'beforeMessageId'),
      limit: any(named: 'limit'))).thenAnswer((_) async {});
  when(() => s.acceptFriend(any())).thenAnswer((_) async {});
  when(() => s.rejectFriend(any())).thenAnswer((_) async {});
  when(() => s.deleteFriend(any())).thenAnswer((_) async {});
  when(() => s.leaveGroup(any())).thenAnswer((_) async {});
  when(() => s.fetchGroupMembers(any())).thenAnswer((_) async {});
  when(() => s.adminCommand(any())).thenAnswer((_) async {});
  when(() => s.adminCommand(any(), targetUser: any(named: 'targetUser')))
      .thenAnswer((_) async {});
  when(() => s.adminCommand(any(), announcement: any(named: 'announcement')))
      .thenAnswer((_) async {});
  when(() => s.respondFileRequest(any(), any(), any()))
      .thenAnswer((_) async {});
  when(() => s.respondGroupFileRequest(any(), any(), any()))
      .thenAnswer((_) async {});
  return s;
}

Future<void> pumpScreen(WidgetTester tester, MockSocketService socket) async {
  await tester.pumpWidget(MaterialApp(
    home: ChatScreen(socketService: socket),
    routes: {'/login': (_) => const Scaffold(body: Text('LOGIN'))},
  ));
  await tester.pump();
}

void main() {
  setUp(resetState);

  group('消息发送接线', () {
    testWidgets('选择好友会话后输入并发送 → sendChat', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      await pumpScreen(tester, socket);

      // 选择 bob 会话
      await tester.tap(find.text('bob'));
      await tester.pumpAndSettle();
      verify(() => socket.fetchHistory(
          to: 'bob',
          groupId: null,
          beforeMessageId: null,
          limit: 50)).called(1);

      // 聚焦输入框并输入
      await tester.tap(find.byType(RawTextField));
      await tester.pump();
      for (final ch in ['h', 'i']) {
        await tester.sendKeyEvent(
            ch == 'h' ? LogicalKeyboardKey.keyH : LogicalKeyboardKey.keyI);
        await tester.pump();
      }
      await tester.tap(find.byTooltip('发送'));
      await tester.pump();

      verify(() => socket.sendChat('bob', 'hi')).called(1);
      // 输入框发送后被清空
      expect(find.text('hi'), findsNothing);
      await tester.pump(const Duration(seconds: 3)); // 冲刷 IME 遗留 Timer
    });

    testWidgets('群组会话发送 → sendGroupChat', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setGroups([Group(id: 7, name: '开发组')]);
      await pumpScreen(tester, socket);

      await tester.tap(find.text('开发组 (ID:7)'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(RawTextField));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyY);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump();
      await tester.tap(find.byTooltip('发送'));
      await tester.pump();

      verify(() => socket.sendGroupChat(7, 'yes')).called(1);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('未选择会话时无发送按钮，也不产生网络调用', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      await pumpScreen(tester, socket);

      // 未选择会话：聊天区为占位，无发送 UI
      expect(find.byTooltip('发送'), findsNothing);
      expect(find.text('选择一个会话开始聊天'), findsOneWidget);
      verifyNever(() => socket.sendChat(any(), any()));
      verifyNever(() => socket.sendGroupChat(any(), any()));
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('系统会话只读：无发送按钮、Enter 不产生网络调用', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.addMessage(
          '服务器',
          ChatMessage(
              sender: '服务器', content: '公告', messageId: 's1', type: 'system'));
      await pumpScreen(tester, socket);

      await tester.tap(find.text('系统消息'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('发送'), findsNothing);
      expect(find.textContaining('为只读会话'), findsOneWidget);
      verifyNever(() => socket.sendChat(any(), any()));
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('通知与强制下线', () {
    testWidgets('notice 队列 → SnackBar 展示', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      await pumpScreen(tester, socket);

      state.showNotice('操作成功');
      await tester.pump();
      expect(find.text('操作成功'), findsOneWidget);
    });

    testWidgets('强制下线（setLoggedOut）→ 跳转登录页', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      await pumpScreen(tester, socket);

      state.setLoggedOut();
      await tester.pumpAndSettle();
      expect(find.text('LOGIN'), findsOneWidget);
    });

    testWidgets('重连横幅"退出"按钮 → disconnect + 回登录页', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setReconnecting();
      await pumpScreen(tester, socket);

      await tester.tap(find.text('退出'));
      await tester.pumpAndSettle();
      verify(() => socket.disconnect()).called(1);
      expect(find.text('LOGIN'), findsOneWidget);
    });
  });

  group('好友请求对话框接线', () {
    testWidgets('接受 → 备注询问跳过 → acceptFriend + 清 pending', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.addPendingRequest('bob');
      await pumpScreen(tester, socket);

      await tester.tap(find.byTooltip('待处理好友请求'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('接受').first);
      await tester.pumpAndSettle();
      // 阶段 J：接受时先询问是否添加备注 → 跳过
      await tester.tap(find.text('跳过'));
      await tester.pumpAndSettle();

      verify(() => socket.acceptFriend('bob')).called(1);
    });

    testWidgets('拒绝 → rejectFriend', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.addPendingRequest('bob');
      await pumpScreen(tester, socket);

      await tester.tap(find.byTooltip('待处理好友请求'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('拒绝'));
      await tester.pumpAndSettle();

      verify(() => socket.rejectFriend('bob')).called(1);
    });
  });

  group('文件请求对话框接线', () {
    testWidgets('私聊文件请求接受 → respondFileRequest', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.addFileRequest(FileRequest(
          messageId: 'f1', sender: 'bob', filename: 'a.zip', filesize: 10));
      await pumpScreen(tester, socket);

      await tester.tap(find.byTooltip('待处理文件请求'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('接受').first);
      await tester.pumpAndSettle();

      verify(() => socket.respondFileRequest('f1', 'bob', true)).called(1);
    });

    testWidgets('群文件请求拒绝 → respondGroupFileRequest', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.addFileRequest(FileRequest(
          messageId: 'f2',
          sender: 'bob',
          filename: 'b.zip',
          filesize: 10,
          groupId: 3));
      await pumpScreen(tester, socket);

      await tester.tap(find.byTooltip('待处理文件请求'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('拒绝'));
      await tester.pumpAndSettle();

      verify(() => socket.respondGroupFileRequest('f2', 3, false)).called(1);
    });
  });

  group('社交管理接线（阶段 F）', () {
    testWidgets('长按好友 → 确认删除 → deleteFriend + 状态移除', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      await pumpScreen(tester, socket);

      await tester.longPress(find.text('bob'));
      await tester.pumpAndSettle();
      expect(find.textContaining('确定删除好友 bob'), findsOneWidget);

      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      verify(() => socket.deleteFriend('bob')).called(1);
      // 状态移除发生在真实 SocketService.deleteFriend 内部（_socket 非空时），
      // mock 不触达，此处只验证网络接线。
    });

    testWidgets('长按群组 → 菜单 → 退出群组 → leaveGroup + 状态移除', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.addGroup(Group(id: 1, name: '开发组'));
      await pumpScreen(tester, socket);

      await tester.longPress(find.text('开发组 (ID:1)'));
      await tester.pumpAndSettle();
      expect(find.text('群成员'), findsOneWidget);
      // 打开菜单即预取成员
      verify(() => socket.fetchGroupMembers(1)).called(1);

      await tester.tap(find.text('退出群组'));
      await tester.pumpAndSettle();

      verify(() => socket.leaveGroup(1)).called(1);
      expect(state.groups.any((g) => g.id == 1), isFalse);
    });

    testWidgets('群组菜单 → 群成员入口 → 群信息对话框', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.addGroup(Group(id: 1, name: '开发组'));
      state.updateGroupMembers(1, ['alice', 'bob']);
      await pumpScreen(tester, socket);

      await tester.longPress(find.text('开发组 (ID:1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('群成员'));
      await tester.pumpAndSettle();

      expect(find.textContaining('群信息'), findsOneWidget);
      expect(find.text('bob'), findsOneWidget);
    });
  });

  group('历史加载接线（阶段 E）', () {
    testWidgets('选择空会话 → fetchHistory(to, null)', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      await pumpScreen(tester, socket);

      await tester.tap(find.text('bob'));
      await tester.pumpAndSettle();

      verify(() => socket.fetchHistory(
          to: 'bob',
          groupId: null,
          beforeMessageId: null,
          limit: 50)).called(1);
    });

    testWidgets('选择已有消息的会话不重复加载历史', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.addMessage(
          'bob', ChatMessage(sender: 'bob', content: '已有', messageId: 'm1'));
      await pumpScreen(tester, socket);

      await tester.tap(find.text('bob'));
      await tester.pumpAndSettle();

      verifyNever(() => socket.fetchHistory(
          to: any(named: 'to'),
          groupId: any(named: 'groupId'),
          beforeMessageId: any(named: 'beforeMessageId'),
          limit: any(named: 'limit')));
    });

    testWidgets('选择系统会话（服务器）不触发历史加载', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.addMessage(
          '服务器',
          ChatMessage(
              sender: '服务器', content: '公告', messageId: 's1', type: 'system'));
      await pumpScreen(tester, socket);

      await tester.tap(find.text('系统消息'));
      await tester.pumpAndSettle();

      verifyNever(() => socket.fetchHistory(
          to: any(named: 'to'),
          groupId: any(named: 'groupId'),
          beforeMessageId: any(named: 'beforeMessageId'),
          limit: any(named: 'limit')));
    });
  });

  group('管理面板接线', () {
    testWidgets('管理员点查看所有用户 → adminCommand(list_users)', (tester) async {
      final socket = buildService();
      state.setLoggedIn('admin', true);
      await pumpScreen(tester, socket);

      await tester.tap(find.byTooltip('管理面板'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看所有用户'));
      await tester.pumpAndSettle();

      verify(() => socket.adminCommand('list_users')).called(1);
    });
  });

  group('空状态', () {
    testWidgets('未选择会话显示占位文案', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      await pumpScreen(tester, socket);
      expect(find.text('选择一个会话开始聊天'), findsOneWidget);
    });
  });
}
