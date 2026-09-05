// ============================================================
// socket_service.dart 公开 API 契约测试（无网络连接）
// ============================================================
// SocketService 的私有字段（_socket 等）无法注入，但"未连接"状态下
// 全部公开方法的契约行为可被严格验证——这是最容易被回归击穿的路径：
//   - login/register 未连接时返回 '未连接到服务器'
//   - 所有发送类方法未连接时静默失败 / 无副作用
//   - disconnect() 幂等安全
//   - sanitizeFilename 安全过滤（含路径穿越攻击）
//
// 注意：本文件所有测试绝不触发真实网络连接（_socket 恒为 null）。
// ============================================================

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/socket_service.dart';
import 'package:chatroom_flutter/services/state_manager.dart';

AppState get state => AppState.instance;

void resetState() {
  state
    ..setLoggedOut()
    ..setConnectionStatus(ConnectionStatus.disconnected);
}

void main() {
  setUp(resetState);

  group('未连接时的公开 API 契约', () {
    final service = SocketService();

    test('初始状态：无 socket、不处于重连', () {
      expect(service.socket, isNull);
      expect(service.isReconnecting, isFalse);
    });

    test('login 未连接返回错误信息且不崩溃', () async {
      final err = await service.login('alice', 'secret123');
      expect(err, '未连接到服务器');
    });

    test('register 未连接返回错误信息且不崩溃', () async {
      final err = await service.register('alice', 'secret123');
      expect(err, '未连接到服务器');
    });

    test('sendChat 未连接且未登录返回 false（I1：已登录未连接时改为入队，见 stage_i 契约）', () async {
      expect(await service.sendChat('bob', 'hi'), isFalse);
    });

    test('sendGroupChat 未连接且未登录返回 false（I1 同上）', () async {
      expect(await service.sendGroupChat(1, 'hi'), isFalse);
    });

    test('sendFile 未连接返回 false', () async {
      expect(await service.sendFile('bob', '/tmp/nonexistent.bin', 'x.bin'),
          isFalse);
    });

    test('changePassword 未连接返回 false', () async {
      expect(await service.changePassword('old', 'newpass123'), isFalse);
    });

    test('无副作用：未连接时其余调用不改变任何状态', () async {
      // 注：sendChat/sendGroupChat 已不在本清单 —— 阶段 I1 起，
      // 已登录未连接时二者会将消息入队 pending 并显示气泡
      // （新契约见 socket_service_stage_i_test.dart）
      state.setLoggedIn('alice', false);
      final beforeFriends = state.friends.length;
      final beforeMsgs = state.messages.length;
      await service.addFriend('bob');
      await service.acceptFriend('bob');
      await service.rejectFriend('bob');
      await service.deleteFriend('bob');
      await service.createGroup('g');
      await service.joinGroup(1);
      await service.leaveGroup(1);
      await service.recallMessage('m1', 'bob');
      await service.fetchHistory(to: 'bob');
      await service.fetchGroupMembers(1);
      await service.adminCommand('list_users');
      await service.respondFileRequest('f1', 'bob', true);
      await service.respondGroupFileRequest('f1', 1, true);
      expect(state.friends.length, beforeFriends);
      expect(state.messages.length, beforeMsgs);
      expect(state.noticeQueue, isEmpty);
      expect(state.pendingFileRequests, isEmpty);
    });

    test('respondFileRequest 未连接时不清除本地待处理请求', () async {
      state.addFileRequest(FileRequest(
          messageId: 'f1', sender: 'bob', filename: 'a', filesize: 1));
      await service.respondFileRequest('f1', 'bob', true);
      expect(state.pendingFileRequests.length, 1,
          reason: '_socket 为 null 直接 return，不产生副作用');
    });

    test('disconnect 未连接时安全（幂等）', () {
      expect(() => service.disconnect(), returnsNormally);
      expect(() => service.disconnect(), returnsNormally);
      expect(service.socket, isNull);
    });
  });

  group('sanitizeFilename 安全过滤（G5 路径穿越防护）', () {
    test('正常文件名原样保留', () {
      expect(SocketService.sanitizeFilename('report.pdf'), 'report.pdf');
    });

    test('Unix 路径被裁为 basename', () {
      expect(SocketService.sanitizeFilename('a/b/c.txt'), 'c.txt');
    });

    test('Windows 路径被裁为 basename', () {
      expect(SocketService.sanitizeFilename(r'C:\Users\evil\virus.exe'),
          'virus.exe');
    });

    test('混合分隔符路径被裁为 basename', () {
      expect(SocketService.sanitizeFilename(r'..\..\etc\passwd'), 'passwd');
      expect(SocketService.sanitizeFilename('../../etc/passwd'), 'passwd');
    });

    test('路径穿越攻击：.. 组合全部失效', () {
      for (final f in [
        '../x',
        '..\\x',
        'a/../x',
        'a/../../x',
        '.../x',
        '.. /x'
      ]) {
        final r = SocketService.sanitizeFilename(f);
        expect(r.contains('/'), isFalse, reason: '$f -> $r');
        expect(r.contains(r'\'), isFalse, reason: '$f -> $r');
      }
    });

    test('空串 / 点 / 双点回退为 received_file', () {
      expect(SocketService.sanitizeFilename(''), 'received_file');
      expect(SocketService.sanitizeFilename('.'), 'received_file');
      expect(SocketService.sanitizeFilename('..'), 'received_file');
    });

    test('纯分隔符路径回退为 received_file', () {
      expect(SocketService.sanitizeFilename('///'), 'received_file');
      expect(SocketService.sanitizeFilename(r'\\\'), 'received_file');
      expect(SocketService.sanitizeFilename('/'), 'received_file');
    });

    test('以 / 结尾的文件名回退为 received_file', () {
      expect(SocketService.sanitizeFilename('dir/'), 'received_file');
      expect(SocketService.sanitizeFilename(r'dir\'), 'received_file');
    });

    test('隐藏文件保留（不以点作为整个名字）', () {
      expect(SocketService.sanitizeFilename('.gitignore'), '.gitignore');
      expect(SocketService.sanitizeFilename('.env'), '.env');
    });

    test('Unicode 与空格文件名保留', () {
      expect(SocketService.sanitizeFilename('报告 最终版.txt'), '报告 最终版.txt');
      expect(SocketService.sanitizeFilename('文件（1）.txt'), '文件（1）.txt');
    });

    test('超长文件名保留（不截断，不崩溃）', () {
      final long = 'a' * 10000 + '.txt';
      final r = SocketService.sanitizeFilename(long);
      expect(r.length, 10004);
      expect(r.endsWith('.txt'), isTrue);
    });

    test('文件名恰为 ".. " 带尾随空格时不回退（保留原样，记录行为）', () {
      expect(SocketService.sanitizeFilename('.. '), '.. ');
      expect(SocketService.sanitizeFilename('. '), '. ');
    });
  });
}
