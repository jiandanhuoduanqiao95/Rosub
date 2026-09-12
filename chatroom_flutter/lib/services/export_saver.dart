/// 导出文件落盘（Q1 真机反馈 #8：聊天记录导出在 Android 点击 TXT/JSON
/// 无反应——`FilePicker.platform.saveFile` 移动端不返回路径，原实现
/// path==null 静默 return）
///
/// 平台分流：
///   - 桌面（Linux/Windows/macOS）：既有语义不变——系统"另存为"对话框
///     （FilePicker.saveFile），用户取消返回 null；
///   - 移动端（Android/iOS）：无对话框直接落盘 `<AppPaths.exportsDir>/
///     <baseName>-<时间戳>.<format>`（Android 为外部存储应用专属目录，
///     文件管理器可见），返回完整路径供调用方提示。
///
/// [mobileTargetForTest] 为测试注入点（null = dart:io Platform 判定）。

import 'dart:io';

import 'package:file_picker/file_picker.dart';

import 'app_paths.dart';

class ExportSaver {
  ExportSaver._();

  /// 测试注入点：强制按移动端/桌面分流；null → 真实平台判定
  static bool? mobileTargetForTest;

  static bool get _isMobile =>
      mobileTargetForTest ?? (Platform.isAndroid || Platform.isIOS);

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// 落盘导出内容并返回文件路径；用户取消（桌面另存对话框）返回 null。
  /// IO 异常向上抛出，由调用方提示（与既有"导出失败"文案一致）。
  static Future<String?> saveExportFile({
    required String baseName,
    required String format,
    required String content,
  }) async {
    if (_isMobile) {
      final dir = Directory(AppPaths.exportsDir);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      final now = DateTime.now();
      final stamp = '${now.year}${_two(now.month)}${_two(now.day)}'
          '-${_two(now.hour)}${_two(now.minute)}${_two(now.second)}';
      final path = '${dir.path}/$baseName-$stamp.$format';
      await File(path).writeAsString(content);
      return path;
    }
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '导出文件',
      fileName: '$baseName.$format',
    );
    if (path == null) return null;
    await File(path).writeAsString(content);
    return path;
  }

  /// 测试复位（注入点清零）
  static void resetForTest() {
    mobileTargetForTest = null;
  }
}
