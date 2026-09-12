// ============================================================
// chat_screen.dart 阶段 Q1 —— 真机手动测试反馈修复契约
// ============================================================
// 覆盖 Q1 Android 真机八项反馈中的两项（ChatScreen 侧）：
//
// 反馈 #3（顶栏遮挡聊天区）：compact 聊天态 AppBar 最简化——
//   · 返回控件 + 居中会话名（displayNameForChat）；
//   · 动作仅：搜索消息 / 导出聊天记录（系统会话无）+ 文件管理
//     （Q1 反馈 #3 增设：聊天内外均可管理文件）；
//   · 设置/文件/设备/资料/密码/退出工具栏收进会话列表态；
//   · AppBar 搜索入口受控展开 ChatView 搜索输入行；
//   · 宽屏双栏态工具栏保持（桌面零回归）。
//
// 反馈 #5（沉浸式观看）：视频查看器点击画面切换顶栏（关闭+文件名）
// 显隐；再点恢复。
// ============================================================

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/screens/chat_screen.dart';
import 'package:chatroom_flutter/services/socket_service.dart';
import 'package:chatroom_flutter/services/state_manager.dart';

class MockSocketService extends Mock implements SocketService {}

AppState get state => AppState.instance;

void resetState() {
  state
    ..setLoggedOut()
    ..setConnectionStatus(ConnectionStatus.disconnected);
}

void stubCommon(MockSocketService socket) {
  when(() => socket.saveConversationDraft(any(), any()))
      .thenAnswer((_) async {});
  when(() => socket.fetchHistory(
        to: any(named: 'to'),
        groupId: any(named: 'groupId'),
        beforeMessageId: any(named: 'beforeMessageId'),
        limit: any(named: 'limit'),
      )).thenAnswer((_) async {});
}

