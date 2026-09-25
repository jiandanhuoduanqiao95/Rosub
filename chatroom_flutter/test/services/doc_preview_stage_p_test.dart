// ============================================================
// doc_preview.dart —— R-P9（文件预览扩展 docx/xlsx/pptx）契约
// ============================================================
// 用户二轮实测反馈：内嵌预览支持的文件类型不够多，起码要支持
// docx/xlsx/pptx/pdf。实现为纯 Dart 提取（archive 解包 OOXML），锁定：
//
//   extractDocumentPreview(path)：
//     - docx：word/document.xml 段落 `<w:t>` 游程，段间换行
//     - xlsx：sharedStrings + 各 sheet 单元格（t="s" 解共享串，
//       直值单元格原样），行格式 `A1: 值`
//     - pptx：slideN.xml（按页序），前 5 页，`—— 第 N 页 ——` 分隔
//     - 不支持扩展名 / 损坏文件 / 空文档 → null（不抛异常）
//
// R-P14（用户实测反馈）：**取消 PDF 预览**——FlateDecode 文本提取命中
// 率低，pdf 统一返回 null（预览对话框回退"打开文件"信息页）。
//
// 对话框级：showFilePreviewDialog 对 docx 显示提取文本（内嵌预览，
// 不再是"该类型暂不支持内嵌预览"）。
// ============================================================

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:io' as io;

import 'package:archive/archive.dart' hide ZLibDecoder;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/services/doc_preview.dart';
import 'package:chatroom_flutter/widgets/dialogs.dart';

Directory _tmp() => Directory.systemTemp.createTempSync('doc_preview_test');

void _write(String path, List<int> bytes) {
  File(path).writeAsBytesSync(bytes);
}

