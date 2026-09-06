/// 证书信任策略（阶段 Q0-6 可选加固 —— 公网试用前的指纹校验）
///
/// 现状：SocketService 对自签名证书 `onBadCertificate: (_) => true`
/// 恒真放行——局域网可接受，公网试用（《部署指南.md》§4）存在中间人
/// 风险。本类提供两种校验模式（§13.9 Q0-6"SHA-256 首连展示/确认或
/// 内嵌指纹"）：
///   - **内嵌指纹**：pinnedSha256 预置服务端证书指纹（SHA-256 小写
///     hex），匹配即放行——纯同步，enforce 开启后立即生效；
///   - **首连确认**：confirmUnknownFingerprint 钩子（UI 层展示指纹
///     与目标地址后用户裁决）——确认接受会记住该指纹（本进程内不再
///     询问；跨进程持久化由 UI 层落盘后回填 pinnedSha256）。
///
/// 默认 enforceFingerprint == false：恒接受（现状语义，Q0 不改变
/// 既有行为）。SocketService 经 acceptBadCertificate 同步门接线
/// （onBadCertificate 签名为同步 bool）：快速路径（关闭/内嵌匹配/
/// 已确认）同步放行；需交互确认的证书本次拒绝并异步发起确认流程
/// （同一指纹并发去重），确认接受后由既有重连机制放行。
///
/// SHA-256 经 package:crypto 计算（对 cert.der 摘要，小写 hex 64 字符）。

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

class CertificateTrust {
  CertificateTrust._();

  /// 指纹校验总开关（默认关 = 局域网现状语义不变）
  static bool enforceFingerprint = false;

  /// 预置指纹（小写 hex 64 字符；null = 未内嵌）
  static String? pinnedSha256;

  /// 首连确认钩子（展示指纹/目标地址 → 用户裁决；null → 未知指纹直接拒绝）
  static Future<bool> Function(
      X509Certificate cert, String host, int port)? confirmUnknownFingerprint;

  static final Set<String> _confirmed = {};
  static final Set<String> _confirming = {};

  /// 证书指纹：SHA-256(der)，小写 hex 64 字符（无分隔符）
  static String fingerprintOf(X509Certificate cert) =>
      sha256.convert(cert.der).toString();

  /// 完整校验策略（异步；测试锁定契约）
  static Future<bool> validate(
      X509Certificate cert, String host, int port) async {
    if (!enforceFingerprint) return true;
    final fp = fingerprintOf(cert);
    if (pinnedSha256 != null && fp == _normalize(pinnedSha256!)) return true;
    if (_confirmed.contains(fp)) return true;
    final confirm = confirmUnknownFingerprint;
    if (confirm == null) return false;
    final ok = await confirm(cert, host, port);
    if (ok) {
      _confirmed.add(fp);
      _confirming.remove(fp);
    }
    return ok;
  }

  /// SocketService 同步门（onBadCertificate 为同步 bool 签名）：
  /// 关闭/内嵌匹配/已确认 → 同步放行；需交互确认 → 本次拒绝并
  /// 异步发起 [validate] 全链确认（接受后既有重连按记忆放行）
  static bool validateSync(X509Certificate cert, String host, int port) {
    if (!enforceFingerprint) return true;
    final fp = fingerprintOf(cert);
    if (pinnedSha256 != null && fp == _normalize(pinnedSha256!)) return true;
    if (_confirmed.contains(fp)) return true;
    if (_confirming.contains(fp)) return false;
    _confirming.add(fp);
    unawaited(validate(cert, host, port).catchError((_) => false));
    return false;
  }

  static String _normalize(String fingerprint) =>
      fingerprint.toLowerCase().replaceAll(':', '');

  /// 清策略状态与确认记忆（teardown 测试隔离）；钩子注入保留——
  /// 需要无钩子场景的用例显式置 confirmUnknownFingerprint = null
  static void resetForTest() {
    enforceFingerprint = false;
    pinnedSha256 = null;
    _confirmed.clear();
    _confirming.clear();
  }
}
