// ============================================================
// export_saver.dart + AppPaths.exportsDir 契约（Q1 真机反馈 #8）
// ============================================================
// 反馈 #8（聊天记录导出点击 TXT/JSON 无反应）：根因为
// FilePicker.platform.saveFile 在移动端不返回路径 → path==null
// 静默 return。
//
// 契约：新增 lib/services/export_saver.dart ——
//
//   ExportSaver.saveExportFile({baseName, format, content})
//     · 移动端（Android/iOS，mobileTargetForTest 可注入）：
//       直接写 '<AppPaths.exportsDir>/<baseName>-<时间戳>.<format>'，
//       返回完整路径（目录不存在自动创建）；
//     · 桌面：FilePicker.saveFile 系统另存为（取消 → null），
//       既有语义不变；
//     · IO 异常向上抛（调用方提示"导出失败"）。
//
//   AppPaths.exportsDir：
//     · exportsDirResolver 注入优先（Q0 resolver 惯例）；
//     · Android 走 path_provider getExternalStorageDirectory
//       （源码扫描锁定），其余非 Linux 平台走文档目录；
//     · 未初始化/解析失败 → 'exports'（兼容值语义，不抛异常；
//       Linux 桌面恒走 FilePicker 另存，不消费此目录）；
//     · resetForTest 清注入与缓存。
//
// 测试环境注意：宿主为 Linux → AppPaths.ensureInitialized 直接就绪
// （Q0-4 语义），exportsDir 相关用例须模拟 android 平台驱动非 Linux
// 解析分支（§21.1 规约：body 内设 override、finally 恢复）。
// ============================================================

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/services/app_paths.dart';
import 'package:chatroom_flutter/services/export_saver.dart';

/// 桌面"另存为"桩：直接继承 FilePicker（公共构造自带 PlatformInterface
/// token，无需 mock PlatformInterfaceMixin）
class _StubFilePicker extends FilePicker {
  String? result;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async =>
      result;
}

