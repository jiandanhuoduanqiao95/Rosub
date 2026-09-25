/// 文档内嵌文本预览（R-P9：文件预览支持 docx/xlsx/pptx）
///
/// 纯 Dart 实现（零原生依赖）：
/// docx/xlsx/pptx：OOXML 即 ZIP+XML，经 archive 解包后用正则提取
/// 文本游程（docx: word/document.xml `<w:t>`；xlsx: sharedStrings +
/// 各 sheet 单元格；pptx: slideN.xml `<a:t>`）。
///
/// R-P14（用户实测反馈）：**取消 PDF 预览**——FlateDecode 内容流的文本
/// 提取对加密/图片型/CID 字体文档命中率低（"尽力而为"体验差），pdf 统一
/// 回退预览对话框的"打开文件"信息页。
///
/// 所有输出截断至 ~8000 字符；提取失败/扩展名不支持 → null。

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

const int _maxPreviewChars = 8000;

/// 按扩展名分派的预览文本提取；不支持/失败 → null
String? extractDocumentPreview(String path) {
  final lower = path.toLowerCase();
  try {
    if (lower.endsWith('.docx')) {
      return _previewDocx(path);
    }
    if (lower.endsWith('.xlsx')) {
      return _previewXlsx(path);
    }
    if (lower.endsWith('.pptx')) {
      return _previewPptx(path);
    }
  } catch (_) {
    return null;
  }
  return null;
}

// ============================================================
// OOXML（docx/xlsx/pptx）
// ============================================================

String? _readZipEntry(Archive archive, String name) {
  final file = archive.files.where((f) => f.name == name).firstOrNull;
  if (file == null) return null;
  return utf8.decode(file.content, allowMalformed: true);
}

List<String> _readZipEntriesMatching(Archive archive, RegExp pattern) {
  final names =
      archive.files.map((f) => f.name).where(pattern.hasMatch).toList()..sort();
  return [
    for (final name in names)
      utf8.decode(archive.files.where((f) => f.name == name).first.content,
          allowMalformed: true)
  ];
}

/// XML 转义还原（文档内容常见五种 + 数字实体）
String _xmlUnescape(String s) {
  return s
      .replaceAllMapped(RegExp(r'&#x([0-9A-Fa-f]+);'),
          (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)))
      .replaceAllMapped(RegExp(r'&#(\d+);'),
          (m) => String.fromCharCode(int.parse(m.group(1)!)))
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
}

/// 提取一类文本元素的内容（如 `<w:t...>text</w:t>`）
String _joinTextElements(String xml, RegExp elementPattern) {
  final buffer = StringBuffer();
  for (final m in elementPattern.allMatches(xml)) {
    buffer.write(_xmlUnescape(m.group(1) ?? ''));
  }
  return buffer.toString();
}

/// 按段落切分后提取段落内文本（paragraphPattern 捕获段落体）
String _joinParagraphs(String xml, RegExp paragraphPattern, RegExp runPattern) {
  final lines = <String>[];
  for (final m in paragraphPattern.allMatches(xml)) {
    final line = _joinTextElements(m.group(1) ?? '', runPattern);
    if (line.trim().isNotEmpty) lines.add(line);
  }
  return lines.join('\n');
}

String _clip(String header, String body) {
  final clipped = body.length > _maxPreviewChars
      ? '${body.substring(0, _maxPreviewChars)}\n…（已截断）'
      : body;
  return '$header\n$clipped';
}

String? _previewDocx(String path) {
  final archive = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
  final xml = _readZipEntry(archive, 'word/document.xml');
  if (xml == null) return null;
  final body = _joinParagraphs(
    xml,
    RegExp(r'<w:p\b[^>]*>(.*?)</w:p>', dotAll: true),
    RegExp(r'<w:t\b[^>]*>(.*?)</w:t>', dotAll: true),
  );
  if (body.trim().isEmpty) return null;
  return _clip('【Word 文档预览（docx）】', body);
}

String? _previewPptx(String path) {
  final archive = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
  final slides = _readZipEntriesMatching(
    archive,
    RegExp(r'^ppt/slides/slide\d+\.xml$'),
  );
  if (slides.isEmpty) return null;
  final buffer = StringBuffer();
  for (var i = 0; i < slides.length && i < 5; i++) {
    if (buffer.isNotEmpty) buffer.write('\n');
    buffer.write('—— 第 ${i + 1} 页 ——\n');
    buffer.write(_joinParagraphs(
      slides[i],
      RegExp(r'<a:p\b[^>]*>(.*?)</a:p>', dotAll: true),
      RegExp(r'<a:t\b[^>]*>(.*?)</a:t>', dotAll: true),
    ));
  }
  if (slides.length > 5) buffer.write('\n…（其余 ${slides.length - 5} 页略）');
  final text = buffer.toString();
  if (text.trim().isEmpty) return null;
  return _clip('【PPT 演示预览（pptx，前 5 页文本）】', text);
}

String? _previewXlsx(String path) {
  final archive = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
  final sharedRaw = _readZipEntry(archive, 'xl/sharedStrings.xml');
  final shared = <String>[];
  if (sharedRaw != null) {
    for (final m in RegExp(r'<si\b[^>]*>(.*?)</si>', dotAll: true)
        .allMatches(sharedRaw)) {
      shared.add(_joinTextElements(
          m.group(1) ?? '', RegExp(r'<t\b[^>]*>(.*?)</t>', dotAll: true)));
    }
  }
  final sheets = _readZipEntriesMatching(
    archive,
    RegExp(r'^xl/worksheets/sheet\d+\.xml$'),
  );
  if (sheets.isEmpty) return null;
  final buffer = StringBuffer();
  var rowsShown = 0;
  for (final sheet in sheets) {
    if (rowsShown >= 50) break;
    for (final row
        in RegExp(r'<row\b[^>]*>(.*?)</row>', dotAll: true).allMatches(sheet)) {
      if (rowsShown >= 50) break;
      final cells = <String>[];
      for (final cell in RegExp(
        r'<c\b[^>]*/>|<c\b[^>]*>.*?</c>',
        dotAll: true,
      ).allMatches(row.group(1) ?? '')) {
        final cellXml = cell.group(0)!;
        final ref =
            RegExp(r'r="([A-Z]+\d+)"').firstMatch(cellXml)?.group(1) ?? '';
        final value = _cellValue(cellXml, shared);
        if (value.isNotEmpty) cells.add('$ref: $value');
      }
      if (cells.isNotEmpty) {
        buffer.write(cells.join('    '));
        buffer.write('\n');
        rowsShown++;
      }
    }
  }
  final text = buffer.toString().trim();
  if (text.isEmpty) return null;
  return _clip('【Excel 表格预览（xlsx，前 50 行）】', text);
}

String _cellValue(String cellXml, List<String> shared) {
  final type = RegExp(r'\bt="(\w+)"').firstMatch(cellXml)?.group(1) ?? '';
  if (type == 'inlineStr') {
    return _joinTextElements(
        cellXml, RegExp(r'<t\b[^>]*>(.*?)</t>', dotAll: true));
  }
  final v = RegExp(r'<v\b[^>]*>(.*?)</v>', dotAll: true)
      .firstMatch(cellXml)
      ?.group(1);
  if (v == null) return '';
  if (type == 's') {
    final idx = int.tryParse(v.trim());
    return (idx != null && idx >= 0 && idx < shared.length) ? shared[idx] : '';
  }
  return _xmlUnescape(v);
}
