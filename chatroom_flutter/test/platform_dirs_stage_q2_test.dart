// ============================================================
// Windows runner 与构建结构锁定（阶段 Q2-1 —— 契约测试）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 Q「Q2 Windows」要点：
//
//   · **标准 runner**——windows/ 保持 flutter create 默认结构
//     （Win32Window / FlutterWindow / wWinMain），不引入 Linux 式
//     自研桥接层（my_application / GTK / persistent_ime 均为 Linux
//     专属，不得出现在 Windows 侧）；
//   · **linux/ runner 专属代码不参与 Windows 构建**——windows/ 的
//     CMake/源码不引用仓库内 linux/ 或 bridge/ 资源；Q2 分支纪律：
//     共享文件与基线资产（linux/ runner、bridge/ 桥接）不动；
//   · **§36.1 Windows 构建产物**——flutter build windows →
//     build/windows/x64/runner/Release/chatroom_flutter.exe
//     （BINARY_NAME 锁定；zip 绿色包分发）；
//   · **Windows 插件后端注册**——media_kit_video（P1 视频气泡）、
//     media_kit_libs_windows_video（mpv Windows 库）、
//     flutter_secure_storage_windows（L2 钥匙串）已入 generated_plugins；
//   · **彩色 emoji 字体随包**——NotoColorEmoji.ttf 资产声明保留
//     （R-P10/R-P26 契约全端不变，Windows 构建产物须含该字体）。
//
// 方法论（TESTING_GUIDE_FLUTTER.md §21.1）：原生层内容不做单测——本
// 文件只锁"关键文件存在 + 标准形态未破坏 + 无跨端污染"（源码/结构
// 扫描，仿 Q0-1 与 tests/test_stage_m_deploy.py 文件内容锁定惯例），
// 在 Linux 开发机即可全量执行；构建与运行行为归 TESTING_GUIDE.md
// §36.2 行走骨架冒烟（Windows 宿主执行）。
// ============================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// flutter test 的 CWD 即包根（chatroom_flutter），路径相对包根（§21.6 惯例）
String repoOf(String relPath) => File(relPath).readAsStringSync();

bool repoExists(String relPath) => File(relPath).existsSync();

int countOf(String source, String needle) => source.split(needle).length - 1;

/// windows/ 目录下全部文本类文件（.txt/.cmake/.cpp/.h/.rc/.manifest）
/// 排除 ephemeral/（flutter 工具生成的插件符号链接缓存，非仓库源码）
List<File> windowsTextFiles() {
  final dir = Directory('windows');
  final files = <File>[];
  const exts = {'.txt', '.cmake', '.cpp', '.h', '.rc', '.manifest'};
  void walk(Directory d) {
    for (final e in d.listSync(recursive: true)) {
      if (e is! File) continue;
      if (e.path.contains('/ephemeral/') || e.path.contains('\\ephemeral\\')) {
        continue;
      }
      if (exts.any((x) => e.path.toLowerCase().endsWith(x))) {
        files.add(e);
      }
    }
  }

  walk(dir);
  return files;
}

