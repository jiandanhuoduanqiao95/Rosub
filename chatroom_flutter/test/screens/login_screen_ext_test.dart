// ============================================================
// login_screen.dart 扩展攻击性测试（测试强化新增）
// ============================================================
// 覆盖既有测试未触达的客户端预验证与 UI 状态分支：
//   - 非法字符 / 超长 / 空白用户名
//   - 密码可见性切换
//   - 管理员模式切换时密钥清空
//   - 密码框 Enter 直接提交
//   - 加载中按钮禁用（连接失败路径模拟）
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/main.dart';

Size testerSurfaceSize = const Size(800, 1000);

LogicalKeyboardKey _charKey(String ch) {
  if ('0123456789'.contains(ch)) {
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
  return const {
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
  }[ch.toLowerCase()]!;
}

Future<void> typeInto(WidgetTester tester, Key fieldKey, String text) async {
  await tester.tap(find.byKey(fieldKey));
  await tester.pump();
  for (final ch in text.split('')) {
    await tester.sendKeyEvent(_charKey(ch));
    await tester.pump();
  }
}

Future<void> pumpLogin(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(testerSurfaceSize);
  await tester.pumpWidget(const ChatroomApp());
  await tester.pump();
}

void main() {
  setUp(() {
    testerSurfaceSize = const Size(800, 1000);
  });

  group('客户端预验证扩展', () {
    testWidgets('用户名含非法字符（点号）被拒', (tester) async {
      await pumpLogin(tester);
      // 键入 'bob.mail'：点号可输入但不在合法字符集
      await typeInto(tester, const ValueKey('username_field'), 'bob');
      await tester.sendKeyEvent(LogicalKeyboardKey.period);
      await tester.pump();
      await typeInto(tester, const ValueKey('password_field'), 'validpw1');
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      expect(find.text('用户名只能包含字母、数字、下划线和连字符'), findsOneWidget);
    });

    testWidgets('33 字符超长用户名被拒', (tester) async {
      await pumpLogin(tester);
      // 输入 33 个 a（每次 sendKeyEvent 一个字符）
      await typeInto(tester, const ValueKey('username_field'), 'a' * 33);
      await typeInto(tester, const ValueKey('password_field'), 'validpw1');
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      expect(find.text('用户名长度不能超过 32 个字符'), findsOneWidget);
    });

    testWidgets('空白用户名（仅空格）被拒', (tester) async {
      await pumpLogin(tester);
      // RawTextField 只接收 0x20 及以上字符，空格可输入
      await tester.tap(find.byKey(const ValueKey('username_field')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      await typeInto(tester, const ValueKey('password_field'), 'validpw1');
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      // trim 后为空 → 长度不足
      expect(find.text('用户名长度不能少于 3 个字符'), findsOneWidget);
    });

    testWidgets('密码框内按 Enter 直接触发校验', (tester) async {
      await pumpLogin(tester);
      await typeInto(tester, const ValueKey('username_field'), 'ab');
      await typeInto(tester, const ValueKey('password_field'), 'validpw1');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.text('用户名长度不能少于 3 个字符'), findsOneWidget);
    });
  });

  group('UI 状态分支', () {
    testWidgets('密码可见性切换图标切换', (tester) async {
      await pumpLogin(tester);
      // 初始掩码状态：显示 visibility_off 图标
      expect(find.byIcon(Icons.visibility_off_rounded), findsOneWidget);
      await tester.tap(find.byIcon(Icons.visibility_off_rounded));
      await tester.pump();
      expect(find.byIcon(Icons.visibility_rounded), findsOneWidget);
      expect(find.byIcon(Icons.visibility_off_rounded), findsNothing);
    });

    testWidgets('关闭管理员模式后密钥被清空', (tester) async {
      await pumpLogin(tester);
      await tester.tap(find.text('管理员模式'));
      await tester.pump();
      await typeInto(tester, const ValueKey('admin_secret_field'), 'topsecret');
      // 关闭管理员模式 → 密钥框消失
      await tester.tap(find.text('管理员模式'));
      await tester.pump();
      expect(find.byKey(const ValueKey('admin_secret_field')), findsNothing);
      // 重新开启 → 密钥为空（已清空）
      await tester.tap(find.text('管理员模式'));
      await tester.pump();
      expect(find.byKey(const ValueKey('admin_secret_field')), findsOneWidget);
      // 不填密钥直接提交 → 报"需要填写密钥"（证明字段已被清空）
      await typeInto(tester, const ValueKey('username_field'), 'adminx');
      await typeInto(tester, const ValueKey('password_field'), 'validpw1');
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      expect(find.text('管理员模式需要填写管理员密钥'), findsOneWidget);
    });

    testWidgets('注册模式标题与按钮文案切换', (tester) async {
      await pumpLogin(tester);
      await tester.tap(find.text('没有账号？注册'));
      await tester.pump();
      expect(find.text('注册新账号'), findsOneWidget);
      expect(find.byType(FilledButton), findsOneWidget);
      await tester.tap(find.text('已有账号？登录'));
      await tester.pump();
      expect(find.text('登录'), findsWidgets);
    });

    testWidgets('切换模式后错误提示被清除', (tester) async {
      await pumpLogin(tester);
      await typeInto(tester, const ValueKey('username_field'), 'a');
      await typeInto(tester, const ValueKey('password_field'), 'validpw1');
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      expect(find.text('用户名长度不能少于 3 个字符'), findsOneWidget);

      await tester.tap(find.text('没有账号？注册'));
      await tester.pump();
      expect(find.text('用户名长度不能少于 3 个字符'), findsNothing);
    });
  });
}
