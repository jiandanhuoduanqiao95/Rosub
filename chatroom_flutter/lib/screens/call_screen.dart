/// 阶段 R1：通话界面
///
/// ringing（来电：接听/拒绝）/ calling+connecting（去话：取消）/
/// active（通话中：挂断 + 视频画面 + 静音/免提/关画面 + 最小化）/
/// ended（结束原因，2s 自动返回）。
/// 语音/视频共用本界面：视频类型挂载远端全屏 + 本地小窗（可拖动，
/// Cover 满幅裁剪，微信式）。最小化=离开界面继续通话（ChatScreen
/// 显示悬浮返回条）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../platform/android_system.dart';
import '../platform/capabilities.dart';
import '../services/call_service.dart';

class CallScreen extends StatefulWidget {
  const CallScreen({super.key, required this.callService});

  final CallService callService;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  RTCVideoRenderer? _remoteRenderer;
  RTCVideoRenderer? _localRenderer;
  Timer? _ticker;
  bool _renderersReady = false;

  /// 本地小窗左上角位置（null=默认右上）；随拖动更新
  Offset? _pipOffset;

  /// 自动返回已执行标志（防 idle 通知重复 pop / 返回链递归）
  bool _autoPopped = false;

  CallService get _svc => widget.callService;

  @override
  void initState() {
    super.initState();
    _svc.addListener(_onPhaseChanged);
    _prepareRenderers();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _svc.phase == CallPhase.active) setState(() {});
    });
  }

  Future<void> _prepareRenderers() async {
    if (_svc.type != CallType.video) return;
    final remote = RTCVideoRenderer();
    final local = RTCVideoRenderer();
    try {
      await remote.initialize();
      await local.initialize();
    } catch (_) {
      return;
    }
    if (!mounted) {
      await remote.dispose();
      await local.dispose();
      return;
    }
    setState(() {
      _remoteRenderer = remote;
      _localRenderer = local;
      _renderersReady = true;
    });
    _svc.attachRenderers(remote: remote, local: local);
  }

  void _onPhaseChanged() {
    // pop 一律由本页执行（ChatScreen 不做 pop）：
    // - idle（服务 2s 后回 idle）→ 自动返回上一页；
    // - minimized → 用户"最小化（不挂断）"离开，ChatScreen 悬浮条接管。
    // 若 ChatScreen 也 pop 会与本页 idle 自返叠加成双 pop（r1s10 回归：
    // 连弹两层路由→导航栈弹空→黑屏卡死闪退）。
    if (mounted &&
        !_autoPopped &&
        (_svc.phase == CallPhase.idle || _svc.minimized)) {
      _autoPopped = true;
      Navigator.of(context).pop();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _svc.removeListener(_onPhaseChanged);
    _ticker?.cancel();
    final remote = _remoteRenderer;
    final local = _localRenderer;
    _svc.attachRenderers();
    Future.microtask(() async {
      remote?.srcObject = null;
      local?.srcObject = null;
      await remote?.dispose();
      await local?.dispose();
    });
    super.dispose();
  }

  Future<void> _accept() async {
    final granted = await AndroidSystem.requestCallPermissions(
        video: _svc.type == CallType.video);
    if (!granted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('需要麦克风/摄像头权限才能接听')),
        );
      }
      _svc.rejectIncoming();
      return;
    }
    await _svc.acceptIncoming();
  }

  String get _typeLabel => _svc.type == CallType.video ? '视频通话' : '语音通话';

  String get _statusText {
    switch (_svc.phase) {
      case CallPhase.calling:
        return '正在等待对方接听…';
      case CallPhase.ringing:
        return '邀请您$_typeLabel';
      case CallPhase.connecting:
        return '接通中…';
      case CallPhase.active:
        return _durationText;
      case CallPhase.ended:
        return _svc.endReason ?? '通话已结束';
      case CallPhase.idle:
        return '';
    }
  }

  String get _durationText {
    final since = _svc.activeSince;
    if (since == null) return '00:00';
    final secs = DateTime.now().difference(since).inSeconds;
    final m = (secs ~/ 60).toString().padLeft(2, '0');
    final s = (secs % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final phase = _svc.phase;
    final showVideo = _renderersReady && phase == CallPhase.active;
    final showControls =
        phase == CallPhase.connecting || phase == CallPhase.active;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // 结束/idle 态直接 pop（maybePop 会被本页 canPop:false 拦截造成递归）
        final action = switch (phase) {
          CallPhase.ringing => _svc.rejectIncoming,
          CallPhase.calling => _svc.cancelOutgoing,
          CallPhase.connecting || CallPhase.active => _svc.hangup,
          CallPhase.ended || CallPhase.idle => () {
              if (!_autoPopped) {
                _autoPopped = true;
                Navigator.of(context).pop();
              }
            },
        };
        action();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF16181C),
        body: Stack(
          children: [
            if (showVideo && _remoteRenderer != null)
              Positioned.fill(
                child: RTCVideoView(_remoteRenderer!,
                    objectFit:
                        RTCVideoViewObjectFit.RTCVideoViewObjectFitContain),
              ),
            // 必须 Positioned.fill：Stack 非定位子项收 loose 约束且默认
            // 左上对齐，SafeArea/Column 会收缩到最宽一行文字的宽度
            // （真机二轮：整页内容贴左不对齐的根因）
            Positioned.fill(
              child: SafeArea(
                child: Column(
                  children: [
                    // R1 真机十轮：最小化（离开不挂断，微信式）——仅媒体
                    // 已建立的阶段提供；calling/ringing 仍走取消/拒绝
                    Align(
                      alignment: Alignment.centerLeft,
                      child: showControls
                          ? _circleIconButton(
                              icon: Icons.keyboard_arrow_left_rounded,
                              tooltip: '最小化（不挂断）',
                              onTap: _svc.minimize,
                            )
                          : const SizedBox(height: 44, width: 52),
                    ),
                    Text(
                      _svc.peer ?? '',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _typeLabel,
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: .6)),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _statusText,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: .8),
                          fontSize: 15),
                    ),
                    const Spacer(),
                    _buildControls(phase),
                    const SizedBox(height: 48),
                  ],
                ),
              ),
            ),
            // 本地小窗：可拖动 + Cover 满幅裁剪（真机十轮：原 Contain 在
            // 竖框内上下留黑边；微信式小窗应满幅）
            if (showVideo && _localRenderer != null) _buildLocalPip(context),
          ],
        ),
      ),
    );
  }

  Offset _defaultPipOffset(Size screen) =>
      Offset(screen.width - 110 - 16, 96);

  Offset _clampPip(Offset o, Size screen) => Offset(
        o.dx.clamp(8.0, screen.width - 110 - 8),
        o.dy.clamp(8.0, screen.height - 160 - 120),
      );

  Widget _buildLocalPip(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final pos = _clampPip(_pipOffset ?? _defaultPipOffset(screen), screen);
    return Positioned(
      left: pos.dx,
      top: pos.dy,
      child: GestureDetector(
        onPanUpdate: (details) => setState(() {
          _pipOffset = _clampPip(
              (_pipOffset ?? _defaultPipOffset(screen)) + details.delta,
              screen);
        }),
        child: Container(
          width: 110,
          height: 160,
          decoration: BoxDecoration(
            color: Colors.black26,
            borderRadius: BorderRadius.circular(12),
            border:
                Border.all(color: Colors.white.withValues(alpha: .2)),
          ),
          clipBehavior: Clip.antiAlias,
          child: _svc.cameraOff
              ? const ColoredBox(
                  color: Colors.black54,
                  child: Center(
                    child: Icon(Icons.videocam_off_rounded,
                        color: Colors.white54, size: 30),
                  ),
                )
              : RTCVideoView(_localRenderer!,
                  mirror: true,
                  objectFit:
                      RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
        ),
      ),
    );
  }

  Widget _buildControls(CallPhase phase) {
    switch (phase) {
      case CallPhase.ringing:
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _roundButton(
              icon: Icons.call_end,
              color: Colors.red,
              onPressed: _svc.rejectIncoming,
            ),
            _roundButton(
              icon: Icons.call,
              color: Colors.green,
              onPressed: _accept,
            ),
          ],
        );
      case CallPhase.calling:
        return _roundButton(
          icon: Icons.call_end,
          color: Colors.red,
          onPressed: _svc.cancelOutgoing,
        );
      case CallPhase.connecting:
      case CallPhase.active:
        // 微信式控制排：静音麦克风 / 免提（移动端）/ 关摄像头（视频）/ 挂断
        final platform = effectiveTargetPlatform();
        final showSpeaker = platform == TargetPlatform.android ||
            platform == TargetPlatform.iOS;
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _toggleButton(
              icon: _svc.micMuted
                  ? Icons.mic_off_rounded
                  : Icons.mic_rounded,
              active: _svc.micMuted,
              onTap: _svc.toggleMic,
            ),
            if (showSpeaker)
              _toggleButton(
                icon: _svc.speakerOn
                    ? Icons.volume_up_rounded
                    : Icons.volume_down_rounded,
                active: _svc.speakerOn,
                onTap: _svc.toggleSpeaker,
              ),
            if (_svc.type == CallType.video)
              _toggleButton(
                icon: _svc.cameraOff
                    ? Icons.videocam_off_rounded
                    : Icons.videocam_rounded,
                active: _svc.cameraOff,
                onTap: _svc.toggleCamera,
              ),
            _roundButton(
              icon: Icons.call_end,
              color: Colors.red,
              onPressed: _svc.hangup,
            ),
          ],
        );
      case CallPhase.ended:
        return const CircularProgressIndicator(color: Colors.white54);
      case CallPhase.idle:
        return const SizedBox.shrink();
    }
  }

  Widget _roundButton({
    required IconData icon,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: color,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Icon(icon, color: Colors.white, size: 30),
        ),
      ),
    );
  }

  /// 开关类圆钮：置位态白底黑图标（微信式按下高亮），否则半透明白图标
  Widget _toggleButton({
    required IconData icon,
    required bool active,
    required VoidCallback onTap,
  }) {
    return Material(
      color: active ? Colors.white : Colors.white24,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Icon(icon,
              color: active ? Colors.black87 : Colors.white, size: 26),
        ),
      ),
    );
  }

  /// 小圆图标钮（最小化等顶角控件）
  Widget _circleIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white24,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(icon, color: Colors.white, size: 26),
          ),
        ),
      ),
    );
  }
}

/// 发起通话的统一入口（ChatScreen 头部按钮调用）：
/// 先按类型请求运行时权限（Android），再进入状态机。
Future<void> startOutgoingCall(
  BuildContext context,
  CallService callService,
  String peer,
  CallType type,
) async {
  final granted =
      await AndroidSystem.requestCallPermissions(video: type == CallType.video);
  if (!granted) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text('需要${type == CallType.video ? '摄像头和麦克风' : '麦克风'}权限才能通话')),
      );
    }
    return;
  }
  final ok = await callService.startCall(peer, type);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('当前正在通话中')),
    );
  }
}
