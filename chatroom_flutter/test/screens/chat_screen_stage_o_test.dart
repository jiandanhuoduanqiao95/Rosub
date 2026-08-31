// ============================================================
// chat_screen.dart 阶段 O —— 群组与消息增强接线契约（TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 O 的 ChatScreen 装配层：
//   - O1（展示接线）：选中群会话时把 Group.announcement 传入 ChatView
//     公告横幅（数据源 list_groups）
//   - O4（入口接线）：输入行"快捷回复"入口 → showQuickReplyPanel，
//     点击短语即发送到当前会话（sendChat/sendGroupChat）
//   - O5（入口接线）：输入行"定时发送"入口 → showScheduleMessageDialog，
//     确定后 scheduleChat/scheduleGroupChat 到当前会话
//   - O6（退出接线）：退出登录改调 SessionStore.clearCurrent——
//     清当前凭据回登录页，但**保留账号列表**（可快速切换）
//
// 实现前：本文件引用尚未实现的接线/行为，编译失败或用例红，属 TDD 红。
// 实现后：全部转绿。
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/screens/chat_screen.dart';
import 'package:chatroom_flutter/screens/login_screen.dart';
import 'package:chatroom_flutter/services/session_store.dart';
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
  when(() => s.disconnect()).thenAnswer((_) {});
  when(() => s.sendChat(any(), any())).thenAnswer((_) async => true);
  when(() => s.sendGroupChat(any(), any())).thenAnswer((_) async => true);
  when(() => s.scheduleChat(any(), any(), any())).thenAnswer((_) async {});
  when(() => s.scheduleGroupChat(any(), any(), any())).thenAnswer((_) async {});
  when(() => s.fetchGroupAnnouncements(any())).thenAnswer((_) async {});
  when(() => s.deleteGroupAnnouncement(any(), any())).thenAnswer((_) async {});
  when(() => s.unpinGroupMessage(any(), messageId: any(named: 'messageId')))
      .thenAnswer((_) async {});
  registerFallbackValue(DateTime(2026, 9, 1));
  return s;
}

Future<void> pumpChat(WidgetTester tester, SocketService socket) async {
  await tester.pumpWidget(MaterialApp(
    home: ChatScreen(socketService: socket),
    routes: {'/login': (_) => const LoginScreen()},
  ));
  await tester.pump();
}

