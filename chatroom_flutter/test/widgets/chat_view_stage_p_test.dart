// ============================================================
// chat_view.dart 阶段 P —— 体验升级视图契约（TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 P（P1/P2/P3/P5 客户端视图）：
//
//   P1 富媒体消息气泡（图片/视频/文件内嵌预览气泡）：
//     - ChatView 新增可选参数 onVideoTap（ValueChanged<ChatMessage>?，
//       与 N3b onImageTap 对称）
//     - 视频文件消息（isVideoFilename + 未撤回 + 传输完成）→ 视频气泡：
//       深色卡片 + 播放图标（Icons.play_arrow_rounded）+ 文件名 +
//       大小行（filesize 已知时 formatFileSize；未知省略）；点击 →
//       onVideoTap(message)
//     - 视频传输中（transferFraction 非空）→ 不渲染视频气泡（N3b 破图
//       门控同款：文本气泡 + 进度条宿主）
//     - 已撤回视频 → 无视频气泡（[已撤回] 文本）
//     - 非媒体文件消息 → 文件卡片：通用文件图标
//       （Icons.insert_drive_file_rounded）+ 内容文本（保持既有
//       '[收到文件] x' 文案——N 系列测试回归）+ 大小行（可选）
//
//   P2 表情包体系（入口）：
//     - ChatView 新增可选参数 onShowStickerPicker（VoidCallback?）——
//       提供即输入栏显示表情包入口（Icons.mood_rounded，tooltip '表情包'）；
//       未提供不渲染（O 系列输入栏回归）
//     - 表情回应面板扩展：菜单"表情回应"展开后展示扩展表情集
//       （emojiPickerCategories 除默认 10 个外的表情，如 '🤣'），
//       点击触发 onAddReaction(messageId, emoji)；默认 10 个仍在
//
//   P3 复合条件消息搜索（入口）：
//     - ChatView 新增可选参数 onAdvancedSearch（VoidCallback?）——
//       搜索输入栏展开时显示"高级搜索"入口（tooltip '高级搜索'），
//       点击触发回调
//
//   P5 UI/UX 视觉升级：
//     - 消息气泡入场动效：新消息（isHistory=false）首次渲染带淡入+
//       上移动效（FadeTransition 存在，≤300ms 完成）；历史消息
//       （isHistory=true）无入场动效（上滑翻页/搜索结果不闪烁）
//     - 滚动到底部悬浮按钮（文档 §13.9 N5 后续扩展"滚底"归入本项）：
//       多消息且上滑离开底部时出现（tooltip '回到底部'）；点击回到底部
//       后消失；底部时不可见
//
// 实现前：本文件用例编译失败或断言红，属 TDD 红。实现后：全部转绿。
// ============================================================

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/widgets/chat_view.dart';

Widget wrap(Widget child) => MaterialApp(
    home: Scaffold(body: SizedBox(width: 600, height: 800, child: child)));

ChatMessage msg(
  String sender,
  String content,
  String id, {
  String status = 'sent',
  String type = 'chat',
  String? filename,
  int? filesize,
  bool isHistory = false,
}) =>
    ChatMessage(
      sender: sender,
      content: content,
      messageId: id,
      status: status,
      type: type,
      filename: filename,
      filesize: filesize,
      isHistory: isHistory,
    );

ChatView view(
  List<ChatMessage> messages, {
  String username = 'alice',
  ValueChanged<ChatMessage>? onVideoTap,
  ValueChanged<ChatMessage>? onFileTap,
  ValueChanged<ChatMessage>? onSaveSticker,
  VoidCallback? onShowStickerPicker,
  VoidCallback? onAdvancedSearch,
  ValueChanged<String>? onReplyMessage,
  void Function(String messageId, String emoji)? onAddReaction,
  double? Function(String messageId)? transferFraction,
}) {
  return ChatView(
    chatKey: 'bob',
    chatTitle: 'bob',
    messages: messages,
    username: username,
    inputCtrl: TextEditingController(),
    canSend: true,
    onSend: () {},
    onSendFile: () {},
    onRecall: (_) {},
    onLoadHistory: (_) async {},
    hasMoreHistory: (_) => false,
    transferFraction: transferFraction,
    onReplyMessage: onReplyMessage,
    onAddReaction: onAddReaction,
    onVideoTap: onVideoTap,
    onFileTap: onFileTap,
    onSaveSticker: onSaveSticker,
    onShowStickerPicker: onShowStickerPicker,
    onAdvancedSearch: onAdvancedSearch,
  );
}

