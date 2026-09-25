// ============================================================
// 证书指纹校验契约（阶段 Q0-6 可选加固 —— TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 Q「Q0-6 安全连接评估（可选
// 加固）」：
//
//   客户端现状 onBadCertificate: (_) => true 接受任意证书；局域网可
//   接受，公网试用（《部署指南.md》§4）建议实现证书指纹校验（SHA-256
//   首连展示/确认或内嵌指纹）。
//
// 契约：新增 lib/services/certificate_trust.dart ——
//
//   class CertificateTrust {
//     static bool enforceFingerprint;   // 默认 false（局域网现状语义不变）
//     static String? pinnedSha256;      // 内嵌/预置指纹（"内嵌指纹"模式）
//     // 首连确认钩子（"首连展示/确认"模式；null → 未知指纹直接拒绝）
//     static Future<bool> Function(
//         X509Certificate cert, String host, int port)? confirmUnknownFingerprint;
//     static String fingerprintOf(X509Certificate cert);
//     //    SHA-256(cert.der) 小写 hex，64 字符无分隔符
//     static Future<bool> validate(X509Certificate cert, String host, int port);
//     static void resetForTest();       // 清确认记忆与开关（teardown）
//   }
//
//   策略矩阵：
//     · enforceFingerprint == false（默认）→ 恒接受（现状语义锁定：
//       自签名证书局域网可用，Q0 不改变既有行为）
//     · enforce == true 且指纹 == pinnedSha256 → 接受（confirm 不触发）
//     · enforce == true 且未知指纹：confirmUnknownFingerprint 返回 true
//       → 接受；返回 false 或钩子为 null → 拒绝（安全默认）
//     · 首连确认记忆：同一指纹确认接受后，本进程内再次校验不再询问
//       （确认回调恰一次；跨进程持久化属实现自由，不锁定）
//   接线：SocketService.connect（主连接 + 大文件传输通道两处）的
//   onBadCertificate 委托 CertificateTrust.validate（源码扫描锁定
//   硬编码恒真消失）。
//
// 实现注意（供落码参考，非测试断言）：SHA-256 计算建议引入
// package:crypto（共享依赖按分支纪律落主干 pubspec）。
//
// 实现前：certificate_trust.dart 不存在，本文件编译失败，属 TDD 红。
// 实现后：全部转绿。
// ============================================================

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/services/certificate_trust.dart';

class FakeCert implements X509Certificate {
  final Uint8List _der;
  FakeCert(this._der);
  @override
  Uint8List get der => _der;
  @override
  String get pem => '-----BEGIN CERTIFICATE-----FAKE-----END CERTIFICATE-----';
  @override
  Uint8List get sha1 => Uint8List(20);
  @override
  String get subject => 'CN=tset.cn';
  @override
  String get issuer => 'CN=tset.cn';
  @override
  DateTime get startValidity => DateTime.fromMillisecondsSinceEpoch(0);
  @override
  DateTime get endValidity =>
      DateTime.fromMillisecondsSinceEpoch(4102444800000);
}

Uint8List bytesOf(String s) => Uint8List.fromList(s.codeUnits);

String srcOf(String relPath) => File('lib/$relPath').readAsStringSync();

int countOf(String source, String needle) => source.split(needle).length - 1;

const sha256Empty =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
const sha256Abc =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

