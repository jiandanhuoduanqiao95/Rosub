// ============================================================
// chat_view.dart 阶段 Q1 —— 真机手动测试反馈修复契约
// ============================================================
// 覆盖 Q1 Android 真机八项反馈中的三项：
//
// 反馈 #1（输入框过小）：compact（< 600）输入栏左侧功能入口
// （发送文件/表情包/快捷回复/定时发送）收进单个「+」键
// （ValueKey('input_actions_toggle')），点击展开面板
// （ValueKey('input_actions_panel')）逐项触发回调并收起；
// 宽屏保持四键并列（桌面既有布局不回归）。
//
// 反馈 #3（顶栏遮挡聊天区）：ChatView 新增 headerVisible /
// searchInputVisible / onSearchVisibilityChanged——
//   · headerVisible=false 不渲染自带标题栏（"与 bob 的聊天"消失）；
//   · 受控模式：搜索输入行显隐由 searchInputVisible 驱动，
//     关闭/提交经 onSearchVisibilityChanged(false) 回传；
//   · 无头 + 搜索结果态：搜索行常驻并提供"退出搜索"出口；
//   · 默认值（headerVisible=true、回调 null）保持自治语义
//     （桌面既有行为零变化）。
//
// 反馈 #7（数字黑色）：气泡正文 Text 显式 fontFamily =
// 主题默认字体（NotoColorEmoji 内含 0-9 键帽黑色字形，fontFamily
// 缺省时 fallback 链抢先命中导致数字变黑）。
// ============================================================

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/widgets/chat_view.dart';

ChatMessage msg(String sender, String content, String id,
        {String status = 'sent', String type = 'chat'}) =>
    ChatMessage(
      sender: sender,
      content: content,
      messageId: id,
      status: status,
      type: type,
    );