Future<void> pumpChat(
  WidgetTester tester,
  MockSocketService socket, {
  Size size = const Size(599, 800),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    home: ChatScreen(socketService: socket),
    routes: {'/login': (_) => const Scaffold(body: Text('LOGIN'))},
  ));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(resetState);
  tearDown(resetState);

  group('Q1 反馈 #3 —— compact 聊天态 AppBar 最简化', () {
    testWidgets('选中会话后：居中会话名 + 搜索/导出/文件管理，无工具栏图标', (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);

      await pumpChat(tester, socket);
      await tester.tap(find.text('bob'));
      await tester.pumpAndSettle();

      expect(find.text('bob'), findsOneWidget,
          reason: 'AppBar 只显示会话名（与 bob 的聊天/工具栏不再出现）');
      expect(find.byTooltip('搜索消息'), findsOneWidget);
      expect(find.byTooltip('导出聊天记录'), findsOneWidget);
      expect(find.byTooltip('文件管理'), findsOneWidget,
          reason: 'Q1 四轮问题4：固定"文件管理"按键恢复');
      expect(find.byTooltip('待处理文件请求'), findsNothing,
          reason: '无待处理请求时不占 AppBar 位');
      expect(find.byTooltip('退出'), findsNothing, reason: '工具栏收进会话列表态');
      expect(find.byTooltip('设备管理'), findsNothing);
      expect(find.byTooltip('修改密码'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('AppBar 搜索入口受控展开/收起 ChatView 搜索行', (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);

      await pumpChat(tester, socket);
      await tester.tap(find.text('bob'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('search_field')), findsNothing);
      await tester.tap(find.byTooltip('搜索消息'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('search_field')), findsOneWidget,
          reason: '搜索行受控展开');

      await tester.tap(find.byTooltip('搜索消息'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('search_field')), findsNothing,
          reason: '再次点击收起');
    });

    testWidgets("系统会话（'服务器'）：仅文件管理入口（无搜索/导出）", (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.addMessage(
        '服务器',
        ChatMessage(
          sender: '系统',
          content: '系统公告测试',
          messageId: 'sys-q1',
          type: 'system',
        ),
      );

      await pumpChat(tester, socket);
      await tester.tap(find.text('系统消息'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('文件管理'), findsOneWidget);
      expect(find.byTooltip('搜索消息'), findsNothing, reason: '系统会话只读无搜索（H4 语义）');
      expect(find.byTooltip('导出聊天记录'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('会话列表态：工具栏完整保留（设置/文件管理/退出等）', (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);

      await pumpChat(tester, socket);

      expect(find.byTooltip('文件管理'), findsOneWidget);
      expect(find.byTooltip('设备管理'), findsOneWidget);
      expect(find.byTooltip('退出'), findsOneWidget);
    });

    testWidgets('Q1 八轮问题1：进入聊天后返回列表态，AppBar 不残留会话名',
        (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);

      await pumpChat(tester, socket);
      await tester.tap(find.text('bob'));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byType(AppBar), matching: find.text('bob')),
          findsOneWidget,
          reason: '聊天态 AppBar 显示会话名');

      // 返回主界面（列表态）
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();

      expect(
          find.descendant(
              of: find.byType(AppBar), matching: find.text('bob')),
          findsNothing,
          reason: 'currentChat 常驻（selectChat 语义）但列表态 AppBar '
              '不得残留对方名称（六轮宽屏标题条件的回归）');
      expect(find.byTooltip('退出'), findsOneWidget,
          reason: '列表态工具栏正常');
    });

    testWidgets('Q1 六轮问题2：Android 宽屏选中会话 AppBar 恒显示会话名', (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);

      await pumpChat(tester, socket, size: const Size(800, 600));
      await tester.tap(find.text('bob'));
      await tester.pumpAndSettle();

      expect(find.text('bob'), findsWidgets,
          reason: '宽屏（平板/横屏）选中会话时 AppBar 不再为空'
              '（此前 hideListTitle 使宽屏选中会话时标题消失）');
    });

    testWidgets('宽屏（≥600）选中会话：工具栏保留（桌面零回归）', (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);

      await pumpChat(tester, socket, size: const Size(800, 600));
      await tester.tap(find.text('bob'));
      await tester.pumpAndSettle();

      expect(find.text('与 bob 的聊天'), findsOneWidget,
          reason: '宽屏保留 ChatView 标题栏');
      expect(find.byTooltip('退出'), findsOneWidget, reason: '宽屏 AppBar 工具栏不变');
      expect(find.byTooltip('搜索消息'), findsOneWidget,
          reason: '搜索入口仍在 ChatView 头部');
    });
  });

  group('Q1 反馈 #5 —— 视频查看器沉浸式（点击画面切换顶栏）', () {
    testWidgets('点击画面隐藏顶栏，再点恢复', (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.addMessage(
        'bob',
        ChatMessage(
          sender: 'alice',
          content: '[文件] clip.mp4',
          messageId: 'v1',
          status: 'sent',
          type: 'file',
          filename: 'clip.mp4',
        ),
      );

      await pumpChat(tester, socket);
      await tester.tap(find.text('bob'));
      await tester.pumpAndSettle();
      // 视频气泡（文件卡片显示文件名）
      final bubble = find.textContaining('clip.mp4');
      expect(bubble, findsOneWidget);
      await tester.tap(bubble);
      await tester.pumpAndSettle();

      expect(find.byTooltip('关闭'), findsOneWidget, reason: '顶栏初始可见');
      expect(find.textContaining('clip.mp4'), findsWidgets);

      await tester.tap(find.byIcon(Icons.play_circle_rounded),
          warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byTooltip('关闭'), findsNothing, reason: '点击画面 → 顶栏隐藏（沉浸式）');

      await tester.tap(find.textContaining('clip.mp4').last,
          warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byTooltip('关闭'), findsOneWidget, reason: '再次点击 → 顶栏恢复');
    });
  });

  // ============================================================
  // Q1 真机反馈二轮 —— 文件请求无感知 / Android 返回链 / 保活接线
  // ============================================================
  group('Q1 二轮 —— 文件请求无感知（compact 聊天态徽标 + 提示）', () {
    testWidgets('聊天中收到文件请求：徽标出现，点击弹"文件请求"对话框', (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);

      await pumpChat(tester, socket);
      await tester.tap(find.text('bob'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('待处理文件请求'), findsNothing,
          reason: '无待处理请求时不占 AppBar 位');

      state.addFileRequest(FileRequest(
        messageId: 'm1',
        sender: 'bob',
        filename: 'report.pdf',
        filesize: 1024,
      ));
      await tester.pumpAndSettle();
      expect(find.byTooltip('待处理文件请求'), findsOneWidget,
          reason: 'Q1 二轮：聊天中可感知（徽标入口）');

      await tester.tap(find.byTooltip('待处理文件请求'));
      await tester.pumpAndSettle();
      expect(find.text('文件请求'), findsOneWidget);
      expect(find.textContaining('report.pdf'), findsOneWidget);
    });
  });

  group('Q1 二轮 —— Android 返回链与保活接线', () {
    const channel = MethodChannel('chatroom/platform');
    final calls = <MethodCall>[];

    /// §21.1 规约：override 必须在 testWidgets body 内恢复（foundation
    /// invariant 检查先于 group tearDown）——统一经本 wrapper 驱动
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

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    testWidgetsOnPlatform(
        '保活生命周期门控：前台不启动，退后台启动，回前台/离开页面停止'
        '（Q1 五轮问题1 重大回归修复：普通服务被深度休眠冻结，后台收不到消息）',
        TargetPlatform.android, (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);

      await pumpChat(tester, socket);
      expect(calls.where((c) => c.method == 'startKeepAlive'), isEmpty,
          reason: '前台使用期间不启动 FGS（零通知）');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(calls.map((c) => c.method), contains('startKeepAlive'),
          reason: '退到后台 → 启动 FGS 维持进程与消息连接（通知为系统强制项）');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(calls.map((c) => c.method), contains('stopKeepAlive'),
          reason: '回前台 → 立即停止 FGS（通知消失）');

      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'stopKeepAlive').length, 2,
          reason: 'ChatScreen dispose 再次兜底停止');
    });

    testWidgetsOnPlatform(
        'Android 会话列表态：AppBar 无"聊天室 - 用户名"标题（Q1 四轮问题3）',
        TargetPlatform.android, (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);

      await pumpChat(tester, socket);
      expect(find.textContaining('聊天室'), findsNothing,
          reason: '列表态标题字样移除（工具栏图标保留）');
      expect(find.byTooltip('退出'), findsOneWidget);
    });

    testWidgetsOnPlatform('compact 聊天区按返回 → 回会话列表（不退出）', TargetPlatform.android,
        (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);

      await pumpChat(tester, socket);
      await tester.tap(find.text('bob'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('退出'), findsNothing, reason: '聊天态工具栏收起');

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byTooltip('退出'), findsOneWidget,
          reason: 'Q1 二轮问题5b：返回键回会话列表（工具栏态）而非退出应用');
      expect(calls.where((c) => c.method == 'moveToBackground'), isEmpty);
    });

    testWidgetsOnPlatform(
        '会话列表再按返回 → 转后台（moveTaskToBack，不杀进程）', TargetPlatform.android,
        (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);

      await pumpChat(tester, socket);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'moveToBackground').length, 1,
          reason: 'Q1 二轮问题5b：根路由返回 = 转后台（保会话，不重新登录）');
    });

    testWidgetsOnPlatform(
        'Linux 平台：无 PopScope 拦截与保活通道调用（桌面零回归）', TargetPlatform.linux,
        (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);

      await pumpChat(tester, socket);
      expect(calls, isEmpty, reason: '保活/权限均为 Android 专属（host 语义）');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'moveToBackground'), isEmpty);
    });
  });
  group('Q1 六轮问题1 —— 接收进度条管线（Android 平台锁定）', () {
    /// §21.1 规约：override 在 testWidgets body 内设置并恢复
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

    testWidgetsOnPlatform('接收中的文件消息：气泡内显示进度条与百分比', TargetPlatform.android,
        (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.addMessage(
        'bob',
        ChatMessage(
          sender: 'bob',
          content: '[收到文件] big.bin',
          messageId: 'm1',
          type: 'file',
          filename: 'big.bin',
          filesize: 1000,
          status: 'sent',
        ),
      );
      // 模拟服务端直传转发中（_listenLoop file 分支注册的传输进度）
      state.updateTransfer('m1', 400, 1000);

      await pumpChat(tester, socket);
      await tester.tap(find.text('bob'));
      await tester.pumpAndSettle();

      // Q1 七轮：全局传输指示条 + 气泡内进度条同时存在
      expect(find.byType(LinearProgressIndicator), findsNWidgets(2),
          reason: '接收方气泡内进度条 + 全局传输指示条（AppBar 下方，'
              '任何界面可见）；与服务端 send_message_header_only 携带 '
              'message_id 的头部契约对齐：气泡 id == 传输 id');
      expect(find.text('接收 big.bin'), findsOneWidget,
          reason: '全局指示条：方向 + 文件名');
      expect(find.text('40%'), findsNWidgets(2));
    });

    testWidgetsOnPlatform('传输发生在别的会话：全局指示条仍可见，点击跳转',
        TargetPlatform.android, (tester) async {
      final socket = MockSocketService();
      stubCommon(socket);
      state.setLoggedIn('alice', false);
      state.setFriends(['bob', 'carol']);
      state.addMessage(
        'carol',
        ChatMessage(
          sender: 'carol',
          content: '[收到文件] movie.mp4',
          messageId: 'm2',
          type: 'file',
          filename: 'movie.mp4',
          filesize: 2000,
          status: 'sent',
        ),
      );
      state.updateTransfer('m2', 500, 2000);

      await pumpChat(tester, socket);
      // 停留在 bob 的聊天（未进入 carol 的会话）
      await tester.tap(find.text('bob'));
      await tester.pumpAndSettle();

      expect(find.text('接收 movie.mp4'), findsOneWidget,
          reason: '任何界面恒可见（问题1：不在传输会话内也要能判断）');
      expect(find.text('25%'), findsOneWidget);

      await tester.tap(find.text('接收 movie.mp4'));
      await tester.pumpAndSettle();
      expect(find.text('carol'), findsWidgets,
          reason: '点击指示条跳转到传输所属会话');
    });
  });

}
