/// 文件拖拽接收（阶段 N3：P2-4 文件拖拽发送）
///
/// Linux runner（my_application.cc）把拖入窗口的文件经 GTK drag 解析为
/// 本地路径列表，通过 MethodChannel("chatroom/dnd") 的 "files" 方法转发；
/// 本类把路径交给 ChatScreen 注册的处理器（走既有上传通道，复用 M8
/// 大文件分流——sendFile 依据文件大小自动选择直传/小文件路径）。
/// 仅桌面端生效；测试/其他平台无平台消息，监听器为空操作。
///
/// 阶段 Q0-3：本类 implements FileDropCapability，作为平台能力工厂
/// （platform/capabilities.dart）的 Linux 默认实现——GTK channel 逻辑
/// 零改动，仅纳入能力抽象分发。

import 'package:flutter/services.dart';

import '../platform/capabilities.dart';

class FileDrop implements FileDropCapability {
  FileDrop._();
  static final FileDrop instance = FileDrop._();

  static const MethodChannel _channel = MethodChannel('chatroom/dnd');
  ValueChanged<List<String>>? _onFilesDropped;

  @override
  bool get isSupported => true;

  /// 注册平台通道监听（幂等；ChatScreen 登录后调用）。
  @override
  void ensureListening() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'files') {
        // C 侧（runner）直接传路径 List；兼容旧实现包 map {"files": [...]}
        // 的形态，防止 runner 未重新编译时拖拽静默失效
        final raw = call.arguments;
        final list =
            raw is List ? raw : (raw is Map ? raw['files'] as List? : null);
        final files =
            list?.map((e) => e.toString()).toList() ?? const <String>[];
        if (files.isNotEmpty) {
          _onFilesDropped?.call(files);
        }
      }
      return null;
    });
  }

  /// 设置拖入文件处理器（ChatScreen 退出时置 null，防跨界面串扰）。
  @override
  void setOnFilesDropped(ValueChanged<List<String>>? handler) {
    _onFilesDropped = handler;
  }
}
