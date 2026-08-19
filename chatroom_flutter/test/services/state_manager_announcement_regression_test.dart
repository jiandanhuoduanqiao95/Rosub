// ============================================================
// state_manager.dart 公告未读徽标回归 —— 用户实测缺陷回归锁定
// ============================================================
// 缺陷（2026-08-19 第二轮用户实测发现）：
//   管理员发送公告后客户端不显示未读徽标，只有应用图标在闪烁。
// 根因：实时公告在 _handleMessage 中以 status='delivered' 落地，
// 而 addMessage 仅对 status='sent' 计未读 → 公告不产生徽标。
// （离线公告经离线推送携带 'sent'，本就显示徽标——两条路径不一致。）
// 修复：实时公告落地改为 status='sent'（与离线公告路径对齐）。
//
// 本文件锁定 AppState 侧契约：
//   - '服务器' 会话的 status='sent' 系统消息 → 计未读徽标
//   - 查看（selectChat '服务器'）→ 徽标清零
//   - 正在查看时到达 → 不计未读
//   - status='delivered'（已读历史）系统消息 → 不计未读（回归）
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/state_manager.dart';

AppState get state => AppState.instance;

void resetState() {
  state
    ..setLoggedOut()
    ..setConnectionStatus(ConnectionStatus.disconnected);
}

ChatMessage _announcement(String id, String content, {String status = 'sent'}) {
  return ChatMessage(
    sender: '[系统公告]',
    content: content,
    type: 'system',
    messageId: id,
    status: status,
  );
}

void main() {
  setUp(resetState);

  group('公告未读徽标（P-60 缺陷回归锁定）', () {
    test('实时公告（sent）到达系统会话 → 未读徽标 +1', () {
      state.setLoggedIn('alice', false);
      state.addMessage('服务器', _announcement('a1', '系统维护通知'));
      expect(state.unreadOf('服务器'), 1, reason: '公告应产生未读徽标');
      expect(state.totalUnread, 1);
    });

    test('查看系统会话后徽标清零', () {
      state.setLoggedIn('alice', false);
      state.addMessage('服务器', _announcement('a1', '通知'));
      state.addMessage('服务器', _announcement('a2', '通知2'));
      expect(state.unreadOf('服务器'), 2);
      state.selectChat('服务器');
      expect(state.unreadOf('服务器'), 0, reason: '查看后徽标清零');
    });

    test('正在查看系统会话时公告到达 → 不计未读', () {
      state.setLoggedIn('alice', false);
      state.selectChat('服务器');
      state.addMessage('服务器', _announcement('a1', '通知'));
      expect(state.unreadOf('服务器'), 0);
    });

    test('已读历史公告（delivered）不计未读（回归）', () {
      state.setLoggedIn('alice', false);
      state.addMessage('服务器',
          _announcement('a1', '历史公告', status: 'delivered'));
      expect(state.unreadOf('服务器'), 0);
      expect(state.totalUnread, 0);
    });

    test('公告徽标与好友会话未读独立', () {
      state.setLoggedIn('alice', false);
      state.addMessage('服务器', _announcement('a1', '公告'));
      state.addMessage('bob',
          ChatMessage(sender: 'bob', content: 'hi', messageId: 'm1'));
      expect(state.unreadOf('服务器'), 1);
      expect(state.unreadOf('bob'), 1);
      state.selectChat('服务器');
      expect(state.unreadOf('服务器'), 0);
      expect(state.unreadOf('bob'), 1, reason: '仅清空当前会话');
    });
  });
}
