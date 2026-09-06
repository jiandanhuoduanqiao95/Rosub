// ============================================================
// 平台目录生成契约（阶段 Q0-1 —— TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 Q「Q0-1 平台目录生成」：
//
//   flutter create --platforms=android,windows,macos,ios . 补齐四个
//   平台目录（当前仅有 linux/），为 Q1 Android / Q2 Windows / Q3 macOS
//   / Q4 iPadOS 分期构建提供工程骨架。
//
//   锁定方式参照 Python 侧 tests/test_stage_m_deploy.py 惯例（deploy
//   文件存在性锁定）：以"关键文件存在性"锁定工程结构。原生层内容
//   （Gradle/CMake/Xcode 配置细节）不做 flutter test 单测——§21.1
//   方法论表：原生层归设备端 integration_test 子集（21.3）与手动矩阵
//   （TESTING_GUIDE.md §36.1 构建产物表 / §36.2 骨架冒烟）。
//
//   Linux 基线必须原样保留：linux/ runner（含 my_application.cc，
//   H 阶段 urgency 导出符号契约）与 bridge/persistent_ime.py（GTK
//   IME 桥接进程）——flutter create 不应触碰既有目录，回归锁定防误删。
//
//   平台判定入口（deviceId 六类别）见 socket_service_stage_l_test，
//   此处不重复；本文件只锁工程结构。
//
// 实现前：android/windows/macos/ios 目录缺失，用例红，属 TDD 红。
// 实现后：全部转绿。
// ============================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

bool fileExists(String path) => File(path).existsSync();

bool dirExists(String path) => Directory(path).existsSync();

/// 在 root 下递归查找文件名完全等于 name 的文件（忽略包路径层级差异——
/// flutter create 生成的 applicationId 路径因版本而异，如
/// android/app/src/main/kotlin/com/example/chatroom_flutter/MainActivity.kt）
bool anyFileNamed(String root, String name) {
  final dir = Directory(root);
  if (!dir.existsSync()) return false;
  for (final e in dir.listSync(recursive: true).whereType<File>()) {
    if (e.uri.pathSegments.last == name) return true;
  }
  return false;
}

void main() {
  group('Q0-1 —— android/ 平台目录（Q1 Android 构建骨架）', () {
    test('android/ 目录存在', () {
      expect(dirExists('android'), isTrue,
          reason: 'flutter create --platforms=android 未执行');
    });

    test('android 应用级构建文件存在', () {
      expect(anyFileNamed('android', 'build.gradle')
          .xor(anyFileNamed('android', 'build.gradle.kts')), isTrue,
          reason: 'android/app/build.gradle（Groovy 或 Kotlin DSL 均可）');
      expect(anyFileNamed('android', 'settings.gradle')
          .xor(anyFileNamed('android', 'settings.gradle.kts')), isTrue);
    });

    test('AndroidManifest.xml 存在', () {
      expect(anyFileNamed('android', 'AndroidManifest.xml'), isTrue);
    });

    test('MainActivity 入口存在（Kotlin 或 Java）', () {
      expect(anyFileNamed('android', 'MainActivity.kt')
          .xor(anyFileNamed('android', 'MainActivity.java')), isTrue);
    });
  });

  group('Q0-1 —— windows/ 平台目录（Q2 Windows 构建骨架）', () {
    test('windows/ 目录存在', () {
      expect(dirExists('windows'), isTrue);
    });

    test('CMake 工程与 runner 入口存在', () {
      expect(fileExists('windows/CMakeLists.txt'), isTrue);
      expect(fileExists('windows/runner/CMakeLists.txt'), isTrue);
      expect(fileExists('windows/runner/main.cpp'), isTrue);
      expect(fileExists('windows/runner/flutter_window.cpp'), isTrue);
    });
  });

  group('Q0-1 —— macos/ 平台目录（Q3 macOS 构建骨架）', () {
    test('macos/ 目录存在', () {
      expect(dirExists('macos'), isTrue);
    });

    test('Xcode 工程与 Runner 入口存在', () {
      expect(
          fileExists('macos/Runner.xcodeproj/project.pbxproj'), isTrue);
      expect(fileExists('macos/Runner/AppDelegate.swift'), isTrue);
      expect(fileExists('macos/Runner/Info.plist'), isTrue);
    });
  });

  group('Q0-1 —— ios/ 平台目录（Q4 iPadOS 构建骨架）', () {
    test('ios/ 目录存在', () {
      expect(dirExists('ios'), isTrue);
    });

    test('Xcode 工程与 Runner 入口存在', () {
      expect(fileExists('ios/Runner.xcodeproj/project.pbxproj'), isTrue);
      expect(fileExists('ios/Runner/AppDelegate.swift')
          .xor(fileExists('ios/Runner/AppDelegate.mm')), isTrue);
      expect(fileExists('ios/Runner/Info.plist'), isTrue);
    });
  });

  group('Q0-1 —— Linux 基线不受平台目录生成影响（回归锁定）', () {
    test('linux/ runner 完整保留（含 H 阶段 urgency 契约文件）', () {
      expect(fileExists('linux/CMakeLists.txt'), isTrue);
      expect(fileExists('linux/runner/main.cc'), isTrue);
      expect(fileExists('linux/runner/my_application.cc'), isTrue);
      expect(fileExists('linux/runner/my_application.h'), isTrue);
    });

    test('bridge/persistent_ime.py 保留（GTK IME 桥接脚本）', () {
      expect(fileExists('bridge/persistent_ime.py'), isTrue);
    });

    test('既有资产与字体注册不受影响', () {
      expect(fileExists('pubspec.yaml'), isTrue);
      expect(fileExists('assets/fonts/NotoColorEmoji.ttf'), isTrue);
    });
  });
}

extension on bool {
  bool xor(bool other) => this != other;
}
