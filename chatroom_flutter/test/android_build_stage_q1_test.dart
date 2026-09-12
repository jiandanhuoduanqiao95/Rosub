// ============================================================
// Android 工程与构建产物锁定（阶段 Q1-0 —— TDD，部分红）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 Q 分期表「Q1 Android」中
// 与构建产物相关的契约 + §36.1 构建产物表（APK 侧载前提）：
//
//   ① release APK 必须可联网 —— flutter create 生成的
//     android/app/src/main/AndroidManifest.xml 默认无 INTERNET 权限
//     （仅 debug/profile 有），侧载 release 包连不上服务端。Q1 须在
//     main manifest 显式声明 <uses-permission android:name=
//     "android.permission.INTERNET"/>。
//   ② debug/profile manifest 的既有 INTERNET 声明保留（Q0 生成基线
//     不回退）。
//   ③ 原生接线存在性锁定：MainActivity.kt 需实现 'chatroom/platform'
//     MethodChannel 的 openFile / isIgnoringBatteryOptimizations /
//     openBatteryOptimizationSettings 三个方法（Q1-2 文件打开与 Q1-4
//     电池白名单的 Dart 侧通道对端）。Kotlin 行为不做单测（§21.1
//     方法论表"原生层"），此处仅锁文件与通道/方法名存在性；真实行为
//     归设备端 integration_test（§21.3）与手动矩阵 §36.2。
//   ④ minSdk 配置行存在（§13.9 风险清单：minSdk 取 Flutter 默认与
//     media_kit 要求的较大者——具体取值由 Q1 骨架期核对，不锁字面值，
//     防止 Flutter 版本升级后误报）。
//   ⑤ 插件版本组合锁定载体：pubspec.lock 存在且登记 media_kit /
//     media_kit_video（§13.9 风险清单"版本组合在骨架期锁定"）。
//
//   arm64 release 优先（--target-platform android-arm64 或 gradle
//   abiFilters）属构建命令/构建配置选择，无法以文件内容稳定锁定，
//   归手动矩阵 §36.1/§36.2 核对，不做自动化断言。
//
// 实现前：①③ 红（权限未加、通道未实现）；②④⑤ 当前已绿（回归锁定）。
// 实现后：全部转绿。
// ============================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String mainManifestPath = 'android/app/src/main/AndroidManifest.xml';

/// 递归查找 android/app/src/main/kotlin 下的 MainActivity（kt/java）
File? findMainActivity() {
  final dir = Directory('android/app/src/main/kotlin');
  if (!dir.existsSync()) return null;
  for (final e in dir.listSync(recursive: true)) {
    if (e is File &&
        (e.path.endsWith('MainActivity.kt') ||
            e.path.endsWith('MainActivity.java'))) {
      return e;
    }
  }
  return null;
}

void main() {
  group('Q1-0 —— Android 构建产物与权限（APK 侧载前提）', () {
    test('main AndroidManifest 声明 INTERNET 权限（release APK 可联网）', () {
      final file = File(mainManifestPath);
      expect(file.existsSync(), isTrue,
          reason: 'android/app/src/main/AndroidManifest.xml 存在');
      expect(
        file.readAsStringSync().contains(
            '<uses-permission android:name="android.permission.INTERNET"'),
        isTrue,
        reason: 'flutter create 默认 main manifest 无 INTERNET——'
            'release 侧载包必须显式声明，否则无法连接服务端',
      );
    });

    test('debug/profile manifest 保留 INTERNET（Q0 生成基线不回退）', () {
      expect(
        File('android/app/src/debug/AndroidManifest.xml')
            .readAsStringSync()
            .contains('android.permission.INTERNET'),
        isTrue,
      );
      expect(
        File('android/app/src/profile/AndroidManifest.xml')
            .readAsStringSync()
            .contains('android.permission.INTERNET'),
        isTrue,
      );
    });

    test('MainActivity 实现 chatroom/platform 通道（openFile/电池白名单方法名）', () {
      final main = findMainActivity();
      expect(main, isNotNull, reason: 'android/app/src/main/kotlin 下存在入口');
      final src = main!.readAsStringSync();
      expect(src.contains('chatroom/platform'), isTrue,
          reason: "Dart 侧契约通道名 MethodChannel('chatroom/platform')");
      expect(src.contains('openFile'), isTrue,
          reason: '文件打开（Q1-2 AndroidFileLauncher 对端）');
      expect(src.contains('isIgnoringBatteryOptimizations'), isTrue,
          reason: '电池优化白名单查询（Q1-4 对端）');
      expect(src.contains('openBatteryOptimizationSettings'), isTrue,
          reason: '跳转电池优化设置（Q1-4 对端）');
    });

    test('app/build.gradle.kts 保留 minSdk 配置（取值骨架期核对，不锁字面值）', () {
      final src = File('android/app/build.gradle.kts').readAsStringSync();
      expect(src.contains('minSdk'), isTrue,
          reason: 'minSdk = max(Flutter 默认, media_kit 要求) 由 Q1 骨架期核对');
    });

    test('pubspec.lock 登记媒体插件版本组合（锁定载体）', () {
      final file = File('pubspec.lock');
      expect(file.existsSync(), isTrue, reason: 'pubspec.lock 随仓库提交');
      final src = file.readAsStringSync();
      expect(src.contains('media_kit'), isTrue);
      expect(src.contains('media_kit_video'), isTrue);
    });
  });
}
