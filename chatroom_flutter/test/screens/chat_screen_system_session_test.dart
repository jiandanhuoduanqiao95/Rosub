// ============================================================
// chat_screen.dart 系统会话只读回归 —— 用户实测缺陷回归锁定（TDD：修复前预期红）
// ============================================================
// 缺陷（2026-08-19 用户实测发现）：
//   用户在查看系统消息会话（'服务器'）后再切换到其他聊天会话时，
//   弹出 "错误：错误：服务器 不是您的好友"（SnackBar）。
//
// 根因：K2 草稿同步未对只读系统会话守门——
//   ① 从 '服务器' 切走时 _flushDraft() 无条件保存当前会话草稿
//      → 发送 set_draft {peer_key='服务器'} → 服务端 _validate_peer_key
//      校验非好友 → error "错误：服务器 不是您的好友"；
//      （客户端再补 "错误: " 前缀 → 弹窗出现"错误：错误："双重前缀）
//   ② 切到 '服务器' 时输入框文本变化触发 _onInputChanged → 800ms 防抖后
//      同样发送 set_draft {peer_key='服务器'}。
//   ③ 系统会话中退出登录：_logout 前 _flushDraft() 同样泄漏。
//
// 契约（修复后须满足）：
//   - '服务器' 会话不产生任何 set_draft 请求（含立即同步与防抖路径）
//   - '服务器' 会话不产生 fetch_history / search_history 等会话请求（守门回归）
//   - '服务器' 会话不产生本地会话元数据（草稿状态不写入）
//   - 好友会话的草稿保存语义不受影响（K2 回归保护）
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
  when(() => s.sendChat(any(), any())).thenAnswer((_) async => true);
  when(() => s.sendGroupChat(any(), any())).thenAnswer((_) async => true);
  when(() => s.fetchHistory(
      to: any(named: 'to'),
      groupId: any(named: 'groupId'),
      beforeMessageId: any(named: 'beforeMessageId'),
      limit: any(named: 'limit'))).thenAnswer((_) async {});
  when(() => s.pinConversation(any())).thenAnswer((_) async {});
  when(() => s.unpinConversation(any())).thenAnswer((_) async {});
  when(() => s.muteConversation(any(), any())).thenAnswer((_) async {});
  when(() => s.saveConversationDraft(any(), any())).thenAnswer((_) async {});
  when(() => s.replyMessage(any(), any(), any())).thenAnswer((_) async {});
  when(() => s.forwardMessage(any(), any())).thenAnswer((_) async {});
  when(() => s.addReaction(any(), any(), any())).thenAnswer((_) async {});
  when(() => s.removeReaction(any(), any(), any())).thenAnswer((_) async {});
  when(() => s.recallMessage(any(), any())).thenAnswer((_) async {});
  when(() => s.searchHistory(any(),
      to: any(named: 'to'),
      groupId: any(named: 'groupId'),
      limit: any(named: 'limit'))).thenAnswer((_) async {});
  return s;
}

Future<void> pumpScreen(WidgetTester tester, MockSocketService socket) async {
  await tester.pumpWidget(MaterialApp(
    home: ChatScreen(socketService: socket),
    routes: {'/login': (_) => const Scaffold(body: Text('LOGIN'))},
  ));
  await tester.pump();
}

/// 预置场景：alice 登录、bob 为好友、系统会话有一条公告（侧边栏出现"系统消息"），
/// 当前选中 bob 会话。
void seedSystemAndFriend(MockSocketService socket) {
  state.setLoggedIn('alice', false);
  state.setFriends(['bob']);
  state.addMessage(
    '服务器',
    ChatMessage(
      sender: '[系统公告]',
      content: '管理员公告',
      type: 'system',
      messageId: 'sys-1',
      status: 'delivered',
    ),
  );
  state.selectChat('bob');
}

