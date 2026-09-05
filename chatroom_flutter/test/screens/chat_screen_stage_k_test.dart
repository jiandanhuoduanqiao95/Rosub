// ============================================================
// chat_screen.dart 阶段 K —— 会话体验接线契约（已实现，全部转绿）
// ============================================================
// 覆盖 P1-11~P1-14 / P1-2 / P1-3 / P1-4（《软件开发文档4.1.0.md》§11 阶段 K / §13.3）：
//   - K1 置顶接线：好友/群组菜单 → pinConversation/unpinConversation
//     + Sidebar isPinned（置顶分区渲染）
//   - K2 草稿接线：切换会话保存/恢复草稿、防抖自动保存（输入停顿 800ms 同步）、
//     退出前立即同步、发送后清除草稿；A 会话文本不泄漏到 B 会话（bug 级回归）
//   - K3 静音接线：好友/群组菜单 → muteConversation + Sidebar isMuted（静音标识）；
//     设置入口打开设置对话框
//   - K5 消息操作接线：引用回复/转发/表情回应/仅我删除 → socketService/状态调用
//
// 用户决策修订：P1-1 编辑、P1-15 通知中心已移除。
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
  when(() => s.fetchGroupAnnouncements(any())).thenAnswer((_) async {});
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
  return s;
}

