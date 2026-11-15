// ============================================================
// 阶段 N E2E —— 图片自动接收 + 设备管理 + 审计日志（真实服务端，端口 8095）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 N：
//   - N3b（P2-4 扩展）：alice 向 bob 发 ≤5MB .png → bob 自动接受并收到
//     file 消息（无残留待处理请求）；群图片自动接受并路由到群聊
//   - N6（P2-6）：bob 双设备（linux + android）→ fetchSessions 列出 2 个
//     会话 → kickSession('android') → android 会话收到"您已被其他设备远程
//     下线"并断连 → 列表剩 1 个
//   - N7（P2-7）：admin 发公告 + 重置密码 → fetchAuditLogs 可查到对应
//     审计记录（操作者 admin）
//
// 独立端口 8095（阶段 K 约定：各 E2E 独立端口）。缺 .venv 自动跳过。
// 实现前：本文件引用尚未实现的 SocketService 方法，编译失败或用例红，
// 属 TDD 红。实现后：全部转绿。
// ============================================================

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/config.dart';
import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/message_cache.dart';
import 'package:chatroom_flutter/services/message_cache_store.dart';
import 'package:chatroom_flutter/services/sent_file_store.dart';
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
for u, p in [('alice', 'password123'), ('bob', 'password456'), ('admin', 'adminpass')]:
    db.add_user(u, bcrypt.hashpw(p.encode(), bcrypt.gensalt()))
with db._get_connection() as conn:
    conn.execute("INSERT INTO friends (user1,user2,status) VALUES ('alice','bob','accepted')")
    conn.execute("INSERT INTO friends (user1,user2,status) VALUES ('bob','alice','accepted')")
    conn.execute("UPDATE users SET is_admin = 1 WHERE username = 'admin'")
    conn.commit()
# 图片群（N3b 群图片路由测试用：alice 群主 + bob 成员，新库首群 id=1）
db.create_group('图片群', 'alice')
db.join_group(1, 'bob')
from server.server_main import Server
server = Server(port=8095)
server.db = db
server.build_listen()
''';

const aliceSender = r'''
import sys, os, time, threading, ssl, socket
root = os.environ['CHATROOM_ROOT']
sys.path.insert(0, root)
from protocol import recv_message, send_message
user, pw, target, count = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
s = ctx.wrap_socket(socket.create_connection(('127.0.0.1', 8095)))
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
time.sleep(0.6)
for i in range(count):
    send_message(s, 'chat', '离线消息%d' % i,
                 extra_headers={'to': target, 'message_id': 'off-%d-%f' % (i, time.time())})
    time.sleep(0.3)
time.sleep(1.0)
s.close()
''';

const fileSender = r'''
import sys, os, time, threading, ssl, socket
root = os.environ['CHATROOM_ROOT']
sys.path.insert(0, root)
from protocol import recv_message, send_message
user, pw, target = sys.argv[1], sys.argv[2], sys.argv[3]
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
s = ctx.wrap_socket(socket.create_connection(('127.0.0.1', 8095)))
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
time.sleep(0.6)
png = bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03])
send_message(s, 'file', png, extra_headers={
    'to': target,
    'filename': 'photo.png',
    'filesize': str(len(png)),
    'message_id': 'n3b-%f' % time.time(),
})
time.sleep(2.0)
s.close()
''';

const groupFileSender = r'''
import sys, os, time, threading, ssl, socket
root = os.environ['CHATROOM_ROOT']
sys.path.insert(0, root)
from protocol import recv_message, send_message
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
s = ctx.wrap_socket(socket.create_connection(('127.0.0.1', 8095)))
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
png = bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03])
send_message(s, 'file', png, extra_headers={
    'to': 'group_1',
    'filename': 'group_photo.png',
    'filesize': str(len(png)),
    'message_id': 'n3b-grp-%f' % time.time(),
})
time.sleep(2.0)
s.close()
''';

const sameNameFileSender = r'''
import sys, os, time, threading, ssl, socket
root = os.environ['CHATROOM_ROOT']
sys.path.insert(0, root)
from protocol import recv_message, send_message
user, pw, to, filename = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
s = ctx.wrap_socket(socket.create_connection(('127.0.0.1', 8095)))
send_message(s, 'login', user, extra_headers={'password': pw, 'device_id': 'linux'})
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
png1 = bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x01])
png2 = bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x02, 0x02])
for payload in (png1, png2):
    send_message(s, 'file', payload, extra_headers={
        'to': to,
        'filename': filename,
        'filesize': str(len(payload)),
        'message_id': 'opt8same-%f-%d' % (time.time(), len(payload)),
    })
    time.sleep(1.0)
