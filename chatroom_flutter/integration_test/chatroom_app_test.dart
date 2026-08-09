// ============================================================
// 抖动 Widget 测试入口（集成测试绑定）
// ============================================================
// integration_test 包提供与 flutter_test 兼容的 IntegrationTestWidgetsFlutterBinding。
// 本文件注册绑定并复用 test/ 下的 widget 测试，使 `flutter test` 与
// `flutter test integration_test/` 两种执行路径都可用。
//
// 运行（Linux 桌面端到端，需先 `flutter pub get`）：
//   flutter test integration_test/chatroom_app_test.dart -d linux
//
// 说明：真正的"连接真实服务端"场景仍需手工测试，详见 TESTING_GUIDE_FLUTTER.md。
// 本文件主要验证应用在 IntegrationTestWidgetsFlutterBinding 下也能启动并渲染登录页，
// 作为后续接入 local_notifier / shared_preferences 等平台插件的基础。
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:chatroom_flutter/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('应用在集成测试绑定下正常启动并显示登录页', (tester) async {
    await tester.pumpWidget(const ChatroomApp());
    await tester.pump();

    expect(find.text('聊天室'), findsWidgets);
    expect(find.text('没有账号？注册'), findsOneWidget);
  });
}