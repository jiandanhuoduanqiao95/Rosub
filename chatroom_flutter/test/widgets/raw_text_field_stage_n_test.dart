// ============================================================
// raw_text_field.dart 阶段 N —— P-68 光标细条化 + N5 键盘导航（TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 N：
//
//  P-68 光标细条化（缺陷修复）：
//    现象：←/→ 方向键移动光标后，光标渲染为覆盖整个字符的块状光标
//    （宽度 = 字符字形宽，中文/全角字符下像"覆盖一个字"）。
//    修复方向：光标在任意位置均渲染细条 '|'（与末尾光标同样式：
//    primary 色 + w100 字重），字符本身正常渲染；选区高亮与
//    530ms 闪烁逻辑不变。
//
//  N5 键盘导航体系（P2-14 第一批）：
//    方向键（↑/↓）切换同一界面输入框焦点（上 = 前一个，下 = 下一个）；
//    回车键代替"提交/确定"——有 onSubmitted 回调的输入框回车触发提交/发送，
//    无回调的输入框回车自动跳到下一个输入框。
//
// 本文件全部用例 showChineseInput=false（不触发 IME 桥接子进程），
// 覆盖 ASCII/无桥接路径；桥接路径（NAV:UP/NAV:DOWN）见
// ime_bridge_nav_test.dart + tests/test_stage_n_ime.py。
//
// 实现前：P-68 用例对当前块状光标实现红；N5 用例对当前未处理 ↑/↓ 红。
// 实现后：全部转绿。
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/widgets/raw_text_field.dart';

Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

Future<void> focusField(WidgetTester tester, Key key) async {
  await tester.tap(find.byKey(key));
  await tester.pump();
}

Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump();
}

Future<void> pressWith(WidgetTester tester, LogicalKeyboardKey modifier,
    LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(modifier);
  await tester.pump();
  await tester.sendKeyEvent(key);
  await tester.pump();
  await tester.sendKeyUpEvent(modifier);
  await tester.pump();
}

/// 收集 RawTextField 内 RichText 的全部 TextSpan（含嵌套 children）。
List<TextSpan> collectSpans(WidgetTester tester) {
  final richText = tester.widget<RichText>(find.descendant(
    of: find.byType(RawTextField),
    matching: find.byType(RichText),
  ));
  final root = richText.text as TextSpan;
  final out = <TextSpan>[];
  void walk(InlineSpan span) {
    if (span is TextSpan) {
      out.add(span);
      for (final c in span.children ?? const <InlineSpan>[]) {
        walk(c);
      }
    }
  }

  walk(root);
  return out;
}

/// 是否存在细条光标 span（文本 '|' + w100 字重）。
bool hasThinCursorSpan(WidgetTester tester) {
  return collectSpans(tester)
      .any((s) => s.text == '|' && s.style?.fontWeight == FontWeight.w100);
}

/// 是否存在带背景色的 span（选区高亮/块状光标都会带 backgroundColor）。
List<TextSpan> backgroundSpans(WidgetTester tester) {
  return collectSpans(tester)
      .where((s) => s.style?.backgroundColor != null)
      .toList();
}

