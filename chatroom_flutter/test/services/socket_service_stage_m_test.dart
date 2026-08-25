// ============================================================
// socket_service.dart 阶段 M —— 群组治理 + 运维协议方法契约（TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§11 阶段 M / §13.3：
//   - M1 群主权限：kickGroupMember / transferGroupOwner / renameGroup /
//     setGroupAvatar（协议 kick_member / transfer_owner / rename_group /
//     set_group_avatar）
//   - M2 入群审批/邀请：requestJoinGroup / approveJoinRequest /
//     rejectJoinRequest / inviteGroupMember / acceptGroupInvite /
//     declineGroupInvite（协议 request_join_group / approve_join_request /
//     reject_join_request / invite_group_member / accept_group_invite /
//     decline_group_invite）
//   - M3 历史可见性：setGroupHistoryVisible（协议 set_group_history_visible）
//   - M4 状态面板/存储清理：fetchServerStatus / runStorageCleanup
//     （admin_command action=server_status / storage_cleanup）
//   - M8 文件增强：fetchFileList / resumeFileTransfer（协议 list_files /
//     file_resume）
//
// 未连接（_socket == null）时全部方法：静默无副作用、不崩溃。
// 实现前：本文件引用尚未实现的方法，编译失败或用例红，属 TDD 红。
// 实现后：全部转绿。
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

  group('M —— 未连接时的公开 API 契约', () {
    final service = SocketService();

    test('kickGroupMember 未连接不崩溃、无副作用', () async {
      await service.kickGroupMember(1, 'bob');
      expect(state.noticeQueue, isEmpty);
    });

    test('transferGroupOwner 未连接不崩溃、无副作用', () async {
      await service.transferGroupOwner(1, 'bob');
      expect(state.noticeQueue, isEmpty);
    });

    test('renameGroup 未连接不崩溃、无副作用', () async {
      await service.renameGroup(1, '新名');
      expect(state.noticeQueue, isEmpty);
    });

    test('setGroupAvatar 未连接不崩溃、无副作用', () async {
      await service.setGroupAvatar(1, 'avatar-data');
      expect(state.noticeQueue, isEmpty);
    });

    test('setGroupHistoryVisible 未连接不崩溃、无副作用', () async {
      await service.setGroupHistoryVisible(1, false);
      expect(state.noticeQueue, isEmpty);
    });

    test('requestJoinGroup 未连接不崩溃、无副作用', () async {
      await service.requestJoinGroup(1);
      expect(state.noticeQueue, isEmpty);
    });

    test('requestJoinGroup 携带验证消息未连接同样静默（P-11）', () async {
      await service.requestJoinGroup(1, message: '我是 carol');
      expect(state.noticeQueue, isEmpty);
      expect(state.joinRequestsOf(1), isEmpty);
    });

    test('searchGroups 未连接不崩溃、无副作用', () async {
      await service.searchGroups('开发');
      expect(state.groupSearchResults, isEmpty);
    });

    test('fetchJoinRequests 未连接不崩溃、无副作用', () async {
      await service.fetchJoinRequests(1);
      expect(state.joinRequestsOf(1), isEmpty);
    });

    test('approveJoinRequest 未连接不崩溃、无副作用', () async {
      await service.approveJoinRequest(1, 'carol');
      expect(state.noticeQueue, isEmpty);
    });

    test('rejectJoinRequest 未连接不崩溃、无副作用', () async {
      await service.rejectJoinRequest(1, 'carol');
      expect(state.noticeQueue, isEmpty);
    });

    test('inviteGroupMember 未连接不崩溃、无副作用', () async {
      await service.inviteGroupMember(1, 'carol');
      expect(state.noticeQueue, isEmpty);
    });

    test('acceptGroupInvite 未连接不崩溃、无副作用', () async {
      await service.acceptGroupInvite(1);
      expect(state.noticeQueue, isEmpty);
    });

    test('declineGroupInvite 未连接不崩溃、无副作用', () async {
      await service.declineGroupInvite(1);
      expect(state.noticeQueue, isEmpty);
    });

    test('fetchServerStatus 未连接不崩溃、无副作用', () async {
      await service.fetchServerStatus();
      expect(state.serverStatus, isNull);
    });

    test('runStorageCleanup 未连接不崩溃、无副作用', () async {
      await service.runStorageCleanup();
      expect(state.storageCleanupResult, isNull);
    });

    test('fetchFileList 未连接不崩溃、无副作用', () async {
      await service.fetchFileList();
      expect(state.fileRecords, isEmpty);
    });

    test('resumeFileTransfer 未连接不崩溃、无副作用', () async {
      await service.resumeFileTransfer('m1', 1024);
      expect(state.noticeQueue, isEmpty);
    });

    test('全部新方法在未登录未连接时均静默失败', () async {
      final beforeLog = state.statusLog.length;
      await service.kickGroupMember(1, 'bob');
      await service.transferGroupOwner(1, 'bob');
      await service.renameGroup(1, '新名');
      await service.setGroupAvatar(1, 'a');
      await service.setGroupHistoryVisible(1, false);
      await service.requestJoinGroup(1);
      await service.searchGroups('开发');
      await service.fetchJoinRequests(1);
      await service.approveJoinRequest(1, 'carol');
      await service.rejectJoinRequest(1, 'carol');
      await service.inviteGroupMember(1, 'carol');
      await service.acceptGroupInvite(1);
      await service.declineGroupInvite(1);
      await service.fetchServerStatus();
      await service.runStorageCleanup();
      await service.fetchFileList();
      await service.resumeFileTransfer('m1', 0);
      expect(state.statusLog.length, beforeLog, reason: '不应产生错误日志');
      expect(state.noticeQueue, isEmpty);
    });
  });
}
