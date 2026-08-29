// ============================================================
// socket_service.dart 阶段 N —— 日常使用便利性协议方法契约（TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 N：
//   - N6（P2-6）登录设备管理：fetchSessions / kickSession
//     （协议 list_sessions / kick_session）
//   - N7（P2-7）审计日志：fetchAuditLogs（admin_command action=audit_log，
//     admin_response response_type=audit_log → state.auditLogs）
//   - N1（P2-2）永久删除：permanentlyDeleteMessage（本地缓存中彻底移除：
//     MessageCacheStore.removeMessage + state.removeMessageLocally）
//   - N3（P2-4）图片/字节直发：sendFileBytes（复用既有上传通道，
//     大文件走 M8 分流）
//
// 未连接（_socket == null）时全部方法：静默无副作用、不崩溃。
// 实现前：本文件引用尚未实现的方法，编译失败或用例红，属 TDD 红。
// 实现后：全部转绿。
//
// 注意：本文件所有测试绝不触发真实网络连接（_socket 恒为 null）。
// ============================================================

import 'dart:typed_data';

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

  group('N —— 未连接时的公开 API 契约', () {
    final service = SocketService();

    test('fetchSessions 未连接不崩溃、无副作用', () async {
      await service.fetchSessions();
      expect(state.sessions, isEmpty);
      expect(state.noticeQueue, isEmpty);
    });

    test('kickSession 未连接不崩溃、无副作用', () async {
      await service.kickSession('android');
      expect(state.sessions, isEmpty);
      expect(state.noticeQueue, isEmpty);
    });

    test('fetchAuditLogs 未连接不崩溃、无副作用', () async {
      await service.fetchAuditLogs();
      expect(state.auditLogs, isEmpty);
      expect(state.noticeQueue, isEmpty);
    });

    test('fetchAuditLogs 带 limit 未连接同样静默', () async {
      await service.fetchAuditLogs(limit: 50);
      expect(state.auditLogs, isEmpty);
    });

    test('permanentlyDeleteMessage 未连接不崩溃、无副作用', () async {
      await service.permanentlyDeleteMessage('bob', 'm1');
      expect(state.noticeQueue, isEmpty);
    });

    test('sendFileBytes 未连接返回 false、无副作用', () async {
      final ok = await service.sendFileBytes(
        'bob',
        Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]),
        'pasted.png',
      );
      expect(ok, isFalse);
      expect(state.noticeQueue, isEmpty);
    });

    test('sendFileBytes 空字节未连接返回 false（不抛异常）', () async {
      final ok = await service.sendFileBytes('bob', Uint8List(0), 'empty.png');
      expect(ok, isFalse);
    });

    test('全部新方法在未登录未连接时均静默失败', () async {
      final service = SocketService();
      await service.fetchSessions();
      await service.kickSession('linux');
      await service.fetchAuditLogs();
      await service.permanentlyDeleteMessage('bob', 'm1');
      await service.sendFileBytes('bob', Uint8List(4), 'a.png');
      expect(state.sessions, isEmpty);
      expect(state.auditLogs, isEmpty);
      expect(state.noticeQueue, isEmpty);
    });
  });
}
