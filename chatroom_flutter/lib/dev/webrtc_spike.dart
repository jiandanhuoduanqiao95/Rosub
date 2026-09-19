/// 阶段 R1 Spike：flutter_webrtc 平台可用性验证程序
///
/// CHATROOM_WEBRTC_SPIKE=1 环境变量启动（main() 门控），验证当前平台的
/// PeerConnection 创建、音频采集、offer 生成与 ICE 收集，结果打印到
/// stdout 后以退出码收口（0=通过）。Q2/Q3 新平台开工可直接复用。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../config.dart';
import '../services/call_engine.dart';
import '../services/call_service.dart';
import '../services/socket_service.dart';
import '../services/state_manager.dart';

/// CHATROOM_WEBRTC_SPIKE=localvideo：本机摄像头预览验证（R1 真机十轮
/// 排障：Linux 本端小窗全黑而远端正常——隔离"本地轨道→渲染器"链路，
/// 不经通话。常驻运行供人工/截图观察）。
class WebrtcLocalVideoApp extends StatelessWidget {
  const WebrtcLocalVideoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: _WebrtcLocalVideoPage(),
    );
  }
}

class _WebrtcLocalVideoPage extends StatefulWidget {
  const _WebrtcLocalVideoPage();

  @override
  State<_WebrtcLocalVideoPage> createState() => _WebrtcLocalVideoPageState();
}

class _WebrtcLocalVideoPageState extends State<_WebrtcLocalVideoPage> {
  final _renderer = RTCVideoRenderer();
  String _status = 'starting…';
  bool _firstFrame = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      // ignore: avoid_print
      print('[spike-localvideo] getUserMedia(video) start');
      final stream = await navigator.mediaDevices
          .getUserMedia({'audio': false, 'video': true});
      // ignore: avoid_print
      print('[spike-localvideo] got stream '
          'video=${stream.getVideoTracks().length} '
          'audio=${stream.getAudioTracks().length}');
      await _renderer.initialize();
      _renderer.onFirstFrameRendered = () {
        // ignore: avoid_print
        print('[spike-localvideo] FIRST FRAME RENDERED');
        if (mounted) setState(() => _firstFrame = true);
      };
      // 回环预览：m150 SDK 桌面端本地 VideoTrack 不向渲染器扇出帧——
      // 用一对隐藏 PC 把本地轨道"远端化"后渲染（远端渲染路径已验证可用）
      final pcA = await createPeerConnection(const {'iceServers': []});
      final pcB = await createPeerConnection(const {'iceServers': []});
      final a = pcA, b = pcB;
      for (final t in stream.getVideoTracks()) {
        await a.addTrack(t, stream);
      }
      a.onIceCandidate = (c) => b.addCandidate(c);
      b.onIceCandidate = (c) => a.addCandidate(c);
      b.onTrack = (e) {
        // ignore: avoid_print
        print(
            '[spike-localvideo] loopback onTrack streams=${e.streams.length}');
        if (e.streams.isNotEmpty) {
          _renderer.srcObject = e.streams.first;
        }
      };
      final offer = await a.createOffer();
      await a.setLocalDescription(offer);
      await b.setRemoteDescription(offer);
      final answer = await b.createAnswer();
      await b.setLocalDescription(answer);
      await a.setRemoteDescription(answer);
      // ignore: avoid_print
      print('[spike-localvideo] loopback sdps exchanged');
      if (mounted) setState(() => _status = 'rendering');
      Timer.periodic(const Duration(seconds: 2), (t) {
        // ignore: avoid_print
        print('[spike-localvideo] probe t+${t.tick * 2}s '
            'firstFrame=$_firstFrame textureId=${_renderer.textureId}');
      });
      // ignore: avoid_print
      print('[spike-localvideo] rendering');
    } catch (e) {
      // ignore: avoid_print
      print('[spike-localvideo] FAIL: $e');
      if (mounted) setState(() => _status = 'FAIL: $e');
    }
  }

  @override
  void dispose() {
    _renderer.srcObject = null;
    _renderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (_status == 'rendering')
            Positioned.fill(
              child: RTCVideoView(_renderer),
            )
          else
            Center(
              child: Text('[spike-localvideo] $_status',
                  style: const TextStyle(color: Colors.white)),
            ),
        ],
      ),
    );
  }
}

class WebrtcSpikeApp extends StatelessWidget {
  const WebrtcSpikeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: _WebrtcSpikePage(),
    );
  }
}

class _WebrtcSpikePage extends StatefulWidget {
  const _WebrtcSpikePage();

  @override
  State<_WebrtcSpikePage> createState() => _WebrtcSpikePageState();
}

