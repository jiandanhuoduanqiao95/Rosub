// ============================================================
// opt8 功能三/二 —— ChatScreen 生命周期接线（来电通知 / 悬浮球 /
// 来电意图消费 / 桌面唤起）
// ============================================================
// 驱动方式（chat_screen_call_pill_test 惯例）：MockSocketService stub
// callService getter 返回真实 CallService（mock 信令/引擎），pumpWidget
// 后手动触发 socket.onCallPhaseChanged（Mock 不自动转发）；MethodChannel
// 'chatroom/platform' 全量 mock 并记录调用。生命周期经
// tester.binding.handleAppLifecycleStateChanged 驱动，测试结束恢复
// resumed。平台模拟 debugDefaultTargetPlatformOverride 在 body 内设置
// 并恢复（§21.1 规约）。
// ============================================================

import 'dart:convert';


import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/platform/capabilities.dart';
import 'package:chatroom_flutter/screens/chat_screen.dart';
import 'package:chatroom_flutter/services/call_engine.dart';
import 'package:chatroom_flutter/services/call_service.dart';
import 'package:chatroom_flutter/services/socket_service.dart';
import 'package:chatroom_flutter/services/state_manager.dart';

class MockSocketService extends Mock implements SocketService {}

class MockSignaling extends Mock implements CallSignaling {}

class MockEngine extends Mock implements CallEngine {}

class _FakeListener extends Fake implements CallEngineListener {}

class _FakeWindow implements WindowActivationCapability {
  int bringToFrontCalls = 0;

  @override
  bool get isSupported => true;

  @override
  Future<void> bringToFront() async {
    bringToFrontCalls++;
  }
}

const MethodChannel _channel = MethodChannel('chatroom/platform');

AppState get state => AppState.instance;

