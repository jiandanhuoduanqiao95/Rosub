/// 阶段 R1：WebRTC 媒体引擎封装（flutter_webrtc）
///
/// CallEngine 为可注入接口（CallService 状态机单测用假实现驱动）；
/// WebRtcCallEngine 为真实现。SDP/ICE 经信令传输时统一转 Map 序列化。
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

abstract class CallEngineListener {
  void onLocalCandidate(Map<String, Object?> candidate);
  void onRemoteStream();
  void onConnectionState(String state);
}

abstract class CallEngine {
  void setListener(CallEngineListener? listener);
  bool get hasVideo;
  MediaStream? get localStream;
  Future<void> open({required bool video});
  Future<Map<String, Object?>> createOffer();
  Future<void> setRemoteOffer(Map<String, Object?> description);
  Future<Map<String, Object?>> createAnswer();
  Future<void> setRemoteAnswer(Map<String, Object?> description);
  Future<void> addRemoteCandidate(Map<String, Object?> candidate);
  Future<void> attachRenderers({
    RTCVideoRenderer? remote,
    RTCVideoRenderer? local,
  });
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

  MediaStream? get remoteStream => _remote;

  @override
  Future<void> open({required bool video}) async {
    _hasVideo = video;
    debugPrint('[call-trace] engine.getUserMedia(video=$video) start');
    _local = await navigator.mediaDevices.getUserMedia(
      {'audio': true, 'video': video},
    );
    debugPrint('[call-trace] engine.getUserMedia done '
        'audio=${_local!.getAudioTracks().length} '
        'video=${_local!.getVideoTracks().length}');
    final pc = await createPeerConnection(_iceServers);
    _pc = pc;
    debugPrint('[call-trace] engine.peerConnection created');
    for (final track in _local!.getTracks()) {
      pc.addTrack(track, _local!);
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
      // webrtc_interface 的枚举名带全前缀（RTCPeerConnectionStateConnected），
      // 归一化为 'connected'/'connecting'/'failed' 等小写短名——CallService
      // 按 'connected'/'failed' 判定被叫接通与失败（r1s9 真机修复：前缀
      // 不匹配导致被叫永远停在"接通中"、视频画面不挂载）
      final name = state.name;
      final normalized = name.startsWith('RTCPeerConnectionState')
          ? name.substring('RTCPeerConnectionState'.length).toLowerCase()
          : name.toLowerCase();
      _listener?.onConnectionState(normalized);
    };
    _localRenderer?.srcObject = _local;
  }

  // 显式空 constraints：flutter_webrtc 缺省会注入 OfferToReceiveAudio/Video
  // =true，纯语音通话的 offer 也会多出一条 recvonly 视频 m-line（无轨道的
  // 幽灵 transceiver）。按已 addTrack 的轨道生成 m-line，减少无谓的
  // transceiver 生命周期（阶段 R1 真机三轮）
  static const _sdpConstraints = <String, dynamic>{
    'mandatory': <String, dynamic>{},
    'optional': <Map<String, dynamic>>[],
  };

  @override
  Future<Map<String, Object?>> createOffer() async {
    final desc = await _pc!.createOffer(_sdpConstraints);
    await _pc!.setLocalDescription(desc);
    return desc.toMap();
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
    await _pc!.setLocalDescription(desc);
    return desc.toMap();
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
    if (local != null && _local != null) local.srcObject = _local;
  }

  @override
  Future<void> close() async {
    final pc = _pc;
    _pc = null;
    final local = _local;
    _local = null;
    _remote = null;
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
      if (local != null) {
        for (final track in local.getTracks()) {
          await track.stop();
        }
        await local.dispose();
      }
    } catch (_) {}
  }
}
