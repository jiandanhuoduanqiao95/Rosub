// opt8 #1/#13 —— 附件路径统一解析器 + 唯一接收路径
//
// 契约：
//   - receivedAttachmentPath：messageId 净化前缀（形变追加快照哈希防碰撞）
//     + 安全文件名；同名文件不同 messageId → 路径不同（防覆盖根）；
//   - resolveMessageAttachmentPath 顺序：filePath → SentFileStore →
//     唯一接收路径 → [file_meta 终止，不走 legacy] → 旧版按文件名路径
//     （isSelf 不走旧接收目录）；
//   - resolveFileRecordPath 顺序：唯一接收路径 → 旧路径（仅接收方）→
//     SentFileStore；
//   - 文件不存在的候选一律跳过；全部 miss → null。
//
// 文件系统隔离：Android 平台 override + documentsDirResolver 注入临时
// 目录（Linux 恒 CWD 兼容路径不走 resolver，见 AppPaths.ensureInitialized），
// received_files/sent_files 全部落临时目录，不触碰仓库真实目录。

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/app_paths.dart';
import 'package:chatroom_flutter/services/file_names.dart';
import 'package:chatroom_flutter/services/message_attachment.dart';
import 'package:chatroom_flutter/services/sent_file_store.dart';

const prefix = 'opt8att_';

ChatMessage _msg(String id,
    {String status = 'sent',
    String? filePath,
    String? filename,
    String sender = 'bob',
    bool isFileMeta = false}) {
  return ChatMessage(
    sender: sender,
    content: '[文件] ${filename ?? ''}',
    type: 'file',
    messageId: id,
    timestamp: DateTime(2026, 1, 1, 12),
    status: status,
    filename: filename,
    filePath: filePath,
    isFileMeta: isFileMeta,
  );
}

