/// 本地消息缓存门面（阶段 L3，P0-4）
///
/// 包装 [MessageCacheStore]，为客户端提供"启动先渲染再增量同步"与"离线可读"：
///   - [persist]：AppState 收到/发出任何消息时落盘（按 message_id 去重）；
///   - [restoreAll]：登录后把缓存历史合并进 AppState（去重 + 时间排序）；
///   - [clear]：退出登录清空缓存（防跨账号数据泄漏）。
///
/// 全部写操作经静态写队列 [_writeTail] 串行化（opt8 #6/#8 修复）：SQLite
/// 异步并发写与删除交错时可能出现"后写入覆盖先删除"的复活竞态，队列保证
/// 同一时刻只有一个写任务在途、按入队顺序执行。
///
/// 未初始化（_store == null，如单元测试环境）时全部方法为安全 no-op，不影响
/// 既有测试。初始化仅在生产入口（main.dart）进行。

import '../models/chat_models.dart';
import 'message_cache_store.dart';
import 'state_manager.dart';

class MessageCache {
  static MessageCacheStore? _store;
  static Future<void> _writeTail = Future.value();

  static MessageCacheStore? get store => _store;

  static bool get enabled => _store != null && _store!.isOpen;

  /// 初始化本地缓存（生产入口调用；[dbPath] 注入便于测试）。
  /// 幂等：已初始化则忽略。
  static Future<void> init({String? dbPath}) async {
    if (_store != null && _store!.isOpen) return;
    final s = MessageCacheStore();
    await s.init(dbPath: dbPath);
    _store = s;
    _writeTail = Future.value();
  }

  /// 落盘一条消息（未初始化/空 messageId/异常时安全跳过）
  static Future<void> persist(String chatKey, ChatMessage msg) {
    final s = _store;
    if (s == null || !s.isOpen || msg.messageId.isEmpty) {
      return Future.value();
    }
    final task = _writeTail
        .then((_) => s.upsertMessage(chatKey, msg))
        .catchError((Object _) {});
    _writeTail = task;
    return task;
  }

  /// 移除一条消息（永久删除/公告删除；与写队列串行避免复活竞态）
  static Future<void> removeMessage(String chatKey, String messageId) {
    final s = _store;
    if (s == null || !s.isOpen) return Future.value();
    final task = _writeTail
        .then((_) => s.removeMessage(chatKey, messageId))
        .catchError((Object _) {});
    _writeTail = task;
    return task;
  }

  /// 清空某会话全部缓存消息（会话移除时调用）
  static Future<void> clearConversation(String chatKey) {
    final s = _store;
    if (s == null || !s.isOpen) return Future.value();
    final task = _writeTail
        .then((_) => s.clearConversation(chatKey))
        .catchError((Object _) {});
    _writeTail = task;
    return task;
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
  static Future<void> clear() {
    final s = _store;
    if (s == null || !s.isOpen) return Future.value();
    final task = _writeTail.then((_) => s.clearAll()).catchError((Object _) {});
    _writeTail = task;
    return task;
  }

  /// 等待全部已入队写任务完成（测试同步用）
  static Future<void> flush() => _writeTail;

  /// 测试重置：关闭并清空 store、重置写队列（生产代码不得调用）
  static Future<void> resetForTest() async {
    final s = _store;
    _store = null;
    _writeTail = Future.value();
    await s?.close();
  }
}
