/// 全局应用状态管理器
///
/// 使用 ChangeNotifier 模式，所有 UI 组件通过监听此对象获取状态更新。
/// 单例模式，通过 AppState.instance 访问。

import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../models/chat_models.dart';
import 'message_cache.dart';

class AppState extends ChangeNotifier {
  AppState._();
  static final AppState _instance = AppState._();
  static AppState get instance => _instance;

  // ---- 连接状态 ----
  ConnectionStatus _connectionStatus = ConnectionStatus.disconnected;
  ConnectionStatus get connectionStatus => _connectionStatus;

  // ---- 重连计数（仅 reconnecting 状态下有意义）----
  int _reconnectAttempts = 0;
  int get reconnectAttempts => _reconnectAttempts;

  // ---- 用户信息 ----
  String? _username;
  String? get username => _username;
  bool get isLoggedIn => _username != null;
  bool _isAdmin = false;
  bool get isAdmin => _isAdmin;

  // ---- 好友列表 ----
  final List<String> _friends = [];
  UnmodifiableListView<String> get friends => UnmodifiableListView(_friends);

  // ---- 待处理好友请求 ----
  final List<String> _pendingRequests = [];
  UnmodifiableListView<String> get pendingRequests =>
      UnmodifiableListView(_pendingRequests);

  // ---- 好友请求验证消息（阶段 J：P1-10）----
  final Map<String, String> _pendingRequestMessages = {};

  /// 某请求来源的验证消息；未设置返回 null
  String? pendingRequestMessageOf(String username) =>
      _pendingRequestMessages[username];

  // ---- 发送好友请求时预填的备注名（阶段 J 修复）----
  // 发送请求时可询问是否给对方取备注名；备注暂存于此，
  // 待对方接受请求（出现在好友列表）后由 SocketService 自动设置为备注名。
  final Map<String, String> _pendingFriendNotes = {};

  void setPendingFriendNote(String username, String note) {
    if (note.isEmpty) return;
    _pendingFriendNotes[username] = note;
  }

  /// 某用户的待应用备注名；未设置返回 null
  String? pendingFriendNoteOf(String username) => _pendingFriendNotes[username];

  /// 取出并移除某用户的待应用备注（好友关系建立后消费一次）
  String? takePendingFriendNote(String username) =>
      _pendingFriendNotes.remove(username);

  // ---- 在线状态（阶段 J：P0-3）----
  final Set<String> _onlineUsers = {};
  UnmodifiableSetView<String> get onlineUsers =>
      UnmodifiableSetView(_onlineUsers);

  bool isOnline(String username) => _onlineUsers.contains(username);

  /// 整体替换在线集合
  void setOnlineUsers(Iterable<String> users) {
    _onlineUsers
      ..clear()
      ..addAll(users);
    notifyListeners();
  }

  /// 更新单用户在线状态（幂等）
  void updatePresence(String username, bool online) {
    if (username.isEmpty) return;
    if (online) {
      if (_onlineUsers.add(username)) notifyListeners();
    } else {
      if (_onlineUsers.remove(username)) notifyListeners();
    }
  }

  // ---- 用户资料缓存（阶段 J：P0-2）----
  final Map<String, UserProfile> _profiles = {};

  UserProfile? profileOf(String username) => _profiles[username];

  void updateProfile(UserProfile profile) {
    _profiles[profile.username] = profile;
    notifyListeners();
  }

  // ---- 好友备注/分组（阶段 J：P1-8）----
  static const String ungroupedLabel = '未分组';

  final Map<String, FriendMeta> _friendMeta = {};

  FriendMeta? friendMetaOf(String username) => _friendMeta[username];
  String? friendNoteOf(String username) => _friendMeta[username]?.note;
  String? friendGroupOf(String username) => _friendMeta[username]?.groupName;

  /// 部分更新备注/分组（未传字段保持原值）
  void updateFriendMeta(String username, {String? note, String? groupName}) {
    final current = _friendMeta[username] ?? FriendMeta(username: username);
    _friendMeta[username] = FriendMeta(
      username: username,
      note: note ?? current.note,
      groupName: groupName ?? current.groupName,
    );
    notifyListeners();
  }

  /// 批量替换好友元数据（list_friends_meta 响应）
  void setFriendMetaList(List<FriendMeta> metas) {
    _friendMeta.clear();
    for (final m in metas) {
      _friendMeta[m.username] = m;
    }
    notifyListeners();
  }

  /// 分组视图：分组名 → 好友用户名列表（空分组归"未分组"）
  Map<String, List<String>> get friendsByGroup {
    final result = <String, List<String>>{};
    for (final meta in _friendMeta.values) {
      final key = meta.groupName.isEmpty ? ungroupedLabel : meta.groupName;
      result.putIfAbsent(key, () => []).add(meta.username);
    }
    return result;
  }

