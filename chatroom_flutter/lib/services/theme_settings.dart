/// 主题设置（阶段 O7：P2-9 字体大小/聊天背景/自定义主题色）
///
/// 设置页集中管理：深色模式（跟随系统/浅色/深色）、字体大小缩放、
/// 主题色种子、聊天背景色。持久化到 shared_preferences：
///   theme_font_scale(double) / theme_color(int) / chat_background(int? 可缺省) /
///   theme_mode(string: system|light|dark)
///
/// 默认值即应用现状（品牌蓝 0xFF2563EB / 跟随系统 / 无背景 / 1.0 倍），
/// 不做任何设置时渲染与既有版本一致。ChatroomApp（main.dart）监听本单例。

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 深色模式选项
enum AppThemeMode { system, light, dark }

/// 界面语言选项（阶段 P6：多语言界面）。
/// 默认 zh——不做任何设置时全部界面中文（既有渲染零回归）。
enum AppLocale { zh, en, system }

class ThemeSettings extends ChangeNotifier {
  ThemeSettings._();

  static final ThemeSettings instance = ThemeSettings._();

  static const double _minScale = 0.8;
  static const double _maxScale = 1.5;

  static const String _kFontScale = 'theme_font_scale';
  static const String _kThemeColor = 'theme_color';
  static const String _kChatBackground = 'chat_background';
  static const String _kThemeMode = 'theme_mode';
  static const String _kLocale = 'locale';

  /// 主题色色板（设置页色板；首个为既有品牌蓝）
  static const List<int> presetColors = [
    0xFF2563EB,
    0xFF059669,
    0xFF7C3AED,
    0xFFEA580C,
    0xFFDB2777,
  ];

  /// 聊天背景色板（首项 null = 无背景）
  static const List<int?> presetBackgrounds = [
    null,
    0xFFF3F4F6,
    0xFFEEF2FF,
    0xFFECFDF5,
  ];

  double _fontScale = 1.0;
  int _themeColor = 0xFF2563EB;
  int? _chatBackground;
  AppThemeMode _mode = AppThemeMode.system;
  AppLocale _locale = AppLocale.zh;

  /// 待落盘写队列：setter 只入队（同步、无 zone 依赖），由 _drain 在
  /// **当前调用方 zone** 逐条落盘。直接 await 跨 zone 的写 future 会因
  /// widget 测试的 FakeAsync zone 销毁而永不完成（load 挂死），故 load
  /// 需在自身 zone 内重新清空队列后再读存储。
  /// 入队时即捕获完整键名（含当时的前缀）——bindUser 切换前缀后，
  /// 在途写仍落回原账号键（2026-08-30 用户反馈 #9）。
  final List<Map<String, Object?>> _pendingWrites = [];

  /// 当前绑定的账号（2026-08-30 用户反馈 #9：设置与账号绑定）。
  /// null = 未登录（登录页），使用全局默认键。
  String _user = '';

  String _key(String base) => _user.isEmpty ? base : '$_user.$base';

  /// 全局文本缩放（0.8 ~ 1.5）
  double get fontScale => _fontScale;
  set fontScale(double value) {
    _fontScale = value.clamp(_minScale, _maxScale);
    notifyListeners();
    _pendingWrites.add({
      'key': _key(_kFontScale),
      'fontScale': _fontScale,
    });
    _drain();
  }

  /// 主题色种子（Material 3 ColorScheme.fromSeed）
  int get themeColor => _themeColor;
  set themeColor(int value) {
    _themeColor = value;
    notifyListeners();
    _pendingWrites.add({'key': _key(_kThemeColor), 'themeColor': value});
    _drain();
  }

  /// 聊天背景色（null = 无背景）
  int? get chatBackground => _chatBackground;
  set chatBackground(int? value) {
    _chatBackground = value;
    notifyListeners();
    _pendingWrites
        .add({'key': _key(_kChatBackground), 'chatBackground': value});
    _drain();
  }

