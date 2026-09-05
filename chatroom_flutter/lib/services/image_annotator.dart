/// 图片标注合成器（阶段 P4：图片简易标注）
///
/// [imageSize] 解码图像尺寸；[compose] 按控制器状态合成标注结果 PNG：
/// 无修改（controller 为 null 或 hasChanges=false）时原字节直通（同一实例，
/// 零重绘快速路径）；有涂鸦先按画布坐标绘制全部笔画；有裁剪后按
/// cropRect（图像像素坐标，调用方先用 clampCropRect 钳制）截取。

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/image_annotation.dart';

class ImageAnnotator {
  ImageAnnotator._();

  /// 解码图像尺寸（非法字节抛异常，由调用方处理）
  static Future<ui.Size> imageSize(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final size =
        ui.Size(frame.image.width.toDouble(), frame.image.height.toDouble());
    frame.image.dispose();
    codec.dispose();
    return size;
  }

  /// 解码图像（编辑器显示用；非法字节返回 null）
  static Future<ui.Image?> decodeImage(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  /// 合成标注结果；详见类头注释
  static Future<Uint8List?> compose(
    Uint8List bytes, {
    AnnotationController? controller,
  }) async {
    if (controller == null || !controller.hasChanges) return bytes;
    final source = await decodeImage(bytes);
    if (source == null) return null;
    final imageSize =
        ui.Size(source.width.toDouble(), source.height.toDouble());

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImage(source, Offset.zero, Paint());
    for (final stroke in controller.strokes) {
      if (stroke.points.isEmpty) continue;
      final paint = Paint()
        ..color = stroke.color
        ..strokeWidth = stroke.strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      final path = ui.Path()
        ..moveTo(stroke.points.first.dx, stroke.points.first.dy);
      for (var i = 1; i < stroke.points.length; i++) {
        path.lineTo(stroke.points[i].dx, stroke.points[i].dy);
      }
      canvas.drawPath(path, paint);
    }
    final picture = recorder.endRecording();
    var outImage = await picture.toImage(source.width, source.height);
    if (source != outImage) source.dispose();

    final crop = controller.cropRect;
    if (crop != null) {
      final clamped = clampCropRect(crop, imageSize);
      final w = clamped.width.round();
      final h = clamped.height.round();
      if (w > 0 && h > 0) {
        final cropRecorder = ui.PictureRecorder();
        final cropCanvas = Canvas(cropRecorder);
        cropCanvas.drawImageRect(
          outImage,
          clamped,
          Offset.zero & ui.Size(w.toDouble(), h.toDouble()),
          Paint(),
        );
        final cropPicture = cropRecorder.endRecording();
        outImage = await cropPicture.toImage(w, h);
      }
    }

    final data = await outImage.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  }
}
