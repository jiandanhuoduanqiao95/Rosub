// ============================================================
// theme_settings.dart 阶段 O —— O7 字体/背景/主题契约（TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 O：
//   O7（P2-9 字体大小/聊天背景/自定义主题色）：设置页集中管理。
//   新增 lib/services/theme_settings.dart：
//
//   enum AppThemeMode { system, light, dark }
//
//   class ThemeSettings extends ChangeNotifier {
//     static final ThemeSettings instance;          // 全局单例
//     double fontScale;                             // 默认 1.0；写入 clamp 0.8~1.5
//     int themeColor;                               // 默认 0xFF2563EB（既有品牌蓝）
//     int? chatBackground;                          // 默认 null（无背景）
//     AppThemeMode mode;                            // 默认 system
//     static const List<int> presetColors;          // 主题色色板（≥4 色）
//     static const List<int?> presetBackgrounds;    // 背景色板（首项 null = 无背景）
//     Future<void> load();                          // 全量重置后读 shared_preferences
//   }
//
//   - 属性赋值即持久化（shared_preferences：theme_font_scale / theme_color /
//     chat_background / theme_mode）并 notifyListeners
//   - load() 为"全量重置再读取"：缺键 → 默认值；损坏数据 → 默认值（不抛异常）
//   - ChatroomApp（main.dart）监听 ThemeSettings：themeMode 映射、主题色 seed、
//     builder 应用 fontScale（MediaQuery.textScalerOf 全局生效）
//
// 实现前：本文件引用尚未实现的类/字段，编译失败或用例红，属 TDD 红。
// 实现后：全部转绿。
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chatroom_flutter/main.dart';
import 'package:chatroom_flutter/screens/login_screen.dart';
import 'package:chatroom_flutter/services/theme_settings.dart';

ThemeSettings get settings => ThemeSettings.instance;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('O7 —— ThemeSettings 默认值', () {
    test('默认：fontScale=1.0 / 品牌蓝 / 无背景 / 跟随系统', () async {
      await settings.load();
      expect(settings.fontScale, 1.0);
      expect(settings.themeColor, 0xFF2563EB);
      expect(settings.chatBackground, isNull);
      expect(settings.mode, AppThemeMode.system);
    });

    test('无存储数据 load() 后仍为默认值', () async {
      await settings.load();
      expect(settings.mode, AppThemeMode.system);
      expect(settings.chatBackground, isNull);
    });

    test('损坏数据回退默认（不抛异常）', () async {
      SharedPreferences.setMockInitialValues({
        'theme_font_scale': 'abc',
        'theme_mode': '未知模式',
        'chat_background': 'not-int',
      });
      await settings.load();
      expect(settings.fontScale, 1.0);
      expect(settings.mode, AppThemeMode.system);
      expect(settings.chatBackground, isNull);
    });

    test('色板常量：主题色 ≥4 色；背景色板首项为 null（无背景）', () {
      expect(ThemeSettings.presetColors.length, greaterThanOrEqualTo(4));
      expect(ThemeSettings.presetBackgrounds.first, isNull);
      expect(ThemeSettings.presetBackgrounds.length, greaterThanOrEqualTo(3));
    });
  });

  group('O7 —— 属性赋值：持久化 + 通知 + 约束', () {
    test('fontScale 写入 clamp 到 0.8~1.5 并通知', () async {
      await settings.load();
      var notified = 0;
      settings.addListener(() => notified++);

      settings.fontScale = 3.0;
      expect(settings.fontScale, 1.5, reason: '上限 1.5');
      settings.fontScale = 0.1;
      expect(settings.fontScale, 0.8, reason: '下限 0.8');
      expect(notified, greaterThanOrEqualTo(2));
    });

    test('mode 赋值持久化（load 往返保持）', () async {
      await settings.load();
      settings.mode = AppThemeMode.dark;
      await settings.load();
      expect(settings.mode, AppThemeMode.dark);
    });

    test('themeColor / chatBackground 赋值持久化', () async {
      await settings.load();
      settings.themeColor = 0xFF059669;
      settings.chatBackground = 0xFFF3F4F6;
      await settings.load();
      expect(settings.themeColor, 0xFF059669);
      expect(settings.chatBackground, 0xFFF3F4F6);
    });

    test('chatBackground 可置回 null（无背景）并持久化', () async {
      await settings.load();
      settings.chatBackground = 0xFFEEEEEE;
      await settings.load();
      expect(settings.chatBackground, isNotNull);
      // 置 null 需显式移除存储键；契约：load 后仍为 null
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('chat_background');
      await settings.load();
      expect(settings.chatBackground, isNull);
    });
  });

  group('O7 —— ChatroomApp 应用主题设置', () {
    testWidgets('深色模式 + 字体缩放全局生效', (tester) async {
      SharedPreferences.setMockInitialValues({
        'theme_mode': 'dark',
        'theme_font_scale': 1.3,
      });
      await settings.load();
      await tester.pumpWidget(const ChatroomApp());
      await tester.pump();

      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.themeMode, ThemeMode.dark, reason: 'theme_mode=dark → 深色');
      expect(app.theme!.colorScheme.brightness, Brightness.dark);
      expect(app.darkTheme, isNotNull);

      final ctx = tester.element(find.byType(LoginScreen));
      expect(MediaQuery.textScalerOf(ctx).scale(10.0), closeTo(13.0, 0.01),
          reason: 'fontScale=1.3 → 文本缩放 1.3 倍');
    });

    testWidgets('system 模式映射 ThemeMode.system（默认回归）', (tester) async {
      await settings.load();
      await tester.pumpWidget(const ChatroomApp());
      await tester.pump();

      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.themeMode, ThemeMode.system);
    });

    testWidgets('自定义主题色 + 聊天背景下应用不崩溃', (tester) async {
      await settings.load();
      settings.themeColor = 0xFF7C3AED;
      settings.chatBackground = 0xFFEEF2FF;
      await tester.pumpWidget(const ChatroomApp());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('O7 补充（用户反馈 #9）—— 设置与账号绑定', () {
    test('bindUser 后键带用户名前缀，账号间互不影响', () async {
      SharedPreferences.setMockInitialValues({
        'alice.theme_mode': 'dark',
        'bob.theme_mode': 'light',
      });
      await settings.bindUser('alice');
      expect(settings.mode, AppThemeMode.dark);
      await settings.bindUser('bob');
      expect(settings.mode, AppThemeMode.light);
    });

    test('绑定账号的修改写入该账号前缀键（持久化隔离）', () async {
      await settings.bindUser('alice');
      settings.themeColor = 0xFF059669;
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('alice.theme_color'), 0xFF059669);
      expect(prefs.getInt('theme_color'), isNull, reason: '不污染全局默认键');
    });

    test('登出（bindUser null）回退全局默认键', () async {
      await settings.bindUser('alice');
      settings.mode = AppThemeMode.dark;
      await settings.bindUser(null);
      expect(settings.mode, AppThemeMode.system);
    });
  });
}
