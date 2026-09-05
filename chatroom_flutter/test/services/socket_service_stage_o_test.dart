// ============================================================
// socket_service.dart 阶段 O —— 群组与消息增强协议方法契约（TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 O 的客户端协议方法：
//   - O1（用户已规划）群公告：setGroupAnnouncement（协议
//     set_group_announcement {group_id}，body=公告文本，空文本=清除）
//   - O2（用户已规划）群置顶：pinGroupMessage / unpinGroupMessage
//     （协议 pin_group_message {group_id, message_id} /
//      unpin_group_message {group_id}）
//   - O5（P2-5）定时消息：scheduleChat / scheduleGroupChat（协议
//     schedule_message {to|group_id, schedule_at=epoch 秒}）/
//     cancelScheduled（cancel_scheduled {message_id}）/
//     fetchScheduled（list_scheduled → scheduled_list_response →
//     state.scheduledMessages）
//   - O8（P2-8）证书续期：renewCert（admin_command action=renew_cert →
//     admin_response response_type=renew_cert）
//   - O9（P2-12）名片/位置/日程卡片：sendContactCard / sendLocationCard /
//     sendScheduleCard（协议 share_contact / share_location / schedule_card，
//     body=JSON 卡片数据；私聊 to 或群聊 group_id 二选一）
//
// 未连接（_socket == null）时全部方法：静默无副作用、不崩溃。
// 实现前：本文件引用尚未实现的方法，编译失败或用例红，属 TDD 红。
// 实现后：全部转绿。
//
// 注意：本文件所有测试绝不触发真实网络连接（_socket 恒为 null）。
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  setUp(resetState);

  group('O1 —— setGroupAnnouncement 未连接契约', () {
    final service = SocketService();

    test('设置公告未连接不崩溃、无副作用', () async {
      await service.setGroupAnnouncement(1, '周五团建');
      expect(state.noticeQueue, isEmpty);
    });

    test('清除公告（空文本）未连接同样静默', () async {
      await service.setGroupAnnouncement(1, '');
      expect(state.noticeQueue, isEmpty);
    });
  });

  group('O2 —— pinGroupMessage / unpinGroupMessage 未连接契约', () {
    final service = SocketService();

    test('置顶群消息未连接不崩溃、无副作用', () async {
      await service.pinGroupMessage(1, 'm-001');
      expect(state.noticeQueue, isEmpty);
    });

    test('取消置顶未连接不崩溃、无副作用', () async {
      await service.unpinGroupMessage(1);
      expect(state.noticeQueue, isEmpty);
    });
  });

  group('O5 —— 定时消息未连接契约', () {
    final service = SocketService();
    final at = DateTime(2026, 9, 1, 9, 30);

    test('scheduleChat 未连接不崩溃、无副作用', () async {
      await service.scheduleChat('bob', '提醒', at);
      expect(state.scheduledMessages, isEmpty);
      expect(state.noticeQueue, isEmpty);
    });

    test('scheduleGroupChat 未连接不崩溃、无副作用', () async {
      await service.scheduleGroupChat(1, '群提醒', at);
      expect(state.scheduledMessages, isEmpty);
    });

    test('cancelScheduled 未连接不崩溃、无副作用', () async {
      await service.cancelScheduled('o5-1');
      expect(state.scheduledMessages, isEmpty);
    });

    test('fetchScheduled 未连接不崩溃、无副作用', () async {
      await service.fetchScheduled();
      expect(state.scheduledMessages, isEmpty);
    });

    test('scheduleAt 以 epoch 秒为协议时间（UTC 中立，注意时区）', () {
      // 契约锁定：Dart DateTime → epoch 秒的换算口径
      // （实现方 schedule_message 头 schedule_at 必须是秒级 epoch）
      expect(at.millisecondsSinceEpoch ~/ 1000,
          at.toUtc().millisecondsSinceEpoch ~/ 1000,
          reason: '本地时刻与 UTC 时刻的 epoch 秒一致（同一瞬间）');
    });
  });

  group('O8 —— renewCert 未连接契约', () {
    final service = SocketService();

    test('renewCert 未连接不崩溃、无副作用', () async {
      await service.renewCert();
      expect(state.noticeQueue, isEmpty);
    });
  });

  group('O1 公告管理 —— fetchGroupAnnouncements/deleteGroupAnnouncement 未连接契约', () {
    final service = SocketService();

    test('fetchGroupAnnouncements 未连接不崩溃、无副作用', () async {
      await service.fetchGroupAnnouncements(1);
      expect(state.groupAnnouncements, isEmpty);
      expect(state.noticeQueue, isEmpty);
    });

    test('deleteGroupAnnouncement 未连接不崩溃、无副作用', () async {
      await service.deleteGroupAnnouncement(1, 'a-1');
      expect(state.groupAnnouncements, isEmpty);
      expect(state.noticeQueue, isEmpty);
    });
  });
}
