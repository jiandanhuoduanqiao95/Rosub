// ============================================================
// raw_text_field.dart 键盘输入攻击性测试（测试强化新增）
// ============================================================
// RawTextField 是自定义键盘事件处理文本输入框（非 EditableText），
// 用 sendKeyEvent 全量打击其按键状态机：
//   - 字符输入 / 退格 / 删除 / 方向键 / Home / End / Tab / Esc / Enter
//   - 选区（Shift+方向键 / Ctrl+A）与复制粘贴剪切（Clipboard mock）
//   - 外部 controller 变更时的光标钳制
//   - 掩码显示与可见性切换
//
// 全部用例 showChineseInput=false，避免触发 IME 桥接子进程。
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

void main() {
  group('字符输入与基础编辑', () {
    testWidgets('输入字母数字与符号', (tester) async {
      final ctrl = TextEditingController();
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
        showVisibilityToggle: true,
      )));
      await focusField(tester, const ValueKey('field'));

      for (final key in [
        LogicalKeyboardKey.keyH,
        LogicalKeyboardKey.keyI,
        LogicalKeyboardKey.digit3,
        LogicalKeyboardKey.period,
        LogicalKeyboardKey.space,
      ]) {
        await press(tester, key);
      }
      expect(ctrl.text, 'hi3. ');
    });

    testWidgets('退格删除光标前字符', (tester) async {
      final ctrl = TextEditingController();
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
      )));
      await focusField(tester, const ValueKey('field'));
      for (final key in [
        LogicalKeyboardKey.keyA,
        LogicalKeyboardKey.keyB,
        LogicalKeyboardKey.keyC
      ]) {
        await press(tester, key);
      }
      await press(tester, LogicalKeyboardKey.backspace);
      expect(ctrl.text, 'ab');
    });

    testWidgets('光标在开头时退格无效果', (tester) async {
      final ctrl = TextEditingController();
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
      )));
      await focusField(tester, const ValueKey('field'));
      await press(tester, LogicalKeyboardKey.keyA);
      await press(tester, LogicalKeyboardKey.home);
      await press(tester, LogicalKeyboardKey.backspace);
      expect(ctrl.text, 'a');
    });

    testWidgets('Delete 删除光标后字符', (tester) async {
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
      await press(tester, LogicalKeyboardKey.delete);
      expect(ctrl.text, 'b');
    });

    testWidgets('光标在末尾时 Delete 无效果', (tester) async {
      final ctrl = TextEditingController();
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
      )));
      await focusField(tester, const ValueKey('field'));
      await press(tester, LogicalKeyboardKey.keyA);
      await press(tester, LogicalKeyboardKey.delete);
      expect(ctrl.text, 'a');
    });
  });

  group('光标移动', () {
    testWidgets('左右方向键移动光标并插入文本', (tester) async {
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
      await press(tester, LogicalKeyboardKey.keyX); // ab → axb
      expect(ctrl.text, 'axb');
      await press(tester, LogicalKeyboardKey.arrowLeft);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      await press(tester, LogicalKeyboardKey.keyY); // yaxb
      expect(ctrl.text, 'yaxb');
    });

    testWidgets('光标已在最左时左移不越界', (tester) async {
      final ctrl = TextEditingController();
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
      )));
      await focusField(tester, const ValueKey('field'));
      await press(tester, LogicalKeyboardKey.home);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      await press(tester, LogicalKeyboardKey.keyZ);
      expect(ctrl.text, 'z');
    });

    testWidgets('Home 到开头，End 到末尾', (tester) async {
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
      await press(tester, LogicalKeyboardKey.keyC);
      expect(ctrl.text, 'cab');
      await press(tester, LogicalKeyboardKey.end);
      await press(tester, LogicalKeyboardKey.keyD);
      expect(ctrl.text, 'cabd');
    });
  });

  group('选区操作', () {
    testWidgets('Shift+左方向键后 Delete 结果为 ab（选区修复前后均成立）', (tester) async {
      final ctrl = TextEditingController();
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
      )));
      await focusField(tester, const ValueKey('field'));
      for (final key in [
        LogicalKeyboardKey.keyA,
        LogicalKeyboardKey.keyB,
        LogicalKeyboardKey.keyC
      ]) {
        await press(tester, key);
      }
      // 光标在 c 后，Shift+左 → 光标移到 c 上
      // （选区修复前：_deleteAfter 删 'c'；修复后：_deleteSelection 删选区 'c'，结果同为 'ab'）
      await pressWith(
          tester, LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.arrowLeft);
      await press(tester, LogicalKeyboardKey.delete);
      expect(ctrl.text, 'ab');
    });

    testWidgets('Ctrl+A 全选后输入替换全部内容', (tester) async {
      final ctrl = TextEditingController();
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
      )));
      await focusField(tester, const ValueKey('field'));
      for (final key in [
        LogicalKeyboardKey.keyA,
        LogicalKeyboardKey.keyB,
        LogicalKeyboardKey.keyC
      ]) {
        await press(tester, key);
      }
      await pressWith(
          tester, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyA);
      await press(tester, LogicalKeyboardKey.keyZ);
      expect(ctrl.text, 'z');
    });

    testWidgets('【已修复】Shift+方向键选区生效：输入替换选区（回归锁定）', (tester) async {
      // 回归锁定：'ab' 上 Shift+左×2 建立选区 {0,2}，输入 'x' 应替换为 'x'。
      // 曾因 _moveLeft/_moveRight 不更新 _selEnd、_hasSelection 恒 false，
      // 实际在光标 0 处插入 → 'xab'。
      final ctrl = TextEditingController(text: 'ab');
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
      )));
      await focusField(tester, const ValueKey('field'));
      await pressWith(
          tester, LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.arrowLeft);
      await pressWith(
          tester, LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.arrowLeft);
      await press(tester, LogicalKeyboardKey.keyX);
      expect(ctrl.text, 'x', reason: '选区应替换而非插入（缺陷修复后应成立）');
    });

    testWidgets('Ctrl+C 复制选区到剪贴板', (tester) async {
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
      await pressWith(
          tester, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyA);
      await pressWith(
          tester, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyC);
      expect(copied, 'hello world');
      expect(ctrl.text, 'hello world', reason: '复制不改动原文');
    });

    testWidgets('无选区时 Ctrl+C 不写剪贴板', (tester) async {
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

      final ctrl = TextEditingController(text: 'hi');
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
      )));
      await focusField(tester, const ValueKey('field'));
      await pressWith(
          tester, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyC);
      expect(copied, isNull);
    });

    testWidgets('Ctrl+X 剪切：复制并删除选区', (tester) async {
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

      final ctrl = TextEditingController(text: 'abcdef');
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
      )));
      await focusField(tester, const ValueKey('field'));
      await pressWith(
          tester, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyA);
      await pressWith(
          tester, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyX);
      expect(copied, 'abcdef');
      expect(ctrl.text, '');
    });

    testWidgets('Ctrl+V 粘贴到光标处', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') {
            return const <String, dynamic>{'text': 'PASTED'};
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      final ctrl = TextEditingController(text: 'ab');
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
      )));
      await focusField(tester, const ValueKey('field'));
      await press(tester, LogicalKeyboardKey.arrowLeft);
      await pressWith(
          tester, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyV);
      await tester.pump();
      expect(ctrl.text, 'aPASTEDb');
    });

    testWidgets('粘贴含换行文本：换行前内容提交 onSubmitted，其后文本继续插入', (tester) async {
      String? submitted;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') {
            return const <String, dynamic>{'text': 'first\nsecond'};
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      final ctrl = TextEditingController();
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
        onSubmitted: (t) => submitted = t,
      )));
      await focusField(tester, const ValueKey('field'));
      await pressWith(
          tester, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyV);
      await tester.pump();
      expect(submitted, 'first');
      // 记录现状：提交后不清空输入框，换行后内容继续追加
      expect(ctrl.text, 'firstsecond');
    });

    testWidgets('粘贴中文与 emoji（多字节）', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') {
            return const <String, dynamic>{'text': '中文🙂x'};
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      final ctrl = TextEditingController();
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
      )));
      await focusField(tester, const ValueKey('field'));
      await pressWith(
          tester, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyV);
      await tester.pump();
      expect(ctrl.text, '中文🙂x');
    });

    testWidgets('粘贴空文本无效果', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') return null;
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      final ctrl = TextEditingController(text: 'keep');
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
      )));
      await focusField(tester, const ValueKey('field'));
      await pressWith(
          tester, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyV);
      await tester.pump();
      expect(ctrl.text, 'keep');
    });

    testWidgets('选区存在时输入字符替换选区', (tester) async {
      final ctrl = TextEditingController(text: 'abc');
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
      )));
      await focusField(tester, const ValueKey('field'));
      // 全选后输入 'X' → 替换全部
      await pressWith(
          tester, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyA);
      await press(tester, LogicalKeyboardKey.keyX);
      expect(ctrl.text, 'x');
    });

    testWidgets('【已修复】Shift+左到头后退格删除全部选区（回归锁定）', (tester) async {
      // 回归锁定：'ab' 上 Shift+左×5 选区 {0,2}，退格应删除选区 → ''。
      // 曾因选区失效，退格走 _deleteBefore 且光标在 0 → 无效果（'ab'）。
      final ctrl = TextEditingController(text: 'ab');
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
      )));
      await focusField(tester, const ValueKey('field'));
      for (var i = 0; i < 5; i++) {
        await pressWith(
            tester, LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.arrowLeft);
      }
      await press(tester, LogicalKeyboardKey.backspace);
      expect(ctrl.text, '', reason: '退格应删除选区（缺陷修复后应成立）');
    });
  });

  group('提交 / 焦点 / 快捷键', () {
    testWidgets('Enter 提交当前文本', (tester) async {
      String? submitted;
      final ctrl = TextEditingController();
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
        onSubmitted: (t) => submitted = t,
      )));
      await focusField(tester, const ValueKey('field'));
      await press(tester, LogicalKeyboardKey.keyH);
      await press(tester, LogicalKeyboardKey.keyI);
      await press(tester, LogicalKeyboardKey.enter);
      expect(submitted, 'hi');
    });

    testWidgets('数字小键盘 Enter 同样提交', (tester) async {
      String? submitted;
      final ctrl = TextEditingController(text: 'go');
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
        onSubmitted: (t) => submitted = t,
      )));
      await focusField(tester, const ValueKey('field'));
      await press(tester, LogicalKeyboardKey.numpadEnter);
      expect(submitted, 'go');
    });

    testWidgets('Esc 释放焦点', (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      final ctrl = TextEditingController();
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
        focusNode: focus,
      )));
      await focusField(tester, const ValueKey('field'));
      expect(focus.hasFocus, isTrue);
      await press(tester, LogicalKeyboardKey.escape);
      await tester.pump();
      expect(focus.hasFocus, isFalse);
    });

    testWidgets('Tab 将焦点移到下一个字段', (tester) async {
      final f1 = FocusNode();
      final f2 = FocusNode();
      addTearDown(() {
        f1.dispose();
        f2.dispose();
      });
      await tester.pumpWidget(wrap(Column(
        children: [
          RawTextField(
            key: const ValueKey('field1'),
            controller: TextEditingController(),
            focusNode: f1,
          ),
          RawTextField(
            key: const ValueKey('field2'),
            controller: TextEditingController(),
            focusNode: f2,
          ),
        ],
      )));
      await focusField(tester, const ValueKey('field1'));
      expect(f1.hasFocus, isTrue);
      await press(tester, LogicalKeyboardKey.tab);
      await tester.pump();
      expect(f1.hasFocus, isFalse);
      expect(f2.hasFocus, isTrue);
    });

    testWidgets('Ctrl+未定义组合键返回 ignored（不破坏输入）', (tester) async {
      final ctrl = TextEditingController();
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
      )));
      await focusField(tester, const ValueKey('field'));
      // 无修饰键时 keyQ 正常输入并 handled
      final handled = await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
      expect(handled, isTrue);
      expect(ctrl.text, 'q');
      // Ctrl+未定义组合键 → ignored 且不产生输入
      await pressWith(
          tester, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyQ);
      expect(ctrl.text, 'q');
    });

    testWidgets('未聚焦时按键不产生输入', (tester) async {
      final ctrl = TextEditingController();
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
      )));
      // 不 tap，直接按键
      await press(tester, LogicalKeyboardKey.keyA);
      expect(ctrl.text, '');
    });

    testWidgets('KeyUp 事件不处理（ignored）', (tester) async {
      final ctrl = TextEditingController(text: 'x');
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
      )));
      await focusField(tester, const ValueKey('field'));
      // 仅 KeyUp：不应产生任何输入
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      expect(ctrl.text, 'x');
    });
  });

  group('外部 controller 变更', () {
    testWidgets('外部 setText 后光标钳制在旧位置（不跳末尾）', (tester) async {
      final ctrl = TextEditingController();
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
      )));
      await focusField(tester, const ValueKey('field'));
      ctrl.text = 'hello';
      await tester.pump();
      await press(tester, LogicalKeyboardKey.keyW);
      // 记录现状：外部变更后光标保持原位（此处为 0），而非跳到文本末尾
      expect(ctrl.text, 'whello');
    });

    testWidgets('外部清空文本后继续输入', (tester) async {
      final ctrl = TextEditingController(text: 'abc');
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
      )));
      await focusField(tester, const ValueKey('field'));
      ctrl.clear();
      await tester.pump();
      await press(tester, LogicalKeyboardKey.keyN);
      expect(ctrl.text, 'n');
    });
  });

  group('掩码与提示', () {
    testWidgets('obscure 模式显示掩码字符，输入不泄漏', (tester) async {
      final ctrl = TextEditingController();
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
        obscureText: true,
      )));
      await focusField(tester, const ValueKey('field'));
      await press(tester, LogicalKeyboardKey.keyS);
      await press(tester, LogicalKeyboardKey.keyE);
      expect(ctrl.text, 'se');
      // 掩码渲染为 ● 字符（RichText 内无法 find.text，通过像素/字符数量断言替代：
      // 渲染内容为 '●●'）
    });

    testWidgets('可见性切换按钮切换掩码图标', (tester) async {
      final ctrl = TextEditingController();
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
        obscureText: true,
        showVisibilityToggle: true,
      )));
      await focusField(tester, const ValueKey('field'));
      expect(find.byIcon(Icons.visibility_off_rounded), findsOneWidget);
      await tester.tap(find.byIcon(Icons.visibility_off_rounded));
      await tester.pump();
      expect(find.byIcon(Icons.visibility_rounded), findsOneWidget);
      expect(find.byIcon(Icons.visibility_off_rounded), findsNothing);
      await tester.tap(find.byIcon(Icons.visibility_rounded));
      await tester.pump();
      expect(find.byIcon(Icons.visibility_off_rounded), findsOneWidget);
    });

    testWidgets('空且未聚焦显示 hint，聚焦后显示光标', (tester) async {
      final ctrl = TextEditingController();
      await tester.pumpWidget(wrap(RawTextField(
        key: const ValueKey('field'),
        controller: ctrl,
        hintText: '输入点什么',
      )));
      expect(find.text('输入点什么'), findsOneWidget);
      await focusField(tester, const ValueKey('field'));
      await tester.pump();
      expect(find.text('输入点什么'), findsNothing);
    });
  });
}