  // ---- 黑名单（阶段 J：P1-9）----
  final Set<String> _blockedUsers = {};
  UnmodifiableSetView<String> get blockedUsers =>
      UnmodifiableSetView(_blockedUsers);

  bool isBlocked(String username) => _blockedUsers.contains(username);

  void addBlockedUser(String username) {
    if (_blockedUsers.add(username)) notifyListeners();
  }

  void removeBlockedUser(String username) {
    if (_blockedUsers.remove(username)) notifyListeners();
  }

  /// 批量替换黑名单（list_blocked 响应）
  void setBlockedUsers(List<String> users) {
    _blockedUsers
      ..clear()
      ..addAll(users);
    notifyListeners();
  }

  // ---- 用户搜索结果（阶段 J：P1-10）----
  final List<String> _userSearchResults = [];
  List<String> get userSearchResults =>
      UnmodifiableListView(_userSearchResults);

  void setUserSearchResults(List<String> usernames) {
    _userSearchResults
      ..clear()
      ..addAll(usernames);
    notifyListeners();
  }

  void clearUserSearchResults() {
    if (_userSearchResults.isNotEmpty) {
      _userSearchResults.clear();
      notifyListeners();
    }
  }

  // ---- 群组列表 ----
  final List<Group> _groups = [];
  UnmodifiableListView<Group> get groups => UnmodifiableListView(_groups);

  // ---- 阶段 M2：入群申请（按群隔离）----
  final Map<int, List<String>> _joinRequests = {};
  final Map<int, Map<String, String>> _joinRequestMessages = {};
  List<String> joinRequestsOf(int groupId) =>
      UnmodifiableListView(_joinRequests[groupId] ?? const []);

  /// 某申请的验证消息（P-11 用户反馈：申请可附验证消息）
  String joinRequestMessageOf(int groupId, String username) =>
      _joinRequestMessages[groupId]?[username] ?? '';

  // ---- 阶段 M2：群邀请（group_invite 推送）----
  final List<GroupInvite> _invitations = [];
  List<GroupInvite> get invitations => UnmodifiableListView(_invitations);

  // ---- 阶段 M8：文件收发记录（file_list_response 推送）----
  final List<FileRecord> _fileRecords = [];
  List<FileRecord> get fileRecords => UnmodifiableListView(_fileRecords);

  // ---- 阶段 M：群组搜索结果（group_search_response 推送）----
  final List<Group> _groupSearchResults = [];
  List<Group> get groupSearchResults =>
      UnmodifiableListView(_groupSearchResults);

  // ---- 阶段 M4：服务端状态面板 / 存储清理结果 ----
  Map<String, dynamic>? _serverStatus;
  Map<String, dynamic>? get serverStatus => _serverStatus;
  Map<String, dynamic>? _storageCleanupResult;
  Map<String, dynamic>? get storageCleanupResult => _storageCleanupResult;

  // ---- 阶段 N6（P2-6）：登录设备会话列表（sessions_response 推送）----
  final List<SessionInfo> _sessions = [];
  List<SessionInfo> get sessions => UnmodifiableListView(_sessions);

  void setSessions(List<SessionInfo> sessions) {
    _sessions
      ..clear()
      ..addAll(sessions);
    notifyListeners();
  }

  // ---- 阶段 N7（P2-7）：审计日志列表（admin_response audit_log 推送）----
  final List<AuditLogEntry> _auditLogs = [];
  List<AuditLogEntry> get auditLogs => UnmodifiableListView(_auditLogs);

  void setAuditLogs(List<AuditLogEntry> logs) {
    _auditLogs
      ..clear()
      ..addAll(logs);
    notifyListeners();
  }

  // ---- 阶段 O1 公告管理：群公告历史列表 ----
  final List<GroupAnnouncement> _groupAnnouncements = [];
  List<GroupAnnouncement> get groupAnnouncements =>
      UnmodifiableListView(_groupAnnouncements);

  void setGroupAnnouncements(List<GroupAnnouncement> list) {
    _groupAnnouncements
      ..clear()
      ..addAll(list);
    notifyListeners();
  }

  /// 追加一条群公告（实时推送；已存在同 id 则忽略——幂等）
  void addGroupAnnouncement(GroupAnnouncement announcement) {
    if (_groupAnnouncements.any((a) => a.messageId == announcement.messageId)) {
      return;
    }
    _groupAnnouncements.add(announcement);
    notifyListeners();
  }

