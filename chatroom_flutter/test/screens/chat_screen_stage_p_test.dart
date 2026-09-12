// ============================================================
// chat_screen.dart 阶段 P —— 体验升级接线契约（TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 P（P1/P2/P3/P4/P5 接线）：
//
//   P1 视频查看器：视频气泡点击 → 黑底全屏查看器（含文件名），点击关闭
//   P2 贴纸发送：表情入口 → 面板 → 选中贴纸 → sendFileBytes(会话, 字节,
//      sticker.name)（复用 N3 通道，接收端按图片消息内联展示）
//   P3 高级搜索：高级搜索对话框 → searchHistory(关键词, to/groupId,
//      sender, timeFrom, timeTo) 按会话路由（私聊 to / 群聊 group_id；
//      未填字段传 null——不发空串头）；系统会话无高级搜索入口
//   P4 图片标注：预览条"标注"按钮 → 编辑器（预览字节）→ 完成 → 预览
//      更新为合成字节
//   P5 多尺寸无溢出回归：ChatScreen 在 4 档窗口尺寸下无布局异常
//      （视觉升级改动不破坏布局）
//
// 注意：高级搜索对话框输入框为 RawTextField（R-O1 惯例），文本经键盘
// 事件注入（typeAscii，仅 ASCII）。
// 实现前：本文件引用尚未实现的 API，编译失败或用例红，属 TDD 红。
// 实现后：全部转绿。
// ============================================================

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/screens/chat_screen.dart';
import 'package:chatroom_flutter/services/socket_service.dart';
import 'package:chatroom_flutter/services/state_manager.dart';
import 'package:chatroom_flutter/services/sticker_store.dart';
import 'package:chatroom_flutter/widgets/raw_text_field.dart';

class MockSocketService extends Mock implements SocketService {}

AppState get state => AppState.instance;

void resetState() {
  state
    ..setLoggedOut()
    ..setConnectionStatus(ConnectionStatus.disconnected);
}

final Uint8List pngBytes = Uint8List.fromList(
    [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03]);

void stubCommon(MockSocketService socket) {
  when(() => socket.sendFileBytes(any(), any(), any()))
      .thenAnswer((_) async => true);
  when(() => socket.fetchGroupAnnouncements(any())).thenAnswer((_) async {});
  when(() => socket.saveConversationDraft(any(), any()))
      .thenAnswer((_) async {});
  when(() => socket.searchHistory(any(),
      to: any(named: 'to'),
      groupId: any(named: 'groupId'),
      limit: any(named: 'limit'),
      senders: any(named: 'senders'),
      timeFrom: any(named: 'timeFrom'),
      timeTo: any(named: 'timeTo'))).thenAnswer((_) async {});
  when(() => socket.fetchGroupMembers(any())).thenAnswer((_) async {});
}

Future<void> pumpScreen(WidgetTester tester, MockSocketService socket,
    {Size size = const Size(1200, 800)}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    home: ChatScreen(socketService: socket),
    routes: {'/login': (_) => const Scaffold(body: Text('LOGIN'))},
  ));
  await tester.pumpAndSettle();
}

