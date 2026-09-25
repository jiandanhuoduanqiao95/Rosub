// ============================================================
// R2 群语音/群视频 —— 三端真机集成测试驱动（gc1，2026-09-21）
// ============================================================
// 角色化设备端驱动：真 UI、真 WebRTC 引擎、真连服务器（§36.10 手动
// 矩阵的自动化执行载体，三端共用同一文件，--dart-define 注入角色）。
//
// 运行（受话端先起、主叫后起，由编排脚本控制时序）：
//   flutter test integration_test/group_call_device_test.dart -d <device> \
//     --profile \
//     --dart-define=GC_ROLE=acceptor --dart-define=GC_USERNAME=lin_b \
//     --dart-define=GC_PASSWORD=lin123456 --dart-define=GC_GROUP_ID=2 \
//     [--dart-define=GC_SERVER_HOST=局域网IP] [--dart-define=GC_VIDEO=1]
//
// 角色：
//   caller       UI 发起群通话 → 等对方加入/接通 → 保持 → 断言 → 挂断
//   acceptor     等群来电 → UI 接听 → 保持 GC_HOLD_SECONDS → 等 caller 挂断
//   late_joiner  拒接 → 经注册表中途加入（G3）→ 保持 → 等房间结束
//   busy_peer    1:1 振铃保持中（G4 占线跳过的对端；由 caller 发起 1:1）
//   ringee       多端收敛（G11）：同账号另一设备接听后本端停铃
//   caller_p2p_first  先 1:1 呼叫 GC_PEER 振铃不挂（G4 前半），随后 UI 发起群通话
// 断言失败/超时即测试红（integration_test 进程非零退出）。
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'dart:io';

import 'package:chatroom_flutter/config.dart';
import 'package:chatroom_flutter/screens/chat_screen.dart';
import 'package:chatroom_flutter/widgets/chat_view.dart';
import 'package:chatroom_flutter/services/call_engine.dart';
import 'package:chatroom_flutter/services/call_service.dart';
import 'package:chatroom_flutter/services/socket_service.dart';
import 'package:chatroom_flutter/services/state_manager.dart';
import 'package:path_provider/path_provider.dart';

// 参数解析：dart-define 优先（桌面编排用），为空时读配置文件
// （Android 真机用——避免每轮构建触发 vivo 安装确认，见 §36.10 记录）；
// 配置文件 = 应用文档目录/gc_role.txt，每行 key=value，编排脚本经
// adb run-as 写入。
late String _role;
late String _username;
late String _password;
late int _groupId;
late String _serverHost;
late bool _video;
late int _holdSeconds;
late String _p2pPeer;
late bool _mute;
late bool _muteExpect;
late bool _minimize;
late String _expectLeave;
late bool _noJoin;
late int _waitSeconds;
late String _groupName;

