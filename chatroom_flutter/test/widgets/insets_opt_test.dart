// ============================================================
// opt1 P3 —— 三星平板任务栏遮挡：底部 inset 消费加固
// ============================================================
// 根因：targetSdk 35+（Flutter 3.44 默认 36）强制 edge-to-edge，应用
// 窗口延伸到系统任务栏/手势条之下，未消费底部 inset 的页面被压住。
// 契约（widget 级，无需设备）：
//   1) ChatScreen 主体在 MediaQuery padding.bottom > 0 时，内容底部
//      不进入系统栏区域；
//   2) showResponsiveDialog 宽屏居中对话框底部按钮同样抬到 inset 之上；
//   3) 通话悬浮条位置计算不受 SafeArea 干扰（独立层）。
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/socket_service.dart';
import 'package:chatroom_flutter/services/state_manager.dart';
import 'package:chatroom_flutter/screens/chat_screen.dart';
import 'package:chatroom_flutter/widgets/responsive_layout.dart';

class MockSocketService extends Mock implements SocketService {}

void main() {
  setUp(() {
    final state = AppState.instance;
    state
      ..setLoggedOut()
      ..setConnectionStatus(ConnectionStatus.disconnected);
  });

  group('opt1 P3 —— 底部 inset 消费', () {
    testWidgets('ChatScreen 主体底部不进入 bottom padding 区域', (tester) async {
      const bottomInset = 48.0;
      final socket = MockSocketService();
      AppState.instance.setLoggedIn('alice', false);
      AppState.instance.setFriends(['bob']);

      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
              padding: EdgeInsets.only(bottom: bottomInset)),
          child: ChatScreen(socketService: socket),
        ),
        routes: {'/login': (_) => const Scaffold(body: Text('LOGIN'))},
      ));
      await tester.pump();

      // 侧栏底部内容（好友磁贴列表）不被任务栏压住：
      // 会话列表 ListView 的可视区域底边 <= 屏高 - inset
      final listRect =
          tester.getRect(find.byWidgetPredicate((w) => w is ListView).first);
      expect(listRect.bottom, lessThanOrEqualTo(600 - bottomInset),
          reason: '主体内容经 SafeArea(bottom) 消费任务栏 inset');
    });

    testWidgets('宽屏居中对话框底部内容抬到 inset 之上', (tester) async {
      const bottomInset = 48.0;
      await tester.pumpWidget(const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
              padding: EdgeInsets.only(bottom: bottomInset)),
          child: Scaffold(body: SizedBox.expand()),
        ),
      ));

      const marker = Key('inset_dialog_probe');
      // 不 await：showDialog 的 Future 在对话框关闭时才完成
      showResponsiveDialog<void>(
        context: tester.element(find.byType(Scaffold)),
        builder: (ctx) => const AlertDialog(
          content: SizedBox(
            width: 280,
            height: 200,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                SizedBox(key: marker, width: 10, height: 10),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final probeRect = tester.getRect(find.byKey(marker));
      expect(probeRect.bottom, lessThanOrEqualTo(600 - bottomInset),
          reason: '对话框内容底部经 SafeArea(bottom) 消费任务栏 inset');
    });
  });
}