Future<void> pumpChatView(
  WidgetTester tester, {
  Size size = const Size(599, 800),
  String chatKey = 'bob',
  bool headerVisible = true,
  bool searchInputVisible = false,
  ValueChanged<bool>? onSearchVisibilityChanged,
  bool isSearchMode = false,
  String searchQuery = '',
  VoidCallback? onSearchExit,
  VoidCallback? onQuickReply,
  VoidCallback? onScheduleMessage,
  VoidCallback? onShowStickerPicker,
  List<ChatMessage>? messages,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: ChatView(
        chatKey: chatKey,
        chatTitle: 'bob',
        messages: messages ?? [msg('bob', '你好', 'm1')],
        username: 'alice',
        inputCtrl: TextEditingController(),
        canSend: true,
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
        isSearchMode: isSearchMode,
        searchQuery: searchQuery,
        onSearchExit: onSearchExit ?? () {},
        onQuickReply: onQuickReply,
        onScheduleMessage: onScheduleMessage,
        onShowStickerPicker: onShowStickerPicker,
        headerVisible: headerVisible,
        searchInputVisible: searchInputVisible,
        onSearchVisibilityChanged: onSearchVisibilityChanged,
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Q1 反馈 #1 —— compact 输入栏「+」折叠', () {
    testWidgets('compact：左侧功能键不直接并列，仅「+」键', (tester) async {
      await pumpChatView(tester, onQuickReply: () {}, onScheduleMessage: () {});

      expect(find.byKey(const ValueKey('input_actions_toggle')), findsOneWidget,
          reason: 'compact 单一「+」键');
      expect(find.byTooltip('发送文件'), findsNothing, reason: '功能入口收进面板，不直接并列');
      expect(find.byTooltip('快捷回复'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('点击「+」展开功能面板；逐项触发回调并收起', (tester) async {
      var quickReplyFired = 0;
      await pumpChatView(tester,
          onQuickReply: () => quickReplyFired++, onScheduleMessage: () {});

      await tester.tap(find.byKey(const ValueKey('input_actions_toggle')));
      await tester.pump();
      expect(find.byKey(const ValueKey('input_actions_panel')), findsOneWidget,
          reason: '展开功能面板');
      expect(find.text('发送文件'), findsOneWidget);
      expect(find.text('快捷回复'), findsOneWidget, reason: '面板带文字标签（微信式功能格）');

      await tester.tap(find.text('快捷回复'));
      await tester.pump();
      expect(quickReplyFired, 1, reason: '面板项触发回调');
      expect(find.byKey(const ValueKey('input_actions_panel')), findsNothing,
          reason: '触发后自动收起');
    });

    testWidgets('「+」键再次点击 = 收起（toggle）', (tester) async {
      await pumpChatView(tester, onQuickReply: () {});

      await tester.tap(find.byKey(const ValueKey('input_actions_toggle')));
      await tester.pump();
      expect(find.byKey(const ValueKey('input_actions_panel')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('input_actions_toggle')));
      await tester.pump();
      expect(find.byKey(const ValueKey('input_actions_panel')), findsNothing);
    });

    testWidgets('宽屏（≥600）：四键并列保持，无「+」键（桌面不回归）', (tester) async {
      await pumpChatView(tester,
          size: const Size(800, 600),
          onQuickReply: () {},
          onScheduleMessage: () {},
          onShowStickerPicker: () {});

      expect(find.byKey(const ValueKey('input_actions_toggle')), findsNothing,
          reason: '宽屏无折叠键');
      expect(find.byTooltip('发送文件'), findsOneWidget);
      expect(find.byTooltip('表情包'), findsOneWidget);
      expect(find.byTooltip('快捷回复'), findsOneWidget);
      expect(find.byTooltip('定时发送'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Q1 反馈 #3 —— 无头模式 + 受控搜索', () {
    testWidgets('headerVisible=false：自带标题栏不渲染', (tester) async {
      await pumpChatView(tester, headerVisible: false);

      expect(find.text('与 bob 的聊天'), findsNothing,
          reason: 'compact 聊天态标题移至 AppBar');
      expect(find.byTooltip('搜索消息'), findsNothing, reason: '搜索入口同时移至 AppBar');
      expect(find.byTooltip('导出聊天记录'), findsNothing);
    });

    testWidgets('受控搜索：searchInputVisible=true 显示搜索行，关闭回传 false',
        (tester) async {
      var visible = true;
      await pumpChatView(
        tester,
        headerVisible: false,
        searchInputVisible: visible,
        onSearchVisibilityChanged: (v) => visible = v,
      );

      expect(find.byKey(const ValueKey('search_field')), findsOneWidget,
          reason: '受控显示搜索行');

      await tester.tap(find.byTooltip('关闭搜索'));
      await tester.pump();
      expect(visible, isFalse, reason: '关闭动作回传 false');
    });

    testWidgets('无头 + 搜索结果态：搜索行常驻（预填查询词）并提供退出出口', (tester) async {
      var exited = false;
      // 模拟 android（测试宿主为 Linux 时 AdaptiveTextField 渲染
      // RawTextField，无 EditableText 不可用 find.text 断言；Q0-2 规约）
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await pumpChatView(
          tester,
          headerVisible: false,
          isSearchMode: true,
          searchQuery: '会议',
          onSearchExit: () => exited = true,
        );

        expect(find.byKey(const ValueKey('search_field')), findsOneWidget,
            reason: '搜索结果态搜索行常驻（无头部退出按钮可用）');
        expect(find.text('会议'), findsOneWidget, reason: '查询词预填');
        await tester.tap(find.byTooltip('退出搜索'));
        await tester.pump();
        expect(exited, isTrue, reason: '无头模式退出搜索出口');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('默认参数：头部渲染且搜索入口自治（桌面既有行为不回归）', (tester) async {
      await pumpChatView(tester);

      expect(find.text('与 bob 的聊天'), findsOneWidget);
      expect(find.byKey(const ValueKey('search_field')), findsNothing);
      await tester.tap(find.byTooltip('搜索消息'));
      await tester.pump();
      expect(find.byKey(const ValueKey('search_field')), findsOneWidget,
          reason: '自治模式：头部入口直接展开搜索行');
    });
  });

  group('Q1 反馈 #7 —— 气泡正文显式主字体（数字不变黑）', () {
    testWidgets('自己的数字消息：Text.fontFamily = 主题默认字体', (tester) async {
      final themeFamily = ThemeData().textTheme.bodyMedium?.fontFamily;
      await pumpChatView(tester, messages: [msg('alice', '127', 'm1')]);

      final text = tester.widget<Text>(find.text('127'));
      expect(text.style?.fontFamily, themeFamily,
          reason: '显式主字体使数字命中主字体而非 emoji 字体键帽字形');
      expect(text.style?.fontFamily, isNotNull,
          reason: 'fontFamily 必须显式非空（缺省时 fallback 抢先命中）');
      expect(text.style?.fontFamilyFallback, isNotEmpty,
          reason: 'emoji 彩色兜底链保留（R-P10/R-P26 契约）');
    });
  });
}