  /// 移除一条群公告（公告管理删除后本地同步）
  void removeGroupAnnouncement(String messageId) {
    _groupAnnouncements.removeWhere((a) => a.messageId == messageId);
    notifyListeners();
  }

  /// 群公告对账（2026-08-31 用户反馈 R-O12）：以服务端公告历史为准
  /// 设置横幅列表，并从该群聊天流中移除**服务端已不存在**的公告气泡
  /// （离线期间被删除的公告，重登/切会话拉取后自愈）。
  /// 返回被移除的聊天流消息 id 列表（调用方据此同步本地缓存）。
  List<String> syncGroupAnnouncements(
      int groupId, List<GroupAnnouncement> list) {
    setGroupAnnouncements(list);
    final chatKey = 'group_$groupId';
    final valid = list.map((a) => a.messageId).toSet();
    final removed = <String>[];
    for (final m in List<ChatMessage>.of(getMessages(chatKey))) {
      if (m.type == 'group_announcement' && !valid.contains(m.messageId)) {
        removeMessageLocally(chatKey, m.messageId);
        removed.add(m.messageId);
      }
    }
    return removed;
  }

  // ---- 阶段 O5（P2-5）：定时消息列表（scheduled_list_response 推送）----
  final List<ScheduledMessageInfo> _scheduledMessages = [];
  List<ScheduledMessageInfo> get scheduledMessages =>
      UnmodifiableListView(_scheduledMessages);

  void setScheduledMessages(List<ScheduledMessageInfo> messages) {
    _scheduledMessages
      ..clear()
      ..addAll(messages);
    notifyListeners();
  }

  // ---- 阶段 N3（P2-4）：图片粘贴预览（剪贴板图片 → 预览 → 发送）----
  Uint8List? _pendingImagePreview;
  Uint8List? get pendingImagePreview => _pendingImagePreview;

  void setPendingImagePreview(Uint8List bytes) {
    _pendingImagePreview = bytes;
    notifyListeners();
  }

  void clearPendingImagePreview() {
    if (_pendingImagePreview == null) return;
    _pendingImagePreview = null;
    notifyListeners();
  }

  // ---- 聊天消息 ----
  // key = 好友用户名 或 "group_N"
  final Map<String, List<ChatMessage>> _messages = {};
  Map<String, List<ChatMessage>> get messages => _messages;

  List<ChatMessage> getMessages(String key) => _messages[key] ?? [];

  // ---- 当前选中的会话 ----
  String? _currentChat;
  String? get currentChat => _currentChat;

  // ---- 待处理文件请求 ----
  final List<FileRequest> _pendingFileRequests = [];
  List<FileRequest> get pendingFileRequests => _pendingFileRequests;
  bool get hasPendingFileRequests => _pendingFileRequests.isNotEmpty;

  // ---- 已处理的群文件请求（去重） ----
  final Set<String> _processedGroupFileRequests = {};

  // ---- 消息 ID → 消息映射（用于撤回） ----
  final Map<String, ChatMessage> _messageMap = {};

  // ---- 未读消息计数（阶段 E）----
  final Map<String, int> _unreadCount = {};
  int unreadOf(String key) => _unreadCount[key] ?? 0;
  int get totalUnread => _unreadCount.values.fold(0, (a, b) => a + b);

  // ---- 历史分页状态（阶段 E）----
  final Set<String> _noMoreHistory = {};
  bool hasMoreHistory(String key) => !_noMoreHistory.contains(key);
  void setNoMoreHistory(String key) {
    _noMoreHistory.add(key);
    notifyListeners();
  }

  // ---- 消息搜索状态（阶段 H5）----
  // 按会话隔离（key = 用户名 / group_N），与 _messages / _messageMap 相互独立，
  // 不计未读。搜索模式由 SocketService 收到 search_response 后写入。
  final Map<String, List<ChatMessage>> _searchResults = {};
  final Map<String, String> _searchQueries = {};

  /// 某会话的搜索结果；未设置返回空列表
  List<ChatMessage> searchResults(String chatKey) =>
      _searchResults[chatKey] ?? const [];

  /// 是否处于搜索模式（存在搜索结果）
  bool isSearchMode(String chatKey) => _searchResults.containsKey(chatKey);

  /// 搜索关键字；未设置返回空串
  String searchQueryOf(String chatKey) => _searchQueries[chatKey] ?? '';

  /// 设置/替换搜索结果（可携带关键字）
  void setSearchResults(String chatKey, List<ChatMessage> msgs,
      {String query = ''}) {
    _searchResults[chatKey] = List.of(msgs);
    _searchQueries[chatKey] = query;
    notifyListeners();
  }

