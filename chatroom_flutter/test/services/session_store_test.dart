// ============================================================
// session_store.dart 单元测试（阶段 H3 —— Session 持久化）
// ============================================================
// 契约（已实现）：
//   StoredSession{ username, password }
//   SessionStore（shared_preferences 实现）：
//     - 存储键：session_username / session_password
//     - save(session)   ：写入用户名/密码；**不写** session_admin_secret，
//                         并清除旧版本残留的管理员密钥键（安全：密钥不落盘）
//     - load()          ：完整数据返回 StoredSession；键缺失/损坏返回 null
//     - clear()         ：删除全部键
//     - 覆盖保存：再次 save 替换旧值
//   安全约定：管理员密钥永不写入 shared_preferences。
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chatroom_flutter/services/session_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
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

    test('存储键名固定：session_username / session_password（无密钥键）',
        () async {
      await SessionStore.save(const StoredSession(
        username: 'alice',
        password: 'password123',
      ));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('session_username'), 'alice');
      expect(prefs.getString('session_password'), 'password123');
      expect(prefs.getString('session_admin_secret'), isNull);
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
