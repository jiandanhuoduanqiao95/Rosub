// ============================================================
// image_annotator.dart 阶段 P —— 标注合成器契约（已实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 P4（图片简易标注）合成管线：
//
//   ImageAnnotator（纯静态工具）：
//     - imageSize(bytes) → Size：解码图像尺寸（非法字节抛 FormatException
//       由调用方处理）
//     - compose(bytes, {AnnotationController? controller}) → Future<Uint8List?>：
//       合成标注结果 PNG 字节。语义：
//         * controller 为 null 或 !hasChanges → 原字节直通（同一实例，
//           零重绘快速路径——发送未标注图片不劣化）
//         * 有涂鸦：按画布坐标绘制全部笔画（先涂鸦）
//         * 有裁剪：按 cropRect（图像像素坐标，调用方先用 clampCropRect
//           钳制）截取（后裁剪）
//         * 输出为可解码 PNG
//
// 光栅化调用（Picture.toImage / instantiateImageCodec / toByteData）为
// 引擎真实异步，在 widget 测试 FakeAsync zone 内不完成——统一以
// tester.runAsync 包裹（golden 基线同机制的真实光栅化）。
// ============================================================

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/image_annotation.dart';
import 'package:chatroom_flutter/services/image_annotator.dart';

/// 生成真实 PNG（纯色 w×h）
Future<Uint8List> makePng(int w, int h) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..color = Colors.blue);
  final picture = recorder.endRecording();
  final image = await picture.toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Future<ui.Size> decodeSize(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final size = Size(frame.image.width.toDouble(), frame.image.height.toDouble());
  frame.image.dispose();
  codec.dispose();
  return size;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P4 —— ImageAnnotator.imageSize 解码', () {
    testWidgets('真实 PNG → 尺寸正确', (tester) async {
      final bytes = (await tester.runAsync(() => makePng(100, 80)))!;
      final size =
          (await tester.runAsync(() => ImageAnnotator.imageSize(bytes)))!;
      expect(size.width, 100);
      expect(size.height, 80);
    });
  });

  group('P4 —— ImageAnnotator.compose 合成', () {
    testWidgets('无标注（controller null）→ 原字节直通（同一实例）',
        (tester) async {
      final bytes = (await tester.runAsync(() => makePng(60, 40)))!;
      final out = await ImageAnnotator.compose(bytes);
      expect(identical(out, bytes), isTrue,
          reason: '无标注走零重绘快速路径');
    });

    testWidgets('无标注（controller 无修改）→ 原字节直通', (tester) async {
      final bytes = (await tester.runAsync(() => makePng(60, 40)))!;
      final controller = AnnotationController();
      final out = await ImageAnnotator.compose(bytes, controller: controller);
      expect(identical(out, bytes), isTrue, reason: 'hasChanges=false 直通');
    });

    testWidgets('带涂鸦 → 输出为可解码 PNG（尺寸不变）', (tester) async {
      final bytes = (await tester.runAsync(() => makePng(100, 80)))!;
      final controller = AnnotationController()
        ..currentColor = Colors.red
        ..startStroke(const Offset(10, 10))
        ..extendStroke(const Offset(50, 40))
        ..extendStroke(const Offset(90, 60))
        ..endStroke();

      final out = (await tester.runAsync(
          () => ImageAnnotator.compose(bytes, controller: controller)))!;
      expect(out, isNotNull);
      expect(out, isNot(bytes), reason: '涂鸦后字节变化');
      final size = (await tester.runAsync(() => decodeSize(out)))!;
      expect(size.width, 100, reason: '无裁剪时保持原尺寸');
      expect(size.height, 80);
    });

    testWidgets('带裁剪 → 输出尺寸等于裁剪框尺寸', (tester) async {
      final bytes = (await tester.runAsync(() => makePng(100, 80)))!;
      final controller = AnnotationController()
        ..setCropRect(const Rect.fromLTWH(20, 10, 60, 50));

      final out = (await tester.runAsync(
          () => ImageAnnotator.compose(bytes, controller: controller)))!;
      expect(out, isNotNull);
      final size = (await tester.runAsync(() => decodeSize(out)))!;
      expect(size.width, 60);
      expect(size.height, 50);
    });

    testWidgets('涂鸦 + 裁剪组合 → 裁剪后尺寸（先涂鸦后裁剪）', (tester) async {
      final bytes = (await tester.runAsync(() => makePng(100, 80)))!;
      final controller = AnnotationController()
        ..startStroke(const Offset(5, 5))
        ..extendStroke(const Offset(30, 30))
        ..endStroke()
        ..setCropRect(const Rect.fromLTWH(0, 0, 40, 40));

      final out = (await tester.runAsync(
          () => ImageAnnotator.compose(bytes, controller: controller)))!;
      expect(out, isNotNull);
      final size = (await tester.runAsync(() => decodeSize(out)))!;
      expect(size.width, 40);
      expect(size.height, 40);
    });

    testWidgets('越界裁剪框：调用方用 clampCropRect 钳制后合成不抛异常',
        (tester) async {
      final bytes = (await tester.runAsync(() => makePng(100, 80)))!;
      const raw = Rect.fromLTWH(60, 50, 80, 60);
      final clamped = clampCropRect(raw, const Size(100, 80));
      final controller = AnnotationController()..setCropRect(clamped);
      final out = (await tester.runAsync(
          () => ImageAnnotator.compose(bytes, controller: controller)))!;
      expect(out, isNotNull);
    });
  });
}
