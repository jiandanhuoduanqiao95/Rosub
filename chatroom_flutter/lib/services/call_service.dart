/// 阶段 R1：通话服务层——状态机 + 信令接线 + WebRTC 会话管理
///
/// 语音/视频两种通话类型共用同一状态机（call_type 仅影响引擎采集与 UI）；
/// 信令走既有 SSL 长连接（CallSignaling 由 SocketService 实现）。
/// 状态流转：
///   主叫：idle → calling →(对方接听)→ connecting →(answer)→ active → ended
///   被叫：idle → ringing →(接听)→ connecting →(offer/answer)→ active → ended
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCVideoRenderer;

import 'call_engine.dart';

enum CallType { audio, video }

enum CallPhase { idle, calling, ringing, connecting, active, ended }

abstract class CallSignaling {
  Future<void> sendCall(String type, String to, String callId,
      {String? callType, String? body});
}

class CallService extends ChangeNotifier implements CallEngineListener {
  CallService({required CallSignaling signaling, CallEngine? engine})
      : _signaling = signaling,
        _engine = engine ?? WebRtcCallEngine() {
    _engine.setListener(this);
  }

  static const ringTimeout = Duration(seconds: 45);
  static const endedDisplayDuration = Duration(seconds: 2);

  final CallSignaling _signaling;
  final CallEngine _engine;

  CallPhase _phase = CallPhase.idle;
  String? _peer;
  CallType? _type;
  String? _callId;
  String? endReason;
  DateTime? activeSince;

  /// R1 真机十轮（微信式交互）：最小化——用户离开通话界面返回会话
  /// 界面操作而不挂断；由通话页"最小化"按钮置位，ChatScreen 据此
  /// 关闭通话路由并显示悬浮返回条，来电/去电新呼叫时复位
  bool minimized = false;

  /// 通话中控制开关（静音麦克风 / 关闭摄像头 / 免提外放）
  bool micMuted = false;
  bool cameraOff = false;
  bool speakerOn = false;

  CallPhase get phase => _phase;
  String? get peer => _peer;
  CallType? get type => _type;
  String? get callId => _callId;
  bool get isBusy => _phase != CallPhase.idle;

  Timer? _ringTimer;
  Timer? _endedTimer;
  bool _remoteDescSet = false;
  final List<Map<String, Object?>> _pendingCandidates = [];

  String _genCallId() =>
      '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(999999)}';

  /// R1 真机排障（r1s5）：接通路径步骤追踪——Android 闪退发生在
  /// getUserMedia/SDP 应用时刻且无 Java 异常时的唯一观测手段，
  /// Linux 控制台与 adb logcat（-s flutter）均可见。问题定位后移除。
  void _trace(String msg) {
    debugPrint('[call-trace] $msg');
  }

  void _setPhase(CallPhase phase) {
    _phase = phase;
    notifyListeners();
  }

  // ============================================================
  // 用户操作
  // ============================================================

  /// 最小化通话界面（不挂断）：ChatScreen 收到通知后关闭通话路由并
  /// 显示悬浮返回条；ended/idle 态不允许最小化
  void minimize() {
    if (_phase == CallPhase.idle || _phase == CallPhase.ended) return;
    minimized = true;
    notifyListeners();
  }

  /// 从最小化恢复：ChatScreen 悬浮条点击后调用，重新打开通话界面
  void restore() {
    minimized = false;
    notifyListeners();
  }

  /// 静音/取消静音本端麦克风（停止发送音频，发静音包）
  Future<void> toggleMic() async {
    micMuted = !micMuted;
    notifyListeners();
    await _engine.setMicMuted(micMuted);
  }

  /// 开关本端摄像头（仅视频通话）
  Future<void> toggleCamera() async {
    if (_type != CallType.video) return;
    cameraOff = !cameraOff;
    notifyListeners();
    await _engine.setCameraEnabled(!cameraOff);
  }

  /// 免提外放/听筒切换
  Future<void> toggleSpeaker() async {
    speakerOn = !speakerOn;
    notifyListeners();
    await _engine.setSpeakerphoneOn(speakerOn);
  }

  void _resetToggles(CallType type) {
    minimized = false;
    micMuted = false;
    cameraOff = false;
    // 微信式默认路由：语音通话听筒、视频通话外放
    speakerOn = type == CallType.video;
  }

  /// 发起通话（UI 已完成运行时权限请求后调用）
  Future<bool> startCall(String peer, CallType type) async {
    if (isBusy) return false;
    _peer = peer;
    _type = type;
    _callId = _genCallId();
    endReason = null;
    activeSince = null;
    _remoteDescSet = false;
    _pendingCandidates.clear();
    _resetToggles(type);
    _trace('startCall type=$type peer=$peer id=$_callId');
    _setPhase(CallPhase.calling);
    try {
      await _signaling.sendCall('call_invite', peer, _callId!,
          callType: type.name);
    } catch (_) {
      _teardown('呼叫发送失败');
      return false;
    }
    _ringTimer?.cancel();
    _ringTimer = Timer(ringTimeout, () async {
      if (_phase != CallPhase.calling) return;
      try {
        await _signaling.sendCall('call_cancel', peer, _callId!);
      } catch (_) {}
      _teardown('对方无应答');
    });
    return true;
  }

