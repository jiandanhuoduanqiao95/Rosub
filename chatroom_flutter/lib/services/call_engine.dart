/// 阶段 R1/R2：WebRTC 媒体引擎封装（flutter_webrtc）
///
/// CallEngine 为可注入接口（CallService 状态机单测用假实现驱动）；
/// WebRtcCallEngine 为真实现。SDP/ICE 经信令传输时统一转 Map 序列化。
/// R2 群通话扩展：CallPeerSession 按对端一一对应（mesh 网状每条边一个
/// PC，本地轨道共享 addTrack）；一对一保持单 PC 路径不变。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// webrtc_interface 的连接状态枚举名带全前缀
/// （RTCPeerConnectionStateConnected），归一化为小写短名——CallService
/// 按 'connected'/'failed' 判定接通与失败（r1s9 真机修复：前缀不匹配
/// 导致被叫永远停在"接通中"）
String normalizeConnectionState(String name) =>
    name.startsWith('RTCPeerConnectionState')
        ? name.substring('RTCPeerConnectionState'.length).toLowerCase()
        : name.toLowerCase();

/// 群通话单条 mesh 边的会话（对端 → 独立 PeerConnection）
abstract class CallPeerSession {
  String get peerId;
  MediaStream? get remoteStream;
  Future<Map<String, Object?>> createOffer();
  Future<void> setRemoteOffer(Map<String, Object?> description);
  Future<Map<String, Object?>> createAnswer();
  Future<void> setRemoteAnswer(Map<String, Object?> description);
  Future<void> addRemoteCandidate(Map<String, Object?> candidate);

  /// 挂载远端视频渲染器（null=解除挂载；流后到时自动补挂）
  void attachRenderer(RTCVideoRenderer? renderer);
  Future<void> close();
}

abstract class CallEngineListener {
  void onLocalCandidate(Map<String, Object?> candidate);
  void onRemoteStream();
  void onConnectionState(String state);

  /// R2 群通话：多对等会话回调（一对一单 PC 路径不触发）
  void onPeerLocalCandidate(String peerId, Map<String, Object?> candidate);
  void onPeerRemoteStream(String peerId);
  void onPeerConnectionState(String peerId, String state);
}

abstract class CallEngine {
  void setListener(CallEngineListener? listener);
  bool get hasVideo;
  MediaStream? get localStream;

  /// 本地媒体轨道是否就绪（群通话 offer 发送前的终局防御——R2 gc2
  /// 真机排障：Windows Release 曾发出无 m-line 的 142 字节空 offer，
  /// 引擎层就绪状态由服务层显式校验，杜绝空壳协商）
  bool get hasLocalMedia;
  Future<void> open({required bool video});

  /// R2 群通话：仅采集本地媒体（不建一对一 PC），随后按对端
  /// createPeerSession 逐边建连
  Future<void> ensureMedia({required bool video});
  Future<CallPeerSession> createPeerSession(String peerId);
  CallPeerSession? peerSession(String peerId);
  Future<Map<String, Object?>> createOffer();
  Future<void> setRemoteOffer(Map<String, Object?> description);
  Future<Map<String, Object?>> createAnswer();
  Future<void> setRemoteAnswer(Map<String, Object?> description);
  Future<void> addRemoteCandidate(Map<String, Object?> candidate);
  Future<void> attachRenderers({
    RTCVideoRenderer? remote,
    RTCVideoRenderer? local,
  });
  Future<void> setMicMuted(bool muted);
  Future<void> setCameraEnabled(bool enabled);
  Future<void> setSpeakerphoneOn(bool on);
  Future<void> close();
}

class WebRtcCallEngine implements CallEngine {
  WebRtcCallEngine();

