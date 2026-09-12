/// 统一轻提示（Q1 五轮问题3）
///
/// 全应用 SnackBar 收敛入口：持续 1.5s（SnackBar 默认 4s，长时间
/// 遮挡界面底部功能）+ 浮动样式（不挤压布局、少遮底部操作区）。
/// 注意：compact 下 showResponsiveDialog 打开的对话框为全屏铺满，
/// 会完全盖住 Scaffold 上的 SnackBar——**对话框内部触发的反馈不要
/// 走本函数**，用弹层内嵌提示（见 showFileListDialog/_FileListDialog）。

import 'package:flutter/material.dart';

void showNoticeBar(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(milliseconds: 1500),
      behavior: SnackBarBehavior.floating,
    ));
}
