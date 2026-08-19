// ============================================================
// 阶段 K 用户实测缺陷回归 E2E —— 已查看消息重登后不得复发未读徽标（真实服务端）
// ============================================================
// 缺陷（2026-08-19 用户实测发现）：
//   已查看过的消息在重新登录后依然显示为新消息（未读徽标复发）。
// 根因：offline_messages 状态只在登录时 sent→delivered；实时送达
// （live forward）的私聊/文件消息不翻状态，下次登录被当作未读重推。
// （群聊已有修复：notify_group_members 对在线成员标记 delivered。）
//
// 覆盖场景（真实服务端子进程，.venv 缺失时自动跳过；独立端口 8092）：
//   ① 在线收到并查看过的私聊消息：重登后未读徽标不复发（缺陷锁定，预期红）
//   ② 回归保护：离线期间到达的消息首次登录仍显示未读，查看后重登不复发
//   ③ 在线收到并查看过的群聊消息：重登后未读徽标不复发（既有修复回归）
//   ④ 在线收到但未查看的私聊消息：重登后同样不复发（delivered 语义，预期红）
//
// 注意：①④ 在缺陷修复前断言失败，但每个 SocketService 都注册 addTearDown
// 强制断开——断言失败也不残留连接（否则客户端自动重连会冲击服务端，
// 造成 ②③ 的级联失败）。
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
for u, p in [('alice', 'password123'), ('bob', 'password456'), ('admin', 'adminpass')]:
    db.add_user(u, bcrypt.hashpw(p.encode(), bcrypt.gensalt()))
with db._get_connection() as conn:
    for a, b in [('alice','bob'), ('bob','alice')]:
        conn.execute("INSERT INTO friends (user1,user2,status) VALUES (?,?,'accepted')", (a, b))
    conn.execute("UPDATE users SET is_admin = 1 WHERE username = 'admin'")
    conn.commit()
gid = db.create_group('unread-reg', 'alice')
db.join_group(gid, 'bob')
from server.server_main import Server
server = Server(port=8092)
server.db = db
server.build_listen()
''';

// Python 管理员发送端：以管理员身份发送系统公告（独立进程）
const pyAdmin = r'''
import sys, os, time, threading, ssl, socket
root = os.environ['CHATROOM_ROOT']
sys.path.insert(0, root)
from protocol import recv_message, send_message
msg = sys.argv[1]
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
s = None
for attempt in range(10):
    try:
        s = ctx.wrap_socket(socket.create_connection(('127.0.0.1', 8092)))
        break
    except OSError:
        if attempt == 9:
            raise
        time.sleep(0.5)
send_message(s, 'login', 'admin', extra_headers={'password': 'adminpass', 'admin_secret': 'test-admin-secret'})
def reader():
    try:
        while True:
            h, b = recv_message(s)
            if h is None:
                break
    except Exception:
        pass
threading.Thread(target=reader, daemon=True).start()
time.sleep(1.0)
send_message(s, 'admin_command', msg, extra_headers={'action': 'announcement'})
time.sleep(2.0)
''';

// Python 原始协议发送端：独立进程模拟"另一端用户"
// （AppState 为单例，同一进程内无法并存两个登录用户）
// 用法: user pw to msg_type msg group_id seed
const pySender = r'''
import sys, os, time, threading, ssl, socket
root = os.environ['CHATROOM_ROOT']
sys.path.insert(0, root)
from protocol import recv_message, send_message
user, pw, to, msg_type, msg, gid, seed = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7]
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
# 服务端启动竞态防护：连接重试（E2E 启动抖动时不误报）
s = None
for attempt in range(10):
    try:
        s = ctx.wrap_socket(socket.create_connection(('127.0.0.1', 8092)))
        break
    except OSError:
        if attempt == 9:
            raise
        time.sleep(0.5)
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
time.sleep(1.0)
mid = '%d_%s' % (int(time.time() * 1000), seed)
if msg_type == 'group_chat':
    send_message(s, 'group_chat', msg, extra_headers={'group_id': gid, 'message_id': mid})
else:
    send_message(s, 'chat', msg, extra_headers={'to': to, 'message_id': mid})