Uint8List _zip(Map<String, String> entries) {
  final archive = Archive();
  entries.forEach((name, content) {
    final data = Uint8List.fromList(utf8.encode(content));
    archive.addFile(ArchiveFile(name, data.length, data));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List _ascii(String s) => Uint8List.fromList(ascii.encode(s));

Future<void> pumpPreviewOpener(
  WidgetTester tester,
  void Function(BuildContext) open,
) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (ctx) => TextButton(
          onPressed: () => open(ctx),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('R-P9 —— extractDocumentPreview（docx）', () {
    test('提取段落文本，段间换行，XML 转义还原', () {
      final dir = _tmp();
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/report.docx';
      _write(
          path,
          _zip({
            '[Content_Types].xml': '<Types/>',
            'word/document.xml': '<w:document><w:body>'
                '<w:p><w:r><w:t>第一段标题</w:t></w:r></w:p>'
                '<w:p><w:r><w:t>A &amp; B &lt;tag&gt;</w:t></w:r></w:p>'
                '</w:body></w:document>',
          }));
      final text = extractDocumentPreview(path);
      expect(text, isNotNull);
      expect(text!, contains('Word 文档预览'));
      expect(text, contains('第一段标题'));
      expect(text, contains('A & B <tag>'));
      expect(text.indexOf('第一段标题'), lessThan(text.indexOf('A & B')),
          reason: '段落按顺序');
    });

    test('空文档/损坏 zip → null（不抛异常）', () {
      final dir = _tmp();
      addTearDown(() => dir.deleteSync(recursive: true));
      final empty = '${dir.path}/empty.docx';
      _write(
          empty,
          _zip({
            'word/document.xml': '<w:document><w:body></w:body></w:document>',
          }));
      expect(extractDocumentPreview(empty), isNull);

      final broken = '${dir.path}/broken.docx';
      _write(broken, [0x00, 0x01, 0x02, 0x03]);
      expect(extractDocumentPreview(broken), isNull);
    });
  });

  group('R-P9 —— extractDocumentPreview（xlsx）', () {
    test('共享字符串 + 直值单元格，行格式 A1: 值', () {
      final dir = _tmp();
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/book.xlsx';
      _write(
          path,
          _zip({
            'xl/sharedStrings.xml': '<sst><si><t>名称</t></si>'
                '<si><t>数量</t></si></sst>',
            'xl/worksheets/sheet1.xml': '<worksheet><sheetData>'
                '<row r="1"><c r="A1" t="s"><v>0</v></c>'
                '<c r="B1" t="s"><v>1</v></c></row>'
                '<row r="2"><c r="A2"><v>42</v></c>'
                '<c r="B2"><v>3.5</v></c></row>'
                '</sheetData></worksheet>',
          }));
      final text = extractDocumentPreview(path);
      expect(text, isNotNull);
      expect(text!, contains('Excel 表格预览'));
      expect(text, contains('A1: 名称'));
      expect(text, contains('B1: 数量'));
      expect(text, contains('A2: 42'));
      expect(text, contains('B2: 3.5'));
    });
  });

  group('R-P9 —— extractDocumentPreview（pptx）', () {
    test('按页序提取，页间分隔头，含页数上限说明', () {
      final dir = _tmp();
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/deck.pptx';
      _write(
          path,
          _zip({
            'ppt/slides/slide1.xml':
                '<p:sp><a:p><a:r><a:t>封面标题</a:t></a:r></a:p></p:sp>',
            'ppt/slides/slide2.xml':
                '<p:sp><a:p><a:r><a:t>第二页要点</a:t></a:r></a:p></p:sp>',
          }));
      final text = extractDocumentPreview(path);
      expect(text, isNotNull);
      expect(text!, contains('PPT 演示预览'));
      expect(text, contains('—— 第 1 页 ——'));
      expect(text, contains('封面标题'));
      expect(text, contains('—— 第 2 页 ——'));
      expect(text, contains('第二页要点'));
      expect(text.indexOf('第 1 页'), lessThan(text.indexOf('第 2 页')));
    });
  });

  group('R-P14 —— pdf 预览已取消', () {
    test('即使是可提取的 FlateDecode 文本流也返回 null（回退"打开文件"）', () {
      final dir = _tmp();
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/doc.pdf';
      const content = 'BT /F1 12 Tf 72 720 Td (Hello PDF) Tj 0 -20 Td '
          '(Second Line) Tj ET';
      final compressed = io.ZLibEncoder().convert(content.codeUnits);
      final buffer = BytesBuilder()
        ..add(_ascii('%PDF-1.4\n'))
        ..add(_ascii('1 0 obj\n<</Length ${compressed.length}>>\nstream\n'))
        ..add(compressed)
        ..add(_ascii('\nendstream\nendobj\n%%EOF\n'));
      _write(path, buffer.toBytes());

      expect(extractDocumentPreview(path), isNull);
    });
  });

  group('R-P9 —— 不支持的类型', () {
    test('doc/pdf 之外的扩展名（如 .zip/.doc）→ null', () {
      expect(extractDocumentPreview('/tmp/x.zip'), isNull);
      expect(extractDocumentPreview('/tmp/x.doc'), isNull);
      expect(extractDocumentPreview('/tmp/x.pdfx'), isNull);
    });
  });

  group('R-P9 —— 文件预览对话框（docx 内嵌预览）', () {
    testWidgets('docx 文件卡片点击 → 显示提取文本（非"暂不支持"）', (tester) async {
      final dir = _tmp();
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/report.docx';
      _write(
          path,
          _zip({
            'word/document.xml': '<w:document><w:body>'
                '<w:p><w:r><w:t>项目周报正文</w:t></w:r></w:p>'
                '</w:body></w:document>',
          }));

      await pumpPreviewOpener(
        tester,
        (ctx) => showFilePreviewDialog(ctx,
            filename: 'report.docx',
            path: path,
            filesize: 2048,
            sender: 'alice'),
      );

      expect(find.textContaining('Word 文档预览'), findsOneWidget,
          reason: 'docx 走内嵌文本预览');
      expect(find.textContaining('项目周报正文'), findsOneWidget);
      expect(find.text('该类型暂不支持内嵌预览'), findsNothing);
    });
  });
}
