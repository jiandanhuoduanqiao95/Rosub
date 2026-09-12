// ============================================================
// 阶段 R1 —— 通话信令端到端契约（真实 Python 服务端子进程）
// ============================================================
// 验证 SocketService ↔ CallService 接线与信令链路：
//   alice 呼叫 bob → bob 响铃 → 接听 → offer/answer/ICE 中继 →
//   挂断；忙线拒绝；离线失败原因映射。
// WebRTC 媒体层用假引擎（E2E 只验信令，媒体连通性由
// CHATROOM_WEBRTC_SPIKE=1 平台冒烟 + 双端手动验收覆盖）。
// 依赖本地 .venv Python（缺失时跳过，不阻塞其它环境）。
// ============================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:chatroom_flutter/config.dart';
import 'package:chatroom_flutter/services/call_engine.dart';
import 'package:chatroom_flutter/services/call_service.dart';
import 'package:chatroom_flutter/services/socket_service.dart';
import 'package:chatroom_flutter/services/state_manager.dart';

AppState get state => AppState.instance;

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
config._data.setdefault('database', {})['path'] = os.path.join(tmp, 'r1e2e99.db')
from database import Database
db = Database(os.path.join(tmp, 'r1e2e99.db'))
db.add_user('alice', bcrypt.hashpw(b'password123', bcrypt.gensalt()))
db.add_user('bob', bcrypt.hashpw(b'password456', bcrypt.gensalt()))
db.add_user('carol', bcrypt.hashpw(b'password789', bcrypt.gensalt()))
with db._get_connection() as conn:
    conn.execute("INSERT INTO friends (user1,user2,status) VALUES ('alice','bob','accepted')")
    conn.execute("INSERT INTO friends (user1,user2,status) VALUES ('bob','alice','accepted')")
    conn.execute("INSERT INTO friends (user1,user2,status) VALUES ('alice','carol','accepted')")
    conn.execute("INSERT INTO friends (user1,user2,status) VALUES ('carol','alice','accepted')")
    conn.execute("INSERT INTO friends (user1,user2,status) VALUES ('carol','bob','accepted')")
    conn.execute("INSERT INTO friends (user1,user2,status) VALUES ('bob','carol','accepted')")
    conn.commit()
