/// 界面多语言字典（阶段 P6：多语言界面）
///
/// 轻量 t() 查表方案：locale 缺省时按 ThemeSettings 当前语言解析；
/// 显式传 'zh'/'en' 直接查表；未知键返回键名本身（防御 fallback，
/// UI 不得出现空白）。第一批覆盖登录页与主界面代表键，逐步扩至全量
/// UI 字符串（RawTextField 自绘 hint 不在本批）。

import 'dart:ui' show Locale;

import 'package:flutter/widgets.dart' show WidgetsBinding;

import '../services/theme_settings.dart';

const Map<String, String> _zh = {
  'appTitle': '聊天室',
  'login': '登录',
  'register': '注册',
  'registerToCreate': '注册新账号',
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

const Map<String, String> _en = {
  'appTitle': 'Chatroom',
  'login': 'Login',
  'register': 'Register',
  'registerToCreate': 'Create an account',
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

/// 语言解析：显式 zh/en 优先；system 跟随平台（中文系 → zh，其余回退 en）
String resolveLocale(AppLocale setting, Locale platform) {
  switch (setting) {
    case AppLocale.zh:
      return 'zh';
    case AppLocale.en:
      return 'en';
    case AppLocale.system:
      return platform.languageCode.toLowerCase() == 'zh' ? 'zh' : 'en';
  }
}

Map<String, String> _dictFor(String lang) => lang == 'en' ? _en : _zh;

/// 取界面文案；locale 缺省取 ThemeSettings 当前语言
String t(String key, {String? locale}) {
  final lang = locale ??
      resolveLocale(
        ThemeSettings.instance.locale,
        WidgetsBinding.instance.platformDispatcher.locale,
      );
  return _dictFor(lang)[key] ?? key;
}