time.sleep(2.0)
s.close()
''';

const androidSession = r'''
import sys, os, time, threading, ssl, socket
root = os.environ['CHATROOM_ROOT']
sys.path.insert(0, root)
from protocol import recv_message, send_message
user, pw, device = sys.argv[1], sys.argv[2], sys.argv[3]
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
s = ctx.wrap_socket(socket.create_connection(('127.0.0.1', 8095)))
send_message(s, 'login', user, extra_headers={'password': pw, 'device_id': device})
def reader():
    try:
        while True:
            h, b = recv_message(s)
            if h is None:
                print('CLOSED', flush=True)
                return
            if h.get('type') == 'error' and '远程下线' in b.decode():
                print('KICKED', flush=True)
                return
    except Exception:
        print('CLOSED', flush=True)
threading.Thread(target=reader, daemon=True).start()
time.sleep(30)
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

/// 轮询等待服务器端口就绪（全量并行负载下固定延时不可靠：
/// 7 个 E2E 文件同时拉起真实服务端，启动窗口会拉长）。
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

/// 写入 E2E 辅助脚本：确保 /tmp/opencode 目录存在
/// （部分环境该目录缺失会导致 writeAsStringSync 抛 PathNotFoundException）
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
    AppConfig.serverPort = 8095;
    final script = File('/tmp/opencode/n_stage_e2e_server.py');
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
    // 等待服务端端口就绪（负载下启动窗口可能远超 6s）
    final ready = await waitForServerReady('127.0.0.1', 8095);
    if (!ready) {
      fail('E2E 服务端未在超时内就绪（端口 8095）');
    }
  });

  tearDownAll(() async {
    serverProcess?.kill(ProcessSignal.sigkill);
    await serverProcess?.exitCode;
    AppConfig.serverPort = 8090;
  });

  Future<Process> startPython(String name, List<String> args) async {
    final root = Directory.current.parent;
    final script = File('/tmp/opencode/n_stage_e2e_$name.py');
    final body = switch (name) {
      'alice' => aliceSender,
      'file' => fileSender,
      'groupfile' => groupFileSender,
      'samefile' => sameNameFileSender,
      _ => androidSession,
    };
    _writeE2eScript(script, body);
    return Process.start(
        '${root.path}/.venv/bin/python', [script.path, ...args],
        environment: {'CHATROOM_ROOT': root.path}, workingDirectory: root.path);
  }

  Future<List<String>> collectOutput(Process proc) async {
    final lines = <String>[];
    proc.stdout
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen(lines.add);
    return lines;
  }

  test('N3b —— 小图片自动接收：bob 自动接受 alice 发的 ≤5MB .png', () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    final bob = SocketService();
    expect(await bob.connect(), isTrue);
    expect(await bob.login('bob', 'password456'), isNull);

    // alice 向已登录的 bob 发一个 ≤5MB 的 .png（走 file_request →
    // 客户端自动接受 → 服务端推送 file → 客户端落盘）
    final alice = await startPython('file', ['alice', 'password123', 'bob']);
    await alice.exitCode;

    final ok = await waitFor(() {
      final msgs = state.getMessages('alice');
      return msgs
          .any((m) => m.type == 'file' && (m.filename ?? '').endsWith('.png'));
    });
    expect(ok, isTrue, reason: 'bob 应自动接受并收到 alice 的 .png 文件消息');
    expect(state.hasPendingFileRequests, isFalse,
        reason: '小图片应自动接受，不残留待处理文件请求（无手动确认弹窗）');
    bob.disconnect();
  });

  test('N3b 回归（问题 3）—— 群图片自动接收并路由到群聊，不落入私聊', () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    final bob = SocketService();
    expect(await bob.connect(), isTrue);
    expect(await bob.login('bob', 'password456'), isNull);

    // alice 向群 1（图片群，id=1）发一个 ≤5MB 的 .png
    final alice =
        await startPython('groupfile', ['alice', 'password123', 'bob']);
    await alice.exitCode;

    // 本文件 E2E 服务端 DB 跨测试共享：前一测试的私聊图片会在本测试
    // 重登时重推回私聊 alice 会话（正确行为）——故按 messageId 前缀
    // 'n3b-grp-' 精确断言本次群文件的路由
    final ok = await waitFor(() {
      final groupMsgs = state.getMessages('group_1');
      return groupMsgs.any((m) =>
          m.type == 'file' &&
          (m.messageId.startsWith('n3b-grp-')) &&
          (m.filename ?? '').endsWith('.png'));
    });
    expect(ok, isTrue, reason: '群图片应自动接收并路由到 group_1');
    expect(
      state
          .getMessages('alice')
          .where((m) => m.type == 'file' && m.messageId.startsWith('n3b-grp-'))
          .isEmpty,
      isTrue,
      reason: '群文件不得落入与 alice 的私聊（问题 3 回归）',
    );
    expect(state.hasPendingFileRequests, isFalse,
        reason: '群小图片同样自动接受，无残留待处理请求');
    bob.disconnect();
  });

  test('opt8 #13 —— 同名图片连续发送：接收方路径唯一、内容不互相覆盖',
      () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    final bob = SocketService();
    expect(await bob.connect(), isTrue);
    expect(await bob.login('bob', 'password456'), isNull);

    final stamp = DateTime.now().microsecondsSinceEpoch;
    final name = 'opt8same_$stamp.png';
    final png1 = <int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x01
    ];
    final png2 = <int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x02, 0x02
    ];
    final receivedPaths = <String>[];
    try {
      final alice =
          await startPython('samefile', ['alice', 'password123', 'bob', name]);
      await alice.exitCode;

      final ok = await waitFor(() {
        final msgs = state
            .getMessages('alice')
            .where((m) => m.type == 'file' && m.filename == name)
            .toList();
        return msgs.length == 2 &&
            msgs.every(
                (m) => m.filePath != null && File(m.filePath!).existsSync());
      });
      expect(ok, isTrue, reason: 'bob 应自动接收两条同名图片且均已落盘');

      final two = state
          .getMessages('alice')
          .where((m) => m.type == 'file' && m.filename == name)
          .toList();
      final paths = two.map((m) => m.filePath!).toList();
      expect(paths.toSet().length, 2,
          reason: 'messageId 唯一路径：同名文件不得互相覆盖');

      final contents =
          paths.map((p) => File(p).readAsBytesSync().join(',')).toList();
      expect(contents.any((c) => c == png1.join(',')), isTrue,
          reason: '第一份内容完整保留');
      expect(contents.any((c) => c == png2.join(',')), isTrue,
          reason: '第二份内容完整保留（旧实现同名覆盖会丢一份）');
      receivedPaths.addAll(paths);
    } finally {
      for (final p in receivedPaths) {
        final f = File(p);
        if (f.existsSync()) f.deleteSync();
      }
      bob.disconnect();
    }
  });

  test('N6 —— 设备管理：双设备列表 + 远程下线 android', () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    final bob = SocketService();
    expect(await bob.connect(), isTrue);
    expect(await bob.login('bob', 'password456'), isNull);

    // 第二个设备（android）登录
    final android =
        await startPython('android', ['bob', 'password456', 'android']);
    final out = await collectOutput(android);

    // 拉取会话列表：linux（当前）+ android
    // （android 为独立 Python 进程，登录时序不定——反复拉取直到 2 个）
    var listed = false;
    for (var i = 0; i < 40 && !listed; i++) {
      await bob.fetchSessions();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      listed = state.sessions.length >= 2;
    }
    expect(listed, isTrue, reason: '应列出 2 个会话（实际: ${state.sessions.length}）');
    final ids = state.sessions.map((s) => s.deviceId).toList();
    expect(ids, contains('linux'));
    expect(ids, contains('android'));
    expect(state.sessions.firstWhere((s) => s.deviceId == 'linux').isCurrent,
        isTrue,
        reason: 'linux 为当前会话');

    // 远程下线 android
    await bob.kickSession('android');
    final kicked = await waitFor(() => out.contains('KICKED'),
        timeout: const Duration(seconds: 8));
    expect(kicked, isTrue, reason: 'android 会话应收到"您已被其他设备远程下线"并断连（输出: $out）');

    // 重新拉取会话列表 → 剩 1 个会话
    await bob.fetchSessions();
    final shrunk = await waitFor(() => state.sessions.length == 1);
    expect(shrunk, isTrue,
        reason: '下线后会话列表应剩 1 个（实际: ${state.sessions.length}）');
    bob.disconnect();
    android.kill(ProcessSignal.sigkill);
  });

  test('N7 —— 审计日志：公告 + 重置密码可查询', () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    final admin = SocketService();
    expect(await admin.connect(), isTrue);
    expect(
        await admin.login('admin', 'adminpass',
            adminSecret: 'test-admin-secret'),
        isNull);

    // 敏感操作：发公告 + 重置 bob 密码
    await admin.adminCommand('announcement', announcement: 'E2E 审计公告');
    await admin.adminResetPassword('bob', 'newpass456');
    await Future<void>.delayed(const Duration(milliseconds: 500));

    await admin.fetchAuditLogs();
    final found = await waitFor(() {
      final logs = state.auditLogs;
      return logs.any((e) =>
              e.action == 'announcement' &&
              e.operator == 'admin' &&
              e.detail == 'E2E 审计公告') &&
          logs.any((e) =>
              e.action == 'reset_password' &&
              e.operator == 'admin' &&
              e.target == 'bob');
    });
    expect(found, isTrue,
        reason: '审计日志应包含公告与重置密码记录（实际: '
            '${state.auditLogs.map((e) => "${e.operator}/${e.action}/${e.target}").toList()}）');
    admin.disconnect();
  });

  test('opt8 #1 —— sendFileBytes：本地回显带 filePath，缓存重开仍在', () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    final tmp = await Directory.systemTemp.createTemp('opt8_sendfile_e2e');
    final cacheDb = '${tmp.path}/cache.db';
    await MessageCache.init(dbPath: cacheDb);
    await SentFileStore.init();
    final alice = SocketService();
    final sentCopies = <String>[];
    try {
      expect(await alice.connect(), isTrue);
      expect(await alice.login('alice', 'password123'), isNull);

      final bytes = Uint8List.fromList(
          [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02]);
      final ok = await alice.sendFileBytes('bob', bytes, 'opt8shot.png');
      expect(ok, isTrue);

      final sent = state.getMessages('bob').firstWhere(
          (m) => m.type == 'file' && m.filename == 'opt8shot.png');
      expect(sent.filePath, isNotNull, reason: 'sendFileBytes 应带 filePath');
      expect(File(sent.filePath!).existsSync(), isTrue,
          reason: 'sent_files 副本应已落盘');
      expect(SentFileStore.pathOf(sent.messageId), sent.filePath);
      sentCopies.add(sent.filePath!);

      await MessageCache.flush();
      await MessageCache.resetForTest();
      final reopened = MessageCacheStore();
      await reopened.init(dbPath: cacheDb);
      final rows = await reopened.loadMessages('bob');
      final cached =
          rows.firstWhere((m) => m.messageId == sent.messageId);
      expect(cached.filePath, sent.filePath,
          reason: '重启（缓存重开）后 filePath 不丢——缩略图恢复的数据源');
      await reopened.close();
    } finally {
      await MessageCache.resetForTest();
      alice.disconnect();
      for (final path in sentCopies) {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      }
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    }
  });

  test('opt8 #1 —— sendFileBytes：副本落盘失败不阻塞发送', () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    if (Platform.isWindows) {
      markTestSkipped('chmod 权限模拟仅 POSIX 可用');
      return;
    }
    final dir = Directory('sent_files');
    final preExisted = dir.existsSync();
    final originalMode = preExisted ? dir.statSync().mode & 0x1FF : null;
    if (!preExisted) dir.createSync();
    await Process.run('chmod', ['0500', dir.path]);
    final alice = SocketService();
    try {
      expect(await alice.connect(), isTrue);
      expect(await alice.login('alice', 'password123'), isNull);

      final ok = await alice.sendFileBytes(
          'bob', Uint8List.fromList([1, 2, 3]), 'opt8fail.png');
      expect(ok, isTrue, reason: '副本落盘失败不应阻塞发送');
      final sent = state.getMessages('bob').firstWhere(
          (m) => m.type == 'file' && m.filename == 'opt8fail.png');
      expect(sent.filePath, isNull, reason: '落盘失败时 filePath 为 null');
    } finally {
      final restoreMode = originalMode != null
          ? originalMode.toRadixString(8).padLeft(4, '0')
          : '0700';
      await Process.run('chmod', [restoreMode, dir.path]);
      if (!preExisted) {
        try {
          await dir.delete();
        } catch (_) {}
      }
      alice.disconnect();
    }
  });


}

