// ============================================================
// sent_file_store.dart —— 已发送文件路径映射（Q1 五轮问题2）
// ============================================================
// 契约：
//   - init() 预载后 pathOf 同步可查；未 init 时 record 跳过、
//     pathOf 恒 null（安全 no-op，不抛异常）；
//   - record 空参数跳过；同 messageId 覆盖（upsert）；
//   - 上限 200 条 FIFO 淘汰（最旧的先出）；
//   - 持久化于 shared_preferences（键 sent_file_paths），重进应用可查。
// ============================================================

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chatroom_flutter/services/sent_file_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SentFileStore.resetForTest();
  });

  group('Q1 五轮问题2 —— SentFileStore 路径映射', () {
    test('未 init：record 安全跳过、pathOf 恒 null（不抛异常）', () async {
      await SentFileStore.record('m1', '/tmp/a.pdf');
      expect(SentFileStore.pathOf('m1'), isNull);
    });

    test('init 后 record → pathOf 同步可查（自己发送的文件回看数据源）',
        () async {
      await SentFileStore.init();
      await SentFileStore.record('m1', '/tmp/a.pdf');
      expect(SentFileStore.pathOf('m1'), '/tmp/a.pdf');
    });

    test('空参数跳过；同 messageId 覆盖', () async {
      await SentFileStore.init();
      await SentFileStore.record('', '/tmp/a.pdf');
      await SentFileStore.record('m1', '');
      expect(SentFileStore.pathOf('m1'), isNull);
      expect(SentFileStore.pathOf(''), isNull);

      await SentFileStore.record('m1', '/tmp/old.pdf');
      await SentFileStore.record('m1', '/tmp/new.pdf');
      expect(SentFileStore.pathOf('m1'), '/tmp/new.pdf');
    });

    test('持久化：重置缓存后重新 init 可查（重进应用语义）', () async {
      await SentFileStore.init();
      await SentFileStore.record('m1', '/tmp/a.pdf');
      SentFileStore.resetForTest();
      expect(SentFileStore.pathOf('m1'), isNull);
      await SentFileStore.init();
      expect(SentFileStore.pathOf('m1'), '/tmp/a.pdf');
    });

    test('FIFO 上限 200 条（最旧淘汰）', () async {
      await SentFileStore.init();
      for (var i = 0; i < 205; i++) {
        await SentFileStore.record('m$i', '/tmp/f$i');
      }
      expect(SentFileStore.pathOf('m0'), isNull, reason: '最旧的 5 条被淘汰');
      expect(SentFileStore.pathOf('m4'), isNull);
      expect(SentFileStore.pathOf('m5'), '/tmp/f5', reason: '第 6 条起保留');
      expect(SentFileStore.pathOf('m204'), '/tmp/f204');
    });

    test('持久化数据损坏 → init 静默回退空表（不抛异常）', () async {
      SharedPreferences.setMockInitialValues({
        'sent_file_paths': 'not-json{',
      });
      await SentFileStore.init();
      expect(SentFileStore.pathOf('m1'), isNull);
      // 损坏后仍可正常记录
      await SentFileStore.record('m1', '/tmp/a.pdf');
      expect(SentFileStore.pathOf('m1'), '/tmp/a.pdf');
    });

    test('存储键与 JSON 形态锁定（跨版本兼容）', () async {
      await SentFileStore.init();
      await SentFileStore.record('m1', '/tmp/a.pdf');
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('sent_file_paths');
      expect(raw, isNotNull);
      final decoded = jsonDecode(raw!) as Map;
      expect(decoded['m1'], '/tmp/a.pdf');
    });
  });
}
