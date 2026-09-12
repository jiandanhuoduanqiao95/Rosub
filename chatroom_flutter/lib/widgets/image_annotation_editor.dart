/// 图片标注编辑器（阶段 P4：图片简易标注——裁剪/涂鸦）
///
/// 全屏对话框：图像画布（拖拽=画笔；裁剪模式下拖拽=框选）+ 工具栏
/// （颜色色板 / 线宽三档 / 撤销 / 清空 / 裁剪切换 / 取消 / 完成）。
/// 状态由 [AnnotationController] 承载（可外部注入便于测试观测）；
/// 关闭由 [showImageAnnotationEditor] 的包装回调统一负责（编辑器内部
/// 只触发 onConfirm/onCancel 回调）；"完成"经 [ImageAnnotator.compose]
/// 合成（无修改时直通原字节）。画布坐标按图像等比缩放（scale ≤ 1）
/// 换算为图像像素坐标。

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/image_annotation.dart';
import '../services/image_annotator.dart';

/// 打开全屏标注编辑器；完成时回调 onConfirm（合成字节），取消回调 onCancel。
/// [compose] 为合成函数注入点（默认 [ImageAnnotator.compose]；测试环境
/// 引擎光栅化 future 在 FakeAsync 下不完成，可注入替身）。
Future<void> showImageAnnotationEditor(
  BuildContext context,
  Uint8List bytes, {
  AnnotationController? controller,
  required ValueChanged<Uint8List> onConfirm,
  VoidCallback? onCancel,
  ComposeFn? compose,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black,
    builder: (ctx) => Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: ImageAnnotationEditor(
        bytes: bytes,
        controller: controller,
        onConfirm: (b) {
          Navigator.of(ctx).pop();
          onConfirm(b);
        },
        onCancel: () {
          Navigator.of(ctx).pop();
          onCancel?.call();
        },
        compose: compose,
      ),
    ),
  );
}

typedef ComposeFn = Future<Uint8List?> Function(
    Uint8List bytes, AnnotationController controller);

class ImageAnnotationEditor extends StatefulWidget {
  final Uint8List bytes;
  final AnnotationController? controller;
  final ValueChanged<Uint8List> onConfirm;
  final VoidCallback? onCancel;
  final ComposeFn? compose;

  const ImageAnnotationEditor({
    super.key,
    required this.bytes,
    this.controller,
    required this.onConfirm,
    this.onCancel,
    this.compose,
  });

  @override
  State<ImageAnnotationEditor> createState() => _ImageAnnotationEditorState();
}

