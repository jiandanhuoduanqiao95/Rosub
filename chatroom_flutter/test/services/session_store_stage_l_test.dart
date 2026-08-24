// ============================================================
// session_store.dart 阶段 L —— 密码改系统钥匙串（L2，P1-23）
// ============================================================
// 依据《软件开发文档4.1.0.md》§11 阶段 L / §13.3 P1-23：
//   "shared_preferences 明文存密码是最大客户端安全隐患；flutter_secure_storage"
//
// 本文件为 TDD 契约（修复前预期红）：
//   公开 API 契约保持（StoredSession / SessionStore.save / load / clear）；
//   核心安全属性变更：
//     - 【红→绿】save 后密码**不再**明文存于 shared_preferences
//       （当前实现写入 session_password 明文键，断言 isNull 失败 = 红；
//        L2 实现改为写系统钥匙串后转绿）
//     - 【红→绿】旧版本明文键（session_username / session_password）在
//       save 后主动清除（迁移到钥匙串，明文不残留）
//     - 保持：管理员密钥永不落盘；clear 幂等；损坏数据返回 null；
//       save→load 往返一致；覆盖保存取新值
//
// 注意：本文件仅依赖 SessionStore 公开 API + SharedPreferences mock，
// 不引入 flutter_secure_storage（实现方在 L2 落地时添加依赖并在测试中
// 注入其 mock，见 TESTING_GUIDE_FLUTTER.md §16.3）。
// ============================================================

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chatroom_flutter/services/session_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // L2 后密码存系统钥匙串：注入内存 mock（实现后转绿所需）
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('L2 —— SessionStore 密码改系统钥匙串（P1-23）', () {
    test('【安全·红→绿】save 后密码不再明文存于 shared_preferences', () async {
      await SessionStore.save(const StoredSession(
        username: 'alice',
        password: 'password123',
      ));
      final prefs = await SharedPreferences.getInstance();
      // L2 契约：明文键必须被清除（密码只存在于系统钥匙串）
      expect(prefs.getString('session_password'), isNull,
          reason: 'L2 后密码不得明文落盘于 shared_preferences');
      expect(prefs.getString('session_username'), isNull,
          reason: 'L2 后用户名随密码一并迁移到钥匙串');
    });

    test('【迁移·红→绿】旧版明文键在 save 后被清除（不残留明文）', () async {
      // 模拟旧版本客户端残留的明文会话（shared_preferences）
      SharedPreferences.setMockInitialValues({
        'session_username': 'alice',
        'session_password': 'oldpassword',
      });
      await SessionStore.save(const StoredSession(
        username: 'alice',
        password: 'newpassword',
      ));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('session_username'), isNull,
          reason: '迁移后旧明文用户名键应被清除');
      expect(prefs.getString('session_password'), isNull,
          reason: '迁移后旧明文密码键应被清除');
    });

    test('【契约保持】save 后 load 往返一致（用户名/密码）', () async {
      await SessionStore.save(const StoredSession(
        username: 'alice',
        password: 'password123',
      ));
      final s = await SessionStore.load();
      expect(s, isNotNull);
      expect(s!.username, 'alice');
      expect(s.password, 'password123');
    });

    test('【契约保持】覆盖保存：再次 save 后 load 取新值', () async {
      await SessionStore.save(
          const StoredSession(username: 'alice', password: 'oldpass1'));
      await SessionStore.save(
          const StoredSession(username: 'alice', password: 'newpass1'));
      final s = await SessionStore.load();
      expect(s!.password, 'newpass1');
    });

    test('【安全·保持】管理员密钥永不落盘：save 后 session_admin_secret 键不存在', () async {
      SharedPreferences.setMockInitialValues({
        'session_admin_secret': 'legacy-secret',
      });
      await SessionStore.save(const StoredSession(
        username: 'admin2',
        password: 'adminpass123',
      ));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('session_admin_secret'), isNull);
      final s = await SessionStore.load();
      expect(s!.username, 'admin2');
    });

    test('【契约保持】损坏数据（有用户名无密码）→ load 返回 null 不崩溃', () async {
      SharedPreferences.setMockInitialValues({
        'session_username': 'alice',
        // 缺 session_password
      });
      expect(await SessionStore.load(), isNull);
    });

    test('【契约保持】clear 幂等且清除后 load 返回 null', () async {
      await SessionStore.save(
          const StoredSession(username: 'alice', password: 'password123'));
      await SessionStore.clear();
      await SessionStore.clear();
      expect(await SessionStore.load(), isNull);
    });

    test('【契约保持】中文/emoji/特殊字符密码往返无损', () async {
      await SessionStore.save(const StoredSession(
        username: 'alice',
        password: '密码🔐!@# 空格',
      ));
      final s = await SessionStore.load();
      expect(s!.password, '密码🔐!@# 空格');
    });
  });
}
