/// 阶段 R1：WebRTC 媒体引擎封装（flutter_webrtc）
///
/// CallEngine 为可注入接口（CallService 状态机单测用假实现驱动）；
/// WebRtcCallEngine 为真实现。SDP/ICE 经信令传输时统一转 Map 序列化。
import 'dart:io';

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
    if (Platform.isLinux && video) {
      await _startLoopbackPreview();
    } else {
      _localRenderer?.srcObject = _local;
    }
  }

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
    // Linux 回环预览：渲染回环"远端"流而非本地轨道（后者在 m150 桌面
    // SDK 上不扇出帧）；其余平台 _previewStream 恒 null 直用本地流
    if (local != null && _local != null) {
      local.srcObject = _previewStream ?? _local;
    }
  }

  @override
  Future<void> setMicMuted(bool muted) async {
    // track.enabled=false 即停止发送（发静音包），是标准的麦克风静音
    for (final track in _local?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = !muted;
    }
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    for (final track in _local?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
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

  @override
  Future<void> close() async {
    final pc = _pc;
    _pc = null;
    final local = _local;
    _local = null;
    _remote = null;
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
      if (local != null) {
        for (final track in local.getTracks()) {
          await track.stop();
        }
        await local.dispose();
      }
    } catch (_) {}
  }
}
