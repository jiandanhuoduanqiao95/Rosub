// ============================================================
// list_users 响应解析回归测试
// ============================================================
// 回归历史缺陷：server_admin_handler.py 曾用 DB 整数 0/1 直接发送
// is_admin 字段，导致 Dart 端 `item[2] == true` 比较 int 1 时永远
// 返回 false，"查看所有用户"列表里管理员不显示 [管理员] 标记。
// 修复后服务端用 bool(is_admin) 转换，JSON 序列化为 true/false。
//
// 本测试不启动服务端，直接构造"修复后"的 list_users 响应 JSON，
// 跑与 socket_service.dart:815-830 相同的解析断言，锁定行为。
// ============================================================

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('list_users 响应中 is_admin 为 JSON 布尔时，Dart 端 == true 正确判定', () {
    // 修复后服务端发送的 JSON：is_admin 字段为 true/false 而非 1/0
    const jsonFromServer =
        '[["admin",true,true],["alice",false,false],["bob",true,false]]';
    final List<dynamic> list = jsonDecode(jsonFromServer);

    final admins = <String>[];
    int onlineCount = 0;
    for (final item in list) {
      final uname = item[0]?.toString() ?? '?';
      final online = item[1] == true;
      final admin = item[2] == true;
      if (online) onlineCount++;
      if (admin) admins.add(uname);
    }

    // 修复后：admin 这一行应被识别为管理员
    expect(admins, contains('admin'));
    expect(admins.length, 1);
    expect(onlineCount, 2); // admin 与 bob 在线
    // 非管理员不被误判
    expect(admins, isNot(contains('alice')));
    expect(admins, isNot(contains('bob')));
  });

  test('list_users 响应中 is_admin 为 JSON 整数时，Dart 端 == true 失败（回归反例）', () {
    // 缺陷版本的 JSON：is_admin 字段为 1/0 整数（这是 bug 触发态）
    const buggyJsonFromServer = '[["admin",true,1],["alice",false,0]]';
    final List<dynamic> list = jsonDecode(buggyJsonFromServer);

    final admins = <String>[];
    for (final item in list) {
      final uname = item[0]?.toString() ?? '?';
      final admin = item[2] == true; // int 1 != true → false
      if (admin) admins.add(uname);
    }

    // 回归反例：bug 版本下 admin 不会被识别，列表为空
    expect(admins, isEmpty,
        reason: 'int is_admin 与 bool true 用 == 比较必然 false，'
            '正是历史缺陷的表现');
  });
}
