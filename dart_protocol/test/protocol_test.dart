// ============================================================
// protocol.dart 的单元测试
// ============================================================
//
// 【测试目标】
//   protocol.dart 提供了 sendMessage() 和 recvMessage() 两个函数，
//   负责将消息编码为 TCP 字节流以及从字节流解码还原消息。
//
//   这个模块是整个项目的 '通信基石' —— 服务端和客户端所有数据交换
//   都依赖它。如果这里出了 bug，一切都会乱套。
//
// 【测试策略】
//   用 ServerSocket + Socket 创建一对已连接的 socket，
//   一端发送，另一端接收，验证编解码的正确性。
//   不需要真实网络连接，完全在本地回环中完成。
//
// 【与 Python 测试的对应关系】
//   本文件中的 15 个测试与 tests/test_protocol.py 逐一对齐，
//   确保 Dart 协议实现与 Python 版本行为 100% 一致。
//
// 【每个测试的结构】
//   test('描述', () async {
//       // 1. ARRANGE（准备）—— 创建 socket pair，准备测试数据
//       // 2. ACT（执行）—— 调用 sendMessage / recvMessage
//       // 3. ASSERT（断言）—— 验证结果是否符合预期
//   });
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_protocol/protocol.dart';
import 'package:test/test.dart';

// ============================================================
// 辅助函数
// ============================================================

/// 创建一对已经连通的 socket（模拟一条 TCP 连接）。
///
/// 通过启动临时 ServerSocket、连接、accept 来模拟 Python
/// socket.socketpair() 的行为。行为与真实 TCP socket 几乎一样：
/// - add() 发送数据
/// - listen() 接收数据
/// 而且是双向全双工的。
///
/// 返回 (client, server) 两个已连接的 Socket。
Future<(Socket, Socket)> makeSocketPair() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;

  // 并发连接和接受
  final clientFuture = Socket.connect(InternetAddress.loopbackIPv4, port);
  final serverSocket = await server.first;
  final client = await clientFuture;

  // 关闭监听 socket（已接受的连接不受影响）
  unawaited(server.close());

  return (client, serverSocket);
}

// ============================================================
// 第 1 组：sendMessage 发送测试
// ============================================================

