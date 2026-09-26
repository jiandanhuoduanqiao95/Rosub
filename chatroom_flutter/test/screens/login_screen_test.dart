// ============================================================
// login_screen.dart Widget 测试
// ============================================================
// 验证登录/注册切换、管理员模式展开，以及客户端预验证：
//   - 短用户名被拒（不连接服务器）
//   - 短密码被拒
//   - 管理员模式未填密钥被拒
//   - 管理员模式展开密钥输入框
//
// 说明：LoginScreen 内部构造 SocketService 并在验证通过后才 connect。
// 本测试只触发"验证失败"路径，因此不会发起任何网络连接，无需 mock。
// 文本通过键盘事件输入（RawTextField 不使用系统 EditableText）。
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chatroom_flutter/main.dart';

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

void main() {
  // 登录卡片内容在输入/管理员模式展开时会超出默认 600pt 高度，
  // 测试中设置更大的视口避免 RenderFlex overflow 误判。
  setUp(() {
    testerSurfaceSize = const Size(800, 1000);
  });

  testWidgets('登录页初始状态', (tester) async {
    await tester.binding.setSurfaceSize(testerSurfaceSize);
    await tester.pumpWidget(const ChatroomApp());
    await tester.pump();
    expect(find.text('Rosub'), findsWidgets);
    expect(find.text('登录'), findsWidgets);
    expect(find.text('没有账号？注册'), findsOneWidget);
  });

  testWidgets('切换到注册再切回登录', (tester) async {
    await tester.binding.setSurfaceSize(testerSurfaceSize);
    await tester.pumpWidget(const ChatroomApp());
    await tester.pump();

    await tester.tap(find.text('没有账号？注册'));
    await tester.pump();
    expect(find.text('注册新账号'), findsOneWidget);
    expect(find.text('注册'), findsOneWidget);
    expect(find.text('已有账号？登录'), findsOneWidget);

    await tester.tap(find.text('已有账号？登录'));
    await tester.pump();
    expect(find.text('登录'), findsWidgets);
    expect(find.text('没有账号？注册'), findsOneWidget);
  });

  testWidgets('短用户名注册被客户端预验证拒绝（不连服务器）', (tester) async {
    await tester.binding.setSurfaceSize(testerSurfaceSize);
    await tester.pumpWidget(const ChatroomApp());
    await tester.pump();
    // 切到注册
    await tester.tap(find.text('没有账号？注册'));
    await tester.pump();

    await typeInto(tester, const ValueKey('username_field'), 'a');
    await typeInto(tester, const ValueKey('password_field'), 'validpw1');
    await tester.tap(find.byType(FilledButton));
    await tester.pump();

    expect(find.text('用户名长度不能少于 3 个字符'), findsOneWidget);
  });

  testWidgets('短密码被客户端预验证拒绝', (tester) async {
    await tester.binding.setSurfaceSize(testerSurfaceSize);
    await tester.pumpWidget(const ChatroomApp());
    await tester.pump();

    await typeInto(tester, const ValueKey('username_field'), 'alice');
    await typeInto(tester, const ValueKey('password_field'), '123');
    await tester.tap(find.byType(FilledButton));
    await tester.pump();

    expect(find.text('密码长度不能少于 6 个字符'), findsOneWidget);
  });

  testWidgets('开启管理员模式但未填密钥被拒绝', (tester) async {
    await tester.binding.setSurfaceSize(testerSurfaceSize);
    await tester.pumpWidget(const ChatroomApp());
    await tester.pump();

    await typeInto(tester, const ValueKey('username_field'), 'admin2');
    await typeInto(tester, const ValueKey('password_field'), 'adminpass123');

    // 开启管理员模式开关
    await tester.tap(find.text('管理员模式'));
    await tester.pump();
    // 密钥输入框出现
    expect(find.byKey(const ValueKey('admin_secret_field')), findsOneWidget);

    // 不填密钥直接注册/登录
    await tester.tap(find.byType(FilledButton));
    await tester.pump();

    expect(find.text('管理员模式需要填写管理员密钥'), findsOneWidget);
  });

  testWidgets('管理员模式关闭后密钥框消失', (tester) async {
    await tester.binding.setSurfaceSize(testerSurfaceSize);
    await tester.pumpWidget(const ChatroomApp());
    await tester.pump();
    await tester.tap(find.text('管理员模式'));
    await tester.pump();
    expect(find.byKey(const ValueKey('admin_secret_field')), findsOneWidget);

    await tester.tap(find.text('管理员模式'));
    await tester.pump();
    expect(find.byKey(const ValueKey('admin_secret_field')), findsNothing);
  });
}
