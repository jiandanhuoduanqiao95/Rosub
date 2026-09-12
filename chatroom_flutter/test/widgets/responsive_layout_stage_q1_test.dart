// ============================================================
// 响应式布局契约（阶段 Q1-1 —— TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 Q「Q1 Android」要点：
// "手机窄屏响应式布局（会话列表↔聊天单屏切换、对话框全屏化）"；
// §36.3 矩阵"会话/群组全功能"行：手机窄屏改单屏切换布局（Q1 响应式）。
//
// 契约：新增 lib/widgets/responsive_layout.dart ——
//
//   const double kCompactWidthBreakpoint = 600;   // Material compact 阈值
//   bool isCompactLayout(BuildContext context);   // 宽度 < 600
//
//   Future<T?> showResponsiveDialog<T>({
//     required BuildContext context,
//     required WidgetBuilder builder,
//     bool barrierDismissible = true,
//     Color? barrierColor,              // 视频查看器黑色 barrier 语义透传
//   });
//     · compact（< 600）→ 全屏化（Dialog 铺满 surface）；
//     · 宽屏（≥ 600）→ 现有 showDialog 居中语义（既有测试 800x600 全兼容）；
//     · pop<T> 返回值 / barrierDismissible / barrierColor 全部透传。
//
// ChatScreen 单屏切换（compact）：
//   · 未选会话 → 仅会话列表（Sidebar 铺满宽度），无聊天区；
//   · 选中会话 → 仅聊天区，Sidebar 不渲染；提供返回控件
//     （tooltip '返回'）→ 回会话列表；可继续选择其他会话；
//   · 系统会话（'服务器'）同样单屏打开（只读语义不变）；
//   · 宽屏（≥ 600，含 Linux 桌面与平板）双栏同现——既有布局不回归
//     （Q4 平板复用同一断点）。
//
// 迁移收敛（源码扫描锁定）：dialogs.dart 全部 42 处 showDialog 调用
// 迁入 showResponsiveDialog（对话框全屏化覆盖全部对话框）；chat_screen
// 的 7 处同步迁移；chat_view 的消息菜单 showModalBottomSheet 保留
// （底部弹层是移动端原生模式，不误改）。
//
// 实现注意（勿破坏既有约定）：ChatScreen AppBar 动作与 ChatView 工具条
// 在 599 宽下不得溢出（本文件测试即断言）；测试窄屏统一用 599x800
// （compact 断点下留足既有控件宽度，溢出即实现问题）。
//
// 实现前：responsive_layout.dart 不存在，本文件编译失败，属 TDD 红。
// 实现后：全部转绿。
// ============================================================

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/screens/chat_screen.dart';
import 'package:chatroom_flutter/services/socket_service.dart';
import 'package:chatroom_flutter/services/state_manager.dart';
import 'package:chatroom_flutter/widgets/chat_view.dart';
import 'package:chatroom_flutter/widgets/responsive_layout.dart';
import 'package:chatroom_flutter/widgets/sidebar.dart';

class MockSocketService extends Mock implements SocketService {}

AppState get state => AppState.instance;

void resetState() {
  state
    ..setLoggedOut()
    ..setConnectionStatus(ConnectionStatus.disconnected);
}

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

String srcOf(String relPath) => File('lib/$relPath').readAsStringSync();

int countOf(String source, String needle) => source.split(needle).length - 1;

void stubCommon(MockSocketService socket) {
  when(() => socket.saveConversationDraft(any(), any()))
      .thenAnswer((_) async {});
  when(() => socket.fetchHistory(
        to: any(named: 'to'),
        groupId: any(named: 'groupId'),
        beforeMessageId: any(named: 'beforeMessageId'),
        limit: any(named: 'limit'),
      )).thenAnswer((_) async {});
}