  /// 退出搜索模式（清除结果与关键字）
  void clearSearchResults(String chatKey) {
    final removedResults = _searchResults.remove(chatKey) != null;
    final removedQuery = _searchQueries.remove(chatKey) != null;
    if (removedResults || removedQuery) {
      notifyListeners();
    }
  }

  // ---- 文件传输进度（阶段 G：传输可视化）----
  final Map<String, TransferProgress> _transfers = {};

  /// 更新传输进度（发送/接收中每块回调）
  void updateTransfer(String messageId, int transferred, int total,
      {bool isSend = false}) {
    _transfers[messageId] = TransferProgress(
      messageId: messageId,
      total: total,
      transferred: transferred,
      isSend: isSend,
    );
    notifyListeners();
  }

  /// 移除传输进度（完成或失败后调用）
  void removeTransfer(String messageId) {
    if (_transfers.remove(messageId) != null) {
      notifyListeners();
    }
  }

  /// 查询传输进度比例；无传输返回 null
  double? transferFraction(String messageId) => _transfers[messageId]?.fraction;

  /// 该消息是否仍在传输中（存在且未完成）
  bool isTransferring(String messageId) {
    final p = _transfers[messageId];
    return p != null && !p.done;
  }

  // ---- 本地发送队列（阶段 I1：pending 队列 + 失败重试）----
  // 断线/发送失败的消息进入此队列（status='sending'），重连后自动补发；
  // 发送成功出队（sent），失败保留并标记 failed，重试复位 sending。
  final List<PendingMessage> _pendingMessages = [];
  UnmodifiableListView<PendingMessage> get pendingMessages =>
      UnmodifiableListView(_pendingMessages);
  int get pendingCount => _pendingMessages.length;

  /// 入队（同 messageId 去重：更新条目内容，保留原顺序）
  void enqueuePendingMessage(String chatKey, ChatMessage message) {
    final idx = _pendingMessages
        .indexWhere((e) => e.message.messageId == message.messageId);
    if (idx != -1) {
      _pendingMessages[idx] =
          PendingMessage(chatKey: chatKey, message: message);
    } else {
      _pendingMessages.add(PendingMessage(chatKey: chatKey, message: message));
    }
    notifyListeners();
  }

  /// 发送成功：出队并将会话内消息状态置为 sent；不存在返回 false
  bool markPendingSent(String messageId) {
    final before = _pendingMessages.length;
    _pendingMessages.removeWhere((e) => e.message.messageId == messageId);
    final msg = _messageMap[messageId];
    if (msg != null) msg.status = 'sent';
    if (_pendingMessages.length != before || msg != null) {
      notifyListeners();
    }
    return _pendingMessages.length != before;
  }

  /// 发送失败：保留在队列并标记 failed（待重试）；不在队列返回 false
  bool markPendingFailed(String messageId) {
    final entry = _pendingEntry(messageId);
    if (entry == null) return false;
    entry.message.status = 'failed';
    _messageMap[messageId]?.status = 'failed';
    notifyListeners();
    return true;
  }

  /// 重试在途：保留在队列并复位为 sending；不在队列返回 false
  bool markPendingSending(String messageId) {
    final entry = _pendingEntry(messageId);
    if (entry == null) return false;
    entry.message.status = 'sending';
    _messageMap[messageId]?.status = 'sending';
    notifyListeners();
    return true;
  }

  PendingMessage? _pendingEntry(String messageId) {
    for (final e in _pendingMessages) {
      if (e.message.messageId == messageId) return e;
    }
    return null;
  }

  /// 从补发队列移除条目（消息已确认送达/已入库时调用）；存在则返回 true
  bool removePendingMessage(String messageId) {
    final before = _pendingMessages.length;
    _pendingMessages.removeWhere((e) => e.message.messageId == messageId);
    if (_pendingMessages.length != before) notifyListeners();
    return _pendingMessages.length != before;
  }

  // ---- 会话元数据（阶段 I2：pinned/muted/draft/clearedAt）----
  // 客户端状态镜像；服务端 conversations 表同步在后续阶段接入。
  final Map<String, ConversationMeta> _conversationMeta = {};

  /// 某会话的元数据；未设置返回 null
  ConversationMeta? conversationMetaOf(String chatKey) =>
      _conversationMeta[chatKey];

  bool isPinned(String chatKey) => _conversationMeta[chatKey]?.pinned ?? false;
  bool isMuted(String chatKey) => _conversationMeta[chatKey]?.muted ?? false;
  String draftOf(String chatKey) => _conversationMeta[chatKey]?.draft ?? '';
  DateTime? clearedAtOf(String chatKey) =>
      _conversationMeta[chatKey]?.clearedAt;

