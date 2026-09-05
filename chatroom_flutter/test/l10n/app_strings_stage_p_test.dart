// ============================================================
// app_strings.dart / theme_settings.dart 阶段 P —— 多语言 i18n 契约
// （TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 P6（P-多语言界面，README
// 长期展望：Flutter i18n）：
//
//   AppLocale 枚举（theme_settings.dart，仿 AppThemeMode 惯例）：
//     enum AppLocale { zh, en, system }
//     **默认 zh（现状回归：不做任何设置时全部界面中文——既有全量
//     中文断言测试零回归）**
//
//   ThemeSettings 扩展（账号绑定键 '<user>.locale'，与 O7 一致）：
//     - locale getter/setter（setter notifyListeners + 持久化字符串
//       'zh'/'en'/'system'）
//     - load()：缺键 → zh；非法存储值 → zh（防御）
//
//   t(key, {String? locale})（lib/l10n/app_strings.dart）：
//     - locale 缺省 → ThemeSettings 当前解析语言
//     - 显式 locale（'zh'/'en'）→ 直接查表
//     - 未知键 → 返回键名本身（防御 fallback，UI 不得出现空白）
//
//   resolveLocale(AppLocale, Locale platform) → 'zh'/'en'：
//     - zh → 'zh'；en → 'en'
//     - system → 平台语言中文系 → 'zh'，否则 'en'（仅两种语言，
//       其余语言回退英文）
//
//   第一批锁定的代表键（字典契约，逐步扩至全量 UI 字符串）：
//     login/register/username/password/rememberMe/adminMode/
//     loginToContinue/logout/settings/send/sendFile/searchMessages/
//     selectChatToStart/inputHint/cancel/confirm/language
//
// 实现前：本文件引用尚未实现的 API，编译失败或用例红，属 TDD 红。
// 实现后：全部转绿。
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chatroom_flutter/l10n/app_strings.dart';
import 'package:chatroom_flutter/services/theme_settings.dart';

ThemeSettings get settings => ThemeSettings.instance;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('P6 —— t() 字典契约（代表键，中/英）', () {
    test('默认（zh）：代表键中文文案', () {
      const zh = {
        'login': '登录',
        'register': '注册',
        'username': '用户名',
        'password': '密码',
        'rememberMe': '记住我',
        'adminMode': '管理员模式',
        'loginToContinue': '登录以继续',
        'logout': '退出',
        'settings': '设置',
        'send': '发送',
        'sendFile': '发送文件',
        'searchMessages': '搜索消息',
        'selectChatToStart': '选择一个会话开始聊天',
        'inputHint': '输入消息，Enter 发送...',
        'cancel': '取消',
        'confirm': '确定',
        'language': '语言',
      };
      zh.forEach((key, value) {
        expect(t(key, locale: 'zh'), value, reason: '键 $key 中文文案');
      });
    });

    test('en：代表键英文文案（翻译表契约）', () {
      const en = {
        'login': 'Login',
        'register': 'Register',
        'username': 'Username',
        'password': 'Password',
        'rememberMe': 'Remember me',
        'adminMode': 'Admin mode',
        'loginToContinue': 'Sign in to continue',
        'logout': 'Logout',
        'settings': 'Settings',
        'send': 'Send',
        'sendFile': 'Send file',
        'searchMessages': 'Search messages',
        'selectChatToStart': 'Select a chat to start',
        'inputHint': 'Type a message, Enter to send',
        'cancel': 'Cancel',
        'confirm': 'OK',
        'language': 'Language',
      };
      en.forEach((key, value) {
        expect(t(key, locale: 'en'), value, reason: '键 $key 英文文案');
      });
    });

    test('未知键 → 返回键名本身（防御 fallback）', () {
      expect(t('no_such_key', locale: 'zh'), 'no_such_key');
      expect(t('no_such_key', locale: 'en'), 'no_such_key');
    });

    test('locale 缺省 → ThemeSettings 当前语言', () async {
      settings.locale = AppLocale.zh;
      expect(t('login'), '登录');
      settings.locale = AppLocale.en;
      expect(t('login'), 'Login', reason: 'setter 后缺省 locale 查表跟随');
    });
  });

  group('P6 —— resolveLocale 语言解析', () {
    test('显式 zh/en', () {
      expect(resolveLocale(AppLocale.zh, const Locale('en')), 'zh');
      expect(resolveLocale(AppLocale.en, const Locale('zh')), 'en');
    });

    test('system：跟随平台，中文系 → zh，其余 → en', () {
      expect(resolveLocale(AppLocale.system, const Locale('zh')), 'zh');
      expect(resolveLocale(AppLocale.system, const Locale('zh', 'TW')), 'zh');
      expect(resolveLocale(AppLocale.system, const Locale('en')), 'en');
      expect(resolveLocale(AppLocale.system, const Locale('ja')), 'en',
          reason: '不支持的语言回退英文');
    });
  });

  group('P6 —— ThemeSettings.locale 持久化（账号绑定）', () {
    test('默认 zh（现状回归：不做设置全中文）', () async {
      await settings.bindUser(null);
      expect(settings.locale, AppLocale.zh);
    });

    test('set en → 持久化字符串 en；load 读回', () async {
      await settings.bindUser(null);
      settings.locale = AppLocale.en;
      expect(settings.locale, AppLocale.en);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('locale'), 'en');

      await settings.bindUser(null);
      expect(settings.locale, AppLocale.en, reason: '重新 load 读回持久化值');
    });

    test("非法存储值（'fr'）→ 防御回退 zh", () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('locale', 'fr');
      await settings.bindUser(null);
      expect(settings.locale, AppLocale.zh, reason: '非法值回退默认 zh');
    });

    test('账号绑定：alice.locale=en 与 bob（默认 zh）互不影响', () async {
      await settings.bindUser('alice');
      settings.locale = AppLocale.en;
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('alice.locale'), 'en');

      await settings.bindUser('bob');
      expect(settings.locale, AppLocale.zh, reason: 'bob 未设置 → 默认 zh');

      await settings.bindUser('alice');
      expect(settings.locale, AppLocale.en, reason: 'alice 读回 en');
    });

    test('set 时通知监听者（ChatroomApp 据此全局重建）', () async {
      await settings.bindUser(null);
      var notified = 0;
      settings.addListener(() => notified++);
      settings.locale = AppLocale.en;
      expect(notified, 1);
    });
  });
}
