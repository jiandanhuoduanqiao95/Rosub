// ============================================================
// Windows 存储路径 / 设备标识 / 缓存后端契约（阶段 Q2-5）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 Q「Q2 Windows」的落盘与
// 多端语义前提，及 TESTING_GUIDE.md §36.2 骨架清单 #6（多端语义）：
//
//   1. **device_id = windows**（阶段 L 互踢语义）：Windows 构建登录时
//      携带 'windows' 类别——两台 Windows 同账号互踢、与 Linux/macOS/
//      Android 并存。deviceId 维持 dart:io Platform 判定（Q0 维护注意
//      ①：勿改 effectiveTargetPlatform——多端互踢语义独立于 widget
//      平台模拟），本组以源码扫描锁定映射与三处 login/register/
//      _relogin 头携带；
//   2. **存储路径 Windows 形态**（Q0-4 的 Windows 视角回归锁）：
//      AppPaths 经 path_provider 文档目录 → <docs>/received_files、
//      <docs>/stickers；resolver 异常回退兼容值；
//   3. **接收文件目录自动创建**：Windows 文档目录下首收文件时
//      createSync(recursive) 建目录（_prepareReceiveTarget/
//      _saveReceivedFile 既有职责，勿在 Q2 重构中丢失）；
//   4. **本地消息缓存 FFI 后端含 Windows**（L3 前提）：sqflite 无
//      Windows 原生插件，message_cache_store 的 FFI 后端选择必须
//      包含 Platform.isWindows——重构丢失 = Windows 缓存静默失效；
//   5. **构建标识递增**（R-P27 口诀）：Q2 实现 buildStamp='q2r1' 起递增，
//      登录页页脚/启动日志可辨"谁在跑旧构建"。
//
// 全部用例可在 Linux 开发机执行（纯逻辑 + 源码扫描，§21.1 方法论表）。
// ============================================================

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/config.dart';
import 'package:chatroom_flutter/services/app_paths.dart';

String srcOf(String relPath) => File(relPath).readAsStringSync();

int countOf(String source, String needle) => source.split(needle).length - 1;

void main() {
  setUp(() {
    AppPaths.resetForTest();
    debugDefaultTargetPlatformOverride = null;
  });
  tearDown(() {
    AppPaths.resetForTest();
    debugDefaultTargetPlatformOverride = null;
  });

  group('Q2-5 —— device_id 平台映射（阶段 L 互踢语义，Windows 类别）', () {
    test('deviceId 映射含 windows 分支（源码锁定，勿改随机生成）', () {
      final src = srcOf('lib/services/socket_service.dart');
      expect(src.contains("if (Platform.isWindows) return 'windows';"), isTrue,
          reason: 'Windows 构建登录携带 windows 类别——同类别互踢/异类别并存（§36.2 #6）');
      expect(src.contains('SharedPreferences'), isFalse,
          reason: 'deviceId 为平台常量（阶段 L 实测缺陷：随机生成+shared_preferences '
              '持久化会破坏同类互踢）——不得引入 SharedPreferences 实现');
    });

    test('device_id 头三处携带：login / register / _relogin', () {
      final src = srcOf('lib/services/socket_service.dart');
      expect(countOf(src, "extraHeaders['device_id'] = deviceId"), 3,
          reason: '重连缺失 device_id 会漂移为 default，误踢 tkinter 等会话（阶段 L 维护注意②）');
    });
  });

  group('Q2-5 —— 存储路径 Windows 形态（Q0-4 的 Windows 视角）', () {
    test('ensureInitialized 后 receivedFilesDir/stickerStoreDir 落文档目录',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      AppPaths.documentsDirResolver = () async => r'C:\Users\tester\Documents';
      await AppPaths.ensureInitialized();
      expect(AppPaths.receivedFilesDir,
          r'C:\Users\tester\Documents/received_files',
          reason: '<docs>/received_files（子目录名保留，数据可辨识）');
      expect(AppPaths.stickerStoreDir, r'C:\Users\tester\Documents/stickers',
          reason: '<docs>/stickers（R-P11 注入点经 AppPaths）');
    });

    test('resolver 异常回退兼容值（path_provider 异常降级惯例）', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      AppPaths.documentsDirResolver = () async => throw StateError('no plugin');
      await AppPaths.ensureInitialized();
      expect(AppPaths.receivedFilesDir, AppConfig.receivedFilesDir,
          reason: '文档目录解析失败静默回退 CWD 相对兼容值（不抛异常）');
      expect(AppPaths.stickerStoreDir, AppConfig.stickerStoreDir);
    });

    test('接收文件目录自动创建职责保留（Windows 文档目录首收建目录）', () {
      final src = srcOf('lib/services/socket_service.dart');
      expect(countOf(src, 'Directory(AppPaths.receivedFilesDir)'),
          greaterThanOrEqualTo(2),
          reason: '_prepareReceiveTarget / _saveReceivedFile 经 AppPaths 取目录');
      expect(
          countOf(src, 'createSync(recursive: true)'), greaterThanOrEqualTo(2),
          reason: '首收文件自动建目录（Windows 文档目录下 received_files 不会预存在）');
    });
  });

  group('Q2-5 —— 本地消息缓存与凭据的 Windows 后端（L2/L3 前提）', () {
    test('sqflite FFI 后端选择包含 Windows（缓存可用前提）', () {
      final src = srcOf('lib/services/message_cache_store.dart');
      expect(src.contains('Platform.isWindows'), isTrue,
          reason: 'sqflite 无 Windows 原生插件——FFI 后端必须覆盖 isWindows，'
              '重构丢失 = Windows 本地缓存静默失效');
    });

    test('凭据存取走 flutter_secure_storage（Windows Credential Storage 由插件承担）', () {
      final src = srcOf('lib/services/session_store.dart');
      expect(src.contains('FlutterSecureStorage'), isTrue,
          reason: 'H3 记住我 + L2 钥匙串：Windows 后端由 flutter_secure_storage_windows '
              '插件提供（generated_plugins 注册见 Q2-1），代码层平台无关');
    });
  });

  group('Q2-5 —— 构建标识递增（R-P27 多端排障口诀）', () {
    test("buildStamp = 'q2rN'（Q2 修订轮次标识，随轮次递增）", () {
      final src = srcOf('lib/config.dart');
      expect(RegExp("buildStamp = 'q2r\\d+'").hasMatch(src), isTrue,
          reason: '§36.1：每端构建后核对登录页"构建"标识与所测服务端代码轮次一致'
              '（q2r1 起递增，勿回退 q1rN/q0——多端排障先看构建标识）');
    });
  });
}
