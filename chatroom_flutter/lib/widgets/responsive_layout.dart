/// 响应式布局工具（阶段 Q1-1 —— 手机窄屏响应式）
///
/// 断点契约：逻辑宽度 < [kCompactWidthBreakpoint]（600，Material compact
/// 阈值）为 compact——手机窄屏单屏布局；≥600 为宽屏——桌面双栏与
/// 平板（Q4 复用同一断点）。平台无关，纯宽度驱动（§36.3"会话/群组
/// 全功能"行：手机窄屏改单屏切换布局）。
///
/// 对话框统一入口 [showResponsiveDialog]：compact 下对话框全屏化
/// （Dialog.fullscreen 路由，barrierColor 作为全屏底色透传——视频/
/// 图片查看器黑色语义）；宽屏下与 showDialog 居中语义完全一致
/// （既有 800x600 测试基线与桌面行为零变化）。

import 'package:flutter/material.dart';

/// compact 断点：逻辑宽度 < 600 视为手机窄屏（Material 窗口分级 compact）
const double kCompactWidthBreakpoint = 600;

/// 当前是否 compact（手机窄屏单屏布局）
///
/// 事实源 = 根渲染视图的当前逻辑宽度——生产环境即窗口/屏幕逻辑宽度
/// （与 MediaQuery 同源）；_widget 测试中 `setSurfaceSize` 驱动的多尺寸
/// 回归（既有 P5 五档、login 响应式各档）同样以渲染表面为准（本
/// Flutter 版本 setSurfaceSize 不回写 MediaQuery/View）。无界约束时
/// 回退 MediaQuery 宽度（防御）。
bool isCompactLayout(BuildContext context) {
  final constraints = WidgetsBinding
      .instance.renderViews.first.configuration.logicalConstraints;
  final width = constraints.hasBoundedWidth && constraints.maxWidth.isFinite
      ? constraints.maxWidth
      : MediaQuery.sizeOf(context).width;
  return width < kCompactWidthBreakpoint;
}

/// 对话框统一入口（阶段 Q1-1 对话框全屏化；Q1 真机反馈修订）
///
/// compact（< 600）：对话框覆盖整屏——外层 [Dialog.fullscreen] 承载
/// 底色（[barrierColor] 非空时作为全屏底色，黑色查看器语义保留）；
/// 内层经局部 [DialogThemeData] 覆盖（insetPadding 清零 + constraints
/// 钳全屏 + 直角）让 [AlertDialog] **本体**铺满整屏（修订前AlertDialog
/// 自带的内层 Dialog 仍按 minWidth 280 居中渲染——"整块灰屏中间浮
/// 小白卡片"的根因）：标题置顶、内容区弹性拉伸、按钮行沉底。
/// 宽屏（≥ 600）：等价于既有 showDialog 居中语义（返回值/遮罩可关/
/// 遮罩色全透传），桌面既有行为与测试基线不变。
Future<T?> showResponsiveDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
}) {
  final compact = isCompactLayout(context);
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierColor: barrierColor,
    builder: compact
        ? (ctx) => Dialog.fullscreen(
              backgroundColor: barrierColor,
              child: Theme(
                data: _fullscreenDialogTheme(ctx),
                child: Builder(builder: builder),
              ),
            )
        : builder,
  );
}

/// compact 全屏对话框的局部主题：AlertDialog 自带的内层 Dialog 默认
/// 渲染为 minWidth 280 的居中卡片——覆盖 insetPadding/constraints/shape
/// 后本体铺满整屏（标题/内容/按钮按 AlertDialog 标准排布）。
ThemeData _fullscreenDialogTheme(BuildContext ctx) {
  final base = Theme.of(ctx);
  return base.copyWith(
    dialogTheme: DialogThemeData(
      insetPadding: EdgeInsets.zero,
      constraints: BoxConstraints.tight(MediaQuery.sizeOf(ctx)),
      shape: const RoundedRectangleBorder(),
    ),
  );
}
