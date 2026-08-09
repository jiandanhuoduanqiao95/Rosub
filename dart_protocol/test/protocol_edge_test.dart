// ============================================================
// protocol.dart 边界 / 异常 / 攻击性测试（测试强化新增）
// ============================================================
// 既有 protocol_test.dart 覆盖常规编解码往返，本文件专门打击：
//   - sendMessage 非法 content 类型（ArgumentError）
//   - 极小 chunkSize 分块 / 0 长度 body / 空内容
//   - extraHeaders 非字符串值强制转换
//   - MessageReader：EOF、0 字节、close 竞态、碎片化写入
//   - readBody / readFileBody 提前 EOF（部分写入）
//   - 损坏头（非法 JSON / 长度截断）行为记录
//   - sendFileMessage：onProgress 抛异常不中断 / 文件缺失
//   - Unicode 与二进制乱码往返
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_protocol/protocol.dart';
import 'package:test/test.dart';

Future<(Socket, Socket)> makeSocketPair() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  final clientFuture = Socket.connect(InternetAddress.loopbackIPv4, port);
  final serverSocket = await server.first;
  final client = await clientFuture;
  unawaited(server.close());
  return (client, serverSocket);
}

void main() {
  group('TestSendMessageInvalid', () {
    test('非法 content 类型抛出 ArgumentError', () async {
      final (c, s) = await makeSocketPair();
      addTearDown(() {
        c.close();
        s.close();
      });
      expect(
        () => sendMessage(c, 'chat', 12345),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => sendMessage(c, 'chat', true),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => sendMessage(c, 'chat', null),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => sendMessage(c, 'chat', {'a': 1}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('空字符串与空字节数组往返', () async {
      final (c, s) = await makeSocketPair();
      addTearDown(() {
        c.close();
        s.close();
      });
      await sendMessage(c, 'chat', '');
      final reader = MessageReader(s);
      final (header, body) = await recvMessage(reader);
      expect(header?['type'], 'chat');
      expect(header?['length'], 0);
      expect(body, isEmpty);

      await sendMessage(c, 'chat', Uint8List(0));
      final (h2, b2) = await recvMessage(reader);
      expect(h2?['length'], 0);
      expect(b2, isEmpty);
    });

    test('extraHeaders 数字/布尔值强制转字符串', () async {
      final (c, s) = await makeSocketPair();
      addTearDown(() {
        c.close();
        s.close();
      });
      await sendMessage(c, 'chat', 'x', extraHeaders: {
        'num': 123,
        'bool': true,
        'null': null,
      });
      final reader = MessageReader(s);
      final (header, _) = await recvMessage(reader);
      expect(header?['num'], '123');
      expect(header?['bool'], 'true');
      expect(header?['null'], 'null');
    });
  });

  group('TestChunkedSend', () {
    test('极小 chunkSize 分块发送仍可完整接收', () async {
      final (c, s) = await makeSocketPair();
      addTearDown(() {
        c.close();
        s.close();
      });
      final payload = 'A' * 100;
      await sendMessage(c, 'chat', payload, chunkSize: 7);
      final reader = MessageReader(s);
      final (header, body) = await recvMessage(reader);
      expect(header?['length'], 100);
      expect(utf8.decode(body!), payload);
    });

    test('分块大小与内容长度一致时不越界', () async {
      final (c, s) = await makeSocketPair();
      addTearDown(() {
        c.close();
        s.close();
      });
      await sendMessage(c, 'chat', '12345', chunkSize: 5);
      final reader = MessageReader(s);
      final (header, body) = await recvMessage(reader);
      expect(header?['length'], 5);
      expect(utf8.decode(body!), '12345');
    });
  });

  group('TestMessageReaderEOF', () {
    test('recvall(0) 返回空字节', () async {
      final (c, s) = await makeSocketPair();
      addTearDown(() {
        c.close();
        s.close();
      });
      final reader = MessageReader(s);
      final data = await reader.recvall(0);
      expect(data, isEmpty);
    });

    test('连接关闭后 recvall 返回 null', () async {
      final (c, s) = await makeSocketPair();
      final reader = MessageReader(s);
      c.close();
      final data = await reader.recvall(10);
      expect(data, isNull);
      s.close();
    });

    test('close 后 recvall 返回 null（读取器主动关闭）', () async {
      final (c, s) = await makeSocketPair();
      addTearDown(() {
        c.close();
        s.close();
      });
      final reader = MessageReader(s);
      reader.close();
      final data = await reader.recvall(5);
      expect(data, isNull);
    });

    test('部分数据 + 连接关闭：recvall 返回 null 且不挂起', () async {
      final (c, s) = await makeSocketPair();
      final reader = MessageReader(s);
      c.add(utf8.encode('abc'));
      await c.flush();
      c.close();
      final data = await reader.recvall(10);
      expect(data, isNull);
      s.close();
    });

    test('碎片化写入累积后精确读取', () async {
      final (c, s) = await makeSocketPair();
      addTearDown(() {
        c.close();
        s.close();
      });
      final reader = MessageReader(s);
      for (var i = 0; i < 5; i++) {
        c.add(utf8.encode('chunk$i'));
        await c.flush();
      }
      final data = await reader.recvall(30);
      expect(utf8.decode(data!), 'chunk0chunk1chunk2chunk3chunk4');
      // 剩余的也完整
      final rest = await reader.recvall(0);
      expect(rest, isEmpty);
    });

    test('recvall 精确截取并保留剩余字节', () async {
      final (c, s) = await makeSocketPair();
      addTearDown(() {
        c.close();
        s.close();
      });
      final reader = MessageReader(s);
      c.add(utf8.encode('abcdefghij'));
      await c.flush();
      final first = await reader.recvall(4);
      expect(utf8.decode(first!), 'abcd');
      final second = await reader.recvall(6);
      expect(utf8.decode(second!), 'efghij');
    });

    test('重复 close 幂等', () async {
      final (c, s) = await makeSocketPair();
      addTearDown(() {
        c.close();
        s.close();
      });
      final reader = MessageReader(s);
      expect(() {
        reader.close();
        reader.close();
      }, returnsNormally);
    });
  });

  group('TestBodyEOF', () {
    test('readBody 提前 EOF 返回 null', () async {
      final (c, s) = await makeSocketPair();
      final reader = MessageReader(s);
      c.add(utf8.encode('short'));
      await c.flush();
      c.close();
      final body = await readBody(reader, 100);
      expect(body, isNull);
      s.close();
    });

    test('【缺陷记录】readFileBody 提前 EOF：不足一块时返回 0，部分字节滞留缓冲', () async {
      final (c, s) = await makeSocketPair();
      final reader = MessageReader(s);
      c.add(utf8.encode('partial-data'));
      await c.flush();
      c.close();

      final tmp = Directory.systemTemp.createTempSync('protocol_edge');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final filePath = '${tmp.path}/partial.bin';

      // 现状：recvall(chunkSize) 要求整块，不足时返回 null，
      // 已收到的 12 字节滞留缓冲、不写入文件 → 返回 0
      final written = await readFileBody(reader, 100, filePath);
      expect(written, 0);
      expect(File(filePath).lengthSync(), 0);
      // 滞留字节仍可从 reader 读取（未被吞掉）
      final leftover = await reader.recvall(12);
      expect(utf8.decode(leftover!), 'partial-data');
      s.close();
    });

    test('readFileBody 完整写入内容与进度回调', () async {
      final (c, s) = await makeSocketPair();
      addTearDown(() {
        c.close();
        s.close();
      });
      final reader = MessageReader(s);
      final payload = Uint8List.fromList(List.generate(5000, (i) => i % 256));
      await sendMessage(c, 'file', payload, chunkSize: 2048);

      final tmp = Directory.systemTemp.createTempSync('protocol_edge');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final filePath = '${tmp.path}/f.bin';
      final progresses = <int>[];
      final header = await readHeader(reader);
      final len = (header!['length'] as num).toInt();
      final written = await readFileBody(reader, len, filePath,
          chunkSize: 2048,
          onProgress: (r, t) => progresses.add(r));
      expect(written, 5000);
      expect(File(filePath).lengthSync(), 5000);
      expect(progresses.last, 5000);
      expect(progresses.first, greaterThan(0));
      expect(progresses, orderedEquals(progresses.toSet().toList()),
          reason: '进度应单调递增');
    });

    test('readFileBody 目标路径不存在目录时抛异常', () async {
      final (c, s) = await makeSocketPair();
      addTearDown(() {
        c.close();
        s.close();
      });
      final reader = MessageReader(s);
      await sendMessage(c, 'file', 'data');
      final header = await readHeader(reader);
      final len = (header!['length'] as num).toInt();
      expect(
        () => readFileBody(reader, len, '/nonexistent_dir_xyz/f.bin'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('TestCorruptedHeader', () {
    test('非 JSON 头抛出 FormatException（记录行为：由调用方 catch）', () async {
      final (c, s) = await makeSocketPair();
      addTearDown(() {
        c.close();
        s.close();
      });
      final reader = MessageReader(s);
      final badJson = utf8.encode('{not-json');
      final buf = ByteData(4);
      buf.setUint32(0, badJson.length, Endian.big);
      c.add(buf.buffer.asUint8List());
      c.add(badJson);
      await c.flush();
      expect(() => readHeader(reader), throwsA(isA<FormatException>()));
    });

    test('头长度截断（只发 2 字节）返回 null', () async {
      final (c, s) = await makeSocketPair();
      final reader = MessageReader(s);
      c.add([0, 0]);
      await c.flush();
      c.close();
      expect(await readHeader(reader), isNull);
      s.close();
    });

    test('长度字段为字符串类型时 readBody 抛 TypeError（记录行为）', () async {
      final (c, s) = await makeSocketPair();
      addTearDown(() {
        c.close();
        s.close();
      });
      final reader = MessageReader(s);
      final header = utf8.encode('{"type":"chat","length":"10"}');
      final buf = ByteData(4);
      buf.setUint32(0, header.length, Endian.big);
      c.add(buf.buffer.asUint8List());
      c.add(header);
      c.add(utf8.encode('0123456789'));
      await c.flush();
      expect(() => recvMessage(reader), throwsA(isA<TypeError>()));
    });
  });

  group('TestSendFileMessageEdge', () {
    test('onProgress 回调抛异常不中断发送', () async {
      final (c, s) = await makeSocketPair();
      addTearDown(() {
        c.close();
        s.close();
      });
      final tmp = Directory.systemTemp.createTempSync('protocol_edge');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final filePath = '${tmp.path}/prog.bin';
      File(filePath).writeAsBytesSync(List.generate(100000, (i) => i % 256));

      await sendFileMessage(c, 'file', filePath,
          onProgress: (sent, total) {
        if (sent > 0) throw StateError('UI 异常');
      });
      final reader = MessageReader(s);
      final (header, body) = await recvMessage(reader);
      expect(header?['length'], 100000);
      expect(body!.length, 100000);
    });

    test('文件不存在时抛异常（记录行为）', () async {
      final (c, s) = await makeSocketPair();
      addTearDown(() {
        c.close();
        s.close();
      });
      expect(
        () => sendFileMessage(c, 'file', '/nonexistent_xyz.bin'),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('空文件发送：header length 0 且成功', () async {
      final (c, s) = await makeSocketPair();
      addTearDown(() {
        c.close();
        s.close();
      });
      final tmp = Directory.systemTemp.createTempSync('protocol_edge');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final filePath = '${tmp.path}/empty.bin';
      File(filePath).writeAsBytesSync([]);

      await sendFileMessage(c, 'file', filePath);
      final reader = MessageReader(s);
      final (header, body) = await recvMessage(reader);
      expect(header?['length'], 0);
      expect(body, isEmpty);
    });
  });

  group('TestRoundTripEdge', () {
    test('Unicode 与 emoji 往返无损', () async {
      final (c, s) = await makeSocketPair();
      addTearDown(() {
        c.close();
        s.close();
      });
      const text = '中文消息🙂🚀\u0000\u0001混合\x00\x01';
      await sendMessage(c, 'chat', text);
      final reader = MessageReader(s);
      final (_, body) = await recvMessage(reader);
      expect(utf8.decode(body!), text);
    });

    test('全字节 0-255 二进制往返无损', () async {
      final (c, s) = await makeSocketPair();
      addTearDown(() {
        c.close();
        s.close();
      });
      final bytes = Uint8List.fromList(List.generate(256, (i) => i));
      await sendMessage(c, 'file', bytes);
      final reader = MessageReader(s);
      final (_, body) = await recvMessage(reader);
      expect(body, bytes);
    });

    test('sendAndRecv 便捷组合', () async {
      final (c, s) = await makeSocketPair();
      addTearDown(() {
        c.close();
        s.close();
      });
      final reader = MessageReader(s);
      final (header, body) =
          await sendAndRecv(c, reader, 'chat', 'hello', extraHeaders: {'to': 'bob'});
      expect(header?['type'], 'chat');
      expect(header?['to'], 'bob');
      expect(utf8.decode(body!), 'hello');
    });
  });
}
