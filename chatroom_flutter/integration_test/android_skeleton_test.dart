// ============================================================
// 设备端行走骨架子集（阶段 Q1-5 —— Android 真机 integration_test）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 Q 分层测试方法论"原生层"
// 行与 TESTING_GUIDE_FLUTTER.md §21.3：每端真机跑"登录页渲染 + 主
// 界面接线"最小集，不做全量；不依赖 .venv E2E harness（网络用例归
// 手动矩阵 TESTING_GUIDE.md §36.2 行走骨架 7 项与 §36.3 一致性矩阵）。
//
// 运行（Android 设备/模拟器连接后）：
//   flutter test integration_test/android_skeleton_test.dart -d <device>
//
// 说明：
//   · 非 Android 桌面（flutter run -d linux）执行时平台专属断言自动
//     跳过（按 dart:io Platform 门控），文件仍可作为 Linux 冒烟运行；
//   · 本文件不锁定网络行为（登录/收发/重连/互踢/连发 Spike 由 §36.2
//     手动骨架清单守门）；effectiveTargetPlatform 在真机上回退
//     dart:io Platform → android，AdaptiveTextField 应渲染标准
//     TextField（Q0-2 契约的真机落地验证，即"输入法替换"场景）。
// ============================================================

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:chatroom_flutter/main.dart';
import 'package:chatroom_flutter/screens/chat_screen.dart';
import 'package:chatroom_flutter/services/socket_service.dart';
import 'package:chatroom_flutter/services/state_manager.dart';
import 'package:chatroom_flutter/widgets/raw_text_field.dart';

class MockSocketService extends Mock implements SocketService {}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Q1 骨架 ①：登录页渲染（含注册入口）', (tester) async {
    await tester.pumpWidget(const ChatroomApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('聊天室'), findsWidgets);
    expect(find.text('没有账号？注册'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Q1 骨架 ②：登录页输入为标准 TextField（输入法替换场景，'
      'Q0-2 契约真机落地）', (tester) async {
    if (!Platform.isAndroid) {
      // 非 Android 桌面执行时跳过平台专属断言（RawTextField 为 Linux 基线）
      return;
    }
    await tester.pumpWidget(const ChatroomApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(TextField), findsWidgets,
        reason: 'Android 上 AdaptiveTextField 渲染系统标准输入（系统 IME 可用）');
    expect(find.byType(RawTextField), findsNothing,
        reason: 'GTK 桥接输入是 Linux 专属，Android 不得出现');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Q1 骨架 ③：ChatScreen 主界面接线渲染（Mock 服务，窄屏不溢出）',
      (tester) async {
    final socket = MockSocketService();
    when(() => socket.saveConversationDraft(any(), any()))
        .thenAnswer((_) async {});
    final state = AppState.instance;
    state
      ..setLoggedOut()
      ..setLoggedIn('tester', false)
      ..setFriends([]);

    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(socketService: socket),
      routes: {'/login': (_) => const Scaffold(body: Text('LOGIN'))},
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('聊天室 - tester'), findsOneWidget);
    expect(tester.takeException(), isNull,
        reason: '真机分辨率下主界面无布局异常（响应式布局骨架门槛）');
  });
}
