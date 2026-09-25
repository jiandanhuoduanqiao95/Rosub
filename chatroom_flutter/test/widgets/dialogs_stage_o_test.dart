// ============================================================
// dialogs.dart 阶段 O —— 群组与消息增强面板对话框契约（TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 O：
//   - O4（P2-3）showQuickReplyPanel：快捷回复面板（列出常用语，点击即
//     onSend 并关闭；可添加/删除，经 QuickReplyStore 本地持久化）
//   - O5（P2-5）showScheduleMessageDialog：定时发送对话框（文本 + 日期/
//     时刻选择 → onSchedule(at, text)；空文本禁用确定）
//   - O1（展示接线）showGroupAnnouncementDialog：群主编辑群公告
//     （初始文本 + onConfirm(text)；空文本 = 清除公告）
//   - O7（P2-9）showSettingsDialog 扩展：深色模式三选项 / 字体大小滑块 /
//     主题色色板 / 聊天背景色板（集中管理，读写 ThemeSettings）
//   - O8（P2-8）showServerStatusDialog 扩展：证书剩余天数/已过期提示 +
//     "一键续期"按钮（service.renewCert；旧服务端无 cert 字段时不显示）
//   - O9（P2-12）名片/位置/日程三个发送对话框：
//     showContactPickerDialog / showLocationDialog / showScheduleCardDialog
//
// 对话框接受回调（网络由上层注入）。实现前：本文件引用尚未实现的对话框
// 函数，编译失败或用例红，属 TDD 红。实现后：全部转绿。
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/socket_service.dart';
import 'package:chatroom_flutter/services/state_manager.dart';
import 'package:chatroom_flutter/services/theme_settings.dart';
import 'package:chatroom_flutter/widgets/dialogs.dart';
import 'package:chatroom_flutter/widgets/raw_text_field.dart';

class MockSocketService extends Mock implements SocketService {}

AppState get state => AppState.instance;

ThemeSettings get settings => ThemeSettings.instance;

void resetState() {
  state
    ..setLoggedOut()
    ..setConnectionStatus(ConnectionStatus.disconnected);
}

