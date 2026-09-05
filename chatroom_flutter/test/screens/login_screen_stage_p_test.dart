// ============================================================
// login_screen.dart / main.dart 阶段 P —— 登录页多语言切换契约
// （TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 P6（多语言界面）端到端切换：
//
//   经 ChatroomApp（main.dart）真实壳验证语言解析全链路：
//     ThemeSettings.locale → MaterialApp locale/localizationsDelegates →
//     登录页文案。
//
//   契约（与 app_strings_stage_p_test.dart 字典键对应）：
//     - 默认 zh：登录页中文（'聊天室' / '登录以继续' / '管理员模式'）——
//       既有渲染零回归（既有全量中文断言测试的前提）
//     - locale = en：登录页英文（'Chatroom' / 'Sign in to continue' /
//       'Admin mode'）
//     - 同一测试内切换语言 → 下一次 rebuild 文案即时切换
//       （ThemeSettings notifyListeners → ChatroomApp 重建）
//
//   说明：RawTextField 为自绘 hint（非 Text widget），hint 文案不参与
//   find.text 断言；断言对象为卡片标题/开关标题/品牌标题等 Text。
//
// 实现前：本文件引用尚未实现的 AppLocale（ThemeSettings 扩展），编译
// 失败或用例红，属 TDD 红。实现后：全部转绿。
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chatroom_flutter/main.dart';
import 'package:chatroom_flutter/services/theme_settings.dart';

ThemeSettings get settings => ThemeSettings.instance;

Future<void> pumpApp(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(800, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(const ChatroomApp());
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('P6 —— 登录页多语言（经 ChatroomApp 全链路）', () {
    testWidgets('默认 zh：登录页中文（既有渲染零回归）', (tester) async {
      await settings.bindUser(null);
      expect(settings.locale, AppLocale.zh, reason: '默认中文');

      await pumpApp(tester);
      expect(find.text('聊天室'), findsWidgets);
      expect(find.text('登录以继续'), findsOneWidget);
      expect(find.text('管理员模式'), findsOneWidget);
    });

    testWidgets('locale = en：登录页英文', (tester) async {
      await settings.bindUser(null);
      settings.locale = AppLocale.en;

      await pumpApp(tester);
      expect(find.text('Chatroom'), findsWidgets, reason: '品牌标题英文');
      expect(find.text('Sign in to continue'), findsOneWidget);
      expect(find.text('Admin mode'), findsOneWidget);
      expect(find.text('登录以继续'), findsNothing);
    });

    testWidgets('同会话内切换语言 → 重建后文案即时切换', (tester) async {
      await settings.bindUser(null);
      await pumpApp(tester);
      expect(find.text('登录以继续'), findsOneWidget);

      settings.locale = AppLocale.en;
      await tester.pumpAndSettle();
      expect(find.text('Sign in to continue'), findsOneWidget,
          reason: 'notifyListeners → ChatroomApp 重建 → 文案切换');

      settings.locale = AppLocale.zh;
      await tester.pumpAndSettle();
      expect(find.text('登录以继续'), findsOneWidget, reason: '切回中文');
    });
  });
}
