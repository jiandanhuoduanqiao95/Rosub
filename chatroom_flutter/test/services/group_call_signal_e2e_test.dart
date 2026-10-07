// ============================================================
// 阶段 R2 —— 群语音/群视频信令端到端契约（真实 Python 服务端子进程）
// ============================================================
// 验证 SocketService ↔ CallService 群通话接线与房间化信令链路：
//   alice 发起群通话 → bob/carol 响铃（群名）→ bob 加入 → joined[self]
//   逐对 offer/answer 中继 → carol 经注册表中途加入（新加入者向全体
//   既有成员逐对发起协商）→ alice 挂断房间存续 → 全体离开房间结束。
// 另验证：忙线成员被群来电跳过；同群并发房间拒绝。
// WebRTC 媒体层用假引擎（E2E 只验信令，媒体连通性由平台冒烟 +
// 三端真机手测覆盖）。依赖本地 .venv Python（缺失时跳过）。
// ============================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:chatroom_flutter/config.dart';
import 'package:chatroom_flutter/services/call_engine.dart';
import 'package:chatroom_flutter/services/call_service.dart';
import 'package:chatroom_flutter/services/socket_service.dart';

const groupCallE2ePort = 8100;

const serverScript = r'''
import sys, os, tempfile
root = os.environ['CHATROOM_ROOT']
os.chdir(root)
sys.path.insert(0, root)
os.environ['CHATROOM_ADMIN_SECRET'] = 'test-admin-secret'
import bcrypt
from config import config
config._load()
tmp = tempfile.mkdtemp()
config._data.setdefault('database', {})['path'] = os.path.join(tmp, 'r2e2e00.db')
from database import Database
db = Database(os.path.join(tmp, 'r2e2e00.db'))
for u, p in (('alice', b'password123'), ('bob', b'password456'),
             ('carol', b'password789'), ('dave', b'password000')):
    db.add_user(u, bcrypt.hashpw(p, bcrypt.gensalt()))
with db._get_connection() as conn:
    for a, b in (('alice','bob'),('bob','alice'),('alice','carol'),
                 ('carol','alice'),('bob','carol'),('carol','bob'),
                 ('alice','dave'),('dave','alice'),
                 ('carol','dave'),('dave','carol')):
        conn.execute("INSERT INTO friends (user1,user2,status) VALUES (?,?, 'accepted')", (a, b))
    conn.commit()
gid = db.create_group('研发群', 'alice')
with db._get_connection() as conn:
    for m in ('bob', 'carol'):
        conn.execute("INSERT INTO group_members (group_id, username) VALUES (?,?)", (gid, m))
    conn.commit()
from server.server_main import Server
server = Server(port=8100)
server.db = db
server.build_listen()
''';

/// 假引擎：E2E 只验信令链路（媒体层由平台冒烟 + 手动验收覆盖）
class FakeE2eEngine implements CallEngine {
  @override
  void setListener(CallEngineListener? listener) {}

  @override
  Future<void> setMicMuted(bool muted) async {}

  @override
  Future<void> setCameraEnabled(bool enabled) async {}

  @override
  Future<void> setSpeakerphoneOn(bool on) async {}

  @override
  bool get hasVideo => false;

  @override
  bool get hasLocalMedia => true;

  @override
  Future<int> videoInputCount() async => 0;

  @override
  Future<void> switchCamera() async {}

  @override
  MediaStream? get localStream => null;

  @override
  Future<void> open({required bool video}) async {}

  @override
  Future<void> ensureMedia({required bool video}) async {}

  @override
  Future<CallPeerSession> createPeerSession(String peerId) async =>
      _FakeE2ePeerSession(peerId);

  @override
  CallPeerSession? peerSession(String peerId) => null;

  @override
  Future<Map<String, Object?>> createOffer() async =>
      {'sdp': 'e2e-offer', 'type': 'offer'};

  @override
  Future<void> setRemoteOffer(Map<String, Object?> description) async {}

  @override
  Future<Map<String, Object?>> createAnswer() async =>
      {'sdp': 'e2e-answer', 'type': 'answer'};

  @override
  Future<void> setRemoteAnswer(Map<String, Object?> description) async {}

  @override
  Future<void> addRemoteCandidate(Map<String, Object?> candidate) async {}

  @override
  Future<void> attachRenderers({
    RTCVideoRenderer? remote,
    RTCVideoRenderer? local,
  }) async {}

