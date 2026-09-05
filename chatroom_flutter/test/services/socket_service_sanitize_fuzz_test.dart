// ============================================================
// sanitizeFilename 模糊 / 属性测试（测试强化新增）
// ============================================================
// 用确定性种子 PRNG 生成大量"恶意"文件名，验证不变量：
//   1. 输出永不含路径分隔符（/ 与 \）
//   2. 输出绝不为空 / '.' / '..'
//   3. 输出恒等于输入的最后一个路径段（或回退值）
// 重复执行同一测试（`flutter test --repeat`）可增加发现偶发缺陷的概率。
// ============================================================

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/services/socket_service.dart';

void main() {
  group('sanitizeFilename 模糊不变量（4000 例）', () {
    final prng = _SeededRandom(20260809);

    String randomToken() {
      // 混合：纯字母数字 / 含点与空格的"半合法" / 纯分隔符
      final kind = prng.nextInt(3);
      return switch (kind) {
        0 => String.fromCharCodes(List.generate(prng.nextInt(20) + 1,
            (_) => _alnum.codeUnitAt(prng.nextInt(_alnum.length)))),
        1 => String.fromCharCodes(List.generate(prng.nextInt(15) + 1,
            (_) => _mixed.codeUnitAt(prng.nextInt(_mixed.length)))),
        _ => List.generate(prng.nextInt(5) + 1, (_) => prng.nextInt(2) == 0 ? '/' : r'\').join(),
      };
    }

    String randomPath() {
      final depth = prng.nextInt(6);
      final parts = <String>[];
      for (var d = 0; d < depth; d++) {
        parts.add(randomToken());
      }
      final base = randomToken();
      parts.add(base);
      final sep = prng.nextInt(2) == 0 ? '/' : r'\';
      return parts.join(sep);
    }

    test('输出不含分隔符、不为空/点/双点、等于参考实现', () {
      for (var i = 0; i < 4000; i++) {
        final input = randomPath();
        final out = SocketService.sanitizeFilename(input);

        expect(out.contains('/'), isFalse, reason: 'input=$input out=$out');
        expect(out.contains(r'\'), isFalse, reason: 'input=$input out=$out');
        expect(out, isNot(''), reason: 'input=$input');
        expect(out, isNot('.'), reason: 'input=$input');
        expect(out, isNot('..'), reason: 'input=$input');

        // 与参考实现对照
        final expected = _referenceSanitize(input);
        expect(out, expected, reason: 'input=$input');
      }
    });

    test('纯随机字节串（含控制字符）不崩溃且保持不变量', () {
      for (var i = 0; i < 2000; i++) {
        final len = prng.nextInt(64);
        final bytes = List.generate(
            len, (_) => prng.nextInt(0x100)); // 任意字节 0-255
        final input = String.fromCharCodes(bytes);
        final out = SocketService.sanitizeFilename(input);
        expect(out.contains('/'), isFalse, reason: 'input=${input.codeUnits}');
        expect(out.contains(r'\'), isFalse, reason: 'input=${input.codeUnits}');
        expect(out, isNot(''), reason: 'len=$len');
      }
    });

    test('空字符/点字符组成的恶意名全部回退', () {
      for (var i = 0; i < 500; i++) {
        final n = prng.nextInt(8) + 1;
        final input = List.generate(n, (_) => '.').join() +
            (prng.nextInt(2) == 0 ? '/' : '');
        final out = SocketService.sanitizeFilename(input);
        if (input == '..' || input == '.' || input == '/' || input == r'\' || input.isEmpty) {
          expect(out, 'received_file', reason: 'input=$input');
        } else {
          expect(out, isNot('..'), reason: 'input=$input');
          expect(out, isNot('.'), reason: 'input=$input');
        }
      }
    });
  });
}

/// 与 socket_service.dart sanitizeFilename 等价的参考实现（对偶验证）。
String _referenceSanitize(String filename) {
  final base = filename.split(RegExp(r'[/\\]')).last;
  if (base.isEmpty || base == '.' || base == '..') {
    return 'received_file';
  }
  return base;
}

class _SeededRandom {
  int _state;
  _SeededRandom(this._state);

  int nextInt(int max) {
    _state = (_state * 1103515245 + 12345) & 0x7FFFFFFF;
    return _state % max;
  }
}

const String _alnum =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
const String _mixed = '.-_ 你好é漢字%#~';