class _WebrtcSpikePageState extends State<_WebrtcSpikePage> {
  String _status = '运行中…';

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    // ignore: avoid_print
    print('[webrtc-spike] start');
    var pass = false;
    RTCPeerConnection? pc;
    MediaStream? stream;
    try {
      pc = await createPeerConnection(const {
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
        ],
      });
      // ignore: avoid_print
      print('[webrtc-spike] PeerConnection created');
      var candidateCount = 0;
      pc.onIceCandidate = (c) {
        candidateCount += 1;
        // ignore: avoid_print
        print('[webrtc-spike] ICE: ${c.candidate}');
      };
      stream = await navigator.mediaDevices
          .getUserMedia({'audio': true, 'video': false});
      final tracks = stream.getTracks();
      // ignore: avoid_print
      print('[webrtc-spike] getUserMedia(audio) ok tracks=${tracks.length} '
          'enabled=${tracks.map((t) => t.enabled).toList()}');
      for (final t in tracks) {
        pc.addTrack(t, stream);
      }
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      // ignore: avoid_print
      print('[webrtc-spike] offer type=${offer.type} '
          'sdpLen=${offer.sdp?.length ?? 0}');
      await Future<void>.delayed(const Duration(seconds: 5));
      // ignore: avoid_print
      print('[webrtc-spike] ICE candidates gathered: $candidateCount');
      pass = tracks.isNotEmpty && (offer.sdp?.isNotEmpty ?? false);
    } catch (e, s) {
      // ignore: avoid_print
      print('[webrtc-spike] FAIL: $e');
      // ignore: avoid_print
      print(s);
    } finally {
      try {
        if (stream != null) {
          for (final t in stream.getTracks()) {
            await t.stop();
          }
          await stream.dispose();
        }
        await pc?.close();
      } catch (_) {}
    }
    final result = pass ? 'PASS' : 'FAIL';
    if (mounted) setState(() => _status = result);
    // ignore: avoid_print
    print('[webrtc-spike] RESULT: $result');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(pass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(child: Text('WebRTC Spike: $_status')),
    );
  }
}

/// CHATROOM_WEBRTC_SPIKE=q2call：Q2 Windows 远端视频黑屏诊断受话端
/// （无 UI，Q2-J 缺陷 #2 排障工装）。流程：连接真实服务端 → 注册/登录
/// spike_q2 → 自动接受好友请求 → 来电自动接听（真实引擎+真实渲染器，
/// 触发插件层 [q2diag] 计数日志）→ 保持 [holdSeconds] 供对端呼叫 →
/// 输出阶段/轨道快照后退出。对端由 Linux 客户端 GUI 发起视频呼叫。
class Q2CallDiagApp extends StatelessWidget {
  const Q2CallDiagApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: _Q2CallDiagPage(),
    );
  }
}

class _Q2CallDiagPage extends StatefulWidget {
  const _Q2CallDiagPage();

  @override
  State<_Q2CallDiagPage> createState() => _Q2CallDiagPageState();
}

class _Q2CallDiagPageState extends State<_Q2CallDiagPage> {
  String _status = 'q2call 运行中…';
  RTCVideoRenderer? _remoteView;
  RTCVideoRenderer? _localView;

  @override
  void initState() {
    super.initState();
    _run();
  }

  void _log(String msg) {
    // ignore: avoid_print
    print('[q2call] $msg');
  }

