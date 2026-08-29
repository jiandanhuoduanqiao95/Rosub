// ============================================================
// chat_view.dart 阶段 N —— N1 消息长按菜单：复制 / 永久删除（TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 N（N1 P2-2）：
//
//   复制：文字消息（chat/group_chat）长按菜单新增"复制"——复制消息
//   内容文本到剪贴板（当前不可用）。
//   永久删除：新增"永久删除"——本地缓存中彻底移除（内存 + MessageCache，
//   重登后不恢复）；与"仅我删除"（内存移除，重登后从服务端历史恢复）
//   语义区分。
//   撤回：既有入口（双方消失，2 分钟窗口由接线层控制），语义不变。
//
//   菜单语义区分（实现契约）：
//     - 自己的文字消息：复制 / 仅我删除 / 永久删除 / 撤回
//     - 对方的文字消息：复制 / 永久删除（无仅我删除/撤回）
//     - 文件消息：维持 P-33 行为（仅自己的文件有"撤回"入口，无复制/永久删除）
//     - 系统 / 已撤回消息：不弹菜单（既有行为）
//     - 复制的是消息内容本身（引用消息复制 content，非 replyPreview）
//
// ChatView 新增可选参数 onDeletePermanently（提供即启用菜单模式，
// 与既有 K5 回调同语义）。实现前：本文件用例红，属 TDD 红。
// 实现后：全部转绿。
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/widgets/chat_view.dart';

/// 最小 PNG 字节（N3b 内联渲染测试用）
final Uint8List pngBytes = Uint8List.fromList(
    [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03]);

Widget wrap(Widget child) => MaterialApp(
    home: Scaffold(body: SizedBox(width: 600, height: 800, child: child)));

ChatMessage msg(
  String sender,
  String content,
  String id, {
  String status = 'sent',
  String type = 'chat',
  String? replyTo,
  String? replyPreview,
  String? filename,
  Uint8List? fileData,
}) =>
    ChatMessage(
      sender: sender,
      content: content,
      messageId: id,
      status: status,
      type: type,
      replyTo: replyTo,
      replyPreview: replyPreview,
      filename: filename,
      fileData: fileData,
    );

ChatView view(
  List<ChatMessage> messages, {
  String username = 'alice',
  ValueChanged<String>? onDeletePermanently,
  ValueChanged<String>? onDeleteMessage,
  ValueChanged<String>? onRecall,
  ValueChanged<ChatMessage>? onImageTap,
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
    onRecall: onRecall ?? (_) {},
    onLoadHistory: (_) async {},
    hasMoreHistory: (_) => false,
    transferFraction: transferFraction,
    onReplyMessage: (_) {},
    onForwardMessage: (_) {},
    onAddReaction: (_, __) {},
    onDeleteMessage: onDeleteMessage ?? (_) {},
    onDeletePermanently: onDeletePermanently,
    onJumpToMessage: (_) {},
    onImageTap: onImageTap,
  );
}

/// mock 剪贴板通道并收集调用记录（返回清理函数）。
void mockClipboard(List<MethodCall> log) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
    log.add(call);
    return null;
  });
}