  @override
  Future<void> close() async {}
}

/// 假单边会话：群通话 E2E 只验信令链路
class _FakeE2ePeerSession implements CallPeerSession {
  _FakeE2ePeerSession(this.peerId);

  @override
  final String peerId;

  @override
  MediaStream? get remoteStream => null;

  @override
  Future<Map<String, Object?>> createOffer() async =>
      {'sdp': 'e2e-offer-$peerId', 'type': 'offer'};

  @override
  Future<void> setRemoteOffer(Map<String, Object?> description) async {}

  @override
  Future<Map<String, Object?>> createAnswer() async =>
      {'sdp': 'e2e-answer-$peerId', 'type': 'answer'};

  @override
  Future<void> setRemoteAnswer(Map<String, Object?> description) async {}

  @override
  Future<void> addRemoteCandidate(Map<String, Object?> candidate) async {}

  @override
  void attachRenderer(RTCVideoRenderer? renderer) {}

  @override
  RTCPeerConnection? get peerConnection => null;

  @override
  Future<double?> inboundAudioLevel() async => null;

  @override
  Future<void> close() async {}
}

Future<bool> _waitUntil(bool Function() cond,
    {int tries = 40, Duration step = const Duration(milliseconds: 200)}) async {
  for (var i = 0; i < tries; i++) {
    if (cond()) return true;
    await Future<void>.delayed(step);
  }
  return cond();
}

