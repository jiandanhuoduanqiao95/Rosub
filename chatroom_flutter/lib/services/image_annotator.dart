/// 图片标注合成器（阶段 P4：图片简易标注）
///
/// [imageSize] 解码图像尺寸；[decodeImage] 统一限制解码最大边
/// （[maxDecodeSize]，R-P14 延迟优化）；[compose] 按控制器状态合成标注
/// 结果 PNG：无修改（controller 为 null 或 hasChanges=false）时原字节
/// 直通（同一实例，零重绘快速路径）；有涂鸦先按画布坐标绘制全部笔画；
/// 有裁剪后按 cropRect（图像像素坐标，调用方先用 clampCropRect 钳制）截取。
///
/// R-P14（用户实测"标注延迟过大"）：编辑器与 compose 共用受限尺寸解码
/// ——涂鸦/裁剪坐标均基于解码后图像，光栅化与 PNG 编码的像素量随限幅
/// 大幅下降（4K 原图 → 最长边 1600，编码时间约降为 1/6）。

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/image_annotation.dart';

class ImageAnnotator {
  ImageAnnotator._();

  /// 解码最大边限幅（聊天标注输出无需原图分辨率）
  static const int maxDecodeSize = 1600;

  /// 解码图像尺寸（原始字节尺寸；非法字节抛异常，由调用方处理）
  static Future<ui.Size> imageSize(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final size =
        ui.Size(frame.image.width.toDouble(), frame.image.height.toDouble());
    frame.image.dispose();
    codec.dispose();
    return size;
  }

  /// 解码图像（编辑器显示与 compose 合成共用；非法字节返回 null）。
  ///
  /// 最大边超过 [maxSize] 时等比缩放到限幅内（GPU 光栅化，远快于
  /// 大分辨率 PNG 编码）——调用方所有坐标均基于返回图像。
  static Future<ui.Image?> decodeImage(
    Uint8List bytes, {
    int maxSize = maxDecodeSize,
  }) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      final image = frame.image;
      final w = image.width.toDouble();
      final h = image.height.toDouble();
      final largest = w > h ? w : h;
      if (largest <= maxSize) return image;
      final scale = maxSize / largest;
      final nw = (w * scale).round();
      final nh = (h * scale).round();
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawImageRect(
        image,
        Offset.zero & ui.Size(w, h),
        Offset.zero & ui.Size(nw.toDouble(), nh.toDouble()),
        Paint(),
      );
      final picture = recorder.endRecording();
      final scaled = await picture.toImage(nw, nh);
      image.dispose();
      return scaled;
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
