// ============================================================
// chat_models.dart 阶段 P —— 体验升级模型契约（TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 P：
//
//   P1 富媒体消息气泡：
//     - isVideoFilename(filename)：视频扩展名判定（大小写不敏感），
//       支持 .mp4/.mov/.webm/.m4v/.avi/.mkv
//     - formatFileSize(bytes)：人类可读文件大小（B/KB/MB/GB，1 位小数，
//       <1KB 显示整数 B；0 → '0 B'）
//     - ChatMessage 新增可选 filesize 字段（文件消息字节数，服务端
//       filesize 头/本地已知时填充；null = 未知，气泡省略大小行）
//
//   P2 表情包体系：
//     - Sticker 模型（R-P3：扁平"我的表情包"，无包名概念）
//     - emojiPickerCategories：扩展常用表情集（≥4 分类、每类 ≥8 个、
//       全局无重复；首分类 '常用' 须完整包含 defaultReactionEmojis——
//       阶段 K 既有表情盘不丢失回归）
//
//   P3 复合条件消息搜索（R-P28 修订：发送者选项式多选 + 模糊日期单入口）：
//     - MessageSearchFilter：关键词/多发送者/模糊日期组合检索条件
//       （senders 列表 → 协议头 'sender' 逗号分隔；date 模糊日期 →
//       'time_from'/'time_to'（epoch 秒字符串，与 O5 schedule_at 口径一致））
//     - SearchDateSelection：年/年月/年月日三档模糊精度 → 本地时间
//       范围（from 当档起点 / to 当档终点 23:59:59）+ 中文摘要 label
//
// 实现前：本文件引用尚未实现的 API，编译失败或用例红，属 TDD 红。
// 实现后：全部转绿。
// ============================================================

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';