LogicalKeyboardKey _charKey(String ch) {
  if (ch == ' ') return LogicalKeyboardKey.space;
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

/// 向底部输入栏（RawTextField）键入 ASCII 文本（同 chat_screen_stage_k_test 惯例）
Future<void> typeIntoInput(WidgetTester tester, String text) async {
  final target = find.byType(RawTextField).last;
  await tester.tap(target);
  await tester.pump();
  for (final ch in text.split('')) {
    await tester.sendKeyEvent(_charKey(ch));
    await tester.pump();
  }
}

void main() {
  setUp(resetState);

  group('系统会话只读 —— 不向服务端泄漏会话请求（P-46 缺陷回归锁定）', () {
    testWidgets('查看系统消息后切到好友会话：不保存"服务器"草稿（缺陷主路径）',
        (tester) async {
      final socket = buildService();
      seedSystemAndFriend(socket);
      await pumpScreen(tester, socket);

      // 先查看系统消息会话（侧边栏"系统消息"tile）
      await tester.tap(find.text('系统消息'));
      await tester.pumpAndSettle();
      expect(state.currentChat, '服务器');

      // 再查看其他聊天信息（切回 bob）
      await tester.tap(find.text('bob'));
      await tester.pumpAndSettle();
      expect(state.currentChat, 'bob');

      // 缺陷锁定：切走时 _flushDraft 不得以 '服务器' 为 peer_key 同步草稿
      verifyNever(() => socket.saveConversationDraft('服务器', any()));
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('好友会话切到系统会话：输入框文本变化不触发"服务器"草稿防抖保存',
        (tester) async {
      final socket = buildService();
      seedSystemAndFriend(socket);
      await pumpScreen(tester, socket);

      // bob 会话输入文本（输入框持有文本，切到系统会话时 controller 被清空，
      // 触发 onInputChanged → 防抖路径不得以 '服务器' 为 peer_key 同步草稿）
      await typeIntoInput(tester, 'hi bob');
      await tester.pump();

      await tester.tap(find.text('系统消息'));
      await tester.pumpAndSettle();
      expect(state.currentChat, '服务器');

      // 等待防抖窗口（800ms）过后再断言：不得出现 '服务器' 草稿保存
      await tester.pump(const Duration(milliseconds: 900));
      verifyNever(() => socket.saveConversationDraft('服务器', any()));
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('系统会话中直接退出登录：退出前同步不保存"服务器"草稿', (tester) async {
      final socket = buildService();
      seedSystemAndFriend(socket);
      await pumpScreen(tester, socket);

      await tester.tap(find.text('系统消息'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('退出'));
      await tester.pumpAndSettle();

      verifyNever(() => socket.saveConversationDraft('服务器', any()));
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('切换/选中系统会话不触发 fetch_history / search_history 等会话请求（守门回归）',
        (tester) async {
      final socket = buildService();
      seedSystemAndFriend(socket);
      await pumpScreen(tester, socket);

      await tester.tap(find.text('系统消息'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 900));

      verifyNever(() => socket.fetchHistory(
          to: any(named: 'to'),
          groupId: any(named: 'groupId'),
          beforeMessageId: any(named: 'beforeMessageId'),
          limit: any(named: 'limit')));
      verifyNever(() => socket.searchHistory(any(), to: any(named: 'to')));
      expect(find.text('系统消息 为只读会话'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('系统会话不产生本地会话元数据（草稿状态不写入）', (tester) async {
      final socket = buildService();
      seedSystemAndFriend(socket);
      await pumpScreen(tester, socket);

      await tester.tap(find.text('系统消息'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 900));
      await tester.tap(find.text('bob'));
      await tester.pumpAndSettle();

      expect(state.conversationMetaOf('服务器'), isNull,
          reason: '系统会话不得产生会话元数据（draftOf 恒空）');
      expect(state.draftOf('服务器'), '');
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('切换时好友会话草稿仍正常保存（K2 回归保护）', (tester) async {
      final socket = buildService();
      seedSystemAndFriend(socket);
      await pumpScreen(tester, socket);

      // bob 会话输入草稿 → 切到系统消息 → 再切回 bob
      await typeIntoInput(tester, 'hi bob');
      await tester.pump();
      await tester.tap(find.text('系统消息'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('bob'));
      await tester.pumpAndSettle();

      // 好友草稿同步语义不受影响：bob 草稿被保存（切换 flush + 恢复时防抖均合法）且本地状态保留
      verify(() => socket.saveConversationDraft('bob', 'hi bob')).called(
          greaterThan(0));
      expect(state.draftOf('bob'), 'hi bob');
      // 草稿恢复回输入栏
      expect(find.textContaining('hi bob', findRichText: true), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
