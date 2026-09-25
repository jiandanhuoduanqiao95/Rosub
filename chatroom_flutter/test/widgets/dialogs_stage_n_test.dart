// ============================================================
// dialogs.dart 阶段 N —— N6 设备管理 / N7 审计日志 面板对话框（TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 N：
//   - N6（P2-6）showDeviceManagementDialog：当前账号全部在线会话
//     （device_id/当前标记/最后活跃），可远程下线（复用 _kick_old_session
//     逻辑，注意"同类别互踢、异类别并存"语义）
//   - N7（P2-7）showAuditLogDialog：敏感操作审计记录
//     （操作者/操作/对象/时间），管理面板可查
//
// 对话框接受 SocketService（网络由上层注入），打开时拉取数据、
// 渲染 AppState 状态。实现前：本文件引用尚未实现的对话框函数，
// 编译失败或用例红，属 TDD 红。实现后：全部转绿。
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/socket_service.dart';
import 'package:chatroom_flutter/services/state_manager.dart';
import 'package:chatroom_flutter/widgets/dialogs.dart';

class MockSocketService extends Mock implements SocketService {}

AppState get state => AppState.instance;

void resetState() {
  state
    ..setLoggedOut()
    ..setConnectionStatus(ConnectionStatus.disconnected);
}

SessionInfo session(String deviceId, {bool isCurrent = false}) {
  return SessionInfo(
    deviceId: deviceId,
    lastActive: DateTime(2026, 8, 26, 10, 30),
    isCurrent: isCurrent,
  );
}

AuditLogEntry audit(String operator, String action, String target) {
  return AuditLogEntry.fromJson({
    'id': 1,
    'operator': operator,
    'action': action,
    'target': target,
    'detail': '',
    'timestamp': '2026-08-26 10:00:00',
  });
}

void main() {
  setUp(resetState);

  group('N6 —— 设备管理对话框（showDeviceManagementDialog）', () {
    testWidgets('打开时调用 fetchSessions 拉取会话列表', (tester) async {
      final service = MockSocketService();
      when(() => service.fetchSessions()).thenAnswer((_) async {});
      state.setLoggedIn('alice', false);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showDeviceManagementDialog(ctx, service),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      verify(() => service.fetchSessions()).called(1);
    });

    testWidgets('渲染会话列表：设备 id + 当前标记 + 最后活跃时间', (tester) async {
      final service = MockSocketService();
      when(() => service.fetchSessions()).thenAnswer((_) async {});
      state.setLoggedIn('alice', false);
      state.setSessions([
        session('linux', isCurrent: true),
        session('android'),
      ]);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showDeviceManagementDialog(ctx, service),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('linux'), findsOneWidget);
      expect(find.text('android'), findsOneWidget);
      expect(find.textContaining('当前'), findsOneWidget, reason: '当前会话有标记');
      expect(find.textContaining('10:30'), findsWidgets, reason: '显示最后活跃时间');
    });

    testWidgets('当前设备不显示"下线"按钮', (tester) async {
      final service = MockSocketService();
      when(() => service.fetchSessions()).thenAnswer((_) async {});
      state.setLoggedIn('alice', false);
      state.setSessions([
        session('linux', isCurrent: true),
        session('android'),
      ]);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showDeviceManagementDialog(ctx, service),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('下线'), findsOneWidget, reason: '仅 android 一个下线按钮');
    });

    testWidgets('点击"下线" → kickSession(deviceId) 并刷新列表', (tester) async {
      final service = MockSocketService();
      when(() => service.fetchSessions()).thenAnswer((_) async {});
      when(() => service.kickSession(any())).thenAnswer((_) async {});
      state.setLoggedIn('alice', false);
      state.setSessions([
        session('linux', isCurrent: true),
        session('android'),
      ]);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showDeviceManagementDialog(ctx, service),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下线'));
      await tester.pumpAndSettle();

      verify(() => service.kickSession('android')).called(1);
      verify(() => service.fetchSessions()).called(2);
    });

    testWidgets('无其他设备时显示友好空态', (tester) async {
      final service = MockSocketService();
      when(() => service.fetchSessions()).thenAnswer((_) async {});
      state.setLoggedIn('alice', false);
      state.setSessions([session('linux', isCurrent: true)]);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showDeviceManagementDialog(ctx, service),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('暂无其他设备'), findsOneWidget);
    });
  });

  group('N7 —— 审计日志对话框（showAuditLogDialog）', () {
    testWidgets('打开时调用 fetchAuditLogs 拉取审计记录', (tester) async {
      final service = MockSocketService();
      when(() => service.fetchAuditLogs()).thenAnswer((_) async {});
      state.setLoggedIn('admin', true);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showAuditLogDialog(ctx, service),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      verify(() => service.fetchAuditLogs()).called(1);
    });

    testWidgets('渲染审计条目：操作者/操作/对象/时间', (tester) async {
      final service = MockSocketService();
      when(() => service.fetchAuditLogs()).thenAnswer((_) async {});
      state.setLoggedIn('admin', true);
      state.setAuditLogs([
        audit('admin', 'delete_user', 'bob'),
        audit('alice', 'kick_member', 'carol'),
      ]);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showAuditLogDialog(ctx, service),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('admin'), findsWidgets);
      expect(find.text('delete_user'), findsOneWidget);
      expect(find.text('bob'), findsOneWidget);
      expect(find.text('kick_member'), findsOneWidget);
      expect(find.text('carol'), findsOneWidget);
      expect(find.textContaining('2026-08-26'), findsWidgets, reason: '显示操作时间');
    });

    testWidgets('无审计记录时显示空态', (tester) async {
      final service = MockSocketService();
      when(() => service.fetchAuditLogs()).thenAnswer((_) async {});
      state.setLoggedIn('admin', true);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showAuditLogDialog(ctx, service),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('暂无审计记录'), findsOneWidget);
    });
  });
}