void main() {
  group('TestSendMessage', () {
    // ---------------------------------------------------------
    // 【测试1】发送一条普通文本消息
    // ---------------------------------------------------------
    test('test_send_text_message', () async {
      // === ARRANGE ===
      final (s1, s2) = await makeSocketPair();
      final reader = MessageReader(s2);
      try {
        const msgType = 'chat';
        const content = 'Hello, World!';

        // === ACT ===
        await sendMessage(s1, msgType, content);

        // === ASSERT ===
        final (header, body) = await recvMessage(reader);

        expect(header, isNotNull);
        expect(body, isNotNull);
        expect(header!['type'], equals('chat'));
        expect(utf8.decode(body!), equals('Hello, World!'));
        expect(header['length'], equals(utf8.encode('Hello, World!').length));
      } finally {
        reader.close();
        s1.close();
        s2.close();
      }
    });

    // ---------------------------------------------------------
    // 【测试2】发送二进制数据（模拟文件传输）
    // ---------------------------------------------------------
    test('test_send_binary_message', () async {
      // === ARRANGE ===
      final (s1, s2) = await makeSocketPair();
      final reader = MessageReader(s2);
      try {
        // 构造包含所有可能字节值的二进制数据
        final binaryData = Uint8List.fromList(List.generate(256, (i) => i));

        // === ACT ===
        await sendMessage(s1, 'file', binaryData,
            extraHeaders: {'filename': 'test.bin', 'filesize': '256'});

        // === ASSERT ===
        final (header, body) = await recvMessage(reader);

        expect(header, isNotNull);
        expect(body, isNotNull);
        expect(header!['type'], equals('file'));
        expect(header['filename'], equals('test.bin'));
        expect(body, equals(binaryData));
        expect(body!.length, equals(256));
      } finally {
        reader.close();
        s1.close();
        s2.close();
      }
    });

    // ---------------------------------------------------------
    // 【测试3】发送带附加头的消息
    // ---------------------------------------------------------
    test('test_send_with_extra_headers', () async {
      // === ARRANGE ===
      final (s1, s2) = await makeSocketPair();
      final reader = MessageReader(s2);
      try {
        // === ACT ===
        await sendMessage(s1, 'chat', '你好', extraHeaders: {
          'to': 'alice',
          'message_id': 'abc-123',
          'group_id': 42, // 整数会被转为字符串
        });

        // === ASSERT ===
        final (header, body) = await recvMessage(reader);

        expect(header, isNotNull);
        expect(header!['to'], equals('alice'));
        expect(header['message_id'], equals('abc-123'));
        // 验证整数 42 被转为字符串 "42"（防御性转换）
        expect(header['group_id'], equals('42'));
      } finally {
        reader.close();
        s1.close();
        s2.close();
      }
    });

    // ---------------------------------------------------------
    // 【测试4】发送空消息（边界条件）
    // ---------------------------------------------------------
    test('test_send_empty_message', () async {
      // === ARRANGE ===
      final (s1, s2) = await makeSocketPair();
      final reader = MessageReader(s2);
      try {
        // === ACT ===
        await sendMessage(s1, 'chat', '');

        // === ASSERT ===
        final (header, body) = await recvMessage(reader);

        expect(header, isNotNull);
        expect(header!['type'], equals('chat'));
        expect(header['length'], equals(0));
        expect(body, isNotNull);
        expect(body!, isEmpty);
      } finally {
        reader.close();
        s1.close();
        s2.close();
      }
    });

    // ---------------------------------------------------------
    // 【测试5】发送大消息（触发分块传输）
    //
    // 解释：
    //   protocol.dart 默认使用 4MB chunk_size。
    //   这里故意用极小的 chunk_size=10 来验证分块逻辑的正确性。
    // ---------------------------------------------------------
    test('test_send_large_message_chunked', () async {
      // === ARRANGE ===
      final (s1, s2) = await makeSocketPair();
      final reader = MessageReader(s2);
      try {
        final content = 'A'.padRight(100, 'A'); // 100 字节，chunk=10 → 分成 10 块

        // === ACT ===
        await sendMessage(s1, 'chat', content, chunkSize: 10);

        // === ASSERT ===
        final (header, body) = await recvMessage(reader, chunkSize: 10);

        expect(body, isNotNull);
        expect(utf8.decode(body!), equals(content));
        expect(body.length, equals(100));
      } finally {
        reader.close();
        s1.close();
        s2.close();
      }
    });
  });

  // ============================================================
  // 第 2 组：recvMessage / recvall 接收测试
  // ============================================================

  group('TestRecvMessage', () {
    // ---------------------------------------------------------
    // 【测试6】接收大消息时，分块接收循环正确
    // ---------------------------------------------------------
    test('test_recv_large_message_chunked_receive', () async {
      // === ARRANGE ===
      final (s1, s2) = await makeSocketPair();
      final reader = MessageReader(s2);
      try {
        final content = 'X'.padRight(500, 'X');

        // === ACT ===
        await sendMessage(s1, 'chat', content);
        // 使用小 chunk_size 强制 recvMessage 内部的循环多次执行
        final (header, body) = await recvMessage(reader, chunkSize: 50);

        // === ASSERT ===
        expect(body, isNotNull);
        expect(utf8.decode(body!), equals(content));
      } finally {
        reader.close();
        s1.close();
        s2.close();
      }
    });

    // ---------------------------------------------------------
    // 【测试7】recvall 在一次性收到所有数据时能正确返回
    // ---------------------------------------------------------
    test('test_recvall_exact_bytes', () async {
      // === ARRANGE ===
      final (s1, s2) = await makeSocketPair();
      final reader = MessageReader(s2);
      try {
        final testData = utf8.encode('Hello, recvall!') as Uint8List;
        s1.add(testData);
        await s1.flush();

        // === ACT ===
        final result = await reader.recvall(testData.length);

        // === ASSERT ===
        expect(result, isNotNull);
        expect(result, equals(testData));
      } finally {
        reader.close();
        s1.close();
        s2.close();
      }
    });

    // ---------------------------------------------------------
    // 【测试8】recvall 在数据分多次到达时能循环收齐
    //
    // 解释：
    //   这是 recvall 的核心价值——TCP 不保证一次 recv() 给你全部数据。
    //   这里发送较大数据，验证 recvall 的循环逻辑。
    // ---------------------------------------------------------
    test('test_recvall_partial_data', () async {
      // === ARRANGE ===
      final (s1, s2) = await makeSocketPair();
      final reader = MessageReader(s2);
      try {
        // 发送较大数据 (260 字节)
        const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
        final chunk = List.filled(10, alphabet).join();
        final testData = utf8.encode(chunk) as Uint8List;
        s1.add(testData);
        await s1.flush();

        // === ACT ===
        // recvall 内部会循环直到收满 260 字节
        final result = await reader.recvall(testData.length);

        // === ASSERT ===
        expect(result, isNotNull);
        expect(result, equals(testData));
        expect(result!.length, equals(260));
      } finally {
        reader.close();
        s1.close();
        s2.close();
      }
    });
  });

  // ============================================================
  // 第 3 组：完整的往返测试（Round-trip）
  // ============================================================

  group('TestRoundTrip', () {
    // ---------------------------------------------------------
    // 【测试9】中文文本的完整往返
    // ---------------------------------------------------------
    test('test_roundtrip_text_chinese', () async {
      // === ARRANGE ===
      final (s1, s2) = await makeSocketPair();
      final reader = MessageReader(s2);
      try {
        const text = '你好世界！这是一个中文测试消息';

        // === ACT ===
        await sendMessage(s1, 'chat', text);

        // === ASSERT ===
        final (header, body) = await recvMessage(reader);
        expect(body, isNotNull);
        expect(utf8.decode(body!), equals(text));
      } finally {
        reader.close();
        s1.close();
        s2.close();
      }
    });

    // ---------------------------------------------------------
    // 【测试10】包含 emoji 的文本往返
    // ---------------------------------------------------------
    test('test_roundtrip_text_with_emoji', () async {
      // === ARRANGE ===
      final (s1, s2) = await makeSocketPair();
      final reader = MessageReader(s2);
      try {
        const text = 'Hello 😀🎉🔥 测试';

        // === ACT ===
        await sendMessage(s1, 'chat', text);

        // === ASSERT ===
        final (header, body) = await recvMessage(reader);
        expect(body, isNotNull);
        expect(utf8.decode(body!), equals(text));
      } finally {
        reader.close();
        s1.close();
        s2.close();
      }
    });

    // ---------------------------------------------------------
    // 【测试11】包含大量 \x00 字节的二进制数据往返
    //
    // 为什么重要：
    //   很多编程语言/库在处理字符串时遇到 \x00 会截断。
    //   我们的协议用 length 字段指定消息体长度，所以 \x00 不影响。
    // ---------------------------------------------------------
    test('test_roundtrip_binary_with_null_bytes', () async {
      // === ARRANGE ===
      final (s1, s2) = await makeSocketPair();
      final reader = MessageReader(s2);
      try {
        // 交替放置有效数据和 null 字节
        final data = Uint8List.fromList([
          ...utf8.encode('real data'),
          0,
          0,
          ...utf8.encode('more data'),
          0,
        ]);

        // === ACT ===
        await sendMessage(s1, 'file', data);

        // === ASSERT ===
        final (header, body) = await recvMessage(reader);
        expect(body, isNotNull);
        expect(body, equals(data));
      } finally {
        reader.close();
        s1.close();
        s2.close();
      }
    });

    // ---------------------------------------------------------
    // 【测试12】同一连接上连续发送多条消息
    //
    // 验证点：
    //   - 协议能正确区分消息边界（每条消息不会串到下一跳）
    //   - 这是 TCP 流协议中最容易出现 '粘包' 的地方
    // ---------------------------------------------------------
    test('test_roundtrip_multiple_messages', () async {
      // === ARRANGE ===
      final (s1, s2) = await makeSocketPair();
      final reader = MessageReader(s2);
      try {
        const messages = ['第一条消息', '第二条消息', '第三条消息'];

        // === ACT ===
        for (final msg in messages) {
          await sendMessage(s1, 'chat', msg);
        }

        // === ASSERT ===
        for (final expected in messages) {
          final (header, body) = await recvMessage(reader);
          expect(body, isNotNull);
          expect(utf8.decode(body!), equals(expected));
        }
      } finally {
        reader.close();
        s1.close();
        s2.close();
      }
    });

    // ---------------------------------------------------------
    // 【测试13】混合发送文本和二进制消息
    // ---------------------------------------------------------
    test('test_roundtrip_mixed_types', () async {
      // === ARRANGE ===
      final (s1, s2) = await makeSocketPair();
      final reader = MessageReader(s2);
      try {
        // 先发一条文本
        await sendMessage(s1, 'chat', 'Hello');

        // 再发一个 '文件'
        final fakePng = Uint8List.fromList([
          0x89,
          0x50,
          0x4E,
          0x47,
          0x0D,
          0x0A,
          0x1A,
          0x0A,
          ...utf8.encode('fake png data'),
        ]);
        await sendMessage(s1, 'file', fakePng);

        // === ASSERT ===
        // 收文本
        final (h1, b1) = await recvMessage(reader);
        expect(h1, isNotNull);
        expect(h1!['type'], equals('chat'));
        expect(utf8.decode(b1!), equals('Hello'));

        // 收二进制
        final (h2, b2) = await recvMessage(reader);
        expect(h2, isNotNull);
        expect(h2!['type'], equals('file'));
        // 验证 PNG 幻数
        expect(b2!.sublist(0, 4), equals([0x89, 0x50, 0x4E, 0x47]));
      } finally {
        reader.close();
        s1.close();
        s2.close();
      }
    });
  });

  // ============================================================
  // 第 4 组：防御性/健壮性测试
  // ============================================================

  group('TestDefensive', () {
    // ---------------------------------------------------------
    // 【测试14】extra_headers 的 key/value 都会被转为字符串
    //
    // 原因：
    //   protocol.dart 中有这样一行防御代码：
    //    header[entry.key.toString()] = entry.value.toString();
    //
    //   这防止了数字类型的用户名或 ID 导致 JSON 序列化失败。
    // ---------------------------------------------------------
    test('test_extra_headers_type_conversion', () async {
      // === ARRANGE ===
      final (s1, s2) = await makeSocketPair();
      final reader = MessageReader(s2);
      try {
        // === ACT ===
        await sendMessage(s1, 'test', 'data', extraHeaders: {
          'count': 100, // 整数 → "100"
          'ratio': 3.14, // 浮点数 → "3.14"
          'flag': true, // 布尔 → "true"
          'null_val': null, // null → "null"
        });

        // === ASSERT ===
        final (header, _) = await recvMessage(reader);
        expect(header, isNotNull);
        // 注意：jsonEncode 会将 Dart 的整数/浮点数/布尔值转为 JSON 数字/布尔
        // 但我们的防御代码将它们全部 toString() 了，
        // 所以 JSON 中的值是字符串（如 "100" 而非 100）
        expect(header!['count'], equals('100'));
        expect(header['ratio'], equals('3.14'));
        expect(header['flag'], equals('true'));
        expect(header['null_val'], equals('null'));
      } finally {
        reader.close();
        s1.close();
        s2.close();
      }
    });

    // ---------------------------------------------------------
    // 【测试15】header 中的 length 字段与实际消息体长度完全一致
    //
    // 为什么重要：
    //   recvMessage 依赖这个 length 字段来决定收多少字节。
    //   如果 length 不准确，会导致消息截断或粘包。
    // ---------------------------------------------------------
    test('test_message_length_accuracy', () async {
      // === ARRANGE ===
      final (s1, s2) = await makeSocketPair();
      final reader = MessageReader(s2);
      try {
        final content = 'A'.padRight(1024, 'A'); // 1KB 文本

        // === ACT ===
        await sendMessage(s1, 'chat', content);

        // === ASSERT ===
        final (header, body) = await recvMessage(reader);
        expect(header, isNotNull);
        expect(body, isNotNull);

        // length 应等于 UTF-8 编码后的字节数（纯 ASCII 时 == 字符数）
        expect(header!['length'], equals(utf8.encode(content).length));
        // 实际收到的字节数应等于声明的长度
        expect(body!.length, equals(header['length']));
      } finally {
        reader.close();
        s1.close();
        s2.close();
      }
    });
  });
}

// ============================================================
// 总结：如何运行这些测试
// ============================================================
//
// 运行全部测试:
//   cd dart_protocol
//   dart test
//
// 运行单个测试组:
//   dart test --name TestSendMessage
//
// 运行某个具体测试:
//   dart test --name "test_send_text_message"
//
// 详细输出:
//   dart test -v
//
// 查看测试覆盖率（需要先激活 coverage）:
//   dart pub global activate coverage
//   dart test --coverage=coverage
//   dart pub global run coverage:format_coverage --packages=.dart_tool/package_config.json --report-on=lib --lcov -o coverage/lcov.info -i coverage
// ============================================================
