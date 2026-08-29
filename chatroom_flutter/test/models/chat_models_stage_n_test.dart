// ============================================================
// chat_models.dart + chat_exporter.dart 阶段 N —— 日常使用便利性模型契约（TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 N：
//   - N6（P2-6）SessionInfo 模型：登录设备管理（sessions_response 消息）
//   - N7（P2-7）AuditLogEntry 模型：审计日志（admin_response
//     response_type=audit_log 消息）
//   - N3（P2-4）isSupportedImage：图片粘贴直发/拖拽发送的图片字节识别
//     （PNG/JPEG/GIF 魔数校验）
//   - N2（P2-1）ChatExporter：聊天记录导出（TXT 人工可读 / JSON 完整元数据）
//
// 实现前：本文件引用尚未实现的类/方法，编译失败或用例红，属 TDD 红。
// 实现后：全部转绿。
// ============================================================

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/chat_exporter.dart';

ChatMessage msg({
  required String sender,
  required String content,
  String type = 'chat',
  required String messageId,
  required DateTime timestamp,
  String status = 'sent',
  String? filename,
  String? replyTo,
  String? replyPreview,
  Map<String, List<String>> reactions = const {},
}) {
  return ChatMessage(
    sender: sender,
    content: content,
    type: type,
    messageId: messageId,
    timestamp: timestamp,
    status: status,
    filename: filename,
    replyTo: replyTo,
    replyPreview: replyPreview,
    reactions: reactions,
  );
}