void main() {
  group('N1 —— 消息长按菜单：复制 / 永久删除', () {
    testWidgets('自己的文字消息菜单：复制/仅我删除/永久删除/撤回 四入口共存', (tester) async {
      await tester.pumpWidget(wrap(view(
        [msg('alice', '自己的消息', 'm1')],
        onDeletePermanently: (_) {},
        onRecall: (_) {},
      )));
      await tester.longPress(find.text('自己的消息'));
      await tester.pumpAndSettle();
      expect(find.text('复制'), findsOneWidget);
      expect(find.text('仅我删除'), findsOneWidget);
      expect(find.text('永久删除'), findsOneWidget);
      expect(find.text('撤回'), findsOneWidget);
    });

    testWidgets('对方文字消息菜单：复制/永久删除，无 仅我删除/撤回', (tester) async {
      await tester.pumpWidget(wrap(view(
        [msg('bob', '对方的消息', 'm2')],
        onDeletePermanently: (_) {},
        onRecall: (_) {},
      )));
      await tester.longPress(find.text('对方的消息'));
      await tester.pumpAndSettle();
      expect(find.text('复制'), findsOneWidget);
      expect(find.text('永久删除'), findsOneWidget);
      expect(find.text('仅我删除'), findsNothing, reason: '对方消息无仅我删除');
      expect(find.text('撤回'), findsNothing, reason: '对方消息无撤回');
    });

    testWidgets('群聊消息（对方）长按：复制/永久删除 可用', (tester) async {
      await tester.pumpWidget(wrap(view(
        [msg('carol', '群聊内容', 'g1', type: 'group_chat')],
        onDeletePermanently: (_) {},
      )));
      await tester.longPress(find.text('群聊内容'));
      await tester.pumpAndSettle();
      expect(find.text('复制'), findsOneWidget);
      expect(find.text('永久删除'), findsOneWidget);
    });

    testWidgets('复制自己的消息 → 剪贴板写入消息内容', (tester) async {
      final log = <MethodCall>[];
      mockClipboard(log);
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      await tester.pumpWidget(wrap(view(
        [msg('alice', '要复制的内容', 'm-copy-1')],
        onDeletePermanently: (_) {},
      )));
      await tester.longPress(find.text('要复制的内容'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();
      expect(
        log.any((c) =>
            c.method == 'Clipboard.setData' &&
            (c.arguments as Map)['text'] == '要复制的内容'),
        isTrue,
        reason: '复制应写入消息内容文本',
      );
    });

    testWidgets('复制对方的消息 → 同样写入内容（复制与归属无关）', (tester) async {
      final log = <MethodCall>[];
      mockClipboard(log);
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      await tester.pumpWidget(wrap(view(
        [msg('bob', '对方的内容', 'm-copy-2')],
        onDeletePermanently: (_) {},
      )));
      await tester.longPress(find.text('对方的内容'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();
      expect(
        log.any((c) =>
            c.method == 'Clipboard.setData' &&
            (c.arguments as Map)['text'] == '对方的内容'),
        isTrue,
      );
    });

    testWidgets('引用消息复制的是内容本体而非引用缩略', (tester) async {
      final log = <MethodCall>[];
      mockClipboard(log);
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      await tester.pumpWidget(wrap(view(
        [msg('alice', '我的回复', 'm-copy-3', replyTo: 'm0', replyPreview: '原文')],
        onDeletePermanently: (_) {},
      )));
      await tester.longPress(find.text('我的回复'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();
      expect(
        log.any((c) =>
            c.method == 'Clipboard.setData' &&
            (c.arguments as Map)['text'] == '我的回复'),
        isTrue,
        reason: '复制内容应为消息本体，非 replyPreview',
      );
    });

    testWidgets('永久删除自己的消息 → onDeletePermanently(messageId)', (tester) async {
      final deleted = <String>[];
      await tester.pumpWidget(wrap(view(
        [msg('alice', '自己的消息', 'm-perm-1')],
        onDeletePermanently: deleted.add,
      )));
      await tester.longPress(find.text('自己的消息'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('永久删除'));
      await tester.pumpAndSettle();
      expect(deleted, ['m-perm-1']);
    });

    testWidgets('永久删除对方的消息 → onDeletePermanently(messageId)', (tester) async {
      final deleted = <String>[];
      await tester.pumpWidget(wrap(view(
        [msg('bob', '对方的消息', 'm-perm-2')],
        onDeletePermanently: deleted.add,
      )));
      await tester.longPress(find.text('对方的消息'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('永久删除'));
      await tester.pumpAndSettle();
      expect(deleted, ['m-perm-2']);
    });

    testWidgets('文件消息菜单保持 P-33：仅"撤回"入口，无复制/永久删除', (tester) async {
      await tester.pumpWidget(wrap(view(
        [
          ChatMessage(
            sender: 'alice',
            content: '[发送文件] a.pdf',
            messageId: 'f1',
            type: 'file',
            filename: 'a.pdf',
          ),
        ],
        onDeletePermanently: (_) {},
        onRecall: (_) {},
      )));
      await tester.longPress(find.text('[发送文件] a.pdf'));
      await tester.pumpAndSettle();
      expect(find.text('撤回'), findsOneWidget);
      expect(find.text('复制'), findsNothing, reason: '文件无文本可复制');
      expect(find.text('永久删除'), findsNothing, reason: '文件菜单不新增永久删除');
    });

    testWidgets('已撤回消息不弹菜单（既有行为回归）', (tester) async {
      await tester.pumpWidget(wrap(view(
        [msg('alice', '已撤回内容', 'm-recalled', status: 'recalled')],
        onDeletePermanently: (_) {},
        onRecall: (_) {},
      )));
      await tester.longPress(find.textContaining('[消息已撤回]'));
      await tester.pumpAndSettle();
      expect(find.text('复制'), findsNothing);
      expect(find.text('永久删除'), findsNothing);
      expect(find.text('撤回'), findsNothing);
    });

    testWidgets('系统消息不弹菜单（既有行为回归）', (tester) async {
      await tester.pumpWidget(wrap(view(
        [msg('系统', '公告内容', 'sys1', type: 'system')],
        onDeletePermanently: (_) {},
        onRecall: (_) {},
      )));
      await tester.longPress(find.text('公告内容'));
      await tester.pumpAndSettle();
      expect(find.text('复制'), findsNothing);
      expect(find.text('永久删除'), findsNothing);
    });
  });

  group('N3b —— 小图片内联展示 + 点击全屏（P2-4 扩展）', () {
    testWidgets('图片文件消息渲染内联 Image；非图片文件不渲染', (tester) async {
      await tester.pumpWidget(wrap(view([
        msg('alice', '[收到文件] photo.png', 'img1',
            type: 'file', filename: 'photo.png', fileData: pngBytes),
        msg('alice', '[收到文件] doc.pdf', 'doc1',
            type: 'file', filename: 'doc.pdf'),
      ])));
      expect(find.byType(Image), findsOneWidget, reason: '图片文件消息应渲染内联 Image');
      expect(find.text('[收到文件] doc.pdf'), findsOneWidget,
          reason: '非图片文件消息保持文本气泡');
    });

    testWidgets('点击图片消息触发 onImageTap', (tester) async {
      final tapped = <ChatMessage>[];
      await tester.pumpWidget(wrap(view(
        [
          msg('alice', '[收到文件] photo.png', 'img2',
              type: 'file', filename: 'photo.png', fileData: pngBytes)
        ],
        onImageTap: tapped.add,
      )));
      await tester.tap(find.byType(Image));
      await tester.pumpAndSettle();
      expect(tapped.map((m) => m.messageId), ['img2']);
    });

    testWidgets('已撤回图片消息不内联（显示已撤回文本）', (tester) async {
      await tester.pumpWidget(wrap(view(
        [
          msg('alice', '[收到文件] photo.png', 'img3',
              status: 'recalled',
              type: 'file',
              filename: 'photo.png',
              fileData: pngBytes)
        ],
      )));
      expect(find.byType(Image), findsNothing, reason: '已撤回图片不显示内联图');
      expect(find.textContaining('[已撤回]'), findsOneWidget);
    });

    testWidgets('N3b 回归（问题 1：破图）—— 传输中不内联，完成后才渲染', (tester) async {
      // 传输中（transferFraction 非空，文件尚未完整落盘）：不渲染 Image，
      // 显示文本（进度条宿主）——避免 Image.file 加载半截文件显示破图
      await tester.pumpWidget(wrap(view(
        [
          msg('alice', '[收到文件] photo.png', 'img4',
              type: 'file', filename: 'photo.png', fileData: pngBytes)
        ],
        transferFraction: (id) => id == 'img4' ? 0.5 : null,
      )));
      expect(find.byType(Image), findsNothing, reason: '传输中不渲染内联图（防破图）');
      expect(find.text('[收到文件] photo.png'), findsOneWidget,
          reason: '传输中显示文本气泡（进度条宿主）');

      // 传输完成（transferFraction 变 null）→ 重建后渲染内联图
      await tester.pumpWidget(wrap(view(
        [
          msg('alice', '[收到文件] photo.png', 'img4',
              type: 'file', filename: 'photo.png', fileData: pngBytes)
        ],
        transferFraction: (_) => null,
      )));
      expect(find.byType(Image), findsOneWidget, reason: '传输完成后应渲染内联图');
    });
  });
}
