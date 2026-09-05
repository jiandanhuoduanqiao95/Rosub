// ============================================================
// chat_view.dart 消息搜索 UI 测试（阶段 H5）
// ============================================================
// 契约（已实现）：
//   ChatView 新增参数：isSearchMode / searchQuery / onSearch / onSearchExit
//   - 非搜索模式标题栏显示搜索按钮（tooltip '搜索消息'）：
//       私聊 / 群聊会话显示（to / group_id 范围，见 H5 服务端契约）；
//       系统消息会话（chatKey == '服务器'，只读）不显示
//   - 点击搜索按钮 → 标题栏展开搜索输入栏：
//       RawTextField(key: ValueKey('search_field'), hint '搜索历史消息...')
//       + 确认按钮（tooltip '搜索'）+ 关闭按钮（tooltip '关闭搜索'）
//   - 输入关键字后 Enter 或点确认 → onSearch(keyword)；空关键字不回调
//   - 关闭按钮 → 收起输入栏，不触发任何回调
//   - isSearchMode=true：
//       * 标题栏显示返回按钮（tooltip '退出搜索'）+ '搜索：<searchQuery>'
//       * 隐藏底部输入栏（无发送/文件按钮）
//       * 消息列表展示传入的搜索结果；结果为空显示 '无搜索结果'
//   - 点击返回 → onSearchExit
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/widgets/chat_view.dart';

Widget wrap(Widget child) => MaterialApp(
    home: Scaffold(body: SizedBox(width: 600, height: 800, child: child)));

ChatMessage resultMsg(String content, String id) => ChatMessage(
      sender: 'bob',
      content: content,
      messageId: id,
      type: 'chat',
      isHistory: true,
      status: 'delivered',
    );

Future<void> pumpChatView(
  WidgetTester tester, {
  required ChatView chatView,
}) async {
  await tester.pumpWidget(wrap(chatView));
  await tester.pump();
}