void main() {
  setUp(() {
    CertificateTrust.resetForTest();
  });
  tearDown(() {
    CertificateTrust.resetForTest();
  });

  group('Q0-6 —— SHA-256 指纹计算（cert.der → 小写 hex 64 字符）', () {
    test('空 DER → SHA-256 空串标准向量', () {
      expect(
          CertificateTrust.fingerprintOf(FakeCert(Uint8List(0))), sha256Empty);
    });

    test('DER 内容 "abc" → SHA-256 标准向量', () {
      expect(
          CertificateTrust.fingerprintOf(FakeCert(bytesOf('abc'))), sha256Abc);
    });

    test('格式契约：64 字符、全小写 hex、无分隔符', () {
      final fp = CertificateTrust.fingerprintOf(FakeCert(bytesOf('x')));
      expect(fp.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(fp), isTrue,
          reason: '统一小写纯 hex，便于内嵌/复制比对（冒号分隔格式不采用）');
    });
  });

  group('Q0-6 —— 校验策略矩阵', () {
    test('默认 enforceFingerprint=false → 恒接受（现状语义，局域网可用）', () async {
      expect(CertificateTrust.enforceFingerprint, isFalse,
          reason: 'Q0-6 为可选加固，默认行为必须与现状一致');
      final ok = await CertificateTrust.validate(
          FakeCert(bytesOf('any-self-signed')), 'tset.cn', 8090);
      expect(ok, isTrue);
    });

    test('enforce=true + 指纹与 pinnedSha256 匹配 → 接受（confirm 不触发）', () async {
      CertificateTrust.enforceFingerprint = true;
      CertificateTrust.pinnedSha256 = sha256Abc;
      var confirmCalls = 0;
      CertificateTrust.confirmUnknownFingerprint = (cert, host, port) async {
        confirmCalls++;
        return true;
      };
      final ok = await CertificateTrust.validate(
          FakeCert(bytesOf('abc')), 'tset.cn', 8090);
      expect(ok, isTrue);
      expect(confirmCalls, 0, reason: '内嵌指纹匹配属可信路径，不打扰用户');
    });

    test('enforce=true + 未知指纹 + 钩子为 null → 拒绝（安全默认）', () async {
      CertificateTrust.enforceFingerprint = true;
      CertificateTrust.confirmUnknownFingerprint = null;
      final ok = await CertificateTrust.validate(
          FakeCert(bytesOf('unknown')), 'tset.cn', 8090);
      expect(ok, isFalse);
    });

    test('enforce=true + 未知指纹 + 首连确认返回 true → 接受', () async {
      CertificateTrust.enforceFingerprint = true;
      String? shownHost;
      int? shownPort;
      String? shownFingerprint;
      CertificateTrust.confirmUnknownFingerprint = (cert, host, port) async {
        shownHost = host;
        shownPort = port;
        shownFingerprint = CertificateTrust.fingerprintOf(cert);
        return true;
      };
      final ok = await CertificateTrust.validate(
          FakeCert(bytesOf('abc')), 'tset.cn', 8090);
      expect(ok, isTrue);
      expect(shownHost, 'tset.cn');
      expect(shownPort, 8090);
      expect(shownFingerprint, sha256Abc,
          reason: '首连展示页可拿到指纹与目标地址（SHA-256 展示/确认契约）');
    });

    test('enforce=true + 未知指纹 + 首连确认返回 false → 拒绝', () async {
      CertificateTrust.enforceFingerprint = true;
      CertificateTrust.confirmUnknownFingerprint = (cert, host, port) async {
        return false;
      };
      final ok = await CertificateTrust.validate(
          FakeCert(bytesOf('abc')), 'tset.cn', 8090);
      expect(ok, isFalse);
    });

    test('enforce=false → confirm 钩子不触发（开关关闭即无任何打扰）', () async {
      var confirmCalls = 0;
      CertificateTrust.confirmUnknownFingerprint = (cert, host, port) async {
        confirmCalls++;
        return true;
      };
      await CertificateTrust.validate(
          FakeCert(bytesOf('unknown')), 'tset.cn', 8090);
      expect(confirmCalls, 0);
    });
  });

  group('Q0-6 —— 首连确认记忆（同指纹会话内不再询问）', () {
    test('确认接受后同指纹再次校验 → 接受且不再询问（回调恰一次）', () async {
      CertificateTrust.enforceFingerprint = true;
      var confirmCalls = 0;
      CertificateTrust.confirmUnknownFingerprint = (cert, host, port) async {
        confirmCalls++;
        return true;
      };
      expect(
          await CertificateTrust.validate(
              FakeCert(bytesOf('abc')), 'tset.cn', 8090),
          isTrue);
      expect(
          await CertificateTrust.validate(
              FakeCert(bytesOf('abc')), 'tset.cn', 8090),
          isTrue,
          reason: '主连接确认后，大文件传输通道同证书不应再次弹确认');
      expect(confirmCalls, 1);
    });

    test('不同指纹（未确认过）→ 再次询问', () async {
      CertificateTrust.enforceFingerprint = true;
      var confirmCalls = 0;
      CertificateTrust.confirmUnknownFingerprint = (cert, host, port) async {
        confirmCalls++;
        return true;
      };
      await CertificateTrust.validate(
          FakeCert(bytesOf('cert-a')), 'tset.cn', 8090);
      await CertificateTrust.validate(
          FakeCert(bytesOf('cert-b')), 'tset.cn', 8090);
      expect(confirmCalls, 2, reason: '证书更换（服务端重签/中间人）须重新确认');
    });

    test('resetForTest 清除确认记忆（测试隔离）', () async {
      CertificateTrust.enforceFingerprint = true;
      var confirmCalls = 0;
      CertificateTrust.confirmUnknownFingerprint = (cert, host, port) async {
        confirmCalls++;
        return true;
      };
      await CertificateTrust.validate(
          FakeCert(bytesOf('abc')), 'tset.cn', 8090);
      CertificateTrust.resetForTest();
      CertificateTrust.enforceFingerprint = true;
      await CertificateTrust.validate(
          FakeCert(bytesOf('abc')), 'tset.cn', 8090);
      expect(confirmCalls, 2);
    });

    test('确认被拒绝的指纹不留记忆（下次仍询问——用户可改主意）', () async {
      CertificateTrust.enforceFingerprint = true;
      var confirmCalls = 0;
      CertificateTrust.confirmUnknownFingerprint = (cert, host, port) async {
        confirmCalls++;
        return confirmCalls > 1;
      };
      expect(
          await CertificateTrust.validate(
              FakeCert(bytesOf('abc')), 'tset.cn', 8090),
          isFalse);
      expect(
          await CertificateTrust.validate(
              FakeCert(bytesOf('abc')), 'tset.cn', 8090),
          isTrue,
          reason: '首次拒绝后再次校验应重新询问而非永久拒绝');
      expect(confirmCalls, 2);
    });
  });

  group('Q0-6 —— SocketService 接线（源码扫描锁定）', () {
    test('certificate_trust.dart 存在', () {
      expect(File('lib/services/certificate_trust.dart').existsSync(), isTrue);
    });

    test('socket_service.dart 硬编码恒真 onBadCertificate 消失', () {
      final src = srcOf('services/socket_service.dart');
      expect(countOf(src, 'onBadCertificate: (_) => true'), 0,
          reason: '主连接与传输通道两处均须委托 CertificateTrust.validate');
    });

    test('socket_service.dart 委托 CertificateTrust.validate', () {
      final src = srcOf('services/socket_service.dart');
      expect(src.contains('CertificateTrust'), isTrue);
      expect(src.contains('validate'), isTrue);
    });
  });
}
