// ============================================================
// 阶段 P E2E —— R-P21 已下载文件重登不重复下载（真实服务端，端口 8096）
// ============================================================
// 缺陷（2026-09-05 用户手测）：接收方重登后，此前已完整接收过的文件
//   再次全量推送文件体（进度条气泡重现 + 重复消耗带宽）。
//
// 修复：服务端 push_offline_files 按 file_request_resolutions 判定——
//   本设备已接受过的文件改推 file_meta（同头部、无消息体，追加
//   filesize 头）；客户端仅重建/对账气泡。本文件锁定客户端行为：
//   - 原地重登（缓存完好）：气泡去重保留、filePath 指向的本地文件
//     不被重写（lastModified 不变）、无传输进度
//   - 清空本地状态后重登（模拟重装/缓存丢失）：file_meta 重建气泡
//     （fileData 为空、不落盘），本地文件同样不被重写
//
// 独立端口 8096（各 E2E 独立端口约定）。缺 .venv 自动跳过。
// ============================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/config.dart';
import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/socket_service.dart';
import 'package:chatroom_flutter/services/state_manager.dart';

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
from database import Database
db = Database(db_path)
for u, p in [('alice', 'password123'), ('bob', 'password456')]:
    db.add_user(u, bcrypt.hashpw(p.encode(), bcrypt.gensalt()))
with db._get_connection() as conn:
    conn.execute("INSERT INTO friends (user1,user2,status) VALUES ('alice','bob','accepted')")
    conn.execute("INSERT INTO friends (user1,user2,status) VALUES ('bob','alice','accepted')")
    conn.commit()
from server.server_main import Server
server = Server(port=8096)
server.db = db
server.build_listen()
''';

const fileSender = r'''
import sys, os, time, threading, ssl, socket
root = os.environ['CHATROOM_ROOT']
sys.path.insert(0, root)
from protocol import recv_message, send_message
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
s = ctx.wrap_socket(socket.create_connection(('127.0.0.1', 8096)))
send_message(s, 'login', 'alice', extra_headers={'password': 'password123'})
def reader():
    try:
        while True:
            h, b = recv_message(s)
            if h is None:
                break
    except Exception:
        pass
threading.Thread(target=reader, daemon=True).start()
time.sleep(0.6)
png = bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x07, 0x08])
send_message(s, 'file', png, extra_headers={
    'to': 'bob',
    'filename': 'rpmeta_photo.png',
    'filesize': str(len(png)),
    'message_id': 'rpmeta-1',
})
time.sleep(2.0)
s.close()
''';

Future<bool> waitFor(bool Function() cond,
    {Duration timeout = const Duration(seconds: 20)}) async {
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

void _writeE2eScript(File file, String content) {
  Directory('/tmp/opencode').createSync(recursive: true);
  file.writeAsStringSync(content);
}

void main() {
  Process? serverProcess;
  var skipped = false;

  setUp(resetState);

  setUpAll(() async {
    final root = Directory.current.parent;
    final python = '${root.path}/.venv/bin/python';
    if (!File(python).existsSync()) {
      skipped = true;
      return;
    }
    AppConfig.serverPort = 8096;
    final script = File('/tmp/opencode/p_file_meta_e2e_server.py');
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
    final ready = await waitForServerReady('127.0.0.1', 8096);
    if (!ready) {
      fail('E2E 服务端未在超时内就绪（端口 8096）');
    }
  });

  tearDownAll(() async {
    serverProcess?.kill(ProcessSignal.sigkill);
    await serverProcess?.exitCode;
    AppConfig.serverPort = 8090;
  });

  Future<Process> startPython(String name) async {
    final root = Directory.current.parent;
    final script = File('/tmp/opencode/p_file_meta_e2e_$name.py');
    _writeE2eScript(script, fileSender);
    return Process.start(
      '${root.path}/.venv/bin/python',
      [script.path],
      environment: {'CHATROOM_ROOT': root.path},
      workingDirectory: root.path,
    );
  }

  ChatMessage? metaBubble() {
    for (final m in state.getMessages('alice')) {
      if (m.type == 'file' && m.messageId == 'rpmeta-1') return m;
    }
    return null;
  }

  test('R-P21 —— 已接收文件重登：气泡保留、本地文件不被重写、无传输进度',
      () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    final bob = SocketService();
    expect(await bob.connect(), isTrue);
    expect(await bob.login('bob', 'password456'), isNull);

    // alice 发 ≤5MB png → bob 自动接受（N3b）→ 收到 file 消息（有 filePath）
    final alice = await startPython('file');
    await alice.exitCode;
    final ok = await waitFor(() => metaBubble() != null);
    expect(ok, isTrue, reason: 'bob 应自动接受并收到 rpmeta-1 文件消息');
    final first = metaBubble()!;
    expect(first.filePath, isNotNull, reason: '接收气泡应记录落盘路径');
    final localFile = File(first.filePath!);
    expect(localFile.existsSync(), isTrue, reason: '文件应已落盘');
    final mtimeBefore = localFile.lastModifiedSync();
    expect(state.transferFraction('rpmeta-1'), isNull,
        reason: '首次接收完成后不应残留传输进度');

    // 原地重登（同设备 linux，缓存完好）：服务端只补推 file_meta——
    // 气泡去重保留，本地文件不被重写（旧实现会全量重推文件体）
    bob.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final bob2 = SocketService();
    expect(await bob2.connect(), isTrue);
    expect(await bob2.login('bob', 'password456'), isNull);
    await Future<void>.delayed(const Duration(seconds: 3));

    final after = metaBubble();
    expect(after, isNotNull, reason: '重登后气泡应保留（去重或元数据重建）');
    expect(localFile.lastModifiedSync(), mtimeBefore,
        reason: '重登后本地文件不得被重写（不重复下载）');
    expect(state.transferFraction('rpmeta-1'), isNull,
        reason: '重登补推不得产生传输进度');

    // 清空本地状态后重登（模拟重装/缓存丢失）：file_meta 仅重建气泡
    // 元数据（fileData 为空、不落盘），本地文件同样不被重写
    resetState();
    final bob3 = SocketService();
    expect(await bob3.connect(), isTrue);
    expect(await bob3.login('bob', 'password456'), isNull);
    final rebuilt = await waitFor(() => metaBubble() != null);
    expect(rebuilt, isTrue, reason: 'file_meta 应重建气泡（缓存丢失场景）');
    expect(metaBubble()!.fileData, isNull,
        reason: '元数据重建的气泡不携带文件字节');
    expect(localFile.lastModifiedSync(), mtimeBefore,
        reason: '缓存丢失场景同样不得重写本地文件');
    bob3.disconnect();
  });
}
