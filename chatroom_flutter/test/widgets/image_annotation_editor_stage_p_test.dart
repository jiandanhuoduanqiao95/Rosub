// ============================================================
// image_annotation_editor.dart 阶段 P —— 图片标注编辑器契约（TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 P4（图片简易标注：裁剪/涂鸦）
// 编辑器 Widget：
//
//   ImageAnnotationEditor（全屏对话框内渲染，经 showImageAnnotationEditor
//   打开）：
//     - 构造：{required Uint8List bytes, AnnotationController? controller,
//             required ValueChanged<Uint8List> onConfirm,
//             VoidCallback? onCancel}
//       controller 可外部注入（测试观测内部状态；缺省内部自建）
//     - 布局：图像画布（ValueKey('annotation_canvas')）+ 底部工具栏
//     - 工具栏契约：
//       * 颜色色板 ≥5 个圆点（ValueKey('annot_color_<i>')，第 0 个 =
//         默认红）；点击切换 controller.currentColor
//       * 线宽三档 '细'/'中'/'粗'（4.0/8.0/14.0）；点击切换
//         controller.currentStrokeWidth
//       * '撤销' → controller.undo()；'清空' → controller.clearStrokes()
//       * 裁剪切换按钮（Icons.crop_rounded，tooltip '裁剪'）：开启后
//         画布拖拽为框选 → controller.cropRect；再次点击 → 取消裁剪
//         （cropRect 清空）
//       * '取消' → onCancel 并关闭；'完成' → onConfirm(合成字节) 并关闭
//         （合成走 ImageAnnotator.compose：无修改直通原字节）
//
// 交互：画布拖拽 = 画笔（start/extend/end）。引擎光栅化在 FakeAsync
// 下不完成：PNG 生成统一 tester.runAsync；"带涂鸦完成"用例经编辑器
// compose 注入点注入替身（真实合成管线见 image_annotator_stage_p_test）。
// "无修改完成"走真实直通路径（零引擎调用）。
// ============================================================

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/image_annotation.dart';
import 'package:chatroom_flutter/widgets/image_annotation_editor.dart';

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