void main() {
  group('P1 —— 视频消息内嵌预览气泡', () {
    testWidgets('视频文件消息 → 视频气泡（播放图标 + 文件名 + 大小行）', (tester) async {
      await tester.pumpWidget(wrap(view([
        msg('bob', '[收到文件] clip.mp4', 'v1',
            type: 'file', filename: 'clip.mp4', filesize: 1048576),
      ], onVideoTap: (_) {})));
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget,
          reason: '视频气泡带播放图标');
      expect(find.text('clip.mp4'), findsOneWidget, reason: '显示文件名');
      expect(find.text('1.0 MB'), findsOneWidget, reason: 'filesize 已知显示大小行');
      expect(find.byType(Image), findsNothing, reason: '视频不是内联图片');
    });

    testWidgets('视频消息无 filesize → 显示文件名、省略大小行（不崩溃）', (tester) async {
      await tester.pumpWidget(wrap(view([
        msg('bob', '[收到文件] clip.mp4', 'v2', type: 'file', filename: 'clip.mp4'),
      ], onVideoTap: (_) {})));
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.text('clip.mp4'), findsOneWidget);
    });

    testWidgets('点击视频气泡 → onVideoTap(message)', (tester) async {
      final tapped = <ChatMessage>[];
      await tester.pumpWidget(wrap(view([
        msg('bob', '[收到文件] clip.mp4', 'v3',
            type: 'file', filename: 'clip.mp4', filesize: 2048),
      ], onVideoTap: tapped.add)));
      // 先泵完入场动效（完全透明期间 RenderOpacity 跳过命中测试）
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pumpAndSettle();
      expect(tapped.map((m) => m.messageId), ['v3']);
    });

    testWidgets('传输中的视频不渲染视频气泡（N3b 破图门控同款）', (tester) async {
      await tester.pumpWidget(wrap(view([
        msg('bob', '[收到文件] clip.mp4', 'v4',
            type: 'file', filename: 'clip.mp4', filesize: 2048),
      ], transferFraction: (id) => id == 'v4' ? 0.5 : null)));
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing,
          reason: '传输中不渲染视频气泡');
      expect(find.text('[收到文件] clip.mp4'), findsOneWidget,
          reason: '传输中保持文本气泡（进度条宿主）');
    });

    testWidgets('已撤回视频消息 → 无视频气泡，显示已撤回文本', (tester) async {
      await tester.pumpWidget(wrap(view([
        msg('bob', '[收到文件] clip.mp4', 'v5',
            type: 'file', filename: 'clip.mp4', status: 'recalled'),
      ], onVideoTap: (_) {})));
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
      expect(find.textContaining('[已撤回]'), findsOneWidget);
    });
  });

  group('P1 —— 非媒体文件卡片', () {
    testWidgets('非媒体文件 → 文件卡片（图标 + 内容文本 + 大小行）', (tester) async {
      await tester.pumpWidget(wrap(view([
        msg('bob', '[收到文件] report.pdf', 'f1',
            type: 'file', filename: 'report.pdf', filesize: 1536),
      ])));
      expect(find.byIcon(Icons.insert_drive_file_rounded), findsOneWidget,
          reason: '通用文件图标');
      expect(find.text('[收到文件] report.pdf'), findsOneWidget,
          reason: '内容文本保持既有文案（N 系列回归）');
      expect(find.text('1.5 KB'), findsOneWidget);
    });

    testWidgets('非媒体文件无 filesize → 无大小行', (tester) async {
      await tester.pumpWidget(wrap(view([
        msg('bob', '[收到文件] report.pdf', 'f2',
            type: 'file', filename: 'report.pdf'),
      ])));
      expect(find.byIcon(Icons.insert_drive_file_rounded), findsOneWidget);
      expect(find.text('[收到文件] report.pdf'), findsOneWidget);
    });

    testWidgets('P1 回归：N3b 图片内联展示与点击不受影响', (tester) async {
      final tapped = <ChatMessage>[];
      await tester.pumpWidget(wrap(view([
        ChatMessage(
          sender: 'bob',
          content: '[收到文件] photo.png',
          messageId: 'p1',
          type: 'file',
          filename: 'photo.png',
          fileData: Uint8List.fromList([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01 //
          ]),
        ),
      ], onVideoTap: tapped.add)));
      // 既有 ChatView 构造需 onImageTap 才有点击——此处仅锁定内联渲染不回退
      expect(find.byType(Image), findsOneWidget, reason: 'N3b 内联图片不回退');
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing,
          reason: '图片不是视频');
    });
  });

  group('P2 —— 表情包入口（输入栏）', () {
    testWidgets('提供 onShowStickerPicker → 输入栏显示表情包入口', (tester) async {
      await tester.pumpWidget(
          wrap(view([msg('alice', 'hi', 'm1')], onShowStickerPicker: () {})));
      expect(find.byIcon(Icons.mood_rounded), findsOneWidget);
      expect(find.byTooltip('表情包'), findsOneWidget);
    });

    testWidgets('点击表情包入口 → 触发 onShowStickerPicker', (tester) async {
      var opened = false;
      await tester.pumpWidget(wrap(view([msg('alice', 'hi', 'm2')],
          onShowStickerPicker: () => opened = true)));
      await tester.tap(find.byIcon(Icons.mood_rounded));
      await tester.pumpAndSettle();
      expect(opened, isTrue);
    });

    testWidgets('未提供 onShowStickerPicker → 不渲染入口（O 系列回归）', (tester) async {
      await tester.pumpWidget(wrap(view([msg('alice', 'hi', 'm3')])));
      expect(find.byTooltip('表情包'), findsNothing);
    });
  });

  group('P2 —— 表情回应面板扩展表情集', () {
    testWidgets('菜单"表情回应"展开后包含扩展表情（默认 10 个之外）', (tester) async {
      await tester.pumpWidget(wrap(view([msg('alice', '会被回应', 'r1')],
          onReplyMessage: (_) {}, onAddReaction: (_, __) {})));
      await tester.longPress(find.text('会被回应'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('表情回应'));
      await tester.pumpAndSettle();

      expect(find.text('👍'), findsOneWidget, reason: '默认盘回归：👍 仍在');
      // 扩展集代表 emoji（emojiPickerCategories 契约保证存在 '🤣'）
      final extended = emojiPickerCategories
          .expand((c) => c.$2)
          .where((e) => !defaultReactionEmojis.contains(e))
          .toList();
      expect(extended, isNotEmpty, reason: '扩展集存在默认盘之外的表情');
      expect(find.text(extended.first), findsOneWidget, reason: '扩展表情出现在面板中');
    });

    testWidgets('点击扩展表情 → onAddReaction(messageId, emoji)', (tester) async {
      final reactions = <String>[];
      await tester.pumpWidget(wrap(view([msg('alice', '会被回应', 'r2')],
          onReplyMessage: (_) {},
          onAddReaction: (_, emoji) => reactions.add(emoji))));
      await tester.longPress(find.text('会被回应'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('表情回应'));
      await tester.pumpAndSettle();

      final extended = emojiPickerCategories
          .expand((c) => c.$2)
          .where((e) => !defaultReactionEmojis.contains(e))
          .first;
      await tester.tap(find.text(extended));
      await tester.pumpAndSettle();
      expect(reactions, [extended]);
    });
  });

  group('P2/R-P3 —— 图片消息"添加到表情包"与文件卡片预览', () {
    testWidgets('图片消息菜单含"添加到表情包" → 点击回调', (tester) async {
      final saved = <ChatMessage>[];
      await tester.pumpWidget(wrap(view([
        ChatMessage(
          sender: 'bob',
          content: '[收到文件] photo.png',
          messageId: 'stk1',
          type: 'file',
          filename: 'photo.png',
          fileData: Uint8List.fromList(
              [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01]),
        ),
      ], onSaveSticker: saved.add)));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.longPress(find.byType(Image));
      await tester.pumpAndSettle();

      await tester.tap(find.text('添加到表情包'));
      await tester.pumpAndSettle();
      expect(saved.map((m) => m.messageId), ['stk1']);
    });

    testWidgets('非图片消息菜单无"添加到表情包"入口', (tester) async {
      await tester.pumpWidget(wrap(view(
        [msg('alice', '普通文字', 'txt1')],
        onSaveSticker: (_) {},
      )));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.longPress(find.text('普通文字'));
      await tester.pumpAndSettle();
      expect(find.text('添加到表情包'), findsNothing, reason: '仅图片消息提供收藏入口');
    });

    testWidgets('文件卡片点击 → onFileTap(message)', (tester) async {
      final tapped = <ChatMessage>[];
      await tester.pumpWidget(wrap(view([
        msg('bob', '[收到文件] report.pdf', 'fp1',
            type: 'file', filename: 'report.pdf', filesize: 1536),
      ], onFileTap: tapped.add)));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byIcon(Icons.insert_drive_file_rounded));
      await tester.pumpAndSettle();
      expect(tapped.map((m) => m.messageId), ['fp1'], reason: 'R-P2 文件预览');
    });
  });

  group('P3 —— 高级搜索入口', () {
    testWidgets('搜索输入栏展开时显示"高级搜索"入口', (tester) async {
      await tester.pumpWidget(wrap(view(
        [msg('alice', 'hi', 's1')],
        onAdvancedSearch: () {},
      )));
      // 展开搜索输入栏（点击标题栏搜索按钮）
      await tester.tap(find.byTooltip('搜索消息'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('高级搜索'), findsOneWidget);
    });

    testWidgets('点击"高级搜索" → 触发 onAdvancedSearch', (tester) async {
      var opened = false;
      await tester.pumpWidget(wrap(view(
        [msg('alice', 'hi', 's2')],
        onAdvancedSearch: () => opened = true,
      )));
      await tester.tap(find.byTooltip('搜索消息'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('高级搜索'));
      await tester.pumpAndSettle();
      expect(opened, isTrue);
    });
  });

  group('P5 —— 消息气泡入场动效', () {
    /// 判别某消息文本与 ListView 之间是否存在入场动效包装
    /// （路由层 Zoom/Fade 转场位于 ListView 之上，不计入）
    bool bubbleAnimated(WidgetTester tester, String text,
        {bool slideOnly = false}) {
      final elm = tester.element(find.text(text));
      var animated = false;
      var reachedList = false;
      elm.visitAncestorElements((ancestor) {
        if (ancestor.widget is ListView) reachedList = true;
        if (!reachedList) {
          final w = ancestor.widget;
          if (w is SlideTransition || (!slideOnly && w is FadeTransition)) {
            animated = true;
          }
        }
        return true;
      });
      return animated;
    }

    testWidgets('新消息（isHistory=false）带入场动效（淡入+上移，≤300ms 完成）', (tester) async {
      await tester.pumpWidget(wrap(view([msg('alice', '新消息动效', 'a1')])));
      expect(bubbleAnimated(tester, '新消息动效'), isTrue, reason: '新消息气泡带淡入动效');
      expect(bubbleAnimated(tester, '新消息动效', slideOnly: true), isTrue,
          reason: '新消息气泡带上移滑入动效');

      await tester.pump(const Duration(milliseconds: 300));
      // 动效完成后：文本向上到 ListView 之间的 FadeTransition 应完全不透明
      final elm = tester.element(find.text('新消息动效'));
      var reachedList = false;
      elm.visitAncestorElements((ancestor) {
        if (ancestor.widget is ListView) reachedList = true;
        if (!reachedList && ancestor.widget is FadeTransition) {
          final fade = ancestor.widget as FadeTransition;
          expect(fade.opacity.value, 1.0, reason: '动效 ≤300ms 完成（完全不透明）');
        }
        return true;
      });
    });

    testWidgets('历史消息（isHistory=true）无入场动效（翻页/搜索不闪烁）', (tester) async {
      await tester.pumpWidget(
          wrap(view([msg('bob', '历史消息静态', 'h1', isHistory: true)])));
      // 注：页面路由（Zoom/FadeUpwards 转场）在 ListView 之上常驻多个
      // Slide/FadeTransition 祖先——以"文本到 ListView 之间"为判别范围
      expect(bubbleAnimated(tester, '历史消息静态'), isFalse,
          reason: '历史消息直接渲染，不做入场动效');
    });
  });

  group('P5 —— 滚动到底部悬浮按钮', () {
    List<ChatMessage> manyMessages(int n) => [
          for (var i = 0; i < n; i++) msg('alice', '消息内容 $i', 'm-$i'),
        ];

    testWidgets('底部（最新消息可见）时不显示滚底按钮', (tester) async {
      await tester.pumpWidget(wrap(view(manyMessages(30))));
      await tester.pumpAndSettle();
      expect(find.byTooltip('回到底部'), findsNothing, reason: '已在底部，无滚底按钮');
    });

    testWidgets('上滑离开底部 → 按钮出现；点击 → 回到底部并消失', (tester) async {
      await tester.pumpWidget(wrap(view(manyMessages(30))));
      await tester.pumpAndSettle();

      // reverse 列表：向下拖拽 = 滚向更旧消息（离开底部）
      await tester.drag(find.byType(ListView), const Offset(0, 600));
      await tester.pumpAndSettle();

      expect(find.byTooltip('回到底部'), findsOneWidget, reason: '离开底部后滚底按钮出现');

      await tester.tap(find.byTooltip('回到底部'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('回到底部'), findsNothing, reason: '回到底部后按钮消失');
      expect(find.text('消息内容 29'), findsOneWidget, reason: '最新消息可见');
    });
  });

  group('R-P10 —— 消息正文 emoji 彩色渲染', () {
    testWidgets('气泡文本 fontFamilyFallback 兜底 NotoColorEmoji', (tester) async {
      await tester.pumpWidget(wrap(view([
        msg('bob', '你好 👍', 'emoji-1'),
      ])));
      await tester.pumpAndSettle();
      final text = tester.widget<Text>(find.text('你好 👍'));
      expect(text.style?.fontFamilyFallback, contains('NotoColorEmoji'),
          reason: '缺省字体链 fontconfig 可能命中黑白 emoji 字形——正文必须兜底内置 COLRv1 字体');
    });
  });
}