Future<void> _loadParams() async {
  // String.fromEnvironment 的 name 必须是编译期常量——逐键显式声明
  const envMap = <String, String>{
    'GC_ROLE': String.fromEnvironment('GC_ROLE'),
    'GC_USERNAME': String.fromEnvironment('GC_USERNAME'),
    'GC_PASSWORD': String.fromEnvironment('GC_PASSWORD'),
    'GC_GROUP_ID': String.fromEnvironment('GC_GROUP_ID'),
    'GC_SERVER_HOST': String.fromEnvironment('GC_SERVER_HOST'),
    'GC_VIDEO': String.fromEnvironment('GC_VIDEO'),
    'GC_HOLD_SECONDS': String.fromEnvironment('GC_HOLD_SECONDS'),
    'GC_P2P_PEER': String.fromEnvironment('GC_P2P_PEER'),
    'GC_MUTE': String.fromEnvironment('GC_MUTE'),
    'GC_MUTE_EXPECT': String.fromEnvironment('GC_MUTE_EXPECT'),
    'GC_MIN': String.fromEnvironment('GC_MIN'),
    'GC_EXPECT_LEAVE': String.fromEnvironment('GC_EXPECT_LEAVE'),
    'GC_NO_JOIN': String.fromEnvironment('GC_NO_JOIN'),
    'GC_WAIT_SECONDS': String.fromEnvironment('GC_WAIT_SECONDS'),
    'GC_GROUP_NAME': String.fromEnvironment('GC_GROUP_NAME'),
  };
  String? env(String name) {
    final v = envMap[name];
    return (v == null || v.isEmpty) ? null : v;
  }

  var file = const <String, String>{};
  if (env('GC_ROLE') == null) {
    final candidates = <String>[
      '/storage/emulated/0/Android/data/com.example.chatroom_flutter/files/gc_role.txt',
    ];
    try {
      final dir = await getApplicationDocumentsDirectory();
      candidates.insert(0, '${dir.path}/gc_role.txt');
    } catch (_) {}
    for (final path in candidates) {
      try {
        final f = File(path);
        // ignore: avoid_print
        print('[gc-e2e] param file path=$path exists=${f.existsSync()}');
        if (!f.existsSync()) continue;
        final parsed = <String, String>{};
        for (final line in f.readAsLinesSync()) {
          if (!line.contains('=')) continue;
          final k = line.split('=')[0].trim();
          parsed[k] = line.split('=').sublist(1).join('=').trim();
        }
        file = parsed;
        break;
      } catch (e) {
        // ignore: avoid_print
        print('[gc-e2e] param file READ FAILED: $e');
      }
    }
  }
  String s(String name, String def) => env(name) ?? file[name] ?? def;
  int i(String name, int def) =>
      int.tryParse(env(name) ?? file[name] ?? '') ?? def;
  bool b(String name) => (env(name) ?? file[name] ?? '0') == '1';

  _role = s('GC_ROLE', 'smoke');
  _username = s('GC_USERNAME', 'lin_a');
  _password = s('GC_PASSWORD', 'lin123456');
  _groupId = i('GC_GROUP_ID', 2);
  _serverHost = s('GC_SERVER_HOST', '127.0.0.1');
  _video = b('GC_VIDEO');
  _holdSeconds = i('GC_HOLD_SECONDS', 20);
  _p2pPeer = s('GC_P2P_PEER', '');
  _mute = b('GC_MUTE');
  _muteExpect = b('GC_MUTE_EXPECT');
  _minimize = b('GC_MIN');
  _expectLeave = s('GC_EXPECT_LEAVE', '');
  _noJoin = b('GC_NO_JOIN');
  _waitSeconds = i('GC_WAIT_SECONDS', 0);
  _groupName = s('GC_GROUP_NAME', 'R2群通话测试群');
}

AppState get state => AppState.instance;

Future<bool> waitUntil(bool Function() cond,
    {required WidgetTester tester,
    Duration timeout = const Duration(seconds: 30)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (cond()) return true;
    await tester.pump(const Duration(milliseconds: 200));
  }
  return cond();
}

Future<void> tapWhenVisible(WidgetTester tester, Finder finder,
    {Duration timeout = const Duration(seconds: 20)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (finder.evaluate().isNotEmpty) {
      // 弹层入场动画期间控件可能还在视口外（tap 会 miss）——推进帧
      // 直至中心点进入视口再点
      for (var i = 0; i < 15; i++) {
        final rect = tester.getRect(finder.last);
        final dpr = tester.view.devicePixelRatio;
        final size = tester.view.physicalSize / dpr;
        final c = rect.center;
        if (c.dy >= 0 &&
            c.dy <= size.height &&
            c.dx >= 0 &&
            c.dx <= size.width) {
          await tester.tap(finder.last);
          await tester.pump();
          return;
        }
        await tester.pump(const Duration(milliseconds: 80));
      }
    }
    await tester.pump(const Duration(milliseconds: 200));
  }
  throw StateError('等待可点击控件超时: $finder');
}

/// 通话入口（宽屏头部直呼键 / compact AppBar 通话键），弹层选择类型。
/// 成功进入 calling/ringing 后返回。
Future<void> startGroupCallViaUi(WidgetTester tester, SocketService svc,
    {required bool video}) async {
  final wideKey = find.byTooltip(video ? '视频通话' : '语音通话');
  if (wideKey.evaluate().isNotEmpty) {
    await tester.tap(wideKey.last);
    await tester.pump();
  } else {
    await tapWhenVisible(tester, find.byTooltip('通话'));
  }
  // 群会话弹层（若有进行中房间会多一项"加入"——本场景由角色约定保证无）
  final item = find.text(video ? '发起视频群通话' : '发起语音群通话');
  await tapWhenVisible(tester, item);
  await tester.pump(const Duration(milliseconds: 120));
}

