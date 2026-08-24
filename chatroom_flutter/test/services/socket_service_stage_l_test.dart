// ============================================================
// socket_service.dart 阶段 L —— 多会话并存设备类别（L1，P0-7）
// ============================================================
// 依据《软件开发文档4.1.0.md》§11 阶段 L / §13.2 P0-7：
//   client_map 双键化 (username, device_id) + 会话级推送 —— 移动端规划的前提
//
// 客户端侧契约（2026-08-20 用户决策：device_id 按**平台类别**）：
//   SocketService 只读属性 deviceId：
//     - 平台类别常量：linux / android / ios / windows / macos / default；
//     - 非空 String；同一平台任何实例取值一致（同类互踢、异类并存——
//       服务端按 (username, device_id) 判断，见 test_stage_l_server.py）；
//     - 登录/注册/重连均以 device_id 头随 login 消息发送。
//   AppState 按 messageId 去重（addMessage/prependHistoryMessages）已实现，
//   多设备会话级推送下同一消息到达不重复渲染——本文件同时锁定该语义
//   （多设备去重）。
//
// 注意：本文件所有测试绝不触发真实网络连接（_socket 恒为 null）。
// ============================================================

import 'dart:io';

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

/// 与生产 deviceId 一致的平台类别映射（锁定契约，防止实现漂移）
String _expectedDeviceCategory() {
  if (Platform.isLinux) return 'linux';
  if (Platform.isAndroid) return 'android';
  if (Platform.isIOS) return 'ios';
  if (Platform.isWindows) return 'windows';
  if (Platform.isMacOS) return 'macos';
  return 'default';
}

void main() {
  setUp(resetState);

  group('L1 —— 设备类别 deviceId（P0-7，按平台）', () {
    test('deviceId 为非空字符串', () {
      final service = SocketService();
      expect(service.deviceId, isA<String>());
      expect(service.deviceId, isNotEmpty);
    });

    test('同一实例多次读取 deviceId 稳定', () {
      final service = SocketService();
      final first = service.deviceId;
      final second = service.deviceId;
      expect(second, first, reason: '同一平台类别多次读取应返回同一 deviceId');
    });

    test('同平台两个实例 deviceId 相同（类别语义：同类互踢）', () {
      final a = SocketService();
      final b = SocketService();
      expect(b.deviceId, a.deviceId,
          reason: '同平台共享同一 device_id：服务端据此同类互踢、异类并存');
    });

    test('deviceId 为平台类别标签，与当前运行平台一致', () {
      final service = SocketService();
      expect(service.deviceId, _expectedDeviceCategory(),
          reason: 'device_id 应为平台类别常量（linux/android/…），无随机后缀');
    });
  });

  group('L1 —— 多设备去重（会话级推送不重复渲染）', () {
    test('同一 messageId 重复到达（多设备推送回声）→ 不重复添加，仅更新状态', () {
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');

      final msg = ChatMessage(
        sender: 'bob',
        content: 'hi',
        messageId: 'L1_same_id',
        status: 'sent',
      );
      state.addMessage('bob', msg);
      // 另一设备/另一路径再次收到同一消息（status 升级为 delivered）
      state.addMessage(
          'bob',
          ChatMessage(
            sender: 'bob',
            content: 'hi',
            messageId: 'L1_same_id',
            status: 'delivered',
          ));

      expect(state.getMessages('bob').length, 1, reason: '多设备会话级推送下同一消息只渲染一次');
      expect(state.getMessages('bob').first.status, 'delivered');
    });

    test('历史加载 prependHistoryMessages 按 messageId 去重', () {
      state.setLoggedIn('alice', false);
      state.setFriends(['bob']);
      state.selectChat('bob');

      final existing = ChatMessage(
        sender: 'bob',
        content: 'old',
        messageId: 'm_old',
        timestamp: DateTime(2026, 1, 1),
      );
      state.addMessage('bob', existing);

      // 上滑加载返回的同样历史（含已存在 id）→ 不重复
      state.prependHistoryMessages('bob', [
        ChatMessage(
          sender: 'bob',
          content: 'old',
          messageId: 'm_old',
          timestamp: DateTime(2026, 1, 1),
        ),
        ChatMessage(
          sender: 'bob',
          content: 'older',
          messageId: 'm_older',
          timestamp: DateTime(2025, 12, 31),
        ),
      ]);

      expect(state.getMessages('bob').length, 2);
      expect(state.getMessages('bob').first.messageId, 'm_older');
    });
  });
}
