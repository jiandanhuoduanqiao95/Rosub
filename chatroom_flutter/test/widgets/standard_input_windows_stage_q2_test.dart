// ============================================================
// Windows 标准输入深化契约（阶段 Q2-2 —— 契约测试）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 Q「Q2 Windows」要点
// 「RawTextField → 标准输入」与 TESTING_GUIDE.md §36.3 一致性矩阵
// Windows 列（中文输入=标准输入 / 键盘导航 ASCII 路径 / 表情面板）：
//
//   Q0-2 已锁定 AdaptiveTextField 的平台分发（windows → 标准 TextField、
//   无 RawTextField、showChineseInput/onImagePasted 为无害冗余）。本
//   文件把断言落到 **Windows 真实界面形态**：
//
//   · 登录页（经 ChatroomApp 全壳）在 Windows 模拟下全部输入位为标准
//     TextField：密码掩码 + 可见性切换（showVisibilityToggle 渲染
//     suffixIcon）可用；中文经系统 IME 通道（enterText 模拟）可输入；
//   · 聊天输入框（ChatView，showChineseInput=true 的实例）在 Windows
//     模拟下仍走标准输入——NAV 桥接路径不注册（无 RawTextField），
//     中文/emoji 混排输入同步 controller（R-P10 混排 fallback 契约
//     平台无关）；
//   · 回车提交（N5 ASCII 路径）在 Windows 下对齐 onSubmitted。
//
// 平台模拟规约（§21.1）：debugDefaultTargetPlatformOverride 在
// testWidgets body 内恢复（testWidgetsOnPlatform wrapper）。
// 现状：Q0-2 已使本组用例大多可绿（分发正确）；保留为 Q2 回归锁，
// 防止 Q2 平台实现重构击穿界面层标准输入语义。
// ============================================================

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chatroom_flutter/main.dart';
import 'package:chatroom_flutter/widgets/adaptive_text_field.dart';
import 'package:chatroom_flutter/widgets/chat_view.dart';
import 'package:chatroom_flutter/widgets/raw_text_field.dart';

/// 平台模拟 helper（§21.1，与 Q0-2 相同约定）：override 必须在 body 内恢复
void testWidgetsOnPlatform(String description, TargetPlatform? platform,
    Future<void> Function(WidgetTester tester) body) {
  testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

Future<void> pumpLoginApp(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(800, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(const ChatroomApp());
  await tester.pump();
}

Widget wrap(Widget child) => MaterialApp(
    home: Scaffold(body: SizedBox(width: 600, height: 800, child: child)));

ChatView chatView(TextEditingController ctrl) => ChatView(
      chatKey: 'bob',
      chatTitle: 'bob',
      messages: const [],
      username: 'alice',
      inputCtrl: ctrl,
      canSend: true,
      onSend: () {},
      onSendFile: () {},
      onRecall: (_) {},
      onLoadHistory: (_) async {},
      hasMoreHistory: (_) => false,
      onReplyMessage: (_) {},
      onForwardMessage: (_) {},
      onAddReaction: (_, __) {},
      onDeleteMessage: (_) {},
      onJumpToMessage: (_) {},
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = null;
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  group('Q2-2 —— 登录页 Windows 模拟（ChatroomApp 全壳）', () {
    testWidgetsOnPlatform(
        '全部输入位为标准 TextField，无 RawTextField（NAV 桥接不注册）', TargetPlatform.windows,
        (tester) async {
      await pumpLoginApp(tester);
      expect(find.byType(TextField), findsAtLeastNWidgets(2),
          reason: '§36.3 Windows 列：中文输入=标准输入（用户名/密码至少两输入位）');
      expect(find.byType(RawTextField), findsNothing,
          reason: 'RawTextField 与 GTK IME 桥接是 Linux 专属，Windows 不得渲染');
      expect(find.byType(AdaptiveTextField), findsAtLeastNWidgets(2),
          reason: '输入位统一经适配层（Q0-2 收敛），不允许绕过');
    });

    testWidgetsOnPlatform(
        '密码掩码 + 可见性切换可用（showVisibilityToggle）', TargetPlatform.windows,
        (tester) async {
      await pumpLoginApp(tester);
      final fields =
          tester.widgetList<TextField>(find.byType(TextField)).toList();
      expect(fields.any((f) => f.obscureText), isTrue, reason: '密码输入位掩码渲染');
      expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget,
          reason: '可见性切换按钮（AdaptiveTextField suffixIcon）');
      await tester.tap(find.byIcon(Icons.visibility_off_outlined));
      await tester.pump();
      final after =
          tester.widgetList<TextField>(find.byType(TextField)).toList();
      expect(after.any((f) => f.obscureText), isFalse,
          reason: '点击切换后明文显示（与 Linux RawTextField.showVisibilityToggle 语义对齐）');
    });

    testWidgetsOnPlatform(
        '中文经系统 IME 通道可输入（§36.3 Windows 列：标准输入）', TargetPlatform.windows,
        (tester) async {
      await pumpLoginApp(tester);
      await tester.enterText(find.byType(TextField).first, '你好Windows世界');
      await tester.pump();
      final fields =
          tester.widgetList<TextField>(find.byType(TextField)).toList();
      expect(fields.any((f) => f.controller?.text == '你好Windows世界'), isTrue,
          reason: '标准 TextField 系统输入路径（enterText 模拟），中文无需 GTK 桥接');
    });
  });

  group('Q2-2 —— 聊天输入框 Windows 模拟（ChatView，showChineseInput=true 实例）', () {
    testWidgetsOnPlatform('输入区为标准 TextField：showChineseInput 冗余无害、NAV 不注册',
        TargetPlatform.windows, (tester) async {
      final ctrl = TextEditingController();
      await tester.pumpWidget(wrap(chatView(ctrl)));
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget,
          reason: '聊天输入（showChineseInput=true）在 Windows 仍走标准输入');
      expect(find.byType(RawTextField), findsNothing,
          reason: 'NAV 桥接路径仅 Linux（RawTextField 内部注册），Windows 不触碰桥接');
    });

    testWidgetsOnPlatform('中文/emoji 混排输入同步 controller（R-P10 混排 fallback 平台无关）',
        TargetPlatform.windows, (tester) async {
      final ctrl = TextEditingController();
      await tester.pumpWidget(wrap(chatView(ctrl)));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '消息🫱你好');
      await tester.pump();
      expect(ctrl.text, '消息🫱你好',
          reason: '系统 IME 通道输入含 emoji 的混排文本正常进 controller');
    });

    testWidgetsOnPlatform(
        '回车提交触发 onSubmitted（N5 ASCII 路径平台无关保留）', TargetPlatform.windows,
        (tester) async {
      final controller = TextEditingController();
      var submitted = '';
      await tester.pumpWidget(wrap(MaterialApp(
        home: Scaffold(
          body: AdaptiveTextField(
            controller: controller,
            onSubmitted: (v) => submitted = v,
          ),
        ),
      )));
      await tester.pump();
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'windows submit');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(submitted, 'windows submit',
          reason: '§36.3 Windows 列：键盘导航 ASCII 路径（回车提交）与 Linux 对齐');
    });
  });
}
