// ============================================================
// opt8 test-infra —— generate_shots 出库函数（finalizeShots）单测
// ============================================================
// 复审实锤的时序缺陷回归：出库代码曾放在 testWidgets 注册之后的顶层
// 同步执行——干净 staging 永远空跑、残留 staging 会把旧图拷进
// SHOTS_OUT（甚至 tracked docs）。修复=出库收敛为 testWidgets 回调内
// 的 finalizeShots 调用；本文件用可控 fixture 单测出库语义 + 源码扫描
// 锁定调用时序（出库调用必须在 03_group 生成之后、回调之内）。
//
// fixture 策略（零栅格化——flutter_test 环境下 Picture.toImage 会挂起）：
// 有效图 = 仓库 HEAD 的 docs/screenshots 三张真实 1920x1200 渲染
// （**只读引用**，绝不写回）；占位块 = 12,256 字节数据（复现写坏 docs
// 的同签名形态，validateShot 的体积检查先行拒绝）。
//
// 说明：完整生成路径（真机服务器 + 截图账号 + 真实数据）当前环境无
// 截图账号，未执行——见交付报告"未验证项"；本文件证明的是出库函数
// 本身的契约与时序结构。
// ============================================================

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'generate_shots_test.dart' show finalizeShots, validateShot;

const _docsDir = '../docs/screenshots';
const _requiredShots = ['01_login.png', '02_main.png', '03_group.png'];

String srcOf(String relPath) => File(relPath).readAsStringSync();

int countOf(String source, String needle) => source.split(needle).length - 1;

/// 从 HEAD 恢复后的 tracked 文档截图（只读引用作 fixture——真实
/// 1920x1200 渲染，>50KB，非纯色；**绝不写回 docs**）
void placeValidFixture(Directory stage, String name) {
  final src = File('$_docsDir${Platform.pathSeparator}$name');
  final bytes = src.readAsBytesSync();
  File('${stage.path}${Platform.pathSeparator}$name')
      .writeAsBytesSync(bytes);
}

