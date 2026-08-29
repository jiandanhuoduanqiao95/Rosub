// ============================================================
// P-07 复现 E2E —— 全部设备断开后 Bob 侧 presence 应转离线（真实服务端）
// ============================================================
// 场景：bob（真实 SocketService）在线；alice 双设备（linux + android）
// 登录后全部断开 → bob 的 state.isOnline('alice') 应变为 false。
// 独立端口 8093。
// ============================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/config.dart';
import 'package:chatroom_flutter/services/socket_service.dart';
import 'package:chatroom_flutter/services/state_manager.dart';

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
for u, p in [('alice', 'password123'), ('bob', 'password456')]:
    db.add_user(u, bcrypt.hashpw(p.encode(), bcrypt.gensalt()))
with db._get_connection() as conn:
    conn.execute("INSERT INTO friends (user1,user2,status) VALUES ('alice','bob','accepted')")
    conn.execute("INSERT INTO friends (user1,user2,status) VALUES ('bob','alice','accepted')")
    conn.commit()
from server.server_main import Server
server = Server(port=8093)
server.db = db
server.build_listen()
''';

const pyAlice = r'''
import sys, os, time, threading, ssl, socket
root = os.environ['CHATROOM_ROOT']
sys.path.insert(0, root)
from protocol import recv_message, send_message
user, pw, device, action, seed = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
s = ctx.wrap_socket(socket.create_connection(('127.0.0.1', 8093)))
extra = {'password': pw, 'device_id': device}
send_message(s, 'login', user, extra_headers=extra)
def reader():
    try:
        while True:
            h, b = recv_message(s)
            if h is None:
                break
    except Exception:
        pass
threading.Thread(target=reader, daemon=True).start()
time.sleep(0.8)
if action == 'close':
    s.close()
    time.sleep(0.5)
else:
    time.sleep(8.0)
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
    AppConfig.serverPort = 8093;
    final script = File('/tmp/opencode/l_p07_e2e_server.py');
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

  Future<Process> startAlice(String device, String action, String seed) async {
    final root = Directory.current.parent;
    final script = File('/tmp/opencode/l_p07_alice.py');
    _writeE2eScript(script, pyAlice);
    return Process.start('${root.path}/.venv/bin/python',
        [script.path, 'alice', 'password123', device, action, seed],
        environment: {'CHATROOM_ROOT': root.path},
        workingDirectory: root.path);
  }

  test('alice 全部设备断开后 bob 端 isOnline 转离线', () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    final bob = SocketService();
    expect(await bob.connect(), isTrue);
    expect(await bob.login('bob', 'password456'), isNull);
    await Future<void>.delayed(const Duration(milliseconds: 800));

    // alice 双设备登录（stay=8s，会话保持在线）
    final d1 = await startAlice('linux', 'stay', '1');
    final d2 = await startAlice('android', 'stay', '2');
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(state.isOnline('alice'), isTrue, reason: 'alice 双设备在线，bob 应看到在线');

    // alice 全部设备断开（正常 FIN）
    final c1 = await startAlice('linux', 'close', '3');
    final c2 = await startAlice('android', 'close', '4');
    await c1.exitCode;
    await c2.exitCode;

    // bob 应在数秒内收到 presence 离线
    var offline = false;
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!state.isOnline('alice')) {
        offline = true;
        break;
      }
    }
    expect(offline, isTrue, reason: 'alice 全部设备断开后 bob 侧应转为离线（P-07）');

    // 清理：确保 stay 进程不再存活（正常已自行退出）
    d1.kill(ProcessSignal.sigterm);
    d2.kill(ProcessSignal.sigterm);
    await d1.exitCode;
    await d2.exitCode;

    bob.disconnect();
  });
}