/// 登录会话持久化（阶段 H3，记住我）
///
/// 使用 shared_preferences 存储用户名/密码，供启动时自动回填（不自动登录）。
/// 安全约定：**管理员密钥永不落盘**（session_admin_secret 键不写入，并清理旧版本
/// 残留的该键）。密钥仅保存在内存（SocketService._saveCredentials）用于断线重连，
/// 应用重启后必须由管理员手动重新输入。

import 'package:shared_preferences/shared_preferences.dart';

/// 已保存的登录会话（仅用户名/密码；管理员密钥不持久化）
class StoredSession {
  final String username;
  final String password;

  const StoredSession({
    required this.username,
    required this.password,
  });
}

/// Session 存储（shared_preferences 实现）
///
/// 存储键固定：session_username / session_password。
/// session_admin_secret 为历史遗留键：save 时主动清除，避免旧版本残留。
class SessionStore {
  static const String _kUsername = 'session_username';
  static const String _kPassword = 'session_password';
  static const String _kAdminSecret = 'session_admin_secret';

  /// 读取已保存的会话；键缺失/损坏返回 null
  static Future<StoredSession?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString(_kUsername);
    final password = prefs.getString(_kPassword);
    if (username == null || username.isEmpty || password == null) {
      return null;
    }
    return StoredSession(
      username: username,
      password: password,
    );
  }

  /// 保存会话（仅用户名/密码）；同时清除遗留的管理员密钥键（安全：密钥不落盘）
  static Future<void> save(StoredSession session) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUsername, session.username);
    await prefs.setString(_kPassword, session.password);
    await prefs.remove(_kAdminSecret);
  }

  /// 清除会话（幂等）
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kUsername);
    await prefs.remove(_kPassword);
    await prefs.remove(_kAdminSecret);
  }
}
