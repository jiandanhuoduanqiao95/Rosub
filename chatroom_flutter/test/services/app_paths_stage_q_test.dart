// ============================================================
// 存储路径迁移契约（阶段 Q0-4 —— TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 Q「Q0-4 存储路径迁移」：
//
//   received_files/stickers 由 CWD 相对路径（config.dart
//   receivedFilesDir/stickerStoreDir）迁移到 path_provider 平台目录；
//   Linux 桌面保持现路径兼容既有数据。
//
// 契约：新增 lib/services/app_paths.dart ——
//
//   class AppPaths {
//     static Future<void> ensureInitialized();   // 幂等，main() 启动调用
//     static String get receivedFilesDir;        // 同步读缓存
//     static String get stickerStoreDir;
//     // 测试注入点（仿 TaskbarNotifier.playSoundImpl 惯例）：返回
//     // "应用文档目录"；null → 走 path_provider getApplicationDocumentsDirectory
//     static Future<String?> Function()? documentsDirResolver;
//     static void resetForTest();
//   }
//
//   · Linux（defaultTargetPlatform == TargetPlatform.linux）：恒返回
//     CWD 相对路径 'received_files' / 'stickers'（== AppConfig 既有
//     常量），兼容既有落盘数据；不依赖 path_provider（resolver 注入
//     不改变 Linux 结果）
//   · 非 Linux：'<documentsDir>/received_files'、'<documentsDir>/
//     stickers'（子目录名保留，数据可辨识）；documentsDir 来自
//     path_provider（源码扫描锁定）或 resolver 注入
//   · 未初始化访问：同步 getter 回退 Linux 兼容值（防御既有调用点，
//     不抛异常）；生产正确性由 main() 启动即 ensureInitialized 保证
//   · path_provider 异常（插件未注册/平台通道缺失）：ensureInitialized
//     捕获并回退 Linux 兼容值，不崩（安全降级惯例）
//   · 接线：main() → ensureInitialized() + StickerStore.instance.init
//     (baseDir: AppPaths.stickerStoreDir)；socket_service/chat_screen/
//     chat_view 的调用点全部改走 AppPaths（源码扫描锁定）
//   · AppConfig.receivedFilesDir/stickerStoreDir 常量保留（Linux 兼容
//     值引用源 + 既有测试依赖）
//
// path_provider 已在 pubspec 依赖（^2.1.0，message_cache_store.dart
// 阶段 L3 先例）。实现期如需 crypto/其他新依赖按分支纪律落主干。
//
// 实现前：app_paths.dart 不存在，本文件编译失败，属 TDD 红。
// 实现后：全部转绿。
// ============================================================

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chatroom_flutter/config.dart';
import 'package:chatroom_flutter/services/app_paths.dart';
import 'package:chatroom_flutter/services/sticker_store.dart';

String srcOf(String relPath) => File('lib/$relPath').readAsStringSync();

int countOf(String source, String needle) => source.split(needle).length - 1;

final Uint8List pngBytes = Uint8List.fromList(
    [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03]);