  void setConversationPinned(String chatKey, bool pinned) {
    _setConversationMeta(chatKey, (m) => m.copyWith(pinned: pinned));
  }

  void setConversationMuted(String chatKey, bool muted) {
    _setConversationMeta(chatKey, (m) => m.copyWith(muted: muted));
  }

  void setConversationDraft(String chatKey, String draft) {
    _setConversationMeta(chatKey, (m) => m.copyWith(draft: draft));
  }

  void setConversationClearedAt(String chatKey, DateTime? clearedAt) {
    _setConversationMeta(chatKey, (m) => m.copyWith(clearedAt: clearedAt));
  }

  void _setConversationMeta(
      String chatKey, ConversationMeta Function(ConversationMeta) update) {
    final current = _conversationMeta[chatKey] ?? const ConversationMeta();
    _conversationMeta[chatKey] = update(current);
    notifyListeners();
  }

  /// 批量替换会话元数据（阶段 K：服务端 list_conversations 登录推送）
  void setConversationMetaList(List<ConversationMeta> metas) {
    _conversationMeta.clear();
    for (final m in metas) {
      if (m.peerKey.isEmpty) continue;
      _conversationMeta[m.peerKey] = m;
    }
    notifyListeners();
  }

  // ---- 会话置顶（阶段 K1：P1-11）----
  // 置顶会话排序：chatTargets 原顺序过滤（置顶在前由 Sidebar 分区渲染）

  /// 置顶的会话目标（保持 chatTargets 原顺序）
  List<ChatTarget> get pinnedChatTargets =>
      chatTargets.where((t) => isPinned(t.key)).toList();

  /// 非置顶的会话目标
  List<ChatTarget> get unpinnedChatTargets =>
      chatTargets.where((t) => !isPinned(t.key)).toList();

  // ---- 消息操作状态（阶段 K5：P1-2 引用 / P1-4 表情回应）----

  /// 按 messageId 查询消息本体；不存在返回 null
  ChatMessage? messageById(String messageId) => _messageMap[messageId];

  /// 设置/清除引用信息（P1-2）
  void setMessageQuote(String messageId,
      {String? replyTo, String? replyPreview}) {
    final msg = _messageMap[messageId];
    if (msg == null) return;
    msg.replyTo = replyTo;
    msg.replyPreview = replyPreview;
    notifyListeners();
  }

  /// 整体替换消息的表情回应（P1-4，副本语义）
  void updateMessageReactions(
      String messageId, Map<String, List<String>> reactions) {
    final msg = _messageMap[messageId];
    if (msg == null) return;
    msg.reactions = {
      for (final entry in reactions.entries)
        entry.key: List<String>.of(entry.value),
    };
    notifyListeners();
  }

  /// 切换某用户对消息的表情回应（乐观更新）：
  /// 已在 emoji 列表 → 移除（该 emoji 空则删键）；不在 → 加入
  void toggleReaction(String messageId, String emoji, String username) {
    final msg = _messageMap[messageId];
    if (msg == null) return;
    // 整体替换映射实例（消息 reactions 可能为 const 空映射，不可原地修改）
    final current = {
      for (final e in msg.reactions.entries) e.key: List<String>.of(e.value),
    };
    final users = List<String>.from(current[emoji] ?? const []);
    if (users.contains(username)) {
      users.remove(username);
      if (users.isEmpty) {
        current.remove(emoji);
      } else {
        current[emoji] = users;
      }
    } else {
      current[emoji] = [...users, username];
    }
    msg.reactions = current;
    notifyListeners();
  }

  /// 仅我删除（本地）：从自己界面移除消息（不删除他人/服务端记录）
  void removeMessageLocally(String chatKey, String messageId) {
    final list = _messages[chatKey];
    if (list == null) return;
    final before = list.length;
    list.removeWhere((m) => m.messageId == messageId);
    _messageMap.remove(messageId);
    if (list.length != before) notifyListeners();
  }

  // ---- 状态日志 ----
  final List<String> _statusLog = [];
  UnmodifiableListView<String> get statusLog =>
      UnmodifiableListView(_statusLog);

  // ---- 临时通知（SnackBar）----
  final List<String> _noticeQueue = [];
  List<String> get noticeQueue => UnmodifiableListView(_noticeQueue);

  void _log(String msg) {
    _statusLog.add('[${DateTime.now().toString().substring(11, 19)}] $msg');
    if (_statusLog.length > 500) _statusLog.removeRange(0, 100);
    notifyListeners();
  }

  // ============================================================
  // 状态更新方法（由 SocketService 调用）
  // ============================================================

