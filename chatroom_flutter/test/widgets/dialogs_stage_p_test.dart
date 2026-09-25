// ============================================================
// dialogs.dart 阶段 P —— 表情包面板 / 高级搜索 / 语言设置契约（TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 P（P2/P3/P6 客户端面板）：
//
//   P2 表情包体系：
//     StickerPickerPanel（R-P14 嵌入式面板，输入栏上方挂载；原模态层
//     showStickerPickerDialog 已移除）：
//       - 贴纸面板：包 tab（StickerStore.loadPacks）+ 当前包贴纸网格
//         （缩略图 Image.memory，字节来自 stickerBytes）
//       - 点击贴纸 → onPick(sticker) 并关闭
//       - 管理区：输入包名添加（addPack 后列表刷新）、删除包
//       - 空包/无包 → 空态提示不崩溃
//
//   P3 复合条件消息搜索（R-P28 修订）：
//     showAdvancedSearchDialog(context,
//         {required ValueChanged<MessageSearchFilter> onSearch,
//          List<String> Function()? senderCandidates})：
//       - 输入区（ValueKey 契约）：'adv_search_keyword'（关键词，
//         RawTextField，R-O1 惯例：不 autofocus、showChineseInput）/
//         'adv_search_sender_chip_<name>'（发送者选项式 FilterChip，
//         可单选/多选/取消）/'adv_search_date'（日期单入口，点击弹出
//         托盘式年/月/日滚轮选择器）
//       - 日期托盘（showSearchDatePickerDialog）：精度三档（按年/按月/
//         按日，'date_prec_0/1/2'）→ 对应滚轮列；三档模糊精度均展开为
//         范围（年→全年 / 年月→整月 / 年月日→全天）；'不限'清除
//       - 全空 → "搜索"不触发回调（按钮禁用）
//       - 填写后搜索 → onSearch(MessageSearchFilter)（关键词 trim）
//       - 取消 → 关闭无回调
//
//   P6 多语言界面：
//     showSettingsDialog 扩展"语言"区块：三选项（中文/English/跟随系统）
//       读写 ThemeSettings.locale；切换即时生效（notifyListeners 全局重建）
//
// 实现前：本文件引用尚未实现的对话框函数，编译失败或用例红，属 TDD 红。
// 实现后：全部转绿。
// ============================================================

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/sticker_store.dart';
import 'package:chatroom_flutter/services/theme_settings.dart';
import 'package:chatroom_flutter/widgets/dialogs.dart';

ThemeSettings get settings => ThemeSettings.instance;