  static const _iceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  };

  RTCPeerConnection? _pc;
  MediaStream? _local;
  MediaStream? _remote;
  // Linux 本端预览回环（r1s11）：m150 SDK 桌面端本地 VideoTrack 不向
  // 渲染器扇出帧（AddRenderer 后 onFirstFrameRendered 永不触发，远端
  // 轨道正常，spike 探针实锤）——用一对隐藏 PC 把本地轨道"远端化"，
  // 预览渲染走已验证可用的远端轨道路径。Android/其他平台为 null 直用。
  RTCPeerConnection? _loopA;
  RTCPeerConnection? _loopB;
  MediaStream? _previewStream;
  final Map<String, _WebRtcPeerSession> _peers = {};
  CallEngineListener? _listener;
  bool _hasVideo = false;
  RTCVideoRenderer? _remoteRenderer;
  RTCVideoRenderer? _localRenderer;

  @override
  void setListener(CallEngineListener? listener) {
    _listener = listener;
  }

  @override
  bool get hasVideo => _hasVideo;

  @override
  MediaStream? get localStream => _local;

  @override
  bool get hasLocalMedia => _local?.getTracks().isNotEmpty ?? false;

  MediaStream? get remoteStream => _remote;

  @override
  Future<void> open({required bool video}) async {
    await _acquireMedia(video: video);
    final pc = await createPeerConnection(_iceServers);
    _pc = pc;
    debugPrint('[call-trace] engine.peerConnection created');
    // gc4：addTrack 必须 await——fire-and-forget 与 createOffer 竞态时
    // 视频轨道的原生注册未完成，offer 会缺失视频 m-line（群会话实测，
    // 1:1 同型隐患一并封死）
    for (final track in _local!.getTracks()) {
      await pc.addTrack(track, _local!);
    }
    pc.onIceCandidate = (candidate) {
      _listener?.onLocalCandidate(candidate.toMap());
    };
    pc.onTrack = (event) {
      if (event.streams.isEmpty) return;
      _remote = event.streams.first;
      _remoteRenderer?.srcObject = _remote;
      _listener?.onRemoteStream();
    };
    pc.onConnectionState = (state) {
      _listener?.onConnectionState(normalizeConnectionState(state.name));
    };
  }

  /// 采集本地媒体 + Linux 回环预览（一对一 open 与群通话 ensureMedia
  /// 共用；不含任何 PeerConnection）
  Future<void> _acquireMedia({required bool video}) async {
    _hasVideo = video;
    debugPrint('[call-trace] engine.getUserMedia(video=$video) start');
    _local = await navigator.mediaDevices.getUserMedia(
      {'audio': true, 'video': video},
    );
    final audioCount = _local!.getAudioTracks().length;
    final videoCount = _local!.getVideoTracks().length;
    debugPrint('[call-trace] engine.getUserMedia done '
        'audio=$audioCount video=$videoCount');
    // R2 gc2 真机排障加固：Windows Release 上曾出现 getUserMedia 不抛错
    // 但流内零轨道（142 字节空 offer 的根源）——静默空流会让整场通话
    // 无声无息协商出无媒体的空壳。此处显式判死并抛错，由上层转为
    // 用户可见的"无法访问麦克风或摄像头"。
    if (audioCount == 0 || (video && videoCount == 0)) {
      try {
        await _local!.dispose();
      } catch (_) {}
      _local = null;
      throw StateError(
          'getUserMedia 返回空轨道 audio=$audioCount video=$videoCount');
    }
    // Q2 排障开关（CHATROOM_Q2_NO_LOOPBACK=1）：跳过 Linux 本端预览回环。
    // 生产缺省不受影响（不设该变量）。
    final noLoopback = Platform.environment['CHATROOM_Q2_NO_LOOPBACK'] == '1';
    if (Platform.isLinux && video && !noLoopback) {
      await _startLoopbackPreview();
    } else {
      _localRenderer?.srcObject = _local;
    }
  }

  @override
  Future<void> ensureMedia({required bool video}) async {
    await _acquireMedia(video: video);
  }

  @override
  Future<CallPeerSession> createPeerSession(String peerId) async {
    final old = _peers.remove(peerId);
    if (old != null) {
      try {
        await old.close();
      } catch (_) {}
    }
    final pc = await createPeerConnection(_iceServers);
    final session = _WebRtcPeerSession(peerId, pc, _listener, _local);
    _peers[peerId] = session;
    debugPrint('[call-trace] engine.peerSession[$peerId] created');
    return session;
  }

  @override
  CallPeerSession? peerSession(String peerId) => _peers[peerId];

  /// Linux 本端预览回环：m150 SDK 桌面端本地 VideoTrack 不向渲染器扇出
  /// 帧（AddRenderer 后 onFirstFrameRendered 永不触发；远端轨道正常；
  /// spike 探针实锤，lib/dev/webrtc_spike.dart localvideo 模式可复现）。
  /// 用一对隐藏 PC 把本地视频轨道"远端化"，预览渲染走已验证可用的
  /// 远端轨道路径。仅预览用：不含音频，candidates 进程内直换。
  Future<void> _startLoopbackPreview() async {
    try {
      final a = await createPeerConnection(const {'iceServers': <dynamic>[]});
      final b = await createPeerConnection(const {'iceServers': <dynamic>[]});
      for (final track in _local!.getVideoTracks()) {
        await a.addTrack(track, _local!);
      }
      b.onTrack = (event) {
        if (event.streams.isEmpty) return;
        _previewStream = event.streams.first;
        _localRenderer?.srcObject = _previewStream;
      };
      final offer = await a.createOffer(_sdpConstraints);
      await a.setLocalDescription(offer);
      await b.setRemoteDescription(offer);
      final answer = await b.createAnswer(_sdpConstraints);
      await b.setLocalDescription(answer);
      await a.setRemoteDescription(answer);
      // SDP 定型后再挂 candidate 泵（早到的候选会在对端无 remote 描述时
      // 被拒）；回环候选本机直连，量小无碍
      a.onIceCandidate = (c) => b.addCandidate(c);
      b.onIceCandidate = (c) => a.addCandidate(c);
      _loopA = a;
      _loopB = b;
    } catch (_) {
      // 回环失败降级为黑小窗（不影响通话主体），清理半建状态
      await _stopLoopbackPreview();
    }
  }

  Future<void> _stopLoopbackPreview() async {
    final a = _loopA;
    final b = _loopB;
    _loopA = null;
    _loopB = null;
    _previewStream = null;
    for (final pc in [a, b]) {
      try {
        await pc?.close();
      } catch (_) {}
    }
  }

  // 显式空 constraints：flutter_webrtc 缺省会注入 OfferToReceiveAudio/Video
  // =true，纯语音通话的 offer 也会多出一条 recvonly 视频 m-line（无轨道的
  // 幽灵 transceiver）。按已 addTrack 的轨道生成 m-line，减少无谓的
  // transceiver 生命周期（阶段 R1 真机三轮）
  static const _sdpConstraints = <String, dynamic>{
    'mandatory': <String, dynamic>{},
    'optional': <Map<String, dynamic>>[],
  };

  /// Q2 修复（桌面↔桌面远端视频黑帧）：m150 桌面预编译 libwebrtc 协商到
  /// H264 时解码产**纯黑帧**（像素探针实锤：OnFrame 正常、CopyPixelBuffer
  /// px0 恒为 0,0,0；本端采集预览正常）——Android 预编译不含 H264 故
  /// R1 Android↔Linux 走 VP8 正常，桌面双端才复现。从本地 SDP 中剔除
  /// H264 载荷类型，强制 VP8/VP9（两端 libwebrtc 自带软解，零外部依赖）。
  /// R2 gc3 实测修正：vendored Android 版**已带 H264/H265 解码**且 answer
  /// 主动选 H264/H265（video_receive_stream native 日志实锤；剔除 H264
  /// 后桌面 answer 落 H265，同族黑帧）——桌面收 Android 流即触发黑帧，
  /// 故剔除为**桌面门控**（桌面 offer/answer 剔除 H264/H265 后，协商
  /// 自然落 VP8/VP9；Android 自身硬解不受影响）。
  static String sanitizeDesktopSdp(String sdp) {
    if (!Platform.isLinux && !Platform.isWindows) return sdp;
    final drop = <String>{};
    final lines = sdp.split('\n');
    for (final line in lines) {
      final m = RegExp(r'^a=rtpmap:(\d+) H26[45]/\d+').firstMatch(line.trim());
      if (m != null) drop.add(m.group(1)!);
    }
    if (drop.isEmpty) return sdp;
    // RTX 等依赖载荷经 apt= 引用 H264 的同步剔除
    for (final line in lines) {
      final m =
          RegExp(r'^a=fmtp:(\d+) apt=(\d+)(?:$|;)').firstMatch(line.trim());
      if (m != null && drop.contains(m.group(2))) drop.add(m.group(1)!);
    }
    // gc4 真机排障：Windows m150 的 offer 视频载荷**只有 H264/H265**
    //（Linux offer 含 VP8，平台差异实测）——全删会把 m=video 整行删掉，
    // 该边视频彻底失协。此时注入 VP8+RTX（libwebrtc 内置软编解码，
    // 不依赖预编译裁剪），m-line 恒存。
    final usedPts = <String>{};
    for (final line in lines) {
      final m = RegExp(r'^a=rtpmap:(\d+)').firstMatch(line.trim());
      if (m != null) usedPts.add(m.group(1)!);
    }
    // PT 分配全空间扫描（m150 offer 的 H264 变体可占满 96~127 大半且
    // 逐次不定——范围不足时 vp8Pt 为空 → 注入失效 → m-line 被删）
    String vp8Pt = '', rtxPt = '';
    for (var pt = 96; pt <= 127 && rtxPt.isEmpty; pt++) {
      final p = '$pt';
      if (usedPts.contains(p)) continue;
      if (vp8Pt.isEmpty) {
        vp8Pt = p;
      } else {
        rtxPt = p;
      }
    }
    for (var pt = 35; pt <= 95 && rtxPt.isEmpty; pt++) {
      final p = '$pt';
      if (usedPts.contains(p)) continue;
      if (vp8Pt.isEmpty) {
        vp8Pt = p;
      } else {
        rtxPt = p;
      }
    }
    final out = <String>[];
    var injected = false;
    for (var line in lines) {
      final t = line.trim();
      final attr = RegExp(r'^a=(rtpmap|fmtp|rtcp-fb):(\d+)').firstMatch(t);
      if (attr != null && drop.contains(attr.group(2)!)) continue;
      if (t.startsWith('m=video ')) {
        final parts = t.split(' ');
        final pts = parts.sublist(3).where((p) => !drop.contains(p)).toList();
        if (pts.isEmpty) {
          if (vp8Pt.isEmpty) {
            debugPrint('[call-trace] sdp WARN: video m-line would be empty '
                'and no free PT for VP8 injection, raw=$t');
            continue;
          }
          injected = true;
          final rebuilt = [
            ...parts.sublist(0, 3),
            vp8Pt,
            if (rtxPt.isNotEmpty) rtxPt
          ].join(' ');
          final crlf = line.endsWith('\r') ? '\r' : '';
          out.add('$rebuilt$crlf');
          out
            ..add('a=rtpmap:$vp8Pt VP8/90000$crlf')
            ..add('a=rtcp-fb:$vp8Pt nack$crlf')
            ..add('a=rtcp-fb:$vp8Pt nack pli$crlf')
            ..add('a=rtcp-fb:$vp8Pt goog-remb$crlf');
          if (rtxPt.isNotEmpty) {
            out
              ..add('a=rtpmap:$rtxPt rtx/90000$crlf')
              ..add('a=fmtp:$rtxPt apt=$vp8Pt$crlf');
          }
          continue;
        }
        final rebuilt = [...parts.sublist(0, 3), ...pts].join(' ');
        out.add(line.endsWith('\r') ? '$rebuilt\r' : rebuilt);
        continue;
      }
      out.add(line);
    }
    if (injected) {
      debugPrint('[call-trace] sdp: video m-line had only H264/H265, '
          'injected VP8 pt=$vp8Pt rtx=$rtxPt');
    }
    return out.join('\n');
  }

  /// 从（协商后的）SDP 提取首个视频载荷的编码名（诊断用）
  static String primaryVideoCodec(String? sdp) {
    if (sdp == null || sdp.isEmpty) return '?';
    String? firstPt;
    for (final line in sdp.split(RegExp(r'\r?\n'))) {
      final t = line.trim();
      if (t.startsWith('m=video ')) {
        final parts = t.split(' ');
        if (parts.length > 3) firstPt = parts[3];
        break;
      }
    }
    if (firstPt == null) return '?';
    for (final line in sdp.split(RegExp(r'\r?\n'))) {
      final m = RegExp(r'^a=rtpmap:(\d+) (\S+)/').firstMatch(line.trim());
      if (m != null && m.group(1) == firstPt) return m.group(2)!;
    }
    return 'pt$firstPt';
  }

  @override
  Future<Map<String, Object?>> createOffer() async {
    final desc = await _pc!.createOffer(_sdpConstraints);
    final clean = sanitizeDesktopSdp(desc.sdp ?? '');
    await _pc!.setLocalDescription(
        RTCSessionDescription(clean, desc.type ?? 'offer'));
    debugPrint('[call-trace] offer codec=${primaryVideoCodec(clean)}');
    return {'sdp': clean, 'type': desc.type ?? 'offer'};
  }

  @override
  Future<void> setRemoteOffer(Map<String, Object?> description) async {
    await _pc!.setRemoteDescription(RTCSessionDescription(
      description['sdp'] as String?,
      description['type'] as String?,
    ));
  }

  @override
  Future<Map<String, Object?>> createAnswer() async {
    final desc = await _pc!.createAnswer(_sdpConstraints);
    final clean = sanitizeDesktopSdp(desc.sdp ?? '');
    await _pc!.setLocalDescription(
        RTCSessionDescription(clean, desc.type ?? 'answer'));
    debugPrint('[call-trace] answer codec=${primaryVideoCodec(clean)}');
    return {'sdp': clean, 'type': desc.type ?? 'answer'};
  }

  @override
  Future<void> setRemoteAnswer(Map<String, Object?> description) async {
    await _pc!.setRemoteDescription(RTCSessionDescription(
      description['sdp'] as String?,
      description['type'] as String?,
    ));
  }

  @override
  Future<void> addRemoteCandidate(Map<String, Object?> candidate) async {
    await _pc!.addCandidate(RTCIceCandidate(
      candidate['candidate'] as String?,
      candidate['sdpMid'] as String?,
      candidate['sdpMLineIndex'] as int?,
    ));
  }

  @override
  Future<void> attachRenderers({
    RTCVideoRenderer? remote,
    RTCVideoRenderer? local,
  }) async {
    // null 显式清理引用（通话界面 dispose 时解除挂载）
    _remoteRenderer = remote;
    if (remote != null && _remote != null) remote.srcObject = _remote;
    _localRenderer = local;
    // Linux 回环预览：渲染回环"远端"流而非本地轨道（后者在 m150 桌面
    // SDK 上不扇出帧）；其余平台 _previewStream 恒 null 直用本地流
    if (local != null && _local != null) {
      local.srcObject = _previewStream ?? _local;
    }
  }

  @override
  Future<void> setMicMuted(bool muted) async {
    // track.enabled=false 即停止发送（发静音包），是标准的麦克风静音
    for (final track
        in _local?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = !muted;
    }
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    for (final track
        in _local?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = enabled;
    }
  }

  @override
  Future<void> setSpeakerphoneOn(bool on) async {
    // 听筒/免提路由仅移动端有意义（桌面恒系统输出设备）；Android 走
    // AudioSwitch（r1s9 起恢复启用——接听闪退真根因是清单权限，与
    // AudioSwitch 无关），iOS 待 Q4 接入
    if (!Platform.isAndroid) return;
    Helper.setSpeakerphoneOn(on);
  }

  /// Q2 排障：周期性上报 RTP 收发统计（判别"发送端编码产黑/哑"与
  /// "接收端解码黑/哑"）。outbound-rtp 看 bytesSent/framesEncoded，
  /// inbound-rtp 看 bytesReceived/framesDecoded。
  Future<void> dumpStats(String tag) async {
    // R2 gc3：群通话 mesh 边逐对统计（判别"流已挂载但帧不渲染"与"无流"）。
    // 群通话无 1:1 _pc——mesh 遍历必须在 _pc 判空前执行（曾因此零输出）
    for (final entry in List.of(_peers.entries)) {
      await entry.value.dumpStats(tag);
    }
    try {
      final stats = await _pc?.getStats();
      if (stats == null) return;
      for (final s in stats) {
        final v = s.values;
        final kind = v['kind'] ?? v['mediaType'] ?? '?';
        if (s.type == 'outbound-rtp') {
          debugPrint('[call-stats] $tag OUT $kind '
              'bytes=${v['bytesSent']} pkts=${v['packetsSent']} '
              'framesEnc=${v['framesEncoded'] ?? v['framesSent']}');
        } else if (s.type == 'inbound-rtp') {
          debugPrint('[call-stats] $tag IN $kind '
              'bytes=${v['bytesReceived']} pkts=${v['packetsReceived']} '
              'framesDec=${v['framesDecoded']}');
        }
        // Q2 排障：音频电平客观测量（判别"发送端采集弱"与"接收端播小"）
        if (kind == 'audio') {
          final level = v['audioLevel'] ?? v['totalAudioEnergy'];
          if (level != null) {
            debugPrint('[call-stats] $tag AUD ${s.type} level=$level '
                'energy=${v['totalAudioEnergy']} '
                'totalEnergy=${v['totalSamplesDuration']}');
          } else if (s.type == 'media-source' || s.type == 'track') {
            debugPrint(
                '[call-stats] $tag AUD ${s.type} fields=${v.keys.toList()}');
          }
        }
      }
    } catch (e) {
      debugPrint('[call-stats] $tag FAIL $e');
    }
  }

  /// R2 gc3：指定对端 mesh 边的入站视频已解码帧数（帧级判据——流对象
  /// 挂载≠画面，自动化据此断言"真出画"；会话不存在返回 -1）
  Future<int> peerInboundVideoFrames(String peerId) async {
    final session = _peers[peerId];
    if (session == null) return -1;
    return session.inboundVideoFrames();
  }

  @override
  Future<void> close() async {
    final pc = _pc;
    _pc = null;
    final local = _local;
    _local = null;
    _remote = null;
    final peers = List.of(_peers.values);
    _peers.clear();
    await _stopLoopbackPreview();
    // 先摘掉渲染器对流的引用（native 纹理仍持有 stream 时 dispose 会
    // 在原生层产生悬空引用——Linux 关闭卡死的加固项）
    _remoteRenderer?.srcObject = null;
    _localRenderer?.srcObject = null;
    _remoteRenderer = null;
    _localRenderer = null;
    try {
      // 先断 PeerConnection（释放对轨道/流的 native 引用），再停轨道、
      // 再 dispose 流——顺序颠倒时 Linux 上曾出现关闭链挂起
      await pc?.close();
      for (final session in peers) {
        try {
          await session.close();
        } catch (_) {}
      }
      if (local != null) {
        for (final track in local.getTracks()) {
          await track.stop();
        }
        await local.dispose();
      }
    } catch (_) {}
  }
}