  /// 深色模式
  AppThemeMode get mode => _mode;
  set mode(AppThemeMode value) {
    _mode = value;
    notifyListeners();
    _pendingWrites.add({'key': _key(_kThemeMode), 'mode': value});
    _drain();
  }

  /// 界面语言（阶段 P6，账号绑定键 `<user>.locale`）
  AppLocale get locale => _locale;
  set locale(AppLocale value) {
    _locale = value;
    notifyListeners();
    _pendingWrites.add({'key': _key(_kLocale), 'locale': value});
    _drain();
  }

  /// 清空写队列（幂等；条目入队时已捕获完整键名）
  Future<void> _drain() async {
    while (_pendingWrites.isNotEmpty) {
      final w = _pendingWrites.removeAt(0);
      final prefs = await SharedPreferences.getInstance();
      final key = w['key'] as String;
      final fontScale = w['fontScale'] as double?;
      if (fontScale != null) {
        await prefs.setDouble(key, fontScale);
      }
      final themeColor = w['themeColor'] as int?;
      if (themeColor != null) {
        await prefs.setInt(key, themeColor);
      }
      if (w.containsKey('chatBackground')) {
        final bg = w['chatBackground'] as int?;
        if (bg == null) {
          await prefs.remove(key);
        } else {
          await prefs.setInt(key, bg);
        }
      }
      final mode = w['mode'];
      if (mode != null) {
        await prefs.setString(key, (mode as AppThemeMode).name);
      }
      final locale = w['locale'];
      if (locale != null) {
        await prefs.setString(key, (locale as AppLocale).name);
      }
    }
  }

  double? _readDouble(SharedPreferences prefs, String key) {
    try {
      return prefs.getDouble(key);
    } catch (_) {
      return null;
    }
  }

  int? _readInt(SharedPreferences prefs, String key) {
    try {
      return prefs.getInt(key);
    } catch (_) {
      return null;
    }
  }

  String? _readString(SharedPreferences prefs, String key) {
    try {
      return prefs.getString(key);
    } catch (_) {
      return null;
    }
  }

  /// 全量重置后从 shared_preferences 读取（缺键/损坏数据 → 默认值，
  /// 不抛异常）。测试通过 setMockInitialValues + load() 即可获得确定状态。
  Future<void> load() async {
    // 先在当前 zone 清空待写队列（跨 zone 的旧写 future 不可等待）
    await _drain();
    _fontScale = 1.0;
    _themeColor = 0xFF2563EB;
    _chatBackground = null;
    _mode = AppThemeMode.system;
    _locale = AppLocale.zh;
    final prefs = await SharedPreferences.getInstance();
    final scale = _readDouble(prefs, _key(_kFontScale));
    if (scale != null) {
      _fontScale = scale.clamp(_minScale, _maxScale);
    }
    final color = _readInt(prefs, _key(_kThemeColor));
    if (color != null) _themeColor = color;
    _chatBackground = _readInt(prefs, _key(_kChatBackground));
    final mode = _readString(prefs, _key(_kThemeMode));
    switch (mode) {
      case 'light':
        _mode = AppThemeMode.light;
      case 'dark':
        _mode = AppThemeMode.dark;
      default:
        _mode = AppThemeMode.system;
    }
    final locale = _readString(prefs, _key(_kLocale));
    switch (locale) {
      case 'en':
        _locale = AppLocale.en;
      case 'system':
        _locale = AppLocale.system;
      default:
        _locale = AppLocale.zh;
    }
    notifyListeners();
  }

  /// 绑定账号（登录/登出时由 AppState 调用）：设置键切换为
  /// "<username>.<key>" 前缀并重新加载——每个账号独立主题设置；
  /// username 为 null（未登录/退出）时回退全局默认键。
  /// 存储不可用（异常环境）时静默保持默认值——登录/登出主流程不受影响。
  Future<void> bindUser(String? username) async {
    _user = username ?? '';
    try {
      await load();
    } catch (_) {
      // 读取失败：保持默认值
    }
  }
}