FileRecord _record(String id, String filename,
    {String sender = 'bob', String receiver = 'alice'}) {
  return FileRecord(
    filename: filename,
    filesize: 10,
    sender: sender,
    receiver: receiver,
    messageId: id,
    timestamp: DateTime(2026, 1, 1, 12),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Directory? tmpDir;
  final created = <String>[];

  String receiveDir() => AppPaths.receivedFilesDir;
  String sentDir() => AppPaths.sentFilesDir;

  File touch(String path) {
    final f = File(path);
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync([1, 2, 3]);
    created.add(path);
    return f;
  }

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tmpDir = await Directory.systemTemp.createTemp('opt8_att_test');
    AppPaths.resetForTest();
    final captured = tmpDir!;
    AppPaths.documentsDirResolver = () async => captured.path;
    await AppPaths.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    SentFileStore.resetForTest();
    created.clear();
  });

  tearDown(() {
    for (final p in created) {
      final f = File(p);
      if (f.existsSync()) f.deleteSync();
    }
    created.clear();
    SentFileStore.resetForTest();
    AppPaths.resetForTest();
    debugDefaultTargetPlatformOverride = null;
    final d = tmpDir;
    if (d != null && d.existsSync()) {
      d.deleteSync(recursive: true);
    }
    tmpDir = null;
  });

  group('file_names —— 文件名/组件净化', () {
    test('sanitizeFilename：basename / 空与点回退 received_file', () {
      expect(sanitizeFilename('a/b/c.png'), 'c.png');
      expect(sanitizeFilename('a\\b.png'), 'b.png');
      expect(sanitizeFilename('x.png'), 'x.png');
      expect(sanitizeFilename(''), 'received_file');
      expect(sanitizeFilename('.'), 'received_file');
      expect(sanitizeFilename('..'), 'received_file');
      expect(sanitizeFilename('dir/'), 'received_file');
    });

    test('sanitizeStorageComponent：非法字符替换为下划线', () {
      expect(sanitizeStorageComponent('abc_123-XYZ'), 'abc_123-XYZ');
      expect(sanitizeStorageComponent(''), '');
      expect(sanitizeStorageComponent('.'), '_');
      expect(sanitizeStorageComponent('..'), '__');
      expect(sanitizeStorageComponent('../../etc/passwd'),
          '______etc_passwd');
      expect(sanitizeStorageComponent('中文id'), '__id');
    });
  });

  group('receivedAttachmentPath —— 唯一接收路径（opt8 #13）', () {
    test('同名文件不同 messageId → 路径不同', () {
      final a = receivedAttachmentPath('msgA', 'photo.png');
      final b = receivedAttachmentPath('msgB', 'photo.png');
      expect(a, isNot(equals(b)));
      expect(a.endsWith('_photo.png'), isTrue);
    });

    test('普通安全 messageId 路径格式不变（兼容已写入文件）', () {
      final p = receivedAttachmentPath('plain_id-1', 'f.png');
      expect(p, '${receiveDir()}/plain_id-1_f.png');
    });

    test('净化形变追加快照哈希：a.b 与 a_b 路径不同且互不等于原样', () {
      final dot = receivedAttachmentPath('a.b', 'f.png');
      final underscore = receivedAttachmentPath('a_b', 'f.png');
      expect(dot, isNot(equals(underscore)));
      final dotName = dot.split('/').last;
      expect(dotName.startsWith('a_b_'), isTrue,
          reason: '含点 messageId 净化形变 → 追加哈希防与 a_b 碰撞');
      expect(dotName.endsWith('_f.png'), isTrue);
      final dotHash = dotName.split('_f.png').first.split('a_b_').last;
      expect(dotHash.length, 8);
      expect(RegExp(r'^[0-9a-f]{8}$').hasMatch(dotHash), isTrue);
    });

    test('messageId 特殊字符净化：路径安全 + 哈希后缀；空 id 回退 unknown', () {
      final p = receivedAttachmentPath('id/..\\x', 'f.png');
      final name = p.split('/').last;
      expect(name.contains('/'), isFalse);
      expect(name.contains('\\'), isFalse);
      expect(name.endsWith('_f.png'), isTrue);
      expect(name.startsWith('id'), isTrue);
      final unknown = receivedAttachmentPath('', 'f.png');
      expect(unknown.startsWith('${receiveDir()}/unknown_'), isTrue);
      expect(unknown.endsWith('_f.png'), isTrue);
    });
  });

  group('resolveMessageAttachmentPath —— 气泡解析顺序', () {
    test('1) filePath 存在优先返回', () {
      final fp = touch('${receiveDir()}/${prefix}direct.png');
      final m = _msg('m1', filePath: fp.path, filename: 'photo.png');
      expect(resolveMessageAttachmentPath(m, isSelf: true), fp.path);
    });

    test('2) filePath 失效 → SentFileStore 命中（#1 重启恢复链）', () async {
      await SentFileStore.init();
      final sentPath = touch('${sentDir()}/${prefix}m2_photo.png');
      await SentFileStore.record('m2', sentPath.path);
      final m = _msg('m2', filename: 'photo.png', sender: 'alice');
      final resolved = resolveMessageAttachmentPath(m, isSelf: true);
      expect(resolved, sentPath.path);
    });

    test('3) 唯一接收路径命中（messageId 推导，不依赖 filePath 字段）', () {
      final m = _msg('msgX', filename: 'photo.png');
      final derived = receivedAttachmentPath('msgX', 'photo.png');
      touch(derived);
      expect(resolveMessageAttachmentPath(m), derived);
    });

    test('5) 旧版按文件名路径兜底（仅非 isSelf；隔离目录内通用名安全）', () {
      touch('${receiveDir()}/photo.png');
      final m = _msg('no-unique', filename: 'photo.png');
      expect(resolveMessageAttachmentPath(m, isSelf: false),
          '${receiveDir()}/photo.png');
      expect(resolveMessageAttachmentPath(m, isSelf: true), isNull);
    });

    test('file_meta 消息不走 legacy 回退（不串同名旧图）', () {
      touch('${receiveDir()}/photo.png');
      final m = _msg('meta-1', filename: 'photo.png', isFileMeta: true);
      expect(resolveMessageAttachmentPath(m, isSelf: false), isNull);
    });

    test('file_meta 命中唯一接收路径时仍返回（该设备确有该文件）', () {
      final derived =
          touch(receivedAttachmentPath('meta-2', 'photo.png'));
      final m = _msg('meta-2', filename: 'photo.png', isFileMeta: true);
      expect(resolveMessageAttachmentPath(m), derived.path);
    });

    test('全部 miss → null；filePath 指向不存在文件时继续回退', () {
      final m = _msg('ghost',
          filePath: '${receiveDir()}/${prefix}ghost_missing.png',
          filename: 'photo.png');
      expect(resolveMessageAttachmentPath(m, isSelf: true), isNull);
    });

    test('文件不存在 → null（不猜路径）', () {
      final m = _msg('none', filename: 'missing.png');
      expect(resolveMessageAttachmentPath(m), isNull);
    });
  });

  group('resolveFileRecordPath —— 文件管理页解析', () {
    test('唯一接收路径命中（messageId 版本优先于旧文件名版本）', () {
      final unique =
          touch(receivedAttachmentPath('${prefix}rec1', 'photo.png'));
      final r = _record('${prefix}rec1', 'photo.png');
      expect(resolveFileRecordPath(r, currentUser: 'alice'), unique.path);
    });

    test('旧路径仅接收方解析；发送方（isSelf）跳过旧路径走 SentFileStore',
        () async {
      await SentFileStore.init();
      touch('${receiveDir()}/legacy.png');
      final r = _record('${prefix}legacy1', 'legacy.png', sender: 'bob');
      expect(resolveFileRecordPath(r, currentUser: 'alice'),
          '${receiveDir()}/legacy.png');

      final self = _record('${prefix}self1', 'legacy.png', sender: 'alice');
      expect(resolveFileRecordPath(self, currentUser: 'alice'), isNull);

      final sentPath = touch('${sentDir()}/${prefix}self1_legacy.png');
      await SentFileStore.record('${prefix}self1', sentPath.path);
      expect(resolveFileRecordPath(self, currentUser: 'alice'),
          sentPath.path);
    });

    test('全部 miss → null', () {
      final r = _record('${prefix}ghost', 'ghost.png');
      expect(resolveFileRecordPath(r, currentUser: 'alice'), isNull);
    });
  });
}