/// 群通话单条 mesh 边的真实现：独立 PC + 共享本地轨道
class _WebRtcPeerSession implements CallPeerSession {
  _WebRtcPeerSession(
      this.peerId, RTCPeerConnection pc, this._listener, MediaStream? local)
      : _pc = pc {
    // gc4 真机排障（Windows offer 无视频 m-line 的根因）：生成式构造器
    // 不能 await——addTrack 曾是 fire-and-forget，视频轨道的原生注册
    // 尚未完成 createOffer 就已生成 m-line（音频注册快恒在场，视频
    // 慢一步即输掉竞态，真机逐轮不稳定复现）。改为显式 Future 并在
    // offer/answer 前等待。
    _tracksReady = _addLocalTracks(local);
    pc.onIceCandidate = (candidate) {
      _listener?.onPeerLocalCandidate(peerId, candidate.toMap());
    };
    pc.onTrack = (event) {
      // R2 gc3 排障仪器化：streams=0 说明远端流映射缺失（渲染挂不上）
      debugPrint('[call-trace] peer[$peerId] onTrack kind=${event.track.kind} '
          'streams=${event.streams.length} renderer=${_renderer != null}');
      if (event.streams.isEmpty) return;
      _remote = event.streams.first;
      _renderer?.srcObject = _remote;
      _listener?.onPeerRemoteStream(peerId);
    };
    pc.onConnectionState = (state) {
      _listener?.onPeerConnectionState(
          peerId, normalizeConnectionState(state.name));
    };
  }

