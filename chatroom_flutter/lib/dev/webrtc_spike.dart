/// 阶段 R1 Spike：flutter_webrtc 平台可用性验证程序
///
/// CHATROOM_WEBRTC_SPIKE=1 环境变量启动（main() 门控），验证当前平台的
/// PeerConnection 创建、音频采集、offer 生成与 ICE 收集，结果打印到
/// stdout 后以退出码收口（0=通过）。Q2/Q3 新平台开工可直接复用。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

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
