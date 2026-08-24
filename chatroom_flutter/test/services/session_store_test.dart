// ============================================================
// session_store.dart 单元测试（阶段 H3 —— Session 持久化 + 阶段 L2 钥匙串）
// ============================================================
// 契约（阶段 L2，P1-23 修订）：
//   StoredSession{ username, password }
//   SessionStore（flutter_secure_storage 实现）：
//     - 存储键：session_username / session_password（**系统钥匙串内**）
//     - save(session)   ：写入钥匙串；**不写** session_admin_secret，
//                         并清除旧版本残留的管理员密钥键与旧明文（安全）
//     - load()          ：优先读钥匙串；钥匙串为空回退旧 shared_preferences
//                         明文并迁移清除；完整数据返回 StoredSession；否则 null
//     - clear()         ：删除钥匙串键 + 旧明文残留
//     - 覆盖保存：再次 save 替换旧值
//   安全约定：管理员密钥永不写入任何持久化；密码不落盘 shared_preferences。
// ============================================================

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chatroom_flutter/services/session_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('SessionStore（H3 持久化）', () {
    test('无任何已存数据 → load 返回 null', () async {
      expect(await SessionStore.load(), isNull);
    });

    test('save 后 load 往返一致（用户名/密码）', () async {
      await SessionStore.save(const StoredSession(
        username: 'alice',
        password: 'password123',
      ));
      final s = await SessionStore.load();
      expect(s, isNotNull);
      expect(s!.username, 'alice');
      expect(s.password, 'password123');
    });

    test('【安全】管理员密钥永不落盘：save 后 session_admin_secret 键不存在', () async {
      SharedPreferences.setMockInitialValues({
        'session_admin_secret': 'legacy-secret',
      });
      await SessionStore.save(const StoredSession(
        username: 'admin2',
        password: 'adminpass123',
      ));
      final prefs = await SharedPreferences.getInstance();
      // 旧版本残留的密钥键被主动清除
      expect(prefs.getString('session_admin_secret'), isNull);
      final s = await SessionStore.load();
      expect(s!.username, 'admin2');
    });

    test('clear 后 load 返回 null', () async {
      await SessionStore.save(
          const StoredSession(username: 'alice', password: 'password123'));
      await SessionStore.clear();
      expect(await SessionStore.load(), isNull);
    });

    test('覆盖保存：再次 save 后 load 取新值', () async {
      await SessionStore.save(
          const StoredSession(username: 'alice', password: 'oldpass1'));
      await SessionStore.save(
          const StoredSession(username: 'alice', password: 'newpass1'));
      final s = await SessionStore.load();
      expect(s!.password, 'newpass1');
    });

    test('损坏数据（有用户名无密码）→ load 返回 null 不崩溃', () async {
      SharedPreferences.setMockInitialValues({
        'session_username': 'alice',
        // 缺 session_password
      });
      expect(await SessionStore.load(), isNull);
    });

    test('【L2 安全】存储键只存在于钥匙串：save 后 shared_preferences 无明文键', () async {
      await SessionStore.save(const StoredSession(
        username: 'alice',
        password: 'password123',
      ));
      final prefs = await SharedPreferences.getInstance();
      // L2 契约：明文键必须被清除（密码/用户名只存在于系统钥匙串）
      expect(prefs.getString('session_username'), isNull);
      expect(prefs.getString('session_password'), isNull);
      expect(prefs.getString('session_admin_secret'), isNull);
      // 往返仍一致（钥匙串持有）
      final s = await SessionStore.load();
      expect(s!.username, 'alice');
      expect(s.password, 'password123');
    });

    test('中文/emoji/特殊字符密码往返无损', () async {
      await SessionStore.save(const StoredSession(
        username: 'alice',
        password: '密码🔐!@# 空格',
      ));
      final s = await SessionStore.load();
      expect(s!.password, '密码🔐!@# 空格');
    });

    test('clear 幂等：无数据时调用不抛异常', () async {
      await SessionStore.clear();
      await SessionStore.clear();
      expect(await SessionStore.load(), isNull);
    });
  });
}
