/// 全局应用状态管理器
///
/// 使用 ChangeNotifier 模式，所有 UI 组件通过监听此对象获取状态更新。
/// 单例模式，通过 AppState.instance 访问。

import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../models/chat_models.dart';

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

  // ---- 群组列表 ----
  final List<Group> _groups = [];
  UnmodifiableListView<Group> get groups => UnmodifiableListView(_groups);

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
    _pendingFileRequests.clear();
    _messageMap.clear();
    _unreadCount.clear();
    _noMoreHistory.clear();
    _transfers.clear();
    _searchResults.clear();
    _searchQueries.clear();
    _pendingMessages.clear();
    _conversationMeta.clear();
    _currentChat = null;
    _noticeQueue.clear();
    _log('已断开连接');
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
    _groups[index] = Group(
      id: groupId,
      name: _groups[index].name,
      members: members,
    );
    notifyListeners();
  }

  void addPendingRequest(String username) {
    if (!_pendingRequests.contains(username)) {
      _pendingRequests.add(username);
      notifyListeners();
    }
  }

  void removePendingRequest(String username) {
    _pendingRequests.remove(username);
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
      notifyListeners();
      return;
    }
    _messages.putIfAbsent(chatKey, () => []);
    _messages[chatKey]!.add(msg);
    if (msg.messageId.isNotEmpty) {
      _messageMap[msg.messageId] = msg;
    }
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
      targets.add(ChatTarget(key: f, displayName: f));
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