/// 写坏文档同签名的占位块（12,256 字节——validateShot 体积检查先行拒绝）
void placePlaceholder(Directory stage, String name) {
  final garbage = Uint8List(12256);
  File('${stage.path}${Platform.pathSeparator}$name')
      .writeAsBytesSync(garbage);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('validateShot：真实 1920x1200 文档截图通过（尺寸/体积/非纯色）',
      (tester) async {
    final stage = Directory.systemTemp.createTempSync('shots_fin');
    addTearDown(() => stage.deleteSync(recursive: true));
    placeValidFixture(stage, '01_login.png');
    final f = File('${stage.path}/01_login.png');
    expect(f.lengthSync(), greaterThan(50 * 1024),
        reason: '真实 README 截图远超 50KB');
    await tester.runAsync(() => validateShot(f, '01_login.png'));
    expect(f.existsSync(), isTrue, reason: '通过校验不删文件');
  });

  testWidgets('validateShot：12,256B 占位块被拒并删除（写坏文档同源复现）',
      (tester) async {
    final stage = Directory.systemTemp.createTempSync('shots_fin');
    addTearDown(() => stage.deleteSync(recursive: true));
    placePlaceholder(stage, '02_main.png');
    final f = File('${stage.path}/02_main.png');
    expect(f.lengthSync(), 12256);

    Object? caught;
    await tester.runAsync(() async {
      try {
        await validateShot(f, '02_main.png');
      } catch (e) {
        caught = e;
      }
    });
    expect(caught, isA<StateError>());
    expect((caught as StateError).message, contains('50KB'));
    expect(f.existsSync(), isFalse, reason: '被拒产物必须删除');
  });

  testWidgets('finalizeShots：三张齐备 + 未设 SHOTS_OUT → 仅留暂存区',
      (tester) async {
    final stage = Directory.systemTemp.createTempSync('shots_stage');
    final logs = <String>[];
    addTearDown(() => stage.deleteSync(recursive: true));
    for (final name in _requiredShots) {
      placeValidFixture(stage, name);
    }

    await tester.runAsync(() => finalizeShots(
        stageDir: stage, finalOutDir: null, log: logs.add));

    expect(logs.any((m) => m.contains('未设置 SHOTS_OUT')), isTrue);
    for (final name in _requiredShots) {
      expect(File('${stage.path}/$name').existsSync(), isTrue,
          reason: '$name 留在暂存区');
    }
  });

  testWidgets('finalizeShots：SHOTS_OUT 指向 docs → 拷出 + 人工审阅提醒',
      (tester) async {
    final stage = Directory.systemTemp.createTempSync('shots_stage');
    final out = Directory.systemTemp.createTempSync('shots_out_docs');
    // 模拟 tracked docs 落点：<out>/docs/screenshots
    final docsOut = '${out.path}${Platform.pathSeparator}docs'
        '${Platform.pathSeparator}screenshots';
    final logs = <String>[];
    addTearDown(() => out.deleteSync(recursive: true));
    addTearDown(() => stage.deleteSync(recursive: true));
    for (final name in _requiredShots) {
      placeValidFixture(stage, name);
    }

    await tester.runAsync(() => finalizeShots(
        stageDir: stage, finalOutDir: docsOut, log: logs.add));

    for (final name in _requiredShots) {
      expect(File('$docsOut${Platform.pathSeparator}$name').existsSync(),
          isTrue, reason: '$name 应拷出到目标目录');
    }
    expect(logs.any((m) => m.contains('tracked 文档目录')), isTrue,
        reason: '写往 docs/screenshots 必须打印人工审阅提醒');
    expect(logs.any((m) => m.contains(docsOut)), isTrue,
        reason: '打印解析后的绝对路径');
  });

  testWidgets('finalizeShots：缺少固定三张之一 → 抛错不出库', (tester) async {
    final stage = Directory.systemTemp.createTempSync('shots_stage');
    final logs = <String>[];
    addTearDown(() => stage.deleteSync(recursive: true));
    placeValidFixture(stage, '01_login.png');
    placeValidFixture(stage, '03_group.png'); // 缺 02_main

    Object? caught;
    await tester.runAsync(() async {
      try {
        await finalizeShots(stageDir: stage, finalOutDir: null, log: logs.add);
      } catch (e) {
        caught = e;
      }
    });
    expect(caught, isA<StateError>());
    expect((caught as StateError).message, contains('02_main.png'));
    expect(logs.any((m) => m.contains('已写入')), isFalse,
        reason: '校验失败绝不出库');
  });

  testWidgets('finalizeShots：多余暂存文件清理（staging 只留固定三张）',
      (tester) async {
    final stage = Directory.systemTemp.createTempSync('shots_stage');
    final logs = <String>[];
    addTearDown(() => stage.deleteSync(recursive: true));
    for (final name in _requiredShots) {
      placeValidFixture(stage, name);
    }
    // 上次运行残留的旧图（防被拷进 SHOTS_OUT 写坏文档）
    File('${stage.path}/04_stale.png').writeAsBytesSync(Uint8List(2048));

    await tester.runAsync(() => finalizeShots(
        stageDir: stage, finalOutDir: null, log: logs.add));

    expect(File('${stage.path}/04_stale.png').existsSync(), isFalse,
        reason: '残留文件出库前清理');
    expect(logs.any((m) => m.contains('清理多余暂存文件')), isTrue);
  });

  testWidgets('finalizeShots：两张字节雷同 → 抛错不出库（02/03 同 hash '
      '写坏文档的回归）', (tester) async {
    final stage = Directory.systemTemp.createTempSync('shots_stage');
    addTearDown(() => stage.deleteSync(recursive: true));
    placeValidFixture(stage, '01_login.png');
    final same = File('$_docsDir/02_main.png').readAsBytesSync();
    // 用同一字节冒充 02/03（同屏渲染异常的形态）
    File('${stage.path}/02_main.png').writeAsBytesSync(same);
    File('${stage.path}/03_group.png').writeAsBytesSync(same);

    Object? caught;
    await tester.runAsync(() async {
      try {
        await finalizeShots(stageDir: stage, finalOutDir: null, log: (_) {});
      } catch (e) {
        caught = e;
      }
    });
    expect(caught, isA<StateError>());
    expect((caught as StateError).message, contains('字节雷同'));
  });

  test('出库时序（源码锁定，结构级）：花括号配对提取回调体——出库调用'
      '必须在回调体内、03_group 之后、经 runAsync 封装；回调体之后不得'
      '再有出库/收尾代码；staging 清空重建 + 数据断言在位', () {
    final src = srcOf('test/screenshots/generate_shots_test.dart');

    // ① 封装函数存在，且内部**必须**同时含 runAsync 与 finalizeShots
    //   （结构性禁止"裸 await finalizeShots"——fake async 区图像解码/
    //   异步 IO 不完成，单测包了 runAsync 而真实路径曾漏包）
    final helperStart = src.indexOf('Future<void> _finalizeInsideTest');
    final mainStart = src.indexOf('Future<void> main()');
    expect(helperStart, greaterThanOrEqualTo(0), reason: '封装函数存在');
    expect(mainStart, greaterThan(helperStart));
    final helperBody = src.substring(helperStart, mainStart);
    expect(helperBody, contains('tester.runAsync'),
        reason: 'finalizeShots 必须在 runAsync 真实异步上下文执行');
    expect(helperBody, contains('await finalizeShots('),
        reason: '封装内调用出库');

    // ② 全文件唯一一次 finalizeShots 调用就在封装内（顶层/回调内裸
    //   调用都被此断言禁止）
    expect(countOf(src, 'await finalizeShots('), 1,
        reason: '唯一调用点必须在 _finalizeInsideTest 内');

    // ③ 花括号配对提取 testWidgets 回调体（字符串插值括号自平衡，
    //   朴素深度计数可靠）——出库调用必须在回调体内
    final twMarker = src.indexOf("testWidgets('README 截图采集'");
    expect(twMarker, greaterThan(mainStart), reason: '注册在封装定义之后');
    final bodyStart = src.indexOf('{', twMarker);
    var depth = 0;
    var bodyEnd = -1;
    for (var i = bodyStart; i < src.length; i++) {
      final ch = src[i];
      if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) {
          bodyEnd = i;
          break;
        }
      }
    }
    expect(bodyEnd, greaterThan(bodyStart), reason: '回调体配对成功');
    final callbackBody = src.substring(bodyStart, bodyEnd + 1);

    // ④ 出库调用在回调体内：恰一次、为封装调用、位于 03_group 之后；
    //   回调体内不得裸调 finalizeShots（必须经封装走 runAsync）
    expect(countOf(callbackBody, 'await _finalizeInsideTest(tester, svc);'),
        1, reason: '回调内出库调用恰一次');
    final shoot03 = callbackBody.indexOf("await _shoot('03_group'");
    final callSite =
        callbackBody.indexOf('await _finalizeInsideTest(tester, svc);');
    expect(shoot03, greaterThan(0));
    expect(callSite, greaterThan(shoot03),
        reason: '出库在三张全部生成之后');
    expect(callbackBody.contains('await finalizeShots('), isFalse,
        reason: '回调体内不得裸调 finalizeShots（必须经封装走 runAsync）');

    // ⑤ 回调体之后（文件剩余部分）不得再有任何出库/收尾代码——
    //   旧"注册后顶层出库"形态在此必红
    final after = src.substring(bodyEnd + 1);
    expect(after.contains('finalizeShots'), isFalse,
        reason: '顶层出库（注册后同步执行）在此必红');
    expect(after.contains('_finalizeInsideTest'), isFalse);
    expect(after.contains('disconnect'), isFalse,
        reason: '服务器断开应已并入封装（勿双份收尾）');

    // ⑥ staging 生成前清空重建（勿复用残留文件）
    expect(src, contains('deleteSync(recursive: true)'),
        reason: 'staging 清空重建');

    // ⑦ 数据断言仍在（防空页面被当有效图）——在回调体内
    expect(callbackBody, contains('expect(msgs, isNotEmpty'),
        reason: 'blue 会话数据断言');
    expect(callbackBody, contains("getMessages('group_1'"),
        reason: '群会话数据断言');

    // ⑧ 文件头 opt-in 示例指向仓库根 docs（相对包根）
    expect(src, contains('SHOTS_OUT=../docs/screenshots'),
        reason: '头部示例 = ../docs/screenshots（相对包根解析到仓库根）');
  });
}