final Uint8List pngBytes = Uint8List.fromList(
    [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03]);

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
/// （仅支持 ASCII；与 dialogs_stage_o_test 的 typeAscii 一致）
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
    '-': LogicalKeyboardKey.minus,
    ' ': LogicalKeyboardKey.space,
  };
  await tester.tap(field);
  await tester.pump();
  for (final ch in text.split('')) {
    final key = mapping[ch.toLowerCase()];
    if (key == null) continue;
    if (RegExp(r'[A-Z]').hasMatch(ch)) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(key, platform: 'linux');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    } else {
      await tester.sendKeyEvent(key);
    }
    await tester.pump();
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('P2/R-P3 —— 表情面板（双模块：表情 / 表情包）', () {
    Future<void> seedStickers() async {
      await StickerStore.instance.init(
          baseDir: Directory.systemTemp.createTempSync('sticker_picker').path);
      await StickerStore.instance.bindUser(null);
      await StickerStore.instance.addSticker(pngBytes);
      await StickerStore.instance.addSticker(pngBytes);
    }

    // R-P14：面板为可嵌入组件（ChatScreen 经 ChatView.emojiPanel 挂载
    // 在输入栏上方），测试直接 pump 面板本体
    Future<void> pumpPanel(
      WidgetTester tester, {
      ValueChanged<Sticker>? onPick,
      ValueChanged<String>? onEmojiPicked,
      VoidCallback? onClose,
    }) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StickerPickerPanel(
            key: const ValueKey('sticker_panel'),
            onPick: onPick ?? (_) {},
            onEmojiPicked: onEmojiPicked ?? (_) {},
            onClose: onClose,
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('默认打开表情模块：内置表情网格 + 分类切换（不空白）', (tester) async {
      await seedStickers();
      await pumpPanel(tester);
      expect(find.text('表情'), findsWidgets, reason: '表情 tab');
      expect(find.text('添加表情包'), findsNothing, reason: '表情模块不显示表情包内容');
      expect(find.text('👍'), findsWidgets, reason: '内置表情直接可见（不空白）');
      await tester.tap(find.text('笑脸'));
      await tester.pumpAndSettle();
      expect(find.text('😀'), findsWidgets, reason: '切分类后表情更新');
    });

    testWidgets('表情点击 → onEmojiPicked 回调（面板保持打开，连续插入）', (tester) async {
      await seedStickers();
      final picked = <String>[];
      await pumpPanel(tester, onEmojiPicked: picked.add);
      await tester.tap(find.text('👍').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('👍').first);
      await tester.pumpAndSettle();
      expect(picked, ['👍', '👍'], reason: '连续选择（面板不关闭）');
      expect(find.byIcon(Icons.favorite_rounded), findsOneWidget,
          reason: '面板仍打开（可切换模块）');
    });

    testWidgets('R-P10：表情网格锁定 COLRv1 彩色字体（NotoColorEmoji）', (tester) async {
      await seedStickers();
      await pumpPanel(tester);
      final text = tester.widget<Text>(find.text('👍').first);
      expect(text.style?.fontFamily, 'NotoColorEmoji',
          reason: '缺省字体回落系统黑白字形（部分表情渲染灰黑）——必须指定彩色字体');
    });

    testWidgets('表情包模块：首格"添加表情包"恒可用（空态不空白）', (tester) async {
      await StickerStore.instance.init(
          baseDir: Directory.systemTemp.createTempSync('sticker_empty').path);
      await StickerStore.instance.bindUser(null);
      await pumpPanel(tester);

      await tester.tap(find.text('表情包').last);
      await tester.pumpAndSettle();

      expect(find.text('添加表情包'), findsOneWidget, reason: '添加入口（名称改版）');
      final tile = tester
          .widget<InkWell>(find.byKey(const ValueKey('sticker_add_tile')));
      expect(tile.onTap, isNotNull, reason: 'R-P3：添加恒可用（修复点不动）');
    });

    testWidgets('表情包模块：贴纸缩略图展示；点击 → onPick 并回调 onClose', (tester) async {
      await seedStickers();
      final picked = <Sticker>[];
      var closed = false;
      await pumpPanel(tester, onPick: picked.add, onClose: () => closed = true);

      await tester.tap(find.text('表情包').last);
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsWidgets, reason: '贴纸缩略图网格');
      await tester.tap(find.byType(Image).first);
      await tester.pumpAndSettle();

      expect(picked.length, 1, reason: '点击贴纸即发送');
      expect(picked.first.name.endsWith('.png'), isTrue);
      expect(closed, isTrue, reason: 'R-P14：选择后回调 onClose（宿主收起面板；嵌入组件自身不 pop）');
    });

    testWidgets('长按贴纸 → 删除确认 → store 移除并刷新', (tester) async {
      await seedStickers();
      await pumpPanel(tester, onPick: (_) {});
      await tester.tap(find.text('表情包').last);
      await tester.pumpAndSettle();

      final before = (await StickerStore.instance.loadStickers()).length;
      await tester.longPress(find.byType(Image).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect((await StickerStore.instance.loadStickers()).length, before - 1,
          reason: '确认后删除');
    });
  });

  group('P3 —— 高级搜索对话框（showAdvancedSearchDialog）', () {
    testWidgets('渲染：关键词输入 + 发送者选项 chips + 日期单入口（R-P28）', (tester) async {
      await pumpOpener(
          tester,
          (ctx) => showAdvancedSearchDialog(
                ctx,
                senderCandidates: () => ['bob', 'alice'],
                onSearch: (_) {},
              ));
      expect(find.byKey(const ValueKey('adv_search_keyword')), findsOneWidget);
      expect(find.byKey(const ValueKey('adv_search_date')), findsOneWidget,
          reason: 'R-P28 日期仅保留一个入口');
      expect(find.byKey(const ValueKey('adv_search_sender_chip_bob')),
          findsOneWidget,
          reason: '发送者改为选项式 chip');
      expect(find.byKey(const ValueKey('adv_search_sender_chip_alice')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('adv_search_from')), findsNothing,
          reason: '旧双下拉入口已移除');
      expect(find.byKey(const ValueKey('adv_search_to')), findsNothing);
    });

    testWidgets('候选为空 → 占位提示不崩溃', (tester) async {
      await pumpOpener(
          tester,
          (ctx) => showAdvancedSearchDialog(
                ctx,
                onSearch: (_) {},
              ));
      expect(find.text('（暂无可选发送者）'), findsOneWidget);
      expect(find.byKey(const ValueKey('adv_search_date')), findsOneWidget);
    });

    testWidgets('全空点"搜索" → 不触发回调', (tester) async {
      var searched = false;
      await pumpOpener(
          tester,
          (ctx) => showAdvancedSearchDialog(
                ctx,
                senderCandidates: () => ['bob'],
                onSearch: (_) => searched = true,
              ));
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();
      expect(searched, isFalse, reason: '无任何过滤条件不触发');
    });

    testWidgets('仅关键词 → onSearch 收到 filter.keyword（trim）', (tester) async {
      MessageSearchFilter? got;
      await pumpOpener(
          tester,
          (ctx) => showAdvancedSearchDialog(
                ctx,
                senderCandidates: () => ['bob'],
                onSearch: (f) => got = f,
              ));
      await typeAscii(
          tester, find.byKey(const ValueKey('adv_search_keyword')), 'hello');
      await tester.pump();
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();

      expect(got, isNotNull);
      expect(got!.keyword, 'hello');
      expect(got!.senders, isEmpty);
      expect(got!.date, isNull);
      expect(got!.from, isNull);
      expect(got!.to, isNull);
    });

    testWidgets('发送者 chip 单选/多选 → filter.senders 保序', (tester) async {
      MessageSearchFilter? got;
      await pumpOpener(
          tester,
          (ctx) => showAdvancedSearchDialog(
                ctx,
                senderCandidates: () => ['bob', 'alice'],
                onSearch: (f) => got = f,
              ));
      await typeAscii(
          tester, find.byKey(const ValueKey('adv_search_keyword')), 'report');
      await tester
          .tap(find.byKey(const ValueKey('adv_search_sender_chip_bob')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const ValueKey('adv_search_sender_chip_alice')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();

      expect(got, isNotNull);
      expect(got!.senders, ['bob', 'alice'], reason: '按选择顺序');
    });

    testWidgets('发送者 chip 再点取消 → 从 senders 移除', (tester) async {
      MessageSearchFilter? got;
      await pumpOpener(
          tester,
          (ctx) => showAdvancedSearchDialog(
                ctx,
                senderCandidates: () => ['bob', 'alice'],
                onSearch: (f) => got = f,
              ));
      await typeAscii(
          tester, find.byKey(const ValueKey('adv_search_keyword')), 'report');
      await tester
          .tap(find.byKey(const ValueKey('adv_search_sender_chip_bob')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const ValueKey('adv_search_sender_chip_alice')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const ValueKey('adv_search_sender_chip_bob')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();

      expect(got!.senders, ['alice'], reason: 'bob 已取消勾选');
    });

    testWidgets('日期托盘：按年精度 → 全年范围（模糊精度）', (tester) async {
      MessageSearchFilter? got;
      await pumpOpener(
          tester,
          (ctx) => showAdvancedSearchDialog(
                ctx,
                senderCandidates: () => ['bob'],
                onSearch: (f) => got = f,
              ));
      await typeAscii(
          tester, find.byKey(const ValueKey('adv_search_keyword')), 'report');

      await tester.tap(find.byKey(const ValueKey('adv_search_date')));
      await tester.pumpAndSettle();
      expect(find.text('选择日期'), findsOneWidget, reason: '托盘对话框弹出');

      await tester.tap(find.byKey(const ValueKey('date_prec_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2024年'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('date_ok')));
      await tester.pumpAndSettle();

      expect(find.text('2024年'), findsOneWidget, reason: '入口摘要显示所选年');
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();

      expect(got, isNotNull);
      expect(got!.date!.year, 2024);
      expect(got!.date!.month, isNull, reason: '按年精度月不限');
      expect(got!.from, DateTime(2024, 1, 1), reason: '全年范围起点');
      expect(got!.to, DateTime(2024, 12, 31, 23, 59, 59), reason: '全年范围终点');
    });

    testWidgets('日期托盘：按月精度 → 整月范围', (tester) async {
      MessageSearchFilter? got;
      await pumpOpener(
          tester,
          (ctx) => showAdvancedSearchDialog(
                ctx,
                senderCandidates: () => ['bob'],
                onSearch: (f) => got = f,
              ));
      await tester.tap(find.byKey(const ValueKey('adv_search_date')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('date_prec_1')));
      await tester.pumpAndSettle();
      // 滚轮可视窗口为选中项 ±2 行：年轮默认当前年（1 行上=2025 可见），
      // 月轮默认当前月（9 月），+2 行 = 11 月可见
      await tester.tap(find.text('2025年'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('11月'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('date_ok')));
      await tester.pumpAndSettle();

      expect(find.text('2025年11月'), findsOneWidget);
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();

      expect(got!.from, DateTime(2025, 11, 1), reason: '整月起点');
      expect(got!.to, DateTime(2025, 11, 30, 23, 59, 59), reason: '整月终点（小月）');
    });

    testWidgets('日期托盘：按日默认今天 → 全天范围', (tester) async {
      MessageSearchFilter? got;
      await pumpOpener(
          tester,
          (ctx) => showAdvancedSearchDialog(
                ctx,
                senderCandidates: () => ['bob'],
                onSearch: (f) => got = f,
              ));
      await tester.tap(find.byKey(const ValueKey('adv_search_date')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('date_ok')));
      await tester.pumpAndSettle();

      final now = DateTime.now();
      expect(find.text('${now.year}年${now.month}月${now.day}日'), findsOneWidget,
          reason: '默认精度按日、选中今天');
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();

      expect(got!.from, DateTime(now.year, now.month, now.day));
      expect(got!.to, DateTime(now.year, now.month, now.day, 23, 59, 59),
          reason: '全天范围');
    });

    testWidgets('日期"不限"清除 + 托盘取消不动原选择', (tester) async {
      MessageSearchFilter? got;
      await pumpOpener(
          tester,
          (ctx) => showAdvancedSearchDialog(
                ctx,
                senderCandidates: () => ['bob'],
                onSearch: (f) => got = f,
              ));
      await tester.tap(find.byKey(const ValueKey('adv_search_date')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('date_ok')));
      await tester.pumpAndSettle();
      final now = DateTime.now();
      expect(find.text('${now.year}年${now.month}月${now.day}日'), findsOneWidget);

      // 取消 → 入口摘要不变
      await tester.tap(find.byKey(const ValueKey('adv_search_date')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('date_cancel')));
      await tester.pumpAndSettle();
      expect(find.text('${now.year}年${now.month}月${now.day}日'), findsOneWidget,
          reason: '托盘取消不改主对话框');

      // 不限 → 摘要复位
      await tester.tap(find.byKey(const ValueKey('adv_search_date')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('date_clear')));
      await tester.pumpAndSettle();
      expect(find.text('日期（不限）'), findsOneWidget);

      await typeAscii(
          tester, find.byKey(const ValueKey('adv_search_keyword')), 'hello');
      await tester.pump();
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();
      expect(got!.from, isNull, reason: '清除后不携带时间头');
      expect(got!.to, isNull);
    });

    testWidgets('取消 → 关闭且无回调', (tester) async {
      var searched = false;
      await pumpOpener(
          tester,
          (ctx) => showAdvancedSearchDialog(
                ctx,
                senderCandidates: () => ['bob'],
                onSearch: (_) => searched = true,
              ));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(searched, isFalse);
      expect(find.text('高级搜索'), findsNothing);
    });
  });

  group('P6 —— 设置对话框"语言"区块', () {
    testWidgets('设置对话框显示语言选项（当前值中文）', (tester) async {
      await settings.bindUser(null);
      await pumpOpener(tester, (ctx) => showSettingsDialog(ctx));
      expect(find.text('语言'), findsOneWidget);
      expect(find.text('中文'), findsOneWidget, reason: '当前语言中文');
    });

    testWidgets('切换 English → ThemeSettings.locale 更新', (tester) async {
      await settings.bindUser(null);
      await pumpOpener(tester, (ctx) => showSettingsDialog(ctx));

      await tester.tap(find.text('中文'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('English').last);
      await tester.pumpAndSettle();

      expect(settings.locale, AppLocale.en, reason: '语言切换写入 ThemeSettings');
    });

    testWidgets('三选项齐全（中文/English/跟随系统）', (tester) async {
      await settings.bindUser(null);
      await pumpOpener(tester, (ctx) => showSettingsDialog(ctx));
      await tester.tap(find.text('中文'));
      await tester.pumpAndSettle();
      expect(find.text('中文'), findsWidgets);
      expect(find.text('English'), findsOneWidget);
      // '跟随系统' 与 O7 深色模式选项同文案，菜单打开时两处同现
      expect(find.text('跟随系统'), findsWidgets);
    });
  });
}