  @override
  final String peerId;
  final RTCPeerConnection _pc;
  final CallEngineListener? _listener;
  MediaStream? _remote;
  RTCVideoRenderer? _renderer;

  /// 本地轨道原生注册完成门（构造器启动，offer/answer 前必须 await）
  Future<void> _tracksReady = Future.value();

  Future<void> _addLocalTracks(MediaStream? local) async {
    final tracks = local?.getTracks() ?? const <MediaStreamTrack>[];
    debugPrint('[call-trace] peer[$peerId] addTracks '
        'audio=${tracks.where((t) => t.kind == 'audio').length} '
        'video=${tracks.where((t) => t.kind == 'video').length}');
    for (final track in tracks) {
      try {
        await _pc.addTrack(track, local!);
      } catch (e) {
        debugPrint('[call-trace] peer[$peerId] addTrack(${track.kind}) '
            'FAILED: $e');
      }
    }
  }

  @override
  MediaStream? get remoteStream => _remote;

  @override
  Future<Map<String, Object?>> createOffer() async {
    await _tracksReady;
    final desc = await _pc.createOffer(WebRtcCallEngine._sdpConstraints);
    for (final line in (desc.sdp ?? '').split('\n')) {
      final t = line.trim();
      if (t.startsWith('m=')) {
        debugPrint(
            '[call-trace] peer[$peerId] raw ${t.split(' ').take(4).join(' ')}');
      }
    }
    final clean = WebRtcCallEngine.sanitizeDesktopSdp(desc.sdp ?? '');
    await _pc.setLocalDescription(
        RTCSessionDescription(clean, desc.type ?? 'offer'));
    debugPrint('[call-trace] peer[$peerId] offer '
        'codec=${WebRtcCallEngine.primaryVideoCodec(clean)}');
    return {'sdp': clean, 'type': desc.type ?? 'offer'};
  }