void main() {
  group('Q2-1 —— windows/ 平台目录关键文件存在（flutter create 标准产物）', () {
    test('CMake 工程文件齐全（根 CMakeLists + runner CMakeLists + flutter 生成层）', () {
      expect(repoExists('windows/CMakeLists.txt'), isTrue);
      expect(repoExists('windows/runner/CMakeLists.txt'), isTrue);
      expect(repoExists('windows/flutter/CMakeLists.txt'), isTrue);
      expect(repoExists('windows/flutter/generated_plugins.cmake'), isTrue);
    });

    test('runner 源码齐全（main / flutter_window / win32_window / utils / 资源）', () {
      expect(repoExists('windows/runner/main.cpp'), isTrue);
      expect(repoExists('windows/runner/flutter_window.cpp'), isTrue);
      expect(repoExists('windows/runner/flutter_window.h'), isTrue);
      expect(repoExists('windows/runner/win32_window.cpp'), isTrue);
      expect(repoExists('windows/runner/win32_window.h'), isTrue);
      expect(repoExists('windows/runner/utils.cpp'), isTrue);
      expect(repoExists('windows/runner/utils.h'), isTrue);
      expect(repoExists('windows/runner/Runner.rc'), isTrue);
      expect(repoExists('windows/runner/resource.h'), isTrue);
      expect(repoExists('windows/runner/runner.exe.manifest'), isTrue);
    });
  });

  group('Q2-1 —— 标准 runner 形态锁定（不引入自研桥接层）', () {
    test('main.cpp 为 flutter create 标准结构（wWinMain/DartProject/FlutterWindow）',
        () {
      final src = repoOf('windows/runner/main.cpp');
      expect(src.contains('wWinMain'), isTrue, reason: '标准 Win32 入口（非自研主循环）');
      expect(src.contains('DartProject'), isTrue,
          reason: '标准 flutter::DartProject 装配');
      expect(src.contains('FlutterWindow'), isTrue,
          reason: '标准 FlutterWindow 托管');
      expect(src.contains('SetQuitOnClose(true)'), isTrue,
          reason: '标准关闭即退出语义（窗口 X = 应用退出）');
    });

    test('默认窗口尺寸保持（1280x720，Q2 不做窗口管理改造）', () {
      final src = repoOf('windows/runner/main.cpp');
      expect(src.contains('1280, 720'), isTrue,
          reason: 'flutter create 默认尺寸；如后续调整须同步本契约与 §36 手动矩阵');
    });

    test('产物名 BINARY_NAME = chatroom_flutter（§36.1 产物路径锁定）', () {
      final src = repoOf('windows/CMakeLists.txt');
      expect(countOf(src, 'BINARY_NAME "chatroom_flutter"'), 1,
          reason: '构建产物 build/windows/x64/runner/Release/chatroom_flutter.exe');
    });

    test('Runner.rc 含应用名与图标资源（zip 绿色包可辨识）', () {
      final rc = repoOf('windows/runner/Runner.rc');
      expect(rc.contains('chatroom_flutter'), isTrue);
      final res = repoOf('windows/runner/resource.h');
      expect(res.contains('IDI_APP_ICON'), isTrue);
    });
  });

  group('Q2-1 —— linux/ runner 专属代码不参与 Windows 构建（跨端污染扫描）', () {
    test('windows/ 全部文本文件不含 Linux 专属符号（my_application/persistent_ime/GTK）', () {
      for (final f in windowsTextFiles()) {
        final src = f.readAsStringSync().toLowerCase();
        expect(src.contains('my_application'), isFalse,
            reason: '${f.path} 引用 Linux runner 专属 my_application');
        expect(src.contains('persistent_ime'), isFalse,
            reason: '${f.path} 引用 Linux IME 桥接进程 persistent_ime');
        expect(src.contains('gtk'), isFalse,
            reason: '${f.path} 引用 GTK（Linux 桌面专属栈）');
      }
    });

    test('windows/ 构建脚本不引用仓库内 linux/ 或 bridge/ 资源', () {
      for (final f in windowsTextFiles()) {
        final src = f.readAsStringSync();
        expect(src.contains('../linux'), isFalse,
            reason: '${f.path} 引用 ../linux（Linux runner 目录）');
        expect(src.contains('bridge/'), isFalse,
            reason: '${f.path} 引用 bridge/（GTK 桥接进程目录）');
      }
    });

    test('Linux 基线资产不被 Q2 波及（分支纪律：共享与基线不动）', () {
      expect(repoExists('linux/runner/my_application.cc'), isTrue,
          reason: 'H 阶段任务栏 urgency 契约载体，勿删');
      expect(repoExists('bridge/persistent_ime.py'), isTrue,
          reason: 'Linux IME 桥接进程本体，勿删');
    });
  });

  group('Q2-1 —— Windows 插件后端与全端资产', () {
    test('视频/钥匙串 Windows 后端已注册（generated_plugins.cmake）', () {
      final src = repoOf('windows/flutter/generated_plugins.cmake');
      expect(src.contains('media_kit_video'), isTrue,
          reason: 'P1 视频气泡 Windows 后端');
      expect(src.contains('media_kit_libs_windows_video'), isTrue,
          reason: 'mpv Windows 原生库（R-P20 升级链）');
      expect(src.contains('flutter_secure_storage_windows'), isTrue,
          reason: 'L2 密码钥匙串 Windows 后端（Credential Storage）');
    });

    test('彩色 emoji 字体随包（NotoColorEmoji.ttf 资产声明保留）', () {
      final src = repoOf('pubspec.yaml');
      expect(src.contains('assets/fonts/NotoColorEmoji.ttf'), isTrue,
          reason: 'R-P10/R-P26 契约全端不变：Windows 构建产物须含 COLRv1 彩色字体');
    });
  });
}
