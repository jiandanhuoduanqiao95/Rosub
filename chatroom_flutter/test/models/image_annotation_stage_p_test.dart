// ============================================================
// image_annotation.dart 阶段 P —— 图片标注模型/控制器契约（TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 P4（P2-11 图片简易标注：
// 裁剪/涂鸦，依赖 P1 富媒体气泡后做）：
//
//   AnnotationStroke：一笔涂鸦（点列 + 颜色 + 线宽）
//   AnnotationController（ChangeNotifier）：
//     - strokes（不可变视图）/ currentColor（默认红）/ currentStrokeWidth（默认 4.0）
//     - startStroke(p) / extendStroke(p) / endStroke()：手势驱动画笔
//     - undo()（空时 no-op）/ clearStrokes()
//     - cropRect / setCropRect(null 可清除)
//     - hasChanges：有涂鸦或裁剪即 true（决定"完成"是否走重绘管线）
//   clampCropRect(rect, imageSize)：裁剪框钳制到图像边界（纯函数）——
//     负坐标钳 0，右/下越界钳图像宽高，宽高 ≤0 原样返回调用方处理
//
// 涂鸦坐标为编辑画布坐标（= 原图像素坐标，等比 1:1 逻辑空间），
// compose（见 image_annotator_stage_p_test.dart）按"先涂鸦后裁剪"合成。
// 实现前：本文件引用尚未实现的 API，编译失败或用例红，属 TDD 红。
// 实现后：全部转绿。
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/image_annotation.dart';

void main() {
  group('P4 —— AnnotationController 初始状态', () {
    test('初始：无涂鸦、无裁剪、红笔、4.0 线宽、hasChanges false', () {
      final controller = AnnotationController();
      expect(controller.strokes, isEmpty);
      expect(controller.cropRect, isNull);
      expect(controller.currentColor, Colors.red);
      expect(controller.currentStrokeWidth, 4.0);
      expect(controller.hasChanges, isFalse);
    });
  });

  group('P4 —— AnnotationController 涂鸦笔画', () {
    test('start/extend/end 产出一笔（点列正确）', () {
      final controller = AnnotationController();
      controller
        ..startStroke(const Offset(10, 10))
        ..extendStroke(const Offset(20, 20))
        ..extendStroke(const Offset(30, 25))
        ..endStroke();

      expect(controller.strokes.length, 1);
      final stroke = controller.strokes.first;
      expect(stroke.points,
          const [Offset(10, 10), Offset(20, 20), Offset(30, 25)]);
      expect(stroke.color, controller.currentColor);
      expect(stroke.strokeWidth, controller.currentStrokeWidth);
      expect(controller.hasChanges, isTrue);
    });

    test('连续两笔 → 两条独立笔画', () {
      final controller = AnnotationController();
      controller
        ..startStroke(const Offset(0, 0))
        ..endStroke()
        ..startStroke(const Offset(50, 50))
        ..endStroke();
      expect(controller.strokes.length, 2);
    });

    test('undo：移除最后一笔；空时 no-op 不抛异常', () {
      final controller = AnnotationController();
      controller.undo();
      expect(controller.strokes, isEmpty, reason: '空撤销 no-op');

      controller
        ..startStroke(const Offset(1, 1))
        ..endStroke()
        ..startStroke(const Offset(2, 2))
        ..endStroke();
      controller.undo();
      expect(controller.strokes.length, 1);
      expect(controller.strokes.first.points.first, const Offset(1, 1));
      controller.undo();
      expect(controller.strokes, isEmpty);
      expect(controller.hasChanges, isFalse);
    });

    test('clearStrokes：清空全部笔画（裁剪框保留语义由按钮层决定）', () {
      final controller = AnnotationController();
      controller
        ..startStroke(const Offset(1, 1))
        ..endStroke()
        ..clearStrokes();
      expect(controller.strokes, isEmpty);
    });
  });

  group('P4 —— AnnotationController 颜色/线宽/通知', () {
    test('setColor/setStrokeWidth 更新并通知', () {
      final controller = AnnotationController();
      var notified = 0;
      controller.addListener(() => notified++);

      controller.currentColor = Colors.blue;
      expect(controller.currentColor, Colors.blue);
      controller.currentStrokeWidth = 8.0;
      expect(controller.currentStrokeWidth, 8.0);
      expect(notified, 2, reason: '每次 setter 触发 notifyListeners');
    });

    test('新笔画使用当前颜色/线宽', () {
      final controller = AnnotationController();
      controller
        ..currentColor = Colors.lime
        ..currentStrokeWidth = 10.0
        ..startStroke(const Offset(5, 5))
        ..endStroke();
      expect(controller.strokes.first.color, Colors.lime);
      expect(controller.strokes.first.strokeWidth, 10.0);
    });
  });

  group('P4 —— AnnotationController 裁剪框', () {
    test('setCropRect 设置/清除并通知', () {
      final controller = AnnotationController();
      var notified = 0;
      controller.addListener(() => notified++);

      const rect = Rect.fromLTWH(10, 10, 50, 40);
      controller.setCropRect(rect);
      expect(controller.cropRect, rect);
      expect(controller.hasChanges, isTrue);
      expect(notified, 1);

      controller.setCropRect(null);
      expect(controller.cropRect, isNull);
      expect(controller.hasChanges, isFalse);
      expect(notified, 2);
    });

    test('hasChanges：有涂鸦或有裁剪任一即 true', () {
      final controller = AnnotationController();
      controller.startStroke(const Offset(1, 1));
      controller.endStroke();
      expect(controller.hasChanges, isTrue);

      final cropOnly = AnnotationController()
        ..setCropRect(const Rect.fromLTWH(0, 0, 10, 10));
      expect(cropOnly.hasChanges, isTrue, reason: '仅裁剪也算有修改');
    });
  });

  group('P4 —— clampCropRect 裁剪框钳制（纯函数）', () {
    const imageSize = Size(100, 80);

    test('正常框不变', () {
      const rect = Rect.fromLTWH(10, 10, 50, 40);
      expect(clampCropRect(rect, imageSize), rect);
    });

    test('负坐标钳 0', () {
      final clamped =
          clampCropRect(const Rect.fromLTWH(-10, -5, 50, 40), imageSize);
      expect(clamped.left, 0);
      expect(clamped.top, 0);
      // 语义：钳制原点并收缩尺寸保持右/下边界（或等价钳制策略——
      // 锁定"结果完全落在图像内"这一硬性约束）
      expect(clamped.left >= 0, isTrue);
      expect(clamped.top >= 0, isTrue);
      expect(clamped.right <= imageSize.width, isTrue);
      expect(clamped.bottom <= imageSize.height, isTrue);
    });

    test('右/下越界钳到图像边界', () {
      final clamped =
          clampCropRect(const Rect.fromLTWH(60, 50, 80, 60), imageSize);
      expect(clamped.right, imageSize.width);
      expect(clamped.bottom, imageSize.height);
      expect(clamped.left, 60);
      expect(clamped.top, 50);
    });

    test('完全越界的框 → 结果仍完全落在图像内（不抛异常）', () {
      final clamped =
          clampCropRect(const Rect.fromLTWH(500, 500, 50, 50), imageSize);
      expect(clamped.left >= 0, isTrue);
      expect(clamped.right <= imageSize.width, isTrue);
      expect(clamped.top >= 0, isTrue);
      expect(clamped.bottom <= imageSize.height, isTrue);
    });
  });
}