  @override
  Future<void> setRemoteOffer(Map<String, Object?> description) async {
    await _pc.setRemoteDescription(RTCSessionDescription(
      description['sdp'] as String?,
      description['type'] as String?,
    ));
  }

  @override
  Future<Map<String, Object?>> createAnswer() async {
    await _tracksReady;
    final desc = await _pc.createAnswer(WebRtcCallEngine._sdpConstraints);
    final clean = WebRtcCallEngine.sanitizeDesktopSdp(desc.sdp ?? '');
    await _pc.setLocalDescription(
        RTCSessionDescription(clean, desc.type ?? 'answer'));
    debugPrint('[call-trace] peer[$peerId] answer '
        'codec=${WebRtcCallEngine.primaryVideoCodec(clean)}');
    return {'sdp': clean, 'type': desc.type ?? 'answer'};
  }

  @override
  Future<void> setRemoteAnswer(Map<String, Object?> description) async {
    await _pc.setRemoteDescription(RTCSessionDescription(
      description['sdp'] as String?,
      description['type'] as String?,
    ));
  }

  @override
  Future<void> addRemoteCandidate(Map<String, Object?> candidate) async {
    await _pc.addCandidate(RTCIceCandidate(
      candidate['candidate'] as String?,
      candidate['sdpMid'] as String?,
      candidate['sdpMLineIndex'] as int?,
    ));
  }

