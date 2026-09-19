// ============================================================
// 阶段 Q2 行走骨架——SecureSocket 1000 条连发 Spike（真实服务端，端口 8098）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 风险清单与 TESTING_GUIDE.md §36.2
// 骨架冒烟 #7（硬性门槛）：
//
//   「每新平台骨架期第一件事：1000 条消息连发 spike 对账落库数——
//   阶段 J 已知 Linux 缺陷（Dart SecureSocket IOSink add+flush 随机
//   静默丢失/挂起竞态）的跨平台复现验证」
//
// 本文件即 Windows 宿主的 Spike 执行载体（§21.2：第 7 项为硬性门槛，
// 异常时记录现象与该平台缓解结论并回写 §13.9 风险清单）：
//
//   阶段 1 连发：alice → bob 连发 1000 条文本（sendChat 逐条 await，
//     全部返回 true——任何一次写失败/挂起即红）；
//   阶段 2 对账：对账期间 alice 保持连接（sendChat 的 await 只保证
//     写入本端 IOSink，服务端按会话线程逐条消费——发送后立即断开会
//     使未读字节随 RST 丢弃，属 harness 伪缺陷）；bob 登录后，已离线
//     落库的经补发、之后消费的经实时推送，双路收敛——唯一 message_id
//     数 == 1000（零丢失）且无重复投递（零重复、message_id 幂等）。
//
// 执行策略：
//   · **Windows 宿主默认执行**（本 Spike 的验证对象）；
//   · Linux 开发机默认跳过——Linux 基线的 SecureSocket 竞态已由阶段 J
//     专项与 8 个既有 E2E 覆盖，避免 Linux 全量门引入平台性 flake；
//     需要在 Linux 复跑时设 Q2_SPIKE=1 强制执行；
//   · 缺 Python 服务端环境（.venv）自动跳过（既有 E2E 惯例）。
// Windows 宿主运行：
//   flutter test test/services/stage_q2_windows_spike_e2e_test.dart
// ============================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/config.dart';
import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/socket_service.dart';
import 'package:chatroom_flutter/services/state_manager.dart';
import 'package:chatroom_flutter/services/taskbar_notifier.dart';

const int spikeCount = 1000;
const int spikePort = 8098;
const String spikePrefix = 'SPK-';

AppState get state => AppState.instance;

void resetState() {
  state
    ..setLoggedOut()
    ..setConnectionStatus(ConnectionStatus.disconnected);
}

const serverScript = r'''
import sys, os, time, threading, tempfile
root = os.environ['CHATROOM_ROOT']
os.chdir(root)
sys.path.insert(0, root)
os.environ['CHATROOM_ADMIN_SECRET'] = 'test-admin-secret'
import bcrypt
from config import config
config._load()
tmp = tempfile.mkdtemp()
db_path = os.path.join(tmp, 'e2e.db')
config._data.setdefault('database', {})['path'] = db_path
# 服务端绑 0.0.0.0：config.dart 的 serverHost 在 Q1 后固化为开发机局域网 IP
# （安卓真机/Windows 客户端跨机连接），E2E 服务端不得依赖 config.yaml 只绑
# 回环的默认值——否则跨机客户端 connect 被拒
config._data.setdefault('server', {})['host'] = '0.0.0.0'
from database import Database
db = Database(db_path)
for u, p in [('alice', 'password123'), ('bob', 'password456')]:
    db.add_user(u, bcrypt.hashpw(p.encode(), bcrypt.gensalt()))
with db._get_connection() as conn:
    conn.execute("INSERT INTO friends (user1,user2,status) VALUES ('alice','bob','accepted')")
    conn.execute("INSERT INTO friends (user1,user2,status) VALUES ('bob','alice','accepted')")
    conn.commit()
from server.server_main import Server
server = Server(port=int(os.environ['CHATROOM_SPIKE_PORT']))
server.db = db
server.build_listen()
''';