void main() {
  group('N6 —— SessionInfo 设备会话模型（sessions_response）', () {
    test('fromJson 解析完整字段（last_active 数字字符串）', () {
      final s = SessionInfo.fromJson(const {
        'device_id': 'linux',
        'last_active': '1724690000',
        'is_current': true,
      });
      expect(s.deviceId, 'linux');
      expect(
        s.lastActive,
        DateTime.fromMillisecondsSinceEpoch(1724690000 * 1000),
        reason: 'last_active 为 epoch 秒 → 毫秒转换',
      );
      expect(s.isCurrent, isTrue);
    });

    test('fromJson last_active 为数字（非字符串）防御性解析', () {
      final s = SessionInfo.fromJson(const {
        'device_id': 'android',
        'last_active': 1724690000.5,
        'is_current': false,
      });
      expect(s.lastActive.millisecondsSinceEpoch, 1724690000500);
      expect(s.isCurrent, isFalse);
    });

    test('fromJson 缺失 last_active → epoch 0', () {
      final s = SessionInfo.fromJson(const {'device_id': 'linux'});
      expect(s.lastActive, DateTime.fromMillisecondsSinceEpoch(0));
    });

    test('fromJson 非法 last_active → epoch 0（不抛异常）', () {
      final s = SessionInfo.fromJson(const {
        'device_id': 'linux',
        'last_active': 'abc',
      });
      expect(s.lastActive, DateTime.fromMillisecondsSinceEpoch(0));
    });

    test('fromJson 缺失 is_current → false', () {
      final s = SessionInfo.fromJson(const {'device_id': 'linux'});
      expect(s.isCurrent, isFalse);
    });

    test('fromJson 缺失 device_id → 空串', () {
      final s = SessionInfo.fromJson(const {'last_active': '1'});
      expect(s.deviceId, '');
    });
  });

  group('N7 —— AuditLogEntry 审计记录模型（audit_log）', () {
    test('fromJson 解析完整字段（timestamp UTC → 本地时间）', () {
      final e = AuditLogEntry.fromJson(const {
        'id': 1,
        'operator': 'admin',
        'action': 'delete_user',
        'target': 'bob',
        'detail': '',
        'timestamp': '2026-08-26 10:00:00',
      });
      expect(e.id, 1);
      expect(e.operator, 'admin');
      expect(e.action, 'delete_user');
      expect(e.target, 'bob');
      expect(e.detail, '');
      expect(e.timestamp, isNotNull);
      expect(e.timestamp!.toUtc().hour, 10, reason: '服务端时间按 UTC 解析');
    });

    test('fromJson 缺失字段 → 空串缺省（防御性）', () {
      final e = AuditLogEntry.fromJson(const {'action': 'announcement'});
      expect(e.operator, '');
      expect(e.target, '');
      expect(e.detail, '');
      expect(e.id, 0);
    });

    test('fromJson 非法 timestamp → null（不抛异常）', () {
      final e = AuditLogEntry.fromJson(const {
        'action': 'kick_member',
        'timestamp': 'not-a-time',
      });
      expect(e.timestamp, isNull);
    });

    test('fromJson id 为字符串 → 防御性解析', () {
      final e = AuditLogEntry.fromJson(const {'id': '7', 'action': 'x'});
      expect(e.id, 7);
    });
  });

  group('N3 —— isSupportedImage 图片字节识别（P2-4）', () {
    test('PNG 魔数识别', () {
      final png = Uint8List.fromList(
          [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00]);
      expect(isSupportedImage(png), isTrue);
    });

    test('JPEG 魔数识别', () {
      final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]);
      expect(isSupportedImage(jpeg), isTrue);
    });

    test('GIF 魔数识别', () {
      final gif = Uint8List.fromList([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]);
      expect(isSupportedImage(gif), isTrue);
    });

    test('文本字节不是图片', () {
      final text = Uint8List.fromList('hello world'.codeUnits);
      expect(isSupportedImage(text), isFalse);
    });

    test('空字节不是图片', () {
      expect(isSupportedImage(Uint8List(0)), isFalse);
    });
  });

  group('N3b —— isImageFilename 图片扩展名识别（P2-4 扩展）', () {
    test('png 识别', () {
      expect(isImageFilename('photo.png'), isTrue);
    });

    test('jpg/jpeg 识别', () {
      expect(isImageFilename('a.jpg'), isTrue);
      expect(isImageFilename('b.jpeg'), isTrue);
    });

    test('gif 识别', () {
      expect(isImageFilename('动画.gif'), isTrue);
    });

    test('扩展名大小写不敏感', () {
      expect(isImageFilename('PHOTO.PNG'), isTrue);
      expect(isImageFilename('Img.JpEg'), isTrue);
    });

    test('非图片扩展名', () {
      expect(isImageFilename('doc.txt'), isFalse);
      expect(isImageFilename('archive.pdf'), isFalse);
    });

    test('无扩展名', () {
      expect(isImageFilename('README'), isFalse);
    });
  });

  group('N2 —— ChatExporter 聊天记录导出（P2-1）', () {
    final at = DateTime(2026, 8, 26, 10, 0, 0);

    test('exportTxt 基本格式：头部 + 消息行 + 页脚', () {
      final out = ChatExporter.exportTxt(
        chatKey: 'bob',
        messages: [
          msg(
              sender: 'alice',
              content: '你好',
              messageId: 'm1',
              timestamp: DateTime(2026, 8, 26, 10, 0, 1)),
          msg(
              sender: 'bob',
              content: '收到',
              messageId: 'm2',
              timestamp: DateTime(2026, 8, 26, 10, 0, 2)),
        ],
        exportedAt: at,
      );
      expect(out, contains('============ 聊天记录 ============'));
      expect(out, contains('会话: bob'));
      expect(out, contains('导出时间: 2026-08-26 10:00:00'));
      expect(out, contains('消息数: 2'));
      expect(out, contains('[10:00:01] alice: 你好'));
      expect(out, contains('[10:00:02] bob: 收到'));
    });

    test('exportTxt 文件消息行', () {
      final out = ChatExporter.exportTxt(
        chatKey: 'bob',
        messages: [
          msg(
              sender: 'alice',
              content: '[收到文件] report.pdf',
              messageId: 'm1',
              timestamp: DateTime(2026, 8, 26, 10, 0, 1),
              type: 'file',
              filename: 'report.pdf'),
        ],
        exportedAt: at,
      );
      expect(out, contains('[10:00:01] alice: [文件] report.pdf'));
    });

    test('exportTxt 撤回消息（文本 / 文件）', () {
      final out = ChatExporter.exportTxt(
        chatKey: 'bob',
        messages: [
          msg(
              sender: 'alice',
              content: '说错话',
              messageId: 'm1',
              timestamp: DateTime(2026, 8, 26, 10, 0, 1),
              status: 'recalled'),
          msg(
              sender: 'alice',
              content: '[收到文件] a.zip',
              messageId: 'm2',
              timestamp: DateTime(2026, 8, 26, 10, 0, 2),
              type: 'file',
              filename: 'a.zip',
              status: 'recalled'),
        ],
        exportedAt: at,
      );
      expect(out, contains('[10:00:01] alice: [消息已撤回]'));
      expect(out, contains('[10:00:02] alice: [文件] a.zip [已撤回]'));
    });

    test('exportTxt 发送中 / 发送失败标记', () {
      final out = ChatExporter.exportTxt(
        chatKey: 'bob',
        messages: [
          msg(
              sender: 'alice',
              content: '发出中',
              messageId: 'm1',
              timestamp: DateTime(2026, 8, 26, 10, 0, 1),
              status: 'sending'),
          msg(
              sender: 'alice',
              content: '失败了',
              messageId: 'm2',
              timestamp: DateTime(2026, 8, 26, 10, 0, 2),
              status: 'failed'),
        ],
        exportedAt: at,
      );
      expect(out, contains('[10:00:01] alice: 发出中（发送中）'));
      expect(out, contains('[10:00:02] alice: 失败了（发送失败）'));
    });

    test('exportTxt 引用回复缩进行', () {
      final out = ChatExporter.exportTxt(
        chatKey: 'bob',
        messages: [
          msg(
              sender: 'alice',
              content: '同意楼上',
              messageId: 'm2',
              timestamp: DateTime(2026, 8, 26, 10, 0, 2),
              replyTo: 'm1',
              replyPreview: '原方案可行'),
        ],
        exportedAt: at,
      );
      expect(out, contains('[10:00:02] alice: 同意楼上'));
      expect(out, contains('↳ 回复: 原方案可行'));
    });

    test('exportTxt 空消息列表', () {
      final out =
          ChatExporter.exportTxt(chatKey: 'bob', messages: [], exportedAt: at);
      expect(out, contains('消息数: 0'));
    });

    test('exportTxt 导出时间为可选（缺省不抛）', () {
      final out = ChatExporter.exportTxt(chatKey: 'bob', messages: []);
      expect(out, contains('消息数: 0'));
    });

    test('exportJson 结构含完整元数据', () {
      final out = ChatExporter.exportJson(
        chatKey: 'group_1',
        messages: [
          msg(
              sender: 'alice',
              content: '你好',
              messageId: 'm1',
              timestamp: DateTime(2026, 8, 26, 10, 0, 1),
              status: 'delivered',
              replyTo: 'm0',
              replyPreview: '原文',
              reactions: {
                '👍': ['bob']
              }),
          msg(
              sender: 'bob',
              content: '[收到文件] a.pdf',
              messageId: 'm2',
              timestamp: DateTime(2026, 8, 26, 10, 0, 2),
              type: 'file',
              filename: 'a.pdf'),
        ],
        exportedAt: at,
      );
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect(decoded['chat_key'], 'group_1');
      expect(decoded['message_count'], 2);
      expect(decoded['exported_at'], '2026-08-26 10:00:00');
      final messages = decoded['messages'] as List<dynamic>;
      final m0 = messages[0] as Map<String, dynamic>;
      expect(m0['sender'], 'alice');
      expect(m0['content'], '你好');
      expect(m0['type'], 'chat');
      expect(m0['message_id'], 'm1');
      expect(m0['timestamp'], '2026-08-26 10:00:01');
      expect(m0['status'], 'delivered');
      expect(m0['reply_to'], 'm0');
      expect(m0['reply_preview'], '原文');
      expect(m0['reactions'], {
        '👍': ['bob']
      });
      final m1 = messages[1] as Map<String, dynamic>;
      expect(m1['filename'], 'a.pdf');
      expect(m1['group_id'], isNull);
    });

    test('exportJson 引号/换行转义', () {
      final out = ChatExporter.exportJson(
        chatKey: 'bob',
        messages: [
          msg(
              sender: 'alice',
              content: '他说"你好"\n第二行',
              messageId: 'm1',
              timestamp: DateTime(2026, 8, 26, 10, 0, 1)),
        ],
        exportedAt: at,
      );
      // jsonDecode 成功即转义正确，且内容无损
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      final m = (decoded['messages'] as List).first as Map<String, dynamic>;
      expect(m['content'], '他说"你好"\n第二行');
    });

    test('exportJson 空消息列表', () {
      final out =
          ChatExporter.exportJson(chatKey: 'bob', messages: [], exportedAt: at);
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect(decoded['message_count'], 0);
      expect(decoded['messages'], isEmpty);
    });
  });
}
