/// 本地消息缓存门面（阶段 L3，P0-4）
///
/// 包装 [MessageCacheStore]，为客户端提供"启动先渲染再增量同步"与"离线可读"：
///   - [persist]：AppState 收到/发出任何消息时落盘（按 message_id 去重）；
///   - [restoreAll]：登录后把缓存历史合并进 AppState（去重 + 时间排序）；
///   - [clear]：退出登录清空缓存（防跨账号数据泄漏）。
///
/// 未初始化（_store == null，如单元测试环境）时全部方法为安全 no-op，不影响
/// 既有测试。初始化仅在生产入口（main.dart）进行。

import '../models/chat_models.dart';
import 'message_cache_store.dart';
import 'state_manager.dart';

class MessageCache {
  static MessageCacheStore? _store;

  static MessageCacheStore? get store => _store;

  static bool get enabled => _store != null && _store!.isOpen;

  /// 初始化本地缓存（生产入口调用；[dbPath] 注入便于测试）。
  /// 幂等：已初始化则忽略。
  static Future<void> init({String? dbPath}) async {
    if (_store != null && _store!.isOpen) return;
    final s = MessageCacheStore();
    await s.init(dbPath: dbPath);
    _store = s;
  }

  /// 落盘一条消息（未初始化/空 messageId/异常时安全跳过）
  static Future<void> persist(String chatKey, ChatMessage msg) async {
    final s = _store;
    if (s == null || !s.isOpen || msg.messageId.isEmpty) return;
    try {
      await s.upsertMessage(chatKey, msg);
    } catch (_) {
      // 缓存失败不影响消息收发（尽力而为）
    }
  }

  /// 登录后把缓存历史合并进 AppState（按 message_id 去重 + 时间排序），
  /// 实现"启动先渲染本地、再与服务端增量同步"。
  static Future<void> restoreAll() async {
    final s = _store;
    if (s == null || !s.isOpen) return;
    try {
      final convs = await s.conversations();
      for (final chatKey in convs) {
        final msgs = await s.loadRecentMessages(chatKey, limit: 200);
        if (msgs.isNotEmpty) {
          AppState.instance.prependHistoryMessages(chatKey, msgs);
        }
      }
    } catch (_) {
      // 恢复失败不影响登录（尽力而为）
    }
  }

  /// 退出登录清空缓存（防跨账号数据泄漏）
  static Future<void> clear() async {
    final s = _store;
    if (s == null || !s.isOpen) return;
    try {
      await s.clearAll();
    } catch (_) {}
  }
}
