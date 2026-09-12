/// 应用存储目录解析（阶段 Q0-4 —— 存储路径迁移到平台目录）
///
/// received_files / stickers 旧实现为 CWD 相对路径（config.dart 常量，
/// Linux 桌面运行时 CWD 即项目根，落盘位置可预期）。多端后移动端
/// CWD 不可写，迁移到 path_provider 平台目录：
///   - Linux（TargetPlatform.linux）：**恒返回既有 CWD 相对路径**
///     （== AppConfig.receivedFilesDir / AppConfig.stickerStoreDir），
///     兼容既有落盘数据，且不依赖 path_provider（resolver 注入不
///     改变 Linux 结果）；
///   - 其余平台：`<getApplicationDocumentsDirectory>/received_files`
///     与 `.../stickers`（子目录名保留，数据可辨识）。
///
/// 用法：main() 启动先 `await AppPaths.ensureInitialized()`，之后
/// 同步 getter 即返回确定值；未初始化访问回退 Linux 兼容值（防御
/// 存量调用点，不抛异常）。path_provider 异常（插件未注册/平台通道
/// 缺失）时安全降级为兼容值。测试注入：documentsDirResolver（返回
/// 文档目录；null → 走 path_provider），resetForTest() 复位。
///
/// 平台判定统一走 effectiveTargetPlatform()（§21.1 平台模拟规约：
/// 显式 override 优先，无 override 回退 dart:io Platform）。

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../config.dart';
import '../platform/capabilities.dart';

class AppPaths {
  AppPaths._();

  /// 测试注入点：返回"应用文档目录"；null → path_provider 真实解析
  static Future<String?> Function()? documentsDirResolver;

  /// 测试注入点：返回"导出文件根目录"（Q1 真机反馈：移动端导出走
  /// 直接落盘，根目录 Android 取外部存储应用目录、iOS 取文档目录）；
  /// null → 按平台走 path_provider，异常时回退文档目录
  static Future<String?> Function()? exportsDirResolver;

  static bool _initialized = false;
  static String? _documentsDir;
  static String? _exportsRootDir;

  /// 解析平台文档目录并缓存（幂等，main() 启动调用）。
  /// Linux 直接就绪（兼容路径无需解析）；其余平台解析失败
  /// （插件未注册/目录为空）静默回退——getter 落到兼容值。
  static Future<void> ensureInitialized() async {
    if (_initialized) return;
    if (effectiveTargetPlatform() == TargetPlatform.linux) {
      _initialized = true;
      return;
    }
    String? docs;
    try {
      final resolver = documentsDirResolver;
      docs = resolver != null
          ? await resolver()
          : (await getApplicationDocumentsDirectory()).path;
    } catch (_) {
      docs = null;
    }
    _documentsDir = (docs == null || docs.isEmpty) ? null : docs;
    // 导出根目录独立解析（Android 外部存储目录；失败回退文档目录）
    String? exportsRoot;
    try {
      final resolver = exportsDirResolver;
      if (resolver != null) {
        exportsRoot = await resolver();
      } else if (effectiveTargetPlatform() == TargetPlatform.android) {
        exportsRoot = (await getExternalStorageDirectory())?.path;
      } else {
        exportsRoot = (await getApplicationDocumentsDirectory()).path;
      }
    } catch (_) {
      exportsRoot = null;
    }
    _exportsRootDir = (exportsRoot == null || exportsRoot.isEmpty)
        ? _documentsDir
        : exportsRoot;
    _initialized = true;
  }

  /// 接收文件保存目录（原 config.dart receivedFilesDir 调用点统一改走此 getter）
  static String get receivedFilesDir => _resolve(AppConfig.receivedFilesDir);

  /// 已发送文件副本目录（Q1 五轮问题2：字节直发的文件[贴纸/粘贴图片/
  /// 标注图]落盘副本，供文件管理页回看；路径直发的文件不复制，仅记映射）
  static String get sentFilesDir => _resolve('sent_files');

  /// 自定义表情包落盘目录（原 config.dart stickerStoreDir 调用点统一改走此 getter）
  static String get stickerStoreDir => _resolve(AppConfig.stickerStoreDir);

  /// 导出文件目录（Q1 真机反馈：聊天记录/审计日志导出在移动端直接
  /// 落盘到此目录——FilePicker.saveFile 在移动端不可用导致"点击无
  /// 反应"）。Android 为外部存储应用专属目录（文件管理器可见），
  /// 其余平台为文档目录；Linux（恒 FilePicker 另存，不消费此目录）
  /// 与未初始化场景回退 CWD 相对 'exports'（兼容值语义）。
  static String get exportsDir {
    final root = _exportsRootDir;
    if (root == null) return 'exports';
    return '$root/exports';
  }

  static String _resolve(String subdir) {
    final docs = _documentsDir;
    if (docs == null) return subdir;
    return '$docs/$subdir';
  }

  static void resetForTest() {
    _initialized = false;
    _documentsDir = null;
    _exportsRootDir = null;
    documentsDirResolver = null;
    exportsDirResolver = null;
  }
}
