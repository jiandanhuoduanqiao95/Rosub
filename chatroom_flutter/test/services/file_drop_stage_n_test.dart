import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/services/file_drop.dart';

/// 阶段 N3（P2-4 文件拖拽发送）：MethodChannel("chatroom/dnd") 参数解析契约。
///
/// 问题 3 定位结论（用户实测"文件拖拽完全失灵"）：
/// ① runner C 侧 fl_method_channel_new 传 nullptr codec → 断言失败，
///   拖拽通道从未建立（my_application.cc 修复，需重新编译）；
/// ② C 侧参数包 map {"files": [...]} 而 Dart 侧强转 List → TypeError。
/// 本测试锁定 Dart 侧对两种参数形态的容错解析。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('N3 —— 拖拽通道 files 方法解析', () {
    test('List 参数（runner 直传）→ 转发给处理器', () async {
      final paths = <List<String>>[];
      FileDrop.instance.ensureListening();
      FileDrop.instance.setOnFilesDropped(paths.add);
      addTearDown(() => FileDrop.instance.setOnFilesDropped(null));

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const codec = StandardMethodCodec();
      await messenger.handlePlatformMessage(
        'chatroom/dnd',
        codec.encodeMethodCall(
            const MethodCall('files', ['/a/1.png', '/b/2.png'])),
        (_) {},
      );
      expect(paths, [
        ['/a/1.png', '/b/2.png'],
      ]);
    });

    test('旧实现 map 参数形态（{"files": [...]}）同样解析', () async {
      final paths = <List<String>>[];
      FileDrop.instance.ensureListening();
      FileDrop.instance.setOnFilesDropped(paths.add);
      addTearDown(() => FileDrop.instance.setOnFilesDropped(null));

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const codec = StandardMethodCodec();
      await messenger.handlePlatformMessage(
        'chatroom/dnd',
        codec.encodeMethodCall(const MethodCall('files', {
          'files': ['/c/3.png'],
        })),
        (_) {},
      );
      expect(paths, [
        ['/c/3.png'],
      ]);
    });

    test('空列表 / 非 files 方法 → 不触发处理器', () async {
      final paths = <List<String>>[];
      FileDrop.instance.ensureListening();
      FileDrop.instance.setOnFilesDropped(paths.add);
      addTearDown(() => FileDrop.instance.setOnFilesDropped(null));

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const codec = StandardMethodCodec();
      await messenger.handlePlatformMessage(
        'chatroom/dnd',
        codec.encodeMethodCall(const MethodCall('files', <String>[])),
        (_) {},
      );
      await messenger.handlePlatformMessage(
        'chatroom/dnd',
        codec.encodeMethodCall(const MethodCall('other', <String>['x'])),
        (_) {},
      );
      expect(paths, isEmpty);
    });
  });
}
