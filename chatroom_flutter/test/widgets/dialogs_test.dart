// ============================================================
// dialogs.dart 全流程 Widget 测试（测试强化新增）
// ============================================================
// 覆盖全部对话框的正向 / 反向 / 边界流程：
//   - 添加好友（trim / 非法用户名 SnackBar / 合法回调）
//   - 创建群组（空名 no-op / 合法回调）
//   - 加入群组（非法 ID / 0 / 负数 / 合法）
//   - 好友请求（空态 / 接受 / 拒绝）
//   - 文件请求（空态 / B/KB/MB 格式化 / 群文件标记 / 接受 / 拒绝）
//   - 管理面板（list_users / 公告 / 删除用户，mocktail mock SocketService）
//   - 修改密码（短密码 / 不一致 / 合法提交）
//   - 删除好友确认、群组信息（成员列表 / 创建者标记 / 加载态）
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/socket_service.dart';
import 'package:chatroom_flutter/services/state_manager.dart';
import 'package:chatroom_flutter/widgets/dialogs.dart';
import 'package:chatroom_flutter/widgets/raw_text_field.dart';

class MockSocketService extends Mock implements SocketService {}

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
  if (ch == '-') return LogicalKeyboardKey.minus;
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

Future<void> typeInto(WidgetTester tester, String text,
    {bool tapField = true, int index = 0}) async {
  // RawTextField 不自动聚焦，先点击对话框内的输入框
  if (tapField) {
    await tester.tap(find.byType(RawTextField).at(index));
    await tester.pump();
  }
  for (final ch in text.split('')) {
    await tester.sendKeyEvent(_charKey(ch));
    await tester.pump();
  }
}

/// 构造带 Builder 的宿主，用于弹对话框
Widget host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) => child),
      ),
    );

