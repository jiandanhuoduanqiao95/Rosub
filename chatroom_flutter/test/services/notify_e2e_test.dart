// ============================================================
// 阶段 K 修订 E2E —— 新消息提示音全链路回归（真实服务端）
// ============================================================
// 覆盖 2026-08-18 用户手动测试发现的缺陷（真实服务端子进程）：
//   ① 发送方登录后向各用户发送的第一条消息：接收端必须响铃
//   ② 静音一个会话后，其他未静音用户的第一条消息仍须响铃
//   ③ 解除静音后，首条消息恢复响铃
//   ④ 免打扰时段内置顶会话仍响铃（置顶豁免），未置顶被压制
//   ⑤ 根因修复：接收端登录初始数据窗口内到达的实时消息不再被丢弃
//      （原实现静默丢失：无气泡、无提示音，后续消息才正常）——
//      服务器预置 2000 条离线消息拉长初始数据窗口，发送端在窗口内发消息
// 依赖本地 .venv Python（缺失时跳过）；独立端口 8091（避免与
// blocked_state_e2e_test.dart 的 8090 并发冲突）。
// ============================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/config.dart';
import 'package:chatroom_flutter/services/socket_service.dart';
import 'package:chatroom_flutter/services/state_manager.dart';
import 'package:chatroom_flutter/services/taskbar_notifier.dart';

AppState get state => AppState.instance;

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
from database import Database
db = Database(db_path)
for u, p in [('alice', 'password123'), ('bob', 'password456'), ('carol', 'password789')]:
    db.add_user(u, bcrypt.hashpw(p.encode(), bcrypt.gensalt()))
with db._get_connection() as conn:
    for a, b in [('alice','bob'), ('bob','alice'), ('alice','carol'), ('carol','alice'), ('carol','bob'), ('bob','carol')]:
        conn.execute("INSERT INTO friends (user1,user2,status) VALUES (?,?,'accepted')", (a, b))
    conn.commit()
# bob 预置 500 条离线消息（get_offline_messages 上限 500）：
# 拉长登录初始数据窗口（复现"首条消息被丢弃"的窗口期）
for i in range(500):
    db.save_offline_message('alice', 'bob', 'chat', ('离线消息%d' % i).encode(),
                            message_id='offline_%d' % i)
from server.server_main import Server
server = Server(port=8091)
server.db = db
server.build_listen()
''';

// Python 原始协议发送端：独立进程模拟"另一端用户"（AppState 为单例，
// 同一进程内无法并存两个登录用户，必须用独立进程模拟对端）
const pySender = r'''
import sys, os, time, threading, ssl, socket
root = os.environ['CHATROOM_ROOT']
sys.path.insert(0, root)
from protocol import recv_message, send_message
user, pw, to, mid_seed, msg, delay = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], float(sys.argv[6])
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
s = ctx.wrap_socket(socket.create_connection(('127.0.0.1', 8091)))
send_message(s, 'login', user, extra_headers={'password': pw})
def reader():
    try:
        while True:
            h, b = recv_message(s)
            if h is None:
                break
    except Exception:
        pass
