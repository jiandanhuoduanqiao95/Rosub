/// 附件文件名安全工具（opt8 #13）
///
/// [sanitizeFilename]：显示/落盘安全名——取 basename 去路径分隔符防穿越，
/// 空 / "." / ".." 回退 received_file。
/// [sanitizeStorageComponent]：路径组件净化——非法字符替换为下划线
/// （保留 [A-Za-z0-9_-]），空串返回空串；替换会引入形变，调用方
/// （receivedAttachmentPath）对形变结果追加快照哈希防碰撞。

String sanitizeFilename(String filename) {
  final base = filename.split(RegExp(r'[/\\]')).last;
  if (base.isEmpty || base == '.' || base == '..') {
    return 'received_file';
  }
  return base;
}

final RegExp _unsafeStorageChars = RegExp(r'[^A-Za-z0-9_-]');

String sanitizeStorageComponent(String component) {
  return component.replaceAll(_unsafeStorageChars, '_');
}
