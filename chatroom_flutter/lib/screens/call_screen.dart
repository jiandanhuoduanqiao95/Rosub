/// 阶段 R1/R2：通话界面
///
/// ringing（来电：接听/拒绝）/ calling+connecting（去话：取消）/
/// active（通话中：挂断 + 视频画面 + 静音/免提/关画面 + 最小化）/
/// ended（结束原因，2s 自动返回）。
/// 一对一：视频类型挂载远端全屏 + 本地小窗（可拖动，Cover 满幅裁剪，
/// 微信式）。R2 群通话：宫格布局——视频成员瓦片带昵称，纯音频/关摄像头
/// 成员头像 + 麦克风态，自己占首格（微信式九宫格）。最小化=离开界面
/// 继续通话（ChatScreen 显示悬浮返回条）。
import 'dart:async';
import 'dart:math' as math;

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
  final Map<String, RTCVideoRenderer> _groupRenderers = {};
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
    await _syncGroupRenderers();
  }

  /// 群通话：按远端成员增删同步渲染器（joined/left/宫格重建驱动）
  Future<void> _syncGroupRenderers() async {
    if (!_renderersReady) return;
    final wanted = _svc.isGroupCall ? _svc.remotePeers.toSet() : <String>{};
    for (final peer in List.of(_groupRenderers.keys)) {
      if (wanted.contains(peer)) continue;
      final r = _groupRenderers.remove(peer);
      _svc.attachPeerRenderer(peer, null);
      await r?.dispose();
    }
    for (final peer in wanted) {
      final existing = _groupRenderers[peer];
      if (existing != null) {
        // gc3 修复：渲染器可能先于会话创建（接通阶段同步时 peerSession
        // 尚不存在，挂载空操作）——已有渲染器必须幂等重挂，否则会话
        // 建立、流到达后无人补挂 srcObject（真机三端"只见自己画面"
        // 的根因：瓦片走视频分支但渲染器从未绑流）
        _svc.attachPeerRenderer(peer, existing);
        continue;
      }
      final r = RTCVideoRenderer();
      _groupRenderers[peer] = r;
      try {
        await r.initialize();
      } catch (_) {
        _groupRenderers.remove(peer);
        continue;
      }
      if (!mounted) {
        await r.dispose();
        _groupRenderers.remove(peer);
        return;
      }
      _svc.attachPeerRenderer(peer, r);
      setState(() {});
    }
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
    if (_svc.isGroupCall) {
      unawaited(_syncGroupRenderers());
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _svc.removeListener(_onPhaseChanged);
    _ticker?.cancel();
    final remote = _remoteRenderer;
    final local = _localRenderer;
    final group = List.of(_groupRenderers.entries);
    _groupRenderers.clear();
    for (final peer in group) {
      _svc.attachPeerRenderer(peer.key, null);
    }
    _svc.attachRenderers();
    Future.microtask(() async {
      remote?.srcObject = null;
      local?.srcObject = null;
      await remote?.dispose();
      await local?.dispose();
      for (final peer in group) {
        peer.value.srcObject = null;
        await peer.value.dispose();
      }
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
        return _svc.isGroupCall ? '正在邀请成员…' : '正在等待对方接听…';
      case CallPhase.ringing:
        return _svc.isGroupCall ? '邀请你加入群$_typeLabel' : '邀请您$_typeLabel';
      case CallPhase.connecting:
        return '接通中…';
      case CallPhase.active:
        return _svc.isGroupCall
            ? '$_durationText · ${_svc.participants.length}人'
            : _durationText;
      case CallPhase.ended:
        return _svc.endReason ?? '通话已结束';
      case CallPhase.idle:
        return '';
    }
  }

  String get _titleText =>
      _svc.isGroupCall ? (_svc.groupName ?? '群聊') : (_svc.peer ?? '');

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
    final isGroup = _svc.isGroupCall;
    final showVideo = !isGroup && _renderersReady && phase == CallPhase.active;
    // 群通话接通/通话中：全屏自适应宫格 + 悬浮信息条 + 底部控制排
    // （R2 gc2 重设计：原固定 2/3 列 GridView 在手机竖屏裁切末位瓦片、
    // 桌面宽窗把瓦片压扁成宽黑条——改按视口与人数动态求行列）
    final showGroupStage =
        isGroup && (phase == CallPhase.connecting || phase == CallPhase.active);
    final showControls =
        phase == CallPhase.connecting || phase == CallPhase.active;
    final topInset = MediaQuery.paddingOf(context).top;
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
            if (showGroupStage) ...[
              Positioned.fill(
                child: SafeArea(child: _buildGroupStage()),
              ),
              Positioned(
                top: topInset + 8,
                left: 12,
                right: 12,
                child: _buildGroupHeaderBar(),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _buildGroupControlsBar(phase),
              ),
              // gc3 微信式：视频群通话自己为可拖动悬浮小窗（宫格只放远端）
              if (_svc.type == CallType.video) _buildGroupSelfPip(context),
            ],
            if (!showGroupStage)
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
                        _titleText,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        isGroup ? '群$_typeLabel' : _typeLabel,
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
            // 本地小窗（仅一对一视频）：可拖动 + Cover 满幅裁剪（真机十轮：
            // 原 Contain 在竖框内上下留黑边；微信式小窗应满幅）
            if (showVideo && _localRenderer != null) _buildLocalPip(context),
          ],
        ),
      ),
    );
  }

  /// 群通话媒体区：按视口与人数动态求行列的自适应宫格，瓦片短边最大化
  /// 铺满可用空间、末行居中——R2 gc2/gc3 重设计（原固定 crossAxisCount +
  /// childAspectRatio 在手机竖屏把末位瓦片挤出视口、桌面宽窗按比例反推
  /// 行高远超视口把瓦片压扁）。gc3 微信式：视频类型宫格只放远端成员，
  /// 自己为可拖动悬浮小窗（_buildGroupSelfPip）；语音类型保持全员头像格。
  Widget _buildGroupStage() {
    return LayoutBuilder(builder: (context, constraints) {
      final isVideo = _svc.type == CallType.video;
      final all = isVideo ? _svc.remotePeers : _svc.participants;
      if (all.isEmpty) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.group_rounded, color: Colors.white24, size: 56),
              const SizedBox(height: 12),
              Text('等待其他成员加入…',
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: .5), fontSize: 14)),
            ],
          ),
        );
      }
      const gap = 6.0;
      final n = all.length;
      var bestCols = n;
      var bestScore = -1.0;
      for (var rows = 1; rows <= n; rows++) {
        final cols = math.min(n, (n / rows).ceil());
        final tw = (constraints.maxWidth - (cols - 1) * gap) / cols;
        final th = (constraints.maxHeight - (rows - 1) * gap) / rows;
        final score = math.min(tw, th);
        if (score > bestScore) {
          bestScore = score;
          bestCols = cols;
        }
      }
      final videoGrid = isVideo;
      final tileW = (constraints.maxWidth - (bestCols - 1) * gap) / bestCols;
      final rows = <List<String>>[
        for (var i = 0; i < n; i += bestCols)
          all.sublist(i, math.min(i + bestCols, n)),
      ];
      return Padding(
        padding: const EdgeInsets.all(3),
        child: Column(
          children: [
            for (var r = 0; r < rows.length; r++) ...[
              if (r > 0) const SizedBox(height: gap),
              Expanded(
                child: _buildStageRow(
                  rows[r],
                  isLast: r == rows.length - 1,
                  fullCols: bestCols,
                  tileW: tileW,
                  gap: gap,
                  videoGrid: videoGrid,
                ),
              ),
            ],
          ],
        ),
      );
    });
  }

  Widget _buildStageRow(
    List<String> members, {
    required bool isLast,
    required int fullCols,
    required double tileW,
    required double gap,
    required bool videoGrid,
  }) {
    Widget tile(String name) => name == _svc.selfUsername
        ? _buildSelfTile(videoGrid)
        : _buildRemoteTile(name, videoGrid);
    // 末行不满时固定瓦片宽度居中（微信式），满行 Expanded 均分
    if (isLast && members.length < fullCols) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var c = 0; c < members.length; c++) ...[
            if (c > 0) SizedBox(width: gap),
            SizedBox(width: tileW, child: tile(members[c])),
          ],
        ],
      );
    }
    return Row(
      children: [
        for (var c = 0; c < members.length; c++) ...[
          if (c > 0) SizedBox(width: gap),
          Expanded(child: tile(members[c])),
        ],
      ],
    );
  }

  /// 悬浮信息条（覆在宫格上层）：最小化钮 + 群名 + 类型/状态一行小字
  Widget _buildGroupHeaderBar() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(24),
      ),
      padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _circleIconButton(
            icon: Icons.keyboard_arrow_left_rounded,
            tooltip: '最小化（不挂断）',
            onTap: _svc.minimize,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _titleText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  '群$_typeLabel · $_statusText',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: .7), fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 底部控制排：黑色渐变半透明底，覆在宫格上层（微信式）
  Widget _buildGroupControlsBar(CallPhase phase) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0),
            Colors.black.withValues(alpha: .7),
          ],
        ),
      ),
      padding: EdgeInsets.fromLTRB(16, 24, 16, bottomInset + 16),
      child: _buildControls(phase),
    );
  }

  /// 自己的瓦片：视频类型渲染本地预览（镜像），语音/关摄像头为头像
  Widget _buildSelfTile(bool videoGrid) {
    final showLocalVideo = videoGrid &&
        _svc.type == CallType.video &&
        !_svc.cameraOff &&
        _localRenderer != null;
    return _tileFrame(
      video: showLocalVideo
          ? RTCVideoView(_localRenderer!,
              mirror: true,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
          : null,
      placeholderIcon: Icons.person_rounded,
      label: '我',
      micMuted: _svc.micMuted,
    );
  }

  Widget _buildRemoteTile(String name, bool videoGrid) {
    final renderer = _groupRenderers[name];
    final hasStream = videoGrid &&
        _svc.type == CallType.video &&
        !_svc.peerCamOff(name) &&
        renderer != null &&
        _svc.remoteStreamOf(name) != null;
    return _tileFrame(
      video: hasStream
          ? RTCVideoView(renderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
          : null,
      placeholderIcon: Icons.person_rounded,
      label: name,
      micMuted: _svc.peerMicMuted(name),
    );
  }

  Widget _tileFrame({
    required Widget? video,
    required IconData placeholderIcon,
    required String label,
    required bool micMuted,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF23262E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: .12)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (video != null)
            video
          else
            Center(
              child: Icon(placeholderIcon, color: Colors.white24, size: 44),
            ),
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .4),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (micMuted) ...[
                      const Icon(Icons.mic_off_rounded,
                          color: Colors.redAccent, size: 12),
                      const SizedBox(width: 3),
                    ],
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Offset _defaultPipOffset(Size screen) => Offset(screen.width - 110 - 16, 96);

  /// 群视频通话自己的悬浮小窗（微信式）：可拖动、镜像、关摄像头占位；
  /// 与 1:1 小窗共用拖动偏移（一次只有一种布局在场）
  Widget _buildGroupSelfPip(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final topInset = MediaQuery.paddingOf(context).top;
    final fallback = Offset(screen.width - 120 - 14, topInset + 64);
    final pos = _clampPip(_pipOffset ?? fallback, screen);
    final hasPreview =
        !_svc.cameraOff && _localRenderer != null && _renderersReady;
    return Positioned(
      left: pos.dx,
      top: pos.dy,
      child: GestureDetector(
        onPanUpdate: (details) => setState(() {
          _pipOffset =
              _clampPip((_pipOffset ?? fallback) + details.delta, screen);
        }),
        child: Container(
          width: 120,
          height: 170,
          decoration: BoxDecoration(
            color: const Color(0xFF23262E),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withValues(alpha: .2)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: .4),
                blurRadius: 8,
              ),
            ],
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
              : hasPreview
                  ? RTCVideoView(_localRenderer!,
                      mirror: true,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
                  : const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            color: Colors.white38, strokeWidth: 2),
                      ),
                    ),
        ),
      ),
    );
  }

  Offset _clampPip(Offset o, Size screen, {double w = 110, double h = 160}) {
    return Offset(
      o.dx.clamp(8.0, screen.width - w - 8),
      o.dy.clamp(8.0, screen.height - h - 120),
    );
  }

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
            border: Border.all(color: Colors.white.withValues(alpha: .2)),
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
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
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
              icon: _svc.micMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
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

/// 发起一对一通话的统一入口（ChatScreen 头部按钮调用）：
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

/// 发起群通话的统一入口（ChatScreen 群会话调用；权限语义同一对一）
Future<void> startOutgoingGroupCall(
  BuildContext context,
  CallService callService,
  int groupId,
  String groupName,
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
  final ok = await callService.startGroupCall(groupId, groupName, type);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('当前正在通话中')),
    );
  }
}