  Future<void> _run() async {
    const holdSeconds = 600;
    // 角色：callee（默认，等来电）/ caller（向 target 发起视频呼叫）
    final role = Platform.environment['CHATROOM_Q2CALL_ROLE'] ?? 'callee';
    final isCaller = role == 'caller';
    final account = Platform.environment['CHATROOM_Q2CALL_USER'] ??
        (isCaller ? 'spike_q3' : 'spike_q2');
    final target = Platform.environment['CHATROOM_Q2CALL_TARGET'] ?? 'spike_q2';
    _log('role=$role account=$account target=$target');
    final state = AppState.instance;
    // ignore: invalid_use_of_visible_for_testing_member
    final engine = WebRtcCallEngine();
    // ignore: invalid_use_of_visible_for_testing_member
    SocketService.callEngineOverride = engine;
    final socket = SocketService();
    RTCVideoRenderer? remoteRenderer;
    var phaseLog = <String>[];
    try {
      _log('connect start');
      final connected = await socket.connect();
      if (!connected) {
        _log('connect FAILED host=${AppConfig.serverHost}');
        throw 'connect failed';
      }
      _log('connected, registering');
      final regErr = await socket.register(account, 'spike123456');
      _log('register => $regErr');
      // 阶段 J 已知 Dart SecureSocket 紧连写竞态：注册后立即登录偶发挂起
      // （服务器无响应）——间隔 + 失败重连重试
      await Future<void>.delayed(const Duration(seconds: 3));
      var loginErr = await socket.login(account, 'spike123456');
      _log('login => $loginErr');
      if (loginErr != null) {
        _log('login retry after: $loginErr');
        try {
          socket.disconnect();
        } catch (_) {}
        await Future<void>.delayed(const Duration(seconds: 3));
        await socket.connect();
        await Future<void>.delayed(const Duration(seconds: 2));
        loginErr = await socket.login(account, 'spike123456');
        _log('login#2 => $loginErr');
      }
      if (loginErr != null) throw 'login failed: $loginErr';
      final call = socket.callService;
      call.addListener(() {
        final p = call.phase.name;
        if (phaseLog.isEmpty || phaseLog.last != p) {
          phaseLog.add(p);
          _log('phase => $p');
        }
        if (call.phase == CallPhase.ringing) {
          _log('incoming from=${call.peer} '
              'type=${call.type?.name ?? "?"} => auto accept');
          call.acceptIncoming();
        }
      });
      var lastReport = '';
      Future<void> acceptPending() async {
        for (final req in state.pendingRequests.toList()) {
          if (!state.friends.contains(req)) {
            _log('friend request from=$req => auto accept');
            await socket.acceptFriend(req);
            _log('acceptFriend($req) sent, friends=${state.friends.join(",")}');
          }
        }
      }

      final deadline = DateTime.now().add(const Duration(seconds: 25));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
        await acceptPending();
      }
      if (isCaller) {
        if (!state.friends.contains(target)) {
          _log('sending friend request to=$target');
          await socket.addFriend(target, message: 'Q2 视频诊断 caller');
          final fd = DateTime.now().add(const Duration(seconds: 30));
          while (
              DateTime.now().isBefore(fd) && !state.friends.contains(target)) {
            await Future<void>.delayed(const Duration(milliseconds: 800));
            await acceptPending();
          }
        }
        _log('friends=${state.friends.join(",")}, startCall(video) to=$target');
        // 阶段 J 已知 Linux SecureSocket 发送偶发静默挂起：startCall 未
        // 进入 calling（邀请被吞）时重试（socket 自愈重连后通常即通）
        for (var attempt = 0; attempt < 6; attempt++) {
          final ok = await socket.callService.startCall(target, CallType.video);
          _log('startCall#${attempt + 1} => $ok '
              '(phase=${socket.callService.phase.name})');
          if (socket.callService.phase != CallPhase.idle) break;
          await Future<void>.delayed(const Duration(seconds: 15));
        }
      }
      _log('hold ${holdSeconds}s role=$role '
          'friends=${state.friends.join(",")}');
      final callDeadline =
          DateTime.now().add(const Duration(seconds: holdSeconds));
      var statsTick = 0;
      while (DateTime.now().isBefore(callDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
        await acceptPending();
        statsTick++;
        if (statsTick % 15 == 0) {
          try {
            await engine.dumpStats('t${statsTick ~/ 15}');
          } catch (_) {}
        }
        final phase = call.phase.name;
        final remote = engine.remoteStream;
        if (remote != null && remoteRenderer == null) {
          final r = RTCVideoRenderer();
          remoteRenderer = r;
          await r.initialize();
          final l = RTCVideoRenderer();
          await l.initialize();
          await engine.attachRenderers(remote: r, local: l);
          _log('remote+local renderers attached '
              'tracks=${remote.getTracks().length}');
          if (mounted) {
            setState(() {
              _remoteView = r;
              _localView = l;
            });
          }
        }
        final report = 'phase=$phase remoteTracks='
            '${remote?.getTracks().length ?? 0}';
        if (report != lastReport && phase != 'idle') {
          lastReport = report;
          _log('snap: $report');
        }
      }
      _log('hold done. phases: ${phaseLog.join(" -> ")}');
      _log(
          'final remoteTracks=${engine.remoteStream?.getTracks().length ?? 0}');
      try {
        call.hangup();
      } catch (_) {}
    } catch (e, s) {
      _log('FAIL: $e');
      // ignore: avoid_print
      print(s);
    } finally {
      try {
        await remoteRenderer?.dispose();
      } catch (_) {}
      // ignore: invalid_use_of_visible_for_testing_member
      SocketService.callEngineOverride = null;
      try {
        socket.disconnect();
      } catch (_) {}
    }
    if (mounted) setState(() => _status = 'q2call 完成');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Q2 Call Diag: $_status')),
      body: Column(
        children: [
          Container(
            color: Colors.black,
            width: 480,
            height: 270,
            child: _remoteView == null
                ? const Center(child: Text('remote: pending'))
                : RTCVideoView(_remoteView!),
          ),
          Container(
            color: Colors.blueGrey,
            width: 240,
            height: 135,
            child: _localView == null
                ? const Center(child: Text('local: pending'))
                : RTCVideoView(_localView!),
          ),
          Text('remote=${_remoteView != null} local=${_localView != null}'),
        ],
      ),
    );
  }
}