class _ImageAnnotationEditorState extends State<ImageAnnotationEditor> {
  late final AnnotationController _controller =
      widget.controller ?? AnnotationController();
  bool _cropMode = false;
  Offset? _cropDraftStart;
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    final image = await ImageAnnotator.decodeImage(widget.bytes);
    if (mounted) setState(() => _image = image);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  Center(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final imageSize = _image != null
                            ? Size(
                                _image!.width.toDouble(),
                                _image!.height.toDouble())
                            : const Size(400, 300);
                        var scale = 1.0;
                        if (imageSize.width > 0 && imageSize.height > 0) {
                          scale = (constraints.maxWidth / imageSize.width)
                              .clamp(0.0, 1.0);
                          scale = scale
                              .clamp(
                                  0.0,
                                  (constraints.maxHeight / imageSize.height)
                                      .clamp(0.0, 1.0))
                              .toDouble();
                        }
                        final displaySize = Size(
                          (imageSize.width * scale)
                              .clamp(1.0, constraints.maxWidth),
                          (imageSize.height * scale)
                              .clamp(1.0, constraints.maxHeight),
                        );
                        return GestureDetector(
                          onPanStart: (d) =>
                              _onPanStart(d.localPosition, scale),
                          onPanUpdate: (d) =>
                              _onPanUpdate(d.localPosition, scale),
                          onPanEnd: (_) => _onPanEnd(),
                          child: Container(
                            key: const ValueKey('annotation_canvas'),
                            width: displaySize.width,
                            height: displaySize.height,
                            color: Colors.black,
                            // Q1 真机反馈二轮（笔迹越界溢出）：越界点虽已钳制，
                            // 画布仍裁剪绘制——笔画/裁剪框恒不越出图像区域
                            child: ClipRect(
                              child: CustomPaint(
                                painter: _AnnotationPainter(
                                  image: _image,
                                  controller: _controller,
                                  scale: scale,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  // Q1 四轮（问题2）：取消移至画面左上角悬浮——远离底部
                  // 发送按钮，避免放弃编辑时误触
                  Positioned(
                    top: 8,
                    left: 8,
                    child: Material(
                      color: Colors.white.withValues(alpha: 0.12),
                      shape: const CircleBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: IconButton(
                        key: const ValueKey('annotation_cancel'),
                        tooltip: '取消',
                        icon: const Icon(Icons.close_rounded,
                            color: Colors.white),
                        onPressed: () => widget.onCancel == null
                            ? Navigator.of(context).pop()
                            : widget.onCancel!(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _buildToolbar(context),
          ],
        ),
      ),
    );
  }

  // ---- 手势（裁剪模式 = 框选；否则 = 画笔）----

  /// 手指局部坐标 → 图像像素坐标，并钳制到图像边界内。
  ///
  /// Q1 真机反馈二轮（笔迹越界溢出）：手指拖出画布（如划到屏幕右缘）
  /// 时 localPosition 已在画布外——不钳制的坐标会绘制到画布/屏幕外，
  /// 视觉上"画面右侧溢出屏幕"。
  Offset _toImagePoint(Offset local, double scale) {
    final img = _image;
    final dx = local.dx / scale;
    final dy = local.dy / scale;
    if (img == null) return Offset(dx, dy);
    return Offset(
      dx.clamp(0.0, img.width.toDouble()),
      dy.clamp(0.0, img.height.toDouble()),
    );
  }

  void _onPanStart(Offset local, double scale) {
    final p = _toImagePoint(local, scale);
    if (_cropMode) {
      _cropDraftStart = p;
    } else {
      _controller.startStroke(p);
    }
  }

  void _onPanUpdate(Offset local, double scale) {
    final p = _toImagePoint(local, scale);
    if (_cropMode) {
      final start = _cropDraftStart;
      if (start == null) return;
      _controller.setCropRect(Rect.fromPoints(start, p));
    } else {
      _controller.extendStroke(p);
    }
  }

  void _onPanEnd() {
    if (_cropMode) {
      _cropDraftStart = null;
    } else {
      _controller.endStroke();
    }
  }

  // ---- 工具栏 ----

  /// Q1 三轮（问题2）：底部操作全部同屏——两行均经 FittedBox(scaleDown)
  /// 压缩（过窄屏按比例缩小而非滑动），行内按钮 compact 密度收敛宽度；
  /// 全部交互入口（色板/线宽/撤销/清空/裁剪/取消/直接发送/发送）零删除。
  Widget _buildToolbar(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: SafeArea(
        top: false,
        child: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) {
            const palette = <int>[
              0xFFFF3B30,
              0xFF007AFF,
              0xFF34C759,
              0xFFFF9500,
              0xFFAF52DE,
            ];
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < palette.length; i++)
                        GestureDetector(
                          key: ValueKey('annot_color_$i'),
                          onTap: () =>
                              _controller.currentColor = Color(palette[i]),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 5),
                            child: CircleAvatar(
                              radius: _controller.currentColor.toARGB32() ==
                                      palette[i]
                                  ? 12
                                  : 9,
                              backgroundColor: Color(palette[i]),
                            ),
                          ),
                        ),
                      const SizedBox(width: 8),
                      Container(
                        width: 1,
                        height: 20,
                        color: Theme.of(context)
                            .colorScheme
                            .outline
                            .withValues(alpha: 0.6),
                      ),
                      const SizedBox(width: 8),
                      for (final entry in const {
                        '细': 4.0,
                        '中': 8.0,
                        '粗': 14.0,
                      }.entries)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: ChoiceChip(
                            label: Text(entry.key,
                                style: const TextStyle(fontSize: 12)),
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            selected:
                                _controller.currentStrokeWidth == entry.value,
                            onSelected: (_) =>
                                _controller.currentStrokeWidth = entry.value,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    children: [
                      _compactTextAction(
                        onPressed: _controller.undo,
                        label: '撤销',
                      ),
                      _compactTextAction(
                        onPressed: _controller.clearStrokes,
                        label: '清空',
                      ),
                      _compactAction(
                        onPressed: () {
                          setState(() {
                            _cropMode = !_cropMode;
                            if (!_cropMode) _controller.setCropRect(null);
                          });
                        },
                        child: Icon(
                          Icons.crop_rounded,
                          size: 20,
                          color: _cropMode
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                        tooltip: '裁剪',
                      ),
                      const SizedBox(width: 4),
                      // R-P12：仿微信双出口——不编辑直接发原图 / 编辑后发送
                      OutlinedButton(
                        key: const ValueKey('annotation_send_original'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 36),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          textStyle: const TextStyle(fontSize: 13),
                        ),
                        onPressed: () => widget.onConfirm(widget.bytes),
                        child: const Text('直接发送'),
                      ),
                      const SizedBox(width: 6),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 36),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          textStyle: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                        onPressed: () async {
                          final composeFn = widget.compose ??
                              (bytes, controller) => ImageAnnotator.compose(
                                  bytes,
                                  controller: controller);
                          final bytes =
                              await composeFn(widget.bytes, _controller);
                          if (bytes != null) widget.onConfirm(bytes);
                        },
                        child: const Text('发送'),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 工具行紧凑动作（图标按钮，裁剪共用）
  Widget _compactAction({
    required VoidCallback? onPressed,
    required Widget child,
    String? tooltip,
  }) {
    return IconButton(
      onPressed: onPressed,
      icon: child,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      constraints: const BoxConstraints(minWidth: 32, minHeight: 36),
    );
  }

  /// 工具行紧凑文字动作（撤销/清空/取消）
  Widget _compactTextAction({
    required VoidCallback? onPressed,
    required String label,
  }) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        textStyle: const TextStyle(fontSize: 13),
      ),
      child: Text(label),
    );
  }
}

/// 画布绘制：底图 + 涂鸦笔画 + 裁剪框
class _AnnotationPainter extends CustomPainter {
  final ui.Image? image;
  final AnnotationController controller;

  /// 显示缩放比（画布尺寸 = 图像尺寸 × scale）。笔画/裁剪框存储与合成
  /// 均为图像像素坐标——绘制必须经 [scale] 换算，否则缩小显示的大图
  /// 上标注位置/粗细与手指轨迹错位（R-P14 用户实测）。
  final double scale;

  _AnnotationPainter({
    required this.image,
    required this.controller,
    required this.scale,
  }) : super(repaint: controller);

  @override
  void paint(Canvas canvas, Size size) {
    final img = image;
    if (img != null) {
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        Offset.zero & size,
        Paint(),
      );
    } else {
      canvas.drawRect(
          Offset.zero & size, Paint()..color = Colors.grey.shade800);
    }
    // 笔画/裁剪框为图像坐标 → 经 canvas.scale 换算到显示坐标
    canvas.save();
    canvas.scale(scale);
    for (final stroke in controller.strokes) {
      _paintStroke(canvas, stroke.points, stroke.color, stroke.strokeWidth);
    }
    // Q1 真机反馈二轮（涂鸦不跟手）：进行中笔画实时绘制
    // （当前颜色/线宽），笔迹随手指延伸，不等松手
    final draft = controller.draftPoints;
    if (draft.isNotEmpty) {
      _paintStroke(
        canvas,
        draft,
        controller.currentColor,
        controller.currentStrokeWidth,
      );
    }
    final crop = controller.cropRect;
    if (crop != null) {
      // R-P21（用户反馈：透明白框不醒目，看不出裁了哪些部分）：改为
      // 标准裁剪 UI——框外区域整体压暗（保留区保持原亮度，一眼可辨），
      // 白色实线边框 + 三分构图网格 + 四角粗 L 形角标。所有线宽按
      // 1/scale 换算，保证不同缩放下显示粗细一致。
      final bounds =
          Rect.fromLTWH(0, 0, size.width / scale, size.height / scale);
      final outside = ui.Path()
        ..addRect(bounds)
        ..addRect(crop)
        ..fillType = ui.PathFillType.evenOdd;
      canvas.drawPath(
          outside, Paint()..color = Colors.black.withValues(alpha: 0.55));
      canvas.drawRect(
        crop,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5 / scale,
      );
      final gridPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.35)
        ..strokeWidth = 1 / scale;
      for (final f in const [1.0 / 3.0, 2.0 / 3.0]) {
        canvas.drawLine(Offset(crop.left + crop.width * f, crop.top),
            Offset(crop.left + crop.width * f, crop.bottom), gridPaint);
        canvas.drawLine(Offset(crop.left, crop.top + crop.height * f),
            Offset(crop.right, crop.top + crop.height * f), gridPaint);
      }
      final arm = 18.0 / scale;
      final cornerPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3 / scale
        ..strokeCap = StrokeCap.round;
      final corners = <(Offset, Offset, Offset, Offset)>[
        (
          crop.topLeft,
          Offset(crop.left + arm, crop.top),
          Offset(crop.left, crop.top + arm),
          crop.topLeft
        ),
        (
          crop.topRight,
          Offset(crop.right - arm, crop.top),
          Offset(crop.right, crop.top + arm),
          crop.topRight
        ),
        (
          crop.bottomLeft,
          Offset(crop.left + arm, crop.bottom),
          Offset(crop.left, crop.bottom - arm),
          crop.bottomLeft
        ),
        (
          crop.bottomRight,
          Offset(crop.right - arm, crop.bottom),
          Offset(crop.right, crop.bottom - arm),
          crop.bottomRight
        ),
      ];
      for (final (_, hEnd, vEnd, origin) in corners) {
        canvas.drawLine(origin, hEnd, cornerPaint);
        canvas.drawLine(origin, vEnd, cornerPaint);
      }
    }
    canvas.restore();
  }

  void _paintStroke(
      Canvas canvas, List<Offset> points, Color color, double width) {
    if (points.isEmpty) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    if (points.length == 1) {
      canvas.drawPoints(
          ui.PointMode.points, points, paint..strokeWidth = width * 1.2);
      return;
    }
    final path = ui.Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _AnnotationPainter oldDelegate) => false;
}