void main() {
  // ============================================================
  // P1 —— 富媒体消息气泡
  // ============================================================
  group('P1 —— isVideoFilename 视频扩展名判定', () {
    test('常见视频扩展名 → true', () {
      expect(isVideoFilename('clip.mp4'), isTrue);
      expect(isVideoFilename('clip.mov'), isTrue);
      expect(isVideoFilename('clip.webm'), isTrue);
      expect(isVideoFilename('clip.m4v'), isTrue);
      expect(isVideoFilename('clip.avi'), isTrue);
      expect(isVideoFilename('clip.mkv'), isTrue);
    });

    test('大小写不敏感', () {
      expect(isVideoFilename('CLIP.MP4'), isTrue);
      expect(isVideoFilename('clip.Mp4'), isTrue);
      expect(isVideoFilename('录像.WEBM'), isTrue);
    });

    test('非视频扩展名 → false', () {
      expect(isVideoFilename('photo.png'), isFalse);
      expect(isVideoFilename('doc.pdf'), isFalse);
      expect(isVideoFilename('song.mp3'), isFalse);
      expect(isVideoFilename('noext'), isFalse);
      expect(isVideoFilename(''), isFalse);
      expect(isVideoFilename('mp4'), isFalse, reason: '无点号不算扩展名');
      expect(isVideoFilename('fake.mp4.exe'), isFalse, reason: '仅按最终扩展名判定');
    });
  });

  group('P1 —— formatFileSize 人类可读大小', () {
    test('字节区间', () {
      expect(formatFileSize(0), '0 B');
      expect(formatFileSize(1), '1 B');
      expect(formatFileSize(512), '512 B');
      expect(formatFileSize(1023), '1023 B');
    });

    test('KB 区间（1 位小数）', () {
      expect(formatFileSize(1024), '1.0 KB');
      expect(formatFileSize(1536), '1.5 KB');
      expect(formatFileSize(10 * 1024), '10.0 KB');
    });

    test('MB 区间（1 位小数）', () {
      expect(formatFileSize(1024 * 1024), '1.0 MB');
      expect(formatFileSize(1024 * 1536), '1.5 MB');
      expect(formatFileSize(5 * 1024 * 1024), '5.0 MB');
    });

    test('GB 区间（1 位小数）', () {
      expect(formatFileSize(1024 * 1024 * 1024), '1.0 GB');
      final twoAndHalf = (2.5 * 1024 * 1024 * 1024).round();
      expect(formatFileSize(twoAndHalf), '2.5 GB');
    });
  });

  group('P1 —— ChatMessage.filesize 字段', () {
    test('默认 null；构造可传', () {
      final plain =
          ChatMessage(sender: 'alice', content: '[文件] a.pdf', messageId: 'f1');
      expect(plain.filesize, isNull, reason: '缺省 filesize 为 null（未知）');

      final sized = ChatMessage(
          sender: 'alice',
          content: '[文件] a.pdf',
          messageId: 'f2',
          filesize: 2048);
      expect(sized.filesize, 2048);
    });

    test('回归：filesize 不影响 displayText（文件消息格式不变）', () {
      final msg = ChatMessage(
          sender: 'alice',
          content: '[文件] a.pdf',
          messageId: 'f3',
          filename: 'a.pdf',
          filesize: 4096);
      expect(msg.displayText, 'alice: [文件] a.pdf');
    });

    test('回归：filesize 不影响撤回显示（文件撤回标志不变）', () {
      final msg = ChatMessage(
          sender: 'alice',
          content: '[文件] a.pdf',
          messageId: 'f4',
          type: 'file',
          filename: 'a.pdf',
          filesize: 4096,
          status: 'recalled');
      expect(msg.displayText, 'alice: [文件] a.pdf [已撤回]');
    });
  });

  // ============================================================
  // P2 —— 表情包体系
  // ============================================================
  group('P2 —— Sticker 模型', () {
    test('构造 + toJson/fromJson 往返', () {
      const sticker = Sticker(id: 's1', name: 'sticker_s1.png');
      final json = sticker.toJson();
      final back = Sticker.fromJson(json);
      expect(back.id, 's1');
      expect(back.name, 'sticker_s1.png');
    });

    test('fromJson 防御性解析（缺失字段 → 空串，不抛异常）', () {
      final sticker = Sticker.fromJson(const {});
      expect(sticker.id, '');
      expect(sticker.name, '');
      expect(() => Sticker.fromJson(<String, dynamic>{'id': 1, 'name': 2}),
          returnsNormally,
          reason: '类型漂移不抛异常');
    });
  });

  group('P2 —— emojiPickerCategories 扩展常用表情集', () {
    test('≥4 个分类，每分类 ≥8 个表情', () {
      expect(emojiPickerCategories.length, greaterThanOrEqualTo(4),
          reason: '扩展常用表情集至少 4 个分类');
      for (final category in emojiPickerCategories) {
        expect(category.$2.length, greaterThanOrEqualTo(8),
            reason: "分类 '${category.$1}' 表情数不足 8");
      }
    });

    test('全局无重复表情', () {
      final all = [
        for (final category in emojiPickerCategories) ...category.$2,
      ];
      expect(all.toSet().length, all.length, reason: '表情集内不得重复');
    });

    test("首分类 '常用' 完整包含 defaultReactionEmojis（阶段 K 回归）", () {
      expect(emojiPickerCategories.first.$1, '常用');
      final common = emojiPickerCategories.first.$2;
      for (final emoji in defaultReactionEmojis) {
        expect(common, contains(emoji), reason: '既有表情盘 emoji $emoji 不得在扩展集中丢失');
      }
    });
  });

  // ============================================================
  // P3 —— 复合条件消息搜索
  // ============================================================
  group('P3 —— MessageSearchFilter 组合语义', () {
    test('默认构造：无过滤条件', () {
      const filter = MessageSearchFilter();
      expect(filter.keyword, '');
      expect(filter.senders, isEmpty);
      expect(filter.date, isNull);
      expect(filter.from, isNull);
      expect(filter.to, isNull);
      expect(filter.hasFilters, isFalse);
    });

    test('任一字段设置即 hasFilters', () {
      expect(const MessageSearchFilter(keyword: '你好').hasFilters, isTrue);
      expect(const MessageSearchFilter(senders: ['bob']).hasFilters, isTrue);
      expect(
        const MessageSearchFilter(
                date: SearchDateSelection(year: 2026, month: 9))
            .hasFilters,
        isTrue,
      );
      expect(
          const MessageSearchFilter(keyword: 'x').hasFilters, isTrue);
    });

    test('toHeaders：空条件仅携带 keyword', () {
      const filter = MessageSearchFilter();
      final headers = filter.toHeaders();
      expect(headers, {'keyword': ''});
    });

    test('toHeaders：关键词 + 单发送者', () {
      const filter = MessageSearchFilter(keyword: ' 会议 ', senders: ['bob']);
      final headers = filter.toHeaders();
      expect(headers['keyword'], '会议', reason: '关键词 trim');
      expect(headers['sender'], 'bob');
      expect(headers.containsKey('time_from'), isFalse);
      expect(headers.containsKey('time_to'), isFalse);
    });

    test('toHeaders：多发送者逗号分隔（R-P28 选项式多选）', () {
      const filter = MessageSearchFilter(senders: ['bob', 'alice']);
      final headers = filter.toHeaders();
      expect(headers['sender'], 'bob,alice', reason: '多发送者 join(\',\')');
      expect(headers.length, 2);
    });

    test('toHeaders：年精度 date → 全年范围头（epoch 秒）', () {
      const filter = MessageSearchFilter(date: SearchDateSelection(year: 2026));
      final headers = filter.toHeaders();
      final expectedFrom =
          (DateTime(2026, 1, 1).millisecondsSinceEpoch ~/ 1000).toString();
      final expectedTo = (DateTime(2026, 12, 31, 23, 59, 59)
              .millisecondsSinceEpoch ~/
          1000)
          .toString();
      expect(headers['time_from'], expectedFrom);
      expect(headers['time_to'], expectedTo);
      expect(headers.length, 3, reason: 'keyword 恒在');
    });

    test('toHeaders：完整组合', () {
      const filter = MessageSearchFilter(
        keyword: '报告',
        senders: ['carol'],
        date: SearchDateSelection(year: 2026, month: 9, day: 3),
      );
      final headers = filter.toHeaders();
      expect(headers['keyword'], '报告');
      expect(headers['sender'], 'carol');
      expect(headers['time_from'],
          (DateTime(2026, 9, 3).millisecondsSinceEpoch ~/ 1000).toString());
      expect(
          headers['time_to'],
          (DateTime(2026, 9, 3, 23, 59, 59).millisecondsSinceEpoch ~/ 1000)
              .toString());
      expect(headers.length, 4);
    });
  });

  group('P3 —— SearchDateSelection 模糊日期（R-P28 托盘选择）', () {
    test('仅年 → 全年范围 + 摘要', () {
      const sel = SearchDateSelection(year: 2026);
      expect(sel.from, DateTime(2026, 1, 1), reason: '当年 1 月 1 日零点');
      expect(sel.to, DateTime(2026, 12, 31, 23, 59, 59), reason: '当年末');
      expect(sel.label, '2026年');
    });

    test('年月 → 整月范围（2 月平年 28 天 / 闰年 29 天）', () {
      const feb = SearchDateSelection(year: 2026, month: 2);
      expect(feb.from, DateTime(2026, 2, 1));
      expect(feb.to, DateTime(2026, 2, 28, 23, 59, 59));
      expect(feb.label, '2026年2月');
      const leap = SearchDateSelection(year: 2028, month: 2);
      expect(leap.to, DateTime(2028, 2, 29, 23, 59, 59), reason: '闰年');
    });

    test('小月月末（4 月 → 30 日）', () {
      const apr = SearchDateSelection(year: 2026, month: 4);
      expect(apr.to, DateTime(2026, 4, 30, 23, 59, 59));
    });

    test('年月日 → 全天范围 + 摘要', () {
      const sel = SearchDateSelection(year: 2026, month: 9, day: 3);
      expect(sel.from, DateTime(2026, 9, 3), reason: '当日零点');
      expect(sel.to, DateTime(2026, 9, 3, 23, 59, 59), reason: '当日末 23:59:59');
      expect(sel.label, '2026年9月3日');
    });
  });
}
