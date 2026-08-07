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
    // 按 messageId 去重：自己发的群聊/私聊消息会被服务器回显，
    // 已存在的消息仅更新状态（sent → delivered），不重复添加
    if (_messageMap.containsKey(msg.messageId)) {
      _messageMap[msg.messageId]!.status = msg.status;
      notifyListeners();
      return;
    }
    _messages.putIfAbsent(chatKey, () => []);
    _messages[chatKey]!.add(msg);
    _messageMap[msg.messageId] = msg;
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
