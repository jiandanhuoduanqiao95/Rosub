/// 文本输入适配层（阶段 Q0-2 —— 跨平台统一入口）
///
/// 33 个输入实例化点（dialogs 25 + login_screen 3 + chat_screen 3 +
/// chat_view 2）统一经由本 widget，按目标平台分发：
///   - Linux（TargetPlatform.linux）：渲染 RawTextField，保持
///     "RawTextField + GTK IME 桥接"现状语义（中文输入/光标细条/
///     选区/NAV 键盘导航/粘贴图片全部不变）；
///   - 其余平台（android/ios/windows/macos）：渲染标准 Material
///     TextField——系统 IME 输入路径，不触碰 GTK 桥接进程（桥接进程
///     是 Linux 桌面专属，移动端无 X11 上下文）；showChineseInput 与
///     onImagePasted 在非 Linux 平台为无害冗余（保留参数以对齐
///     RawTextField 契约，调用点零成本迁移）。
///
/// 平台判定统一走 effectiveTargetPlatform()（platform/capabilities.dart）：
/// 显式 debugDefaultTargetPlatformOverride 优先（widget 测试可模拟目标
/// 平台，§21.1 规约）；无 override 回退 dart:io Platform 真实判定。
/// N5 键盘导航：ASCII 路径（回车提交/方向键切焦点）平台无关保留；
/// NAV 桥接路径仅 Linux（RawTextField 内部注册）。

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../platform/capabilities.dart';
import 'raw_text_field.dart';

class AdaptiveTextField extends StatefulWidget {
  /// 参数集与 RawTextField 完全一致（最小侵入迁移）
  final TextEditingController controller;
  final FocusNode? focusNode;
  final String? hintText;
  final bool obscureText;
  final bool showVisibilityToggle;
  final bool showChineseInput;
  final ValueChanged<String>? onSubmitted;

  /// 仅 Linux 生效：剪贴板含图片时回调（经 GTK 桥接读取，阶段 N3）。
  /// 移动端剪贴板无文件路径语义，入口按平台裁剪（§13.9 Q1）。
  final ValueChanged<Uint8List>? onImagePasted;

  const AdaptiveTextField({
    super.key,
    required this.controller,
    this.focusNode,
    this.hintText,
    this.obscureText = false,
    this.showVisibilityToggle = false,
    this.showChineseInput = false,
    this.onSubmitted,
    this.onImagePasted,
  });

  @override
  State<AdaptiveTextField> createState() => _AdaptiveTextFieldState();
}

class _AdaptiveTextFieldState extends State<AdaptiveTextField> {
  late bool _obscured = widget.obscureText;

  @override
  Widget build(BuildContext context) {
    if (effectiveTargetPlatform() == TargetPlatform.linux) {
      return RawTextField(
        controller: widget.controller,
        focusNode: widget.focusNode,
        hintText: widget.hintText,
        obscureText: widget.obscureText,
        showVisibilityToggle: widget.showVisibilityToggle,
        showChineseInput: widget.showChineseInput,
        onSubmitted: widget.onSubmitted,
        onImagePasted: widget.onImagePasted,
      );
    }
    final canToggle = widget.obscureText && widget.showVisibilityToggle;
    return TextField(
      controller: widget.controller,
      focusNode: widget.focusNode,
      obscureText: _obscured,
      onSubmitted: widget.onSubmitted,
      decoration: InputDecoration(
        hintText: widget.hintText,
        suffixIcon: canToggle
            ? IconButton(
                icon: Icon(_obscured
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined),
                onPressed: () => setState(() => _obscured = !_obscured),
              )
            : null,
      ),
    );
  }
}
