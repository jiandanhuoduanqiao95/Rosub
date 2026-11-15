// opt9 批次 #3：Android 音频策略按设备分流 —— 策略矩阵 / Android 通道
// mock / 源码契约（MainActivity getAudioDeviceInfo、main 三档 options、
// call_engine 仍 audio:true 不带 bypass map）。
import 'dart:io';

import 'package:chatroom_flutter/platform/android_audio_policy.dart';
import 'package:chatroom_flutter/platform/android_system.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const MethodChannel platformChannel = MethodChannel('chatroom/platform');

AndroidAudioDeviceInfo info({
  String? manufacturer,
  String? brand,
  String? model,
  String? display,
}) =>
    AndroidAudioDeviceInfo(
      manufacturer: manufacturer,
      brand: brand,
      model: model,
      display: display,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('策略矩阵', () {
    test('vivo manufacturer → bypass', () {
      expect(resolveAndroidAudioProfile(info(manufacturer: 'vivo')),
          AndroidAudioProfile.bypass);
    });

    test('iQOO（大小写混合 brand）→ bypass', () {
      expect(resolveAndroidAudioProfile(info(brand: 'iQOO')),
          AndroidAudioProfile.bypass);
      expect(resolveAndroidAudioProfile(info(manufacturer: 'VIVO')),
          AndroidAudioProfile.bypass);
    });

    test('OriginOS display（非 vivo 厂商字段）→ bypass', () {
      expect(
          resolveAndroidAudioProfile(info(
              manufacturer: 'pd2426', display: 'OriginOS 5')),
          AndroidAudioProfile.bypass);
    });

    test('非 vivo 设备（Samsung/Google/OnePlus/Xiaomi）→ defaultProcessing',
        () {
      for (final m in ['samsung', 'google', 'OnePlus', 'Xiaomi']) {
        expect(resolveAndroidAudioProfile(info(manufacturer: m)),
            AndroidAudioProfile.defaultProcessing,
            reason: m);
      }
      expect(resolveAndroidAudioProfile(info()), 
          AndroidAudioProfile.defaultProcessing);
    });

    test('null 设备信息 → defaultProcessing', () {
      expect(resolveAndroidAudioProfile(null),
          AndroidAudioProfile.defaultProcessing);
    });

    test('override 优先于设备判定（三种取值）', () {
      final vivo = info(manufacturer: 'vivo');
      expect(resolveAndroidAudioProfile(vivo, override: 'default'),
          AndroidAudioProfile.defaultProcessing);
      expect(resolveAndroidAudioProfile(vivo, override: 'software'),
          AndroidAudioProfile.softwareApm);
      expect(resolveAndroidAudioProfile(vivo, override: 'bypass'),
          AndroidAudioProfile.bypass);
      expect(resolveAndroidAudioProfile(null, override: 'software'),
          AndroidAudioProfile.softwareApm);
    });

    test('override 大小写/空白容错', () {
      expect(resolveAndroidAudioProfile(null, override: '  BYPASS '),
          AndroidAudioProfile.bypass);
      expect(resolveAndroidAudioProfile(null, override: 'Software'),
          AndroidAudioProfile.softwareApm);
      expect(resolveAndroidAudioProfile(null, override: '\tDefault\n'),
          AndroidAudioProfile.defaultProcessing);
    });

    test('非法 override 忽略走设备判定', () {
      final vivo = info(manufacturer: 'vivo');
      expect(resolveAndroidAudioProfile(vivo, override: 'hardware'),
          AndroidAudioProfile.bypass);
      expect(resolveAndroidAudioProfile(info(manufacturer: 'google'),
          override: 'nonsense'), AndroidAudioProfile.defaultProcessing);
      expect(resolveAndroidAudioProfile(null, override: ''),
          AndroidAudioProfile.defaultProcessing);
    });

    test('fromMap 容错（缺字段/非字符串值/null）', () {
      final parsed = AndroidAudioDeviceInfo.fromMap({
        'manufacturer': 'vivo',
        'sdk': 34,
        'brand': null,
        'unknown_extra': 'ignored',
      });
      expect(parsed.manufacturer, 'vivo');
      expect(parsed.sdk, 34);
      expect(parsed.brand, isNull);
      expect(parsed.release, isNull);
      expect(parsed.isVivoFamily, isTrue);
      expect(parsed.summary(), contains('sdk=34'));
    });
  });

  group('AndroidSystem.getAudioDeviceInfo 通道', () {
    setUp(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platformChannel, null);
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platformChannel, null);
    });

    test('Android 通道返回 map → 解析为设备信息', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platformChannel, (call) async {
        expect(call.method, 'getAudioDeviceInfo');
        return <String, Object?>{
          'manufacturer': 'vivo',
          'brand': 'vivo',
          'model': 'V2426A',
          'sdk': 34,
        };
      });
      final info = await AndroidSystem.getAudioDeviceInfo();
      expect(info, isNotNull);
      expect(info!.manufacturer, 'vivo');
      expect(info.sdk, 34);
    });

    test('通道异常（MissingPluginException）→ null 安全降级', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platformChannel, (call) async {
        throw MissingPluginException();
      });
      expect(await AndroidSystem.getAudioDeviceInfo(), isNull);
    });

    test('通道返回 null → null', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platformChannel, (call) async => null);
      expect(await AndroidSystem.getAudioDeviceInfo(), isNull);
    });

    test('非 Android 平台 → null（不触通道）', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      var called = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platformChannel, (call) async {
        called = true;
        return <String, Object?>{};
      });
      expect(await AndroidSystem.getAudioDeviceInfo(), isNull);
      expect(called, isFalse);
    });
  });

  group('源码契约', () {
    String srcOf(String relPath) => File(relPath).readAsStringSync();

    test('MainActivity.kt 有 getAudioDeviceInfo（Build.* 八字段）', () {
      final src = srcOf(
          'android/app/src/main/kotlin/com/example/chatroom_flutter/'
          'MainActivity.kt');
      expect(src, contains('"getAudioDeviceInfo"'));
      for (final field in [
        'Build.MANUFACTURER', 'Build.BRAND', 'Build.MODEL', 'Build.DEVICE',
        'Build.PRODUCT', 'Build.DISPLAY', 'Build.VERSION.RELEASE',
        'Build.VERSION.SDK_INT',
      ]) {
        expect(src, contains(field), reason: field);
      }
    });

    test('main.dart 三档 options 全存在且经 resolveAndroidAudioProfile',
        () {
      final src = srcOf('lib/main.dart');
      expect(src, contains('resolveAndroidAudioProfile'));
      expect(src, contains('CHATROOM_ANDROID_AUDIO_PROFILE'));
      expect(src, contains("'androidUseHardwareAudioProcessing': true"));
      expect(src, contains("'androidUseHardwareAudioProcessing': false"));
      expect(src, contains("'bypassVoiceProcessing': true"));
      expect(src.indexOf('getAudioDeviceInfo'),
          lessThan(src.indexOf('WebRTC.initialize')),
          reason: '设备信息读取先于 WebRTC.initialize（r1s8 顺序契约）');
    });

    test('main.dart 仅 Android 分支初始化 WebRTC 选项', () {
      final src = srcOf('lib/main.dart');
      final androidBranch =
          src.substring(src.indexOf('if (Platform.isAndroid)'));
      expect(androidBranch, contains('WebRTC.initialize'));
      expect(androidBranch.split('WebRTC.initialize').length - 1, 1);
    });

    test('call_engine 采集仍为 audio:true（不改 audio map 语义）', () {
      final src = srcOf('lib/services/call_engine.dart');
      expect(src, contains("getUserMedia(\n      {'audio': true, 'video': video},\n    )"));
      expect(src.contains('bypassVoiceProcessing'), isFalse,
          reason: 'bypass 只经 main 初始化选项注入，不进采集参数');
    });

    test('vendored 插件 Java 未改动（git 工作树无 third_party 改动）', () {
      final result = Process.runSync('git', [
        'status',
        '--porcelain',
        '--',
        'third_party/flutter_webrtc/android/',
      ]);
      expect(result.stdout.toString().trim(), isEmpty,
          reason: '批次 #3 不改 vendored 插件 Java');
    });
  });
}
