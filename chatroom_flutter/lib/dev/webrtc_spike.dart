/// 阶段 R1 Spike：flutter_webrtc 平台可用性验证程序
///
/// CHATROOM_WEBRTC_SPIKE=1 环境变量启动（main() 门控），验证当前平台的
/// PeerConnection 创建、音频采集、offer 生成与 ICE 收集，结果打印到
/// stdout 后以退出码收口（0=通过）。Q2/Q3 新平台开工可直接复用。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

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
        print('[spike-localvideo] loopback onTrack streams=${e.streams.length}');
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
