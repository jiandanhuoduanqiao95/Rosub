/// 登录会话持久化（阶段 H3 记住我 + 阶段 L2 P1-23 密码改系统钥匙串 +
/// 阶段 O6 P2-10 多账号切换）
///
/// 阶段 L2（P1-23）：密码不再明文存于 shared_preferences，改存系统钥匙串
/// （flutter_secure_storage，Linux=libsecret / Windows=DPAPI / Android=Keystore）。
/// 存储键固定：session_username / session_password（钥匙串内）。
/// 阶段 O6（P2-10 多账号切换）：新增钥匙串键 session_accounts（JSON 数组
/// [{"username","password"}...]），家庭 PC 多人场景下登录页可列出已保存账号
/// 快速切换。退出登录改调 clearCurrent()——清当前凭据但保留账号列表。
/// 安全约定：
///   - **管理员密钥永不落盘**（session_admin_secret 键不写入，并清理旧版本
///     残留的该键）。密钥仅保存在内存（SocketService._saveCredentials）用于
///     断线重连，应用重启后必须由管理员手动重新输入。
///   - **旧版本明文凭据迁移**：首次 load/save 时，若 shared_preferences 仍存有
///     旧版明文（session_username/session_password），读取后迁移进钥匙串并
///     清除明文（明文不残留）。load() 优先读钥匙串，空则回退旧明文（兼容升级）。
///
/// 桌面（Linux）需 libsecret 钥匙串环境；测试通过 FlutterSecureStorage
/// 的 setMockInitialValues 注入内存后端。

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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

/// Session 存储（flutter_secure_storage 实现，阶段 L2；多账号列表阶段 O6）
class SessionStore {
  static const String _kUsername = 'session_username';
  static const String _kPassword = 'session_password';
  static const String _kAdminSecret = 'session_admin_secret';
  static const String _kAccounts = 'session_accounts';

  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  /// 读取已保存的会话；键缺失/损坏返回 null
  ///
  /// 优先读系统钥匙串（L2）；钥匙串为空时回退旧版本 shared_preferences 明文
  /// （兼容升级：读取后迁移进钥匙串并清除明文，不残留）。
  static Future<StoredSession?> load() async {
    final username = await _secure.read(key: _kUsername);
    final password = await _secure.read(key: _kPassword);
    if (username != null &&
        username.isNotEmpty &&
        password != null &&
        password.isNotEmpty) {
      // 已迁移完成：顺带清理 shared_preferences 明文残留（幂等）
      await _clearLegacyPlaintext();
      return StoredSession(username: username, password: password);
    }

    final legacy = await _loadLegacy();
    if (legacy != null) {
      // 旧版本明文 → 迁移进钥匙串后清除明文
      await _secure.write(key: _kUsername, value: legacy.username);
      await _secure.write(key: _kPassword, value: legacy.password);
      await _clearLegacyPlaintext();
      return legacy;
    }
    return null;
  }

  /// 保存会话（仅用户名/密码，存系统钥匙串）；同时清除遗留的管理员密钥键与
  /// 旧版本明文残留（安全：密码不落盘 shared_preferences、密钥不落盘）
  ///
  /// 注意：save() 仅写当前凭据，**不**自动加入账号列表（账号列表由
  /// saveAccount 管理）；登录成功保存账号走 saveAccount。
  static Future<void> save(StoredSession session) async {
    await _secure.write(key: _kUsername, value: session.username);
    await _secure.write(key: _kPassword, value: session.password);
    await _clearLegacyPlaintext();
  }

  /// 清除会话（幂等）：钥匙串 + 旧明文残留 + 账号列表一并清除
  static Future<void> clear() async {
    await _secure.delete(key: _kUsername);
    await _secure.delete(key: _kPassword);
    await _secure.delete(key: _kAccounts);
    await _clearLegacyPlaintext();
  }

  // ============================================================
  // 阶段 O6（P2-10）：多账号切换
  // ============================================================

  /// 读取已保存的账号列表；键缺失/损坏返回 []（不抛异常）
  static Future<List<StoredSession>> loadAccounts() async {
    final raw = await _secure.read(key: _kAccounts);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((e) => StoredSession(
                  username: (e['username'] ?? '').toString(),
                  password: (e['password'] ?? '').toString(),
                ))
            .where((s) => s.username.isNotEmpty)
            .toList();
      }
    } catch (_) {
      // 损坏数据 → 空列表
    }
    return [];
  }

  static Future<void> _writeAccounts(List<StoredSession> accounts) async {
    await _secure.write(
      key: _kAccounts,
      value: jsonEncode([
        for (final a in accounts)
          {'username': a.username, 'password': a.password}
      ]),
    );
  }

  /// 保存账号（O6）：按用户名 upsert（同名覆盖密码）并置为当前账号——
  /// 当前凭据键同步写入，load() 语义不变。登录成功保存账号走本方法。
  static Future<void> saveAccount(StoredSession session) async {
    final accounts = await loadAccounts();
    final others = accounts.where((a) => a.username != session.username);
    await _writeAccounts([session, ...others]);
    await save(session);
  }

  /// 移除账号（O6）：若移除的是当前账号则清除当前凭据键（load() 返回
  /// null）；列表清空时等价 clear()（连账号列表一并清除）。
  static Future<void> removeAccount(String username) async {
    final accounts = await loadAccounts();
    final remaining = accounts.where((a) => a.username != username).toList();
    if (remaining.length == accounts.length) return;
    if (remaining.isEmpty) {
      await clear();
      return;
    }
    await _writeAccounts(remaining);
    final current = await load();
    if (current?.username == username) {
      await clearCurrent();
    }
  }

  /// 切换当前账号（O6）：仅当该用户名在账号列表中才切换（写当前凭据键，
  /// load() 跟随）；不存在时不切换、不抛异常。
  static Future<void> setCurrentAccount(String username) async {
    final accounts = await loadAccounts();
    for (final account in accounts) {
      if (account.username == username) {
        await save(account);
        return;
      }
    }
  }

  /// 清除当前凭据（O6）：session_username / session_password 与旧明文残留
  /// 一并清除，但**保留账号列表**——退出登录改调本方法，回登录页可快速
  /// 切换其他账号。
  static Future<void> clearCurrent() async {
    await _secure.delete(key: _kUsername);
    await _secure.delete(key: _kPassword);
    await _clearLegacyPlaintext();
  }

  static Future<StoredSession?> _loadLegacy() async {
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString(_kUsername);
    final password = prefs.getString(_kPassword);
    if (username == null || username.isEmpty || password == null) {
      return null;
    }
    return StoredSession(username: username, password: password);
  }

  /// 清除旧版本明文残留（session_username / session_password /
  /// session_admin_secret），L2 后密码只存在于钥匙串
  static Future<void> _clearLegacyPlaintext() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kUsername);
    await prefs.remove(_kPassword);
    await prefs.remove(_kAdminSecret);
  }
}