Future<String> makeTmpRoot() async {
  final tmp = await Directory.systemTemp.createTemp('q1_export');
  return tmp.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppPaths.resetForTest();
    ExportSaver.resetForTest();
    debugDefaultTargetPlatformOverride = null;
  });
  tearDown(() {
    AppPaths.resetForTest();
    ExportSaver.resetForTest();
    debugDefaultTargetPlatformOverride = null;
  });

  group('AppPaths.exportsDir（Q1 反馈 #8 配套）', () {
    test('未初始化访问回退兼容值 exports（不抛异常）', () {
      expect(AppPaths.exportsDir, 'exports');
    });

    test('Linux 桌面：ensureInitialized 恒兼容值（不消费导出目录）', () async {
      final tmp = await makeTmpRoot();
      addTearDown(() => Directory(tmp).deleteSync(recursive: true));
      await AppPaths.ensureInitialized();

      expect(AppPaths.exportsDir, 'exports',
          reason: 'Linux 恒 FilePicker 另存（Q0-4 语义延伸）');
    });

    test('android 模拟 + resolver 注入：ensureInitialized 后 = <root>/exports',
        () async {
      final tmp = await makeTmpRoot();
      addTearDown(() => Directory(tmp).deleteSync(recursive: true));
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AppPaths.exportsDirResolver = () async => tmp;
      try {
        await AppPaths.ensureInitialized();
        expect(AppPaths.exportsDir, '$tmp/exports');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('android 模拟 + resolver 异常：静默回退（不抛异常）', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AppPaths.exportsDirResolver = () async => throw Exception('no dir');
      try {
        await AppPaths.ensureInitialized();
        expect(AppPaths.exportsDir, 'exports', reason: '解析失败回退兼容值（安全降级惯例）');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('resetForTest 清注入与缓存', () async {
      final tmp = await makeTmpRoot();
      addTearDown(() => Directory(tmp).deleteSync(recursive: true));
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AppPaths.exportsDirResolver = () async => tmp;
      try {
        await AppPaths.ensureInitialized();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
      AppPaths.resetForTest();
      expect(AppPaths.exportsDir, 'exports');
    });

    test('源码扫描：Android 分支走 getExternalStorageDirectory', () {
      final src = File('lib/services/app_paths.dart').readAsStringSync();
      expect(src.contains('getExternalStorageDirectory'), isTrue,
          reason: 'Android 导出根目录 = 外部存储应用专属目录（文件管理器可见）');
    });
  });

  group('ExportSaver 移动端分流', () {
    test('mobile：目录自动创建、内容完整落盘、文件名含 baseName/格式/时间戳', () async {
      final tmp = await makeTmpRoot();
      addTearDown(() => Directory(tmp).deleteSync(recursive: true));
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AppPaths.exportsDirResolver = () async => tmp;
      await AppPaths.ensureInitialized();
      ExportSaver.mobileTargetForTest = true;
      try {
        final path = await ExportSaver.saveExportFile(
          baseName: 'chat_bob',
          format: 'txt',
          content: 'hello export',
        );

        expect(path, isNotNull);
        expect(File(path!).existsSync(), isTrue);
        expect(File(path).readAsStringSync(), 'hello export');
        expect(path.startsWith('$tmp/exports/chat_bob-'), isTrue,
            reason: '落盘 exports 子目录（自动创建）');
        expect(path.endsWith('.txt'), isTrue);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('mobile：JSON 同语义', () async {
      final tmp = await makeTmpRoot();
      addTearDown(() => Directory(tmp).deleteSync(recursive: true));
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AppPaths.exportsDirResolver = () async => tmp;
      await AppPaths.ensureInitialized();
      ExportSaver.mobileTargetForTest = true;
      try {
        final path = await ExportSaver.saveExportFile(
          baseName: 'chat_group_1',
          format: 'json',
          content: '{}',
        );
        expect(path, isNotNull);
        expect(path!.endsWith('.json'), isTrue);
        expect(File(path).readAsStringSync(), '{}');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('desktop：FilePicker 取消 → null；选择路径 → 写入', () async {
      ExportSaver.mobileTargetForTest = false;
      final picker = _StubFilePicker();
      FilePicker.platform = picker;

      picker.result = null;
      expect(
          await ExportSaver.saveExportFile(
              baseName: 'a', format: 'txt', content: 'x'),
          isNull,
          reason: '用户取消返回 null（桌面既有语义）');

      final target =
          '${Directory.systemTemp.path}/q1_export_desktop_${DateTime.now().microsecondsSinceEpoch}.txt';
      addTearDown(() {
        final f = File(target);
        if (f.existsSync()) f.deleteSync();
      });
      picker.result = target;
      final path = await ExportSaver.saveExportFile(
          baseName: 'a', format: 'txt', content: 'desk');
      expect(path, target);
      expect(File(target).readAsStringSync(), 'desk');
    });

    test('IO 异常向上抛（调用方提示导出失败）', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AppPaths.exportsDirResolver = () async => '/proc/q1-impossible-dir';
      await AppPaths.ensureInitialized();
      ExportSaver.mobileTargetForTest = true;
      try {
        await expectLater(
          ExportSaver.saveExportFile(
              baseName: 'a', format: 'txt', content: 'x'),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('Q1 反馈 #8 —— 导出接线（源码扫描）', () {
    test('chat_screen 与 dialogs 的导出改经 ExportSaver，FilePicker.saveFile 清零', () {
      final chat = File('lib/screens/chat_screen.dart').readAsStringSync();
      final dialogs = File('lib/widgets/dialogs.dart').readAsStringSync();
      final saver = File('lib/services/export_saver.dart').readAsStringSync();

      expect(chat.contains('ExportSaver.saveExportFile'), isTrue,
          reason: '聊天记录导出走 ExportSaver');
      expect(chat.contains('FilePicker.platform'), isFalse,
          reason: 'chat_screen 不再直调 FilePicker');
      expect(dialogs.contains('ExportSaver.saveExportFile'), isTrue,
          reason: '审计日志导出同源修复');
      expect(dialogs.contains('FilePicker.platform.saveFile'), isFalse);
      expect(saver.contains('FilePicker.platform.saveFile'), isTrue,
          reason: '桌面另存为语义收敛在 ExportSaver 单点');
    });
  });
}
