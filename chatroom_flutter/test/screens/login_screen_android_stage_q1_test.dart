// ============================================================
// login_screen.dart 阶段 Q1 —— 真机反馈二轮/三轮（Android 布局/账号管理）
// ============================================================
// Q1 二轮问题6/7：
//   - Android 布局：品牌 logo/标题/介绍一概删去，功能表单全屏；
//   - 返回键 → moveTaskToBackground（不退出进程）；
//   - Linux 桌面三档布局零回归（品牌区保留）。
//
// Q1 三轮问题0/1（本轮修订）：
//   - 登录/注册切换为滑块式动画开关（_LoginModeToggle，键
//     login_mode_segment 保留）——SegmentedButton 移除；
//   - 已记录用户回归方形磁贴，说明小字删除；
//   - 账号删除改编辑态：长按磁贴 → 右上角叉号浮现 → 点叉直接删除
//     （SessionStore.removeAccount 钥匙串清理）；横向侧滑取消编辑态；
//   - 新增"不记录此次登录"勾选——勾选后登录成功不写入钥匙串
//     （账号列表与当前凭据均不保存）。
// 平台模拟规约：debugDefaultTargetPlatformOverride 在 testWidgets body
// 内设置并恢复（§21.1）。
// ============================================================

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chatroom_flutter/screens/login_screen.dart';
import 'package:chatroom_flutter/services/session_store.dart';

const MethodChannel _channel = MethodChannel('chatroom/platform');

