// ============================================================
// dialogs.dart 阶段 P —— 表情包面板 / 高级搜索 / 语言设置契约（TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 P（P2/P3/P6 客户端面板）：
//
//   P2 表情包体系：
//     showStickerPickerDialog(context, {required ValueChanged<Sticker> onPick})：
//       - 贴纸面板：包 tab（StickerStore.loadPacks）+ 当前包贴纸网格
//         （缩略图 Image.memory，字节来自 stickerBytes）
//       - 点击贴纸 → onPick(sticker) 并关闭
//       - 管理区：输入包名添加（addPack 后列表刷新）、删除包
//       - 空包/无包 → 空态提示不崩溃
//
//   P3 复合条件消息搜索：
//     showAdvancedSearchDialog(context,
//         {required ValueChanged<MessageSearchFilter> onSearch})：
//       - 四输入区（ValueKey 契约，防与 ChatView 搜索栏字段歧义）：
//         'adv_search_keyword' / 'adv_search_sender' /
//         'adv_search_from' / 'adv_search_to'
//         （RawTextField，R-O1 惯例：不 autofocus、showChineseInput；
//         占位：关键词/发送者/起始日期(YYYY-MM-DD)/结束日期）
//       - 全空 → "搜索"不触发回调（按钮禁用）
//       - 填写后搜索 → onSearch(MessageSearchFilter)（日期经
//         parseSearchDay 解析；关键词 trim）
//       - 非法日期 → 不触发回调 + 错误提示
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

    Future<void> pumpPanel(
      WidgetTester tester, {
      ValueChanged<Sticker>? onPick,
      ValueChanged<String>? onEmojiPicked,
    }) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showStickerPickerDialog(
                ctx,
                onPick: onPick ?? (_) {},
                onEmojiPicked: onEmojiPicked ?? (_) {},
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
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

    testWidgets('表情包模块：贴纸缩略图展示；点击 → onPick 并关闭', (tester) async {
      await seedStickers();
      final picked = <Sticker>[];
      await pumpPanel(tester, onPick: picked.add);

      await tester.tap(find.text('表情包').last);
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsWidgets, reason: '贴纸缩略图网格');
      await tester.tap(find.byType(Image).first);
      await tester.pumpAndSettle();

      expect(picked.length, 1, reason: '点击贴纸即发送');
      expect(picked.first.name.endsWith('.png'), isTrue);
      expect(find.byIcon(Icons.favorite_rounded), findsNothing,
          reason: '选择后面板关闭');
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
    testWidgets('四输入区渲染（关键词/发送者/起始日期/结束日期）', (tester) async {
      await pumpOpener(
          tester,
          (ctx) => showAdvancedSearchDialog(
                ctx,
                onSearch: (_) {},
              ));
      expect(find.byKey(const ValueKey('adv_search_keyword')), findsOneWidget);
      expect(find.byKey(const ValueKey('adv_search_sender')), findsOneWidget);
      // R-P4：日期改为下拉选择（不再手输）
      expect(find.byKey(const ValueKey('adv_search_from')), findsOneWidget);
      expect(find.byKey(const ValueKey('adv_search_to')), findsOneWidget);
      // 注：下拉占位提示位于 DropdownButton 的 IndexedStack 离台节点，
      // find.text（skipOffstage 默认 true）不可见——占位/选择行为由
      // "日期下拉选择"用例点选验证
    });

    testWidgets('全空点"搜索" → 不触发回调', (tester) async {
      var searched = false;
      await pumpOpener(
          tester,
          (ctx) => showAdvancedSearchDialog(
                ctx,
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
                onSearch: (f) => got = f,
              ));
      await typeAscii(
          tester, find.byKey(const ValueKey('adv_search_keyword')), 'hello');
      await tester.pump();
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();

      expect(got, isNotNull);
      expect(got!.keyword, 'hello');
      expect(got!.sender, '');
      expect(got!.from, isNull);
      expect(got!.to, isNull);
    });

    testWidgets('日期下拉选择（R-P4）→ filter 时间范围正确（零点/当日末）', (tester) async {
      MessageSearchFilter? got;
      await pumpOpener(
          tester,
          (ctx) => showAdvancedSearchDialog(
                ctx,
                onSearch: (f) => got = f,
              ));
      await typeAscii(
          tester, find.byKey(const ValueKey('adv_search_keyword')), 'report');
      await typeAscii(
          tester, find.byKey(const ValueKey('adv_search_sender')), 'b');

      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final yesterday = today.subtract(const Duration(days: 1));

      await tester.tap(find.byKey(const ValueKey('adv_search_from')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('昨天').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('adv_search_to')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('今天').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();

      expect(got, isNotNull);
      expect(got!.keyword, 'report');
      expect(got!.sender, 'b');
      expect(got!.from, yesterday, reason: '起始日期 → 当日零点');
      expect(got!.to,
          today.add(const Duration(hours: 23, minutes: 59, seconds: 59)),
          reason: '结束日期含当日（23:59:59）');
    });

    testWidgets('不选日期（默认不限）→ filter 不携带时间头', (tester) async {
      MessageSearchFilter? got;
      await pumpOpener(
          tester,
          (ctx) => showAdvancedSearchDialog(
                ctx,
                onSearch: (f) => got = f,
              ));
      await typeAscii(
          tester, find.byKey(const ValueKey('adv_search_keyword')), 'hello');
      await tester.pump();
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();

      expect(got, isNotNull);
      expect(got!.from, isNull, reason: '默认不限');
      expect(got!.to, isNull);
    });

    testWidgets('取消 → 关闭且无回调', (tester) async {
      var searched = false;
      await pumpOpener(
          tester,
          (ctx) => showAdvancedSearchDialog(
                ctx,
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
