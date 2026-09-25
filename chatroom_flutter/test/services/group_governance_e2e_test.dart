// ============================================================
// 阶段 M —— 群组治理 + 运维 E2E 契约（真实服务端，TDD 未实现）
// ============================================================
// 场景（Dart 侧单一用户 carol + Python 辅助客户端 alice/bob）：
//   1. M1 群主标识：登录初始 list_groups 携带 created_by → isGroupOwner
//   2. M2 邀请制：alice 邀请 carol → carol 收到 group_invite →
//      acceptGroupInvite 入群（state.groups 含该群）
//   3. M2 入群审批：carol requestJoinGroup → alice approve →
//      carol 群列表刷新（state.groups 含目标群）
//   4. M1 踢人：alice 将 carol 移出群组 → carol 群列表移除该群
//   5. M1 改名：alice 改名 → carol 群名称更新
//   6. M3 历史可见性：关闭前 carol 可见 bob 的加入前消息；alice 关闭后
//      carol fetchHistory 为空（P1-18 过滤）
//   7. M1 转让群主：alice 转让给 carol → carol isGroupOwner 转 true
//   8. M8 文件列表：carol 请求 list_files → 状态记录空/有数据（契约接线）
//
// 独立端口 8094（约定见 AGENTS.md：notify=8091 / blocked=8090 /
// unread=8092 / presence=8093）。
// 实现前：本文件引用尚未实现的服务端协议与客户端方法，用例红，属 TDD 红。
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
for u, p in [('alice', 'password123'), ('bob', 'password456'),
             ('carol', 'password789')]:
    db.add_user(u, bcrypt.hashpw(p.encode(), bcrypt.gensalt()))
# 群 1：开发组（alice 群主 + bob）；群 2：新群（alice 群主 + bob）；
# 群 3：离线群（仅 alice，供"离线邀请登录补发"验证）
g1 = db.create_group('开发组', 'alice')
g2 = db.create_group('新群', 'alice')
g3 = db.create_group('离线群', 'alice')
db.join_group(g1, 'bob')
db.join_group(g2, 'bob')
from server.server_main import Server
server = Server(port=8094)
server.db = db
server.build_listen()
''';

// alice：群主操作脚本（固定时间轴，各动作间隔宽松避免竞态）
const pyAlice = r'''
import sys, os, time, threading, ssl, socket
root = os.environ['CHATROOM_ROOT']
sys.path.insert(0, root)
from protocol import recv_message, send_message
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
s = ctx.wrap_socket(socket.create_connection(('127.0.0.1', 8094)))
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
time.sleep(1.5)
def act(typ, body='', **kw):
    send_message(s, typ, body, extra_headers={str(k): str(v) for k, v in kw.items()})
    time.sleep(0.4)
# t≈1.9s 邀请 carol 加入群 1（Dart 侧接受）
act('invite_group_member', group_id=1, target='carol')
# t≈2.3s 等待 carol 的入群申请（t≈0.7s 发出）后批准（预留到 5.5s 执行）
time.sleep(2.6)
act('approve_join_request', group_id=2, target='carol')
# t≈5.5s 把 carol 移出群 1
time.sleep(2.2)
act('kick_member', group_id=1, target='carol')
# t≈8.1s 群 2 改名
time.sleep(2.2)
act('rename_group', group_id=2, name='新群名')
# t≈10.7s 关闭群 2 新成员历史可见性
time.sleep(2.2)
act('set_group_history_visible', group_id=2, visible=0, limit=50)
# t≈13.3s 把群 2 转让给 carol
time.sleep(2.2)
act('transfer_owner', group_id=2, target='carol')
# t≈14.1s 邀请 carol 加入群 3（carol 已离线 → 登录时补发 group_invite）
time.sleep(1.5)
act('invite_group_member', group_id=3, target='carol')
time.sleep(4.0)
s.close()
''';

// bob：向群 2 发一条 carol 加入前的消息（历史可见性判定依据）
const pyBob = r'''
import sys, os, time, threading, ssl, socket
root = os.environ['CHATROOM_ROOT']
sys.path.insert(0, root)
from protocol import recv_message, send_message
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
s = ctx.wrap_socket(socket.create_connection(('127.0.0.1', 8094)))
send_message(s, 'login', 'bob', extra_headers={'password': 'password456'})
def reader():
    try:
        while True:
            h, b = recv_message(s)
            if h is None:
                break
    except Exception:
        pass
threading.Thread(target=reader, daemon=True).start()
time.sleep(3.0)
send_message(s, 'group_chat', 'before-carol', extra_headers={
    'group_id': '2', 'message_id': 'm-bob-pre-join'})
