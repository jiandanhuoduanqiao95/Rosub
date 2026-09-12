// ============================================================
// dialogs.dart 阶段 Q1 —— 真机手动测试反馈修复契约
// ============================================================
// 反馈 #4（文件名过长影响观感）：文件请求对话框条目的文件名
// maxLines=2 + ellipsis——不再逐字折行撑爆对话框（竖屏手机
// 《绝区零》× ZOZOTOWN 长文件名实测场景）。
//
// 反馈 #6（对话框全屏化补充锁定）：compact 下 showResponsiveDialog
// 打开的 AlertDialog 本体铺满整屏——AlertDialog 内层 Dialog 的
// 渲染盒（视觉卡片）= surface 尺寸（原 minWidth 280 居中小卡片
// 的根因回归锁定）。
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/widgets/dialogs.dart';
import 'package:chatroom_flutter/widgets/responsive_layout.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Q1 反馈 #4 —— 文件请求文件名过长省略', () {
    testWidgets('长文件名 maxLines=2 + ellipsis（不逐字折行）', (tester) async {
      const longName = '《绝区零》×ZOZOTOWN 联动PV【4K慢放】绝区零零号安比德玛拉竞坦重锤演出.mp4';
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () => showFileRequestsDialog(
                  ctx,
                  [
                    FileRequest(
                      messageId: 'f1',
                      sender: 'alice',
                      filename: longName,
                      filesize: 21 * 1024 * 1024,
                    ),
                  ],
                  (_, __) {},
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final nameFinder = find.text(longName);
      expect(nameFinder, findsOneWidget);
      final text = tester.widget<Text>(nameFinder);
      expect(text.maxLines, 2, reason: '长文件名最多两行');
      expect(text.overflow, TextOverflow.ellipsis, reason: '超出省略');
      expect(tester.takeException(), isNull, reason: '窄视口不溢出');
    });
  });

  group('Q1 反馈 #6 —— compact 对话框本体铺满（AlertDialog 内层盒）', () {
    testWidgets('599 宽：AlertDialog 视觉卡片 = surface（非居中小卡片）', (tester) async {
      await tester.binding.setSurfaceSize(const Size(599, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () => showResponsiveDialog<void>(
                  context: ctx,
                  builder: (dctx) => AlertDialog(
                    title: const Text('Q1FULL'),
                    content: const Text('内容区'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dctx),
                          child: const Text('关闭')),
                    ],
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // AlertDialog 会再包一层内层 Dialog——取最后一个（最内层），
      // 其渲染盒应铺满 surface（标题置顶/按钮沉底由 AlertDialog 排布）
      final dialogs = find.byType(Dialog);
      expect(dialogs, findsAtLeastNWidgets(2),
          reason: '外层 Dialog.fullscreen + AlertDialog 内层 Dialog');
      final inner = tester.getSize(dialogs.last);
      expect(inner, const Size(599, 800),
          reason: 'AlertDialog 本体铺满整屏（反馈 #6：不再整块灰屏中间小白卡片）');
      expect(find.text('Q1FULL'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
