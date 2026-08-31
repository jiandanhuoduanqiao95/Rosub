// ============================================================
// login_screen.dart 阶段 O —— O6 多账号切换（登录页账号列表）契约（TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 O：
//   O6（P2-10 多账号切换）：家庭 PC 多人场景——登录页展示已保存的账号
//   列表（SessionStore.loadAccounts），点击账号即回填用户名/密码
//   （不自动登录，沿用 H3 语义）；无账号时不渲染列表（回归兼容）。
//
// 纯客户端改动。本测试只验证回填路径，不触发网络连接（沿用
// login_screen_test 的"仅验证失败路径不连网"约定——点击账号只填充字段）。
//
// 实现前：本文件引用尚未实现的行为，编译失败或用例红，属 TDD 红。
// 实现后：全部转绿。
// ============================================================

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/screens/login_screen.dart';
import 'package:chatroom_flutter/widgets/raw_text_field.dart';

Future<void> pumpLogin(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
  await tester.pump();
  // _initSession 为异步：等账号列表渲染
  await tester.pumpAndSettle();
}

RawTextField field(WidgetTester tester, String key) =>
    tester.widget<RawTextField>(find.byKey(ValueKey(key)));

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  group('O6 —— 登录页账号列表', () {
    testWidgets('有已保存账号 → 登录页渲染账号条目', (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        'session_accounts': jsonEncode([
          {'username': 'alice', 'password': 'pw1'},
          {'username': 'bob', 'password': 'pw2'},
        ]),
      });
      await pumpLogin(tester);

      expect(find.text('alice'), findsOneWidget, reason: '账号列表含 alice');
      expect(find.text('bob'), findsOneWidget, reason: '账号列表含 bob');
    });

    testWidgets('点击账号 → 回填用户名/密码（不自动登录）', (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        'session_accounts': jsonEncode([
          {'username': 'alice', 'password': 'pw1'},
          {'username': 'bob', 'password': 'pw2'},
        ]),
      });
      await pumpLogin(tester);

      await tester.tap(find.text('bob'));
      await tester.pumpAndSettle();

      expect(field(tester, 'username_field').controller.text, 'bob',
          reason: '用户名回填');
      expect(field(tester, 'password_field').controller.text, 'pw2',
          reason: '密码回填');
      // 未自动登录：仍在登录页
      expect(find.byType(LoginScreen), findsOneWidget);
    });

    testWidgets('当前账号同时回填（既有记住我语义）+ 账号列表共存', (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        'session_username': 'alice',
        'session_password': 'pw1',
        'session_accounts': jsonEncode([
          {'username': 'alice', 'password': 'pw1'},
          {'username': 'bob', 'password': 'pw2'},
        ]),
      });
      await pumpLogin(tester);

      expect(field(tester, 'username_field').controller.text, 'alice',
          reason: 'H3 记住我回填不回退');
      expect(find.text('bob'), findsOneWidget, reason: '账号列表仍可切换');
    });

    testWidgets('无已保存账号 → 不渲染账号列表（回归兼容）', (tester) async {
      await pumpLogin(tester);
      expect(find.text('alice'), findsNothing);
      expect(find.text('bob'), findsNothing);
    });

    testWidgets('账号列表损坏 JSON → 不渲染也不崩溃（防御）', (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        'session_accounts': '不是JSON',
      });
      await pumpLogin(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('alice'), findsNothing);
    });
  });
}
