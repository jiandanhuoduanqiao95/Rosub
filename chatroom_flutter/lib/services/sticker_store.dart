/// 表情包本地存储（阶段 P2；R-P3 修订：扁平"我的表情包"）
///
/// 自定义表情（Sticker，PNG 图片）本地管理：贴纸字节落盘
/// `<baseDir>/<stickerId>.png`，清单（JSON 数组）存 shared_preferences
/// 键 `stickers`（绑定账号时 `<user>.stickers`，与 O7 键前缀惯例一致）。
/// 不再区分包名——向微信"我的表情"看齐，展示为单一扁平网格。
///
/// 无内存缓存（每次读写存储，仿 QuickReplyStore 惯例）；未 init 时读取
/// 安全返回空、写入安全 no-op。贴纸发送复用 N3 图片通道（sendFileBytes），
/// 协议零改动。

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_models.dart';

class StickerStore {
  StickerStore._();

  static final StickerStore instance = StickerStore._();

  static const String _kStickers = 'stickers';

  String _user = '';
  String? _baseDir;

  /// 注入贴纸落盘目录（生产入口 main() 调用；测试用临时目录）。幂等。
  /// R-P11：注入后同步确保目录存在（否则首张贴纸写入抛异常被吞，
  /// 表现为"添加无反应"）。
  Future<void> init({String? baseDir}) async {
    if (baseDir != null) _baseDir = baseDir;
    final dir = _dir;
    if (dir != null) {
      try {
        Directory(dir).createSync(recursive: true);
      } catch (_) {}
    }
  }

  /// 绑定账号（登录/登出路径调用）：键切换为 "<username>.stickers"；
  /// username 为 null 时回退全局默认键。
  Future<void> bindUser(String? username) async {
    _user = username ?? '';
  }

  String get _key => _user.isEmpty ? _kStickers : '$_user.$_kStickers';

  String? get _dir {
    final dir = _baseDir;
    if (dir == null || dir.isEmpty) return null;
    return dir;
  }

  String _newId() =>
      '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(999999)}';

  Future<List<Sticker>> loadStickers() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((e) => Sticker.fromJson(e.cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _saveStickers(List<Sticker> stickers) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode([for (final s in stickers) s.toJson()]),
    );
  }

  /// 添加贴纸（R-P3：无包概念；isSupportedImage 魔数校验，非法字节/
  /// 未 init → null）。成功返回 Sticker（name 形如 sticker_<id>.png，
  /// 接收端按图片消息内联展示）。
  Future<Sticker?> addSticker(Uint8List bytes) async {
    final dir = _dir;
    if (dir == null) return null;
    if (!isSupportedImage(bytes)) return null;
    final id = _newId();
    final sticker = Sticker(id: id, name: 'sticker_$id.png');
    try {
      // 同步落盘：贴纸为小图，与 removeSticker 的 deleteSync 保持一致
      File('$dir/$id.png').writeAsBytesSync(bytes);
    } catch (_) {
      return null;
    }
    final stickers = await loadStickers();
    await _saveStickers([...stickers, sticker]);
    return sticker;
  }

  /// 移除贴纸（清单 + 磁盘文件同步删除；不存在时幂等）
  Future<void> removeSticker(String stickerId) async {
    final stickers = await loadStickers();
    if (!stickers.any((s) => s.id == stickerId)) return;
    _deleteFile(stickerId);
    await _saveStickers(stickers.where((s) => s.id != stickerId).toList());
  }

  /// 读取贴纸字节；未知/未 init → null
  Uint8List? stickerBytes(String stickerId) {
    final dir = _dir;
    if (dir == null) return null;
    try {
      final file = File('$dir/$stickerId.png');
      if (!file.existsSync()) return null;
      return file.readAsBytesSync();
    } catch (_) {
      return null;
    }
  }

  void _deleteFile(String stickerId) {
    final dir = _dir;
    if (dir == null) return;
    try {
      File('$dir/$stickerId.png').deleteSync();
    } catch (_) {}
  }
}