Future<void> pumpScreen(WidgetTester tester, MockSocketService socket) async {
  await tester.pumpWidget(MaterialApp(
    home: ChatScreen(socketService: socket),
    routes: {'/login': (_) => const Scaffold(body: Text('LOGIN'))},
  ));
  await tester.pump();
}

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
/// 取 .last：对话框字段位于底部输入栏之后。
Future<void> typeInto(WidgetTester tester, String text) async {
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

  group('K1 —— 会话置顶接线', () {
    testWidgets('好友菜单置顶 → pinConversation + 置顶分区渲染', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');
      await pumpScreen(tester, socket);

      await tester.longPress(find.text('bob'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('置顶'));
      await tester.pumpAndSettle();

      verify(() => socket.pinConversation('bob')).called(1);
      expect(state.isPinned('bob'), isTrue);
      expect(find.text('置顶'), findsOneWidget, reason: '侧边栏应出现置顶分区');
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('已置顶好友菜单取消置顶 → unpinConversation', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.setConversationPinned('bob', true);
      state.selectChat('bob');
      await pumpScreen(tester, socket);

      await tester.longPress(find.text('bob'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消置顶'));
      await tester.pumpAndSettle();

      verify(() => socket.unpinConversation('bob')).called(1);
      expect(state.isPinned('bob'), isFalse);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('群组菜单置顶 → pinConversation(group_1)', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.addGroup(Group(id: 1, name: '开发组'));
      state.selectChat('group_1');
      when(() => socket.fetchGroupMembers(any())).thenAnswer((_) async {});
      await pumpScreen(tester, socket);

      // 侧边栏 tile（第一个）与聊天标题文本相同，取 .first 长按侧边栏
      await tester.longPress(find.text('开发组 (ID:1)').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('置顶'));
      await tester.pumpAndSettle();

      verify(() => socket.pinConversation('group_1')).called(1);
      expect(state.isPinned('group_1'), isTrue);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('K2 —— 逐会话草稿接线（跨会话泄漏回归锁定）', () {
    testWidgets('A 会话输入切换到 B 会话：输入栏清空且草稿保存', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob', 'carol']);
      state.selectChat('bob');
      await pumpScreen(tester, socket);

      await typeInto(tester, 'hi bob');
      await tester.pumpAndSettle();
      // 切换到 carol
      await tester.tap(find.text('carol'));
      await tester.pumpAndSettle();

      verify(() => socket.saveConversationDraft('bob', 'hi bob')).called(1);
      expect(state.draftOf('bob'), 'hi bob');
      expect(find.text('hi bob'), findsNothing, reason: 'A 会话文本不泄漏到 B 会话');
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('切回 A 会话恢复草稿', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob', 'carol']);
      state.selectChat('bob');
      await pumpScreen(tester, socket);

      await typeInto(tester, 'hi bob');
      await tester.pumpAndSettle();
      await tester.tap(find.text('carol'));
      await tester.pumpAndSettle();
      expect(find.text('hi bob'), findsNothing);

      await tester.tap(find.text('bob'));
      await tester.pumpAndSettle();
      expect(find.textContaining('hi bob', findRichText: true), findsOneWidget,
          reason: '草稿应恢复到输入栏（RawTextField 为 RichText 渲染，含光标符）');
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('登录推送的草稿在选择会话时恢复（draftOf → 输入栏）', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.setConversationDraft('bob', '服务端草稿');
      await pumpScreen(tester, socket);

      await tester.tap(find.text('bob'));
      await tester.pumpAndSettle();
      expect(find.textContaining('服务端草稿', findRichText: true), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('发送消息后草稿清除', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');
      await pumpScreen(tester, socket);

      await typeInto(tester, 'hello');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('发送'));
      await tester.pump();

      verify(() => socket.sendChat('bob', 'hello')).called(1);
      expect(state.draftOf('bob'), '');
      verify(() => socket.saveConversationDraft('bob', '')).called(1);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('空输入切换会话不误清草稿（保留既有草稿）', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob', 'carol']);
      state.selectChat('bob');
      state.setConversationDraft('carol', 'carol 的草稿');
      await pumpScreen(tester, socket);

      // 未输入任何内容直接切换
      await tester.tap(find.text('carol'));
      await tester.pumpAndSettle();
      expect(
          find.textContaining('carol 的草稿', findRichText: true), findsOneWidget,
          reason: 'carol 草稿应恢复显示（RawTextField 为 RichText 渲染，含光标符）');

      // 切回 bob：bob 无草稿，输入栏为空
      await tester.tap(find.text('bob'));
      await tester.pumpAndSettle();
      expect(find.text('carol 的草稿'), findsNothing, reason: '草稿不跨会话泄漏');
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('输入停顿后草稿自动保存（防抖，不切换会话也保存）', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');
      await pumpScreen(tester, socket);

      // 输入后不切换会话，仅等待防抖触发
      await typeInto(tester, 'autosave');
      verifyNever(() => socket.saveConversationDraft(any(), any()));
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pump();
      verify(() => socket.saveConversationDraft('bob', 'autosave')).called(1);
      expect(state.draftOf('bob'), 'autosave');
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('退出登录前立即同步当前输入为草稿（防抖未触发也不丢失）',
        (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');
      await pumpScreen(tester, socket);

      await typeInto(tester, 'exitdraft');
      // 防抖尚未触发（<800ms）直接退出
      await tester.tap(find.byTooltip('退出'));
      await tester.pump();
      await tester.pumpAndSettle();

      verify(() => socket.saveConversationDraft('bob', 'exitdraft')).called(1);
      expect(state.draftOf('bob'), 'exitdraft');
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('K3 —— 静音与设置接线', () {
    testWidgets('好友菜单静音 → muteConversation(bob, true)', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');
      await pumpScreen(tester, socket);

      await tester.longPress(find.text('bob'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('静音'));
      await tester.pumpAndSettle();

      verify(() => socket.muteConversation('bob', true)).called(1);
      expect(state.isMuted('bob'), isTrue);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('已静音好友取消静音 → muteConversation(bob, false)', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.setConversationMuted('bob', true);
      state.selectChat('bob');
      await pumpScreen(tester, socket);

      await tester.longPress(find.text('bob'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消静音'));
      await tester.pumpAndSettle();

      verify(() => socket.muteConversation('bob', false)).called(1);
      expect(state.isMuted('bob'), isFalse);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('AppBar 设置按钮打开设置对话框', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      await pumpScreen(tester, socket);

      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.text('提示音'), findsOneWidget);
      expect(find.text('免打扰'), findsOneWidget);
    });
  });

  group('K5 —— 消息操作接线', () {
    Future<void> seedOwnMessage(
        WidgetTester tester, MockSocketService socket) async {
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.addMessage(
        'bob',
        ChatMessage(sender: 'alice', content: '自己的消息', messageId: 'm1'),
      );
      state.selectChat('bob');
      await pumpScreen(tester, socket);
      await tester.pump();
    }

    testWidgets('长按消息 → 引用回复 → 输入 → replyMessage', (tester) async {
      final socket = buildService();
      await seedOwnMessage(tester, socket);

      await tester.longPress(find.text('自己的消息'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('引用回复'));
      await tester.pumpAndSettle();

      // 仅 ASCII 键入（RawTextField 按键状态机不支持中文键位映射）
      await typeInto(tester, 'rback');
      await tester.tap(find.text('发送'));
      await tester.pumpAndSettle();

      verify(() => socket.replyMessage('m1', 'rback', 'bob')).called(1);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('长按消息 → 转发 → 选择目标 → forwardMessage', (tester) async {
      final socket = buildService();
      state.setLoggedIn('alice', false);
      state.setFriends(['bob', 'carol']);
      state.addMessage(
        'bob',
        ChatMessage(sender: 'alice', content: '自己的消息', messageId: 'm1'),
      );
      state.selectChat('bob');
      await pumpScreen(tester, socket);
      await tester.pump();

      await tester.longPress(find.text('自己的消息'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('转发'));
      await tester.pumpAndSettle();
      // 目标选择对话框：选择 carol
      await tester.tap(find.text('carol').last);
      await tester.pumpAndSettle();

      verify(() => socket.forwardMessage('m1', 'carol')).called(1);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('长按消息 → 表情回应 → 👍 → addReaction', (tester) async {
      final socket = buildService();
      await seedOwnMessage(tester, socket);

      await tester.longPress(find.text('自己的消息'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('表情回应'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('👍').last);
      await tester.pumpAndSettle();

      verify(() => socket.addReaction('m1', '👍', 'bob')).called(1);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('长按消息 → 仅我删除 → 本地移除（不触网）', (tester) async {
      final socket = buildService();
      await seedOwnMessage(tester, socket);
      expect(find.text('自己的消息'), findsOneWidget);

      await tester.longPress(find.text('自己的消息'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('仅我删除'));
      await tester.pumpAndSettle();

      expect(find.text('自己的消息'), findsNothing, reason: '仅我删除：从自己界面移除');
      expect(state.messageById('m1'), isNull);
      expect(state.getMessages('bob'), isEmpty);
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