Future<void> openDialog(WidgetTester tester, Widget button,
    {bool settle = true}) async {
  await tester.pumpWidget(host(button));
  await tester.tap(find.text('open'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // 对话框内含无限动画（CircularProgressIndicator）时 pumpAndSettle 会超时
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  setUp(resetState);

  group('添加好友对话框', () {
    testWidgets('合法用户名调用 onAdd（含 trim）', (tester) async {
      String? added;
      await openDialog(
          tester,
          ElevatedButton(
            onPressed: () => showAddFriendDialog(
                tester.element(find.byType(ElevatedButton)),
                (name) => added = name),
            child: const Text('open'),
          ));

      await typeInto(tester, '  bobby  ');
      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();

      expect(added, 'bobby');
    });

    testWidgets('非法用户名弹 SnackBar 且对话框不关闭', (tester) async {
      String? added;
      await openDialog(
          tester,
          ElevatedButton(
            onPressed: () => showAddFriendDialog(
                tester.element(find.byType(ElevatedButton)),
                (name) => added = name),
            child: const Text('open'),
          ));

      await typeInto(tester, 'ab'); // 太短
      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();

      expect(find.text('用户名长度不能少于 3 个字符'), findsOneWidget);
      expect(added, isNull);
      expect(find.text('添加好友'), findsOneWidget, reason: '对话框保持打开');
    });

    testWidgets('取消关闭对话框且不回调', (tester) async {
      String? added;
      await openDialog(
          tester,
          ElevatedButton(
            onPressed: () => showAddFriendDialog(
                tester.element(find.byType(ElevatedButton)),
                (name) => added = name),
            child: const Text('open'),
          ));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(added, isNull);
      expect(find.text('添加好友'), findsNothing);
    });
  });

  group('创建群组对话框', () {
    testWidgets('空群名点创建不回调且保持打开', (tester) async {
      String? created;
      await openDialog(
          tester,
          ElevatedButton(
            onPressed: () => showCreateGroupDialog(
                tester.element(find.byType(ElevatedButton)),
                (name) => created = name),
            child: const Text('open'),
          ));
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();
      expect(created, isNull);
      expect(find.text('创建群组'), findsOneWidget);
    });

    testWidgets('合法群名回调并关闭', (tester) async {
      String? created;
      await openDialog(
          tester,
          ElevatedButton(
            onPressed: () => showCreateGroupDialog(
                tester.element(find.byType(ElevatedButton)),
                (name) => created = name),
            child: const Text('open'),
          ));
      await typeInto(tester, 'devteam');
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();
      expect(created, 'devteam');
      expect(find.text('创建群组'), findsNothing);
    });
  });

  group('加入群组对话框', () {
    testWidgets('非法 ID（字母）弹 SnackBar', (tester) async {
      int? joined;
      await openDialog(
          tester,
          ElevatedButton(
            onPressed: () => showJoinGroupDialog(
                tester.element(find.byType(ElevatedButton)),
                (id) => joined = id),
            child: const Text('open'),
          ));
      await typeInto(tester, 'abc');
      await tester.tap(find.text('加入'));
      await tester.pumpAndSettle();
      expect(find.text('请输入有效的群组 ID'), findsOneWidget);
      expect(joined, isNull);
    });

    testWidgets('ID=0 与负数被拒', (tester) async {
      for (final bad in ['0', '-5']) {
        int? joined;
        await openDialog(
            tester,
            ElevatedButton(
              onPressed: () => showJoinGroupDialog(
                  tester.element(find.byType(ElevatedButton)),
                  (id) => joined = id),
              child: const Text('open'),
            ));
        await typeInto(tester, bad);
        await tester.tap(find.text('加入'));
        await tester.pumpAndSettle();
        expect(find.text('请输入有效的群组 ID'), findsOneWidget, reason: '输入 $bad 应被拒');
        expect(joined, isNull);
        // 关闭对话框准备下一个
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
      }
    });

    testWidgets('合法 ID 回调', (tester) async {
      int? joined;
      await openDialog(
          tester,
          ElevatedButton(
            onPressed: () => showJoinGroupDialog(
                tester.element(find.byType(ElevatedButton)),
                (id) => joined = id),
            child: const Text('open'),
          ));
      await typeInto(tester, '42');
      await tester.tap(find.text('加入'));
      await tester.pumpAndSettle();
      expect(joined, 42);
    });
  });

  group('好友请求对话框', () {
    testWidgets('空列表显示占位', (tester) async {
      await openDialog(
          tester,
          ElevatedButton(
            onPressed: () => showFriendRequestsDialog(
                tester.element(find.byType(ElevatedButton)),
                const [],
                (u, a, n) {}),
            child: const Text('open'),
          ));
      expect(find.text('暂无待处理的好友请求'), findsOneWidget);
    });

    testWidgets('展示请求者的验证消息（阶段 J）', (tester) async {
      // 预置验证消息（服务端 friend_request 携带 message 头时写入）
      AppState.instance.addPendingRequest('bob', message: '我是 alice，来自项目组');
      await openDialog(
          tester,
          ElevatedButton(
            onPressed: () => showFriendRequestsDialog(
                tester.element(find.byType(ElevatedButton)),
                const ['bob'],
                (u, a, n) {}),
            child: const Text('open'),
          ));
      expect(find.textContaining('我是 alice，来自项目组'), findsOneWidget);
    });

    testWidgets('无验证消息时显示默认提示', (tester) async {
      await openDialog(
          tester,
          ElevatedButton(
            onPressed: () => showFriendRequestsDialog(
                tester.element(find.byType(ElevatedButton)),
                const ['bob'],
                (u, a, n) {}),
            child: const Text('open'),
          ));
      expect(find.text('请求添加您为好友'), findsOneWidget);
    });

    testWidgets('接受 → 询问备注 → 跳过 → (username, true, "")', (tester) async {
      final responses = <(String, bool, String)>[];
      await openDialog(
          tester,
          ElevatedButton(
            onPressed: () => showFriendRequestsDialog(
                tester.element(find.byType(ElevatedButton)),
                const ['bob', 'carol'],
                (u, a, n) => responses.add((u, a, n))),
            child: const Text('open'),
          ));
      expect(find.text('bob'), findsOneWidget);
      expect(find.text('carol'), findsOneWidget);

      // 接受 bob → 弹出备注询问框 → 跳过（不添加备注）
      await tester.tap(find.byTooltip('接受').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('是否添加备注'), findsOneWidget);
      await tester.tap(find.text('跳过'));
      await tester.pumpAndSettle();
      expect(responses, [('bob', true, '')]);
      expect(find.text('好友请求'), findsNothing);
    });

    testWidgets('接受 → 备注询问框填写备注 → (username, true, note)', (tester) async {
      final responses = <(String, bool, String)>[];
      await openDialog(
          tester,
          ElevatedButton(
            onPressed: () => showFriendRequestsDialog(
                tester.element(find.byType(ElevatedButton)),
                const ['bob'],
                (u, a, n) => responses.add((u, a, n))),
            child: const Text('open'),
          ));
      await tester.tap(find.byTooltip('接受'));
      await tester.pumpAndSettle();
      // 输入备注名（RawTextField 逐键输入）
      await typeInto(tester, 'ahbo');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(responses, [('bob', true, 'ahbo')]);
    });

    testWidgets('拒绝回调', (tester) async {
      final responses = <(String, bool, String)>[];
      await openDialog(
          tester,
          ElevatedButton(
            onPressed: () => showFriendRequestsDialog(
                tester.element(find.byType(ElevatedButton)),
                const ['bob'],
                (u, a, n) => responses.add((u, a, n))),
            child: const Text('open'),
          ));
      await tester.tap(find.byTooltip('拒绝'));
      await tester.pumpAndSettle();
      expect(responses, [('bob', false, '')]);
    });
  });

  group('文件请求对话框', () {
    testWidgets('空列表占位', (tester) async {
      await openDialog(
          tester,
          ElevatedButton(
            onPressed: () => showFileRequestsDialog(
                tester.element(find.byType(ElevatedButton)),
                const [],
                (r, a) {}),
            child: const Text('open'),
          ));
      expect(find.text('暂无待处理的文件请求'), findsOneWidget);
    });

    testWidgets('大小格式化 B/KB/MB', (tester) async {
      final reqs = [
        FileRequest(
            messageId: 'a',
            sender: 'alice',
            filename: 'tiny.txt',
            filesize: 500),
        FileRequest(
            messageId: 'b', sender: 'bob', filename: 'mid.dat', filesize: 2048),
        FileRequest(
            messageId: 'c',
            sender: 'carol',
            filename: 'big.bin',
            filesize: 5 * 1024 * 1024),
        FileRequest(
            messageId: 'd',
            sender: 'dave',
            filename: 'grp.dat',
            filesize: 1024,
            groupId: 7),
      ];
      await openDialog(
          tester,
          ElevatedButton(
            onPressed: () => showFileRequestsDialog(
                tester.element(find.byType(ElevatedButton)), reqs, (r, a) {}),
            child: const Text('open'),
          ));
      expect(find.textContaining('500 B'), findsOneWidget);
      expect(find.textContaining('2.0 KB'), findsOneWidget);
      expect(find.textContaining('5.0 MB'), findsOneWidget);
      // 群文件标记
      expect(find.textContaining('群文件'), findsOneWidget);
    });

    testWidgets('接受回调传递请求对象', (tester) async {
      final req = FileRequest(
          messageId: 'f1', sender: 'bob', filename: 'x.bin', filesize: 10);
      FileRequest? responded;
      bool? accepted;
      await openDialog(
          tester,
          ElevatedButton(
            onPressed: () => showFileRequestsDialog(
                tester.element(find.byType(ElevatedButton)), [req], (r, a) {
              responded = r;
              accepted = a;
            }),
            child: const Text('open'),
          ));
      await tester.tap(find.byTooltip('接受'));
      await tester.pumpAndSettle();
      expect(responded?.messageId, 'f1');
      expect(accepted, isTrue);
    });
  });

  group('删除好友确认对话框', () {
    testWidgets('确认触发 onDelete', (tester) async {
      String? deleted;
      await openDialog(
          tester,
          ElevatedButton(
            onPressed: () => showDeleteFriendDialog(
                tester.element(find.byType(ElevatedButton)),
                'bob',
                () => deleted = 'bob'),
            child: const Text('open'),
          ));
      expect(find.textContaining('确定删除好友 bob'), findsOneWidget);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(deleted, 'bob');
    });

    testWidgets('取消不触发 onDelete', (tester) async {
      String? deleted;
      await openDialog(
          tester,
          ElevatedButton(
            onPressed: () => showDeleteFriendDialog(
                tester.element(find.byType(ElevatedButton)),
                'bob',
                () => deleted = 'bob'),
            child: const Text('open'),
          ));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(deleted, isNull);
    });
  });

  group('管理面板', () {
    // mocktail 对 Future<void> 返回类型默认返回 null 会抛
    // "Null is not a subtype of Future<void>"，统一预置桩
    void stubAdmin(MockSocketService service) {
      when(() => service.adminCommand(any())).thenAnswer((_) async {});
      when(() =>
              service.adminCommand(any(), targetUser: any(named: 'targetUser')))
          .thenAnswer((_) async {});
      when(() => service.adminCommand(any(),
          announcement: any(named: 'announcement'))).thenAnswer((_) async {});
    }

    testWidgets('查看所有用户调用 adminCommand(list_users)', (tester) async {
      final service = MockSocketService();
      stubAdmin(service);
      state.setLoggedIn('admin', true);
      await openDialog(
          tester,
          ElevatedButton(
            onPressed: () => showAdminPanel(
                tester.element(find.byType(ElevatedButton)), service, state),
            child: const Text('open'),
          ));
      await tester.tap(find.text('查看所有用户'));
      await tester.pumpAndSettle();
      verify(() => service.adminCommand('list_users')).called(1);
    });

    testWidgets('发送公告流程', (tester) async {
      final service = MockSocketService();
      stubAdmin(service);
      state.setLoggedIn('admin', true);
      await openDialog(
          tester,
          ElevatedButton(
            onPressed: () => showAdminPanel(
                tester.element(find.byType(ElevatedButton)), service, state),
            child: const Text('open'),
          ));
      await tester.tap(find.text('发送系统公告'));
      await tester.pumpAndSettle();

      // 空公告点发送：不调用
      await tester.tap(find.text('发送'));
      await tester.pumpAndSettle();
      verifyNever(() => service.adminCommand(any(),
          announcement: any(named: 'announcement')));

      // 输入公告
      await typeInto(tester, 'helloall');
      await tester.tap(find.text('发送'));
      await tester.pumpAndSettle();
      verify(() =>
              service.adminCommand('announcement', announcement: 'helloall'))
          .called(1);
    });

    testWidgets('删除用户：非法名弹 SnackBar，合法名调用 adminCommand', (tester) async {
      final service = MockSocketService();
      stubAdmin(service);
      state.setLoggedIn('admin', true);
      await openDialog(
          tester,
          ElevatedButton(
            onPressed: () => showAdminPanel(
                tester.element(find.byType(ElevatedButton)), service, state),
            child: const Text('open'),
          ));
      // 注意：点"删除用户"会先 pop 管理面板再弹删除框
      await tester.tap(find.text('删除用户'));
      await tester.pumpAndSettle();

      // 非法（太短）
      await typeInto(tester, 'a');
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('用户名长度不能少于 3 个字符'), findsOneWidget);
      verifyNever(() =>
          service.adminCommand(any(), targetUser: any(named: 'targetUser')));

      // 取消删除框 → 需重新打开管理面板（记录现状：面板已在打开删除框时关闭）
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除用户'));
      await tester.pumpAndSettle();
      await typeInto(tester, 'villain');
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      verify(() => service.adminCommand('delete_user', targetUser: 'villain'))
          .called(1);
    });

    testWidgets('重置用户密码：短密码拦截，合法密码调用 adminResetPassword（阶段 J）', (tester) async {
      final service = MockSocketService();
      stubAdmin(service);
      when(() => service.adminResetPassword(any(), any()))
          .thenAnswer((_) async {});
      state.setLoggedIn('admin', true);
      await openDialog(
          tester,
          ElevatedButton(
            onPressed: () => showAdminPanel(
                tester.element(find.byType(ElevatedButton)), service, state),
            child: const Text('open'),
          ));
      await tester.tap(find.text('重置用户密码'));
      await tester.pumpAndSettle();

      // 新密码过短 → SnackBar 拦截，不调用
      await typeInto(tester, 'bob', index: 0);
      await typeInto(tester, '123', index: 1);
      await tester.tap(find.text('重置'));
      await tester.pumpAndSettle();
      expect(find.text('密码长度不能少于 6 个字符'), findsOneWidget);
      verifyNever(() => service.adminResetPassword(any(), any()));

      // 取消并重新打开（输入框内容清空）→ 合法输入 → 调用
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重置用户密码'));
      await tester.pumpAndSettle();
      await typeInto(tester, 'bob', index: 0);
      await typeInto(tester, 'newpass123', index: 1);
      await tester.tap(find.text('重置'));
      await tester.pumpAndSettle();
      verify(() => service.adminResetPassword('bob', 'newpass123')).called(1);
    });
  });

  group('修改密码对话框', () {
    // changePassword 返回 Future<bool>，需预置桩避免 null 返回异常
    void stubChangePw(MockSocketService service) {
      when(() => service.changePassword(any(), any()))
          .thenAnswer((_) async => true);
    }

    testWidgets('新密码为空弹 SnackBar（对齐服务端 P-17 文案）', (tester) async {
      final service = MockSocketService();
      stubChangePw(service);
      state.setLoggedIn('alice', false);
      await openDialog(
          tester,
          ElevatedButton(
            onPressed: () => showChangePasswordDialog(
                tester.element(find.byType(ElevatedButton)), service),
            child: const Text('open'),
          ));
      await typeInto(tester, 'oldpass'); // 旧密码
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      // 新密码为空 → 与服务端 validate_password 一致文案"密码不能为空"
      expect(find.text('密码不能为空'), findsOneWidget);
      verifyNever(() => service.changePassword(any(), any()));
    });

    testWidgets('两次新密码不一致弹 SnackBar', (tester) async {
      final service = MockSocketService();
      stubChangePw(service);
      state.setLoggedIn('alice', false);
      await openDialog(
          tester,
          ElevatedButton(
            onPressed: () => showChangePasswordDialog(
                tester.element(find.byType(ElevatedButton)), service),
            child: const Text('open'),
          ));
      await typeInto(tester, 'oldpass');
      // 依次点击第 2、3 个输入框后输入
      await tester.tap(find.byType(RawTextField).at(1));
      await tester.pump();
      await typeInto(tester, 'newpass1', tapField: false);
      await tester.tap(find.byType(RawTextField).at(2));
      await tester.pump();
      await typeInto(tester, 'newpass2', tapField: false);
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(find.text('两次输入的新密码不一致'), findsOneWidget);
      verifyNever(() => service.changePassword(any(), any()));
    });

    testWidgets('合法修改调用 changePassword', (tester) async {
      final service = MockSocketService();
      stubChangePw(service);
      state.setLoggedIn('alice', false);
      await openDialog(
          tester,
          ElevatedButton(
            onPressed: () => showChangePasswordDialog(
                tester.element(find.byType(ElevatedButton)), service),
            child: const Text('open'),
          ));
      await typeInto(tester, 'oldpass');
      await tester.tap(find.byType(RawTextField).at(1));
      await tester.pump();
      await typeInto(tester, 'newpass1', tapField: false);
      await tester.tap(find.byType(RawTextField).at(2));
      await tester.pump();
      await typeInto(tester, 'newpass1', tapField: false);
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      verify(() => service.changePassword('oldpass', 'newpass1')).called(1);
    });
  });

  group('群组信息对话框', () {
    testWidgets('成员列表渲染，首个标记创建者', (tester) async {
      state.setLoggedIn('alice', false);
      state.addGroup(Group(id: 1, name: '开发组'));
      state.updateGroupMembers(1, ['alice', 'bob', 'carol']);
      await openDialog(
          tester,
          ElevatedButton(
            onPressed: () => showGroupInfoDialog(
                tester.element(find.byType(ElevatedButton)),
                state.groups.first),
            child: const Text('open'),
          ));
      expect(find.text('alice'), findsOneWidget);
      expect(find.text('bob'), findsOneWidget);
      expect(find.text('carol'), findsOneWidget);
      expect(find.text('创建者'), findsOneWidget);
    });

    testWidgets('成员为空显示加载态', (tester) async {
      state.setLoggedIn('alice', false);
      state.addGroup(Group(id: 1, name: '开发组'));
      await openDialog(
          tester,
          ElevatedButton(
            onPressed: () => showGroupInfoDialog(
                tester.element(find.byType(ElevatedButton)),
                state.groups.first),
            child: const Text('open'),
          ),
          settle: false);
      expect(find.text('加载成员列表中…'), findsOneWidget);
    });

    testWidgets('空字符串成员显示 ? 头像（不崩溃）', (tester) async {
      state.setLoggedIn('alice', false);
      state.addGroup(Group(id: 1, name: 'g'));
      state.updateGroupMembers(1, ['']);
      await openDialog(
          tester,
          ElevatedButton(
            onPressed: () => showGroupInfoDialog(
                tester.element(find.byType(ElevatedButton)),
                state.groups.first),
            child: const Text('open'),
          ));
      expect(find.text('?'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
