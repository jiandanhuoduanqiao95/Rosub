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

import 'capabilities.dart';
import 'capabilities_android.dart';

/// 是否已在电池优化白名单；null = 无法判定（不弹引导的安全默认）
abstract class BatteryOptimizationCapability {
  Future<bool?> isIgnoring();

  /// 跳转电池优化设置页；false = 失败/不适用
  Future<bool> openSettings();

  /// 直弹系统"忽略电池优化"确认框（一键允许，无需翻设置页；
  /// 需 manifest REQUEST_IGNORE_BATTERY_OPTIMIZATIONS）；false = 失败/不适用
  Future<bool> requestIgnore();
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

  @override
  Future<bool> requestIgnore() async {
    try {
      return await platformChannel
              .invokeMethod<bool>('requestIgnoreBatteryOptimizations') ??
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

  @override
  Future<bool> requestIgnore() async => false;
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

// 电池白名单引导 UI 已并入 widgets/dialogs.dart 的"运行环境自检"
// （maybeShowEnvironmentCheckDialog，opt8）：与通知/悬浮窗/vivo 自启动
// 合并为一次引导，电池项走上面的 requestIgnore 直弹系统确认框。
// 旧 maybeShowBatteryOptimizationGuide 已删除（Q1-4 引导契约由新自检
// 语义覆盖，见 battery_optimization_stage_q1_test 与
// env_check_dialog_opt8_test）。
