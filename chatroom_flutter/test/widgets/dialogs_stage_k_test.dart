// ============================================================
// dialogs.dart 阶段 K —— 设置对话框 / 好友与群组菜单置顶·静音项（TDD 契约，待实现）
// ============================================================
// 覆盖 P1-13/P1-14（设置）+ P1-11/P1-13（会话菜单入口）
// （《软件开发文档4.1.0.md》§11 阶段 K / §13.3）：
//   - showSettingsDialog：提示音开关（默认开）、免打扰开关（默认关）、
//     免打扰时段（开始/结束小时选择），直接读写 TaskbarNotifier 设置
//   - showFriendManageDialog 扩展：置顶/取消置顶 + 静音/取消静音入口
//     （pinned/muted 决定文案，onTogglePin/onToggleMute 回调翻转值）
//   - showGroupMenuDialog 扩展：同上（群组会话置顶/静音）
//
// 对话框接受纯参数，便于直接 pump 验证。
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/state_manager.dart';
import 'package:chatroom_flutter/services/taskbar_notifier.dart';
import 'package:chatroom_flutter/widgets/dialogs.dart';

AppState get state => AppState.instance;

void resetState() {
  state
    ..setLoggedOut()
    ..setConnectionStatus(ConnectionStatus.disconnected);
}

Future<void> pumpOpen(
    WidgetTester tester, void Function(BuildContext) open) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(builder: (context) {
        return ElevatedButton(
          onPressed: () => open(context),
          child: const Text('OPEN'),
        );
      }),
    ),
  ));
  await tester.tap(find.text('OPEN'));
  await tester.pumpAndSettle();
}