  /// 接听来电（UI 已完成运行时权限请求后调用）
  Future<void> acceptIncoming() async {
    if (_phase != CallPhase.ringing || _callId == null) return;
    final id = _callId!;
    final peer = _peer!;
    _ringTimer?.cancel();
    _setPhase(CallPhase.connecting);
    _trace('acceptIncoming id=$id');
    // 引擎就绪门：Android 运行时权限弹窗下 open 可能耗时数秒，
    // offer/ICE 先到时须等待（未就绪即处理会打到 null PeerConnection）
    _calleeMediaReady = () async {
      try {
        _trace('callee engine.open(video=${_type == CallType.video}) start');
        await _engine.open(video: _type == CallType.video);
        await _engine.setSpeakerphoneOn(speakerOn);
        _trace('callee engine.open done');
      } catch (e) {
        _trace('callee engine.open FAILED: $e');
        await _safeSend('call_hangup', peer, id);
        _teardown('无法访问麦克风或摄像头');
      }
    }();
    try {
      await _signaling.sendCall('call_accept', peer, id);
      _trace('call_accept sent');
    } catch (e) {
      _trace('call_accept send FAILED: $e');
      _teardown('接听发送失败');
      return;
    }
  }

  Future<void>? _calleeMediaReady;

  void rejectIncoming() {
    if (_phase != CallPhase.ringing || _callId == null) return;
    final id = _callId!;
    final peer = _peer!;
    _safeSend('call_reject', peer, id);
    _teardown('已拒绝');
  }

  void cancelOutgoing() {
    if (_phase != CallPhase.calling || _callId == null) return;
    final id = _callId!;
    final peer = _peer!;
    _safeSend('call_cancel', peer, id);
    _teardown('已取消');
  }

  void hangup() {
    if (_phase != CallPhase.connecting && _phase != CallPhase.active) {
      return;
    }
    if (_callId == null) return;
    final id = _callId!;
    final peer = _peer!;
    _safeSend('call_hangup', peer, id);
    _teardown('通话已结束');
  }

  /// 连接断开（SocketService 断线/登出时通知）：结束本地通话状态
  void handleDisconnected() {
    if (isBusy || _phase == CallPhase.ended) {
      _teardown('连接已断开');
    }
  }

  // ============================================================
  // 信令入站（SocketService 分发）
  // ============================================================

  void handleSignal(
      String msgType, Map<String, dynamic> header, Uint8List body) {
    final from = header['from'] as String?;
    final id = header['call_id'] as String?;
    switch (msgType) {
      case 'call_invite':
        if (isBusy || from == null) {
          if (from != null && id != null) {
            _safeSend('call_reject', from, id);
          }
          return;
        }
        _peer = from;
        _callId = id;
        _type = (header['call_type'] as String?) == 'video'
            ? CallType.video
            : CallType.audio;
        endReason = null;
        activeSince = null;
        _remoteDescSet = false;
        _pendingCandidates.clear();
        _resetToggles(_type!);
        _trace('incoming call_invite from=$from id=$id type=$_type');
        _setPhase(CallPhase.ringing);
        break;
      case 'call_accept':
        if (_phase != CallPhase.calling || id != _callId) return;
        _ringTimer?.cancel();
        _startCallerMedia();
        break;
      case 'call_active':
        // 多端收敛：本呼叫已在（其他设备）接听
        if (id != _callId) return;
        if (_phase == CallPhase.ringing) {
          _teardown('已在其他设备接听');
        }
        break;
      case 'call_reject':
        if (id != _callId || _phase != CallPhase.calling) return;
        _teardown('对方已拒绝');
        break;
      case 'call_cancel':
        if (id != _callId || _phase != CallPhase.ringing) return;
        _teardown('对方已取消');
        break;
      case 'call_hangup':
        if (id != _callId || _phase == CallPhase.idle) return;
        _teardown('通话已结束');
        break;
      case 'call_failed':
        if (id != _callId) return;
        _teardown(_failText(header['reason'] as String?));
        break;
      case 'call_offer':
        if (id != _callId || _phase != CallPhase.connecting) return;
        _handleOffer(body);
        break;
      case 'call_answer':
        if (id != _callId || _phase != CallPhase.connecting) return;
        _handleAnswer(body);
        break;
      case 'call_ice':
        if (id != _callId ||
            (_phase != CallPhase.connecting && _phase != CallPhase.active)) {
          return;
        }
        _handleCandidate(body);
        break;
    }
  }

  String _failText(String? reason) {
    switch (reason) {
      case 'offline':
        return '对方不在线';
      case 'busy':
        return '对方忙线中';
      case 'not_friend':
        return '对方不是您的好友';
      case 'blocked':
        return '对方已将您拉黑';
      case 'expired':
        return '对方无应答';
      default:
        return '呼叫失败';
    }
  }