from server.server_main import Server
server = Server(port=8099)
server.db = db
server.build_listen()
''';

/// 假引擎：E2E 只验信令链路（媒体层由平台冒烟 + 手动验收覆盖）
class FakeE2eEngine implements CallEngine {
  @override
  void setListener(CallEngineListener? listener) {}

  @override
  bool get hasVideo => false;

  @override
  MediaStream? get localStream => null;

  @override
  Future<void> open({required bool video}) async {}

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

Future<bool> _waitUntil(bool Function() cond,
    {int tries = 40, Duration step = const Duration(milliseconds: 200)}) async {
  for (var i = 0; i < tries; i++) {
    if (cond()) return true;
    await Future<void>.delayed(step);
  }
  return cond();
}

void _writeE2eScript(File file, String content) {
  Directory('/tmp/opencode').createSync(recursive: true);
  file.writeAsStringSync(content);
}

/// 等待服务端端口就绪（全量并发下 Python 子进程启动可超 3s 固定等待）
Future<void> _waitServerReady(int port) async {
  for (var i = 0; i < 60; i++) {
    try {
      final probe = await Socket.connect('127.0.0.1', port,
          timeout: const Duration(milliseconds: 400));
      probe.destroy();
      return;
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }
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
    AppConfig.serverPort = 8099;
    AppConfig.serverHost = '127.0.0.1';
    final script = File('/tmp/opencode/r1_e2e_server.py');
    _writeE2eScript(script, serverScript);
    serverProcess = await Process.start(
      python,
      [script.path],
      environment: {'CHATROOM_ROOT': root.path},
      workingDirectory: root.path,
    );
    serverProcess!.stderr
        .transform(const SystemEncoding().decoder)
        .listen((s) {
      if (s.contains('通话') || s.contains('call_')) {
        // ignore: avoid_print
        print('SRV: ${s.trim()}');
      }
    });
    await _waitServerReady(8099);
  });

  tearDownAll(() async {
    AppConfig.serverPort = 8090;
    AppConfig.serverHost = '127.0.0.1';
    SocketService.callEngineOverride = null;
    serverProcess?.kill(ProcessSignal.sigkill);
    await serverProcess?.exitCode;
  });

  test('语音通话全链路：邀请→接听→offer/answer/ICE→挂断', () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    SocketService.callEngineOverride = FakeE2eEngine();
    final alice = SocketService();
    final bob = SocketService();
    expect(await alice.connect(), isTrue);
    expect(await alice.login('alice', 'password123'), isNull);
    expect(await bob.connect(), isTrue);
    expect(await bob.login('bob', 'password456'), isNull);

    // alice 呼叫 bob（audio）
    expect(await alice.callService.startCall('bob', CallType.audio), isTrue);
    expect(alice.callService.phase, CallPhase.calling);
    expect(await _waitUntil(() => bob.callService.phase == CallPhase.ringing),
        isTrue, reason: 'bob 应进入响铃态');
    expect(bob.callService.peer, 'alice');
    expect(bob.callService.type, CallType.audio);

    // bob 接听 → alice 收 accept → 双方 offer/answer 交换
    await bob.callService.acceptIncoming();
    expect(
        await _waitUntil(() => alice.callService.phase == CallPhase.active),
        isTrue,
        reason: 'alice 应在收到 answer 后进入通话中');
    expect(bob.callService.phase, CallPhase.connecting);

    // 挂断 → 双方 ended
    alice.callService.hangup();
    expect(
        await _waitUntil(() => bob.callService.phase == CallPhase.ended), isTrue,
        reason: 'bob 应收到挂断');
    expect(bob.callService.endReason, '通话已结束');

    alice.disconnect();
    bob.disconnect();
  });

  test('视频通话：call_type=video 中继 + 拒绝', () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    SocketService.callEngineOverride = FakeE2eEngine();
    final alice = SocketService();
    final bob = SocketService();
    expect(await alice.connect(), isTrue);
    expect(await alice.login('alice', 'password123'), isNull);
    expect(await bob.connect(), isTrue);
    expect(await bob.login('bob', 'password456'), isNull);

    expect(await alice.callService.startCall('bob', CallType.video), isTrue);
    expect(await _waitUntil(() => bob.callService.type == CallType.video),
        isTrue, reason: 'bob 应看到视频类型');
    expect(bob.callService.phase, CallPhase.ringing);
    bob.callService.rejectIncoming();
    expect(
        await _waitUntil(() => alice.callService.phase == CallPhase.ended),
        isTrue);
    expect(alice.callService.endReason, '对方已拒绝');

    alice.disconnect();
    bob.disconnect();
  });

  test('忙线：bob 通话中，carol 呼叫收 busy 失败原因', () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    SocketService.callEngineOverride = FakeE2eEngine();
    final alice = SocketService();
    final bob = SocketService();
    final carol = SocketService();
    expect(await alice.connect(), isTrue);
    expect(await alice.login('alice', 'password123'), isNull);
    expect(await bob.connect(), isTrue);
    expect(await bob.login('bob', 'password456'), isNull);
    expect(await carol.connect(), isTrue);
    expect(await carol.login('carol', 'password789'), isNull);

    expect(await alice.callService.startCall('bob', CallType.audio), isTrue);
    expect(await _waitUntil(() => bob.callService.phase == CallPhase.ringing),
        isTrue);

    expect(await carol.callService.startCall('bob', CallType.audio), isTrue);
    expect(
        await _waitUntil(() => carol.callService.phase == CallPhase.ended),
        isTrue,
        reason: 'carol 应收到 call_failed');
    expect(carol.callService.endReason, '对方忙线中');

    alice.callService.cancelOutgoing();
    alice.disconnect();
    bob.disconnect();
    carol.disconnect();
  });

  test('离线：呼叫不在线的 carol 收 offline 失败原因', () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    SocketService.callEngineOverride = FakeE2eEngine();
    final alice = SocketService();
    expect(await alice.connect(), isTrue);
    expect(await alice.login('alice', 'password123'), isNull);

    expect(await alice.callService.startCall('carol', CallType.audio), isTrue);
    expect(
        await _waitUntil(() => alice.callService.phase == CallPhase.ended),
        isTrue);
    expect(alice.callService.endReason, '对方不在线');
    alice.disconnect();
  });

  test('服务端信令类型不被当作未知消息（state.log 无"未处理"）', () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    SocketService.callEngineOverride = FakeE2eEngine();
    final alice = SocketService();
    final bob = SocketService();
    expect(await alice.connect(), isTrue);
    expect(await alice.login('alice', 'password123'), isNull);
    expect(await bob.connect(), isTrue);
    expect(await bob.login('bob', 'password456'), isNull);
    expect(await alice.callService.startCall('bob', CallType.audio), isTrue);
    expect(await _waitUntil(() => bob.callService.phase == CallPhase.ringing),
        isTrue);
    bob.callService.rejectIncoming();
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final logs = state.statusLog.join('\n');
    expect(logs.contains('未处理的消息类型: call_'), isFalse,
        reason: '通话信令不应落入 default 未知分支');
    alice.disconnect();
    bob.disconnect();
  });
}