Future<void> pumpChat(
  WidgetTester tester,
  MockSocketService socket, {
  Size size = const Size(599, 800),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    home: ChatScreen(socketService: socket),
    routes: {'/login': (_) => const Scaffold(body: Text('LOGIN'))},
  ));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(resetState);
  tearDown(resetState);

  group('Q1-1 —— 断点契约（responsive_layout.dart）', () {
    test('kCompactWidthBreakpoint == 600（Material compact 阈值）', () {
      expect(kCompactWidthBreakpoint, 600);
    });

    testWidgets('isCompactLayout 边界：599 → true，600/800 → false',
        (tester) async {
      bool? compact;
      Future<void> pumpAt(Size size) async {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpWidget(MaterialApp(
          home: Builder(
            builder: (ctx) {
              compact = isCompactLayout(ctx);
              return const SizedBox.shrink();
            },
          ),
        ));
        addTearDown(() => tester.binding.setSurfaceSize(null));
      }

      await pumpAt(const Size(599, 800));
      expect(compact, isTrue, reason: '< 600 = compact（手机窄屏）');
      await pumpAt(const Size(600, 800));
      expect(compact, isFalse, reason: '600 = 宽屏下界（平板/桌面双栏）');
      await pumpAt(const Size(800, 600));
      expect(compact, isFalse, reason: '既有测试 800x600 基线保持宽屏');
    });
  });

  group('Q1-1 —— ChatScreen 单屏切换（android 模拟，599x800）', () {
    testWidgetsOnPlatform('未选会话：仅会话列表，无聊天区、无返回控件', TargetPlatform.android,
        (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob', 'carol']);

      await pumpChat(tester, socket);

      expect(find.byType(Sidebar), findsOneWidget, reason: '首屏为会话列表');
      expect(find.byType(ChatView), findsNothing);
      expect(find.byTooltip('返回'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgetsOnPlatform('会话列表铺满屏宽（不再固定 270 侧栏）', TargetPlatform.android,
        (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);

      await pumpChat(tester, socket);

      expect(tester.getSize(find.byType(Sidebar)).width, 599,
          reason: 'compact 下会话列表占满全宽');
    });

    testWidgetsOnPlatform(
        '选中会话 → 仅聊天区（Sidebar 不渲染）+ 返回控件出现', TargetPlatform.android,
        (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob', 'carol']);

      await pumpChat(tester, socket);
      await tester.tap(find.text('bob'));
      await tester.pumpAndSettle();

      expect(find.byType(ChatView), findsOneWidget, reason: '切到聊天区');
      expect(find.byType(Sidebar), findsNothing, reason: '单屏：列表不渲染');
      expect(find.byTooltip('返回'), findsOneWidget, reason: '回列表出口');
      expect(tester.takeException(), isNull);
    });

    testWidgetsOnPlatform('点返回 → 回会话列表（可继续选择其他会话）', TargetPlatform.android,
        (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob', 'carol']);

      await pumpChat(tester, socket);
      await tester.tap(find.text('bob'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();

      expect(find.byType(Sidebar), findsOneWidget, reason: '返回后回到列表');
      expect(find.byType(ChatView), findsNothing);

      await tester.tap(find.text('carol'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatView), findsOneWidget, reason: '再选另一会话正常切换');
      expect(tester.takeException(), isNull);
    });

    testWidgetsOnPlatform("系统会话（'服务器'）单屏打开正常（只读语义不变）", TargetPlatform.android,
        (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.addMessage(
        '服务器',
        ChatMessage(
          sender: '系统',
          content: '系统公告测试',
          messageId: 'sys-q1',
          type: 'system',
        ),
      );

      await pumpChat(tester, socket);
      await tester.tap(find.text('系统消息'));
      await tester.pumpAndSettle();

      expect(find.byType(ChatView), findsOneWidget);
      expect(find.byType(Sidebar), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('Q1-1 —— 宽屏不回归（≥ 600 双栏同现，平台无关）', () {
    testWidgetsOnPlatform(
        'linux 800x600：选会话后 Sidebar 与 ChatView 同帧可见', TargetPlatform.linux,
        (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);

      await pumpChat(tester, socket, size: const Size(800, 600));
      await tester.tap(find.text('bob'));
      await tester.pumpAndSettle();

      expect(find.byType(Sidebar), findsOneWidget, reason: '桌面双栏基线');
      expect(find.byType(ChatView), findsOneWidget);
      expect(find.byTooltip('返回'), findsNothing, reason: '宽屏无单屏返回控件');
    });

    testWidgetsOnPlatform(
        'android 800 宽（平板）：双栏同现（Q4 平板复用断点）', TargetPlatform.android,
        (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);

      await pumpChat(tester, socket, size: const Size(800, 800));
      await tester.tap(find.text('bob'));
      await tester.pumpAndSettle();

      expect(find.byType(Sidebar), findsOneWidget);
      expect(find.byType(ChatView), findsOneWidget);
    });

    testWidgetsOnPlatform(
        'android 600 宽（断点边界）→ 双栏（< 600 才 compact）', TargetPlatform.android,
        (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);

      await pumpChat(tester, socket, size: const Size(600, 800));
      expect(find.byType(Sidebar), findsOneWidget, reason: '600 不算 compact');
      expect(find.byTooltip('返回'), findsNothing);
    });
  });

  group('Q1-1 —— 对话框全屏化（showResponsiveDialog）', () {
    Future<void> pumpDialogHost(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: () => showResponsiveDialog<void>(
                    context: ctx,
                    builder: (_) => const SizedBox.expand(
                      child: Center(child: Text('Q1DIALOG')),
                    ),
                  ),
                  child: const Text('OPEN_FULL'),
                ),
                TextButton(
                  onPressed: () => showResponsiveDialog<void>(
                    context: ctx,
                    builder: (_) =>
                        const AlertDialog(title: Text('Q1DIALOG_CENTERED')),
                  ),
                  child: const Text('OPEN_CENTER'),
                ),
                TextButton(
                  onPressed: () async {
                    final v = await showResponsiveDialog<String>(
                      context: ctx,
                      builder: (inner) => AlertDialog(
                        title: const Text('Q1DIALOG_VALUE'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(inner, 'ok'),
                            child: const Text('确定'),
                          ),
                        ],
                      ),
                    );
                    if (v == 'ok' && ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(content: Text('GOT_OK')),
                      );
                    }
                  },
                  child: const Text('OPEN_VALUE'),
                ),
                TextButton(
                  onPressed: () => showResponsiveDialog<void>(
                    context: ctx,
                    barrierDismissible: false,
                    builder: (_) =>
                        const AlertDialog(title: Text('Q1DIALOG_STICKY')),
                  ),
                  child: const Text('OPEN_STICKY'),
                ),
                TextButton(
                  onPressed: () => showResponsiveDialog<void>(
                    context: ctx,
                    barrierColor: Colors.black,
                    builder: (_) =>
                        const AlertDialog(title: Text('Q1DIALOG_BARRIER')),
                  ),
                  child: const Text('OPEN_BARRIER'),
                ),
              ],
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgetsOnPlatform('compact：对话框铺满 surface（全屏化）', TargetPlatform.android,
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(599, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpDialogHost(tester);

      await tester.tap(find.text('OPEN_FULL'));
      await tester.pumpAndSettle();

      expect(tester.getSize(find.byType(Dialog)), const Size(599, 800),
          reason: '窄屏对话框全屏化（Dialog.fullscreen 语义）');
    });

    testWidgetsOnPlatform(
        'compact AlertDialog：内层 Dialog 本体铺满 surface（真机反馈 #6 修订）',
        TargetPlatform.android, (tester) async {
      await tester.binding.setSurfaceSize(const Size(599, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpDialogHost(tester);

      await tester.tap(find.text('OPEN_CENTER'));
      await tester.pumpAndSettle();

      // AlertDialog 自带内层 Dialog（原 minWidth 280 居中小卡片）——
      // 局部 dialogTheme 覆盖后本体铺满整屏（标题置顶/按钮沉底）
      final dialogs = find.byType(Dialog);
      expect(dialogs, findsAtLeastNWidgets(2),
          reason: '外层 Dialog.fullscreen + AlertDialog 内层 Dialog');
      expect(tester.getSize(dialogs.last), const Size(599, 800),
          reason: 'AlertDialog 本体铺满（不再"整块灰屏中间小白卡片"）');
    });

    testWidgetsOnPlatform(
        '宽屏：对话框居中（既有 showDialog 语义，视觉卡片 < surface）', TargetPlatform.linux,
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpDialogHost(tester);

      await tester.tap(find.text('OPEN_CENTER'));
      await tester.pumpAndSettle();

      // AlertDialog extends Dialog，其组件盒（内含铺满的 AnimatedPadding+
      // Align）恒等于 surface——视觉尺寸须测内部 Material 卡片
      final card = find
          .descendant(
            of: find.byType(Dialog),
            matching: find.byType(Material),
          )
          .first;
      final size = tester.getSize(card);
      expect(size.width, lessThan(800), reason: '宽屏保持居中小窗（视觉卡片）');
      expect(find.text('Q1DIALOG_CENTERED'), findsOneWidget);
    });

    testWidgetsOnPlatform('pop<T> 返回值透传', TargetPlatform.linux, (tester) async {
      await pumpDialogHost(tester);

      await tester.tap(find.text('OPEN_VALUE'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(find.text('GOT_OK'), findsOneWidget, reason: "返回值 'ok' 透传");
    });

    testWidgetsOnPlatform(
        'barrierDismissible 透传（true 点遮罩关 / false 不关）', TargetPlatform.linux,
        (tester) async {
      await pumpDialogHost(tester);

      await tester.tap(find.text('OPEN_CENTER'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(40, 300));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing, reason: '默认可点遮罩关闭');

      await tester.tap(find.text('OPEN_STICKY'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(40, 300));
      await tester.pumpAndSettle();
      expect(find.text('Q1DIALOG_STICKY'), findsOneWidget,
          reason: 'barrierDismissible=false 点遮罩不关（视频查看器语义）');
    });

    testWidgetsOnPlatform('barrierColor 透传（黑色遮罩，视频查看器语义）', TargetPlatform.linux,
        (tester) async {
      await pumpDialogHost(tester);

      await tester.tap(find.text('OPEN_BARRIER'));
      await tester.pumpAndSettle();

      expect(
        find.byWidgetPredicate(
            (w) => w is ModalBarrier && w.color == Colors.black),
        findsOneWidget,
      );
    });
  });

  group('Q1-1 —— 对话框迁移收敛（源码扫描）', () {
    test('dialogs.dart 全量迁移：showDialog 直调清零、showResponsiveDialog 接管', () {
      final src = srcOf('widgets/dialogs.dart');
      expect(countOf(src, 'showDialog('), 0, reason: '原 42 处居中对话框全迁移');
      expect(countOf(src, 'showDialog<'), 0, reason: '泛型调用点同样清零');
      expect(countOf(src, 'showResponsiveDialog'), greaterThanOrEqualTo(40),
          reason: '迁移点数与原 showDialog 调用数对应');
    });

    test('chat_screen.dart 迁移 + compact 接线（源码扫描）', () {
      final src = srcOf('screens/chat_screen.dart');
      expect(countOf(src, 'showDialog('), 0, reason: '原 7 处全迁移');
      expect(countOf(src, 'showDialog<'), 0);
      expect(countOf(src, 'showResponsiveDialog'), greaterThanOrEqualTo(7));
      expect(countOf(src, 'isCompactLayout'), greaterThanOrEqualTo(1),
          reason: '单屏切换按断点驱动');
    });

    test('chat_view 消息菜单 showModalBottomSheet 保留（移动端原生模式不误改）', () {
      final src = srcOf('widgets/chat_view.dart');
      expect(countOf(src, 'showModalBottomSheet'), greaterThanOrEqualTo(1),
          reason: '消息长按菜单为底部弹层，不纳入对话框全屏化迁移');
    });
  });
}