/// RawTextField 文本注入（键盘事件，仅 ASCII）
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
  TestWidgetsFlutterBinding.ensureInitialized();
  registerFallbackValue(Uint8List(0));
  registerFallbackValue(DateTime(2026));
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    resetState();
  });

  group('P1 —— 视频查看器接线', () {
    testWidgets('点击视频气泡 → 全屏查看器（含文件名）；点击关闭无异常', (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');
      state.addMessage(
        'bob',
        ChatMessage(
          sender: 'bob',
          content: '[收到文件] movie.mp4',
          messageId: 'v-1',
          type: 'file',
          filename: 'movie.mp4',
          filesize: 2048,
          fileData: pngBytes,
        ),
      );

      await pumpScreen(tester, socket);
      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pumpAndSettle();

      expect(find.text('movie.mp4'), findsWidgets, reason: '查看器显示文件名');
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('movie.mp4').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('P2/R-P3 —— 贴纸发送接线（表情包模块）', () {
    testWidgets('表情入口 → 表情包模块 → 选中贴纸 → sendFileBytes(会话, 字节, name)',
        (tester) async {
      final dir = Directory.systemTemp.createTempSync('sticker_screen_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      await StickerStore.instance.init(baseDir: dir.path);
      await StickerStore.instance.bindUser(null);
      final sticker = await StickerStore.instance.addSticker(pngBytes);

      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');

      await pumpScreen(tester, socket);

      await tester.tap(find.byTooltip('表情包'));
      await tester.pumpAndSettle();
      // 切到表情包模块（微信式双模块面板）
      await tester.tap(find.text('表情包').last);
      await tester.pumpAndSettle();

      expect(find.text('添加表情包'), findsOneWidget, reason: '添加入口恒可用');

      await tester.tap(find.byType(Image).first);
      await tester.pumpAndSettle();

      verify(() => socket.sendFileBytes('bob', pngBytes, sticker!.name))
          .called(1);
    });

    testWidgets('表情模块：点击表情插入输入框（不发送文件）', (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');

      await pumpScreen(tester, socket);

      await tester.tap(find.byTooltip('表情包'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('👍').first);
      await tester.pumpAndSettle();

      final input =
          tester.widget<RawTextField>(find.byType(RawTextField).first);
      expect(input.controller.text, '👍', reason: '表情插入输入框（光标处）');
      verifyNever(() => socket.sendFileBytes(any(), any(), any()));
    });
  });

  group('P3 —— 高级搜索接线', () {
    testWidgets('私聊会话：高级搜索 → searchHistory(to, 其他未填字段为 null)', (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');

      await pumpScreen(tester, socket);

      await tester.tap(find.byTooltip('搜索消息'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('高级搜索'));
      await tester.pumpAndSettle();

      await typeAscii(
          tester, find.byKey(const ValueKey('adv_search_keyword')), 'hello');
      await tester.pump();
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();

      verify(() => socket.searchHistory('hello',
          to: 'bob',
          groupId: null,
          limit: any(named: 'limit'),
          senders: [],
          timeFrom: null,
          timeTo: null)).called(1);
    });

    testWidgets('群会话：高级搜索按 group_id 路由', (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.setGroups([
        Group(id: 1, name: '项目群', members: const ['alice', 'bob']),
      ]);
      state.selectChat('group_1');

      await pumpScreen(tester, socket);

      await tester.tap(find.byTooltip('搜索消息'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('高级搜索'));
      await tester.pumpAndSettle();

      await typeAscii(
          tester, find.byKey(const ValueKey('adv_search_keyword')), 'meeting');
      await tester.pump();
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();

      verify(() => socket.searchHistory('meeting',
          to: null,
          groupId: 1,
          limit: any(named: 'limit'),
          senders: [],
          timeFrom: null,
          timeTo: null)).called(1);
    });

    testWidgets('系统会话（服务器）：无搜索入口，也就无高级搜索入口', (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.selectChat('服务器');
      state.addMessage(
          '服务器',
          ChatMessage(
              sender: '服务器',
              content: '公告',
              type: 'system',
              messageId: 'sys-1'));

      await pumpScreen(tester, socket);

      expect(find.byTooltip('搜索消息'), findsNothing, reason: '系统会话只读无搜索入口（既有契约）');
      expect(find.byTooltip('高级搜索'), findsNothing);
    });
  });

  group('P4/R-P5 —— 图片标注接线（粘贴自动进编辑器）', () {
    testWidgets('粘贴图片 → 自动进入标注编辑器（工具栏渲染）', (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');

      await pumpScreen(tester, socket);

      final input =
          tester.widget<RawTextField>(find.byType(RawTextField).first);
      input.onImagePasted?.call(pngBytes);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('annotation_canvas')), findsOneWidget,
          reason: '自动进入标注编辑器');
      expect(find.text('发送'), findsOneWidget, reason: '编辑后发送/直接发送');
      expect(find.byTooltip('取消'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('不编辑直接"发送" → sendFileBytes（直通原字节）', (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');

      await pumpScreen(tester, socket);

      final input =
          tester.widget<RawTextField>(find.byType(RawTextField).first);
      input.onImagePasted?.call(pngBytes);
      await tester.pumpAndSettle();

      await tester.tap(find.text('发送'));
      await tester.pumpAndSettle();

      verify(() => socket.sendFileBytes('bob', pngBytes, 'pasted_image.png'))
          .called(1);
      expect(find.byKey(const ValueKey('annotation_canvas')), findsNothing,
          reason: '发送后编辑器关闭');
    });

    testWidgets('"取消" → 不发送', (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');

      await pumpScreen(tester, socket);

      final input =
          tester.widget<RawTextField>(find.byType(RawTextField).first);
      input.onImagePasted?.call(pngBytes);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('取消'));
      await tester.pumpAndSettle();

      verifyNever(() => socket.sendFileBytes(any(), any(), any()));
      expect(find.byKey(const ValueKey('annotation_canvas')), findsNothing);
    });

    testWidgets('R-P12：点"直接发送" → 原图直发（不经合成，文件名不变）', (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');

      await pumpScreen(tester, socket);

      final input =
          tester.widget<RawTextField>(find.byType(RawTextField).first);
      input.onImagePasted?.call(pngBytes);
      await tester.pumpAndSettle();

      await tester.tap(find.text('直接发送'));
      await tester.pumpAndSettle();

      verify(() => socket.sendFileBytes('bob', pngBytes, 'pasted_image.png'))
          .called(1);
      expect(find.byKey(const ValueKey('annotation_canvas')), findsNothing,
          reason: '直发后编辑器关闭');
    });
  });

  group('P5 —— 多尺寸无溢出回归', () {
    for (final size in [
      const Size(1920, 1080),
      const Size(1280, 720),
      const Size(1024, 640),
      const Size(900, 600),
    ]) {
      testWidgets('${size.width}x${size.height} 无布局异常', (tester) async {
        final socket = MockSocketService();
        stubCommon(socket);
        state.setLoggedIn('alice', false);
        state.setFriends(['bob']);
        state.selectChat('bob');
        state.addMessage(
            'bob',
            ChatMessage(
                sender: 'bob',
                content: '一段比较长的消息内容，用来检查文本换行与气泡自适应宽度在窗口缩放时的布局稳定性。',
                messageId: 'long-1'));
        state.addMessage('bob',
            ChatMessage(sender: 'alice', content: '回复', messageId: 'long-2'));

        await pumpScreen(tester, socket, size: size);
        expect(tester.takeException(), isNull,
            reason: '${size.width}x${size.height} 下不抛布局异常');
      });
    }
  });
}