void main() {
  group('搜索入口（非搜索模式）', () {
    testWidgets('私聊会话标题栏显示搜索按钮', (tester) async {
      await pumpChatView(tester, chatView: ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: const [],
        username: 'alice',
        inputCtrl: TextEditingController(),
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
        onSearch: (_) {},
        onSearchExit: () {},
      ));

      expect(find.byTooltip('搜索消息'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('系统会话（服务器）不显示搜索按钮（只读会话）', (tester) async {
      await pumpChatView(tester, chatView: ChatView(
        chatKey: '服务器',
        chatTitle: '系统消息',
        messages: const [],
        username: 'alice',
        inputCtrl: TextEditingController(),
        canSend: false,
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
        onSearch: (_) {},
        onSearchExit: () {},
      ));

      expect(find.byTooltip('搜索消息'), findsNothing);
    });

    testWidgets('群聊会话显示搜索按钮（group_id 范围）', (tester) async {
      await pumpChatView(tester, chatView: ChatView(
        chatKey: 'group_1',
        chatTitle: '开发组 (ID:1)',
        messages: const [],
        username: 'alice',
        inputCtrl: TextEditingController(),
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
        onSearch: (_) {},
        onSearchExit: () {},
      ));

      expect(find.byTooltip('搜索消息'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('搜索输入栏（展开）', () {
    Future<void> openSearchBar(WidgetTester tester) async {
      await tester.tap(find.byTooltip('搜索消息'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    }

    testWidgets('点击搜索按钮 → 展开搜索输入栏', (tester) async {
      await pumpChatView(tester, chatView: ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: const [],
        username: 'alice',
        inputCtrl: TextEditingController(),
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
        onSearch: (_) {},
        onSearchExit: () {},
      ));

      expect(find.byKey(const ValueKey('search_field')), findsNothing);
      await openSearchBar(tester);

      expect(find.byKey(const ValueKey('search_field')), findsOneWidget);
      expect(find.text('搜索历史消息...'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('输入关键字 + Enter → onSearch(keyword)', (tester) async {
      final submitted = <String>[];
      await pumpChatView(tester, chatView: ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: const [],
        username: 'alice',
        inputCtrl: TextEditingController(),
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
        onSearch: submitted.add,
        onSearchExit: () {},
      ));
      await openSearchBar(tester);

      await tester.tap(find.byKey(const ValueKey('search_field')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(submitted, ['fl']);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('输入关键字 + 点击确认按钮 → onSearch(keyword)', (tester) async {
      final submitted = <String>[];
      await pumpChatView(tester, chatView: ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: const [],
        username: 'alice',
        inputCtrl: TextEditingController(),
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
        onSearch: submitted.add,
        onSearchExit: () {},
      ));
      await openSearchBar(tester);

      await tester.tap(find.byKey(const ValueKey('search_field')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.pump();
      await tester.tap(find.byTooltip('搜索'));
      await tester.pump();

      expect(submitted, ['h']);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('空关键字提交 → 不触发 onSearch', (tester) async {
      int calls = 0;
      await pumpChatView(tester, chatView: ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: const [],
        username: 'alice',
        inputCtrl: TextEditingController(),
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
        onSearch: (_) => calls++,
        onSearchExit: () {},
      ));
      await openSearchBar(tester);

      await tester.tap(find.byKey(const ValueKey('search_field')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.tap(find.byTooltip('搜索'));
      await tester.pump();

      expect(calls, 0);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('关闭按钮 → 收起输入栏，不触发任何回调', (tester) async {
      int searchCalls = 0;
      int exitCalls = 0;
      await pumpChatView(tester, chatView: ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: const [],
        username: 'alice',
        inputCtrl: TextEditingController(),
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
        onSearch: (_) => searchCalls++,
        onSearchExit: () => exitCalls++,
      ));
      await openSearchBar(tester);
      expect(find.byKey(const ValueKey('search_field')), findsOneWidget);

      await tester.tap(find.byTooltip('关闭搜索'));
      await tester.pump();

      expect(find.byKey(const ValueKey('search_field')), findsNothing);
      expect(searchCalls, 0);
      expect(exitCalls, 0);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('输入栏展开时再次点击搜索按钮 → 无异常（幂等）', (tester) async {
      await pumpChatView(tester, chatView: ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: const [],
        username: 'alice',
        inputCtrl: TextEditingController(),
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
        onSearch: (_) {},
        onSearchExit: () {},
      ));
      await openSearchBar(tester);
      await tester.tap(find.byTooltip('搜索消息'));
      await tester.pump();

      expect(find.byKey(const ValueKey('search_field')), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('搜索模式（isSearchMode=true）', () {
    testWidgets('标题栏显示返回按钮与"搜索：<query>"', (tester) async {
      await pumpChatView(tester, chatView: ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: [resultMsg('包含 flutter 的消息', 's1')],
        username: 'alice',
        inputCtrl: TextEditingController(),
        isSearchMode: true,
        searchQuery: 'flutter',
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
        onSearch: (_) {},
        onSearchExit: () {},
      ));

      expect(find.byTooltip('退出搜索'), findsOneWidget);
      expect(find.text('搜索：flutter'), findsOneWidget);
    });

    testWidgets('搜索模式隐藏底部输入栏（无发送/文件按钮）', (tester) async {
      await pumpChatView(tester, chatView: ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: [resultMsg('x', 's1')],
        username: 'alice',
        inputCtrl: TextEditingController(),
        canSend: true,
        isSearchMode: true,
        searchQuery: 'flutter',
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
        onSearch: (_) {},
        onSearchExit: () {},
      ));

      expect(find.byTooltip('发送'), findsNothing);
      expect(find.byTooltip('发送文件'), findsNothing);
    });

    testWidgets('消息列表展示搜索结果', (tester) async {
      await pumpChatView(tester, chatView: ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: [
          resultMsg('第一条匹配', 's1'),
          resultMsg('第二条匹配', 's2'),
        ],
        username: 'alice',
        inputCtrl: TextEditingController(),
        isSearchMode: true,
        searchQuery: 'flutter',
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
        onSearch: (_) {},
        onSearchExit: () {},
      ));

      expect(find.text('第一条匹配'), findsOneWidget);
      expect(find.text('第二条匹配'), findsOneWidget);
    });

    testWidgets('搜索模式结果为空 → 显示"无搜索结果"占位', (tester) async {
      await pumpChatView(tester, chatView: ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: const [],
        username: 'alice',
        inputCtrl: TextEditingController(),
        isSearchMode: true,
        searchQuery: 'flutter',
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
        onSearch: (_) {},
        onSearchExit: () {},
      ));

      expect(find.text('无搜索结果'), findsOneWidget);
    });

    testWidgets('点击返回 → onSearchExit 回调', (tester) async {
      int exitCalls = 0;
      await pumpChatView(tester, chatView: ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: [resultMsg('x', 's1')],
        username: 'alice',
        inputCtrl: TextEditingController(),
        isSearchMode: true,
        searchQuery: 'flutter',
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
        onSearch: (_) {},
        onSearchExit: () => exitCalls++,
      ));

      await tester.tap(find.byTooltip('退出搜索'));
      await tester.pump();

      expect(exitCalls, 1);
    });

    testWidgets('搜索模式消息支持撤回回调（与普通模式一致）', (tester) async {
      final recalled = <String>[];
      await pumpChatView(tester, chatView: ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: [
          ChatMessage(
            sender: 'alice',
            content: '自己发的匹配',
            messageId: 's1',
            type: 'chat',
            isHistory: true,
            status: 'delivered',
          ),
        ],
        username: 'alice',
        inputCtrl: TextEditingController(),
        isSearchMode: true,
        searchQuery: 'flutter',
        onSend: () {},
        onSendFile: () {},
        onRecall: recalled.add,
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
        onSearch: (_) {},
        onSearchExit: () {},
      ));

      await tester.longPress(find.text('自己发的匹配'));
      await tester.pump();
      expect(recalled, ['s1']);
    });
  });
}
