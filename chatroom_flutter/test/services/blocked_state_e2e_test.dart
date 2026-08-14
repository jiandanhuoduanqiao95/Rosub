// ============================================================
// 阶段 J 修复 —— 拉黑状态跨登录恢复 E2E 契约（真实服务端）
// ============================================================
// 背景（dart:io VM 缺陷）：客户端 SecureSocket 存在连续 add+flush
// 批次静默丢失的竞态（随机触发），登录后立即连发 list_blocked 等
// 请求可能整条丢失 → 重登后黑名单状态不恢复、长按好友显示"拉黑"
// 而非"取消拉黑"。
//
// 修复方案：服务端把好友元数据/黑名单随登录初始数据主动推送
// （客户端读侧可靠），客户端登录后不再连发请求。
//
// 本测试启动真实 Python 服务端子进程 + 真实 SocketService，
// 验证：拉黑 → 退出 → 重新登录 → 黑名单状态自动恢复。
// 依赖本地 .venv Python（缺失时跳过，不阻塞其它环境）。
// ============================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
db.add_user('alice', bcrypt.hashpw(b'password123', bcrypt.gensalt()))
db.add_user('bob', bcrypt.hashpw(b'password456', bcrypt.gensalt()))
with db._get_connection() as conn:
    conn.execute("INSERT INTO friends (user1,user2,status) VALUES ('alice','bob','accepted')")
    conn.execute("INSERT INTO friends (user1,user2,status) VALUES ('bob','alice','accepted')")
    conn.commit()
from server.server_main import Server
server = Server(port=8090)
server.db = db
server.build_listen()
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
    final script = File('/tmp/opencode/j_e2e_server.py');
    script.writeAsStringSync(serverScript);
    serverProcess = await Process.start(
      python,
      [script.path],
      environment: {'CHATROOM_ROOT': root.path},
      workingDirectory: root.path,
    );
    serverProcess!.stderr.transform(const SystemEncoding().decoder).listen((s) {
      if (s.contains('block_user') ||
          s.contains('list_blocked') ||
          s.contains('登录成功')) {
        // ignore: avoid_print
        print('SRV: ${s.trim()}');
      }
    });
    await Future<void>.delayed(const Duration(seconds: 3));
  });

  tearDownAll(() async {
    serverProcess?.kill(ProcessSignal.sigkill);
    await serverProcess?.exitCode;
  });

  test('拉黑后重新登录，黑名单状态自动恢复（服务端初始数据推送）', () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    final service = SocketService();

    final ok1 = await service.connect();
    expect(ok1, isTrue);
    final err1 = await service.login('alice', 'password123');
    expect(err1, isNull);

    await service.blockUser('bob');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(state.isBlocked('bob'), isTrue, reason: '拉黑后本地状态即时更新');

    service.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final ok2 = await service.connect();
    expect(ok2, isTrue);
    final err2 = await service.login('alice', 'password123');
    expect(err2, isNull);

    // 黑名单随登录初始数据推送，listen loop 启动后即刻恢复
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (state.isBlocked('bob')) break;
    }
    expect(state.isBlocked('bob'), isTrue,
        reason: '重新登录后黑名单状态应自动恢复（长按显示"取消拉黑"）');

    service.disconnect();
  });

  test('重新登录后好友备注/分组同样随初始数据恢复', () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    final service = SocketService();

    final ok1 = await service.connect();
    expect(ok1, isTrue);
    expect(await service.login('alice', 'password123'), isNull);

    await service.setFriendNote('bob', '阿波');
    await service.setFriendGroup('bob', '家人');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(state.friendNoteOf('bob'), '阿波');

    service.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final ok2 = await service.connect();
    expect(ok2, isTrue);
    expect(await service.login('alice', 'password123'), isNull);

    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (state.friendNoteOf('bob') == '阿波') break;
    }
    expect(state.friendNoteOf('bob'), '阿波', reason: '重新登录后备注名应随初始数据恢复');
    expect(state.friendGroupOf('bob'), '家人', reason: '重新登录后分组应随初始数据恢复');

    service.disconnect();
  });
}