  Future<void> _startCallerMedia() async {
    final id = _callId!;
    final peer = _peer!;
    _setPhase(CallPhase.connecting);
    _trace('caller media start (accepted by peer)');
    try {
      _trace('caller engine.open(video=${_type == CallType.video}) start');
      await _engine.open(video: _type == CallType.video);
      await _engine.setSpeakerphoneOn(speakerOn);
      _trace('caller engine.open done');
      final offer = await _engine.createOffer();
      _trace('caller offer created');
      await _signaling.sendCall('call_offer', peer, id,
          body: jsonEncode(offer));
      _trace('caller offer sent');
    } catch (e) {
      _trace('caller media FAILED: $e');
      await _safeSend('call_hangup', peer, id);
      _teardown('无法建立通话');
    }
  }

  Future<void> _handleOffer(Uint8List body) async {
    final id = _callId!;
    final peer = _peer!;
    try {
      _trace('callee offer received, waiting media');
      await (_calleeMediaReady ?? Future<void>.value());
      if (_phase != CallPhase.connecting) return;
      final offer = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      await _engine.setRemoteOffer(offer);
      _trace('callee setRemoteOffer done');
      final answer = await _engine.createAnswer();
      await _signaling.sendCall('call_answer', peer, id,
          body: jsonEncode(answer));
      _trace('callee answer sent');
      await _flushCandidates();
    } catch (e) {
      _trace('callee handleOffer FAILED: $e');
      await _safeSend('call_hangup', peer, id);
      _teardown('无法建立通话');
    }
  }

  Future<void> _handleAnswer(Uint8List body) async {
    try {
      final answer = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      await _engine.setRemoteAnswer(answer);
      _trace('caller setRemoteAnswer done');
      await _flushCandidates();
      activeSince = DateTime.now();
      _setPhase(CallPhase.active);
    } catch (e) {
      _trace('caller handleAnswer FAILED: $e');
      _teardown('无法建立通话');
    }
  }

  Future<void> _handleCandidate(Uint8List body) async {
    try {
      final candidate = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      if (_remoteDescSet) {
        await _engine.addRemoteCandidate(candidate);
      } else {
        _pendingCandidates.add(candidate);
      }
    } catch (_) {}
  }

  Future<void> _flushCandidates() async {
    _remoteDescSet = true;
    final pending = List.of(_pendingCandidates);
    _pendingCandidates.clear();
    for (final candidate in pending) {
      try {
        await _engine.addRemoteCandidate(candidate);
      } catch (_) {}
    }
  }

  // ============================================================
  // 引擎回调（CallEngineListener）
  // ============================================================

  @override
  void onLocalCandidate(Map<String, Object?> candidate) {
    if (_phase != CallPhase.connecting && _phase != CallPhase.active) {
      return;
    }
    if (_callId == null || _peer == null) return;
    _safeSend('call_ice', _peer!, _callId!, body: jsonEncode(candidate));
  }

  @override
  void onRemoteStream() {
    notifyListeners();
  }

  @override
  void onConnectionState(String state) {
    _trace('connectionState=$state phase=$_phase');
    // ICE 连通：被叫（无 answer 回执驱动）据此从接通中转通话中
    if (state == 'connected' && _phase == CallPhase.connecting) {
      activeSince ??= DateTime.now();
      _setPhase(CallPhase.active);
      return;
    }
    if (state == 'failed' &&
        (_phase == CallPhase.connecting || _phase == CallPhase.active)) {
      if (_callId != null && _peer != null) {
        _safeSend('call_hangup', _peer!, _callId!);
      }
      _teardown('连接失败');
    }
  }

  // ============================================================
  // 收尾
  // ============================================================

  Future<void> _safeSend(String type, String to, String callId,
      {String? body}) async {
    try {
      await _signaling.sendCall(type, to, callId, body: body);
    } catch (_) {}
  }

  void _teardown(String reason) {
    _trace('teardown: $reason (phase=$_phase)');
    _ringTimer?.cancel();
    _ringTimer = null;
    _endedTimer?.cancel();
    endReason = reason;
    micMuted = false;
    cameraOff = false;
    _engine.close();
    _remoteDescSet = false;
    _pendingCandidates.clear();
    _setPhase(CallPhase.ended);
    _endedTimer = Timer(endedDisplayDuration, () {
      if (_phase == CallPhase.ended) {
        _phase = CallPhase.idle;
        _peer = null;
        _type = null;
        _callId = null;
        activeSince = null;
        minimized = false;
        notifyListeners();
      }
    });
  }

  /// UI 视频渲染器接线（CallScreen 在 initState/dispose 调用）
  Future<void> attachRenderers({
    RTCVideoRenderer? remote,
    RTCVideoRenderer? local,
  }) =>
      _engine.attachRenderers(remote: remote, local: local);

  @override
  void dispose() {
    _ringTimer?.cancel();
    _endedTimer?.cancel();
    _engine.close();
    super.dispose();
  }
}