/// 全屏打开编辑器的标准壳
Future<void> pumpEditor(
  WidgetTester tester,
  Uint8List bytes,
  AnnotationController controller,
  void Function(Uint8List) onConfirm, {
  ComposeFn? compose,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (ctx) => Center(
          child: TextButton(
            onPressed: () => showImageAnnotationEditor(
              ctx,
              bytes,
              controller: controller,
              onConfirm: onConfirm,
              compose: compose,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P4 —— 编辑器布局', () {
    testWidgets('画布 + 工具栏渲染（色板/线宽/撤销/清空/裁剪/取消/完成）', (tester) async {
      final bytes = (await tester.runAsync(() => makePng(120, 90)))!;
      final controller = AnnotationController();
      await pumpEditor(tester, bytes, controller, (_) {});

      expect(find.byKey(const ValueKey('annotation_canvas')), findsOneWidget);
      expect(find.byKey(const ValueKey('annot_color_0')), findsOneWidget,
          reason: '色板第 0 个 = 默认红');
      expect(find.text('细'), findsOneWidget);
      expect(find.text('中'), findsOneWidget);
      expect(find.text('粗'), findsOneWidget);
      expect(find.text('撤销'), findsOneWidget);
      expect(find.text('清空'), findsOneWidget);
      expect(find.byTooltip('裁剪'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      expect(find.text('发送'), findsOneWidget);
    });
  });

  group('P4 —— 工具栏交互（controller 状态联动）', () {
    testWidgets('点击色板 → currentColor 切换', (tester) async {
      final bytes = (await tester.runAsync(() => makePng(100, 80)))!;
      final controller = AnnotationController();
      await pumpEditor(tester, bytes, controller, (_) {});

      expect(controller.currentColor, Colors.red, reason: '默认红');
      await tester.tap(find.byKey(const ValueKey('annot_color_3')));
      await tester.pumpAndSettle();
      expect(controller.currentColor, isNot(Colors.red), reason: '切换为第 3 色');
    });

    testWidgets('线宽三档 → currentStrokeWidth 切换', (tester) async {
      final bytes = (await tester.runAsync(() => makePng(100, 80)))!;
      final controller = AnnotationController();
      await pumpEditor(tester, bytes, controller, (_) {});

      await tester.tap(find.text('中'));
      await tester.pumpAndSettle();
      expect(controller.currentStrokeWidth, 8.0);

      await tester.tap(find.text('粗'));
      await tester.pumpAndSettle();
      expect(controller.currentStrokeWidth, 14.0);

      await tester.tap(find.text('细'));
      await tester.pumpAndSettle();
      expect(controller.currentStrokeWidth, 4.0);
    });

    testWidgets('画布拖拽 → 新增一笔（点列 ≥2）；撤销/清空联动', (tester) async {
      final bytes = (await tester.runAsync(() => makePng(200, 200)))!;
      final controller = AnnotationController();
      await pumpEditor(tester, bytes, controller, (_) {});

      await tester.drag(find.byKey(const ValueKey('annotation_canvas')),
          const Offset(60, 40));
      await tester.pumpAndSettle();

      expect(controller.strokes.length, 1, reason: '拖拽产生一笔涂鸦');
      expect(controller.strokes.first.points.length, greaterThanOrEqualTo(2),
          reason: '一笔至少起点+终点');

      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect(controller.strokes, isEmpty, reason: '撤销移除最后一笔');

      await tester.drag(find.byKey(const ValueKey('annotation_canvas')),
          const Offset(30, 30));
      await tester.pumpAndSettle();
      expect(controller.strokes.length, 1);

      await tester.tap(find.text('清空'));
      await tester.pumpAndSettle();
      expect(controller.strokes, isEmpty, reason: '清空移除全部笔画');
    });

    testWidgets('裁剪模式：开启后拖拽框选 → cropRect；再点取消裁剪 → 清空', (tester) async {
      final bytes = (await tester.runAsync(() => makePng(300, 300)))!;
      final controller = AnnotationController();
      await pumpEditor(tester, bytes, controller, (_) {});

      await tester.tap(find.byTooltip('裁剪'));
      await tester.pumpAndSettle();

      await tester.drag(find.byKey(const ValueKey('annotation_canvas')),
          const Offset(80, 80));
      await tester.pumpAndSettle();

      expect(controller.cropRect, isNotNull, reason: '框选产生裁剪框');
      expect(controller.cropRect!.width, 80.0);
      expect(controller.cropRect!.height, 80.0);
      expect(controller.strokes, isEmpty, reason: '裁剪模式下拖拽不产生涂鸦');

      await tester.tap(find.byTooltip('裁剪'));
      await tester.pumpAndSettle();
      expect(controller.cropRect, isNull, reason: '再次点击取消裁剪');
    });
  });

  group('P4 —— 完成确认', () {
    testWidgets('无标注点"完成" → onConfirm 收到原字节（直通）并关闭', (tester) async {
      final bytes = (await tester.runAsync(() => makePng(100, 80)))!;
      final controller = AnnotationController();
      Uint8List? confirmed;
      await pumpEditor(tester, bytes, controller, (b) => confirmed = b);

      await tester.tap(find.text('发送'));
      await tester.pumpAndSettle();

      expect(identical(confirmed, bytes), isTrue, reason: '无修改直通原字节（零重绘）');
      expect(find.text('发送'), findsNothing, reason: '确认后编辑器关闭');
    });

    testWidgets('有涂鸦点"完成" → onConfirm 收到合成字节（非原字节）并关闭', (tester) async {
      final bytes = (await tester.runAsync(() => makePng(150, 120)))!;
      final controller = AnnotationController();
      Uint8List? confirmed;
      await pumpEditor(
        tester,
        bytes,
        controller,
        (b) => confirmed = b,
        compose: (b, ctrl) async => Uint8List.fromList([...b, 0xAB]),
      );

      await tester.drag(find.byKey(const ValueKey('annotation_canvas')),
          const Offset(50, 50));
      await tester.pumpAndSettle();
      await tester.tap(find.text('发送'));
      await tester.pumpAndSettle();

      expect(confirmed, isNotNull);
      expect(identical(confirmed, bytes), isFalse, reason: '涂鸦后重新合成');
      expect(confirmed!.lengthInBytes, greaterThan(0));
    });

    testWidgets('点"取消" → onCancel 触发且不调用 onConfirm', (tester) async {
      final bytes = (await tester.runAsync(() => makePng(100, 80)))!;
      final controller = AnnotationController();
      var cancelled = false;
      Uint8List? confirmed;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () => showImageAnnotationEditor(
                  ctx,
                  bytes,
                  controller: controller,
                  onConfirm: (b) => confirmed = b,
                  onCancel: () => cancelled = true,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(cancelled, isTrue);
      expect(confirmed, isNull);
      expect(find.text('发送'), findsNothing);
    });
  });

  group('R-P12 —— 直接发送（仿微信：不编辑直接发原图）', () {
    testWidgets('工具栏含"直接发送"按钮（与"发送"并列）', (tester) async {
      final bytes = (await tester.runAsync(() => makePng(100, 80)))!;
      await pumpEditor(tester, bytes, AnnotationController(), (_) {});

      expect(find.byKey(const ValueKey('annotation_send_original')),
          findsOneWidget, reason: '直接发送入口');
      expect(find.text('直接发送'), findsOneWidget);
      expect(find.text('发送'), findsOneWidget, reason: '编辑后发送（原按钮保留）');
    });

    testWidgets('点"直接发送" → onConfirm 收到原字节（不经合成）并关闭', (tester) async {
      final bytes = (await tester.runAsync(() => makePng(120, 90)))!;
      Uint8List? confirmed;
      var composeCalled = false;
      await pumpEditor(
        tester,
        bytes,
        AnnotationController(),
        (b) => confirmed = b,
        compose: (b, ctrl) async {
          composeCalled = true;
          return Uint8List.fromList([...b, 0xAB]);
        },
      );

      await tester.tap(find.text('直接发送'));
      await tester.pumpAndSettle();

      expect(identical(confirmed, bytes), isTrue, reason: '原图直发（同实例）');
      expect(composeCalled, isFalse, reason: '不经合成管线');
      expect(find.text('直接发送'), findsNothing, reason: '发送后编辑器关闭');
    });
  });
}