void main() {
  group('P-68 —— 光标细条化（任意位置均渲染细条 |）', () {
    testWidgets('光标在文本末尾渲染细条 |（既有行为回归锁定）', (tester) async {
      final ctrl = TextEditingController();
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
      )));
      await focusField(tester, const ValueKey('field'));
      for (final key in [
        LogicalKeyboardKey.keyA,
        LogicalKeyboardKey.keyB,
        LogicalKeyboardKey.keyC,
      ]) {
        await press(tester, key);
      }
      expect(hasThinCursorSpan(tester), isTrue, reason: '末尾光标应为细条 |');
      expect(backgroundSpans(tester), isEmpty, reason: '末尾无块状背景');
    });

    testWidgets('← 方向键移动后光标仍为细条（P-68 核心：字符不被块覆盖）', (tester) async {
      final ctrl = TextEditingController();
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
      )));
      await focusField(tester, const ValueKey('field'));
      for (final key in [
        LogicalKeyboardKey.keyA,
        LogicalKeyboardKey.keyB,
        LogicalKeyboardKey.keyC,
        LogicalKeyboardKey.keyD,
      ]) {
        await press(tester, key);
      }
      await press(tester, LogicalKeyboardKey.arrowLeft);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      // 光标位于 'ab|cd' 中间位置
      expect(hasThinCursorSpan(tester), isTrue,
          reason: '光标在中间也必须是细条 |（P-68 缺陷修复）');
      expect(backgroundSpans(tester), isEmpty, reason: '光标处字符不得以块状背景渲染');
    });

    testWidgets('全角/中文文本中间光标仍为细条（P-68 用户实测场景）', (tester) async {
      final ctrl = TextEditingController(text: '你好世界');
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
      )));
      await focusField(tester, const ValueKey('field'));
      await press(tester, LogicalKeyboardKey.arrowLeft);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(hasThinCursorSpan(tester), isTrue, reason: '中文中间光标必须是细条，不得覆盖整个字符');
      expect(backgroundSpans(tester), isEmpty);
      // 字符本身正常渲染（无 onPrimary 反色；文本按段分组，拼接验证）
      final joined = collectSpans(tester).map((s) => s.text ?? '').join();
      expect(joined, contains('你'), reason: '字符正常渲染');
      expect(joined, contains('世'));
    });

    testWidgets('光标在开头（Home）渲染细条', (tester) async {
      final ctrl = TextEditingController();
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
      )));
      await focusField(tester, const ValueKey('field'));
      for (final key in [LogicalKeyboardKey.keyA, LogicalKeyboardKey.keyB]) {
        await press(tester, key);
      }
      await press(tester, LogicalKeyboardKey.home);
      expect(hasThinCursorSpan(tester), isTrue, reason: '开头光标应为细条');
      expect(backgroundSpans(tester), isEmpty);
    });

    testWidgets('光标闪烁逻辑不变：530ms 隐藏、再 530ms 显示（P-68 回归锁定）', (tester) async {
      final ctrl = TextEditingController();
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
      )));
      await focusField(tester, const ValueKey('field'));
      for (final key in [LogicalKeyboardKey.keyA, LogicalKeyboardKey.keyB]) {
        await press(tester, key);
      }
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(hasThinCursorSpan(tester), isTrue);

      await tester.pump(const Duration(milliseconds: 530));
      expect(hasThinCursorSpan(tester), isFalse, reason: '闪烁隐藏期无光标');
      await tester.pump(const Duration(milliseconds: 530));
      expect(hasThinCursorSpan(tester), isTrue, reason: '闪烁显示期恢复细条');
    });

    testWidgets('选区高亮不变：Shift+→ 渲染半透明高亮而非细条（P-68 回归锁定）', (tester) async {
      final ctrl = TextEditingController();
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
      )));
      await focusField(tester, const ValueKey('field'));
      for (final key in [
        LogicalKeyboardKey.keyA,
        LogicalKeyboardKey.keyB,
        LogicalKeyboardKey.keyC,
      ]) {
        await press(tester, key);
      }
      await press(tester, LogicalKeyboardKey.home);
      await pressWith(
          tester, LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.arrowRight);
      await pressWith(
          tester, LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.arrowRight);
      // 选区 'ab' 高亮
      final bg = backgroundSpans(tester);
      expect(bg, isNotEmpty, reason: '选区应有高亮背景');
      expect(hasThinCursorSpan(tester), isFalse, reason: '选区时不显示光标细条');
      for (final s in bg) {
        expect(s.style!.backgroundColor!.a, lessThan(0.5),
            reason: '选区高亮为半透明（0.35），非块状光标（0.7）');
      }
    });

    testWidgets('掩码模式（obscureText）中间光标仍为细条', (tester) async {
      final ctrl = TextEditingController();
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
        obscureText: true,
      )));
      await focusField(tester, const ValueKey('field'));
      for (final key in [
        LogicalKeyboardKey.keyA,
        LogicalKeyboardKey.keyB,
        LogicalKeyboardKey.keyC,
      ]) {
        await press(tester, key);
      }
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(hasThinCursorSpan(tester), isTrue, reason: '掩码模式光标也应为细条');
      expect(backgroundSpans(tester), isEmpty);
    });
  });

  group('N5 —— 方向键切换输入框焦点', () {
    testWidgets('↓ 切换到下一个输入框', (tester) async {
      final f1 = FocusNode();
      final f2 = FocusNode();
      addTearDown(() {
        f1.dispose();
        f2.dispose();
      });
      await tester.pumpWidget(wrap(Column(
        children: [
          RawTextField(
            key: const ValueKey('f1'),
            controller: TextEditingController(),
            focusNode: f1,
          ),
          const SizedBox(height: 8),
          RawTextField(
            key: const ValueKey('f2'),
            controller: TextEditingController(),
            focusNode: f2,
          ),
        ],
      )));
      await focusField(tester, const ValueKey('f1'));
      expect(f1.hasFocus, isTrue);

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(f2.hasFocus, isTrue, reason: '↓ 应切到下一个输入框');
      expect(f1.hasFocus, isFalse);
    });

    testWidgets('↑ 切换到上一个输入框', (tester) async {
      final f1 = FocusNode();
      final f2 = FocusNode();
      addTearDown(() {
        f1.dispose();
        f2.dispose();
      });
      await tester.pumpWidget(wrap(Column(
        children: [
          RawTextField(
            key: const ValueKey('f1'),
            controller: TextEditingController(),
            focusNode: f1,
          ),
          const SizedBox(height: 8),
          RawTextField(
            key: const ValueKey('f2'),
            controller: TextEditingController(),
            focusNode: f2,
          ),
        ],
      )));
      await focusField(tester, const ValueKey('f2'));
      expect(f2.hasFocus, isTrue);

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(f1.hasFocus, isTrue, reason: '↑ 应切到上一个输入框');
      expect(f2.hasFocus, isFalse);
    });

    testWidgets('第一个输入框按 ↑ 不越界（焦点保持）', (tester) async {
      final f1 = FocusNode();
      final f2 = FocusNode();
      addTearDown(() {
        f1.dispose();
        f2.dispose();
      });
      await tester.pumpWidget(wrap(Column(
        children: [
          RawTextField(
            key: const ValueKey('f1'),
            controller: TextEditingController(),
            focusNode: f1,
          ),
          const SizedBox(height: 8),
          RawTextField(
            key: const ValueKey('f2'),
            controller: TextEditingController(),
            focusNode: f2,
          ),
        ],
      )));
      await focusField(tester, const ValueKey('f1'));
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(f1.hasFocus, isTrue, reason: '首个输入框 ↑ 不越界');
    });

    testWidgets('最后一个输入框按 ↓ 不越界', (tester) async {
      final f1 = FocusNode();
      final f2 = FocusNode();
      addTearDown(() {
        f1.dispose();
        f2.dispose();
      });
      await tester.pumpWidget(wrap(Column(
        children: [
          RawTextField(
            key: const ValueKey('f1'),
            controller: TextEditingController(),
            focusNode: f1,
          ),
          const SizedBox(height: 8),
          RawTextField(
            key: const ValueKey('f2'),
            controller: TextEditingController(),
            focusNode: f2,
          ),
        ],
      )));
      await focusField(tester, const ValueKey('f2'));
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(f2.hasFocus, isTrue, reason: '末尾输入框 ↓ 不越界');
    });

    testWidgets('三个输入框连续 ↓ 切换', (tester) async {
      final f1 = FocusNode();
      final f2 = FocusNode();
      final f3 = FocusNode();
      addTearDown(() {
        f1.dispose();
        f2.dispose();
        f3.dispose();
      });
      await tester.pumpWidget(wrap(Column(
        children: [
          RawTextField(
              key: const ValueKey('f1'),
              controller: TextEditingController(),
              focusNode: f1),
          const SizedBox(height: 8),
          RawTextField(
              key: const ValueKey('f2'),
              controller: TextEditingController(),
              focusNode: f2),
          const SizedBox(height: 8),
          RawTextField(
              key: const ValueKey('f3'),
              controller: TextEditingController(),
              focusNode: f3),
        ],
      )));
      await focusField(tester, const ValueKey('f1'));
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(f2.hasFocus, isTrue);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(f3.hasFocus, isTrue);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(f2.hasFocus, isTrue);
    });
  });

  group('N5 —— 鼠标文字选择（用户反馈补充）', () {
    testWidgets('点击定位光标（点击字符中间）', (tester) async {
      final ctrl = TextEditingController(text: 'abcd');
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
      )));
      await focusField(tester, const ValueKey('field'));
      // 点击文本中部（约 'b' 与 'c' 之间）——先输入一个字符验证插入点
      final textTopLeft =
          tester.getTopLeft(find.byKey(const ValueKey('field')));
      const offset = Offset(60, 28); // 框内中部偏左
      await tester.tapAt(textTopLeft + offset);
      await tester.pump();
      // 插入字符验证光标位置（点击后插入点应在点击处）
      await press(tester, LogicalKeyboardKey.keyX);
      expect(ctrl.text, isNot('xabcd'), reason: '点击定位后插入点不在开头');
      expect(ctrl.text, isNot('abcdx'), reason: '点击定位后插入点不在末尾');
      expect(ctrl.text.contains('x'), isTrue);
    });

    testWidgets('拖动选择文字后 Ctrl+C 复制选区', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      final ctrl = TextEditingController(text: 'hello world');
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
      )));
      await focusField(tester, const ValueKey('field'));
      final topLeft = tester.getTopLeft(find.byKey(const ValueKey('field')));
      // 从文本中部拖动到更右侧（选择后半段）
      final gesture = await tester.startGesture(topLeft + const Offset(40, 28));
      await tester.pump();
      // 分两步移动：首步越过触摸阈值触发 pan 识别，第二步定位选区末端
      await gesture.moveTo(topLeft + const Offset(60, 28));
      await tester.pump();
      await gesture.moveTo(topLeft + const Offset(110, 28));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      // 选区高亮存在（半透明背景 span）
      expect(backgroundSpans(tester), isNotEmpty, reason: '拖动后应产生选区高亮');
      await pressWith(
          tester, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyC);
      expect(copied, isNotNull, reason: 'Ctrl+C 应复制选区文本');
      expect(copied, isNotEmpty);
      expect(copied!.length, lessThan(ctrl.text.length),
          reason: '复制的应是选区子串而非全文');
    });

    testWidgets('点击后选区清除（无高亮残留）', (tester) async {
      final ctrl = TextEditingController(text: 'abcd');
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
      )));
      await focusField(tester, const ValueKey('field'));
      final topLeft = tester.getTopLeft(find.byKey(const ValueKey('field')));
      await tester.tapAt(topLeft + const Offset(50, 28));
      await tester.pump();
      expect(backgroundSpans(tester), isEmpty, reason: '点击定位不应产生选区');
    });
  });

  group('N5 —— 回车代替"提交/确定"', () {
    testWidgets('有 onSubmitted 的输入框回车触发提交（焦点不变）', (tester) async {
      final f1 = FocusNode();
      final f2 = FocusNode();
      addTearDown(() {
        f1.dispose();
        f2.dispose();
      });
      String? submitted;
      await tester.pumpWidget(wrap(Column(
        children: [
          RawTextField(
            key: const ValueKey('f1'),
            controller: TextEditingController(),
            focusNode: f1,
            onSubmitted: (text) => submitted = text,
          ),
          const SizedBox(height: 8),
          RawTextField(
            key: const ValueKey('f2'),
            controller: TextEditingController(),
            focusNode: f2,
          ),
        ],
      )));
      await focusField(tester, const ValueKey('f1'));
      await press(tester, LogicalKeyboardKey.keyH);
      await press(tester, LogicalKeyboardKey.keyI);
      await press(tester, LogicalKeyboardKey.enter);
      expect(submitted, 'hi', reason: '回车应触发 onSubmitted 提交');
      expect(f1.hasFocus, isTrue, reason: '提交后焦点保持在当前输入框');
    });

    testWidgets('无 onSubmitted 的输入框回车跳到下一个输入框', (tester) async {
      final f1 = FocusNode();
      final f2 = FocusNode();
      addTearDown(() {
        f1.dispose();
        f2.dispose();
      });
      await tester.pumpWidget(wrap(Column(
        children: [
          RawTextField(
            key: const ValueKey('f1'),
            controller: TextEditingController(),
            focusNode: f1,
          ),
          const SizedBox(height: 8),
          RawTextField(
            key: const ValueKey('f2'),
            controller: TextEditingController(),
            focusNode: f2,
            onSubmitted: (_) {},
          ),
        ],
      )));
      await focusField(tester, const ValueKey('f1'));
      await press(tester, LogicalKeyboardKey.enter);
      expect(f2.hasFocus, isTrue, reason: '无 onSubmitted 回车应跳到下一个输入框');
      expect(f1.hasFocus, isFalse);
    });

    testWidgets('最后一个无 onSubmitted 输入框回车不越界', (tester) async {
      final f1 = FocusNode();
      final f2 = FocusNode();
      addTearDown(() {
        f1.dispose();
        f2.dispose();
      });
      await tester.pumpWidget(wrap(Column(
        children: [
          RawTextField(
              key: const ValueKey('f1'),
              controller: TextEditingController(),
              focusNode: f1),
          const SizedBox(height: 8),
          RawTextField(
              key: const ValueKey('f2'),
              controller: TextEditingController(),
              focusNode: f2),
        ],
      )));
      await focusField(tester, const ValueKey('f2'));
      await press(tester, LogicalKeyboardKey.enter);
      expect(f2.hasFocus, isTrue, reason: '末尾无回调输入框回车不越界');
    });
  });
}
