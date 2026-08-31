// ============================================================
// quick_reply_store.dart 阶段 O —— O4 快捷回复（常用语）契约（TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 O：
//   O4（P2-3 快捷回复）：高频短语一键发送；**本地存储**常用语列表，
//   输入框旁入口。纯客户端改动（协议零改动）。
//
// 契约：新增 lib/services/quick_reply_store.dart
//   class QuickReplyStore {
//     static const List<String> defaultPhrases;   // ['收到','好的','谢谢','稍等','再见']
//     static Future<List<String>> load();         // 空/损坏 → defaultPhrases
//     static Future<void> save(List<String> phrases);
//     static Future<void> add(String phrase);     // trim；空忽略；去重
//     static Future<void> remove(String phrase);
//   }
//   - 持久化：shared_preferences 键 'quick_replies'（JSON 字符串数组）
//   - 损坏数据（非法 JSON/类型漂移）→ 回退默认列表（不抛异常）
//
// UI 契约（showQuickReplyPanel / 输入框旁入口）见 dialogs_stage_o_test.dart
// 与 chat_view_stage_o_test.dart。
//
// 实现前：本文件引用尚未实现的类，编译失败或用例红，属 TDD 红。
// 实现后：全部转绿。
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chatroom_flutter/services/quick_reply_store.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('O4 —— QuickReplyStore 默认值', () {
    test('无存储数据 → 返回默认常用语', () async {
      final phrases = await QuickReplyStore.load();
      expect(phrases, QuickReplyStore.defaultPhrases);
      expect(phrases, contains('收到'));
      expect(phrases, contains('好的'));
    });

    test('默认列表非空且全部非空白短语', () {
      expect(QuickReplyStore.defaultPhrases, isNotEmpty);
      expect(
        QuickReplyStore.defaultPhrases.every((p) => p.trim().isNotEmpty),
        isTrue,
      );
    });

    test('损坏数据（非法 JSON）→ 回退默认列表（不抛异常）', () async {
      SharedPreferences.setMockInitialValues({'quick_replies': '不是JSON'});
      final phrases = await QuickReplyStore.load();
      expect(phrases, QuickReplyStore.defaultPhrases);
    });

    test('类型漂移（JSON 对象而非数组）→ 回退默认列表', () async {
      SharedPreferences.setMockInitialValues({'quick_replies': '{"a":1}'});
      final phrases = await QuickReplyStore.load();
      expect(phrases, QuickReplyStore.defaultPhrases);
    });
  });

  group('O4 —— QuickReplyStore 保存与读取', () {
    test('save 后 load 往返一致（中文短语）', () async {
      await QuickReplyStore.save(['在吗', '马上来', '收到！']);
      expect(await QuickReplyStore.load(), ['在吗', '马上来', '收到！']);
    });

    test('save 持久化到 shared_preferences（JSON 数组）', () async {
      await QuickReplyStore.save(['自定义短语']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('quick_replies'), isNotNull);
    });

    test('save trim 短语并丢弃空白项', () async {
      await QuickReplyStore.save(['  好的  ', '   ', 'ok']);
      expect(await QuickReplyStore.load(), ['好的', 'ok']);
    });

    test('允许保存空列表（用户清空全部常用语）', () async {
      await QuickReplyStore.save(['临时']);
      await QuickReplyStore.save([]);
      expect(await QuickReplyStore.load(), isEmpty);
    });
  });

  group('O4 —— QuickReplyStore 增删', () {
    test('add 追加新短语', () async {
      await QuickReplyStore.add('辛苦了');
      expect(await QuickReplyStore.load(), contains('辛苦了'));
    });

    test('add trim 且忽略空白', () async {
      await QuickReplyStore.add(' 收到 ');
      await QuickReplyStore.add('   ');
      expect(await QuickReplyStore.load(), ['收到']);
    });

    test('add 去重（已存在不重复添加）', () async {
      await QuickReplyStore.add('好的');
      await QuickReplyStore.add('好的');
      final phrases = await QuickReplyStore.load();
      expect(phrases.where((p) => p == '好的'), hasLength(1));
    });

    test('remove 移除指定短语', () async {
      await QuickReplyStore.add('稍后回复');
      await QuickReplyStore.remove('稍后回复');
      expect(await QuickReplyStore.load(), isNot(contains('稍后回复')));
    });

    test('remove 不存在的短语不抛异常（既有列表不变）', () async {
      await QuickReplyStore.save(['保留']);
      await QuickReplyStore.remove('不存在的短语');
      expect(await QuickReplyStore.load(), ['保留']);
    });
  });
}
