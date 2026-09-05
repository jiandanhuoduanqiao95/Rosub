// ============================================================
// dialogs.dart 阶段 J —— 资料对话框 / 用户搜索对话框 / 拉黑确认（TDD 契约，待实现）
// ============================================================
// 覆盖 P0-2 / P1-9 / P1-10（《软件开发文档4.1.0.md》§13.2/§13.3）：
//   - showProfileDialog：展示昵称/签名/最后在线时间；编辑/刷新回调
//   - showUserSearchDialog：关键字搜索回调 + 结果列表 + 带验证消息的添加
//   - showBlockConfirmDialog：确认后触发拉黑回调；取消不触发
//
// 对话框接受纯参数（网络由上层注入），便于直接 pump 验证。
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/state_manager.dart';
import 'package:chatroom_flutter/widgets/dialogs.dart';
import 'package:chatroom_flutter/widgets/raw_text_field.dart';

AppState get state => AppState.instance;

void resetState() {
  state
    ..setLoggedOut()
    ..setConnectionStatus(ConnectionStatus.disconnected);
}

LogicalKeyboardKey _charKey(String ch) {
  if (ch == ' ') return LogicalKeyboardKey.space;
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

/// 向最上层（对话框内）的 RawTextField 键入文本（RawTextField 不接系统 IME，
/// 只能逐键发送键盘事件；先点击输入框聚焦，同 dialogs_test.dart 惯例）。
/// 取 .last：嵌套对话框打开后，上层对话框的输入框位于最后。
/// [index] 指定 RawTextField 序号；[tapField] 为 false 时不先点击（手动聚焦后）。
Future<void> typeInto(WidgetTester tester, String text,
    {int? index, bool tapField = true}) async {
  final target = index != null
      ? find.byType(RawTextField).at(index)
      : find.byType(RawTextField).last;
  if (tapField) {
    await tester.tap(target);
    await tester.pump();
  }
  for (final ch in text.split('')) {
    await tester.sendKeyEvent(_charKey(ch));
    await tester.pump();
  }
}

Future<void> pumpOpen(
    WidgetTester tester, Future<void> Function(BuildContext) open) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(builder: (context) {
        return ElevatedButton(
          onPressed: () => open(context),
          child: const Text('open'),
        );
      }),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// 模拟真实应用主题（main.dart）：FilledButton minimumSize = Size.fromHeight(46)
/// （宽度为 Infinity）。该主题是"添加好友对话框卡死"崩溃的必要条件——
/// IntrinsicWidth 测量阶段给 content 无界宽度，Infinity 最小宽度按钮崩溃。
Future<void> pumpOpenWithAppTheme(
    WidgetTester tester, Future<void> Function(BuildContext) open) async {
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(46),
        ),
      ),
    ),
    home: Scaffold(
      body: Builder(builder: (context) {
        return ElevatedButton(
          onPressed: () => open(context),
          child: const Text('open'),
        );
      }),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(resetState);

  group('J1 —— 资料对话框', () {
    testWidgets('展示昵称与签名', (tester) async {
      final profile = UserProfile(
        username: 'bob',
        nickname: '阿波',
        signature: '认真生活',
      );
      await pumpOpen(tester, (ctx) async {
        showProfileDialog(ctx,
            username: 'bob', profile: profile, onEdit: () {}, onRefresh: () {});
      });
      expect(find.text('阿波'), findsOneWidget);
      expect(find.text('认真生活'), findsOneWidget);
    });

    testWidgets('无昵称时展示用户名', (tester) async {
      await pumpOpen(tester, (ctx) async {
        showProfileDialog(ctx,
            username: 'bob',
            profile: UserProfile(username: 'bob'),
            onEdit: () {},
            onRefresh: () {});
      });
      expect(find.text('bob'), findsWidgets);
    });

    testWidgets('展示最后在线时间', (tester) async {
      final profile = UserProfile(
        username: 'bob',
        lastSeen: DateTime(2026, 8, 13, 10, 30),
      );
      await pumpOpen(tester, (ctx) async {
        showProfileDialog(ctx,
            username: 'bob', profile: profile, onEdit: () {}, onRefresh: () {});
      });
      expect(find.textContaining('最后在线'), findsOneWidget);
      expect(find.textContaining('10:30'), findsOneWidget);
    });

    testWidgets('profile 为空时展示用户名与占位提示（不崩溃）', (tester) async {
      await pumpOpen(tester, (ctx) async {
        showProfileDialog(ctx,
            username: 'bob', onEdit: () {}, onRefresh: () {});
      });
      expect(find.text('bob'), findsWidgets);
    });

    testWidgets('点击编辑触发 onEdit', (tester) async {
      var edited = 0;
      await pumpOpen(tester, (ctx) async {
        showProfileDialog(ctx,
            username: 'bob',
            profile: UserProfile(username: 'bob'),
            onEdit: () => edited++,
            onRefresh: () {});
      });
      await tester.tap(find.byIcon(Icons.edit));
      await tester.pump();
      expect(edited, 1);
    });

    testWidgets('点击刷新触发 onRefresh', (tester) async {
      var refreshed = 0;
      await pumpOpen(tester, (ctx) async {
        showProfileDialog(ctx,
            username: 'bob',
            profile: UserProfile(username: 'bob'),
            onEdit: () {},
            onRefresh: () => refreshed++);
      });
      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pump();
      expect(refreshed, 1);
    });

    testWidgets('资料异步拉取完成后对话框实时刷新（回归：首次点击不再卡"加载中"）', (tester) async {
      // 模拟首次点击：profile 未缓存（fetchProfile 响应未到达）→ 显示占位
      await pumpOpen(tester, (ctx) async {
        showProfileDialog(ctx,
            username: 'bob', onEdit: () {}, onRefresh: () {});
      });
      expect(find.textContaining('加载'), findsOneWidget, reason: '资料未到达时显示加载占位');

      // 模拟 fetchProfile 响应到达：state.updateProfile 触发通知 → 对话框实时刷新
      state.updateProfile(
          UserProfile(username: 'bob', nickname: '阿波', signature: '你好'));
      await tester.pumpAndSettle();

      expect(find.text('阿波'), findsOneWidget, reason: '昵称实时显示');
      expect(find.text('你好'), findsOneWidget, reason: '签名实时显示');
      expect(find.textContaining('加载'), findsNothing,
          reason: '加载占位消失——首次点击即可看到资料，无需二次点击');
    });

    testWidgets('已缓存的资料首次打开即显示（无加载占位）', (tester) async {
      // 模拟此前已拉取过资料（二次点击场景）：打开即显示，无"加载中"
      state.updateProfile(UserProfile(username: 'bob', nickname: '阿波'));
      await pumpOpen(tester, (ctx) async {
        showProfileDialog(ctx,
            username: 'bob', onEdit: () {}, onRefresh: () {});
      });
      expect(find.text('阿波'), findsOneWidget);
      expect(find.textContaining('加载'), findsNothing);
    });
  });

  group('J4 —— 用户搜索对话框', () {
    testWidgets('输入关键字点击搜索触发 onSearch', (tester) async {
      String? keyword;
      await pumpOpen(tester, (ctx) async {
        showUserSearchDialog(
          ctx,
          onSearch: (k) => keyword = k,
          onAdd: (_, __, ___) {},
        );
      });
      await typeInto(tester, 'alice');
      await tester.tap(find.text('搜索'));
      await tester.pump();
      expect(keyword, 'alice');
    });

    testWidgets('真实应用主题下打开不崩溃（回归：FilledButton 无限宽最小尺寸）', (tester) async {
      // 修复前：应用主题 FilledButton minimumSize=Size.fromHeight(46)
      // （宽度 Infinity）→ 对话框 IntrinsicWidth 无界宽度测量 → 崩溃
      await pumpOpenWithAppTheme(tester, (ctx) async {
        showUserSearchDialog(
          ctx,
          onSearch: (_) {},
          onAdd: (_, __, ___) {},
        );
      });
      expect(find.text('搜索'), findsOneWidget);
      expect(find.text('暂无结果'), findsOneWidget);
      // 搜索按钮可用
      await tester.tap(find.text('搜索'));
      await tester.pump();
    });

    testWidgets('空关键字不触发搜索（提示）', (tester) async {
      var called = 0;
      await pumpOpen(tester, (ctx) async {
        showUserSearchDialog(
          ctx,
          onSearch: (_) => called++,
          onAdd: (_, __, ___) {},
        );
      });
      await tester.tap(find.text('搜索'));
      await tester.pump();
      expect(called, 0, reason: '空关键字不应触发搜索');
    });

    testWidgets('搜索结果来自 AppState 并渲染', (tester) async {
      await pumpOpen(tester, (ctx) async {
        showUserSearchDialog(
          ctx,
          onSearch: (_) {},
          onAdd: (_, __, ___) {},
        );
      });
      state.setUserSearchResults(['alice', 'bob2']);
      await tester.pumpAndSettle();
      expect(find.text('alice'), findsOneWidget);
      expect(find.text('bob2'), findsOneWidget);
    });

    testWidgets('无结果时显示空提示', (tester) async {
      await pumpOpen(tester, (ctx) async {
        showUserSearchDialog(
          ctx,
          onSearch: (_) {},
          onAdd: (_, __, ___) {},
        );
      });
      expect(find.textContaining('无结果'), findsOneWidget);
    });

    testWidgets('点击结果添加 → 填验证消息 → onAdd(username, message, note)',
        (tester) async {
      String? addedUser;
      String? addedMessage;
      String? addedNote;
      await pumpOpen(tester, (ctx) async {
        showUserSearchDialog(
          ctx,
          onSearch: (_) {},
          onAdd: (u, m, n) {
            addedUser = u;
            addedMessage = m;
            addedNote = n;
          },
        );
      });
      state.setUserSearchResults(['alice']);
      await tester.pumpAndSettle();
      await tester.tap(find.text('alice'));
      await tester.pumpAndSettle();
      // 字段顺序：关键字(0) → 备注名(1) → 验证消息(2)
      await typeInto(tester, 'from project team', index: 2);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(addedUser, 'alice');
      expect(addedMessage, 'from project team');
      expect(addedNote, '');
    });

    testWidgets('发送请求时可填写备注名 → onAdd(username, message, note)', (tester) async {
      String? addedUser;
      String? addedMessage;
      String? addedNote;
      await pumpOpen(tester, (ctx) async {
        showUserSearchDialog(
          ctx,
          onSearch: (_) {},
          onAdd: (u, m, n) {
            addedUser = u;
            addedMessage = m;
            addedNote = n;
          },
        );
      });
      state.setUserSearchResults(['alice']);
      await tester.pumpAndSettle();
      await tester.tap(find.text('alice'));
      await tester.pumpAndSettle();
      // 备注名框（index=1）填写备注；验证消息框留空
      await typeInto(tester, 'ALI', index: 1);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(addedUser, 'alice');
      expect(addedMessage, '');
      expect(addedNote, 'ali');
    });

    testWidgets('添加时可跳过验证消息与备注名（空输入）', (tester) async {
      String? addedUser;
      String? addedMessage;
      String? addedNote;
      await pumpOpen(tester, (ctx) async {
        showUserSearchDialog(
          ctx,
          onSearch: (_) {},
          onAdd: (u, m, n) {
            addedUser = u;
            addedMessage = m;
            addedNote = n;
          },
        );
      });
      state.setUserSearchResults(['alice']);
      await tester.pumpAndSettle();
      await tester.tap(find.text('alice'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(addedUser, 'alice');
      expect(addedMessage, '');
      expect(addedNote, '');
    });
  });

  group('J4 —— 拉黑确认对话框', () {
    testWidgets('确认触发 onBlock', (tester) async {
      var blocked = 0;
      await pumpOpen(tester, (ctx) async {
        showBlockConfirmDialog(ctx, 'bob', () => blocked++);
      });
      expect(find.textContaining('bob'), findsWidgets);
      await tester.tap(find.text('拉黑'));
      await tester.pumpAndSettle();
      expect(blocked, 1);
    });

    testWidgets('取消不触发 onBlock', (tester) async {
      var blocked = 0;
      await pumpOpen(tester, (ctx) async {
        showBlockConfirmDialog(ctx, 'bob', () => blocked++);
      });
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(blocked, 0);
    });
  });
}