time.sleep(20.0)
s.close()
''';

Future<bool> waitUntil(bool Function() cond,
    {int tries = 40,
    Duration delay = const Duration(milliseconds: 250)}) async {
  for (var i = 0; i < tries; i++) {
    if (cond()) return true;
    await Future<void>.delayed(delay);
  }
  return cond();
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

  setUpAll(() async {
    final root = Directory.current.parent;
    final python = '${root.path}/.venv/bin/python';
    if (!File(python).existsSync()) {
      skipped = true;
      return;
    }
    AppConfig.serverPort = 8094;
    final script = File('/tmp/opencode/m_group_governance_server.py');
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

  Future<Process> startHelper(
      String name, String scriptSrc, String pyFile) async {
    final root = Directory.current.parent;
    final script = File('/tmp/opencode/$pyFile');
    _writeE2eScript(script, scriptSrc);
    return Process.start('${root.path}/.venv/bin/python', [script.path],
        environment: {'CHATROOM_ROOT': root.path}, workingDirectory: root.path);
  }

  test('群主治理端到端：邀请/审批/踢人/改名/历史可见性/转让（真实服务端）', () async {
    if (skipped) {
      markTestSkipped('缺少本地 Python 服务端环境，跳过 E2E 测试');
      return;
    }
    final aliceProc = await startHelper('alice', pyAlice, 'm_alice.py');
    final bobProc = await startHelper('bob', pyBob, 'm_bob.py');

    final carol = SocketService();
    expect(await carol.connect(), isTrue);
    expect(await carol.login('carol', 'password789'), isNull,
        reason: 'carol 登录应成功');

    // ---- 1. M2 入群审批：carol 申请加入群 2（须在 alice 批准前发出）----
    await carol.requestJoinGroup(2);

    // ---- 2. M2 邀请制：alice 邀请 → carol 收到邀请并接受 ----
    final invited =
        await waitUntil(() => state.invitations.any((i) => i.groupId == 1));
    expect(invited, isTrue, reason: 'alice 邀请后 carol 应收到 group_invite');
    await carol.acceptGroupInvite(1);
    final joined1 = await waitUntil(() => state.groups.any((g) => g.id == 1));
    expect(joined1, isTrue, reason: '接受邀请后 carol 群列表应含群 1');

    // ---- 3. M1 群主标识：alice 批准后 carol 入群 2，但群主仍是 alice ----
    final joined2 =
        await waitUntil(() => state.groups.any((g) => g.id == 2), tries: 60);
    expect(joined2, isTrue, reason: 'alice 批准后 carol 群列表应含群 2（list_groups 刷新）');
    expect(state.isGroupOwner(2), isFalse,
        reason: 'carol 加入后不是群 2 群主（created_by=alice）');

    // ---- 4. M3 历史可见性（开启）：carol 可见 bob 加入前消息 ----
    await carol.fetchHistory(groupId: 2);
    final sawPreJoin = await waitUntil(() =>
        state.getMessages('group_2').any((m) => m.content == 'before-carol'));
    expect(sawPreJoin, isTrue, reason: '历史可见性开启时新成员应可见加入前最近消息（P1-18 默认）');

    // ---- 5. M1 踢人：alice 将 carol 移出群 1 → carol 群列表移除 ----
    final kicked =
        await waitUntil(() => !state.groups.any((g) => g.id == 1), tries: 60);
    expect(kicked, isTrue, reason: '被群主移出后 carol 群列表应移除群 1');

    // ---- 6. M1 改名：alice 改名 → carol 侧群名称更新 ----
    final renamed =
        await waitUntil(() => state.getGroupName(2) == '新群名', tries: 60);
    expect(renamed, isTrue, reason: '群主改名后 carol 侧群名称应更新');

    // ---- 7. M3 历史可见性（关闭）：carol 重新登录后 fetchHistory 为空 ----
    // 转让前 alice 已关闭群 2 历史可见性（t≈13.3s 先于 t≈16.1s 转让）；
    // carol 本地已缓存 step 4 拉取的 before-carol，重新登录（清空本地）
    // 后 fetch 验证服务端过滤（P1-18）。
    final transferred = await waitUntil(() => state.isGroupOwner(2), tries: 60);
    expect(transferred, isTrue,
        reason: '群主转让后 carol 应成为群 2 群主（list_groups created_by 刷新）');
    carol.disconnect();
    state.setLoggedOut();
    final carol2 = SocketService();
    expect(await carol2.connect(), isTrue);
    expect(await carol2.login('carol', 'password789'), isNull,
        reason: 'carol 重新登录应成功');
    await carol2.fetchHistory(groupId: 2);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(
        state.getMessages('group_2').where((m) => m.content == 'before-carol'),
        isEmpty,
        reason: '群主关闭历史可见性后，新成员历史应不可见（P1-18）');

    // ---- 8. M8 文件列表：契约接线（无文件 → 空记录）----
    await carol2.fetchFileList();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(state.fileRecords, isEmpty, reason: '无文件历史时文件列表应为空');

    // ---- 9. 离线邀请登录补发（P-11 修复回归）：carol 离线期间 alice
    // 邀请她加入群 3（t≈14.1s）→ carol 重新登录时服务端补发
    // group_invite → 客户端初始数据窗口内处理 → 邀请入口出现 ----
    carol2.disconnect();
    state.setLoggedOut();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final carol3 = SocketService();
    expect(await carol3.connect(), isTrue);
    expect(await carol3.login('carol', 'password789'), isNull,
        reason: 'carol 重新登录应成功');
    final offlineInvite =
        await waitUntil(() => state.invitations.any((i) => i.groupId == 3));
    expect(offlineInvite, isTrue, reason: '离线期间收到的邀请应在登录补发后出现在邀请入口（P-11）');
    await carol3.acceptGroupInvite(3);
    final joined3 = await waitUntil(() => state.groups.any((g) => g.id == 3));
    expect(joined3, isTrue, reason: '接受离线补发的邀请后应入群 3');

    carol3.disconnect();
    aliceProc.kill(ProcessSignal.sigterm);
    bobProc.kill(ProcessSignal.sigterm);
    await aliceProc.exitCode;
    await bobProc.exitCode;
  });
}