Future<void> holdActive(WidgetTester tester, SocketService svc,
    {required Duration duration}) async {
  final end = DateTime.now().add(duration);
  var lastDump = DateTime.now();
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 300));
    if (DateTime.now().difference(lastDump) > const Duration(seconds: 5)) {
      lastDump = DateTime.now();
      // ignore: avoid_print
      print('[gc-e2e] hold phase=${svc.callService.phase} '
          'participants=${svc.callService.participants} '
          'remotePeers=${svc.callService.remotePeers}');
    }
  }
}

/// gc3 帧级判据：每个远端 mesh 边的入站视频必须真正解码出帧
/// （流对象挂载≠画面——"只见自己画面"缺陷的自动化回归锁）
Future<void> expectRemoteVideoFrames(
    WidgetTester tester, SocketService svc, WebRtcCallEngine engine,
    {Duration timeout = const Duration(seconds: 40)}) async {
  final end = DateTime.now().add(timeout);
  var last = <String, int>{};
  while (DateTime.now().isBefore(end)) {
    final frames = <String, int>{};
    for (final p in svc.callService.remotePeers) {
      frames[p] = await engine.peerInboundVideoFrames(p);
    }
    last = frames;
    if (frames.isNotEmpty && frames.values.every((f) => f > 0)) {
      // ignore: avoid_print
      print('[gc-e2e] remote video frames DECODING: $frames');
      return;
    }
    await tester.pump(const Duration(milliseconds: 500));
  }
  // ignore: avoid_print
  print('[gc-e2e] FAIL remote video frames: $last');
  fail('远端视频帧未到达/未解码（有流无画）: $last');
}

Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  await _loadParams();
  AppConfig.serverHost = _serverHost;
  AppConfig.serverPort = 8090;

  testWidgets('R2 群通话设备端驱动: $_role/$_username', (tester) async {
    final engine = WebRtcCallEngine();
    SocketService.callEngineOverride = engine;
    final svc = SocketService();
    state.setLoggedOut();

    expect(await svc.connect(), isTrue, reason: '连接服务器 $_serverHost:8090');
    expect(await svc.login(_username, _password), isNull,
        reason: '登录 $_username');
    await tester.pumpWidget(MaterialApp(
      routes: {'/login': (_) => const Scaffold(body: Text('login'))},
      home: ChatScreen(socketService: svc),
    ));
    await tester.pump();
    // 群会话选中（真实状态操作；列表渲染非 R2 被测面）
    // 真 UI 路径：点击群列表项进入会话（compact 下唯一合法的聊天态入口，
    // _selectChat 会置 _compactShowChat；宽屏走同一回调）
    final groupTile = find.textContaining(_groupName);
    await tapWhenVisible(tester, groupTile.first);
    await waitUntil(() => find.byType(ChatView).evaluate().isNotEmpty,
        tester: tester, timeout: const Duration(seconds: 15));
    // ignore: avoid_print
    print('[gc-e2e] role=$_role user=$_username video=$_video '
        'group=$_groupId ready');

    switch (_role) {
      case 'smoke':
        // UI 链冒烟：宽屏键 → 弹层 → 断言菜单项（不真正发起）
        // compact 聊天态 AppBar 需数帧构建——轮询任一入口键可见
        final keyOk = await waitUntil(
            () =>
                find.byTooltip('语音通话').evaluate().isNotEmpty ||
                find.byTooltip('视频通话').evaluate().isNotEmpty ||
                find.byTooltip('通话').evaluate().isNotEmpty,
            tester: tester,
            timeout: const Duration(seconds: 15));
        if (!keyOk) {
          final dpr = tester.view.devicePixelRatio;
          // ignore: avoid_print
          print('[gc-e2e] DIAG size=${tester.view.physicalSize / dpr} '
              'chat=${state.currentChat} '
              'chatView=${find.byType(ChatView).evaluate().length} '
              'appBar=${find.byType(AppBar).evaluate().length} '
              'groupName=${find.textContaining('研发群').evaluate().length} '
              'callIcons=${find.byIcon(Icons.call_rounded).evaluate().length}');
        }
        expect(keyOk, isTrue, reason: '通话入口键应可见');
        // ignore: avoid_print
        print(
            '[gc-e2e] smoke wide-key=${find.byTooltip('语音通话').evaluate().length} '
            'compact-key=${find.byTooltip('通话').evaluate().length}');
        // 点入口键（不点菜单项）——菜单项出现即弹层验证通过
        final wideKey = find.byTooltip('语音通话');
        if (wideKey.evaluate().isNotEmpty) {
          await tester.tap(wideKey.last);
        } else {
          await tapWhenVisible(tester, find.byTooltip('通话'));
        }
        await tester.pump();
        final menuOk = await waitUntil(
            () => find.text('发起语音群通话').evaluate().isNotEmpty,
            tester: tester,
            timeout: const Duration(seconds: 12));
        expect(menuOk, isTrue, reason: '群通话弹层应出现');
        // ignore: avoid_print
        print('[gc-e2e] smoke PASS: picker visible');
        svc.disconnect();
        return;

      case 'smoke2':
        // 弹层项点击验证：点"发起语音群通话" → 断言 phase=calling → 挂断
        await startGroupCallViaUi(tester, svc, video: false);
        // 等弹层入场动画稳定后再点（连续 pump 推进动画帧）
        await waitUntil(() => find.text('发起语音群通话').evaluate().isNotEmpty,
            tester: tester, timeout: const Duration(seconds: 8));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 120));
        }
        final item2 = find.text('发起语音群通话');
        // ignore: avoid_print
        print('[gc-e2e] smoke2 item widgets=${item2.evaluate().length}');
        await tester.tap(item2.last, warnIfMissed: false);
        final okCalling = await waitUntil(
            () => svc.callService.phase == CallPhase.calling,
            tester: tester,
            timeout: const Duration(seconds: 10));
        // ignore: avoid_print
        print('[gc-e2e] smoke2 calling=$okCalling '
            'phase=${svc.callService.phase}');
        if (okCalling) {
          svc.callService.cancelOutgoing();
          await waitUntil(() => svc.callService.phase == CallPhase.idle,
              tester: tester, timeout: const Duration(seconds: 6));
        }
        expect(okCalling, isTrue, reason: '点弹层菜单项应发起群通话');
        svc.disconnect();
        return;

      case 'caller':
        if (_waitSeconds > 0) {
          // 跨端时序协调：等待其它端进入指定状态窗口
          // ignore: avoid_print
          print('[gc-e2e] caller waiting $_waitSeconds s before invite');
          await holdActive(tester, svc,
              duration: Duration(seconds: _waitSeconds));
        }
        await startGroupCallViaUi(tester, svc, video: _video);
        var ok = await waitUntil(
            () => svc.callService.phase == CallPhase.calling,
            tester: tester,
            timeout: const Duration(seconds: 10));
        expect(ok, isTrue, reason: '发起后应进入 calling');
        // ignore: avoid_print
        print('[gc-e2e] caller calling, invite sent');
        if (_noJoin) {
          // G8：无人接听场景——仅保持房间供并发发起者撞 busy
          await holdActive(tester, svc,
              duration: Duration(seconds: _holdSeconds));
          await tapWhenVisible(tester, find.byIcon(Icons.call_end));
          // ignore: avoid_print
          print('[gc-e2e] caller(no-join) hangup done');
          svc.disconnect();
          return;
        }
        ok = await waitUntil(
            () =>
                svc.callService.phase == CallPhase.connecting &&
                svc.callService.remotePeers.isNotEmpty,
            tester: tester,
            timeout: const Duration(seconds: 40));
        expect(ok, isTrue, reason: '首个成员加入应转 connecting 且有远端成员');
        ok = await waitUntil(() => svc.callService.phase == CallPhase.active,
            tester: tester, timeout: const Duration(seconds: 40));
        expect(ok, isTrue, reason: '首对端连通后应进入 active');
        // ignore: avoid_print
        print('[gc-e2e] caller active participants='
            '${svc.callService.participants}');
        if (_muteExpect) {
          // G7 判据：远端静音态（media 广播驱动瓦片图标）
          var ok = await waitUntil(
              () => svc.callService.remotePeers
                  .every(svc.callService.peerMicMuted),
              tester: tester,
              timeout: const Duration(seconds: 15));
          expect(ok, isTrue, reason: '远端静音态应经 group_call_media 同步');
          expect(find.byIcon(Icons.mic_off_rounded), findsOneWidget,
              reason: '静音瓦片应有 mic_off 图标');
          // ignore: avoid_print
          print('[gc-e2e] caller observed remote mute');
        }
        if (_expectLeave.isNotEmpty) {
          // G10 判据：对端进程被杀 → left(reason=disconnect) 成员收缩
          var ok = await waitUntil(
              () => !svc.callService.participants.contains(_expectLeave),
              tester: tester,
              timeout: const Duration(seconds: 40));
          expect(ok, isTrue, reason: '$_expectLeave 断线后应从成员表移除');
          // ignore: avoid_print
          print('[gc-e2e] caller observed leave of $_expectLeave');
        }
        if (_minimize) {
          // G12：最小化（离开不挂断）→ 悬浮条 → restore 回通话页
          await tapWhenVisible(tester, find.byTooltip('最小化（不挂断）'));
          var ok = await waitUntil(
              () => find.textContaining('通话中').evaluate().isNotEmpty,
              tester: tester,
              timeout: const Duration(seconds: 10));
          expect(ok, isTrue, reason: '最小化后聊天页应出现悬浮返回条');
          // ignore: avoid_print
          print('[gc-e2e] caller minimized, floating bar visible');
          await tapWhenVisible(tester, find.textContaining('通话中'));
          ok = await waitUntil(
              () => find.byTooltip('最小化（不挂断）').evaluate().isNotEmpty,
              tester: tester,
              timeout: const Duration(seconds: 10));
          expect(ok, isTrue, reason: 'restore 后应回通话页');
          // ignore: avoid_print
          print('[gc-e2e] caller restored');
        }
        // 宫格瓦片：gc3 微信式——视频=远端宫格+自己悬浮小窗（无"我"瓦片），
        // 语音=全员头像宫格（自己占首格）
        await holdActive(tester, svc,
            duration: Duration(seconds: _holdSeconds));
        if (_video) {
          expect(find.text('我'), findsNothing, reason: 'gc3 视频群通话自己应为悬浮小窗');
        } else {
          expect(find.text('我'), findsOneWidget, reason: '语音宫格自己占首格');
        }
        for (final peer in svc.callService.remotePeers) {
          final tile = find.text(peer);
          if (tile.evaluate().isEmpty) {
            // 宫格懒加载：3+ 人时末排瓦片在视口外，滚动至可见再断言
            await tester.scrollUntilVisible(tile, 150,
                scrollable: find.byType(Scrollable).first);
          }
          expect(tile, findsOneWidget, reason: '瓦片昵称 $peer');
        }
        if (_video) {
          // gc3 回归锁定：远端视频流必须挂载（真机"三方只见自己画面"缺陷）
          for (final peer in svc.callService.remotePeers) {
            // ignore: avoid_print
            print('[gc-e2e] remoteStream[$peer]='
                '${svc.callService.remoteStreamOf(peer) != null ? 'present' : 'NULL'}');
          }
          expect(
              svc.callService.remotePeers
                  .every((p) => svc.callService.remoteStreamOf(p) != null),
              isTrue,
              reason: 'gc3 回归：远端视频流应挂载');
          await expectRemoteVideoFrames(tester, svc, engine);
        }
        await engine.dumpStats('gc-caller');
        // 挂断（UI 红键）
        await tapWhenVisible(tester, find.byIcon(Icons.call_end));
        ok = await waitUntil(() => svc.callService.phase == CallPhase.ended,
            tester: tester, timeout: const Duration(seconds: 10));
        expect(ok, isTrue, reason: '挂断后应 ended');
        // ignore: avoid_print
        print('[gc-e2e] caller hangup done');
        await holdActive(tester, svc, duration: const Duration(seconds: 2));

      case 'acceptor':
        var ok =
            await waitUntil(() => svc.callService.phase == CallPhase.ringing,
                tester: tester,
                // 等铃窗口余量经 GC_WAIT_SECONDS 扩展（三方编排时 Android
                // 安装确认等不可控延迟，固定 180s 过窄）
                timeout: Duration(seconds: 180 + _waitSeconds));
        expect(ok, isTrue, reason: '应收到群来电');
        // ignore: avoid_print
        print('[gc-e2e] acceptor ringing group='
            '${svc.callService.groupName}');
        await tapWhenVisible(tester, find.byIcon(Icons.call));
        ok = await waitUntil(() => svc.callService.phase == CallPhase.active,
            tester: tester, timeout: const Duration(seconds: 40));
        expect(ok, isTrue, reason: '接听后应 active');
        // ignore: avoid_print
        print('[gc-e2e] acceptor active participants='
            '${svc.callService.participants}');
        if (_mute) {
          // G7：静音 → 群内其余成员应收到 group_call_media
          await tapWhenVisible(tester, find.byIcon(Icons.mic_rounded));
          // ignore: avoid_print
          print('[gc-e2e] acceptor muted');
        }
        if (_video) {
          // gc3/gc4 回归锁定：接听侧远端视频流必须挂载且真正解码出帧。
          // 必须在 hold 之前断言——caller hold 更短先挂断时，远端会话
          // 已被 left 清理，断言只会看到空表（第七轮实测教训）
          for (final peer in svc.callService.remotePeers) {
            // ignore: avoid_print
            print('[gc-e2e] remoteStream[$peer]='
                '${svc.callService.remoteStreamOf(peer) != null ? 'present' : 'NULL'}');
          }
          expect(
              svc.callService.remotePeers
                  .every((p) => svc.callService.remoteStreamOf(p) != null),
              isTrue,
              reason: 'gc3 回归：远端视频流应挂载');
          await expectRemoteVideoFrames(tester, svc, engine);
        }
        await holdActive(tester, svc,
            duration: Duration(seconds: _holdSeconds));
        await engine.dumpStats('gc-acceptor');
        // G5：主叫挂断只移除自己、房间存续——acceptor 确认成员收缩后自行挂断
        // ignore: avoid_print
        print('[gc-e2e] acceptor after-caller-left participants='
            '${svc.callService.participants}');
        expect(svc.callService.participants, [svc.callService.selfUsername],
            reason: '主叫离开后仅剩自己');
        await tapWhenVisible(tester, find.byIcon(Icons.call_end));
        ok = await waitUntil(() => svc.callService.phase == CallPhase.ended,
            tester: tester, timeout: const Duration(seconds: 15));
        expect(ok, isTrue, reason: '本端挂断后应 ended');
        // ignore: avoid_print
        print('[gc-e2e] acceptor ended reason=${svc.callService.endReason}');

      case 'late_joiner':
        var ok = await waitUntil(
            () => svc.callService.phase == CallPhase.ringing,
            tester: tester,
            timeout: const Duration(seconds: 180));
        expect(ok, isTrue, reason: '应收到群来电');
        // 红键 = 拒绝
        await tapWhenVisible(tester, find.byIcon(Icons.call_end));
        ok = await waitUntil(() => svc.callService.phase == CallPhase.idle,
            tester: tester, timeout: const Duration(seconds: 10));
        expect(ok, isTrue, reason: '拒绝后应回 idle');
        ok = await waitUntil(
            () => svc.callService.knownGroupCalls[_groupId] != null,
            tester: tester,
            timeout: const Duration(seconds: 40));
        expect(ok, isTrue, reason: '注册表应显示进行中房间（中途加入入口）');
        // 打开群通话弹层 → 点"加入进行中的群通话（N人）"
        final wideKey = find.byTooltip(_video ? '视频通话' : '语音通话');
        if (wideKey.evaluate().isNotEmpty) {
          await tester.tap(wideKey.last);
        } else {
          await tapWhenVisible(tester, find.byTooltip('通话'));
        }
        await tester.pump();
        final joinTile = find.textContaining('加入进行中的群通话');
        await tapWhenVisible(tester, joinTile);
        ok = await waitUntil(() => svc.callService.phase == CallPhase.active,
            tester: tester, timeout: const Duration(seconds: 40));
        expect(ok, isTrue, reason: '中途加入后应 active');
        // ignore: avoid_print
        print('[gc-e2e] late_joiner active participants='
            '${svc.callService.participants}');
        await engine.dumpStats('gc-late-joiner');
        await holdActive(tester, svc,
            duration: Duration(seconds: _holdSeconds));
        // ignore: avoid_print
        print('[gc-e2e] late_joiner in-call participants='
            '${svc.callService.participants}');
        await tapWhenVisible(tester, find.byIcon(Icons.call_end));
        ok = await waitUntil(() => svc.callService.phase == CallPhase.ended,
            tester: tester, timeout: const Duration(seconds: 15));
        expect(ok, isTrue, reason: '本端挂断后应 ended');
        ok = await waitUntil(
            () => svc.callService.knownGroupCalls[_groupId] == null,
            tester: tester,
            timeout: const Duration(seconds: 20));
        expect(ok, isTrue, reason: '注册表应随房间结束清除');

      case 'busy_initiator':
        // G8：房间进行中另一成员发起同群通话 → call_failed(busy)
        var okDecline = await waitUntil(
            () => svc.callService.phase == CallPhase.ringing,
            tester: tester,
            timeout: const Duration(seconds: 180));
        expect(okDecline, isTrue, reason: '应收到群来电');
        // 红键 = 拒绝
        await tapWhenVisible(tester, find.byIcon(Icons.call_end));
        await waitUntil(() => svc.callService.phase == CallPhase.idle,
            tester: tester, timeout: const Duration(seconds: 10));
        await startGroupCallViaUi(tester, svc, video: false);
        okDecline = await waitUntil(
            () => svc.callService.phase == CallPhase.ended,
            tester: tester,
            timeout: const Duration(seconds: 15));
        expect(okDecline, isTrue, reason: '同群并发房间应被拒');
        expect(svc.callService.endReason, '对方忙线中',
            reason: '应收到 call_failed(busy)');
        // ignore: avoid_print
        print('[gc-e2e] busy_initiator rejected: '
            '${svc.callService.endReason}');

      case 'busy_peer':
        // G4：与 p2p_caller 进入 1:1 通话（忙线窗口无限长，供群发起方
        // 在任意时刻撞上），全程不应被群来电打扰
        var ok = await waitUntil(
            () => svc.callService.phase == CallPhase.ringing,
            tester: tester,
            timeout: const Duration(seconds: 180));
        expect(ok, isTrue, reason: '应收到 1:1 来电');
        await tapWhenVisible(tester, find.byIcon(Icons.call));
        ok = await waitUntil(() => svc.callService.phase == CallPhase.active,
            tester: tester, timeout: const Duration(seconds: 40));
        expect(ok, isTrue, reason: '1:1 应接通');
        // ignore: avoid_print
        print('[gc-e2e] busy_peer in 1:1 call (busy window open)');
        await holdActive(tester, svc,
            duration: Duration(seconds: _holdSeconds));
        // 判据：全程未被群来电打扰（1:1 可能已被对方取消 → ended 合法）
        expect(svc.callService.groupId, isNull, reason: '全程不应进入群通话');
        // ignore: avoid_print
        print('[gc-e2e] busy_peer untouched by group invite');
        // 等 caller 挂断 1:1
        ok = await waitUntil(() => svc.callService.phase == CallPhase.ended,
            tester: tester, timeout: const Duration(seconds: 60));
        expect(ok, isTrue, reason: '对方挂断后应收尾');

      case 'p2p_caller':
        // G4 前半：先 1:1 呼叫 GC_P2P_PEER 并保持振铃（群发起者是他人）
        final okP2p = await svc.callService.startCall(_p2pPeer, CallType.audio);
        expect(okP2p, isTrue);
        var ok = await waitUntil(
            () => svc.callService.phase == CallPhase.active,
            tester: tester,
            timeout: const Duration(seconds: 60));
        expect(ok, isTrue, reason: '1:1 应接通');
        // ignore: avoid_print
        print('[gc-e2e] p2p in call with $_p2pPeer (busy window open)');
        await holdActive(tester, svc,
            duration: Duration(seconds: _holdSeconds));
        svc.callService.hangup();
        ok = await waitUntil(() => svc.callService.phase == CallPhase.ended,
            tester: tester, timeout: const Duration(seconds: 10));
        expect(ok, isTrue);

      case 'ringee':
        // G11：同账号另一设备接听后，本设备停止响铃
        var ok = await waitUntil(
            () => svc.callService.phase == CallPhase.ringing,
            tester: tester,
            timeout: const Duration(seconds: 180));
        expect(ok, isTrue, reason: '应收到群来电');
        ok = await waitUntil(() => svc.callService.phase == CallPhase.ended,
            tester: tester, timeout: const Duration(seconds: 30));
        expect(ok, isTrue, reason: '另一设备接听后本端应停铃');
        expect(svc.callService.endReason, '已在其他设备接听');
        // ignore: avoid_print
        print('[gc-e2e] ringee converged: ${svc.callService.endReason}');

      default:
        throw StateError('未知 GC_ROLE=$_role');
    }

    svc.disconnect();
    // ignore: avoid_print
    print('[gc-e2e] PASS role=$_role user=$_username');
  });
}