void main() {
  setUp(() {
    resetState();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('O1 —— 群公告横幅接线（多公告并存）', () {
    testWidgets('选中群会话 → 拉取公告历史并显示横幅（groupAnnouncements）', (tester) async {
      state.setLoggedIn('alice', false);
      state.setGroups([
        Group(id: 1, name: '开发组', owner: 'alice'),
      ]);
      state.setGroupAnnouncements([
        const GroupAnnouncement(
            messageId: 'a-1', sender: 'alice', content: '周五 18:00 团建'),
        const GroupAnnouncement(
            messageId: 'a-2', sender: 'alice', content: '周日线上会议'),
      ]);
      state.selectChat('group_1');
      final socket = buildService();
      when(() => socket.fetchGroupAnnouncements(any()))
          .thenAnswer((_) async {});
      await pumpChat(tester, socket);

      // 多公告并存：逐条显示
      expect(find.textContaining('📢'), findsNWidgets(2));
      expect(find.textContaining('周五 18:00 团建'), findsOneWidget);
      expect(find.textContaining('周日线上会议'), findsOneWidget);
      // 选中群会话即拉取公告历史（横幅数据源）
      verify(() => socket.fetchGroupAnnouncements(1))
          .called(greaterThanOrEqualTo(1));
    });

    testWidgets('无公告的群 → 不显示横幅；私聊会话不显示横幅', (tester) async {
      state.setLoggedIn('alice', false);
      state.setGroups([
        Group(id: 1, name: '开发组', owner: 'alice'),
      ]);
      state.selectChat('group_1');
      final socket = buildService();
      when(() => socket.fetchGroupAnnouncements(any()))
          .thenAnswer((_) async {});
      await pumpChat(tester, socket);
      expect(find.textContaining('📢'), findsNothing);

      state.selectChat('bob');
      await tester.pump();
      expect(find.textContaining('📢'), findsNothing);
    });
  });

  group('O4 —— 快捷回复接线', () {
    testWidgets('私聊会话：点击短语"收到" → sendChat 发送该短语', (tester) async {
      state.setLoggedIn('alice', false);
      state.selectChat('bob');
      final socket = buildService();
      await pumpChat(tester, socket);

      await tester.tap(find.byTooltip('快捷回复'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('收到'));
      await tester.pumpAndSettle();

      verify(() => socket.sendChat('bob', '收到')).called(1);
    });

    testWidgets('群会话：点击短语 → sendGroupChat 发送到当前群', (tester) async {
      state.setLoggedIn('alice', false);
      state.setGroups([Group(id: 1, name: '开发组', owner: 'alice')]);
      state.selectChat('group_1');
      final socket = buildService();
      await pumpChat(tester, socket);

      await tester.tap(find.byTooltip('快捷回复'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('好的'));
      await tester.pumpAndSettle();

      verify(() => socket.sendGroupChat(1, '好的')).called(1);
      verifyNever(() => socket.sendChat(any(), any()));
    });
  });

  group('O5 —— 定时发送接线', () {
    testWidgets('私聊会话：定时对话框确定 → scheduleChat 到当前会话', (tester) async {
      state.setLoggedIn('alice', false);
      state.selectChat('bob');
      final socket = buildService();
      await pumpChat(tester, socket);

      await tester.tap(find.byTooltip('定时发送'));
      await tester.pumpAndSettle();
      // 用户反馈 #7：定时入口两选项（定时设定 / 取消定时设定）
      expect(find.text('定时设定'), findsOneWidget);
      expect(find.text('取消定时设定'), findsOneWidget);

      await tester.tap(find.text('定时设定'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      // RawTextField 不走系统 EditableText：文本经键盘事件注入（ASCII）
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(RawTextField),
      ));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.pump();
      await tester.tap(find.text('定时发送'));
      await tester.pumpAndSettle();

      final captured =
          verify(() => socket.scheduleChat('bob', 'hi', captureAny()))
            ..called(1);
      final at = captured.captured.single as DateTime;
      expect(at.isAfter(DateTime.now()), isTrue, reason: '定时时刻晚于当前');
    });

    testWidgets('群会话：定时对话框确定 → scheduleGroupChat 到当前群', (tester) async {
      state.setLoggedIn('alice', false);
      state.setGroups([Group(id: 2, name: '定时群', owner: 'alice')]);
      state.selectChat('group_2');
      final socket = buildService();
      await pumpChat(tester, socket);

      await tester.tap(find.byTooltip('定时发送'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('定时设定'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(RawTextField),
      ));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.pump();
      await tester.tap(find.text('定时发送'));
      await tester.pumpAndSettle();

      final captured =
          verify(() => socket.scheduleGroupChat(2, 'hi', captureAny()))
            ..called(1);
      expect((captured.captured.single as DateTime).isAfter(DateTime.now()),
          isTrue);
    });
  });

  group('O6 —— 退出登录保留账号列表', () {
    testWidgets('退出登录 → 清当前凭据回登录页，账号列表保留', (tester) async {
      await SessionStore.saveAccount(
          const StoredSession(username: 'alice', password: 'pw1'));
      await SessionStore.saveAccount(
          const StoredSession(username: 'bob', password: 'pw2'));

      state.setLoggedIn('alice', false);
      final socket = buildService();
      await pumpChat(tester, socket);

      await tester.tap(find.byTooltip('退出'));
      await tester.pumpAndSettle();

      verify(() => socket.disconnect()).called(1);
      // 回到登录页且账号列表保留（可快速切换）
      expect(find.byType(LoginScreen), findsOneWidget);
      final accounts = await SessionStore.loadAccounts();
      expect(accounts.map((a) => a.username).toSet(), {'alice', 'bob'},
          reason: '退出登录不清账号列表（O6 多账号切换语义）');
      expect(await SessionStore.load(), isNull, reason: '当前凭据已清除');
    });
  });
}