  @override
  void attachRenderer(RTCVideoRenderer? renderer) {
    _renderer = renderer;
    if (renderer != null && _remote != null) {
      renderer.srcObject = _remote;
      debugPrint('[call-trace] peer[$peerId] attachRenderer '
          'remoteStream=${_remote!.id}');
    }
  }

  /// R2 gc3 排障：单条 mesh 边的 RTP 收发统计（与 1:1 dumpStats 同口径）
  Future<void> dumpStats(String tag) async {
    try {
      final stats = await _pc.getStats();
      for (final s in stats) {
        final v = s.values;
        final kind = v['kind'] ?? v['mediaType'] ?? '?';
        if (s.type == 'outbound-rtp') {
          debugPrint('[call-stats] $tag peer[$peerId] OUT $kind '
              'bytes=${v['bytesSent']} pkts=${v['packetsSent']} '
              'framesEnc=${v['framesEncoded'] ?? v['framesSent']}');
        } else if (s.type == 'inbound-rtp') {
          debugPrint('[call-stats] $tag peer[$peerId] IN $kind '
              'bytes=${v['bytesReceived']} pkts=${v['packetsReceived']} '
              'framesDec=${v['framesDecoded']}');
        }
      }
    } catch (e) {
      debugPrint('[call-stats] $tag peer[$peerId] FAIL $e');
    }
  }

  /// 入站视频已解码帧数（帧级判据；无 inbound 视频 stats 视为 0）
  Future<int> inboundVideoFrames() async {
    try {
      final stats = await _pc.getStats();
      for (final s in stats) {
        final v = s.values;
        if (s.type == 'inbound-rtp' &&
            (v['kind'] ?? v['mediaType']) == 'video') {
          final f = v['framesDecoded'];
          if (f is int) return f;
          return int.tryParse('$f') ?? 0;
        }
      }
    } catch (_) {}
    return 0;
  }

  @override
  Future<void> close() async {
    _renderer?.srcObject = null;
    _renderer = null;
    _remote = null;
    await _pc.close();
  }
}