Future<bool> waitFor(bool Function() cond,
    {Duration timeout = const Duration(minutes: 6)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return cond();
}

Future<bool> waitForServerReady(String host, int port,
    {Duration timeout = const Duration(seconds: 40)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    try {
      final s = await Socket.connect(host, port);
      s.destroy();
      return true;
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }
  return false;
}

/// 兼容 Linux（.venv/bin/python）与 Windows（.venv/Scripts/python.exe）；
/// CHATROOM_SPIKE_PYTHON 可显式指定解释器（venv 布局不同的机器）
String? resolvePython() {
  final override = Platform.environment['CHATROOM_SPIKE_PYTHON'];
  if (override != null && override.isNotEmpty && File(override).existsSync()) {
    return override;
  }
  final root = Directory.current.parent;
  final candidates = [
    '${root.path}/.venv/bin/python',
    '${root.path}\\.venv\\Scripts\\python.exe',
  ];
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return null;
}

void main() {
  Process? serverProcess;
  var skipped = false;
  var skipReason = '';

  setUp(resetState);

  setUpAll(() async {
    TaskbarNotifier.enabled = false;
    TaskbarNotifier.soundEnabled = false;
    if (!Platform.isWindows && Platform.environment['Q2_SPIKE'] != '1') {
      skipped = true;
      skipReason = '连发 Spike 归 Windows 宿主执行（Linux 基线已由阶段 J 专项与'
          '既有 E2E 覆盖）；如需在 Linux 强制执行请设置 Q2_SPIKE=1';
      return;
    }
    final python = resolvePython();
    if (python == null) {
      skipped = true;
      skipReason = '缺少本地 Python 服务端环境（.venv），跳过 E2E 测试';
      return;
    }
    AppConfig.serverPort = spikePort;
    final root = Directory.current.parent;
    final scriptDir = Directory('${Directory.systemTemp.path}/opencode')
      ..createSync(recursive: true);
    final script = File('${scriptDir.path}/stage_q2_spike_server.py');
    script.writeAsStringSync(serverScript);
    serverProcess = await Process.start(python, [script.path],
        environment: {
          'CHATROOM_ROOT': root.path,
          'CHATROOM_SPIKE_PORT': spikePort.toString(),
        },
        workingDirectory: root.path);
    serverProcess!.stderr.transform(const SystemEncoding().decoder).listen((s) {
      // ignore: avoid_print
      print('SRV: ${s.trim()}');
    });
    final ready = await waitForServerReady('127.0.0.1', spikePort);
    if (!ready) {
      fail('E2E 服务端未在超时内就绪（端口 $spikePort）');
    }
  });

  tearDownAll(() async {
    serverProcess?.kill();
    await serverProcess?.exitCode.catchError((_) => 0);
    AppConfig.serverPort = 8090;
  });

  test('1000 条连发 Spike：连发无挂起/无写失败 + 落库对账零丢失/零重复', () async {
    if (skipped) {
      markTestSkipped(skipReason);
      return;
    }
    final alice = SocketService();
    expect(await alice.connect(), isTrue);
    expect(await alice.login('alice', 'password123'), isNull);

    var failures = 0;
    final sendStart = DateTime.now();
    for (var i = 0; i < spikeCount; i++) {
      final ok = await alice.sendChat('bob', '$spikePrefix$i');
      if (!ok) failures++;
    }
    // ignore: avoid_print
    print('SPIKE-DIAG: send loop '
        '${DateTime.now().difference(sendStart).inMilliseconds}ms, '
        'failures=$failures');
    expect(failures, 0,
        reason: 'SecureSocket 连发写失败/超时即触发（阶段 J 缺陷跨平台复现信号，'
            '异常时记录现象与平台缓解结论回写 §13.9 风险清单）');

    // 对账前重置共享 AppState（单例）：alice 的本地发送气泡与全局
    // messageId 去重表（_messageMap 跨会话）必须清空——否则 bob 收到的
    // 同 id 消息会被去重合并进 alice 的气泡（两个账号同进程是 harness
    // 特有场景，生产环境各账号独立进程无此问题），对账恒为 0。
    // alice 的 socket 保持连接：sendChat 的 await 只保证写入本端 IOSink，
    // 1000 条在服务端按会话线程逐条消费——若发送后立即断开，服务端未读
    // 字节随 RST 丢弃（harness 伪缺陷，非被测行为）。bob 登录后，已离线
    // 落库的经补发、之后消费的经实时推送，双路收敛到 spikeCount。
    resetState();

    final bob = SocketService();
    expect(await bob.connect(), isTrue);
    expect(await bob.login('bob', 'password456'), isNull);

    List<ChatMessage> spkMessages() => state
        .getMessages('alice')
        .where((m) => m.content.startsWith(spikePrefix))
        .toList();

    final ok = await waitFor(() =>
        spkMessages().map((m) => m.messageId).toSet().length >= spikeCount);
    if (!ok) {
      // 诊断（§21.31 对账停滞家族）：失败时打印实际摄入量与最新一条
      // 时间戳，区分"实时推送缺失"与"离线补发缺失"
      final msgs = spkMessages();
      // ignore: avoid_print
      print('SPIKE-DIAG: stall count=${msgs.length} '
          'unique=${msgs.map((m) => m.messageId).toSet().length} '
          'last=${msgs.isEmpty ? "-" : msgs.last.timestamp}');
    }
    expect(ok, isTrue, reason: '对账未在超时内收敛到 $spikeCount 条（服务端落库/推送停滞）');
    final spk = spkMessages();
    expect(spk.map((m) => m.messageId).toSet().length, spikeCount,
        reason: '服务端落库对账（零丢失）');
    expect(spk.length, spk.map((m) => m.messageId).toSet().length,
        reason: '补发/实时推送双路不得重复投递（message_id 幂等）');

    alice.disconnect();
    bob.disconnect();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
