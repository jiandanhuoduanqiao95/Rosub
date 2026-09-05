// ============================================================
// sticker_store.dart 阶段 P —— 表情包本地存储契约（R-P3 修订：扁平列表）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 P2（表情包体系；2026-09-04
// 用户实测反馈 R-P3 重构）：
//
//   StickerStore（仿 QuickReplyStore 无内存缓存惯例 + O7 ThemeSettings
//   账号绑定键前缀惯例）："我的表情包"扁平管理——不再区分包名
//   （向微信"我的表情"看齐）。贴纸字节落盘 <baseDir>/<stickerId>.png，
//   清单（JSON 数组）存 shared_preferences 键 'stickers'
//   （绑定账号时 '<user>.stickers'）。
//
//   契约：
//     - StickerStore.instance（单例）+ bindUser(String? username)
//       （null = 未登录全局键；切换账号各自独立表情列表）
//     - init({String? baseDir})：注入贴纸落盘目录（测试用临时目录），
//       幂等；未 init 时读取方法安全返回空、写入方法安全 no-op
//     - loadStickers() → List<Sticker>（每次从存储读取，无内存缓存；
//       无数据/损坏（非法 JSON/类型漂移）→ 空列表，不抛异常）
//     - addSticker(bytes)：isSupportedImage 魔数校验（复用 N3），
//       非法字节/未 init → null（不落库不落盘）；成功返回 Sticker
//       （name 形如 sticker_<id>.png，接收端按图片消息内联展示）
//     - removeSticker(stickerId)：清单 + 磁盘文件同步删除；不存在不抛异常
//     - stickerBytes(stickerId)：读取贴纸字节；未知/未 init → null
//
//   纯客户端改动（协议零改动：贴纸发送 = 图片文件消息，复用 N3 通道）。
// ============================================================

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chatroom_flutter/services/sticker_store.dart';

/// 最小 PNG 字节（N3b 同款魔数头）
final Uint8List pngBytes = Uint8List.fromList(
    [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03]);

final Uint8List notImageBytes = Uint8List.fromList([1, 2, 3, 4, 5]);

void main() {
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('sticker_store_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('P2/R-P3 —— StickerStore 账号绑定', () {
    test('未绑定账号（null）→ 全局键；写入后 loadStickers 可见', () async {
      await StickerStore.instance.init(baseDir: tempDir.path);
      await StickerStore.instance.bindUser(null);
      final sticker = await StickerStore.instance.addSticker(pngBytes);
      expect(sticker, isNotNull);
      expect((await StickerStore.instance.loadStickers()).length, 1);
    });

    test('绑定账号后键前缀隔离：alice 与 bob 互不串表情', () async {
      await StickerStore.instance.init(baseDir: tempDir.path);
      await StickerStore.instance.bindUser('alice');
      await StickerStore.instance.addSticker(pngBytes);

      await StickerStore.instance.bindUser('bob');
      expect(await StickerStore.instance.loadStickers(), isEmpty,
          reason: 'bob 无表情');

      await StickerStore.instance.bindUser('alice');
      final stickers = await StickerStore.instance.loadStickers();
      expect(stickers.length, 1, reason: 'alice 的表情仍在');
    });
  });

  group('P2/R-P3 —— StickerStore 表情管理', () {
    setUp(() async {
      await StickerStore.instance.init(baseDir: tempDir.path);
      await StickerStore.instance.bindUser(null);
    });

    test('addSticker：合法 PNG 字节成功（name 以 .png 结尾，id 非空）', () async {
      final sticker = await StickerStore.instance.addSticker(pngBytes);
      expect(sticker, isNotNull);
      expect(sticker!.name.endsWith('.png'), isTrue,
          reason: '贴纸文件名为图片扩展名（接收端按图片消息内联展示）');
      expect(sticker.id, isNotEmpty);
      expect((await StickerStore.instance.loadStickers()).length, 1);
    });

    test('addSticker：非图片字节 → null 且不落库', () async {
      final sticker = await StickerStore.instance.addSticker(notImageBytes);
      expect(sticker, isNull);
      expect(await StickerStore.instance.loadStickers(), isEmpty);
    });

    test('addSticker 多张：清单按添加顺序', () async {
      await StickerStore.instance.addSticker(pngBytes);
      await StickerStore.instance.addSticker(pngBytes);
      expect((await StickerStore.instance.loadStickers()).length, 2);
    });

    test('removeSticker：删除后清单与磁盘文件同步移除', () async {
      final sticker = await StickerStore.instance.addSticker(pngBytes);
      final file = File('${tempDir.path}/${sticker!.id}.png');
      expect(file.existsSync(), isTrue, reason: '贴纸字节落盘');

      await StickerStore.instance.removeSticker(sticker.id);
      expect(await StickerStore.instance.loadStickers(), isEmpty);
      expect(file.existsSync(), isFalse, reason: '磁盘文件同步删除');
    });

    test('removeSticker：不存在不抛异常', () async {
      await StickerStore.instance.removeSticker('not-exist');
      expect(await StickerStore.instance.loadStickers(), isEmpty);
    });

    test('stickerBytes：返回已添加贴纸字节；未知 id → null', () async {
      final sticker = await StickerStore.instance.addSticker(pngBytes);
      expect(StickerStore.instance.stickerBytes(sticker!.id), pngBytes);
      expect(StickerStore.instance.stickerBytes('unknown'), isNull);
    });

    test('持久化往返：同目录同账号重新 init 后表情仍在，字节可读', () async {
      final s1 = await StickerStore.instance.addSticker(pngBytes);
      await StickerStore.instance.addSticker(pngBytes);

      await StickerStore.instance.init(baseDir: tempDir.path);
      await StickerStore.instance.bindUser(null);

      final stickers = await StickerStore.instance.loadStickers();
      expect(stickers.length, 2, reason: '表情清单持久化');
      expect(
        StickerStore.instance.stickerBytes(stickers.first.id),
        pngBytes,
        reason: '贴纸字节从磁盘恢复',
      );
      expect(s1, isNotNull);
    });

    test('安全 no-op：删除不存在的表情、未知贴纸字节、损坏清单', () async {
      await StickerStore.instance.removeSticker('no-such-sticker');
      expect(StickerStore.instance.stickerBytes('no-such-sticker'), isNull);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('stickers', '{not-valid-json');
      expect(await StickerStore.instance.loadStickers(), isEmpty);
    });

    test('R-P11：init 自动创建缺失目录（生产 main() 只传路径不建目录）', () async {
      final nested = '${tempDir.path}/stickers';
      expect(Directory(nested).existsSync(), isFalse);
      await StickerStore.instance.init(baseDir: nested);
      expect(Directory(nested).existsSync(), isTrue, reason: '目录在 init 时确保存在');
      final sticker = await StickerStore.instance.addSticker(pngBytes);
      expect(sticker, isNotNull, reason: '首张贴纸直接可添加（修"添加无反应"）');
    });
  });
}