  void setConnectionStatus(ConnectionStatus status) {
    _connectionStatus = status;
    notifyListeners();
  }

  /// 进入重连状态（不清空好友/群组/消息，区别于 setLoggedOut）
  void setReconnecting() {
    _connectionStatus = ConnectionStatus.reconnecting;
    notifyListeners();
  }

  /// 更新重连尝试次数（UI banner 显示用）
  void setReconnectAttempt(int attempt) {
    _reconnectAttempts = attempt;
    notifyListeners();
  }

  void setLoggedIn(String username, bool isAdmin) {
    _username = username;
    _isAdmin = isAdmin;
    _connectionStatus = ConnectionStatus.connected;
    _reconnectAttempts = 0;
    _log('登录成功: $username${isAdmin ? " (管理员)" : ""}');
    notifyListeners();
  }

  void setLoggedOut() {
    _username = null;
    _isAdmin = false;
    _connectionStatus = ConnectionStatus.disconnected;
    _friends.clear();
    _groups.clear();
    _messages.clear();
    _pendingRequests.clear();
    _pendingRequestMessages.clear();
    _pendingFriendNotes.clear();
    _pendingFileRequests.clear();
    _messageMap.clear();
    _unreadCount.clear();
    _noMoreHistory.clear();
    _transfers.clear();
    _searchResults.clear();
    _searchQueries.clear();
    _pendingMessages.clear();
    _conversationMeta.clear();
    _onlineUsers.clear();
    _profiles.clear();
    _friendMeta.clear();
    _blockedUsers.clear();
    _userSearchResults.clear();
    // 阶段 M：群组治理/运维状态随登出清空
    _joinRequests.clear();
    _joinRequestMessages.clear();
    _invitations.clear();
    _fileRecords.clear();
    _groupSearchResults.clear();
    _serverStatus = null;
    _storageCleanupResult = null;
    // 阶段 N：设备会话/审计日志/图片预览随登出清空（防跨账号泄漏）
    _sessions.clear();
    _auditLogs.clear();
    _scheduledMessages.clear();
    _groupAnnouncements.clear();
    _pendingImagePreview = null;
    _currentChat = null;
    _noticeQueue.clear();
    _log('已断开连接');
    // 阶段 L3：退出登录清空本地缓存（防跨账号数据泄漏）
    MessageCache.clear();
    notifyListeners();
  }

  void setFriends(List<String> friends) {
    _friends
      ..clear()
      ..addAll(friends);
    _log('好友列表已更新: ${friends.length} 人');
    notifyListeners();
  }

  void setGroups(List<Group> groups) {
    _groups
      ..clear()
      ..addAll(groups);
    _log('群组列表已更新: ${groups.length} 个');
    notifyListeners();
  }

  void setPendingRequests(List<String> requests) {
    _pendingRequests
      ..clear()
      ..addAll(requests);
    notifyListeners();
  }

  void addFriend(String friend) {
    if (!_friends.contains(friend)) {
      _friends.add(friend);
      notifyListeners();
    }
  }

  void removeFriend(String friend) {
    _friends.remove(friend);
    _messages.remove(friend);
    _unreadCount.remove(friend);
    _searchResults.remove(friend);
    _searchQueries.remove(friend);
    _friendMeta.remove(friend);
    if (_currentChat == friend) _currentChat = null;
    notifyListeners();
  }

  void addGroup(Group group) {
    if (!_groups.any((g) => g.id == group.id)) {
      _groups.add(group);
      notifyListeners();
    }
  }

  void leaveGroup(int groupId) {
    final key = 'group_$groupId';
    _groups.removeWhere((g) => g.id == groupId);
    _messages.remove(key);
    _unreadCount.remove(key);
    _noMoreHistory.remove(key);
    _searchResults.remove(key);
    _searchQueries.remove(key);
    if (_currentChat == key) _currentChat = null;
    notifyListeners();
  }

  void updateGroupMembers(int groupId, List<String> members) {
    final index = _groups.indexWhere((g) => g.id == groupId);
    if (index == -1) return;
    final old = _groups[index];
    _groups[index] = Group(
      id: groupId,
      name: old.name,
      members: members,
      owner: old.owner,
      avatar: old.avatar,
      historyVisible: old.historyVisible,
      historyLimit: old.historyLimit,
    );
    notifyListeners();
  }

  // ---- 阶段 M1：群主标识 / 群组更新（改名/头像/转让后同步）----

  bool isGroupOwner(int groupId) {
    final index = _groups.indexWhere((g) => g.id == groupId);
    if (index == -1) return false;
    return _groups[index].isOwner(_username ?? '');
  }

