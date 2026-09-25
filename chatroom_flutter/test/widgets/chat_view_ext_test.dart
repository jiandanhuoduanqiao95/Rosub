// ============================================================
// chat_view.dart 扩展攻击性测试（测试强化新增）
// ============================================================
// 覆盖既有测试未触达的分支：
//   - canSend=true 输入栏的发送/文件按钮与 Enter 提交
//   - 传输进度百分比文本
//   - 已撤回消息不可再撤回（onRecall=null）
//   - 时间格式化（同日 HH:MM / 隔日 MM-DD HH:MM）
//   - 大量消息 / 超长文本渲染
//   - 上滑加载历史的滚动触发与加载指示器
// ============================================================

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/widgets/chat_view.dart';
import 'package:chatroom_flutter/widgets/raw_text_field.dart';

Widget wrap(Widget child) => MaterialApp(
    home: Scaffold(body: SizedBox(width: 600, height: 800, child: child)));

ChatMessage msg(String sender, String content, String id,
        {String status = 'sent',
        String? type,
        String? filename,
        DateTime? timestamp}) =>
    ChatMessage(
      sender: sender,
      content: content,
      messageId: id,
      status: status,
      type: type ?? 'chat',
      filename: filename,
      timestamp: timestamp,
    );

void main() {
  group('输入栏（canSend=true）', () {
    testWidgets('显示输入栏、发送按钮与文件按钮，点击触发回调', (tester) async {
      int sendCalls = 0;
      int fileCalls = 0;
      await tester.pumpWidget(wrap(ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: const [],
        username: 'alice',
        inputCtrl: TextEditingController(),
        canSend: true,
        onSend: () => sendCalls++,
        onSendFile: () => fileCalls++,
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
      )));
      await tester.pump();

      expect(find.byTooltip('发送'), findsOneWidget);
      expect(find.byTooltip('发送文件'), findsOneWidget);
      expect(find.text('输入消息，Enter 发送...'), findsOneWidget);

      await tester.tap(find.byTooltip('发送文件'));
      await tester.pump();
      expect(fileCalls, 1);

      await tester.tap(find.byTooltip('发送'));
      await tester.pump();
      expect(sendCalls, 1);

      // canSend=true 的 RawTextField 会触发 IME 桥接启动路径，
      // 其内部遗留一个一次性 Timer（生产代码缺陷，见 TESTING_GUIDE），
      // 测试需推进假时钟使其触发，避免 teardown 报 pending timer。
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('输入文本后按 Enter 触发 onSend', (tester) async {
      String? sent;
      final ctrl = TextEditingController();
      await tester.pumpWidget(wrap(ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: const [],
        username: 'alice',
        inputCtrl: ctrl,
        canSend: true,
        onSend: () => sent = ctrl.text,
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
      )));
      await tester.pump();

      // 点击输入框获得焦点（输入栏内的 RawTextField）
      await tester.tap(find.byType(RawTextField));
      await tester.pump();
      // 通过键盘输入
      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(sent, 'hi');

      // 同上：冲刷 IME 桥接遗留的一次性 Timer
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('canSend=false 不显示输入栏', (tester) async {
      await tester.pumpWidget(wrap(ChatView(
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
      )));
      expect(find.byTooltip('发送'), findsNothing);
      expect(find.text('系统消息 为只读会话'), findsOneWidget);
    });
  });

  group('传输进度显示', () {
    testWidgets('文件消息显示百分比文本', (tester) async {
      await tester.pumpWidget(wrap(ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: [
          msg('alice', '[发送文件] big.bin', 'f1',
              type: 'file', filename: 'big.bin'),
        ],
        username: 'alice',
        inputCtrl: TextEditingController(),
        canSend: false,
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
        transferFraction: (id) => id == 'f1' ? 0.42 : null,
      )));
      expect(find.text('42%'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets('传输完成（1.0）百分比显示 100%', (tester) async {
      await tester.pumpWidget(wrap(ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: [
          msg('alice', '[发送文件] big.bin', 'f1',
              type: 'file', filename: 'big.bin'),
        ],
        username: 'alice',
        inputCtrl: TextEditingController(),
        canSend: false,
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
        transferFraction: (id) => 1.0,
      )));
      expect(find.text('100%'), findsOneWidget);
    });
  });

  group('撤回边界', () {
    testWidgets('已撤回的自己的消息长按不触发撤回', (tester) async {
      String? recalled;
      await tester.pumpWidget(wrap(ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: [msg('alice', 'x', 'm1', status: 'recalled')],
        username: 'alice',
        inputCtrl: TextEditingController(),
        canSend: false,
        onSend: () {},
        onSendFile: () {},
        onRecall: (id) => recalled = id,
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
      )));
      await tester.longPress(find.textContaining('[消息已撤回]'));
      await tester.pump(const Duration(milliseconds: 600));
      expect(recalled, isNull);
    });

    testWidgets('自己未撤回消息右键（secondary tap）触发撤回', (tester) async {
      String? recalled;
      await tester.pumpWidget(wrap(ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: [msg('alice', 'x', 'm1')],
        username: 'alice',
        inputCtrl: TextEditingController(),
        canSend: false,
        onSend: () {},
        onSendFile: () {},
        onRecall: (id) => recalled = id,
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
      )));
      final gesture = await tester.startGesture(
          tester.getCenter(find.text('x')),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton);
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(recalled, 'm1');
    });
  });

  group('时间格式化', () {
    testWidgets('当天消息显示 HH:MM', (tester) async {
      final now = DateTime.now();
      final t = DateTime(now.year, now.month, now.day, 9, 5);
      await tester.pumpWidget(wrap(ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: [msg('bob', 'hi', 'm1', timestamp: t)],
        username: 'alice',
        inputCtrl: TextEditingController(),
        canSend: false,
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
      )));
      expect(find.text('09:05'), findsOneWidget);
    });

    testWidgets('隔天消息显示 MM-DD HH:MM', (tester) async {
      final now = DateTime.now();
      final yesterday = now.subtract(const Duration(days: 1));
      final t =
          DateTime(yesterday.year, yesterday.month, yesterday.day, 23, 59);
      await tester.pumpWidget(wrap(ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: [msg('bob', 'hi', 'm1', timestamp: t)],
        username: 'alice',
        inputCtrl: TextEditingController(),
        canSend: false,
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
      )));
      final mm = t.month.toString().padLeft(2, '0');
      final dd = t.day.toString().padLeft(2, '0');
      expect(find.text('$mm-$dd 23:59'), findsOneWidget);
    });
  });

  group('渲染压力', () {
    testWidgets('200 条消息正常渲染无异常', (tester) async {
      final messages = List.generate(
          200, (i) => msg(i.isEven ? 'alice' : 'bob', '消息 $i 的内容', 'm$i'));
      await tester.pumpWidget(wrap(ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: messages,
        username: 'alice',
        inputCtrl: TextEditingController(),
        canSend: false,
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
      )));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('消息 199'), findsOneWidget);
    });

    testWidgets('5000 字符超长消息渲染不溢出', (tester) async {
      final longText = '长' * 5000;
      await tester.pumpWidget(wrap(ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: [msg('bob', longText, 'm1')],
        username: 'alice',
        inputCtrl: TextEditingController(),
        canSend: false,
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
      )));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('文件消息与系统消息混排', (tester) async {
      await tester.pumpWidget(wrap(ChatView(
        chatKey: 'group_1',
        chatTitle: '群',
        messages: [
          msg('服务器', '公告', 's1', type: 'system'),
          msg('bob', '[文件] a.pdf', 'f1', type: 'file', filename: 'a.pdf'),
          msg('carol', '群聊', 'm1', type: 'group_chat'),
        ],
        username: 'alice',
        inputCtrl: TextEditingController(),
        canSend: false,
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
      )));
      await tester.pump();
      expect(find.text('公告'), findsOneWidget);
      expect(find.textContaining('a.pdf'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('上滑加载历史', () {
    testWidgets('滚动接近顶部触发 onLoadHistory（带 before 游标）', (tester) async {
      final loaded = <String?>[];
      final messages = List.generate(
          60,
          (i) => msg('bob', 'm$i', 'id$i',
              timestamp: DateTime(2026, 1, 1, 12, i)));
      await tester.pumpWidget(wrap(ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: messages,
        username: 'alice',
        inputCtrl: TextEditingController(),
        canSend: false,
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (beforeId) async {
          loaded.add(beforeId);
        },
        hasMoreHistory: (_) => true,
      )));
      await tester.pump();

      // 反向 ListView：向上拖（负 dy 在 reverse 列表中等价于滚向旧消息方向）
      await tester.drag(find.byType(ListView), const Offset(0, 5000));
      await tester.pumpAndSettle();

      expect(loaded, isNotEmpty, reason: '滚动应触发历史加载');
      // 游标应为"当前最旧消息"的 messageId（id0）
      expect(loaded.first, 'id0');
    });

    testWidgets('【已修复】加载期间应显示"加载中…"指示器（回归锁定）', (tester) async {
      // 回归锁定：历史加载进行中（onLoadHistory 挂起）时 UI 应显示"加载中…"。
      // 曾因 _loadMoreHistory 直接赋值 _isLoadingHistory 无 setState，
      // 滚动事件不触发 rebuild，指示器从不出现。
      final completer = Completer<void>();
      int called = 0;
      final messages = List.generate(60, (i) => msg('bob', 'm$i', 'id$i'));
      await tester.pumpWidget(wrap(ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: messages,
        username: 'alice',
        inputCtrl: TextEditingController(),
        canSend: false,
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (beforeId) {
          called++;
          return completer.future;
        },
        hasMoreHistory: (_) => true,
      )));
      await tester.pump();

      await tester.drag(find.byType(ListView), const Offset(0, 5000));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(called, 1, reason: '滚动应触发历史加载');
      expect(find.text('加载中…'), findsOneWidget,
          reason: '加载窗口内应显示指示器（缺陷修复后应成立）');

      completer.complete();
      await tester.pumpAndSettle();
      expect(find.text('加载中…'), findsNothing);
    });

    testWidgets('hasMoreHistory=false 时滚动不触发加载', (tester) async {
      int calls = 0;
      final messages = List.generate(60, (i) => msg('bob', 'm$i', 'id$i'));
      await tester.pumpWidget(wrap(ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: messages,
        username: 'alice',
        inputCtrl: TextEditingController(),
        canSend: false,
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {
          calls++;
        },
        hasMoreHistory: (_) => false,
      )));
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, 5000));
      await tester.pumpAndSettle();
      expect(calls, 0);
    });
  });
}
