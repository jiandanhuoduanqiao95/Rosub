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
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show MediaStream, RTCVideoRenderer;

import 'call_engine.dart';

enum CallType { audio, video }

enum CallPhase { idle, calling, ringing, connecting, active, ended }

/// 群通话信令接口（SocketService 实现；与 sendCall 一样走既有发送队列）
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
  })  : _signaling = signaling,
        _engine = engine ?? WebRtcCallEngine(),
        _selfUsername = selfUsername ?? (() => null) {
    _engine.setListener(this);
  }

  static const ringTimeout = Duration(seconds: 45);
  static const endedDisplayDuration = Duration(seconds: 2);

  final CallSignaling _signaling;
  final CallEngine _engine;
  final String? Function() _selfUsername;

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

  // ---- R2 群通话状态 ----
  bool _isGroup = false;
  int? _groupId;
  String? _groupName;
  final Set<String> _participants = {};
  final Map<String, _GroupPeer> _groupPeers = {};
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
    // 微信式默认路由：语音通话听筒、视频通话外放
    speakerOn = type == CallType.video;
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
    _resetGroupSessionState({
      if (_self != null) _self!,
    });
    _resetToggles(type);
    _trace('startGroupCall group=$groupId type=$type room=$_callId');
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

  /// R2 群通话共用加入流程（acceptIncoming 群分支 / joinGroupRoom）：
  /// 媒体就绪门 + group_call_join，joined[self] 广播确认后逐对发起协商
  Future<void> _beginGroupJoin() async {
    final id = _callId!;
    final gid = _groupId!;
    _ringTimer?.cancel();
    _setPhase(CallPhase.connecting);
    _trace('group join room=$id');
    _calleeMediaReady = () async {
      try {
        _trace(
            'callee engine.ensureMedia(video=${_type == CallType.video}) start');
        await _engine.ensureMedia(video: _type == CallType.video);
        await _engine.setSpeakerphoneOn(speakerOn);
        _trace('callee engine.ensureMedia done');
      } catch (e) {
        _trace('callee engine.ensureMedia FAILED: $e');
        await _safeSendGroup('group_call_leave');
        _teardown('无法访问麦克风或摄像头');
      }
    }();
    try {
      await _signaling.sendGroupCall('group_call_join', gid, id);
      _trace('group_call_join sent');
    } catch (e) {
      _trace('group_call_join send FAILED: $e');
      _teardown('接听发送失败');
      return;
    }
  }

  /// 中途加入进行中的群通话（knownGroupCalls 注册表驱动；占线/无房间拒绝）
  Future<bool> joinGroupRoom(int groupId) async {
    final info = knownGroupCalls[groupId];
    if (info == null || isBusy) return false;
    _isGroup = true;
    _groupId = groupId;
    _groupName = info.groupName;
    _peer = null;
    _type = info.callType;
    _callId = info.callId;
    endReason = null;
    activeSince = null;
    _resetGroupSessionState({...info.participants, if (_self != null) _self!});
    _resetToggles(info.callType);
    _trace('joinGroupRoom group=$groupId room=${info.callId}');
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
        _resetToggles(_type!);
        _trace('incoming call_invite from=$from id=$id type=$_type');
        _setPhase(CallPhase.ringing);
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
        if (_isGroup) {
          _handleGroupOffer(header, body);
          break;
        }
        if (id != _callId || _phase != CallPhase.connecting) return;
        _handleOffer(body);
        break;
      case 'call_answer':
        if (_isGroup) {
          _handleGroupAnswer(header, body);
          break;
        }
        if (id != _callId || _phase != CallPhase.connecting) return;
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
        _handleGroupJoined(header);
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
    _resetGroupSessionState({from});
    _resetToggles(_type!);
    _updateGroupRegistry(gid, id,
        groupName: _groupName!,
        participants: [from],
        ended: false,
        callType: _type);
    _trace('group invite from=$from room=$id group=$gid type=$_type');
    _setPhase(CallPhase.ringing);
  }

  void _handleGroupJoined(Map<String, dynamic> header) {
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
      // 发起协商，避免 offer 碰撞）
      if (_phase != CallPhase.connecting) return;
      _startGroupOffers();
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
    try {
      _trace(
          'caller engine.ensureMedia(video=${_type == CallType.video}) start');
      await _engine.ensureMedia(video: _type == CallType.video);
      await _engine.setSpeakerphoneOn(speakerOn);
      _trace('caller engine.ensureMedia done');
    } catch (e) {
      _trace('caller engine.ensureMedia FAILED: $e');
      await _safeSendGroup('group_call_leave');
      _teardown('无法访问麦克风或摄像头');
    }
  }

  Future<void> _startGroupOffers() async {
    try {
      _trace(
          'group joined(self), creating offers to ${remotePeers.length} peers');
      await (_calleeMediaReady ?? Future<void>.value());
      if (_phase != CallPhase.connecting || !_isGroup) return;
      // R2 gc2 真机排障加固：就绪门通过后终局校验本地轨道（Windows
      // Release 实测发出过无 m-line 的 142 字节空 offer 且零 ICE——
      // 无论媒体门被何种路径绕过，都不再发出空壳协商）
      if (!_engine.hasLocalMedia) {
        _trace('group offers aborted: no local media tracks');
        await _safeSendGroup('group_call_leave');
        _teardown('无法访问麦克风或摄像头');
        return;
      }
      for (final p in remotePeers) {
        await _createPeerAndOffer(p);
      }
      notifyListeners();
    } catch (e) {
      _trace('group offers FAILED: $e');
      await _safeSendGroup('group_call_leave');
      _teardown('无法建立通话');
    }
  }

  Future<void> _createPeerAndOffer(String peerId) async {
    final old = _groupPeers.remove(peerId);
    if (old != null) {
      try {
        await old.session?.close();
      } catch (_) {}
    }
    final session = await _engine.createPeerSession(peerId);
    _groupPeers[peerId] = _GroupPeer(session: session);
    final offer = await session.createOffer();
    await _signaling.sendCall('call_offer', peerId, _callId!,
        body: jsonEncode(offer));
    _trace('group offer -> $peerId');
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
      _trace('group offer from=$from, waiting media');
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
      _trace('group answer -> $from');
      notifyListeners();
    } catch (e) {
      // 单条 mesh 边失败不拖垮整场群通话（其余边照常协商）
      _trace('group handleOffer from=$from FAILED: $e');
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
      _trace('group answer from=$from');
      notifyListeners();
    } catch (e) {
      _trace('group handleAnswer from=$from FAILED: $e');
    }
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
    _trace('peer=$peerId connectionState=$state phase=$_phase');
    if (state == 'connected') {
      if (_phase == CallPhase.connecting) {
        activeSince ??= DateTime.now();
        _setPhase(CallPhase.active);
      } else {
        notifyListeners();
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
    _trace('teardown: $reason (phase=$_phase)');
    _ringTimer?.cancel();
    _ringTimer = null;
    _endedTimer?.cancel();
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
    _engine.close();
    super.dispose();
  }
}
