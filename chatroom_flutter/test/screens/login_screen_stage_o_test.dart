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
import 'package:chatroom_flutter/services/theme_settings.dart';

import 'package:chatroom_flutter/widgets/raw_text_field.dart';

ThemeSettings get settings => ThemeSettings.instance;

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

  group('O 修订（2026-08-31 登录页专属主题）', () {
    testWidgets('登录页主题独立于用户设置（R-O9 补充）：深色模式/字体缩放不影响', (tester) async {
      // 用户设置：深色 + 1.3x 缩放
      await settings.load();
      settings.mode = AppThemeMode.dark;
      settings.fontScale = 1.3;
      await pumpLogin(tester);

      // 登录页固定品牌深色主题 + 排版隔离（不受用户设置影响）
      final ctx = tester.element(find.byType(RawTextField).first);
      expect(Theme.of(ctx).brightness, Brightness.dark, reason: '登录页恒为品牌深色主题');
      expect(MediaQuery.textScalerOf(ctx).scale(10.0), 10.0,
          reason: '登录页排版不随用户字体缩放');
    });

    testWidgets('三段式布局（>=1280px）：品牌区 + 中部对话插画 + 表单', (tester) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      // 中部插画含循环浮动动画：手动逐帧 pump，不用 pumpAndSettle
      await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));

      // 左：品牌区；中：对话插画（浮动卡片组）；右：表单
      expect(find.text('私有化部署的即时通讯'), findsOneWidget, reason: '品牌展示区');
      expect(find.text('明晚 8 点线上会议，记得参加 🎉'), findsWidgets,
          reason: '中部对话插画（双份列表循环滚动，文案可出现多次）');
      expect(find.textContaining('TLS 加密传输'), findsWidgets, reason: '加密系统卡');
      expect(find.byType(RawTextField), findsNWidgets(2),
          reason: '右侧表单（用户名/密码）');
    });

    testWidgets('登录页输入框融入深色主题（无白色内层框）', (tester) async {
      await pumpLogin(tester);
      // RawTextField 主题感知改造后：未聚焦描边 = colorScheme.outline
      //（登录主题 #334155 深蓝灰），填充 = #0B1428——不再是灰白硬编码框
      final ctx = tester.element(find.byType(RawTextField).first);
      expect(Theme.of(ctx).colorScheme.outline, const Color(0xFF334155));
      // 单层框（2026-09-01 用户反馈 #1）：RawTextField 路径上仅其自身一个
      // AnimatedContainer（登录页不再包额外输入容器）
      final boxes = find
          .descendant(
            of: find.byType(RawTextField).first,
            matching: find.byType(AnimatedContainer),
          )
          .evaluate();
      expect(boxes.length, 1, reason: '输入框应保持单层描边（无内外两层）');
    });
  });

  group('2026-09-01 尺寸适配（BOTTOM OVERFLOW 回归）', () {
    Future<void> pumpAt(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
    }

    testWidgets('三段式矮窗（1300x480）：无溢出异常', (tester) async {
      await pumpAt(tester, const Size(1300, 480));
      expect(tester.takeException(), isNull,
          reason: '调窗口高度不得出现 BOTTOM OVERFLOW / 黄色条纹');
      expect(find.byType(RawTextField), findsNWidgets(2));
    });

    testWidgets('双栏矮窗（1024x480）：无溢出异常', (tester) async {
      await pumpAt(tester, const Size(1024, 480));
      expect(tester.takeException(), isNull);
    });

    testWidgets('单列矮窗（420x600）：无溢出异常', (tester) async {
      await pumpAt(tester, const Size(420, 600));
      expect(tester.takeException(), isNull);
    });

    testWidgets('大屏三段式（1920x1080）：消息流滚动播放且无溢出', (tester) async {
      await pumpAt(tester, const Size(1920, 1080));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('会议纪要截图.png'), findsWidgets,
          reason: '中部消息流滚动播放');
    });
  });
}
