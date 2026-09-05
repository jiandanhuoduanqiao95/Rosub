// ============================================================
// 阶段 O E2E —— 群公告/群置顶/历史在线区分/定时消息/名片卡片
// （真实服务端，端口 8096）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 O 全链路：
//   - O1 群公告：群主 setGroupAnnouncement → 成员实时收到 group_announcement
//     消息 + list_groups 刷新（announcement 字段更新）
//   - O2 群置顶：成员发群消息 → 群主 pinGroupMessage → 成员 list_groups
//     刷新（pinned_preview 非空）
//   - O5 定时消息：bob scheduleChat 到 alice（+2s）→ 服务端定时器到点
//     投递，alice 实时收到
//
// 2026-08-30 用户反馈修订：O3 历史/在线区分与 O9 名片/位置/日程卡片已按
// 用户决策移除，对应 E2E 用例一并删除。
//
// 独立端口 8096（阶段 K 约定：各 E2E 独立端口）。缺 .venv 自动跳过。
// 实现前：本文件引用尚未实现的 SocketService 方法，编译失败或用例红，
// 属 TDD 红。实现后：全部转绿。
// ============================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
import sys, os, time, tempfile
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
for u, p in [('alice', 'password123'), ('bob', 'password456'),
             ('carol', 'password789'), ('admin', 'adminpass')]:
    db.add_user(u, bcrypt.hashpw(p.encode(), bcrypt.gensalt()))
with db._get_connection() as conn:
    conn.execute("INSERT INTO friends (user1,user2,status) VALUES ('alice','bob','accepted')")
    conn.execute("INSERT INTO friends (user1,user2,status) VALUES ('bob','alice','accepted')")
    conn.commit()
# 公告群（首群 id=1：alice 群主 + bob 成员）
db.create_group('公告群', 'alice')
db.join_group(1, 'bob')
from server.server_main import Server
server = Server(port=8096)
server.db = db
server.build_listen()
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

/// 轮询等待服务器端口就绪（多 E2E 并行拉起时固定延时不可靠）。
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
void _writeE2eScript(File file, String content) {
  Directory('/tmp/opencode').createSync(recursive: true);
  file.writeAsStringSync(content);
}

Future<SocketService> connectAndLogin(String username, String password,
    {String? adminSecret}) async {
  final service = SocketService();
  expect(await service.connect(), isTrue);
  expect(await service.login(username, password, adminSecret: adminSecret),
      isNull);
  return service;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
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
    final script = File('/tmp/opencode/o_stage_e2e_server.py');
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

  test('O1 —— 群公告：群主发布 → 成员实时收到 + 列表字段更新', () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    final bob = await connectAndLogin('bob', 'password456');
    final alice = await connectAndLogin('alice', 'password123');

    await alice.setGroupAnnouncement(1, 'E2E 群公告');

    final got = await waitFor(() {
      return state
          .getMessages('group_1')
          .any((m) => m.type == 'group_announcement' && m.content == 'E2E 群公告');
    });
    expect(got, isTrue, reason: '成员应实时收到群公告消息（group_1 内）');
    final annUpdated = await waitFor(() =>
        state.groups.any((g) => g.id == 1 && g.announcement == 'E2E 群公告'));
    expect(annUpdated, isTrue, reason: 'list_groups 刷新后 announcement 字段更新');

    alice.disconnect();
    bob.disconnect();
  });

  test('O2 —— 群置顶：群主置顶成员消息 → 成员列表字段更新', () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    final alice = await connectAndLogin('alice', 'password123');
    final bob = await connectAndLogin('bob', 'password456');

    // bob 发一条群消息
    await bob.sendGroupChat(1, '待置顶消息');
    // alice 收到推送后取 messageId 发起置顶
    String? pinned;
    final found = await waitFor(() {
      for (final m in state.getMessages('group_1')) {
        if (m.type == 'group_chat' && m.content == '待置顶消息') {
          pinned = m.messageId;
          return true;
        }
      }
      return false;
    });
    expect(found, isTrue, reason: '群主应先收到成员消息');
    await alice.pinGroupMessage(1, pinned!);

    final refreshed = await waitFor(() {
      final g = state.groups.where((g) => g.id == 1).toList();
      return g.isNotEmpty && g.first.pinnedPreview == '待置顶消息';
    });
    expect(refreshed, isTrue, reason: '置顶后 list_groups 刷新携带 pinned_preview');

    alice.disconnect();
    bob.disconnect();
  });

  test('O5 —— 定时消息：到点由服务端投递', () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    final alice = await connectAndLogin('alice', 'password123');
    final bob = await connectAndLogin('bob', 'password456');

    final at = DateTime.now().add(const Duration(seconds: 2));
    await bob.scheduleChat('alice', '定时 E2E 消息', at);

    final delivered = await waitFor(
      () => state
          .getMessages('bob')
          .any((m) => m.type == 'chat' && m.content == '定时 E2E 消息'),
      timeout: const Duration(seconds: 15),
    );
    expect(delivered, isTrue, reason: '服务端定时器到点应投递给在线的 alice');
    final msg =
        state.getMessages('bob').firstWhere((m) => m.content == '定时 E2E 消息');
    expect(msg.sender, 'bob', reason: '投递消息归属发送者 bob');

    alice.disconnect();
    bob.disconnect();
  });
}
