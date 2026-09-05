// ============================================================
// login_screen.dart Session 回填测试（阶段 H3 —— 记住我）
// ============================================================
// 契约（已实现）：
//   - 登录成功 → SessionStore.save(用户名/密码)；管理员密钥不持久化
//   - 启动时 initState 读取 SessionStore.load()：
//       * 有 session → 用户名/密码自动回填
//       * 管理员模式**不**自动开启、密钥**不**回填（安全：密钥不落盘，
//         每次启动需管理员手动输入密钥）
//       * 无 session → 字段为空
//   - 不自动登录：启动只回填，不发起连接、无任何"自动登录"指示
//   - 手动登录预验证失败 → 不写入 session
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chatroom_flutter/main.dart';
import 'package:chatroom_flutter/widgets/raw_text_field.dart';

Size testerSurfaceSize = const Size(800, 1000);

LogicalKeyboardKey _charKey(String ch) {
  if (ch.contains(RegExp(r'[0-9]'))) {
    return const {
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
    }[ch]!;
  }
  return {
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
  }[ch]!;
}

Future<void> typeInto(WidgetTester tester, Key fieldKey, String text) async {
  await tester.tap(find.byKey(fieldKey));
  await tester.pump();
  for (final ch in text.split('')) {
    await tester.sendKeyEvent(_charKey(ch));
    await tester.pump();
  }
}

/// 读取 RawTextField 的真实文本（其渲染含光标 span，不能依赖 find.text）。
String fieldText(WidgetTester tester, Key fieldKey) =>
    tester.widget<RawTextField>(find.byKey(fieldKey)).controller.text;

Future<void> pumpApp(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(testerSurfaceSize);
  await tester.pumpWidget(const ChatroomApp());
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() {
    testerSurfaceSize = const Size(800, 1000);
    SharedPreferences.setMockInitialValues({});
    // 阶段 L2：SessionStore 密码存钥匙串，测试注入内存 mock（旧明文预置仍走
    // 兼容迁移路径——钥匙串为空时回退 shared_preferences 明文）
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('H3 Session 回填（记住我，不自动登录）', () {
    testWidgets('无 session → 字段为空、无回填', (tester) async {
      await pumpApp(tester);

      expect(fieldText(tester, const ValueKey('username_field')), '');
      expect(fieldText(tester, const ValueKey('password_field')), '');
    });

    testWidgets('有 session → 用户名/密码自动回填', (tester) async {
      SharedPreferences.setMockInitialValues({
        'session_username': 'alice',
        'session_password': 'password123',
      });
      await pumpApp(tester);

      expect(fieldText(tester, const ValueKey('username_field')), 'alice');
      expect(
          fieldText(tester, const ValueKey('password_field')), 'password123');
    });

    testWidgets('管理员 session → 只回填用户名/密码，密钥不回填、管理员模式不自动开启', (tester) async {
      SharedPreferences.setMockInitialValues({
        'session_username': 'admin2',
        'session_password': 'adminpass123',
        'session_admin_secret': 'sec',
      });
      await pumpApp(tester);
      await tester.pump(const Duration(milliseconds: 300));

      expect(fieldText(tester, const ValueKey('username_field')), 'admin2');
      expect(
          fieldText(tester, const ValueKey('password_field')), 'adminpass123');
      // 安全：密钥不落盘 → 管理员模式不自动开启，密钥字段不存在
      expect(find.byKey(const ValueKey('admin_secret_field')), findsNothing);
    });

    testWidgets('有 session → 不自动登录（无指示、无加载态）', (tester) async {
      SharedPreferences.setMockInitialValues({
        'session_username': 'alice',
        'session_password': 'password123',
      });
      await pumpApp(tester);

      // 回填生效但绝不自动登录：无"自动登录"文案、按钮非加载态
      expect(fieldText(tester, const ValueKey('username_field')), 'alice');
      expect(find.textContaining('自动登录'), findsNothing);
      expect(find.text('登录'), findsWidgets);
    });

    testWidgets('无 session 时手动登录预验证失败 → 不写入 session', (tester) async {
      await pumpApp(tester);

      await typeInto(tester, const ValueKey('username_field'), 'alice');
      await typeInto(tester, const ValueKey('password_field'), '123');
      await tester.tap(find.byType(FilledButton));
      await tester.pump();

      expect(find.text('密码长度不能少于 6 个字符'), findsOneWidget);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('session_username'), isNull);
      expect(prefs.getString('session_password'), isNull);
    });
  });
}