/// 打开对话框的标准壳：点 'open' 触发 [open]
Future<void> pumpOpener(
  WidgetTester tester,
  void Function(BuildContext) open,
) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (ctx) => TextButton(
          onPressed: () => open(ctx),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// RawTextField 不使用系统 EditableText：文本经硬件键盘事件注入
/// （仅支持 ASCII；与 login_screen_test 的结论一致）
Future<void> typeAscii(WidgetTester tester, Finder field, String text) async {
  final mapping = {
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
    ' ': LogicalKeyboardKey.space,
  };
  await tester.tap(field);
  await tester.pump();
  for (final ch in text.split('')) {
    final key = mapping[ch];
    if (key != null) {
      await tester.sendKeyEvent(key);
      await tester.pump();
    }
  }
}

void main() {
  setUp(() {
    resetState();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('O1 —— 群公告对话框（showGroupAnnouncementDialog：发布/清除两选项）', () {
    testWidgets('带初始公告打开 → 发布页输入框回填现有公告', (tester) async {
      await pumpOpener(
        tester,
        (ctx) => showGroupAnnouncementDialog(
          ctx,
          initial: '现有公告',
          onConfirm: (_) {},
          onListAnnouncements: () {},
          onDelete: (_) {},
        ),
      );
      // RawTextField 自绘文本（无 Text widget）：经 controller 断言回填
      final field =
          tester.widget<RawTextField>(find.byType(RawTextField).first);
      expect(field.controller.text, '现有公告', reason: '初始公告回填输入框');
      expect(find.text('发布公告'), findsOneWidget, reason: '发布选项页');
      expect(find.text('清除公告'), findsOneWidget, reason: '清除选项页');
    });

    testWidgets('发布页输入并确认 → onConfirm 收到新文本并关闭', (tester) async {
      String? confirmed;
      await pumpOpener(
        tester,
        (ctx) => showGroupAnnouncementDialog(
          ctx,
          initial: '',
          onConfirm: (text) => confirmed = text,
          onListAnnouncements: () {},
          onDelete: (_) {},
        ),
      );
      await typeAscii(tester, find.byType(RawTextField).first, 'ok');
      await tester.pump();
      await tester.tap(find.text('发布'));
      await tester.pumpAndSettle();
      expect(confirmed, 'ok');
    });

    testWidgets('切到"清除公告"页 → 拉取公告历史并渲染列表', (tester) async {
      var listed = false;
      var deleted = '';
      state.setGroupAnnouncements([
        const GroupAnnouncement(
            messageId: 'a-1', sender: 'alice', content: '第一条公告'),
      ]);
      await pumpOpener(
        tester,
        (ctx) => showGroupAnnouncementDialog(
          ctx,
          initial: '',
          onConfirm: (_) {},
          onListAnnouncements: () => listed = true,
          onDelete: (id) => deleted = id,
        ),
      );
      expect(listed, isFalse, reason: '发布页不拉取');

      await tester.tap(find.text('清除公告'));
      await tester.pumpAndSettle();
      expect(listed, isTrue, reason: '切到清除页拉取公告历史');
      expect(find.text('第一条公告'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('announcement_delete_a-1')));
      await tester.pumpAndSettle();
      expect(deleted, 'a-1', reason: '点删除回调对应公告 id');
    });

    testWidgets('清除公告页空历史显示空态', (tester) async {
      await pumpOpener(
        tester,
        (ctx) => showGroupAnnouncementDialog(
          ctx,
          initial: '',
          onConfirm: (_) {},
          onListAnnouncements: () {},
          onDelete: (_) {},
        ),
      );
      await tester.tap(find.text('清除公告'));
      await tester.pumpAndSettle();
      expect(find.textContaining('暂无'), findsOneWidget);
    });
  });

  group('O1 —— 群菜单"群公告"入口（showGroupMenuDialog 扩展）', () {
    testWidgets('提供 onAnnouncement → 菜单渲染"群公告"入口，点击回调', (tester) async {
      state.setLoggedIn('alice', false);
      final group = Group(id: 1, name: '开发组', owner: 'alice');
      var opened = false;
      await pumpOpener(
        tester,
        (ctx) => showGroupMenuDialog(
          ctx,
          group,
          (_) {},
          (_) {},
          onAnnouncement: () => opened = true,
        ),
      );
      expect(find.text('群公告'), findsOneWidget);
      await tester.tap(find.text('群公告'));
      await tester.pumpAndSettle();
      expect(opened, isTrue, reason: '点击"群公告"关闭菜单并打开发布对话框');
    });

    testWidgets('未提供 onAnnouncement → 不渲染"群公告"入口（回归兼容）', (tester) async {
      state.setLoggedIn('bob', false);
      final group = Group(id: 1, name: '开发组', owner: 'alice');
      await pumpOpener(
        tester,
        (ctx) => showGroupMenuDialog(ctx, group, (_) {}, (_) {}),
      );
      expect(find.text('群公告'), findsNothing);
    });
  });

  group('O4 —— 快捷回复面板（showQuickReplyPanel）', () {
    testWidgets('打开列出本地常用语；点击短语 → onSend + 关闭', (tester) async {
      final sent = <String>[];
      await pumpOpener(
        tester,
        (ctx) => showQuickReplyPanel(ctx, onSend: sent.add),
      );
      expect(find.text('收到'), findsOneWidget,
          reason: '默认常用语渲染（QuickReplyStore 默认列表）');

      await tester.tap(find.text('收到'));
      await tester.pumpAndSettle();
      expect(sent, ['收到'], reason: '点击短语即发送');
      expect(find.text('收到'), findsNothing, reason: '发送后关闭面板');
    });

    testWidgets('输入新短语添加 → 持久化并出现在列表', (tester) async {
      await pumpOpener(
        tester,
        (ctx) => showQuickReplyPanel(ctx, onSend: (_) {}),
      );
      await typeAscii(tester, find.byType(RawTextField).first, 'ok');
      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();
      expect(find.text('ok'), findsOneWidget, reason: '添加后立即出现在列表');
    });

    testWidgets('删除短语 → 从列表移除', (tester) async {
      await pumpOpener(
        tester,
        (ctx) => showQuickReplyPanel(ctx, onSend: (_) {}),
      );
      // 默认列表第一项 '收到' 行内的删除入口
      await tester.tap(find.byKey(const ValueKey('quick_reply_delete_收到')));
      await tester.pumpAndSettle();
      expect(find.text('收到'), findsNothing);
    });
  });

  group('O5 —— 定时发送对话框（showScheduleMessageDialog）', () {
    testWidgets('空文本 → 确定按钮禁用', (tester) async {
      var called = false;
      await pumpOpener(
        tester,
        (ctx) => showScheduleMessageDialog(
          ctx,
          onSchedule: (_, __) async => called = true,
        ),
      );
      final button = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('定时发送'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(button.onPressed, isNull, reason: '空文本不能定时');
      expect(called, isFalse);
    });

    testWidgets('输入文本 + 默认时刻（明天 09:00）确定 → onSchedule 回调', (tester) async {
      DateTime? scheduledAt;
      String? scheduledText;
      await pumpOpener(
        tester,
        (ctx) => showScheduleMessageDialog(
          ctx,
          onSchedule: (at, text) async {
            scheduledAt = at;
            scheduledText = text;
          },
        ),
      );
      await typeAscii(tester, find.byType(RawTextField).first, 'remind');
      await tester.pump();
      await tester.tap(find.text('定时发送'));
      await tester.pumpAndSettle();

      expect(scheduledText, 'remind');
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      expect(scheduledAt!.day, tomorrow.day, reason: '默认日期为明天');
      expect(scheduledAt!.hour, 9, reason: '默认时刻 09:00');
      expect(scheduledAt!.minute, 0);
      expect(scheduledAt!.isAfter(DateTime.now()), isTrue,
          reason: '定时时刻必须晚于当前');
    });

    testWidgets('取消 → 不回调', (tester) async {
      var called = false;
      await pumpOpener(
        tester,
        (ctx) => showScheduleMessageDialog(
          ctx,
          onSchedule: (_, __) async => called = true,
        ),
      );
      await typeAscii(tester, find.byType(RawTextField).first, 'x');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(called, isFalse);
    });
  });

  group('O5 补充（用户反馈 #7）—— 定时管理对话框（showScheduledManageDialog）', () {
    testWidgets('打开时拉取定时任务并渲染列表（目标 + 时刻）', (tester) async {
      var listed = false;
      await pumpOpener(
        tester,
        (ctx) => showScheduledManageDialog(
          ctx,
          onList: () => listed = true,
          onDelete: (_) {},
        ),
      );
      expect(listed, isTrue, reason: '打开即拉取定时任务');
      state.setScheduledMessages([
        ScheduledMessageInfo(
          messageId: 's-1',
          receiver: 'bob',
          content: '下午提醒',
          scheduleAt: DateTime(2026, 9, 2, 9, 30),
        ),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('下午提醒'), findsOneWidget);
      expect(find.textContaining('发给 bob'), findsOneWidget);
    });

    testWidgets('点取消 → onDelete 回调 message_id', (tester) async {
      var deleted = '';
      state.setScheduledMessages([
        ScheduledMessageInfo(
          messageId: 's-2',
          groupId: 3,
          content: '群定时',
          scheduleAt: DateTime(2026, 9, 2, 9, 30),
        ),
      ]);
      await pumpOpener(
        tester,
        (ctx) => showScheduledManageDialog(
          ctx,
          onList: () {},
          onDelete: (id) => deleted = id,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('scheduled_cancel_s-2')));
      await tester.pumpAndSettle();
      expect(deleted, 's-2');
    });

    testWidgets('空任务显示空态', (tester) async {
      await pumpOpener(
        tester,
        (ctx) => showScheduledManageDialog(
          ctx,
          onList: () {},
          onDelete: (_) {},
        ),
      );
      expect(find.textContaining('暂无'), findsOneWidget);
    });
  });

  group('O7 —— 设置对话框扩展（showSettingsDialog）', () {
    Future<void> openSettings(WidgetTester tester) async {
      await pumpOpener(tester, (ctx) => showSettingsDialog(ctx));
    }

    testWidgets('包含四个新设置区块：深色模式/字体大小/主题色/聊天背景', (tester) async {
      await settings.load();
      await openSettings(tester);
      expect(find.text('深色模式'), findsOneWidget);
      expect(find.text('字体大小'), findsOneWidget);
      expect(find.text('主题色'), findsOneWidget);
      expect(find.text('聊天背景'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget, reason: '字体大小滑块');
    });

    testWidgets('选择"深色" → ThemeSettings.mode 变为 dark', (tester) async {
      await settings.load();
      await openSettings(tester);
      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();
      expect(settings.mode, AppThemeMode.dark);
    });

    testWidgets('点选主题色色板 → themeColor 更新', (tester) async {
      await settings.load();
      final picked = ThemeSettings.presetColors.last;
      await openSettings(tester);
      await tester.tap(find.byKey(ValueKey('o7_theme_color_$picked')));
      await tester.pumpAndSettle();
      expect(settings.themeColor, picked);
    });

    testWidgets('点选"无背景" → chatBackground 置空', (tester) async {
      await settings.load();
      settings.chatBackground = 0xFFEEEEEE;
      await openSettings(tester);
      await tester.tap(find.text('无背景'));
      await tester.pumpAndSettle();
      expect(settings.chatBackground, isNull);
    });
  });

  group('O8 —— 服务端状态对话框证书区（showServerStatusDialog）', () {
    testWidgets('cert 未过期 → 显示剩余天数与"一键续期"按钮', (tester) async {
      final service = MockSocketService();
      when(() => service.fetchServerStatus()).thenAnswer((_) async {});
      when(() => service.renewCert()).thenAnswer((_) async {});
      state.setLoggedIn('admin', true);
      state.setServerStatus({
        'online_users': 1,
        'online_sessions': 1,
        'total_users': 3,
        'total_messages': 10,
        'pending_file_requests': 0,
        'storage': {'file_store_bytes': 0, 'file_count': 0, 'db_bytes': 0},
        'disk': {'disk_free': 1, 'disk_total': 100, 'warn': false},
        'cert': {'exists': true, 'expired': false, 'days_left': 3650},
      });

      await pumpOpener(tester, (ctx) => showServerStatusDialog(ctx, service));
      expect(find.textContaining('证书'), findsOneWidget);
      expect(find.textContaining('3650'), findsOneWidget);
      expect(find.text('一键续期'), findsOneWidget);

      await tester.tap(find.text('一键续期'));
      await tester.pumpAndSettle();
      verify(() => service.renewCert()).called(1);
    });

    testWidgets('cert 已过期 → 显示"已过期"警示', (tester) async {
      final service = MockSocketService();
      when(() => service.fetchServerStatus()).thenAnswer((_) async {});
      state.setLoggedIn('admin', true);
      state.setServerStatus({
        'online_users': 1,
        'cert': {'exists': true, 'expired': true, 'days_left': -3},
      });

      await pumpOpener(tester, (ctx) => showServerStatusDialog(ctx, service));
      expect(find.textContaining('已过期'), findsOneWidget);
      expect(find.text('一键续期'), findsOneWidget);
    });

    testWidgets('旧服务端无 cert 字段 → 不显示证书区（向后兼容）', (tester) async {
      final service = MockSocketService();
      when(() => service.fetchServerStatus()).thenAnswer((_) async {});
      state.setLoggedIn('admin', true);
      state.setServerStatus({
        'online_users': 1,
        'total_users': 3,
      });

      await pumpOpener(tester, (ctx) => showServerStatusDialog(ctx, service));
      expect(find.text('一键续期'), findsNothing);
    });
  });
}
