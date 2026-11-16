/// 阶段 R1/R2：通话服务层——状态机 + 信令接线 + WebRTC 会话管理
///
/// 语音/视频两种通话类型共用同一状态机（call_type 仅影响引擎采集与 UI）；
/// 信令走既有 SSL 长连接（CallSignaling 由 SocketService 实现）。
/// 一对一状态流转：
///   主叫：idle → calling →(对方接听)→ connecting →(answer)→ active → ended
///   被叫：idle → ringing →(接听)→ connecting →(offer/answer)→ active → ended
/// R2 群通话（mesh 网状，同 Phase 枚举）：
///   主叫：idle → calling →(首成员加入)→ connecting →(任一对端连通)→ active
///   被邀：idle → ringing →(加入)→ connecting →(joined[self] 逐对发起
///   offer，新加入者发起协商)→ active；成员变更经 group_call_joined/left
///   广播驱动 per-peer 会话表增删；knownGroupCalls 注册表跟踪进行中的
///   群房间（中途加入入口）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show MediaStream, RTCVideoRenderer;

import '../platform/capabilities.dart';
import 'call_engine.dart';

enum CallType { audio, video }

enum CallPhase { idle, calling, ringing, connecting, active, ended }

/// 群通话信令接口（SocketService 实现；与 sendCall 一样走既有发送队列）
/// 通话音效钩子（gc8：来电铃声循环 / 挂断音；构造注入使状态机单测
/// 可确定性断言，默认实现走平台能力抽象并在测试绑定下静默）
abstract class CallSound {
  Future<void> playRingtone();
  Future<void> stopRingtone();
  Future<void> playHangup();
}

/// 默认实现：PlatformCapabilities.sound 分发（Android 原生 looping /
/// 桌面 Timer 重播循环；测试绑定静默——R-P21 惯例）
class PlatformCallSound implements CallSound {
  Timer? _loopTimer;

