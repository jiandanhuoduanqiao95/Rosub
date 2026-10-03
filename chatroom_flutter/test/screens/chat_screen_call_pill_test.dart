// ============================================================
// opt1 —— 通话悬浮条改造：拖动 / 两态切换 / 默认位置避让
// ============================================================
// 现象：最小化通话胶囊固定顶部居中（压住会话列表头部功能行），不可
// 拖动、不可收起。
// 修复契约：
//   1) 胶囊默认位置在屏幕底部（不与列表头部功能行重叠）；
//   2) 可拖动（pan 手势，clamp 在屏幕内）；
//   3) 两态：胶囊右端收缩钮 → 圆点态；点圆点重新展开；
//   4) 点击胶囊本体 restore() 回到通话界面（pop 职责仍在通话页）。
// 驱动方式：MockSocketService stub callService getter 返回真实
// CallService（mock 信令与引擎），pumpWidget 后手动触发
// socket.onCallPhaseChanged（Mock 不自动转发——与生产接线一致）。
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/call_engine.dart';
import 'package:chatroom_flutter/services/call_service.dart';
import 'package:chatroom_flutter/services/socket_service.dart';
import 'package:chatroom_flutter/services/state_manager.dart';
import 'package:chatroom_flutter/screens/chat_screen.dart';

class MockSocketService extends Mock implements SocketService {}

class MockSignaling extends Mock implements CallSignaling {}

class MockEngine extends Mock implements CallEngine {}

class _FakeListener extends Fake implements CallEngineListener {}

AppState get state => AppState.instance;

