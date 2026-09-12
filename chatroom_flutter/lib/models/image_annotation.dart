/// 图片标注模型（阶段 P4：图片简易标注——裁剪/涂鸦）
///
/// [AnnotationStroke] 为一笔涂鸦（点列 + 颜色 + 线宽）；
/// [AnnotationController] 为编辑器状态（ChangeNotifier）；
/// [clampCropRect] 将裁剪框钳制到图像边界。涂鸦/裁剪坐标均为图像像素
/// 坐标（编辑画布 1:1 换算，见 image_annotation_editor.dart）。

import 'package:flutter/material.dart';

/// 一笔涂鸦
class AnnotationStroke {
  final List<Offset> points;
  final Color color;
  final double strokeWidth;

  const AnnotationStroke({
    required this.points,
    required this.color,
    required this.strokeWidth,
  });
}

/// 标注编辑控制器
class AnnotationController extends ChangeNotifier {
  final List<AnnotationStroke> _strokes = [];
  Color _color = Colors.red;
  double _strokeWidth = 4.0;
  Rect? _cropRect;

  List<Offset> _draftPoints = [];

  /// 已完成笔画（不可变视图）
  List<AnnotationStroke> get strokes => List.unmodifiable(_strokes);

  /// 进行中笔画点列（不可变视图；空 = 未在绘制）
  ///
  /// Q1 真机反馈二轮（涂鸦不跟手根因）：画布必须绘制进行中笔画——
  /// 仅在 endStroke 落入 strokes 后才绘制，表现为"松手才显现整笔"。
  List<Offset> get draftPoints => List.unmodifiable(_draftPoints);

  Color get currentColor => _color;
  set currentColor(Color value) {
    _color = value;
    notifyListeners();
  }

  double get currentStrokeWidth => _strokeWidth;
  set currentStrokeWidth(double value) {
    _strokeWidth = value;
    notifyListeners();
  }

  Rect? get cropRect => _cropRect;

  void setCropRect(Rect? rect) {
    _cropRect = rect;
    notifyListeners();
  }

  /// 有涂鸦或裁剪即视为有修改（决定 compose 是否走重绘管线）
  bool get hasChanges => _strokes.isNotEmpty || _cropRect != null;

  /// 开始一笔（手势 onPanStart）
  ///
  /// Q1 真机反馈（跟手）：起笔即通知画布重绘——单点按压的落笔痕迹
  /// 立即可见，不等松手。
  void startStroke(Offset point) {
    _draftPoints = [point];
    notifyListeners();
  }

  /// 延伸当前一笔（手势 onPanUpdate）
  ///
  /// Q1 真机反馈（跟手）：拖动过程逐点通知重绘，笔迹随手指实时延伸
  /// （原实现仅在 endStroke 通知，松手才显现整笔）。
  void extendStroke(Offset point) {
    if (_draftPoints.isEmpty) return;
    _draftPoints = [..._draftPoints, point];
    notifyListeners();
  }

  /// 结束当前一笔（手势 onPanEnd）；单点同样成笔
  void endStroke() {
    if (_draftPoints.isEmpty) return;
    _strokes.add(AnnotationStroke(
      points: _draftPoints,
      color: _color,
      strokeWidth: _strokeWidth,
    ));
    _draftPoints = [];
    notifyListeners();
  }

  /// 撤销最后一笔（空时 no-op）
  void undo() {
    if (_strokes.isEmpty) return;
    _strokes.removeLast();
    notifyListeners();
  }

  /// 清空全部笔画（裁剪框保留，由按钮层决定是否一并清除）
  void clearStrokes() {
    if (_strokes.isEmpty) return;
    _strokes.clear();
    notifyListeners();
  }
}

/// 裁剪框钳制到图像边界（纯函数）：负坐标钳 0，右/下越界钳图像宽高；
/// 结果恒完全落在图像内（可为零面积，由 compose 端跳过）。
Rect clampCropRect(Rect rect, Size imageSize) {
  final right = rect.right.clamp(0.0, imageSize.width);
  final bottom = rect.bottom.clamp(0.0, imageSize.height);
  final left = rect.left.clamp(0.0, right);
  final top = rect.top.clamp(0.0, bottom);
  return Rect.fromLTRB(left, top, right, bottom);
}