Uint8List _body(Map<String, dynamic> json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(_FakeListener());
    registerFallbackValue(<String, Object?>{});
  });

  final calls = <MethodCall>[];
  final callSends = <String>[];
  Map<String, Object?>? Function(String method)? respond;

  Future<void> installChannelMock() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      final custom = respond?.call(call.method);
      if (custom != null) return custom;
      switch (call.method) {
        case 'setupMessageChannel':
        case 'setupCallChannel':
        case 'requestNotificationPermission':
        case 'startKeepAlive':
        case 'stopKeepAlive':
        case 'startCallForeground':
        case 'stopCallForeground':
        case 'showIncomingCallNotification':
        case 'cancelIncomingCallNotification':
        case 'clearCallLockFlags':
        case 'showCallBubble':
        case 'hideCallBubble':
          return true;
        case 'isIgnoringBatteryOptimizations':
          return true;
        case 'getLastCrashLog':
          return null;
        case 'consumeCallIntent':
          return {'open': false, 'action': null};
        case 'consumeOpenCallIntent':
          return false;
        case 'requestCallPermissions':
          return true;
      }
      return null;
    });
  }

  void uninstallChannelMock() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }

  List<MethodCall> callsOf(String method) =>
      calls.where((c) => c.method == method).toList();

  void resetLifecycle() {
    // 测试结束恢复前台（任务书 §10.4：tearDown 恢复 resumed）
    WidgetsBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }

  setUp(() {
    calls.clear();
    callSends.clear();
    respond = null;
    debugDefaultTargetPlatformOverride = null;
    PlatformCapabilities.resetForTest();
    state
      ..setLoggedOut()
      ..setConnectionStatus(ConnectionStatus.disconnected);
  });

  tearDown(() {
    uninstallChannelMock();
    debugDefaultTargetPlatformOverride = null;
    PlatformCapabilities.resetForTest();
  });

  /// 构建 MockSocketService + 真实 CallService（mock 信令/引擎）
  Future<(MockSocketService, CallService, void Function())> pumpChat(
      WidgetTester tester) async {
    final socket = MockSocketService();
    final signaling = MockSignaling();
    final engine = MockEngine();
    when(() => engine.setListener(any())).thenAnswer((_) {});
    when(() => signaling.sendCall(any(), any(), any(),
        callType: any(named: 'callType'),
        body: any(named: 'body'))).thenAnswer((inv) async {
      callSends.add(inv.positionalArguments[0] as String);
    });
    when(() => signaling.sendGroupCall(any(), any(), any(),
        callType: any(named: 'callType'),
        mic: any(named: 'mic'),
        cam: any(named: 'cam'))).thenAnswer((_) async {});
    when(() => engine.open(video: any(named: 'video')))
        .thenAnswer((_) async {});
    when(() => engine.ensureMedia(video: any(named: 'video')))
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
    when(() => engine.createPeerSession(any()))
        .thenThrow(StateError('group sessions not used in this test'));
    when(() => engine.videoInputCount()).thenAnswer((_) async => 0);
    when(() => engine.switchCamera()).thenAnswer((_) async {});

    final svc = CallService(
        signaling: signaling, engine: engine, selfUsername: () => 'alice');
    when(() => socket.callService).thenReturn(svc);

    void Function()? onCallChanged;
    when(() => socket.onCallPhaseChanged = any())
        .thenAnswer((inv) => onCallChanged =
            inv.positionalArguments[0] as void Function()?);

    state.setLoggedIn('alice', false);
    state.setFriends(['bob']);

    debugDefaultTargetPlatformOverride ??= TargetPlatform.android;
    await tester.pumpWidget(MaterialApp(home: ChatScreen(socketService: socket)));
    await tester.pump();
    await tester.pump();
    return (socket, svc, () => onCallChanged?.call());
  }

  /// 测试收尾：结束通话推进 fake 时钟 + 恢复前台生命周期 + 卸载组件
  /// （foundation invariant 在 tearDown 前检查——平台 override 必须在
  /// test body 内恢复，勿只依赖 tearDown）
  Future<void> teardown(WidgetTester tester, CallService svc) async {
    if (svc.isInLiveCall) {
      if (svc.phase == CallPhase.ringing) {
        svc.rejectIncoming();
      } else if (svc.phase == CallPhase.calling) {
        svc.cancelOutgoing();
      } else {
        svc.hangup();
      }
    }
    resetLifecycle();
    debugDefaultTargetPlatformOverride = null;
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 10));
  }

  group('opt8 F3 —— 来电通知（振铃 + 后台）', () {
    testWidgets('paused + 1:1 语音振铃 → 通知（标题=对方名，正文=邀请你语音通话）',
        (tester) async {
      await installChannelMock();
      final (_, svc, notify) = await pumpChat(tester);
      svc.handleSignal('call_invite',
          {'from': 'bob', 'call_id': 'r1', 'call_type': 'audio'}, Uint8List(0));
      notify();
      await tester.pump();
      expect(callsOf('showIncomingCallNotification'), isEmpty,
          reason: '前台振铃不发高优先级来电通知');

      WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      await tester.pump();

      final shows = callsOf('showIncomingCallNotification');
      expect(shows, hasLength(1), reason: '退后台时正在振铃 → 补发来电通知');
      expect(shows.single.arguments, {'title': 'bob', 'body': '邀请你语音通话'});
      await teardown(tester, svc);
    });

    testWidgets('paused + 群视频振铃 → 标题=群名（不显示邀请人）', (tester) async {
      await installChannelMock();
      final (_, svc, notify) = await pumpChat(tester);
      svc.handleSignal(
          'group_call_invite',
          {
            'from': 'bob',
            'call_id': 'room-1',
            'group_id': 7,
            'call_type': 'video',
            'group_name': '研发群',
          },
          Uint8List(0));
      notify();
      await tester.pump();

      WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      await tester.pump();

      final shows = callsOf('showIncomingCallNotification');
      expect(shows.single.arguments,
          {'title': '研发群', 'body': '邀请你加入群视频通话'});
      await teardown(tester, svc);
    });

    testWidgets('resumed → 撤除来电通知；振铃中再次退后台 → 再次补发',
        (tester) async {
      await installChannelMock();
      final (_, svc, notify) = await pumpChat(tester);
      svc.handleSignal('call_invite',
          {'from': 'bob', 'call_id': 'r1', 'call_type': 'audio'}, Uint8List(0));
      notify();
      await tester.pump();

      WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(callsOf('showIncomingCallNotification'), hasLength(1));

      // 振铃中回前台 → 撤除通知
      WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(callsOf('cancelIncomingCallNotification'), isNotEmpty);

      // 重新退后台（仍在振铃）→ 补发第二条（复审修订：本用例只断言
      // 振铃路径；"active 后台不发通知"由下方独立用例真实驱动 active 锁定）
      WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      final showsBefore = callsOf('showIncomingCallNotification').length;
      expect(showsBefore, 2);
      await teardown(tester, svc);
    });

    testWidgets('paused + active（非振铃）→ 不发通知（悬浮球接管，见 F2）',
        (tester) async {
      await installChannelMock();
      final (_, svc, notify) = await pumpChat(tester);
      await svc.startCall('bob', CallType.audio);
      svc.handleSignal(
          'call_accept', {'from': 'bob', 'call_id': svc.callId}, Uint8List(0));
      await tester.pump();
      svc.handleSignal('call_answer', {'from': 'bob', 'call_id': svc.callId},
          _body({'sdp': 'a', 'type': 'answer'}));
      notify();
      await tester.pump();
      expect(svc.phase, CallPhase.active);

      WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(callsOf('showIncomingCallNotification'), isEmpty,
          reason: 'active 不是来电，不发高优先级通知');
      await teardown(tester, svc);
    });
  });

  group('opt8 F3 —— 来电意图消费（接听/拒绝 action）', () {
    testWidgets('decline action → 拒绝来电（ended + call_reject 信令 + 撤通知）',
        (tester) async {
      await installChannelMock();
      final (_, svc, notify) = await pumpChat(tester);
      svc.handleSignal('call_invite',
          {'from': 'bob', 'call_id': 'r1', 'call_type': 'audio'}, Uint8List(0));
      notify();
      await tester.pump();
      expect(svc.phase, CallPhase.ringing);

      respond = (method) =>
          method == 'consumeCallIntent' ? {'open': true, 'action': 'decline'} : null;
      WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();

      expect(svc.phase, CallPhase.ended, reason: '拒绝后进入 ended 展示期');
      expect(callSends, contains('call_reject'),
          reason: '拒绝发 call_reject 信令（主叫即刻知晓）');
      expect(callsOf('cancelIncomingCallNotification'), isNotEmpty);
      await teardown(tester, svc);
    });

    testWidgets('accept action + 权限授予 → 接通中（connecting + call_accept）',
        (tester) async {
      await installChannelMock();
      final (_, svc, notify) = await pumpChat(tester);
      svc.handleSignal('call_invite',
          {'from': 'bob', 'call_id': 'r2', 'call_type': 'audio'}, Uint8List(0));
      notify();
      await tester.pump();

      respond = (method) =>
          method == 'consumeCallIntent' ? {'open': true, 'action': 'accept'} : null;
      WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();

      expect(svc.phase, CallPhase.connecting, reason: '接听后进入接通中');
      expect(callsOf('requestCallPermissions'), hasLength(1),
          reason: '接听 action 先请求运行时权限');
      await teardown(tester, svc);
    });

    testWidgets('accept action + 权限拒绝 → 自动拒绝来电', (tester) async {
      await installChannelMock();
      final (_, svc, notify) = await pumpChat(tester);
      svc.handleSignal('call_invite',
          {'from': 'bob', 'call_id': 'r3', 'call_type': 'audio'}, Uint8List(0));
      notify();
      await tester.pump();

      respond = (method) {
        if (method == 'consumeCallIntent') {
          return {'open': true, 'action': 'accept'};
        }
        if (method == 'requestCallPermissions') {
          return <String, Object?>{'granted': false};
        }
        return null;
      };
      // requestCallPermissions 的 mock 返回布尔而非 map——单独覆写通道
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        if (call.method == 'consumeCallIntent') {
          return {'open': true, 'action': 'accept'};
        }
        if (call.method == 'requestCallPermissions') {
          return false;
        }
        return true;
      });
      WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();

      expect(svc.phase, CallPhase.ended, reason: '权限拒绝自动 reject');
      await teardown(tester, svc);
    });

    testWidgets('非振铃阶段到达的 accept action → 忽略（不改状态）',
        (tester) async {
      await installChannelMock();
      final (_, svc, notify) = await pumpChat(tester);
      await svc.startCall('bob', CallType.audio);
      svc.handleSignal(
          'call_accept', {'from': 'bob', 'call_id': svc.callId}, Uint8List(0));
      await tester.pump();
      svc.handleSignal('call_answer', {'from': 'bob', 'call_id': svc.callId},
          _body({'sdp': 'a', 'type': 'answer'}));
      notify();
      await tester.pump();
      expect(svc.phase, CallPhase.active);

      respond = (method) =>
          method == 'consumeCallIntent' ? {'open': true, 'action': 'accept'} : null;
      WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();

      expect(svc.phase, CallPhase.active, reason: '过期 action 不改通话状态');
      await teardown(tester, svc);
    });

    testWidgets('无 action（点通知本体）→ 最小化通话恢复', (tester) async {
      await installChannelMock();
      final (_, svc, notify) = await pumpChat(tester);
      await svc.startCall('bob', CallType.audio);
      svc.minimize();
      notify();
      await tester.pump();

      respond = (method) =>
          method == 'consumeCallIntent' ? {'open': true, 'action': null} : null;
      WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();

      expect(svc.minimized, isFalse, reason: '点通知回通话（restore）');
      await teardown(tester, svc);
    });
  });

  group('opt8 F3 —— 桌面来电唤起（Linux/Windows ringing）', () {
    testWidgets('Linux 来电：bringToFront 恰一次；重复通知不重复唤起；ended 复位',
        (tester) async {
      await installChannelMock();
      final fakeWindow = _FakeWindow();
      PlatformCapabilities.windowOverride = fakeWindow;
      final (_, svc, notify) = await pumpChat(tester);
      // pumpChat 默认 android override；桌面用例切 linux（须重建能力缓存）
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      PlatformCapabilities.resetForTest();
      PlatformCapabilities.windowOverride = fakeWindow;

      svc.handleSignal('call_invite',
          {'from': 'bob', 'call_id': 'r4', 'call_type': 'audio'}, Uint8List(0));
      notify();
      await tester.pump();
      expect(fakeWindow.bringToFrontCalls, 1, reason: '来电 ringing 恢复窗口');

      notify();
      await tester.pump();
      expect(fakeWindow.bringToFrontCalls, 1, reason: '振铃期重复回调不重复抢焦点');

      svc.rejectIncoming();
      notify();
      await tester.pump();
      expect(svc.phase, CallPhase.ended);
      expect(fakeWindow.bringToFrontCalls, 1);

      // ended→idle 后新来电可再次唤起
      await tester.pump(const Duration(seconds: 3));
      svc.handleSignal('call_invite',
          {'from': 'carol', 'call_id': 'r5', 'call_type': 'audio'}, Uint8List(0));
      notify();
      await tester.pump();
      expect(fakeWindow.bringToFrontCalls, 2, reason: 'ended 复位后新来电再次唤起');
      await teardown(tester, svc);
    });

    testWidgets('Android 来电不做窗口唤起（走系统通知）', (tester) async {
      await installChannelMock();
      final fakeWindow = _FakeWindow();
      PlatformCapabilities.windowOverride = fakeWindow;
      final (_, svc, notify) = await pumpChat(tester);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      PlatformCapabilities.resetForTest();
      PlatformCapabilities.windowOverride = fakeWindow;

      svc.handleSignal('call_invite',
          {'from': 'bob', 'call_id': 'r6', 'call_type': 'audio'}, Uint8List(0));
      notify();
      await tester.pump();
      expect(fakeWindow.bringToFrontCalls, 0);
      await teardown(tester, svc);
    });
  });

  group('opt8 F2 —— 悬浮球生命周期（paused 显示 / resumed 收回）', () {
    testWidgets('paused + 语音 active → showCallBubble(video:false)；resumed → hide',
        (tester) async {
      await installChannelMock();
      final (_, svc, notify) = await pumpChat(tester);
      await svc.startCall('bob', CallType.audio);
      svc.handleSignal(
          'call_accept', {'from': 'bob', 'call_id': svc.callId}, Uint8List(0));
      await tester.pump();
      svc.handleSignal('call_answer', {'from': 'bob', 'call_id': svc.callId},
          _body({'sdp': 'a', 'type': 'answer'}));
      notify();
      await tester.pump();

      WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      final shows = callsOf('showCallBubble');
      expect(shows, hasLength(1));
      expect(shows.single.arguments, {'video': false},
          reason: '语音通话 video 标志透传 false（FGS 不降级契约）');

      WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      final hides = callsOf('hideCallBubble');
      expect(hides, hasLength(1), reason: '回前台收回悬浮球');
      expect(hides.single.arguments, {'video': false});
      await teardown(tester, svc);
    });

    testWidgets('paused + 视频 active → showCallBubble(video:true)', (tester) async {
      await installChannelMock();
      final (_, svc, notify) = await pumpChat(tester);
      await svc.startCall('bob', CallType.video);
      svc.handleSignal(
          'call_accept', {'from': 'bob', 'call_id': svc.callId}, Uint8List(0));
      await tester.pump();
      svc.handleSignal('call_answer', {'from': 'bob', 'call_id': svc.callId},
          _body({'sdp': 'a', 'type': 'answer'}));
      notify();
      await tester.pump();

      WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      final shows = callsOf('showCallBubble');
      expect(shows.single.arguments, {'video': true},
          reason: '视频通话 video=true（气泡 action 不得降级 FGS 类型）');
      await teardown(tester, svc);
    });

    testWidgets('从未显示过球 → resume/idle 不调用 hide（防无意义 FGS 启动）',
        (tester) async {
      await installChannelMock();
      final (_, svc, _) = await pumpChat(tester);
      WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(callsOf('showCallBubble'), isEmpty);
      expect(callsOf('hideCallBubble'), isEmpty,
          reason: '未 show 过不得 hide（否则给服务发无意义 action）');
      await teardown(tester, svc);
    });

    testWidgets('通话结束 → 收回悬浮球（曾显示过）', (tester) async {
      await installChannelMock();
      final (_, svc, notify) = await pumpChat(tester);
      await svc.startCall('bob', CallType.audio);
      svc.handleSignal(
          'call_accept', {'from': 'bob', 'call_id': svc.callId}, Uint8List(0));
      await tester.pump();
      svc.handleSignal('call_answer', {'from': 'bob', 'call_id': svc.callId},
          _body({'sdp': 'a', 'type': 'answer'}));
      notify();
      await tester.pump();

      WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(callsOf('showCallBubble'), hasLength(1));

      svc.hangup();
      notify();
      await tester.pump();
      expect(callsOf('hideCallBubble'), hasLength(1),
          reason: 'ended 收敛点收回悬浮球（后台 hangup 场景）');
      await teardown(tester, svc);
    });
  });
}
