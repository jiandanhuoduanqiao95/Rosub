// opt8 #1/#13 —— 附件气泡路径解析收敛（chat_view）
//
// 契约：
//   - 重启场景（fileData 未持久化 = null）：自己发送的图片经 filePath /
//     SentFileStore 仍渲染缩略图（#1）；
//   - 接收图片无 filePath 时经唯一接收路径（messageId 前缀）解析，
//     两个同名文件不串图（#13）；
//   - N3b 门控不变：传输中（transferFraction 非空）不内联。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/message_attachment.dart';
import 'package:chatroom_flutter/services/sent_file_store.dart';
import 'package:chatroom_flutter/widgets/chat_view.dart';

const prefix = 'opt8view_';

final Uint8List pngBytes = Uint8List.fromList(
    [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03]);

final Uint8List otherBytes = Uint8List.fromList(
    [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x09, 0x08, 0x07]);

Widget wrap(Widget child) => MaterialApp(
    home: Scaffold(body: SizedBox(width: 600, height: 800, child: child)));

ChatMessage msg(
  String sender,
  String content,
  String id, {
  String status = 'sent',
  String type = 'chat',
  String? filename,
  Uint8List? fileData,
  String? filePath,
}) =>
    ChatMessage(
      sender: sender,
      content: content,
      messageId: id,
      status: status,
      type: type,
      filename: filename,
      fileData: fileData,
      filePath: filePath,
    );

ChatView view(
  List<ChatMessage> messages, {
  String username = 'alice',
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
    onReplyMessage: (_) {},
    onForwardMessage: (_) {},
    onAddReaction: (_, __) {},
    onDeleteMessage: (_) {},
    onJumpToMessage: (_) {},
    onImageTap: (_) {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final created = <String>[];

  File touch(String path, [List<int> bytes = const [1, 2, 3]]) {
    final f = File(path);
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(bytes);
    created.add(path);
    return f;
  }

  setUp(() {
    created.clear();
    SharedPreferences.setMockInitialValues({});
    SentFileStore.resetForTest();
  });

  tearDown(() {
    for (final p in created) {
      final f = File(p);
      if (f.existsSync()) f.deleteSync();
    }
    created.clear();
    SentFileStore.resetForTest();
  });

  group('#1 —— 重启后自己发送的图片缩略图恢复', () {
    testWidgets('fileData 为 null，filePath（sent_files 副本）存在 → 内联渲染',
        (tester) async {
      final sentPath =
          touch('sent_files/${prefix}restart1_shot.png', pngBytes);
      await tester.pumpWidget(wrap(view([
        msg('alice', '[发送文件] shot.png', '${prefix}restart1',
            type: 'file',
            filename: 'shot.png',
            filePath: sentPath.path),
      ], username: 'alice')));
      expect(find.byType(Image), findsOneWidget,
          reason: '自己发送的图片重启后（fileData 已失）经 filePath 仍应渲染缩略图');
    });

    testWidgets('fileData 失效、filePath 缺失 → SentFileStore 二次解析命中',
        (tester) async {
      await SentFileStore.init();
      final sentPath =
          touch('sent_files/${prefix}restart2_shot.png', pngBytes);
      await SentFileStore.record('${prefix}restart2', sentPath.path);
      await tester.pumpWidget(wrap(view([
        msg('alice', '[发送文件] shot.png', '${prefix}restart2',
            type: 'file', filename: 'shot.png'),
      ], username: 'alice')));
      expect(find.byType(Image), findsOneWidget,
          reason: '旧缓存（v1 时代无 file_path）经 SentFileStore 应恢复缩略图');
    });

    testWidgets('路径与 SentFileStore 全 miss（文件已删）→ 回退文本气泡',
        (tester) async {
      await tester.pumpWidget(wrap(view([
        msg('alice', '[发送文件] gone.png', '${prefix}gone',
            type: 'file', filename: 'gone.png'),
      ], username: 'alice')));
      expect(find.byType(Image), findsNothing);
      expect(find.text('[发送文件] gone.png'), findsOneWidget);
    });
  });

  group('#13 —— 同名文件不串图', () {
    testWidgets('两个同名图片消息各自 filePath 渲染，互不干扰', (tester) async {
      final pathA = touch('received_files/${prefix}a_photo.png', pngBytes);
      final pathB =
          touch('received_files/${prefix}b_photo.png', otherBytes);
      await tester.pumpWidget(wrap(view([
        msg('bob', '[收到文件] photo.png', '${prefix}mA',
            type: 'file', filename: 'photo.png', filePath: pathA.path),
        msg('bob', '[收到文件] photo.png', '${prefix}mB',
            type: 'file', filename: 'photo.png', filePath: pathB.path),
      ])));
      expect(find.byType(Image), findsNWidgets(2));
      expect(resolveMessageAttachmentPath(msg('bob', '', '${prefix}mA',
              type: 'file', filename: 'photo.png', filePath: pathA.path)),
          pathA.path);
      expect(resolveMessageAttachmentPath(msg('bob', '', '${prefix}mB',
              type: 'file', filename: 'photo.png', filePath: pathB.path)),
          pathB.path);
    });

    testWidgets('旧缓存（无 filePath）同名双消息经唯一路径各自解析', (tester) async {
      final uniqueA =
          touch(receivedAttachmentPath('${prefix}oldA', 'photo.png'));
      final uniqueB =
          touch(receivedAttachmentPath('${prefix}oldB', 'photo.png'));
      expect(uniqueA.path, isNot(equals(uniqueB.path)));
      await tester.pumpWidget(wrap(view([
        msg('bob', '[收到文件] photo.png', '${prefix}oldA',
            type: 'file', filename: 'photo.png'),
        msg('bob', '[收到文件] photo.png', '${prefix}oldB',
            type: 'file', filename: 'photo.png'),
      ])));
      expect(find.byType(Image), findsNWidgets(2),
          reason: '同名文件经 messageId 唯一路径解析，两气泡均应内联');
    });
  });

  group('N3b 门控回归', () {
    testWidgets('传输中不内联（transferFraction 非空）', (tester) async {
      final p = touch('received_files/${prefix}busy_photo.png', pngBytes);
      await tester.pumpWidget(wrap(view([
        msg('bob', '[收到文件] photo.png', '${prefix}busy',
            type: 'file', filename: 'photo.png', filePath: p.path),
      ], transferFraction: (id) => id == '${prefix}busy' ? 0.5 : null)));
      expect(find.byType(Image), findsNothing,
          reason: '传输中文件未完整落盘，不内联渲染（防破图）');
      expect(find.text('[收到文件] photo.png'), findsOneWidget);
    });
  });
}
