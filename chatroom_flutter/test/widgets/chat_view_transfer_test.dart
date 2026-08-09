// ============================================================
// 文件消息气泡传输进度条 Widget 测试（阶段 G：传输可视化）
// ============================================================
// 验证：
//   - 文件消息传输中（0 < fraction < 1）显示 LinearProgressIndicator
//   - 传输完成/移除后进度条消失
//   - 文本消息不显示进度条
//   - 进度条不阻塞其它消息渲染（非模态局部刷新）
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/state_manager.dart';
import 'package:chatroom_flutter/widgets/chat_view.dart';

AppState get state => AppState.instance;

void resetState() {
  state
    ..setLoggedOut()
    ..setConnectionStatus(ConnectionStatus.disconnected);
}

ChatMessage fileMsg(String id, {String sender = 'alice'}) => ChatMessage(
      sender: sender,
      content: '[发送文件] big.bin',
      type: 'file',
      messageId: id,
      filename: 'big.bin',
      status: 'sent',
    );

Widget buildView(List<ChatMessage> messages) {
  return MaterialApp(
    home: Scaffold(
      body: ChatView(
        chatKey: 'bob',
        chatTitle: 'bob',
        messages: messages,
        username: 'alice',
        inputCtrl: TextEditingController(),
        canSend: false,
        onSend: () {},
        onSendFile: () {},
        onRecall: (_) {},
        onLoadHistory: (_) async {},
        hasMoreHistory: (_) => false,
        transferFraction: (id) => state.transferFraction(id),
      ),
    ),
  );
}

void main() {
  setUp(resetState);

  testWidgets('文件消息传输中显示进度条', (tester) async {
    state.setLoggedIn('alice', false);
    state.updateTransfer('f1', 40, 100);
    await tester.pumpWidget(buildView([fileMsg('f1')]));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    // 文件消息气泡仍在（进度条不替代消息）
    expect(find.textContaining('big.bin'), findsOneWidget);
  });

  testWidgets('传输完成后进度条消失', (tester) async {
    state.setLoggedIn('alice', false);
    state.updateTransfer('f1', 100, 100);
    state.removeTransfer('f1');
    await tester.pumpWidget(buildView([fileMsg('f1')]));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.textContaining('big.bin'), findsOneWidget);
  });

  testWidgets('文本消息不显示进度条', (tester) async {
    state.setLoggedIn('alice', false);
    await tester.pumpWidget(buildView([
      ChatMessage(sender: 'bob', content: 'hello', messageId: 'm1'),
    ]));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('进度条随进度更新刷新', (tester) async {
    state.setLoggedIn('alice', false);
    state.updateTransfer('f1', 10, 100);
    await tester.pumpWidget(buildView([fileMsg('f1')]));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    // 进度推进 + 完成后移除（模拟 ChatScreen ListenableBuilder 重建）→ 进度条消失
    state.updateTransfer('f1', 100, 100);
    state.removeTransfer('f1');
    await tester.pumpWidget(buildView([fileMsg('f1')]));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('多个文件消息各自显示独立进度', (tester) async {
    state.setLoggedIn('alice', false);
    state.updateTransfer('f1', 30, 100);
    state.updateTransfer('f2', 80, 100);
    await tester.pumpWidget(buildView([
      fileMsg('f1', sender: 'alice'),
      fileMsg('f2', sender: 'bob'),
    ]));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNWidgets(2));
  });
}