  bool get _isTestEnv {
    // flutter test 进程恒带 FLUTTER_TEST（覆盖纯 test() 无 binding 场景）
    if (Platform.environment.containsKey('FLUTTER_TEST')) return true;
    try {
      return WidgetsBinding.instance.runtimeType.toString() ==
          'AutomatedTestWidgetsFlutterBinding';
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> playRingtone() async {
    if (_isTestEnv) return;
    unawaited(_playOnce());
    if (!Platform.isAndroid && !Platform.isIOS) {
      // 桌面单次播放（paplay/PlaySoundW）——Timer 重播循环；Android
      // 由原生 MediaPlayer looping 持续
      _loopTimer?.cancel();
      _loopTimer = Timer.periodic(const Duration(milliseconds: 2200), (_) {
        unawaited(_playOnce());
      });
    }
  }

  Future<void> _playOnce() async {
    try {
      await PlatformCapabilities.sound.playCallRingtone();
    } catch (_) {}
  }

  @override
  Future<void> stopRingtone() async {
    _loopTimer?.cancel();
    _loopTimer = null;
    if (_isTestEnv) return;
    try {
      await PlatformCapabilities.sound.stopCallRingtone();
    } catch (_) {}
  }

  @override
  Future<void> playHangup() async {
    if (_isTestEnv) return;
    try {
      await PlatformCapabilities.sound.playHangupSound();
    } catch (_) {}
  }
}

abstract class CallSignaling {
  Future<void> sendCall(String type, String to, String callId,
      {String? callType, String? body});
  Future<void> sendGroupCall(String type, int groupId, String callId,
      {String? callType, String? mic, String? cam});
}

/// 进行中的群通话房间快照（knownGroupCalls 注册表项，供会话页
/// "加入群通话"入口展示与中途加入）
class GroupCallRoomInfo {
  const GroupCallRoomInfo({
    required this.groupId,
    required this.groupName,
    required this.callId,
    required this.callType,
    required this.participants,
  });

  final int groupId;
  final String groupName;
  final String callId;
  final CallType callType;
  final List<String> participants;
}

/// 单个对端的 mesh 边状态（服务层侧；引擎侧会话在 CallPeerSession）
class _GroupPeer {
  _GroupPeer({this.session});
  CallPeerSession? session;
  bool remoteDescSet = false;
  final List<Map<String, Object?>> pendingCandidates = [];
}

class CallService extends ChangeNotifier implements CallEngineListener {
  CallService({
    required CallSignaling signaling,
    CallEngine? engine,
    String? Function()? selfUsername,
    CallSound? sound,
  })  : _signaling = signaling,
        _engine = engine ?? WebRtcCallEngine(),
        _selfUsername = selfUsername ?? (() => null),
        _callSound = sound ?? PlatformCallSound() {
    _engine.setListener(this);
  }

  static const ringTimeout = Duration(seconds: 45);
  static const endedDisplayDuration = Duration(seconds: 2);

  /// gc9：来电振铃超时自动拒绝（早于服务端 60s 过期，被叫主动发拒绝
  /// 信令让主叫即刻知晓）
  static const incomingRingTimeout = Duration(seconds: 30);

  /// opt9 断线恢复：本地重连兜底超时（服务端宽限期 30s + 对端回线信令
  /// 到达余量；超时本地挂断收场，不无限等待）
  static const reconnectTimeout = Duration(seconds: 35);

  /// opt9 断线恢复：ICE 连接 failed 后的自动恢复次数上限
  static const maxIceRestartAttempts = 2;

  /// 群通话重入的 joined[self] 兜底窗口（超时直接对既有远端发 offer）
  static const groupRejoinFallback = Duration(seconds: 2);

  final CallSignaling _signaling;
  final CallEngine _engine;
  final String? Function() _selfUsername;
  final CallSound _callSound;

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

  /// 当前摄像头朝向（默认前置自拍；切换镜头后翻转——本地小窗镜像跟随，
  /// 后置不镜像）
  bool isFrontCamera = true;

  // ---- opt9 断线恢复状态 ----
  /// 本端/对端连接异常等待恢复中（UI 显示提示条）
  bool reconnecting = false;

  /// 恢复提示文案（CallScreen 顶部提示条数据源）
  String? hint;

  /// 本场 1:1 通话中是否为主叫（恢复协商方向判定：caller 恒为 offer
  /// 发起方，callee 发 resume 请求，避免 offer 碰撞）
  bool isCaller = false;

  /// 重新协商进行中（offer 已发未 answer；resume/peer_back 重复触发去重）
  bool renegotiating = false;

  /// 群通话重入流程进行中（重连后 group_call_join 重入去重）
  bool rejoinInProgress = false;

  /// ICE failed 后已执行的恢复次数（超过 maxIceRestartAttempts 收场）
  int iceRestartAttempts = 0;

  /// 恢复兜底定时器（35s 超时挂断收场；connected/teardown 清除）
  Timer? reconnectTimer;

  /// 群重入 joined[self] 兜底定时器（2s；独立于 35s 恢复兜底——二者
  /// 并存，35s 恒兜底收场，2s 只补发缺失 mesh 边的 offer）
  Timer? groupFallbackTimer;

  /// mesh 重建进行中标记（joined[self] 的 _startGroupOffers 在途时
  /// 置位）：fallback 与重建完成前的并发入口据此让路，防止同一 peer
  /// 被重复 createPeerSession/offer
  bool _groupMeshSyncing = false;

  /// 最近一次 1:1 PeerConnection 状态（信令断线重连后判定媒体是否存活）
  String _lastPcState = '';

  // ---- R2 群通话状态 ----
  bool _isGroup = false;
  int? _groupId;
  String? _groupName;
  final Set<String> _participants = {};
  final Map<String, _GroupPeer> _groupPeers = {};
  final Map<String, Future<void>> _peerOfferInFlight = {};
  final Map<String, bool> _peerMicMuted = {};
  final Map<String, bool> _peerCamOff = {};

  /// 进行中的群通话房间（群内任意成员视角，group_call_joined/left 广播
  /// 驱动；房间结束后移除）——群会话页"加入群通话"入口数据源
  final Map<int, GroupCallRoomInfo> knownGroupCalls = {};

  CallPhase get phase => _phase;
  String? get peer => _peer;
  CallType? get type => _type;
  String? get callId => _callId;
  bool get isBusy => _phase != CallPhase.idle;

  /// opt1 P5：通话是否处于进行中（calling/ringing/connecting/active，
  /// 含最小化；ended 展示期不算）——socket 断线豁免拆场与回前台探测
  /// 跳过的判定依据（媒体 P2P 直连不依赖信令通道，熄屏/断线继续通话）
  bool get isInLiveCall =>
      _phase == CallPhase.calling ||
      _phase == CallPhase.ringing ||
      _phase == CallPhase.connecting ||
      _phase == CallPhase.active;

  // ---- 群通话 getters ----
  bool get isGroupCall => _isGroup;
  int? get groupId => _groupId;
  String? get groupName => _groupName;
  String? get _self => _selfUsername();

  /// 本机用户名（宫格自我瓦片判定用；未登录为 null）
  String? get selfUsername => _self;

  /// 房间参与者（含自己，排序稳定供 UI/测试断言）
  List<String> get participants => _participants.toList()..sort();

  /// 远端成员（参与者 - 自己，宫格瓦片数据源）
  List<String> get remotePeers {
    final self = _self;
    return _participants.where((m) => m != self).toList()..sort();
  }

  MediaStream? remoteStreamOf(String peerId) =>
      _groupPeers[peerId]?.session?.remoteStream;

  bool peerMicMuted(String peerId) => _peerMicMuted[peerId] ?? false;

  bool peerCamOff(String peerId) => _peerCamOff[peerId] ?? false;

  Timer? _ringTimer;
  Timer? _endedTimer;
  Timer? _incomingRingTimer;
  bool _reachedConnecting = false;

  /// gc9：来电振铃超时自动拒绝（被叫侧本地定时器；发拒绝信令让主叫
  /// 即刻知晓，早于服务端 60s 过期）
  void _startIncomingRingTimer() {
    _incomingRingTimer?.cancel();
    _incomingRingTimer = Timer(incomingRingTimeout, () {
      if (_phase != CallPhase.ringing) return;
      if (_isGroup) {
        _safeSendGroup('group_call_leave');
      } else if (_peer != null && _callId != null) {
        _safeSend('call_reject', _peer!, _callId!);
      }
      _teardown('超时未接听');
    });
  }

  /// gc8：来电铃声开始（ Android 原生 looping / 桌面 PlatformCallSound
  /// 内部 Timer 重播）
  void _startRingtone() {
    unawaited(_callSound.playRingtone());
  }

  /// gc8：停铃声（接听/结束共用；挂断音由 teardown 按 _reachedConnecting
  /// 单独触发，避免接听瞬间误播）
  void _stopRingtone() {
    unawaited(_callSound.stopRingtone());
  }

  bool _remoteDescSet = false;
  final List<Map<String, Object?>> _pendingCandidates = [];

  String _genCallId() =>
      '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(999999)}';

  void _setPhase(CallPhase phase) {
    _phase = phase;
    notifyListeners();
  }

  static String _flag(bool v) => v ? '1' : '0';

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
    if (_isGroup) {
      await _safeSendGroup('group_call_media',
          mic: _flag(micMuted), cam: _flag(cameraOff));
    }
  }

  /// 开关本端摄像头（仅视频通话）
  Future<void> toggleCamera() async {
    if (_type != CallType.video) return;
    cameraOff = !cameraOff;
    notifyListeners();
    await _engine.setCameraEnabled(!cameraOff);
    if (_isGroup) {
      await _safeSendGroup('group_call_media',
          mic: _flag(micMuted), cam: _flag(cameraOff));
    }
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
    // 默认不外放（1.0.2-opt1，用户决策）：语音/视频一律默认听筒/系统
    // 回退路由，需要免提由用户手动开。Android 上 setSpeakerphoneOn(false)
    // 经 AudioSwitch 偏好链选设备，无听筒设备（平板）自动回退到扬声器
    // 不会无声，因此不再需要"无听筒设备默认外放"特例与预取注入。
    speakerOn = false;
    isFrontCamera = true;
  }

  /// 视频输入设备数（>1 时通话界面显示"切换镜头"键）
  Future<int> videoInputCount() => _engine.videoInputCount();

  /// 切换摄像头（移动端前后翻转 / 桌面多摄循环）；本地小窗镜像跟随
  Future<void> switchCamera() async {
    await _engine.switchCamera();
    isFrontCamera = !isFrontCamera;
    notifyListeners();
  }

  void _resetGroupSessionState(Set<String> initial) {
    _participants
      ..clear()
      ..addAll(initial);
    _groupPeers.clear();
    _peerMicMuted.clear();
    _peerCamOff.clear();
  }

  /// 发起一对一通话（UI 已完成运行时权限请求后调用）
  Future<bool> startCall(String peer, CallType type) async {
    if (isBusy) return false;
    _isGroup = false;
    _groupId = null;
    _groupName = null;
    _peer = peer;
    _type = type;
    _callId = _genCallId();
    endReason = null;
    activeSince = null;
    _remoteDescSet = false;
    _pendingCandidates.clear();
    _resetRecoveryState();
    isCaller = true;
    _resetToggles(type);
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

  /// 发起群通话（对群全体在线成员广播邀请；UI 已完成权限请求后调用）
  Future<bool> startGroupCall(
      int groupId, String groupName, CallType type) async {
    if (isBusy) return false;
    _isGroup = true;
    _groupId = groupId;
    _groupName = groupName;
    _peer = null;
    _type = type;
    _callId = _genCallId();
    endReason = null;
    activeSince = null;
    _resetRecoveryState();
    isCaller = false;
    _resetGroupSessionState({
      if (_self != null) _self!,
    });
    _resetToggles(type);
    _setPhase(CallPhase.calling);
    try {
      await _signaling.sendGroupCall('group_call_invite', groupId, _callId!,
          callType: type.name);
    } catch (_) {
      _teardown('呼叫发送失败');
      return false;
    }
    _ringTimer?.cancel();
    _ringTimer = Timer(ringTimeout, () async {
      if (_phase != CallPhase.calling) return;
      await _safeSendGroup('group_call_leave');
      _teardown('无人接听');
    });
    return true;
  }

  /// 接听来电 / 加入被邀请的群通话（UI 已完成运行时权限请求后调用）
  Future<void> acceptIncoming() async {
    if (_phase != CallPhase.ringing || _callId == null) return;
    if (_isGroup) {
      await _beginGroupJoin();
      return;
    }
    final id = _callId!;
    final peer = _peer!;
    _ringTimer?.cancel();
    _incomingRingTimer?.cancel();
    _reachedConnecting = true;
    _stopRingtone();
    _setPhase(CallPhase.connecting);
    // 引擎就绪门：Android 运行时权限弹窗下 open 可能耗时数秒，
    // offer/ICE 先到时须等待（未就绪即处理会打到 null PeerConnection）
    _calleeMediaReady = () async {
      try {
        await _engine.open(video: _type == CallType.video);
        await _engine.setSpeakerphoneOn(speakerOn);
      } catch (e) {
        await _safeSend('call_hangup', peer, id);
        _teardown('无法访问麦克风或摄像头');
      }
    }();
    try {
      await _signaling.sendCall('call_accept', peer, id);
    } catch (e) {
      _teardown('接听发送失败');
      return;
    }
  }

  Future<void>? _calleeMediaReady;

  /// R2 群通话共用加入流程（acceptIncoming 群分支 / joinGroupRoom）：
  /// 媒体就绪门 + group_call_join，joined[self] 广播确认后逐对发起协商
  Future<void> _beginGroupJoin() async {
    final id = _callId!;
    final gid = _groupId!;
    _ringTimer?.cancel();
    _incomingRingTimer?.cancel();
    _reachedConnecting = true;
    _stopRingtone();
    _setPhase(CallPhase.connecting);
    _calleeMediaReady = () async {
      try {
        await _engine.ensureMedia(video: _type == CallType.video);
        await _engine.setSpeakerphoneOn(speakerOn);
      } catch (e) {
        await _safeSendGroup('group_call_leave');
        _teardown('无法访问麦克风或摄像头');
      }
    }();
    try {
      await _signaling.sendGroupCall('group_call_join', gid, id);
    } catch (e) {
      _teardown('接听发送失败');
      return;
    }
  }

  /// 中途加入进行中的群通话（knownGroupCalls 注册表驱动；占线/无房间
  /// 拒绝）。gc9：ended 展示态允许立即重进（用户挂断退出后马上点加入
  /// 不必等 2s 收尾；_endedTimer 由 phase guard 保证不误清新通话）
  Future<bool> joinGroupRoom(int groupId) async {
    final info = knownGroupCalls[groupId];
    final busy = isBusy && _phase != CallPhase.ended;
    if (info == null || busy) return false;
    _endedTimer?.cancel();
    _endedTimer = null;
    _isGroup = true;
    _groupId = groupId;
    _groupName = info.groupName;
    _peer = null;
    _type = info.callType;
    _callId = info.callId;
    endReason = null;
    activeSince = null;
    _resetRecoveryState();
    isCaller = false;
    _resetGroupSessionState({...info.participants, if (_self != null) _self!});
    _resetToggles(info.callType);
    await _beginGroupJoin();
    return true;
  }

  void rejectIncoming() {
    if (_phase != CallPhase.ringing || _callId == null) return;
    if (_isGroup) {
      _safeSendGroup('group_call_leave');
      _teardown('已拒绝');
      return;
    }
    final id = _callId!;
    final peer = _peer!;
    _safeSend('call_reject', peer, id);
    _teardown('已拒绝');
  }

  void cancelOutgoing() {
    if (_phase != CallPhase.calling || _callId == null) return;
    if (_isGroup) {
      _safeSendGroup('group_call_leave');
      _teardown('已取消');
      return;
    }
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
    if (_isGroup) {
      _safeSendGroup('group_call_leave');
      _teardown('通话已结束');
      return;
    }
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
  // 断线恢复（opt9：信令断线宽限期 + ICE 自愈 + 群重入）
  // ============================================================

  void _resetRecoveryState() {
    reconnecting = false;
    hint = null;
    renegotiating = false;
    rejoinInProgress = false;
    _groupMeshSyncing = false;
    iceRestartAttempts = 0;
    reconnectTimer?.cancel();
    reconnectTimer = null;
    groupFallbackTimer?.cancel();
    groupFallbackTimer = null;
    _peerOfferInFlight.clear();
    _lastPcState = '';
  }

  void _startReconnectTimer() {
    reconnectTimer?.cancel();
    reconnectTimer = Timer(reconnectTimeout, () {
      if (_phase != CallPhase.connecting && _phase != CallPhase.active) {
        return;
      }
      if (_callId == null) return;
      if (_isGroup) {
        _safeSendGroup('group_call_leave');
      } else if (_peer != null) {
        _safeSend('call_hangup', _peer!, _callId!);
      }
      _teardown('重连超时，通话结束');
    });
  }

  void _markReconnecting(String message) {
    if (_phase != CallPhase.connecting && _phase != CallPhase.active) return;
    reconnecting = true;
    hint = message;
    _startReconnectTimer();
    notifyListeners();
  }

  void _clearRecovery({bool notify = false}) {
    reconnectTimer?.cancel();
    reconnectTimer = null;
    groupFallbackTimer?.cancel();
    groupFallbackTimer = null;
    reconnecting = false;
    hint = null;
    renegotiating = false;
    rejoinInProgress = false;
    _groupMeshSyncing = false;
    iceRestartAttempts = 0;
    if (notify) notifyListeners();
  }

  /// 新恢复触发源（call_peer_back / call_resume_request / 信令重连）：
  /// 清空上一轮恢复预算与在途协商标记——旧预算不应让对端回线触发的新
  /// 恢复直接挂断。connected/成功 answer 的既有清零逻辑不受影响。
  void _beginNewRecoveryTrigger() {
    iceRestartAttempts = 0;
    renegotiating = false;
  }

  /// 信令断线重连成功（SocketService._reconnectLoop 在 _relogin 成功后
  /// 调用）：媒体 P2P 直连不依赖信令——PC 存活（connected）时无需恢复；
  /// 否则 1:1 按角色分流恢复（caller 重协商 offer / callee 请求 resume），
  /// 群通话重新加入房间并重建 mesh。phase 门控前置：ringing/calling
  /// （未接听/等待接听）不重入、不收场。
  void onSignalingReconnected() {
    if (!isInLiveCall) return;
    if (_phase != CallPhase.connecting && _phase != CallPhase.active) return;
    _beginNewRecoveryTrigger();
    if (_isGroup) {
      unawaited(_rejoinGroupCall());
      return;
    }
    if (_lastPcState == 'connected') {
      _clearRecovery(notify: true);
      return;
    }
    if (isCaller) {
      unawaited(_recoverAsCaller());
    } else {
      unawaited(_requestResume());
      _markReconnecting('正在请求恢复通话…');
    }
  }

  /// caller 侧恢复：ICE restart + 重新发起 offer（防 glare：全场只有
  /// caller 发 offer；renegotiating 去重并发触发）。恢复次数超限 →
  /// hangup 收场。
  Future<void> _recoverAsCaller() async {
    if (_phase != CallPhase.connecting && _phase != CallPhase.active) return;
    if (renegotiating) return;
    if (iceRestartAttempts >= maxIceRestartAttempts) {
      if (_peer != null && _callId != null) {
        await _safeSend('call_hangup', _peer!, _callId!);
      }
      _teardown('连接恢复失败');
      return;
    }
    renegotiating = true;
    iceRestartAttempts++;
    reconnecting = true;
    hint = '正在恢复连接…';
    _startReconnectTimer();
    notifyListeners();
    try {
      final capable =
          _engine is IceRestartCapable ? _engine as IceRestartCapable : null;
      if (capable != null) {
        await capable.restartIce();
      }
      // 重协商候选缓冲重置：初次协商后 _remoteDescSet=true，ICE restart
      // 的新候选若直接 addRemoteCandidate 会打到旧 remote description
      // （异常被吞导致恢复失败）——answer 前缓冲，answer 后冲刷
      _remoteDescSet = false;
      _pendingCandidates.clear();
      final offer = await _engine.createOffer();
      await _signaling.sendCall('call_offer', _peer!, _callId!,
          body: jsonEncode(offer));
    } catch (_) {
      renegotiating = false;
      notifyListeners();
    }
  }

  /// callee 侧恢复：请求 caller 重新协商（caller 收到后发新 offer，
  /// 本端以既有 PC answer——不发起 offer，避免 offer 碰撞）
  Future<void> _requestResume() async {
    if (_peer == null || _callId == null) return;
    try {
      await _signaling.sendCall('call_resume_request', _peer!, _callId!);
    } catch (_) {}
  }

  /// ICE failed 恢复入口：最多 maxIceRestartAttempts 次恢复，超限 hangup
  /// 收场（旧实现 failed 立即挂断——更新为恢复语义）。重复 failed 表示
  /// 上一轮协商已死，重置 renegotiating 守卫允许再次发起。
  Future<void> _recoverAfterFailure() async {
    if (iceRestartAttempts >= maxIceRestartAttempts) {
      if (_callId != null && _peer != null) {
        await _safeSend('call_hangup', _peer!, _callId!);
      }
      _teardown('连接失败');
      return;
    }
    renegotiating = false;
    if (isCaller) {
      await _recoverAsCaller();
    } else {
      await _requestResume();
      _markReconnecting('连接失败，正在请求恢复…');
    }
  }

  /// 群通话重入：knownGroupCalls 校验房间仍在 → group_call_join 重入 →
  /// joined[self] 广播触发既有 _startGroupOffers 逐边重建 mesh；2 秒
  /// fallback 对尚无会话的远端直接发 offer；房间已结束 → teardown。
  /// 35s 恢复兜底定时器全程保留（join 后无任何 peer 连上时收场，不永久
  /// connecting）；rejoinInProgress 保持到 mesh 重建完成/超时收场，期间
  /// 重复的 onSignalingReconnected 不再重入。
  Future<void> _rejoinGroupCall() async {
    if (rejoinInProgress) return;
    rejoinInProgress = true;
    final gid = _groupId;
    final id = _callId;
    if (gid == null || id == null) {
      rejoinInProgress = false;
      _teardown('通话已结束');
      return;
    }
    final info = knownGroupCalls[gid];
    if (info == null || info.callId != id) {
      _teardown('通话已结束');
      return;
    }
    for (final peerState in _groupPeers.values) {
      final session = peerState.session;
      if (session != null) {
        try {
          // 逐个 await（1s 超时防卡死）：确保旧 PC 关闭完成后才 clear
          // 并重建 mesh——旧 session 的迟到来回调不得命中新 session
          await session.close().timeout(const Duration(seconds: 1));
        } catch (_) {}
      }
    }
    _groupPeers.clear();
    _calleeMediaReady =
        _engine.hasLocalMedia ? Future<void>.value() : _prepareGroupMedia();
    _reachedConnecting = true;
    _setPhase(CallPhase.connecting);
    reconnecting = true;
    hint = '正在重新加入群通话…';
    _startReconnectTimer();
    notifyListeners();
    await _safeSendGroup('group_call_join');
    groupFallbackTimer?.cancel();
    groupFallbackTimer = Timer(groupRejoinFallback, () {
      groupFallbackTimer = null;
      if (_phase != CallPhase.connecting) return;
      unawaited(_offerMissingGroupPeers());
    });
  }

  /// 重入 fallback：仅对尚无 mesh 边会话的远端发 offer（joined[self]
  /// 已触发的边不重复协商，避免打断在途 answer）；mesh 重建在途时让路
  /// （_startGroupOffers 负责本轮建边）；完成即复位重入 guard
  Future<void> _offerMissingGroupPeers() async {
    try {
      if (_groupMeshSyncing) return;
      await (_calleeMediaReady ?? Future<void>.value());
      if (_groupMeshSyncing) return;
      if (_phase != CallPhase.connecting || !_isGroup) return;
      if (!_engine.hasLocalMedia) return;
      for (final p in remotePeers) {
        if (_groupMeshSyncing) return;
        if (_groupPeers[p]?.session == null) {
          await _createPeerAndOffer(p);
        }
      }
      notifyListeners();
    } catch (_) {
    } finally {
      if (!_groupMeshSyncing) rejoinInProgress = false;
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
        _isGroup = false;
        _groupId = null;
        _groupName = null;
        _peer = from;
        _callId = id;
        _type = (header['call_type'] as String?) == 'video'
            ? CallType.video
            : CallType.audio;
        endReason = null;
        activeSince = null;
        _remoteDescSet = false;
        _pendingCandidates.clear();
        _resetRecoveryState();
        isCaller = false;
        _resetToggles(_type!);
        _setPhase(CallPhase.ringing);
        _startRingtone();
        _startIncomingRingTimer();
        break;
      case 'call_accept':
        if (_isGroup) break;
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
        if (id != _callId ||
            _phase == CallPhase.idle ||
            _phase == CallPhase.ended) {
          return;
        }
        _teardown(_phase == CallPhase.ringing ? '对方已取消' : '对方已断开');
        break;
      case 'call_hangup':
        if (id != _callId || _phase == CallPhase.idle) return;
        _teardown(
            header['reason'] == 'reconnect_timeout' ? '对方重连超时，通话结束' : '通话已结束');
        break;
      case 'call_failed':
        if (id != _callId) return;
        _teardown(_failText(header['reason'] as String?));
        break;
      case 'call_suspended':
        if (id != _callId || _isGroup) return;
        if (_phase == CallPhase.connecting || _phase == CallPhase.active) {
          _markReconnecting('对方连接断开，等待重连…');
        }
        break;
      case 'call_peer_back':
        if (id != _callId || _isGroup) return;
        if (_phase != CallPhase.connecting && _phase != CallPhase.active) {
          return;
        }
        if (_lastPcState == 'connected') {
          _clearRecovery(notify: true);
          return;
        }
        _beginNewRecoveryTrigger();
        if (isCaller) {
          unawaited(_recoverAsCaller());
        } else {
          _markReconnecting('对方已恢复连接，正在同步…');
        }
        break;
      case 'call_resume_request':
        if (id != _callId || _isGroup || !isCaller) return;
        if (_phase != CallPhase.connecting && _phase != CallPhase.active) {
          return;
        }
        _beginNewRecoveryTrigger();
        unawaited(_recoverAsCaller());
        break;
      case 'call_offer':
        if (_isGroup) {
          _handleGroupOffer(header, body);
          break;
        }
        if (id != _callId) return;
        if (_phase != CallPhase.connecting && _phase != CallPhase.active) {
          return;
        }
        _handleOffer(body);
        break;
      case 'call_answer':
        if (_isGroup) {
          _handleGroupAnswer(header, body);
          break;
        }
        if (id != _callId) return;
        if (_phase != CallPhase.connecting && _phase != CallPhase.active) {
          return;
        }
        _handleAnswer(body);
        break;
      case 'call_ice':
        if (_isGroup) {
          _handleGroupCandidate(header, body);
          break;
        }
        if (id != _callId ||
            (_phase != CallPhase.connecting && _phase != CallPhase.active)) {
          return;
        }
        _handleCandidate(body);
        break;
      case 'group_call_invite':
        _handleGroupInvite(header);
        break;
      case 'group_call_joined':
        unawaited(_handleGroupJoined(header));
        break;
      case 'group_call_left':
        _handleGroupLeft(header);
        break;
      case 'group_call_media':
        _handleGroupMediaState(header);
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
      case 'not_member':
        return '您不在该群组中';
      case 'full':
        return '群通话人数已满';
      default:
        return '呼叫失败';
    }
  }

  // ============================================================
  // 一对一媒体协商（阶段 R1，语义不变）
  // ============================================================

  Future<void> _startCallerMedia() async {
    final id = _callId!;
    final peer = _peer!;
    _reachedConnecting = true;
    _setPhase(CallPhase.connecting);
    try {
      await _engine.open(video: _type == CallType.video);
      await _engine.setSpeakerphoneOn(speakerOn);
      final offer = await _engine.createOffer();
      await _signaling.sendCall('call_offer', peer, id,
          body: jsonEncode(offer));
    } catch (e) {
      await _safeSend('call_hangup', peer, id);
      _teardown('无法建立通话');
    }
  }

  Future<void> _handleOffer(Uint8List body) async {
    final id = _callId!;
    final peer = _peer!;
    try {
      await (_calleeMediaReady ?? Future<void>.value());
      if (_phase != CallPhase.connecting && _phase != CallPhase.active) {
        return;
      }
      final offer = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      if (_remoteDescSet) {
        _pendingCandidates.clear();
      }
      _remoteDescSet = false;
      await _engine.setRemoteOffer(offer);
      final answer = await _engine.createAnswer();
      await _signaling.sendCall('call_answer', peer, id,
          body: jsonEncode(answer));
      await _flushCandidates();
      _clearRecovery(notify: true);
    } catch (e) {
      await _safeSend('call_hangup', peer, id);
      _teardown('无法建立通话');
    }
  }

  Future<void> _handleAnswer(Uint8List body) async {
    try {
      final answer = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      await _engine.setRemoteAnswer(answer);
      await _flushCandidates();
      // 仅首次进入 active 记时——active 态重协商恢复的 answer 不得把
      // 通话时长归零
      if (activeSince == null || _phase != CallPhase.active) {
        activeSince = DateTime.now();
      }
      _clearRecovery(notify: false);
      _setPhase(CallPhase.active);
    } catch (e) {
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
  // 群通话（阶段 R2）
  // ============================================================

  void _updateGroupRegistry(int gid, String callId,
      {required String groupName,
      required List<String> participants,
      required bool ended,
      CallType? callType}) {
    final existing = knownGroupCalls[gid];
    if (ended) {
      if (existing != null && existing.callId == callId) {
        knownGroupCalls.remove(gid);
      }
      return;
    }
    knownGroupCalls[gid] = GroupCallRoomInfo(
      groupId: gid,
      groupName:
          groupName.isNotEmpty ? groupName : (existing?.groupName ?? '群聊'),
      callId: callId,
      callType: callType ?? existing?.callType ?? CallType.audio,
      participants: List.unmodifiable(participants),
    );
  }

  void _handleGroupInvite(Map<String, dynamic> header) {
    final from = header['from'] as String?;
    final id = header['call_id'] as String?;
    final gid = int.tryParse('${header['group_id']}');
    if (from == null || id == null || gid == null) return;
    if (isBusy) {
      // 占线自动回拒（服务端已对忙线成员静默跳过，此处为双保险）
      _safeSendGroup('group_call_leave', groupId: gid, callId: id);
      return;
    }
    _isGroup = true;
    _groupId = gid;
    _groupName = (header['group_name'] as String?) ?? '群聊';
    _peer = null;
    _callId = id;
    _type = (header['call_type'] as String?) == 'video'
        ? CallType.video
        : CallType.audio;
    endReason = null;
    activeSince = null;
    _resetRecoveryState();
    isCaller = false;
    _resetGroupSessionState({from});
    _resetToggles(_type!);
    _updateGroupRegistry(gid, id,
        groupName: _groupName!,
        participants: [from],
        ended: false,
        callType: _type);
    _setPhase(CallPhase.ringing);
    _startRingtone();
    _startIncomingRingTimer();
  }

  Future<void> _handleGroupJoined(Map<String, dynamic> header) async {
    final from = header['from'] as String?;
    final id = header['call_id'] as String?;
    final gid = int.tryParse('${header['group_id']}');
    if (from == null || id == null || gid == null) return;
    final list = (header['participants'] as String? ?? '')
        .split(',')
        .where((s) => s.isNotEmpty)
        .toList();
    final involved = _isGroup && id == _callId;
    if (involved) {
      _updateGroupRegistry(gid, id,
          groupName: _groupName ?? '',
          participants: list,
          ended: false,
          callType: _type);
    } else {
      _updateGroupRegistry(gid, id,
          groupName: (header['group_name'] as String?) ?? '',
          participants: list,
          ended: false,
          callType: (header['call_type'] as String?) == 'video'
              ? CallType.video
              : CallType.audio);
    }
    if (!involved) return;
    _participants
      ..clear()
      ..addAll(list);
    if (from == _self) {
      // 多端收敛：同账号其他设备已加入本房间 → 本设备停止响铃
      if (_phase == CallPhase.ringing) {
        _teardown('已在其他设备接听');
        return;
      }
      // 本机加入确认：向既有成员逐对发起 offer（mesh 规则：新加入者
      // 发起协商，避免 offer 碰撞）。断线重入场景先清理已不在房间的
      // 陈旧 mesh 边（逐个 await close，旧 session 的回调不得命中
      // 新 session）
      final stale =
          _groupPeers.keys.where((p) => !_participants.contains(p)).toList();
      for (final p in stale) {
        final old = _groupPeers.remove(p);
        final session = old?.session;
        if (session != null) {
          try {
            await session.close().timeout(const Duration(seconds: 1));
          } catch (_) {}
        }
      }
      if (_phase != CallPhase.connecting) {
        rejoinInProgress = false;
        return;
      }
      // joined[self] 即 mesh 重建开工——取消 2s fallback（媒体准备或
      // 逐边建会话超过 2s 时，fallback 与本流程会在同一 peer 上重复
      // createPeerSession/offer）
      groupFallbackTimer?.cancel();
      groupFallbackTimer = null;
      // mesh 重建完成（或 teardown）后复位重入 guard——期间重复的
      // onSignalingReconnected 不再进入重入流程
      unawaited(_startGroupOffers().whenComplete(() {
        rejoinInProgress = false;
      }));
      return;
    }
    if (_phase == CallPhase.calling) {
      // 主叫：首个成员加入即转接通中并预采媒体（offer 到达前就绪）
      _ringTimer?.cancel();
      _setPhase(CallPhase.connecting);
      _calleeMediaReady = _prepareGroupMedia();
    }
    notifyListeners();
  }

  Future<void> _prepareGroupMedia() async {
    _reachedConnecting = true;
    try {
      await _engine.ensureMedia(video: _type == CallType.video);
      await _engine.setSpeakerphoneOn(speakerOn);
    } catch (e) {
      await _safeSendGroup('group_call_leave');
      _teardown('无法访问麦克风或摄像头');
    }
  }

  Future<void> _startGroupOffers() async {
    _groupMeshSyncing = true;
    try {
      await (_calleeMediaReady ?? Future<void>.value());
      if (_phase != CallPhase.connecting || !_isGroup) return;
      // R2 gc2 真机排障加固：就绪门通过后终局校验本地轨道（Windows
      // Release 实测发出过无 m-line 的 142 字节空 offer 且零 ICE——
      // 无论媒体门被何种路径绕过，都不再发出空壳协商）
      if (!_engine.hasLocalMedia) {
        await _safeSendGroup('group_call_leave');
        _teardown('无法访问麦克风或摄像头');
        return;
      }
      for (final p in remotePeers) {
        await _createPeerAndOffer(p);
      }
      notifyListeners();
    } catch (e) {
      await _safeSendGroup('group_call_leave');
      _teardown('无法建立通话');
    } finally {
      _groupMeshSyncing = false;
    }
  }

  Future<void> _createPeerAndOffer(String peerId) async {
    final inFlight = _peerOfferInFlight[peerId];
    if (inFlight != null) {
      await inFlight;
      return;
    }
    final future = _doCreatePeerAndOffer(peerId);
    _peerOfferInFlight[peerId] = future;
    try {
      await future;
    } finally {
      if (identical(_peerOfferInFlight[peerId], future)) {
        _peerOfferInFlight.remove(peerId);
      }
    }
  }

  Future<void> _doCreatePeerAndOffer(String peerId) async {
    final callId = _callId;
    final old = _groupPeers.remove(peerId);
    if (old != null) {
      try {
        await old.session?.close();
      } catch (_) {}
    }
    final session = await _engine.createPeerSession(peerId);
    if (!_isGroup ||
        callId == null ||
        _callId != callId ||
        _phase == CallPhase.ended ||
        _phase == CallPhase.idle) {
      try {
        await session.close();
      } catch (_) {}
      return;
    }
    _groupPeers[peerId] = _GroupPeer(session: session);
    final offer = await session.createOffer();
    if (!_isGroup ||
        _callId != callId ||
        _phase == CallPhase.ended ||
        _phase == CallPhase.idle) {
      if (identical(_groupPeers[peerId]?.session, session)) {
        _groupPeers.remove(peerId);
      }
      try {
        await session.close();
      } catch (_) {}
      return;
    }
    await _signaling.sendCall('call_offer', peerId, callId,
        body: jsonEncode(offer));
  }

  Future<void> _handleGroupOffer(
      Map<String, dynamic> header, Uint8List body) async {
    final from = header['from'] as String?;
    final id = header['call_id'] as String?;
    if (from == null || from == _self || id == null || id != _callId) return;
    if (_phase != CallPhase.calling &&
        _phase != CallPhase.connecting &&
        _phase != CallPhase.active) {
      return;
    }
    try {
      await (_calleeMediaReady ?? Future<void>.value());
      if (_phase != CallPhase.connecting && _phase != CallPhase.active) return;
      final offer = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      final old = _groupPeers.remove(from);
      if (old != null) {
        try {
          await old.session?.close();
        } catch (_) {}
      }
      final session = await _engine.createPeerSession(from);
      final state = _GroupPeer(session: session);
      _groupPeers[from] = state;
      await session.setRemoteOffer(offer);
      final answer = await session.createAnswer();
      await _signaling.sendCall('call_answer', from, id,
          body: jsonEncode(answer));
      state.remoteDescSet = true;
      await _flushPeerCandidates(state);
      notifyListeners();
    } catch (e) {
      // 单条 mesh 边失败不拖垮整场群通话（其余边照常协商）
    }
  }

  Future<void> _handleGroupAnswer(
      Map<String, dynamic> header, Uint8List body) async {
    final from = header['from'] as String?;
    final id = header['call_id'] as String?;
    if (from == null || id != _callId) return;
    final state = _groupPeers[from];
    if (state?.session == null) return;
    try {
      final answer = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      await state!.session!.setRemoteAnswer(answer);
      state.remoteDescSet = true;
      await _flushPeerCandidates(state);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _handleGroupCandidate(
      Map<String, dynamic> header, Uint8List body) async {
    final from = header['from'] as String?;
    if (from == null || header['call_id'] != _callId) return;
    final state = _groupPeers.putIfAbsent(from, () => _GroupPeer());
    try {
      final candidate = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      if (state.remoteDescSet && state.session != null) {
        await state.session!.addRemoteCandidate(candidate);
      } else {
        state.pendingCandidates.add(candidate);
      }
    } catch (_) {}
  }

  Future<void> _flushPeerCandidates(_GroupPeer state) async {
    final pending = List.of(state.pendingCandidates);
    state.pendingCandidates.clear();
    for (final candidate in pending) {
      try {
        await state.session?.addRemoteCandidate(candidate);
      } catch (_) {}
    }
  }

  void _handleGroupLeft(Map<String, dynamic> header) {
    final from = header['from'] as String?;
    final id = header['call_id'] as String?;
    final gid = int.tryParse('${header['group_id']}');
    final ended = header['ended'] == '1';
    if (from == null || id == null || gid == null) return;
    final list = (header['participants'] as String? ?? '')
        .split(',')
        .where((s) => s.isNotEmpty)
        .toList();
    final involved = _isGroup && id == _callId;
    _updateGroupRegistry(gid, id,
        groupName: _groupName ?? knownGroupCalls[gid]?.groupName ?? '',
        participants: list,
        ended: ended);
    if (!involved) return;
    if (ended) {
      if (_phase == CallPhase.idle || _phase == CallPhase.ended) return;
      _teardown('通话已结束');
      return;
    }
    if (from == _self) {
      // 多端收敛：同账号其他设备已拒绝/已超时 → 本设备停止响铃
      if (_phase == CallPhase.ringing &&
          (header['reason'] == 'declined' || header['reason'] == 'timeout')) {
        _teardown('已在其他设备处理');
      }
      return;
    }
    if (_phase == CallPhase.idle || _phase == CallPhase.ended) return;
    _participants.remove(from);
    _peerMicMuted.remove(from);
    _peerCamOff.remove(from);
    final peerState = _groupPeers.remove(from);
    if (peerState != null) {
      unawaited(() async {
        try {
          await peerState.session?.close();
        } catch (_) {}
      }());
    }
    notifyListeners();
  }

  void _handleGroupMediaState(Map<String, dynamic> header) {
    final from = header['from'] as String?;
    if (from == null ||
        from == _self ||
        !_isGroup ||
        header['call_id'] != _callId) {
      return;
    }
    _peerMicMuted[from] = header['mic'] == '1';
    _peerCamOff[from] = header['cam'] == '1';
    notifyListeners();
  }

  /// 群通话瓦片渲染器接线（CallScreen 按参与者增删同步调用）
  void attachPeerRenderer(String peerId, RTCVideoRenderer? renderer) {
    _engine.peerSession(peerId)?.attachRenderer(renderer);
  }

  // ============================================================
  // 引擎回调（CallEngineListener）
  // ============================================================

  @override
  void onLocalCandidate(Map<String, Object?> candidate) {
    if (_isGroup) return;
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
    if (_isGroup) return;
    _lastPcState = state;
    // ICE 连通：被叫（无 answer 回执驱动）据此从接通中转通话中
    if (state == 'connected') {
      _clearRecovery(notify: _phase != CallPhase.connecting);
      if (_phase == CallPhase.connecting) {
        activeSince ??= DateTime.now();
        _setPhase(CallPhase.active);
      }
      return;
    }
    if (state == 'disconnected' &&
        (_phase == CallPhase.connecting || _phase == CallPhase.active)) {
      _markReconnecting('网络波动，正在重连…');
      return;
    }
    if (state == 'failed' &&
        (_phase == CallPhase.connecting || _phase == CallPhase.active)) {
      unawaited(_recoverAfterFailure());
    }
  }

  @override
  void onPeerLocalCandidate(String peerId, Map<String, Object?> candidate) {
    if (!_isGroup || _callId == null) return;
    if (_phase != CallPhase.calling &&
        _phase != CallPhase.connecting &&
        _phase != CallPhase.active) {
      return;
    }
    _safeSend('call_ice', peerId, _callId!, body: jsonEncode(candidate));
  }

  @override
  void onPeerRemoteStream(String peerId) {
    notifyListeners();
  }

  @override
  void onPeerConnectionState(String peerId, String state) {
    if (!_isGroup) return;
    if (state == 'connected') {
      final wasConnecting = _phase == CallPhase.connecting;
      _clearRecovery(notify: !wasConnecting);
      if (wasConnecting) {
        activeSince ??= DateTime.now();
        _setPhase(CallPhase.active);
      }
      return;
    }
    if (state == 'failed') {
      final peerState = _groupPeers.remove(peerId);
      if (peerState != null) {
        unawaited(() async {
          try {
            await peerState.session?.close();
          } catch (_) {}
        }());
      }
      final hasRemote = _participants.any((m) => m != _self);
      if (hasRemote &&
          _groupPeers.isEmpty &&
          (_phase == CallPhase.connecting || _phase == CallPhase.active)) {
        _safeSendGroup('group_call_leave');
        _teardown('连接失败');
        return;
      }
      notifyListeners();
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

  Future<void> _safeSendGroup(String type,
      {int? groupId, String? callId, String? mic, String? cam}) async {
    final gid = groupId ?? _groupId;
    final id = callId ?? _callId;
    if (gid == null || id == null) return;
    try {
      await _signaling.sendGroupCall(type, gid, id, mic: mic, cam: cam);
    } catch (_) {}
  }

  void _teardown(String reason) {
    _ringTimer?.cancel();
    _ringTimer = null;
    _incomingRingTimer?.cancel();
    _incomingRingTimer = null;
    _resetRecoveryState();
    _stopRingtone();
    // 曾接通的通话结束播挂断音（ringing 未接通阶段只停铃）
    if (_reachedConnecting) unawaited(_callSound.playHangup());
    _reachedConnecting = false;
    // R2 gc2：清除跨场残留的媒体就绪门（旧 future 已完成，会让下一场
    // 通话的 await 立即通过——空 offer 竞态的来源之一）
    _calleeMediaReady = null;
    endReason = reason;
    micMuted = false;
    cameraOff = false;
    for (final peerState in _groupPeers.values) {
      final session = peerState.session;
      if (session != null) {
        unawaited(() async {
          try {
            await session.close();
          } catch (_) {}
        }());
      }
    }
    _groupPeers.clear();
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
        _isGroup = false;
        _groupId = null;
        _groupName = null;
        _participants.clear();
        _peerMicMuted.clear();
        _peerCamOff.clear();
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
    _incomingRingTimer?.cancel();
    reconnectTimer?.cancel();
    groupFallbackTimer?.cancel();
    _groupMeshSyncing = false;
    _engine.close();
    super.dispose();
  }
}
