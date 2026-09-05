// ============================================================
// state_manager.dart 阶段 M —— 群组治理 + 运维状态契约（TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§11 阶段 M / §13.3 的客户端状态侧：
//   - M1 群主标识：isGroupOwner（Group.owner == 当前用户）
//   - M1 群组更新/移除：updateGroup / removeGroup（改名/头像/转让后同步）
//   - M2 入群审批/邀请：joinRequestsOf / setJoinRequests / removeJoinRequest
//     + invitations / setInvitations / removeInvitation
//   - M4 服务端状态面板：serverStatus / storageCleanupResult
//   - M8 文件收发管理：fileRecords / setFileRecords
//
// 实现前：本文件引用尚未实现的 AppState 方法/字段，编译失败或用例红，
// 属 TDD 红。实现后：全部转绿。
// ============================================================

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/state_manager.dart';

AppState get state => AppState.instance;

void resetState() {
  state.setLoggedOut();
}

Group groupOf(int id, String name, {String owner = '', int historyLimit = 50}) {
  return Group.fromJson({
    'id': id,
    'group_name': name,
    if (owner.isNotEmpty) 'created_by': owner,
    'history_visible': 1,
    'history_limit': historyLimit,
  });
}

void main() {
  setUp(resetState);

  group('M1 —— 群主标识与群组更新', () {
    test('setGroups 解析 owner，isGroupOwner 判定正确', () {
      state.setLoggedIn('alice', false);
      state.setGroups([groupOf(1, '开发组', owner: 'alice'), groupOf(2, '设计组', owner: 'bob')]);
      expect(state.isGroupOwner(1), isTrue, reason: 'alice 是开发组群主');
      expect(state.isGroupOwner(2), isFalse, reason: 'alice 不是设计组群主');
    });

    test('未设置 owner 时 isGroupOwner 恒 false', () {
      state.setLoggedIn('alice', false);
      state.setGroups([groupOf(1, '旧群')]);
      expect(state.isGroupOwner(1), isFalse);
    });

    test('updateGroup 替换既有群组（改名/头像/转让后同步）', () {
      state.setLoggedIn('alice', false);
      state.setGroups([groupOf(1, '开发组', owner: 'alice')]);
      // 转让群主后服务端推送刷新 → 本地更新
      state.updateGroup(groupOf(1, '开发组', owner: 'bob'));
      expect(state.isGroupOwner(1), isFalse, reason: '转让后 alice 不再是群主');
      expect(state.groups.first.name, '开发组');
      expect(state.groups.length, 1, reason: '按 id 替换，不重复添加');
    });

    test('updateGroup 新增不存在群组', () {
      state.setLoggedIn('alice', false);
      state.updateGroup(groupOf(1, '新群', owner: 'alice'));
      expect(state.groups.length, 1);
      expect(state.isGroupOwner(1), isTrue);
    });

    test('removeGroup 移除群组（被踢出后列表刷新）', () {
      state.setGroups([groupOf(1, '开发组'), groupOf(2, '设计组')]);
      state.removeGroup(1);
      expect(state.groups.map((g) => g.id), [2]);
    });

    test('removeGroup 幂等（群组不存在不抛错）', () {
      state.setGroups([groupOf(1, '开发组')]);
      state.removeGroup(99);
      expect(state.groups.length, 1);
    });

    test('updateGroupMembers 既有语义保持（踢人后成员同步）', () {
      state.setGroups([groupOf(1, '开发组', owner: 'alice')]);
      state.updateGroupMembers(1, ['alice', 'carol']);
      expect(state.groups.first.members, ['alice', 'carol']);
      expect(state.getGroupName(1), '开发组');
    });
  });

  group('M2 —— 入群审批与邀请状态', () {
    test('joinRequestsOf 缺省为空列表', () {
      expect(state.joinRequestsOf(1), isEmpty);
    });

    test('setJoinRequests 设置并覆盖', () {
      state.setJoinRequests(1, ['carol', 'dave']);
      expect(state.joinRequestsOf(1), ['carol', 'dave']);
      state.setJoinRequests(1, ['carol']);
      expect(state.joinRequestsOf(1), ['carol']);
    });

    test('removeJoinRequest 批准/拒绝后移除', () {
      state.setJoinRequests(1, ['carol', 'dave']);
      state.removeJoinRequest(1, 'carol');
      expect(state.joinRequestsOf(1), ['dave']);
    });

    test('joinRequestMessageOf 验证消息存取（P-11）', () {
      expect(state.joinRequestMessageOf(1, 'carol'), '');
      state.setJoinRequests(1, ['carol']);
      state.setJoinRequestMessages(1, {'carol': '我是 carol'});
      expect(state.joinRequestMessageOf(1, 'carol'), '我是 carol');
      state.removeJoinRequest(1, 'carol');
      expect(state.joinRequestMessageOf(1, 'carol'), '',
          reason: '批准/拒绝后验证消息一并清除');
    });

    test('不同群组的申请互不干扰', () {
      state.setJoinRequests(1, ['carol']);
      state.setJoinRequests(2, ['dave']);
      expect(state.joinRequestsOf(1), ['carol']);
      expect(state.joinRequestsOf(2), ['dave']);
    });

    test('invitations 缺省为空，setInvitations 覆盖', () {
      expect(state.invitations, isEmpty);
      state.setInvitations([
        GroupInvite.fromJson(const {'group_id': 1, 'group_name': '开发组', 'from': 'alice'}),
      ]);
      expect(state.invitations.length, 1);
      expect(state.invitations.first.groupId, 1);
    });

    test('removeInvitation 接受/拒绝后移除', () {
      state.setInvitations([
        GroupInvite.fromJson(const {'group_id': 1, 'group_name': '开发组', 'from': 'alice'}),
        GroupInvite.fromJson(const {'group_id': 2, 'group_name': '设计组', 'from': 'bob'}),
      ]);
      state.removeInvitation(1);
      expect(state.invitations.map((i) => i.groupId), [2]);
    });
  });

  group('M4 —— 服务端状态面板', () {
    test('serverStatus 缺省为 null，setServerStatus 设置/清空', () {
      expect(state.serverStatus, isNull);
      state.setServerStatus(const {'online_users': 3, 'storage': {}});
      expect(state.serverStatus?['online_users'], 3);
      state.setServerStatus(null);
      expect(state.serverStatus, isNull);
    });

    test('storageCleanupResult 设置/清空', () {
      expect(state.storageCleanupResult, isNull);
      state.setStorageCleanupResult(const {
        'expired_file_requests': 2,
        'expired_delivered_messages': 5,
      });
      expect(state.storageCleanupResult?['expired_file_requests'], 2);
      state.setStorageCleanupResult(null);
      expect(state.storageCleanupResult, isNull);
    });
  });

  group('M —— 群组搜索状态', () {
    test('groupSearchResults 缺省为空，setGroupSearchResults 覆盖', () {
      expect(state.groupSearchResults, isEmpty);
      state.setGroupSearchResults([
        groupOf(1, '开发组', owner: 'alice'),
      ]);
      expect(state.groupSearchResults.length, 1);
      expect(state.groupSearchResults.first.owner, 'alice');
      state.setGroupSearchResults([]);
      expect(state.groupSearchResults, isEmpty);
    });
  });

  group('M8 —— 文件收发记录', () {
    test('fileRecords 缺省为空，setFileRecords 覆盖', () {
      expect(state.fileRecords, isEmpty);
      state.setFileRecords([
        FileRecord.fromJson(const {
          'filename': 'a.pdf',
          'filesize': 10,
          'sender': 'alice',
          'receiver': 'bob',
          'message_id': 'm1',
        }),
      ]);
      expect(state.fileRecords.length, 1);
      expect(state.fileRecords.first.filename, 'a.pdf');
      state.setFileRecords([]);
      expect(state.fileRecords, isEmpty);
    });
  });
}