  void updateGroup(Group group) {
    final index = _groups.indexWhere((g) => g.id == group.id);
    if (index == -1) {
      _groups.add(group);
    } else {
      _groups[index] = group;
    }
    notifyListeners();
  }

  void removeGroup(int groupId) {
    final key = 'group_$groupId';
    _groups.removeWhere((g) => g.id == groupId);
    _messages.remove(key);
    _unreadCount.remove(key);
    _noMoreHistory.remove(key);
    _searchResults.remove(key);
    _searchQueries.remove(key);
    if (_currentChat == key) _currentChat = null;
    notifyListeners();
  }

  // ---- 阶段 M2：入群申请状态 ----

  void setJoinRequests(int groupId, List<String> usernames) {
    _joinRequests[groupId] = List.of(usernames);
    notifyListeners();
  }

  /// 设置某群待审批申请的验证消息（与 setJoinRequests 配套）
  void setJoinRequestMessages(int groupId, Map<String, String> messages) {
    _joinRequestMessages[groupId] = Map.of(messages);
    notifyListeners();
  }

  void removeJoinRequest(int groupId, String username) {
    final list = _joinRequests[groupId];
    if (list == null) return;
    list.remove(username);
    _joinRequestMessages[groupId]?.remove(username);
    notifyListeners();
  }

  // ---- 阶段 M2：群邀请状态 ----

  void setInvitations(List<GroupInvite> invites) {
    _invitations
      ..clear()
      ..addAll(invites);
    notifyListeners();
  }

  void removeInvitation(int groupId) {
    _invitations.removeWhere((i) => i.groupId == groupId);
    notifyListeners();
  }

  // ---- 阶段 M8：文件收发记录 ----

  void setFileRecords(List<FileRecord> records) {
    _fileRecords
      ..clear()
      ..addAll(records);
    notifyListeners();
  }

  // ---- 阶段 M：群组搜索结果 ----

  void setGroupSearchResults(List<Group> groups) {
    _groupSearchResults
      ..clear()
      ..addAll(groups);
    notifyListeners();
  }

  // ---- 阶段 M4：服务端状态面板 / 存储清理 ----

  void setServerStatus(Map<String, dynamic>? status) {
    _serverStatus = status;
    notifyListeners();
  }

  void setStorageCleanupResult(Map<String, dynamic>? result) {
    _storageCleanupResult = result;
    notifyListeners();
  }

  void addPendingRequest(String username, {String? message}) {
    if (!_pendingRequests.contains(username)) {
      _pendingRequests.add(username);
    }
    _pendingRequestMessages[username] = message ?? '';
    notifyListeners();
  }

  void removePendingRequest(String username) {
    _pendingRequests.remove(username);
    _pendingRequestMessages.remove(username);
    notifyListeners();
  }

  void selectChat(String? key) {
    _currentChat = key;
    // 切换到某会话时清零该会话的未读计数（阶段 E）
    if (key != null && _unreadCount.containsKey(key)) {
      _unreadCount.remove(key);
    }
    notifyListeners();
  }

  /// 添加一条消息到对应会话
  void addMessage(String chatKey, ChatMessage msg) {
    // 阶段 J：黑名单后不接收消息——被拉黑用户的消息不落地、不计未读
    // （服务端已拦截，此为客户端纵深防御）
    if (msg.sender != _username && isBlocked(msg.sender)) return;
    // 阶段 I1 修复：同 messageId 的服务端回显（登录/重连的离线历史推送）
    // 证明该消息已入库——若此前因"发送异常"误入补发队列，这里直接出队，
    // 重连 flush 不再重发已送达的消息
    if (msg.messageId.isNotEmpty) {
      removePendingMessage(msg.messageId);
    }
    // 按 messageId 去重：自己发的群聊/私聊消息会被服务器回显，
    // 已存在的消息仅更新状态（sent → delivered），不重复添加。
    // 空 messageId 不做去重：不同消息不得因空 id 被合并丢失
    if (msg.messageId.isNotEmpty && _messageMap.containsKey(msg.messageId)) {
      _messageMap[msg.messageId]!.status = msg.status;
      // 阶段 L3：去重更新同样落盘（状态演进 sent→delivered 持久化）
      MessageCache.persist(chatKey, _messageMap[msg.messageId]!);
      notifyListeners();
      return;
    }
    _messages.putIfAbsent(chatKey, () => []);
    _messages[chatKey]!.add(msg);
    if (msg.messageId.isNotEmpty) {
      _messageMap[msg.messageId] = msg;
    }
    // 阶段 L3：任何到达/发出的消息落盘（本地缓存，离线可读 + 启动秒开）
    MessageCache.persist(chatKey, msg);
    // 未读计数：仅 status=sent（真正的未读消息），且非自己发送，且非当前会话（阶段 E）
    // 已读历史（delivered）和上滑加载的历史不计未读
    if (msg.status == 'sent' &&
        chatKey != _currentChat &&
        msg.sender != _username) {
      _unreadCount[chatKey] = (_unreadCount[chatKey] ?? 0) + 1;
    }
    notifyListeners();
  }

