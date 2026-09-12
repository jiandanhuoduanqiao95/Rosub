/// 已发送文件本机路径映射（Q1 五轮问题2）
///
/// 问题：文件管理页按 `received_files/<safeName>` 判断"是否下载"——
/// 自己发送的文件不在接收目录，恒显示"文件尚未下载到本机"无法回看。
/// 方案：发送时记录 messageId → 本机路径，文件管理页按记录的
/// messageId 二次解析：
///   - sendFile（路径直发，含大文件分流）：记源路径（零复制）；
///   - sendFileBytes（字节直发：贴纸/粘贴图片/标注图）：字节落盘
///     AppPaths.sentFilesDir 副本后记路径（字节本无路径，回看需要
///     本机副本；实际均为小图片）。
///
/// 存储为 shared_preferences JSON（键 sent_file_paths），进程内缓存
/// 支持同步 pathOf（文件管理列表为同步构建）；上限 200 条 FIFO 淘汰。
/// 未 init（测试/早期）pathOf 返回 null、record 跳过——安全 no-op。

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class SentFileStore {
  SentFileStore._();

  static const String _kKey = 'sent_file_paths';
  static const int _maxEntries = 200;

  static Map<String, String>? _cache;

  /// 启动时加载缓存（main() 调用；失败静默——后续 pathOf 恒 null）
  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kKey);
      if (raw == null || raw.isEmpty) {
        _cache = {};
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        _cache = decoded.map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        );
      } else {
        _cache = {};
      }
    } catch (_) {
      _cache = {};
    }
  }

  /// 记录/覆盖一条映射（未 init 或参数空 → 安全跳过）
  static Future<void> record(String messageId, String path) async {
    if (messageId.isEmpty || path.isEmpty) return;
    final cache = _cache;
    if (cache == null) return;
    cache.remove(messageId);
    cache[messageId] = path;
    while (cache.length > _maxEntries) {
      cache.remove(cache.keys.first);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kKey, jsonEncode(cache));
    } catch (_) {}
  }

  /// 同步查询（文件管理列表同步构建）；未知 → null
  static String? pathOf(String messageId) => _cache?[messageId];

  /// 测试复位
  static void resetForTest() {
    _cache = null;
  }
}
