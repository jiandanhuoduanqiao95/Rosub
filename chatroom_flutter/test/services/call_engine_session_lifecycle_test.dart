import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _src() => File('lib/services/call_engine.dart').readAsStringSync();

void main() {
  group('CallEngine 关闭后回调隔离', () {
    test('1:1 PeerConnection 回调带 generation 校验', () {
      final src = _src();
      expect(src, contains('int _pcGeneration = 0;'));
      expect(src, contains('final generation = ++_pcGeneration;'));
      expect(src, contains('if (generation != _pcGeneration) return;'));
      expect(src, contains('_pcGeneration++;'));
    });

    test('群 mesh PeerSession 关闭后回调短路', () {
      final src = _src();
      expect(src, contains('bool _closed = false;'));
      expect(src, contains('if (_closed) return;'));
      expect(src, contains('if (_closed) return;\n    _closed = true;'));
    });
  });
}