  /// 批量插入历史消息到会话列表（上滑加载更旧消息，阶段 E）
  /// 历史消息不计未读，按 messageId 去重，按 timestamp 排序确保时间顺序正确
  void prependHistoryMessages(String chatKey, List<ChatMessage> msgs) {
    if (msgs.isEmpty) return;
    _messages.putIfAbsent(chatKey, () => []);
    final list = _messages[chatKey]!;
    int inserted = 0;
    for (final msg in msgs) {
      if (_messageMap.containsKey(msg.messageId)) continue;
      list.add(msg);
      _messageMap[msg.messageId] = msg;
      inserted++;
      // 阶段 L3：历史消息同样落盘（增量同步合并的持久化基础）
      MessageCache.persist(chatKey, msg);
    }
    // 按 timestamp 升序排序（旧消息在前，新消息在后）
    if (inserted > 0) {
      list.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      notifyListeners();
    }
  }

  /// 更新消息状态（送达、撤回等）
  void updateMessageStatus(String messageId, String newStatus) {
    final msg = _messageMap[messageId];
    if (msg != null) {
      msg.status = newStatus;
      notifyListeners();
    }
    // 阶段 I1：收到 delivered/recalled 说明消息已生效（回执/撤回路径），
    // 无需再补发 → 自动出队
    if (newStatus == 'delivered' || newStatus == 'recalled') {
      final before = _pendingMessages.length;
      _pendingMessages.removeWhere((e) => e.message.messageId == messageId);
      if (_pendingMessages.length != before) notifyListeners();
    }
  }

  /// 撤回消息
  void recallMessage(String messageId) {
    updateMessageStatus(messageId, 'recalled');
  }

  /// 添加待处理文件请求
  void addFileRequest(FileRequest request) {
    // 去重
    if (!_pendingFileRequests.any((r) => r.messageId == request.messageId)) {
      _pendingFileRequests.add(request);
      notifyListeners();
    }
  }

  /// 移除文件请求（已处理）
  void removeFileRequest(String messageId) {
    _pendingFileRequests.removeWhere((r) => r.messageId == messageId);
    notifyListeners();
  }

  /// 标记群文件请求已处理
  bool markGroupFileProcessed(String messageId) {
    if (_processedGroupFileRequests.contains(messageId)) return false;
    _processedGroupFileRequests.add(messageId);
    return true;
  }

  /// 获取所有会话目标（好友 + 群组 + 系统消息）
  List<ChatTarget> get chatTargets {
    final targets = <ChatTarget>[];
    // 系统消息会话（管理员功能响应等）
    if (_messages.containsKey('服务器') && _messages['服务器']!.isNotEmpty) {
      targets.add(const ChatTarget(
        key: '服务器',
        displayName: '系统消息',
      ));
    }
    for (final f in _friends) {
      final note = _friendMeta[f]?.note;
      targets.add(ChatTarget(
        key: f,
        displayName: (note != null && note.isNotEmpty) ? note : f,
      ));
    }
    for (final g in _groups) {
      targets.add(ChatTarget(
        key: g.chatKey,
        displayName: g.displayName,
        isGroup: true,
      ));
    }
    return targets;
  }

  /// 向状态日志写入
  void log(String msg) {
    _log(msg);
  }

  /// 显示临时通知（SnackBar），不进入系统消息会话
  void showNotice(String msg) {
    _noticeQueue.add(msg);
    notifyListeners();
  }

  /// 消费一条通知（SnackBar 已展示后调用）
  void consumeNotice() {
    if (_noticeQueue.isNotEmpty) {
      _noticeQueue.removeAt(0);
    }
  }

  /// 获取群组名称
  String? getGroupName(int groupId) {
    for (final g in _groups) {
      if (g.id == groupId) return g.name;
    }
    return null;
  }

  String displayNameForChat(String key) {
    if (key == '服务器') return '系统消息';
    if (key.startsWith('group_')) {
      final groupId = int.tryParse(key.substring(6));
      if (groupId != null) {
        final groupName = getGroupName(groupId);
        if (groupName != null && groupName.isNotEmpty) {
          return '$groupName (ID:$groupId)';
        }
        return '群组 $groupId';
      }
    }
    return key;
  }
}
