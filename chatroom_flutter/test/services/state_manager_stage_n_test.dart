// ============================================================
// state_manager.dart 阶段 N —— 日常使用便利性状态契约（TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 N 的客户端状态侧：
//   - N6（P2-6）设备会话列表：sessions / setSessions（登录设备管理）
//   - N7（P2-7）审计日志列表：auditLogs / setAuditLogs
//   - N3（P2-4）图片粘贴预览：pendingImagePreview / setPendingImagePreview /
//     clearPendingImagePreview
//   - N1（P2-2）永久删除的内存侧复用 removeMessageLocally（回归锁定）
//
// 实现前：本文件引用尚未实现的 AppState 方法/字段，编译失败或用例红，
// 属 TDD 红。实现后：全部转绿。
// ============================================================

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/state_manager.dart';

AppState get state => AppState.instance;

void resetState() {
  state.setLoggedOut();
}

SessionInfo session(String deviceId, {bool isCurrent = false}) {
  return SessionInfo(
    deviceId: deviceId,
    lastActive: DateTime.fromMillisecondsSinceEpoch(1724690000000),
    isCurrent: isCurrent,
  );
}

AuditLogEntry audit(String operator, String action, String target) {
  return AuditLogEntry.fromJson({
    'id': 1,
    'operator': operator,
    'action': action,
    'target': target,
    'detail': '',
    'timestamp': '2026-08-26 10:00:00',
  });
}

void main() {
  setUp(resetState);

  group('N6 —— 设备会话列表（sessions）', () {
    test('缺省为空列表', () {
      expect(state.sessions, isEmpty);
    });

    test('setSessions 覆盖更新并通知监听者', () {
      var notified = 0;
      state.addListener(() => notified++);
      state
          .setSessions([session('linux', isCurrent: true), session('android')]);
      expect(notified, greaterThan(0), reason: 'setSessions 应通知');
      expect(state.sessions.length, 2);
      expect(state.sessions.first.deviceId, 'linux');
      expect(state.sessions.first.isCurrent, isTrue);
      expect(state.sessions.last.deviceId, 'android');
    });

    test('setSessions 重复调用替换旧列表（不追加）', () {
      state.setSessions([session('linux', isCurrent: true)]);
      state.setSessions([session('android')]);
      expect(state.sessions.length, 1);
      expect(state.sessions.first.deviceId, 'android');
    });

    test('退出登录清空会话列表', () {
      state.setLoggedIn('alice', false);
      state.setSessions([session('linux', isCurrent: true)]);
      state.setLoggedOut();
      expect(state.sessions, isEmpty);
    });

    test('列表不可修改（只读视图）', () {
      state.setSessions([session('linux', isCurrent: true)]);
      expect(
          () => state.sessions.add(session('android')), throwsUnsupportedError);
    });
  });

  group('N7 —— 审计日志列表（auditLogs）', () {
    test('缺省为空列表', () {
      expect(state.auditLogs, isEmpty);
    });

    test('setAuditLogs 覆盖更新', () {
      state.setAuditLogs([audit('admin', 'delete_user', 'bob')]);
      expect(state.auditLogs.length, 1);
      expect(state.auditLogs.first.action, 'delete_user');
      expect(state.auditLogs.first.operator, 'admin');
      state.setAuditLogs([
        audit('alice', 'kick_member', 'carol'),
        audit('alice', 'transfer_owner', 'carol'),
      ]);
      expect(state.auditLogs.length, 2);
    });

    test('退出登录清空审计日志', () {
      state.setLoggedIn('admin', true);
      state.setAuditLogs([audit('admin', 'delete_user', 'bob')]);
      state.setLoggedOut();
      expect(state.auditLogs, isEmpty);
    });

    test('列表只读视图', () {
      state.setAuditLogs([audit('admin', 'delete_user', 'bob')]);
      expect(() => state.auditLogs.add(audit('a', 'b', 'c')),
          throwsUnsupportedError);
    });
  });

  group('N3 —— 图片粘贴预览（pendingImagePreview）', () {
    final png =
        Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

    test('缺省为 null', () {
      expect(state.pendingImagePreview, isNull);
    });

    test('setPendingImagePreview 后可取', () {
      state.setPendingImagePreview(png);
      expect(state.pendingImagePreview, isNotNull);
      expect(state.pendingImagePreview!.length, png.length);
    });

    test('clearPendingImagePreview 清除并通知', () {
      var notified = 0;
      state.addListener(() => notified++);
      state.setPendingImagePreview(png);
      state.clearPendingImagePreview();
      expect(state.pendingImagePreview, isNull);
      expect(notified, greaterThan(0));
    });

    test('重复 set 覆盖旧预览', () {
      state.setPendingImagePreview(png);
      final other = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);
      state.setPendingImagePreview(other);
      expect(state.pendingImagePreview, same(other));
    });

    test('退出登录清空预览（防跨账号泄漏）', () {
      state.setLoggedIn('alice', false);
      state.setPendingImagePreview(png);
      state.setLoggedOut();
      expect(state.pendingImagePreview, isNull);
    });
  });

  group('N1 —— 永久删除的内存侧复用 removeMessageLocally（回归锁定）', () {
    test('removeMessageLocally 移除消息与 messageMap 索引', () {
      state.addMessage(
          'bob', ChatMessage(sender: 'alice', content: '待删除', messageId: 'm1'));
      expect(state.messageById('m1'), isNotNull);
      state.removeMessageLocally('bob', 'm1');
      expect(state.getMessages('bob'), isEmpty);
      expect(state.messageById('m1'), isNull,
          reason: '永久删除须同时清内存索引（_messageMap）');
    });

    test('removeMessageLocally 幂等（重复删除不抛）', () {
      state.addMessage(
          'bob', ChatMessage(sender: 'alice', content: 'x', messageId: 'm1'));
      state.removeMessageLocally('bob', 'm1');
      expect(() => state.removeMessageLocally('bob', 'm1'), returnsNormally);
    });

    test('removeMessageLocally 不存在会话不抛', () {
      expect(() => state.removeMessageLocally('ghost', 'm1'), returnsNormally);
    });
  });
}