time.sleep(2.0)
''';

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
    AppConfig.serverPort = 8092; // 独立端口（8090/8091 已被其他 E2E 占用）
    final script = File('/tmp/opencode/unread_regression_e2e_server.py');
    script.writeAsStringSync(serverScript);
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

  Future<Process> startPy(String user, String pw, String to, String msgType,
      String msg, String gid, String seed) async {
    final root = Directory.current.parent;
    final script = File('/tmp/opencode/unread_regression_py_sender.py');
    script.writeAsStringSync(pySender);
    return Process.start(
        '${root.path}/.venv/bin/python',
        [script.path, user, pw, to, msgType, msg, gid, seed],
        environment: {'CHATROOM_ROOT': root.path},
        workingDirectory: root.path);
  }

  Future<void> sendAnnouncement(String content) async {
    final root = Directory.current.parent;
    final script = File('/tmp/opencode/unread_regression_py_admin.py');
    script.writeAsStringSync(pyAdmin);
    final py = await Process.start(
        '${root.path}/.venv/bin/python', [script.path, content],
        environment: {'CHATROOM_ROOT': root.path},
        workingDirectory: root.path);
    await py.exitCode;
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }

  // 登录并保证测试结束（含断言失败）时断开连接——避免残留连接触发
  // 客户端自动重连冲击服务端（否则会级联失败 ②③）
  Future<SocketService> loginBob() async {
    final bob = SocketService();
    addTearDown(bob.disconnect);
    expect(await bob.connect(), isTrue);
    expect(await bob.login('bob', 'password456'), isNull);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    return bob;
  }

  Future<void> sendChats(String seedPrefix, String content, int count,
      {String msgType = 'chat', String gid = ''}) async {
    for (var i = 0; i < count; i++) {
      final py = await startPy('alice', 'password123', 'bob', msgType,
          '$content${i + 1}', gid, '$seedPrefix$i');
      await py.exitCode;
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }

  test('① 在线收到并查看过的私聊消息：重登后未读徽标不复发（缺陷锁定）', () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    state.setLoggedOut();

    final bob = await loginBob();
    await sendChats('1', '已读消息', 2);
    expect(state.unreadOf('alice'), 2, reason: '在线收到未查看消息应计未读');
    expect(state.getMessages('alice').length, 2);

    // 查看（切换到会话 → 未读清零）
    state.selectChat('alice');
    expect(state.unreadOf('alice'), 0, reason: '查看后未读应清零');

    // 重登：已查看消息不得再显示未读徽标
    bob.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await loginBob();
    expect(state.unreadOf('alice'), 0,
        reason: '已查看过的消息重登后不得复发未读徽标（缺陷锁定）');
    expect(state.getMessages('alice').length, 2,
        reason: '消息仍作为已送达历史可见');
  });

  test('② 回归保护：离线消息首次登录仍显示未读，查看后重登不复发', () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    state.setLoggedOut();

    // bob 不在线：alice 发 2 条离线消息
    await sendChats('2', '离线消息', 2);

    final bob = await loginBob();
    expect(state.unreadOf('alice'), 2, reason: '离线消息首次登录应显示未读（回归保护）');
    state.selectChat('alice');
    expect(state.unreadOf('alice'), 0);

    bob.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await loginBob();
    expect(state.unreadOf('alice'), 0, reason: '查看后重登不复发未读');
  });

  test('③ 在线收到并查看过的群聊消息：重登后未读徽标不复发（既有修复回归）', () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    state.setLoggedOut();

    final bob = await loginBob();
    await sendChats('3', '群在线消息', 1, msgType: 'group_chat', gid: '1');
    expect(state.unreadOf('group_1'), 1, reason: '群聊未读应显示');
    state.selectChat('group_1');
    expect(state.unreadOf('group_1'), 0);

    bob.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await loginBob();
    expect(state.unreadOf('group_1'), 0, reason: '群聊已查看消息重登后不复发未读');
  });

  test('④ 在线收到但未查看的私聊消息：重登后同样不复发（delivered 语义锁定）', () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    state.setLoggedOut();

    final bob = await loginBob();
    await sendChats('4', '未查看消息', 1);
    expect(state.unreadOf('alice'), 1, reason: '本次会话内未查看消息应计未读');
    // 不查看直接重登
    bob.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await loginBob();
    expect(state.unreadOf('alice'), 0,
        reason: '已实时送达（delivered）的消息不得在重登后复发未读');
  });

  test('⑤ 管理员发送公告 → 系统会话出现未读徽标，查看后清零（P-60 缺陷锁定）', () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    state.setLoggedOut();

    await loginBob();
    expect(state.unreadOf('服务器'), 0, reason: '登录初始无公告未读');

    // 管理员（独立进程）发送公告 → 实时广播
    await sendAnnouncement('系统维护通知');
    expect(state.unreadOf('服务器'), 1,
        reason: '管理员发送公告后系统会话应出现未读徽标（缺陷锁定）');
    expect(
        state.getMessages('服务器').any((m) => m.content == '系统维护通知'), isTrue,
        reason: '公告应进入系统消息会话');

    // 查看系统会话 → 徽标清零
    state.selectChat('服务器');
    expect(state.unreadOf('服务器'), 0, reason: '查看系统会话后徽标清零');
  });
}
