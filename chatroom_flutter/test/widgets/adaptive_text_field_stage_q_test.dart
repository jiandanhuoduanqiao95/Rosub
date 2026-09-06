// ============================================================
// 文本输入适配层契约（阶段 Q0-2 —— TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 Q「Q0-2 文本输入适配层」：
//
//   Linux = RawTextField + GTK IME 桥接（现状，保持不变）；
//   其余平台 = 标准 TextField 输入路径。将 33 个 RawTextField 实例化点
//   （dialogs.dart 25 + login_screen 3 + chat_screen 3 + chat_view 2）
//   收敛到统一工厂/适配器按平台切换；N5 键盘导航 ASCII 路径平台无关
//   保留，NAV 桥接路径仅 Linux。
//
// 契约：新增 lib/widgets/adaptive_text_field.dart ——
//
//   class AdaptiveTextField extends StatefulWidget
//
//   · 参数集与 RawTextField 完全一致（33 个实例化点迁移最小侵入）：
//       controller / focusNode / hintText / obscureText /
//       showVisibilityToggle / showChineseInput / onSubmitted /
//       onImagePasted
//   · 平台判定用 Flutter 层 defaultTargetPlatform（debugDefaultTarget-
//     PlatformOverride 可模拟；不得直接用 dart:io Platform——widget
//     测试须可驱动，§21.1 平台模拟规约）：
//       TargetPlatform.linux  → 渲染 RawTextField（GTK 桥接语义全保留）
//       其余（android/ios/windows/macos）→ 渲染标准 Material TextField
//   · 非 Linux 下 showChineseInput/onImagePasted 为无害冗余（不启动
//     GTK 桥接——桥接进程是 Linux 桌面专属，移动端无 X11/GTK 上下文）
//   · RawTextField 是唯一注册桥接监听器的输入 widget：非 Linux 渲染
//     无 RawTextField 即无 NAV 桥接监听注册（NAV 桥接路径仅 Linux），
//     标准 TextField 的 ASCII 输入/提交走系统 IME 通道（N5 键盘导航
//     ASCII 路径平台无关保留）
//
// 实例化点收敛以源码扫描锁定（ dialogs/login_screen/chat_screen/
// chat_view 四文件不得再直接实例化 RawTextField；AdaptiveTextField
// 数量不低于文档基线 25/3/3/2，新增输入框一律走适配层）。
//
// 平台模拟规约：debugDefaultTargetPlatformOverride（§21.1）。
// 实现前：AdaptiveTextField 不存在，本文件编译失败，属 TDD 红。
// 实现后：全部转绿。
// ============================================================

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/widgets/adaptive_text_field.dart';
import 'package:chatroom_flutter/widgets/raw_text_field.dart';

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// 平台模拟 helper（§21.1）：override 必须在 testWidgets body 内恢复——
/// flutter_test 的 foundation 变量 invariant 检查先于 group tearDown 执行
void testWidgetsOnPlatform(
    String description,
    TargetPlatform? platform,
    Future<void> Function(WidgetTester tester) body) {
  testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

String srcOf(String relPath) => File('lib/$relPath').readAsStringSync();

int countOf(String source, String needle) =>
    source.split(needle).length - 1;

const Set<TargetPlatform> nonLinuxPlatforms = {
  TargetPlatform.android,
  TargetPlatform.iOS,
  TargetPlatform.windows,
  TargetPlatform.macOS,
};

void main() {
  setUp(() {
    debugDefaultTargetPlatformOverride = null;
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  group('Q0-2 —— 适配层按平台选择（工厂契约）', () {
    testWidgetsOnPlatform('Linux 模拟 → 渲染 RawTextField（GTK 桥接语义保留）',
        TargetPlatform.linux, (tester) async {
      await tester.pumpWidget(host(AdaptiveTextField(
        controller: TextEditingController(),
        key: const ValueKey('linux'),
      )));
      await tester.pump();
      expect(find.byType(RawTextField), findsOneWidget,
          reason: 'Linux 基线不回退：仍走 RawTextField + GTK IME 桥接');
      expect(find.byType(TextField), findsNothing,
          reason: 'Linux 不走标准输入路径（现状语义不变）');
    });

    testWidgetsOnPlatform('Android 模拟 → 渲染标准 TextField', TargetPlatform.android, (tester) async {
      await tester.pumpWidget(host(AdaptiveTextField(
        controller: TextEditingController(),
        key: const ValueKey('android'),
      )));
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byType(RawTextField), findsNothing,
          reason: '非 Linux 不注册 GTK 桥接监听（NAV 桥接路径仅 Linux）');
    });

    testWidgetsOnPlatform('iOS/Windows/macOS 模拟 → 同样走标准输入路径',
        TargetPlatform.iOS, (tester) async {
      for (final platform in {
        TargetPlatform.iOS,
        TargetPlatform.windows,
        TargetPlatform.macOS,
      }) {
        debugDefaultTargetPlatformOverride = platform;
        await tester.pumpWidget(host(AdaptiveTextField(
          controller: TextEditingController(),
          key: ValueKey(platform),
        )));
        await tester.pump();
        expect(find.byType(TextField), findsOneWidget,
            reason: '$platform 走标准输入');
        expect(find.byType(RawTextField), findsNothing,
            reason: '$platform 不渲染 Linux 专属 RawTextField');
      }
    });

    testWidgetsOnPlatform('showChineseInput 仅 Linux 生效：非 Linux 传入不触发桥接路径',
        TargetPlatform.android, (tester) async {
      await tester.pumpWidget(host(AdaptiveTextField(
        controller: TextEditingController(),
        showChineseInput: true,
        key: const ValueKey('android-cn'),
      )));
      await tester.pump();
      expect(find.byType(RawTextField), findsNothing,
          reason: '移动端无 X11/GTK 上下文，showChineseInput 必须为无害冗余');
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgetsOnPlatform('Linux + showChineseInput → RawTextField 渲染且桥接注册安全'
        '（FLUTTER_TEST 下 ensureStarted 为 no-op）', TargetPlatform.linux,
        (tester) async {
      await tester.pumpWidget(host(AdaptiveTextField(
        controller: TextEditingController(),
        showChineseInput: true,
        key: const ValueKey('linux-cn'),
      )));
      await tester.pump();
      expect(find.byType(RawTextField), findsOneWidget);
    });
  });

  group('Q0-2 —— 非 Linux 标准输入语义（N5 ASCII 路径平台无关保留）', () {
    testWidgetsOnPlatform('ASCII 输入同步到 controller（系统 IME 通道）', TargetPlatform.android, (tester) async {
      final controller = TextEditingController();
      await tester.pumpWidget(host(AdaptiveTextField(controller: controller)));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'hello Q0');
      await tester.pump();
      expect(controller.text, 'hello Q0');
    });

    testWidgetsOnPlatform('回车提交触发 onSubmitted（TextInputAction.done）',
        TargetPlatform.android, (tester) async {
      final controller = TextEditingController();
      var submitted = '';
      await tester.pumpWidget(host(AdaptiveTextField(
        controller: controller,
        onSubmitted: (v) => submitted = v,
      )));
      await tester.pump();
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '提交内容');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(submitted, '提交内容',
          reason: '标准输入路径的提交语义与 RawTextField.onSubmitted 对齐');
    });

    testWidgetsOnPlatform('hintText 透传渲染', TargetPlatform.android, (tester) async {
      await tester.pumpWidget(host(AdaptiveTextField(
        controller: TextEditingController(),
        hintText: '输入消息…',
      )));
      await tester.pump();
      expect(find.text('输入消息…'), findsOneWidget);
    });

    testWidgetsOnPlatform('obscureText 透传（密码掩码）', TargetPlatform.android, (tester) async {
      await tester.pumpWidget(host(AdaptiveTextField(
        controller: TextEditingController(),
        obscureText: true,
        showVisibilityToggle: true,
      )));
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.obscureText, isTrue);
    });

    testWidgetsOnPlatform('focusNode 透传：tap 聚焦后 node.hasFocus 为真',
        TargetPlatform.android, (tester) async {
      final node = FocusNode();
      await tester.pumpWidget(host(AdaptiveTextField(
        controller: TextEditingController(),
        focusNode: node,
      )));
      await tester.pump();
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(node.hasFocus, isTrue);
    });
  });

  group('Q0-2 —— Linux 路径参数透传（RawTextField 语义不变）', () {
    testWidgetsOnPlatform('focusNode 透传：tap 聚焦后 node.hasFocus 为真', TargetPlatform.linux, (tester) async {
      final node = FocusNode();
      final controller = TextEditingController();
      await tester
          .pumpWidget(host(AdaptiveTextField(controller: controller, focusNode: node)));
      await tester.pump();
      final raw = tester.widget<RawTextField>(find.byType(RawTextField));
      expect(identical(raw.focusNode, node), isTrue,
          reason: '适配层不得重建 FocusNode（onKeyEvent 绑定依赖稳定 node）');
    });

    testWidgetsOnPlatform('obscureText/hintText/showVisibilityToggle 全参透传',
        TargetPlatform.linux, (tester) async {
      await tester.pumpWidget(host(AdaptiveTextField(
        controller: TextEditingController(),
        hintText: '密码',
        obscureText: true,
        showVisibilityToggle: true,
      )));
      await tester.pump();
      final raw = tester.widget<RawTextField>(find.byType(RawTextField));
      expect(raw.hintText, '密码');
      expect(raw.obscureText, isTrue);
      expect(raw.showVisibilityToggle, isTrue);
    });
  });

  group('Q0-2 —— 33 个实例化点收敛（源码扫描锁定）', () {
    test('适配层文件存在', () {
      expect(fileExists('lib/widgets/adaptive_text_field.dart'), isTrue);
    });

    test('dialogs.dart 不再直接实例化 RawTextField（25 处迁入适配层）', () {
      final src = srcOf('widgets/dialogs.dart');
      expect(countOf(src, 'RawTextField('), 0,
          reason: '统一工厂收敛：对话框输入框一律走 AdaptiveTextField');
      expect(countOf(src, 'AdaptiveTextField('), greaterThanOrEqualTo(25),
          reason: '文档基线：dialogs.dart 25 个输入实例化点');
    });

    test('login_screen.dart 不再直接实例化 RawTextField（3 处迁入）', () {
      final src = srcOf('screens/login_screen.dart');
      expect(countOf(src, 'RawTextField('), 0);
      expect(countOf(src, 'AdaptiveTextField('), greaterThanOrEqualTo(3));
    });

    test('chat_screen.dart 不再直接实例化 RawTextField（3 处迁入）', () {
      final src = srcOf('screens/chat_screen.dart');
      expect(countOf(src, 'RawTextField('), 0);
      expect(countOf(src, 'AdaptiveTextField('), greaterThanOrEqualTo(3));
    });

    test('chat_view.dart 不再直接实例化 RawTextField（2 处迁入）', () {
      final src = srcOf('widgets/chat_view.dart');
      expect(countOf(src, 'RawTextField('), 0);
      expect(countOf(src, 'AdaptiveTextField('), greaterThanOrEqualTo(2));
    });

    test('raw_text_field.dart 自身保留（Linux 路径实现本体不删除）', () {
      final src = srcOf('widgets/raw_text_field.dart');
      expect(src.contains('class RawTextField'), isTrue,
          reason: 'Linux = RawTextField + GTK 桥接（现状保持），适配层仅做分发');
    });
  });
}

bool fileExists(String path) => File(path).existsSync();