void main() {
  setUp(() {
    AppPaths.resetForTest();
    debugDefaultTargetPlatformOverride = null;
  });
  tearDown(() {
    AppPaths.resetForTest();
    debugDefaultTargetPlatformOverride = null;
  });

  group('Q0-4 —— Linux 桌面保持现路径（兼容既有数据，回归锁定）', () {
    test('未初始化访问回退 Linux 兼容值（防御既有调用点，不抛异常）', () {
      expect(AppPaths.receivedFilesDir, AppConfig.receivedFilesDir,
          reason: "CWD 相对 'received_files'，行为与迁移前完全一致");
      expect(AppPaths.stickerStoreDir, AppConfig.stickerStoreDir,
          reason: "CWD 相对 'stickers'");
    });

    test('ensureInitialized 后 Linux 路径不变（不依赖 path_provider）', () async {
      await AppPaths.ensureInitialized();
      expect(AppPaths.receivedFilesDir, AppConfig.receivedFilesDir);
      expect(AppPaths.stickerStoreDir, AppConfig.stickerStoreDir);
    });

    test('ensureInitialized 幂等（连续调用安全）', () async {
      await AppPaths.ensureInitialized();
      await AppPaths.ensureInitialized();
      await AppPaths.ensureInitialized();
      expect(AppPaths.receivedFilesDir, AppConfig.receivedFilesDir);
    });

    test('resolver 注入文档目录不改变 Linux 结果（Linux 恒 CWD 兼容）', () async {
      AppPaths.documentsDirResolver = () async => '/fake/docs';
      await AppPaths.ensureInitialized();
      expect(AppPaths.receivedFilesDir, AppConfig.receivedFilesDir,
          reason: 'Linux 兼容优先——resolver 仅对非 Linux 生效');
      expect(AppPaths.stickerStoreDir, AppConfig.stickerStoreDir);
    });
  });

  group('Q0-4 —— 非 Linux 迁移到 path_provider 平台目录', () {
    test('android：receivedFilesDir = <documentsDir>/received_files', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AppPaths.documentsDirResolver = () async => '/data/user/0/cn.tset/files';
      await AppPaths.ensureInitialized();
      expect(AppPaths.receivedFilesDir,
          '/data/user/0/cn.tset/files/received_files');
    });

    test('android：stickerStoreDir = <documentsDir>/stickers', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AppPaths.documentsDirResolver = () async => '/data/user/0/cn.tset/files';
      await AppPaths.ensureInitialized();
      expect(AppPaths.stickerStoreDir, '/data/user/0/cn.tset/files/stickers');
    });

    test('ios/windows/macos：以文档目录为前缀（子目录名保留）', () async {
      for (final platform in {
        TargetPlatform.iOS,
        TargetPlatform.windows,
        TargetPlatform.macOS,
      }) {
        debugDefaultTargetPlatformOverride = platform;
        AppPaths.documentsDirResolver = () async => '/fake/docs';
        await AppPaths.ensureInitialized();
        expect(AppPaths.receivedFilesDir, '/fake/docs/received_files',
            reason: '$platform 接收文件目录迁入平台文档目录');
        expect(AppPaths.stickerStoreDir, '/fake/docs/stickers',
            reason: '$platform 贴纸目录迁入平台文档目录');
      }
    });

    test('path_provider 异常（插件未注册）→ ensureInitialized 不崩并回退兼容值', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await AppPaths.ensureInitialized();
      expect(AppPaths.receivedFilesDir, AppConfig.receivedFilesDir,
          reason: '无 resolver 时 flutter test 环境取不到平台目录，安全降级');
      expect(AppPaths.stickerStoreDir, AppConfig.stickerStoreDir);
    });

    test('resetForTest 后缓存清空（回到未初始化防御态）', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AppPaths.documentsDirResolver = () async => '/fake/docs';
      await AppPaths.ensureInitialized();
      expect(AppPaths.stickerStoreDir, '/fake/docs/stickers');
      AppPaths.resetForTest();
      debugDefaultTargetPlatformOverride = null;
      expect(AppPaths.stickerStoreDir, AppConfig.stickerStoreDir,
          reason: 'reset 后回到 Linux 兼容防御值');
    });
  });

  group('Q0-4 —— StickerStore 目录接线（Linux 语义行为验证）', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('main 接线等价路径：AppPaths.stickerStoreDir 注入后贴纸落盘 CWD/stickers', () async {
      await AppPaths.ensureInitialized();
      await StickerStore.instance.init(baseDir: AppPaths.stickerStoreDir);
      await StickerStore.instance.bindUser(null);
      final sticker = await StickerStore.instance.addSticker(pngBytes);
      expect(sticker, isNotNull, reason: 'AppPaths 注入值可正常落盘');
      final file = File(
          '${Directory.current.path}/${AppConfig.stickerStoreDir}/${sticker!.id}.png');
      expect(file.existsSync(), isTrue, reason: 'Linux 兼容：落盘位置与迁移前一致');
      await StickerStore.instance.removeSticker(sticker.id);
      expect(file.existsSync(), isFalse);
    });
  });

  group('Q0-4 —— 调用点收敛与迁移锁定（源码扫描）', () {
    test('socket_service.dart 不再直接引用 AppConfig.receivedFilesDir', () {
      final src = srcOf('services/socket_service.dart');
      expect(countOf(src, 'AppConfig.receivedFilesDir'), 0,
          reason: '_prepareReceiveTarget/_saveReceivedFile 改走 AppPaths');
      expect(
          countOf(src, 'AppPaths.receivedFilesDir'), greaterThanOrEqualTo(2));
    });

    test('chat_screen.dart 不再直接引用 AppConfig.receivedFilesDir', () {
      final src = srcOf('screens/chat_screen.dart');
      expect(countOf(src, 'AppConfig.receivedFilesDir'), 0,
          reason: '4 处接收路径改走 AppPaths');
      expect(
          countOf(src, 'AppPaths.receivedFilesDir'), greaterThanOrEqualTo(4));
    });

    test('chat_view.dart 不再直接引用 AppConfig.receivedFilesDir', () {
      final src = srcOf('widgets/chat_view.dart');
      expect(countOf(src, 'AppConfig.receivedFilesDir'), 0);
      expect(
          countOf(src, 'AppPaths.receivedFilesDir'), greaterThanOrEqualTo(1));
    });

    test('app_paths.dart 确实使用 path_provider（迁移本体锁定）', () {
      final src = srcOf('services/app_paths.dart');
      expect(src.contains('getApplicationDocumentsDirectory'), isTrue,
          reason: 'path_provider 化是 Q0-4 的核心动作，非仅加注入点');
      expect(src.contains("package:path_provider/path_provider.dart"), isTrue);
    });

    test('main.dart 接线：ensureInitialized + StickerStore 用 AppPaths 目录', () {
      final src = srcOf('main.dart');
      expect(src.contains('AppPaths.ensureInitialized'), isTrue);
      expect(src.contains('AppPaths.stickerStoreDir'), isTrue,
          reason: 'R-P11 生产 init 注入点改用平台目录');
    });

    test('AppConfig 既有常量保留（Linux 兼容值引用源 + 既有测试依赖）', () {
      final src = srcOf('config.dart');
      expect(src.contains('receivedFilesDir'), isTrue);
      expect(src.contains('stickerStoreDir'), isTrue);
    });
  });
}