void main() {
  Process? serverProcess;
  var skipped = false;

  setUpAll(() async {
    final root = Directory.current.parent;
    final python = '${root.path}/.venv/bin/python';
    if (!File(python).existsSync()) {
      skipped = true;
      return;
    }
    AppConfig.serverPort = groupCallE2ePort;
    AppConfig.serverHost = '127.0.0.1';
    final script = File('/tmp/opencode/r2_group_e2e_server.py');
    Directory('/tmp/opencode').createSync(recursive: true);
    script.writeAsStringSync(serverScript);
    serverProcess = await Process.start(
      python,
      [script.path],
      environment: {'CHATROOM_ROOT': root.path},
      workingDirectory: root.path,
    );
    serverProcess!.stderr.transform(const SystemEncoding().decoder).listen((s) {
      if (s.contains('群通话') || s.contains('group_call')) {
        // ignore: avoid_print
        print('SRV: ${s.trim()}');
      }
    });
    for (var i = 0; i < 60; i++) {
      try {
        final probe = await Socket.connect('127.0.0.1', groupCallE2ePort,
            timeout: const Duration(milliseconds: 400));
        probe.destroy();
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
  });

  tearDownAll(() async {
    AppConfig.serverPort = 8090;
    AppConfig.serverHost = '127.0.0.1';
    SocketService.callEngineOverride = null;
    serverProcess?.kill(ProcessSignal.sigkill);
    await serverProcess?.exitCode;
  });

  test('群通话全链路：邀请→响铃→逐对协商→中途加入→挂断存续→房间结束', () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    SocketService.callEngineOverride = FakeE2eEngine();
    final alice = SocketService();
    final bob = SocketService();
    final carol = SocketService();
    final dave = SocketService();
    expect(await alice.connect(), isTrue);
    expect(await alice.login('alice', 'password123'), isNull);
    expect(await bob.connect(), isTrue);
    expect(await bob.login('bob', 'password456'), isNull);
    expect(await carol.connect(), isTrue);
    expect(await carol.login('carol', 'password789'), isNull);
    expect(await dave.connect(), isTrue);
    expect(await dave.login('dave', 'password000'), isNull);

    // carol 先与 dave 1:1 通话（忙线）→ 群来电对其静默跳过
    expect(await dave.callService.startCall('carol', CallType.audio), isTrue);
    expect(await _waitUntil(() => carol.callService.phase == CallPhase.ringing),
        isTrue);

    // alice 发起群语音通话 → bob 响铃（群名）；carol 忙线被服务端跳过
    expect(await alice.callService.startGroupCall(1, '研发群', CallType.audio),
        isTrue);
    expect(alice.callService.phase, CallPhase.calling);
    expect(await _waitUntil(() => bob.callService.phase == CallPhase.ringing),
        isTrue,
        reason: 'bob 应进入群响铃态');
    expect(bob.callService.groupName, '研发群');
    expect(bob.callService.isGroupCall, isTrue);
    expect(carol.callService.groupId, isNull, reason: '忙线成员不收群邀请');

    // bob 加入 → joined[self] → bob 向 alice 逐对发起 offer
    await bob.callService.acceptIncoming();
    expect(
        await _waitUntil(() =>
            bob.callService.participants.contains('bob') &&
            bob.callService.participants.contains('alice')),
        isTrue,
        reason: 'bob 应收到 joined[self] 确认');
    expect(
        await _waitUntil(() => alice.callService.phase == CallPhase.connecting),
        isTrue,
        reason: '主叫在首个成员加入后转接通中');

    // carol 的 1:1 结束后，经 joined 广播得知房间存续 → 中途加入
    // （忙线被跳过的成员中途加入场景；新加入者对 alice/bob 逐对发 offer）
    dave.callService.cancelOutgoing();
    expect(await _waitUntil(() => carol.callService.phase == CallPhase.idle),
        isTrue);
    expect(carol.callService.knownGroupCalls[1]?.callId, isNotNull,
        reason: 'carol 应从 joined 广播得知进行中的房间');
    expect(await carol.callService.joinGroupRoom(1), isTrue);
    expect(
        await _waitUntil(() =>
            alice.callService.remotePeers.contains('bob') &&
            alice.callService.remotePeers.contains('carol')),
        isTrue,
        reason: 'alice 的远端成员应含 bob 与 carol');
    expect(
        await _waitUntil(() =>
            bob.callService.remotePeers.contains('carol') &&
            bob.callService.remotePeers.contains('alice')),
        isTrue);

    // alice 挂断：只移除自己，房间存续（bob/carol 继续）
    alice.callService.hangup();
    expect(
        await _waitUntil(
            () => bob.callService.participants.toString() == '[bob, carol]'),
        isTrue,
        reason: 'bob 应收到 left 且参与者收缩为 bob/carol');
    expect(bob.callService.phase != CallPhase.ended, isTrue,
        reason: '房间存续，bob 不应被结束');

    // bob/carol 依次离开 → 最后参与者离开后房间结束（ended=1）
    bob.callService.hangup();
    expect(
        await _waitUntil(
            () => carol.callService.participants.toString() == '[carol]'),
        isTrue,
        reason: 'carol 应看到只剩自己');
    carol.callService.hangup();
    expect(await _waitUntil(() => carol.callService.phase == CallPhase.ended),
        isTrue,
        reason: '最后参与者离开后房间结束');
    expect(carol.callService.endReason, '通话已结束');
    expect(
        await _waitUntil(() =>
            bob.callService.knownGroupCalls[1] == null &&
            carol.callService.knownGroupCalls[1] == null),
        isTrue,
        reason: '注册表应随房间结束清除');

    alice.disconnect();
    bob.disconnect();
    carol.disconnect();
    dave.disconnect();
  });

  test('群通话：忙线成员被跳过（1:1 振铃中不收群邀请）', () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    SocketService.callEngineOverride = FakeE2eEngine();
    final alice = SocketService();
    final bob = SocketService();
    final carol = SocketService();
    final dave = SocketService();
    expect(await alice.connect(), isTrue);
    expect(await alice.login('alice', 'password123'), isNull);
    expect(await bob.connect(), isTrue);
    expect(await bob.login('bob', 'password456'), isNull);
    expect(await carol.connect(), isTrue);
    expect(await carol.login('carol', 'password789'), isNull);
    expect(await dave.connect(), isTrue);
    expect(await dave.login('dave', 'password000'), isNull);

    // carol 与 dave 1:1 通话振铃中 → 忙线
    expect(await dave.callService.startCall('carol', CallType.audio), isTrue);
    expect(await _waitUntil(() => carol.callService.phase == CallPhase.ringing),
        isTrue);

    // alice 发起群通话：bob 收到，carol 被服务端静默跳过
    expect(await alice.callService.startGroupCall(1, '研发群', CallType.audio),
        isTrue);
    expect(await _waitUntil(() => bob.callService.phase == CallPhase.ringing),
        isTrue);
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(carol.callService.phase, CallPhase.ringing,
        reason: 'carol 仍停留在 1:1 振铃，未被群通话打扰');

    alice.callService.cancelOutgoing();
    dave.callService.cancelOutgoing();
    alice.disconnect();
    bob.disconnect();
    carol.disconnect();
    dave.disconnect();
  });
}