void main() {
  setUpAll(() {
    registerFallbackValue(_FakeListener());
    registerFallbackValue(<String, Object?>{});
  });

  setUp(() {
    state
      ..setLoggedOut()
      ..setConnectionStatus(ConnectionStatus.disconnected);
  });

  CallService buildCallService() {
    final signaling = MockSignaling();
    final engine = MockEngine();
    when(() => engine.setListener(any())).thenAnswer((_) {});
    when(() => signaling.sendCall(any(), any(), any(),
        callType: any(named: 'callType'),
        body: any(named: 'body'))).thenAnswer((_) async {});
    when(() => engine.open(video: any(named: 'video')))
        .thenAnswer((_) async {});
    when(() => engine.hasLocalMedia).thenReturn(true);
    when(() => engine.close()).thenAnswer((_) async {});
    when(() => engine.setMicMuted(any())).thenAnswer((_) async {});
    when(() => engine.setCameraEnabled(any())).thenAnswer((_) async {});
    when(() => engine.setSpeakerphoneOn(any())).thenAnswer((_) async {});
    when(() => engine.createOffer())
        .thenAnswer((_) async => {'sdp': 'o', 'type': 'offer'});
    when(() => engine.createAnswer())
        .thenAnswer((_) async => {'sdp': 'a', 'type': 'answer'});
    when(() => engine.setRemoteOffer(any())).thenAnswer((_) async {});
    when(() => engine.setRemoteAnswer(any())).thenAnswer((_) async {});
    when(() => engine.addRemoteCandidate(any())).thenAnswer((_) async {});
    when(() => engine.attachRenderers(
            remote: any(named: 'remote'), local: any(named: 'local')))
        .thenAnswer((_) async {});
    when(() => engine.videoInputCount()).thenAnswer((_) async => 0);
    when(() => engine.switchCamera()).thenAnswer((_) async {});
    return CallService(signaling: signaling, engine: engine);
  }

  // 进入"最小化通话中"状态并返回 (触发回调, socket, svc)
  Future<(void Function(), MockSocketService, CallService)> pumpMinimizedCall(
      WidgetTester tester) async {
    final socket = MockSocketService();
    final svc = buildCallService();
    when(() => socket.callService).thenReturn(svc);
    // Mock 不自动转发通话状态回调——捕获 ChatScreen 注册的回调供手动触发
    void Function()? onCallChanged;
    when(() => socket.onCallPhaseChanged = any())
        .thenAnswer((inv) => onCallChanged =
            inv.positionalArguments[0] as void Function()?);
    state.setLoggedIn('alice', false);
    state.setFriends(['bob']);

    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(socketService: socket),
      routes: {'/login': (_) => const Scaffold(body: Text('LOGIN'))},
    ));
    await tester.pump();

    await svc.startCall('bob', CallType.audio);
    expect(svc.phase, CallPhase.calling);
    svc.minimize();
    onCallChanged!();
    await tester.pump();
    return (onCallChanged!, socket, svc);
  }

  /// 测试收尾：取消通话推进 fake 时钟，清掉呼叫超时/endedTimer
  /// （pending timer 会让 testWidgets 红）
  Future<void> endCall(WidgetTester tester, CallService svc) async {
    svc.cancelOutgoing();
    await tester.pump(const Duration(seconds: 3));
  }

  group('opt1 —— 悬浮条默认位置', () {
    testWidgets('胶囊渲染在屏幕底部，不与列表头部功能行重叠', (tester) async {
      final (_, _, svc) = await pumpMinimizedCall(tester);

      final pill = find.textContaining('bob 正在呼叫');
      expect(pill, findsOneWidget);
      final rect = tester.getRect(pill);
      // 默认视口 800x600：头部功能行高度 < 100，胶囊 top 应远在其下
      expect(rect.top, greaterThan(200),
          reason: '胶囊默认位于屏幕底部上方，不遮列表头部功能行');
      expect(rect.bottom, lessThan(600), reason: '胶囊完整在屏幕内');
      // 左下角（left=16 起点）
      expect(rect.left, lessThan(100));
      await endCall(tester, svc);
    });

    testWidgets('最小化后不残留顶部居中旧位（top 不再是 8）', (tester) async {
      final (_, _, svc) = await pumpMinimizedCall(tester);
      final rect = tester.getRect(find.byIcon(Icons.phone_in_talk_rounded));
      expect(rect.top, greaterThan(8));
      await endCall(tester, svc);
    });
  });

  group('opt1 —— 悬浮条拖动', () {
    testWidgets('拖动后位置跟随并保持屏幕内', (tester) async {
      final (_, _, svc) = await pumpMinimizedCall(tester);

      await tester.drag(find.textContaining('bob 正在呼叫'),
          const Offset(300, -200));
      await tester.pump();

      final rect = tester.getRect(find.textContaining('bob 正在呼叫'));
      expect(rect.left, greaterThan(100), reason: '向右拖动 300 后 left 变大');
      expect(rect.top, greaterThan(8), reason: '向上拖动后仍在屏幕内（clamp）');
      expect(rect.top, lessThan(400));
      await endCall(tester, svc);
    });
  });

  group('opt1 —— 两态切换', () {
    testWidgets('收缩钮 → 圆点态；点圆点 → 胶囊回归', (tester) async {
      final (_, _, svc) = await pumpMinimizedCall(tester);
      expect(find.textContaining('bob 正在呼叫'), findsOneWidget);

      await tester.tap(find.byKey(const Key('call_pill_collapse')));
      await tester.pump();

      expect(find.byKey(const Key('call_pill_dot')), findsOneWidget);
      expect(find.textContaining('bob 正在呼叫'), findsNothing,
          reason: '收起后胶囊文本消失');

      await tester.tap(find.byKey(const Key('call_pill_dot')));
      await tester.pump();

      expect(find.byKey(const Key('call_pill_dot')), findsNothing);
      expect(find.textContaining('bob 正在呼叫'), findsOneWidget,
          reason: '点击圆点重新展开胶囊');
      await endCall(tester, svc);
    });

    testWidgets('圆点态拖动不触发展开', (tester) async {
      final (_, _, svc) = await pumpMinimizedCall(tester);
      await tester.tap(find.byKey(const Key('call_pill_collapse')));
      await tester.pump();

      await tester.drag(find.byKey(const Key('call_pill_dot')),
          const Offset(-200, 100));
      await tester.pump();

      expect(find.byKey(const Key('call_pill_dot')), findsOneWidget,
          reason: '拖动是 pan 手势，不触发圆点点击展开');
      final rect = tester.getRect(find.byKey(const Key('call_pill_dot')));
      expect(rect.left, lessThan(16), reason: '向左拖动 200 后 clamp 在屏幕内');
      await endCall(tester, svc);
    });
  });

  group('opt1 —— 点击胶囊恢复通话', () {
    testWidgets('点击胶囊本体调用 restore 并重新打开通话界面', (tester) async {
      final (notifyCall, socket, svc) = await pumpMinimizedCall(tester);

      await tester.tap(find.textContaining('bob 正在呼叫'));
      notifyCall();
      await tester.pump();

      expect(svc.minimized, isFalse);
      expect(find.textContaining('bob 正在呼叫'), findsNothing,
          reason: '恢复后悬浮条消失，通话界面重新打开');
      await endCall(tester, svc);
    });
  });
}
