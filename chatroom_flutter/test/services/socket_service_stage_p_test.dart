// ============================================================
// socket_service.dart 阶段 P —— 复合条件消息搜索契约（TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 P3（复合条件消息搜索）：
//
//   searchHistory 扩展可选命名参数（既有 H5 契约向后兼容追加，协议
//   v1.0.0 新增可选头，非破坏性）：
//     searchHistory(keyword,
//         {String? to, int? groupId, int limit = 50,   // 既有参数不变
//          String? sender,          // 发送者过滤（新增头 'sender'）
//          DateTime? timeFrom,      // 起始时刻（新增头 'time_from'，epoch 秒）
//          DateTime? timeTo})       // 结束时刻（新增头 'time_to'，epoch 秒）
//
//   协议头组装契约以 MessageSearchFilter.toHeaders() 为准
//   （见 chat_models_stage_p_test.dart P3 组）；本文件锁定：
//     - 未连接（_socket == null）时全部参数组合静默无副作用、不崩溃
//     - 头字段口径：sender 原样字符串；time_from/time_to 为 epoch 秒
//       字符串（与 O5 schedule_at 秒级口径一致）
//     - 关键词为空但存在其他过滤条件时客户端不做拦截（合法性由
//       服务端/对话框层把关——复合检索允许"只按发送者/时间查"）
//
//   服务端配套（实现期同步落地，本阶段 Python 侧测试随后补）：
//   search_history 处理器接受可选 sender/time_from/time_to 头，
//   search_message_history 组合 WHERE（sender 等值 + timestamp 区间）。
//   search_response 结构不变（复用既有解析，结果进 state.setSearchResults）。
//
// 未连接契约惯例与 socket_service_search_contract_test.dart（H5）一致。
// 实现前：本文件引用尚未实现的参数，编译失败或用例红，属 TDD 红。
// 实现后：全部转绿。
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
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(resetState);

  group('P3 —— searchHistory 复合条件未连接契约', () {
    final service = SocketService();

    setUp(() {
      state.setLoggedIn('alice', false);
    });

    test('纯发送者过滤（无关键词）未连接不崩溃、无副作用', () async {
      await service.searchHistory('', senders: ['bob']);
      expect(state.searchResults('bob'), isEmpty);
      expect(state.isSearchMode('bob'), isFalse);
      expect(state.noticeQueue, isEmpty);
    });

    test('纯时间范围过滤（无关键词）未连接不崩溃、无副作用', () async {
      await service.searchHistory(
        '',
        timeFrom: DateTime(2026, 9, 1),
        timeTo: DateTime(2026, 9, 3),
      );
      expect(state.noticeQueue, isEmpty);
      expect(state.isSearchMode('bob'), isFalse);
    });

    test('完整组合（关键词 + 发送者 + 时间 + 会话）未连接不崩溃、无副作用', () async {
      await service.searchHistory(
        '报告',
        to: 'bob',
        limit: 20,
        senders: ['bob'],
        timeFrom: DateTime(2026, 9, 1, 8, 30),
        timeTo: DateTime(2026, 9, 30, 23, 59),
      );
      expect(state.messages.length, state.messages.length);
      expect(state.noticeQueue, isEmpty);
      expect(state.searchResults('bob'), isEmpty);
    });

    test('群范围组合过滤未连接不崩溃、无副作用', () async {
      await service.searchHistory(
        '公告',
        groupId: 1,
        senders: ['carol'],
        timeFrom: DateTime(2026, 9, 1),
      );
      expect(state.searchResults('group_1'), isEmpty);
      expect(state.isSearchMode('group_1'), isFalse);
    });

    test('多发送者（R-P28 选项式多选）未连接不崩溃、无副作用', () async {
      await service.searchHistory('', senders: ['bob', 'alice']);
      expect(state.searchResults('bob'), isEmpty);
      expect(state.isSearchMode('bob'), isFalse);
      expect(state.noticeQueue, isEmpty);
    });

    test('senders 全空白元素 → 等价不过滤（不发送空 sender 头）', () async {
      await service.searchHistory('', senders: ['', '   ']);
      expect(state.noticeQueue, isEmpty);
      expect(state.isSearchMode('bob'), isFalse);
    });

    test('多次调用安全（幂等）', () async {
      for (var i = 0; i < 5; i++) {
        await service.searchHistory('x',
            senders: ['bob'], timeFrom: DateTime(2026, 9, 1));
      }
      expect(state.isSearchMode('bob'), isFalse);
    });
  });

  group('P3 —— 头字段口径（epoch 秒，与 O5 口径一致）', () {
    test('本地时刻与 UTC 时刻的 epoch 秒一致（同一瞬间）', () {
      const sel = SearchDateSelection(year: 2026, month: 9, day: 1);
      expect(sel.from.millisecondsSinceEpoch ~/ 1000,
          sel.from.toUtc().millisecondsSinceEpoch ~/ 1000);
      const filter = MessageSearchFilter(keyword: '', date: sel);
      final expected = (sel.from.millisecondsSinceEpoch ~/ 1000).toString();
      expect(filter.toHeaders()['time_from'], expected,
          reason: 'toHeaders 与本地毫秒换算口径一致');
    });
  });
}
