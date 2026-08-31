// ============================================================
// session_store.dart 阶段 O —— O6 多账号切换契约（TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 O：
//   O6（P2-10 多账号切换）：家庭 PC 多人场景；记住我（H3）已有凭据回填
//   基础，加账号列表切换。纯客户端改动（协议零改动）。
//
// 契约：session_store.dart 扩展（钥匙串新键 session_accounts，
// JSON 数组 [{"username","password"}...]）：
//   static Future<List<StoredSession>> loadAccounts();  // 空/损坏 → []
//   static Future<void> saveAccount(StoredSession s);   // 按用户名 upsert + 置为当前
//   static Future<void> removeAccount(String username); // 移除；移除当前 → 清当前键；
//                                                       // 列表清空 → 等价 clear()
//   static Future<void> setCurrentAccount(String username); // 列表中存在才切换
//   static Future<void> clearCurrent();                 // 清当前凭据，**保留账号列表**
//   （退出登录改调 clearCurrent：回登录页可快速切换，账号列表不丢）
//
// 回归锁定：既有 load() / save() / clear() 语义不变——
//   save() 仅写当前凭据（**不**自动入列表，列表由 saveAccount 管理）；
//   load() 读当前凭据；clear() 全清（含账号列表）。
//
// 实现前：本文件引用尚未实现的方法，编译失败或用例红，属 TDD 红。
// 实现后：全部转绿。
// ============================================================

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/services/session_store.dart';

StoredSession s(String username, String password) =>
    StoredSession(username: username, password: password);

void main() {
  // SharedPreferences（旧明文清理路径）需要测试绑定（与 session_store_stage_l_test 一致）
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  group('O6 —— loadAccounts', () {
    test('无存储数据 → 空列表', () async {
      expect(await SessionStore.loadAccounts(), isEmpty);
    });

    test('损坏 JSON → 空列表（不抛异常）', () async {
      FlutterSecureStorage.setMockInitialValues({'session_accounts': '不是JSON'});
      expect(await SessionStore.loadAccounts(), isEmpty);
    });
  });

  group('O6 —— saveAccount / setCurrentAccount', () {
    test('saveAccount 入列表并置为当前（load() 返回该账号）', () async {
      await SessionStore.saveAccount(s('alice', 'pw1'));
      expect((await SessionStore.loadAccounts()).single.username, 'alice');
      final current = await SessionStore.load();
      expect(current?.username, 'alice');
      expect(current?.password, 'pw1');
    });

    test('多账号共存；最近保存的为当前', () async {
      await SessionStore.saveAccount(s('alice', 'pw1'));
      await SessionStore.saveAccount(s('bob', 'pw2'));
      final names =
          (await SessionStore.loadAccounts()).map((a) => a.username).toSet();
      expect(names, {'alice', 'bob'});
      expect((await SessionStore.load())?.username, 'bob');
    });

    test('同名账号 upsert（覆盖密码，不重复）', () async {
      await SessionStore.saveAccount(s('alice', 'old'));
      await SessionStore.saveAccount(s('alice', 'new'));
      final accounts = await SessionStore.loadAccounts();
      expect(accounts.length, 1);
      expect(accounts.single.password, 'new');
      expect((await SessionStore.load())?.password, 'new');
    });

    test('setCurrentAccount 切换当前（load() 跟随）', () async {
      await SessionStore.saveAccount(s('alice', 'pw1'));
      await SessionStore.saveAccount(s('bob', 'pw2'));
      await SessionStore.setCurrentAccount('alice');
      expect((await SessionStore.load())?.username, 'alice');
    });

    test('setCurrentAccount 不存在的用户名 → 不切换不抛异常', () async {
      await SessionStore.saveAccount(s('alice', 'pw1'));
      await SessionStore.setCurrentAccount('ghost');
      expect((await SessionStore.load())?.username, 'alice');
    });
  });

  group('O6 —— removeAccount', () {
    test('移除非当前账号：列表缩短、当前不变', () async {
      await SessionStore.saveAccount(s('alice', 'pw1'));
      await SessionStore.saveAccount(s('bob', 'pw2'));
      await SessionStore.setCurrentAccount('alice');

      await SessionStore.removeAccount('bob');
      final names =
          (await SessionStore.loadAccounts()).map((a) => a.username).toList();
      expect(names, ['alice']);
      expect((await SessionStore.load())?.username, 'alice');
    });

    test('移除当前账号：load() 返回 null，剩余账号保留', () async {
      await SessionStore.saveAccount(s('alice', 'pw1'));
      await SessionStore.saveAccount(s('bob', 'pw2'));
      await SessionStore.setCurrentAccount('alice');

      await SessionStore.removeAccount('alice');
      expect(await SessionStore.load(), isNull);
      final names =
          (await SessionStore.loadAccounts()).map((a) => a.username).toSet();
      expect(names, {'bob'});
    });

    test('移除最后一个账号 → 等价 clear（列表空、当前清）', () async {
      await SessionStore.saveAccount(s('alice', 'pw1'));
      await SessionStore.removeAccount('alice');
      expect(await SessionStore.loadAccounts(), isEmpty);
      expect(await SessionStore.load(), isNull);
    });
  });

  group('O6 —— clearCurrent / 回归锁定', () {
    test('clearCurrent 清当前凭据但保留账号列表（退出登录语义）', () async {
      await SessionStore.saveAccount(s('alice', 'pw1'));
      await SessionStore.saveAccount(s('bob', 'pw2'));
      await SessionStore.setCurrentAccount('alice');

      await SessionStore.clearCurrent();
      expect(await SessionStore.load(), isNull);
      final names =
          (await SessionStore.loadAccounts()).map((a) => a.username).toSet();
      expect(names, {'alice', 'bob'}, reason: '退出登录保留账号列表，可快速切换');
    });

    test('回归：save() 仅写当前凭据，不自动入账号列表', () async {
      await SessionStore.save(s('carol', 'pw3'));
      expect((await SessionStore.load())?.username, 'carol');
      expect(
        (await SessionStore.loadAccounts()).where((a) => a.username == 'carol'),
        isEmpty,
        reason: '账号列表由 saveAccount 管理（O6 登录成功改调 saveAccount）',
      );
    });

    test('回归：clear() 全清（含账号列表）', () async {
      await SessionStore.saveAccount(s('alice', 'pw1'));
      await SessionStore.clear();
      expect(await SessionStore.loadAccounts(), isEmpty);
      expect(await SessionStore.load(), isNull);
    });
  });
}