void main() {
  late bool originalSoundEnabled;
  late bool originalDndEnabled;
  late DateTime originalDndEnd;
  late DateTime Function() originalNowProvider;

  // 假时钟基准取"真实今天"（而非固定日期）：日期选择器 firstDate 用真实
  // DateTime.now()，若假时钟日期落后于真实日期会触发
  // "initialDate must be on or after firstDate" 断言（跨天复发）。
  final DateTime baseDay =
      DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);

  setUp(() {
    resetState();
    originalSoundEnabled = TaskbarNotifier.soundEnabled;
    originalDndEnabled = TaskbarNotifier.dndEnabled;
    originalDndEnd = TaskbarNotifier.dndEndTime;
    originalNowProvider = TaskbarNotifier.nowProvider;
    TaskbarNotifier.soundEnabled = true;
    TaskbarNotifier.dndEnabled = false;
    TaskbarNotifier.dndEndTime =
        DateTime(baseDay.year, baseDay.month, baseDay.day, 23, 0);
    TaskbarNotifier.nowProvider = () =>
        DateTime(baseDay.year, baseDay.month, baseDay.day, 10, 0);
  });

  tearDown(() {
    TaskbarNotifier.soundEnabled = originalSoundEnabled;
    TaskbarNotifier.dndEnabled = originalDndEnabled;
    TaskbarNotifier.dndEndTime = originalDndEnd;
    TaskbarNotifier.nowProvider = originalNowProvider;
    resetState();
  });

  group('K3 —— 设置对话框（提示音 / 免打扰）', () {
    testWidgets('打开设置对话框显示提示音与免打扰开关', (tester) async {
      await pumpOpen(tester, (ctx) => showSettingsDialog(ctx));
      expect(find.text('设置'), findsOneWidget);
      expect(find.text('提示音'), findsOneWidget);
      expect(find.text('免打扰'), findsOneWidget);
    });

    testWidgets('默认：提示音开、免打扰关、时段选择不显示', (tester) async {
      await pumpOpen(tester, (ctx) => showSettingsDialog(ctx));
      final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
      expect(switches.length, 2);
      expect(switches[0].value, isTrue, reason: '提示音默认开');
      expect(switches[1].value, isFalse, reason: '免打扰默认关');
      expect(find.text('结束日期'), findsNothing, reason: '免打扰关闭时隐藏时段');
    });

    testWidgets('关闭提示音写入 soundEnabled=false', (tester) async {
      await pumpOpen(tester, (ctx) => showSettingsDialog(ctx));
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(TaskbarNotifier.soundEnabled, isFalse);
    });

    testWidgets('开启免打扰写入 dndEnabled=true 并默认结束时刻今天 23:00',
        (tester) async {
      await pumpOpen(tester, (ctx) => showSettingsDialog(ctx));
      await tester.tap(find.byType(Switch).last);
      await tester.pumpAndSettle();
      expect(TaskbarNotifier.dndEnabled, isTrue);
      expect(
          TaskbarNotifier.dndEndTime,
          DateTime(baseDay.year, baseDay.month, baseDay.day, 23, 0),
          reason: '开启时自动设置默认结束时刻（今天 23:00）');
      expect(find.text('结束日期'), findsOneWidget);
      expect(find.text('结束时刻'), findsOneWidget);
      expect(find.textContaining('至 ${baseDay.toIso8601String().substring(0, 10)} 23:00'),
          findsOneWidget,
          reason: '开关副标题展示到期时刻');
    });

    testWidgets('修改结束时刻写入 dndEndTime（精确到时分）', (tester) async {
      await pumpOpen(tester, (ctx) => showSettingsDialog(ctx));
      await tester.tap(find.byType(Switch).last);
      await tester.pumpAndSettle();

      // 时 23 → 22
      await tester.tap(find.text('23 时').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('22 时').last);
      await tester.pumpAndSettle();
      // 分 0 → 5（下拉菜单为滚动列表，取首屏可见项）
      await tester.tap(find.text('0 分').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('5 分').last);
      await tester.pumpAndSettle();
      expect(TaskbarNotifier.dndEndTime,
          DateTime(baseDay.year, baseDay.month, baseDay.day, 22, 5));
    });

    testWidgets('点击"结束日期"打开日期选择器', (tester) async {
      await pumpOpen(tester, (ctx) => showSettingsDialog(ctx));
      await tester.tap(find.byType(Switch).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.calendar_month_rounded));
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget,
          reason: '日期选择器应打开（精确到日）');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    });

    testWidgets('对话框关闭不丢失设置（设置即写即生效）', (tester) async {
      await pumpOpen(tester, (ctx) => showSettingsDialog(ctx));
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(TaskbarNotifier.soundEnabled, isFalse);
    });
  });

  group('K1/K3 —— 好友管理菜单：置顶与静音入口', () {
    testWidgets('未置顶未静音时显示"置顶"与"静音"', (tester) async {
      await pumpOpen(
          tester,
          (ctx) => showFriendManageDialog(
                ctx,
                'bob',
                onViewProfile: () {},
                onSetNote: () {},
                onSetGroup: () {},
                onBlock: () {},
                onUnblock: () {},
                onDelete: () {},
                onTogglePin: (_) {},
                onToggleMute: (_) {},
              ));
      expect(find.text('置顶'), findsOneWidget);
      expect(find.text('静音'), findsOneWidget);
    });

    testWidgets('已置顶时显示"取消置顶"，点击触发 onTogglePin(false)', (tester) async {
      final toggles = <bool>[];
      await pumpOpen(
          tester,
          (ctx) => showFriendManageDialog(
                ctx,
                'bob',
                onViewProfile: () {},
                onSetNote: () {},
                onSetGroup: () {},
                onBlock: () {},
                onUnblock: () {},
                onDelete: () {},
                pinned: true,
                onTogglePin: toggles.add,
              ));
      expect(find.text('取消置顶'), findsOneWidget);
      await tester.tap(find.text('取消置顶'));
      await tester.pumpAndSettle();
      expect(toggles, [false]);
    });

    testWidgets('未置顶时点击"置顶"触发 onTogglePin(true)', (tester) async {
      final toggles = <bool>[];
      await pumpOpen(
          tester,
          (ctx) => showFriendManageDialog(
                ctx,
                'bob',
                onViewProfile: () {},
                onSetNote: () {},
                onSetGroup: () {},
                onBlock: () {},
                onUnblock: () {},
                onDelete: () {},
                onTogglePin: toggles.add,
              ));
      await tester.tap(find.text('置顶'));
      await tester.pumpAndSettle();
      expect(toggles, [true]);
    });

    testWidgets('静音入口翻转：已静音显示"取消静音"并触发 onToggleMute(false)', (tester) async {
      final toggles = <bool>[];
      await pumpOpen(
          tester,
          (ctx) => showFriendManageDialog(
                ctx,
                'bob',
                onViewProfile: () {},
                onSetNote: () {},
                onSetGroup: () {},
                onBlock: () {},
                onUnblock: () {},
                onDelete: () {},
                muted: true,
                onToggleMute: toggles.add,
              ));
      expect(find.text('取消静音'), findsOneWidget);
      await tester.tap(find.text('取消静音'));
      await tester.pumpAndSettle();
      expect(toggles, [false]);
    });

    testWidgets('未静音时点击"静音"触发 onToggleMute(true)', (tester) async {
      final toggles = <bool>[];
      await pumpOpen(
          tester,
          (ctx) => showFriendManageDialog(
                ctx,
                'bob',
                onViewProfile: () {},
                onSetNote: () {},
                onSetGroup: () {},
                onBlock: () {},
                onUnblock: () {},
                onDelete: () {},
                onToggleMute: toggles.add,
              ));
      await tester.tap(find.text('静音'));
      await tester.pumpAndSettle();
      expect(toggles, [true]);
    });

    testWidgets('未提供 K 回调时无置顶/静音入口（回归兼容）', (tester) async {
      await pumpOpen(
          tester,
          (ctx) => showFriendManageDialog(
                ctx,
                'bob',
                onViewProfile: () {},
                onSetNote: () {},
                onSetGroup: () {},
                onBlock: () {},
                onUnblock: () {},
                onDelete: () {},
              ));
      expect(find.text('置顶'), findsNothing);
      expect(find.text('静音'), findsNothing);
      expect(find.text('取消置顶'), findsNothing);
      expect(find.text('取消静音'), findsNothing);
    });
  });

  group('K1/K3 —— 群组菜单：置顶与静音入口', () {
    testWidgets('群组菜单显示置顶/静音入口', (tester) async {
      await pumpOpen(
          tester,
          (ctx) => showGroupMenuDialog(
                ctx,
                Group(id: 1, name: '开发组'),
                (_) {},
                (_) {},
                onTogglePin: (_) {},
                onToggleMute: (_) {},
              ));
      expect(find.text('置顶'), findsOneWidget);
      expect(find.text('静音'), findsOneWidget);
    });

    testWidgets('未提供 K 回调时群组菜单无置顶/静音入口（回归兼容）', (tester) async {
      await pumpOpen(
          tester,
          (ctx) => showGroupMenuDialog(
                ctx,
                Group(id: 1, name: '开发组'),
                (_) {},
                (_) {},
              ));
      expect(find.text('置顶'), findsNothing);
      expect(find.text('静音'), findsNothing);
    });

    testWidgets('已置顶群组点击"取消置顶"触发 onTogglePin(false)', (tester) async {
      final toggles = <bool>[];
      await pumpOpen(
          tester,
          (ctx) => showGroupMenuDialog(
                ctx,
                Group(id: 1, name: '开发组'),
                (_) {},
                (_) {},
                pinned: true,
                onTogglePin: toggles.add,
              ));
      await tester.tap(find.text('取消置顶'));
      await tester.pumpAndSettle();
      expect(toggles, [false]);
    });

    testWidgets('群组静音入口触发 onToggleMute(true)', (tester) async {
      final toggles = <bool>[];
      await pumpOpen(
          tester,
          (ctx) => showGroupMenuDialog(
                ctx,
                Group(id: 1, name: '开发组'),
                (_) {},
                (_) {},
                onToggleMute: toggles.add,
              ));
      await tester.tap(find.text('静音'));
      await tester.pumpAndSettle();
      expect(toggles, [true]);
    });
  });
}