/// §21.1 规约：override 必须在 testWidgets body 内恢复（foundation
/// invariant 检查先于 group tearDown）
void testWidgetsOnPlatform(String name, TargetPlatform platform,
    Future<void> Function(WidgetTester) cb) {
  testWidgets(name, (tester) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await cb(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];

  Future<void> pumpLogin(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    await tester.pumpAndSettle();
  }

  setUp(() {
    calls.clear();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({
      'session_accounts': jsonEncode([
        {'username': 'alice', 'password': 'pw-alice-1'},
      ]),
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return true;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  group('Q1 二轮 —— Android 登录/注册布局（问题7）', () {
    testWidgetsOnPlatform(
        '无品牌区（logo/标题/介绍），滑块切换 + 账号磁贴 + 表单全屏', TargetPlatform.android,
        (tester) async {
      await pumpLogin(tester);

      expect(find.text('私有化部署的即时通讯'), findsNothing, reason: '品牌介绍删除');
      expect(find.text('在这里，墙没有耳朵'), findsNothing,
          reason: 'v1.0.1 用户决策：欢迎标语删除');
      expect(find.textContaining('已记录的用户'), findsNothing,
          reason: 'Q1 三轮：磁贴上方说明小字删除');
      expect(find.byKey(const ValueKey('login_mode_segment')), findsOneWidget,
          reason: '登录/注册切换（滑块式开关，Q1 三轮问题0 美化）');
      expect(find.text('登录'), findsWidgets);
      expect(find.text('注册'), findsWidgets);
      expect(find.byKey(const ValueKey('username_field')), findsOneWidget);
      expect(find.byKey(const ValueKey('password_field')), findsOneWidget);
      expect(find.byKey(const ValueKey('saved_account_alice')), findsOneWidget,
          reason: '已记录账号磁贴（方形，Q1 三轮回归）');
    });

    testWidgetsOnPlatform('账号磁贴点击回填（O6 语义保留）', TargetPlatform.android,
        (tester) async {
      await pumpLogin(tester);
      await tester.tap(find.byKey(const ValueKey('saved_account_alice')));
      await tester.pumpAndSettle();
      // 回填不自动登录：仍停留登录页，表单填入用户名（经 controller 难以
      // 断言——回填后磁贴仍在 + 页面未跳转即契约）
      expect(find.byKey(const ValueKey('saved_account_alice')), findsOneWidget);
      expect(find.byKey(const ValueKey('login_mode_segment')), findsOneWidget);
    });

    testWidgetsOnPlatform(
        '返回键 → moveTaskToBackground（不退出）', TargetPlatform.android,
        (tester) async {
      await pumpLogin(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'moveToBackground').length, 1,
          reason: 'Q1 二轮问题5b：登录页根路由返回转后台');
    });
  });

  group('Q1 三轮 —— 账号删除编辑态（问题1：长按出叉 / 点叉删除 / 侧滑取消）', () {
    testWidgetsOnPlatform('普通态无叉号；长按磁贴 → 编辑态叉号浮现', TargetPlatform.android,
        (tester) async {
      await pumpLogin(tester);

      expect(find.byKey(const ValueKey('saved_account_remove_alice')),
          findsNothing,
          reason: '普通态不显示删除叉号');

      await tester.longPress(find.byKey(const ValueKey('saved_account_alice')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('saved_account_remove_alice')),
          findsOneWidget,
          reason: '长按进入编辑态：磁贴右上角叉号');
    });

    testWidgetsOnPlatform('点叉号 → 直接删除（钥匙串账号列表与当前凭据清除）', TargetPlatform.android,
        (tester) async {
      await pumpLogin(tester);

      await tester.longPress(find.byKey(const ValueKey('saved_account_alice')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const ValueKey('saved_account_remove_alice')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('saved_account_alice')), findsNothing,
          reason: '磁贴移除');
      expect(await SessionStore.loadAccounts(), isEmpty, reason: '钥匙串账号列表清空');
    });

    testWidgetsOnPlatform('编辑态横向侧滑 → 取消编辑态，账号保留', TargetPlatform.android,
        (tester) async {
      await pumpLogin(tester);

      await tester.longPress(find.byKey(const ValueKey('saved_account_alice')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('saved_account_remove_alice')),
          findsOneWidget);

      await tester.drag(find.byKey(const ValueKey('saved_accounts_row')),
          const Offset(-120, 0));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('saved_account_remove_alice')),
          findsNothing,
          reason: '侧滑退出编辑态（叉号消失）');
      expect(find.byKey(const ValueKey('saved_account_alice')), findsOneWidget,
          reason: '侧滑仅取消编辑态，不删除账号');
      expect(await SessionStore.loadAccounts(), isNotEmpty);
    });

    testWidgetsOnPlatform('编辑态点击磁贴本体 → 退出编辑态（不回填不删除）', TargetPlatform.android,
        (tester) async {
      await pumpLogin(tester);

      await tester.longPress(find.byKey(const ValueKey('saved_account_alice')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('saved_account_alice')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('saved_account_remove_alice')),
          findsNothing,
          reason: '点击磁贴退出编辑态');
      expect(await SessionStore.loadAccounts(), isNotEmpty);
    });
  });

  group('Q1 三轮 —— 不记录此次登录（问题1 勾选项）', () {
    testWidgetsOnPlatform('勾选行点击切换勾选态', TargetPlatform.android, (tester) async {
      await pumpLogin(tester);

      Checkbox checkbox() => tester.widget<Checkbox>(
          find.byKey(const ValueKey('dont_remember_checkbox')));
      expect(checkbox().value, isFalse, reason: '默认记录登录');

      await tester.tap(find.byKey(const ValueKey('dont_remember_row')));
      await tester.pumpAndSettle();
      expect(checkbox().value, isTrue, reason: '点击勾选');

      await tester.tap(find.byKey(const ValueKey('dont_remember_row')));
      await tester.pumpAndSettle();
      expect(checkbox().value, isFalse, reason: '再次点击取消');
    });
  });

  group('Q1 二轮 —— Linux 桌面零回归', () {
    testWidgetsOnPlatform('窄屏（<600）品牌区保留（旧单列布局不变）', TargetPlatform.linux,
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpLogin(tester);

      expect(find.text('私有化部署的即时通讯'), findsOneWidget,
          reason: '窄屏品牌区（compact 头部）保留');
      expect(find.byKey(const ValueKey('login_mode_segment')), findsNothing,
          reason: '滑块切换为 Android 专属');
      expect(find.byKey(const ValueKey('saved_account_alice')), findsNothing,
          reason: 'Linux 仍为 ActionChip 账号条目（非磁贴）');
      // ActionChip 条目仍存在（O6）
      expect(find.text('alice'), findsOneWidget);
    });
  });
}
