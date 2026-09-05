/// 快捷回复（常用语）本地存储（阶段 O4：P2-3）
///
/// 高频短语一键发送；常用语列表存 shared_preferences（键 `quick_replies`，
/// JSON 字符串数组），纯客户端改动（协议零改动）。输入框旁入口与面板
/// 见 dialogs.dart `showQuickReplyPanel`。

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class QuickReplyStore {
  QuickReplyStore._();

  /// 默认常用语（无存储数据/数据损坏时使用）
  static const List<String> defaultPhrases = [
    '收到',
    '好的',
    '谢谢',
    '稍等',
    '再见',
  ];

  static const String _kQuickReplies = 'quick_replies';

  /// 读取常用语列表；无存储数据或数据损坏（非法 JSON/类型漂移）时
  /// 回退默认列表（不抛异常）。保存过的空列表保持为空。
  static Future<List<String>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kQuickReplies);
    if (raw == null) {
      return List<String>.of(defaultPhrases);
    }
    final stored = _decode(raw);
    if (stored != null) return stored;
    return List<String>.of(defaultPhrases);
  }

  /// 读取**已存储**的原始列表（未保存过 → 空列表，不展开默认值）。
  /// add/remove 的去重与增删以此为准：用户自定义从存储列表出发，
  /// 避免新装用户添加与默认同词的短语时被"去重"吞掉。
  static Future<List<String>> _loadStored() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kQuickReplies);
    if (raw == null) return [];
    return _decode(raw) ?? [];
  }

  /// 解析存储的 JSON 数组；非法/类型漂移返回 null（由调用方决定回退策略）
  static List<String>? _decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList();
      }
    } catch (_) {
      // 损坏数据
    }
    return null;
  }

  /// 保存常用语列表（trim 短语并丢弃空白项）
  static Future<void> save(List<String> phrases) async {
    final cleaned =
        phrases.map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kQuickReplies, jsonEncode(cleaned));
  }

  /// 追加常用语（trim；空白忽略；已存在不重复添加）
  static Future<void> add(String phrase) async {
    final trimmed = phrase.trim();
    if (trimmed.isEmpty) return;
    final stored = await _loadStored();
    if (stored.contains(trimmed)) return;
    await save([...stored, trimmed]);
  }

  /// 移除常用语（不存在时不抛异常）
  static Future<void> remove(String phrase) async {
    final stored = await _loadStored();
    await save(stored.where((p) => p != phrase).toList());
  }
}