threading.Thread(target=reader, daemon=True).start()
time.sleep(delay)
send_message(s, 'chat', msg, extra_headers={'to': to, 'message_id': '%d_%s' % (int(time.time()*1000), mid_seed)})
time.sleep(2.0)
''';

/// 写入 E2E 辅助脚本：确保 /tmp/opencode 目录存在
/// （部分环境该目录缺失会导致 writeAsStringSync 抛 PathNotFoundException）
void _writeE2eScript(File file, String content) {
  Directory('/tmp/opencode').createSync(recursive: true);
  file.writeAsStringSync(content);
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
    AppConfig.serverPort = 8091; // 独立端口，避免与 blocked_state E2E 的 8090 冲突
    final script = File('/tmp/opencode/k_notify_e2e_server.py');
    _writeE2eScript(script, serverScript);
    serverProcess = await Process.start(
      python,
      [script.path],
      environment: {'CHATROOM_ROOT': root.path},
      workingDirectory: root.path,
    );
    serverProcess!.stderr.transform(const SystemEncoding().decoder).listen((s) {
      // ignore: avoid_print
      print('SRV: ${s.trim()}');
    });
    await Future<void>.delayed(const Duration(seconds: 6));
  });

  tearDownAll(() async {
    serverProcess?.kill(ProcessSignal.sigkill);
    await serverProcess?.exitCode;
    AppConfig.serverPort = 8090;
  });

  Future<Process> startPy(
      String user, String pw, String to, String seed, String msg,
      {double delay = 1.2}) async {
    final root = Directory.current.parent;
    final script = File('/tmp/opencode/k_notify_py_sender.py');
    _writeE2eScript(script, pySender);
    return Process.start('${root.path}/.venv/bin/python',
        [script.path, user, pw, to, seed, msg, delay.toString()],
        environment: {'CHATROOM_ROOT': root.path}, workingDirectory: root.path);
  }

  Future<SocketService> loginBob() async {
    final bob = SocketService();
    expect(await bob.connect(), isTrue);
    expect(await bob.login('bob', 'password456'), isNull);
    // 2000 条离线消息 + 会话元数据推送消费完成后，监听循环稳定
    await Future<void>.delayed(const Duration(milliseconds: 800));
    return bob;
  }

  test('① 发送方登录后向空闲接收端发第一条消息 → 接收端响铃', () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    final sounds = <String>[];
    final origImpl = TaskbarNotifier.playSoundImpl;
    TaskbarNotifier.playSoundImpl = () => sounds.add('sound');

    final bob = await loginBob();
    final py = await startPy('alice', 'password123', 'bob', '1', '第一条');
    await py.exitCode;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(sounds, isNotEmpty, reason: '发送方登录后首条消息应响铃');
    expect(state.getMessages('alice').any((m) => m.content == '第一条'), isTrue,
        reason: '消息应正常到达');

    TaskbarNotifier.playSoundImpl = origImpl;
    bob.disconnect();
  });

  test('② 静音 alice 后 carol（未静音）第一条消息仍响铃；③ 解除静音后首条恢复响铃', () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    final sounds = <String>[];
    final origImpl = TaskbarNotifier.playSoundImpl;
    TaskbarNotifier.playSoundImpl = () => sounds.add('sound');

    final bob = await loginBob();

    // 静音 alice；carol 未静音 → 首条消息仍响铃
    await bob.muteConversation('alice', true);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final py = await startPy('carol', 'password789', 'bob', '2', 'carol第一条');
    await py.exitCode;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(sounds, isNotEmpty, reason: '静音 alice 后 carol 的首条消息应响铃');
    sounds.clear();

    // 解除静音 alice → 首条消息恢复响铃
    await bob.muteConversation('alice', false);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final py2 = await startPy('alice', 'password123', 'bob', '3', '解除后第一条');
    await py2.exitCode;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(sounds, isNotEmpty, reason: '解除静音后首条消息应恢复响铃');

    TaskbarNotifier.playSoundImpl = origImpl;
    bob.disconnect();
  });

  test('④ 免打扰时段内置顶会话仍响铃（置顶豁免），未置顶会话被压制', () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    final sounds = <String>[];
    final origImpl = TaskbarNotifier.playSoundImpl;
    final origDnd = TaskbarNotifier.dndEnabled;
    final origDndEnd = TaskbarNotifier.dndEndTime;
    TaskbarNotifier.playSoundImpl = () => sounds.add('sound');
    TaskbarNotifier.dndEnabled = true;
    TaskbarNotifier.dndEndTime = DateTime.now().add(const Duration(hours: 1));

    final bob = await loginBob();

    // 未置顶会话 → 免打扰压制
    final py = await startPy('carol', 'password789', 'bob', '4', '压制消息');
    await py.exitCode;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(sounds, isEmpty, reason: '未置顶会话在免打扰时段内不响铃');
    expect(state.getMessages('carol'), isNotEmpty, reason: '消息正常到达但无声');

    // 置顶 carol → 免打扰时段内仍响铃
    await bob.pinConversation('carol');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final py2 = await startPy('carol', 'password789', 'bob', '5', '置顶消息');
    await py2.exitCode;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(sounds, isNotEmpty, reason: '置顶会话在免打扰时段内应响铃（豁免）');

    TaskbarNotifier.playSoundImpl = origImpl;
    TaskbarNotifier.dndEnabled = origDnd;
    TaskbarNotifier.dndEndTime = origDndEnd;
    bob.disconnect();
  });

  test('⑤ 接收端初始数据窗口内到达的实时消息：不丢失并响铃（根因修复）', () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    final sounds = <String>[];
    final origImpl = TaskbarNotifier.playSoundImpl;
    TaskbarNotifier.playSoundImpl = () => sounds.add('sound');

    // alice 在 bob 登录初始数据窗口期间（2000 条离线消息 → 窗口 >1s）发消息
    final py =
        await startPy('alice', 'password123', 'bob', '6', '窗口内第一条', delay: 0.1);
    final bob = SocketService();
    expect(await bob.connect(), isTrue);
    expect(await bob.login('bob', 'password456'), isNull);
    await py.exitCode;
    await Future<void>.delayed(const Duration(milliseconds: 600));

    expect(state.getMessages('alice').any((m) => m.content == '窗口内第一条'), isTrue,
        reason: '初始数据窗口内到达的实时消息不应丢失');
    expect(sounds, isNotEmpty, reason: '窗口内到达的第一条消息应响铃');

    TaskbarNotifier.playSoundImpl = origImpl;
    bob.disconnect();
  });
}
