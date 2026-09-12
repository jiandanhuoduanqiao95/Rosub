/// 电池优化白名单（阶段 Q1-4 —— OneUI/OriginOS 深度休眠杀后台引导）
///
/// 产品语义（§13.9 风险清单）：引导用户把应用加入电池优化白名单；
/// 未加白名单时后台仅离线可读（本地缓存，阶段 L3）+ 前台连接收消息
/// （回前台重连由 Q0-5 生命周期接线负责）。
///
/// 能力契约：[BatteryOptimizationCapability.isIgnoring] 返回是否已在
/// 白名单（null = 无法判定——非 Android/通道缺失/查询失败）；[openSettings]
/// 跳转系统电池优化设置页。Android 经 MethodChannel('chatroom/platform')
/// 由 MainActivity.kt 实现；桌面/其他平台为 [UnsupportedBatteryOptimization]
/// （null/false，桌面天然不弹）。
///
/// [maybeShowBatteryOptimizationGuide]：仅 Android 且未白名单且本次
/// 安装未提醒过 → 弹引导对话框（"去设置"/"暂不"两出口），任一出口
/// 持久化 SharedPreferences 键 'battery_guide_dismissed'（本次安装
/// 不再提醒）。SharedPreferences/通道异常一律按"不弹"安全降级。

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'capabilities.dart';
import 'capabilities_android.dart';

/// 是否已在电池优化白名单；null = 无法判定（不弹引导的安全默认）
abstract class BatteryOptimizationCapability {
  Future<bool?> isIgnoring();

  /// 跳转电池优化设置页；false = 失败/不适用
  Future<bool> openSettings();
}

class AndroidBatteryOptimization implements BatteryOptimizationCapability {
  @override
  Future<bool?> isIgnoring() async {
    try {
      return await platformChannel
          .invokeMethod<bool>('isIgnoringBatteryOptimizations');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> openSettings() async {
    try {
      return await platformChannel
              .invokeMethod<bool>('openBatteryOptimizationSettings') ??
          false;
    } catch (_) {
      return false;
    }
  }
}

/// 桌面/非 Android：无电池优化语义（isIgnoring null → 引导恒不弹）
class UnsupportedBatteryOptimization implements BatteryOptimizationCapability {
  @override
  Future<bool?> isIgnoring() async => null;

  @override
  Future<bool> openSettings() async => false;
}

class BatteryOptimization {
  BatteryOptimization._();

  /// 测试注入点（仿 PlatformCapabilities.*Override 惯例，优先于一切默认链）
  static BatteryOptimizationCapability? override;

  static BatteryOptimizationCapability? _resolved;
  static TargetPlatform? _resolvedPlatform;

  static BatteryOptimizationCapability get instance {
    if (override != null) return override!;
    final platform = effectiveTargetPlatform();
    if (_resolvedPlatform == platform && _resolved != null) return _resolved!;
    _resolvedPlatform = platform;
    _resolved = platform == TargetPlatform.android
        ? AndroidBatteryOptimization()
        : UnsupportedBatteryOptimization();
    return _resolved!;
  }

  static void resetForTest() {
    override = null;
    _resolved = null;
    _resolvedPlatform = null;
  }
}

/// 本次安装内"已提醒过"的持久化键（任一出口置 true）
const String batteryGuideDismissedKey = 'battery_guide_dismissed';

/// 进入聊天页时检查并按需弹出电池优化白名单引导（Q1-4）
///
/// 仅 Android 且 isIgnoring()==false 且未提醒过时弹出；桌面（null 链）
/// 与已白名单/已提醒场景均为无操作。SharedPreferences 异常按"未提醒
/// 过"处理（不崩）；弹窗关闭后持久化 dismissed，"去设置"再跳系统页。
Future<void> maybeShowBatteryOptimizationGuide(BuildContext context) async {
  bool? ignoring;
  try {
    ignoring = await BatteryOptimization.instance.isIgnoring();
  } catch (_) {
    return;
  }
  if (ignoring == null || ignoring) return;
  if (!context.mounted) return;

  bool dismissed = false;
  try {
    final prefs = await SharedPreferences.getInstance();
    dismissed = prefs.getBool(batteryGuideDismissedKey) ?? false;
  } catch (_) {
    dismissed = false;
  }
  if (dismissed || !context.mounted) return;

  final goSettings = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('电池优化白名单'),
      content: const Text(
        '部分手机厂商（如三星 OneUI、vivo OriginOS）会在深度休眠时'
        '结束后台应用，导致消息延迟送达。\n\n'
        '建议将本应用加入电池优化白名单：后台仍仅在前台连接收消息，'
        '退后台后可离线查看本地缓存消息。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('暂不'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('去设置'),
        ),
      ],
    ),
  );

  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(batteryGuideDismissedKey, true);
  } catch (_) {}

  if (goSettings == true) {
    await BatteryOptimization.instance.openSettings();
  }
}
