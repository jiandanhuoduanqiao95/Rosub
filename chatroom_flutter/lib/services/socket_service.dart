/// Socket 通信服务
///
/// 负责：
///   - SSL/TLS 连接管理
///   - 使用 dart_protocol 进行消息编解码
///   - 后台持续监听服务器消息
///   - 将收到的消息分派到 AppState

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_protocol/protocol.dart';

import '../config.dart';
import '../models/chat_models.dart';
import 'state_manager.dart';

class SocketService {
  final AppState state = AppState.instance;

  SecureSocket? _socket;
  MessageReader? _reader;
  StreamSubscription? _listenSub;
  bool _running = false;

  /// 已连接的 socket（供外部查询）
  SecureSocket? get socket => _socket;

  /// 生成唯一的消息 ID
  String _generateMessageId() {
    final rand = Random().nextInt(999999);
    return '${DateTime.now().millisecondsSinceEpoch}_$rand';
  }

  // ============================================================
  // 连接管理
  // ============================================================

  /// 建立 SSL 连接到服务器
  Future<bool> connect() async {
    state.setConnectionStatus(ConnectionStatus.connecting);
    try {
      _socket = await SecureSocket.connect(
        AppConfig.serverHost,
        AppConfig.serverPort,
        onBadCertificate: (_) => true, // 接受自签名证书
        timeout: const Duration(seconds: 10),
      );
      _reader = MessageReader(_socket!);
      _running = true;
      state.log('已连接到 ${AppConfig.serverHost}:${AppConfig.serverPort}');
      return true;
    } catch (e) {
      state.log('连接失败: $e');
      state.setConnectionStatus(ConnectionStatus.disconnected);
      return false;
    }
  }

  /// 断开连接
  void disconnect() {
    _running = false;
    _listenSub?.cancel();
    _reader?.close();
    try {
      _socket?.close();
    } catch (_) {}
    _socket = null;
    _reader = null;
    state.setLoggedOut();
  }

  // ============================================================
  // 认证
  // ============================================================

  /// 登录
  Future<String?> login(String username, String password) async {
    if (_socket == null) return '未连接到服务器';

    await sendMessage(
      _socket!,
      'login',
      username,
      extraHeaders: {'password': password},
    );

    // 等待登录响应（阻塞式，在启动监听前处理初始数据）
    final (header, body) = await recvMessage(_reader!, chunkSize: 65536);
    if (header == null) return '服务器无响应';

    final type = header['type'] as String?;
    if (type == 'error') {
      return utf8.decode(body ?? Uint8List(0));
    }

    final isAdmin = type == 'admin_auth';
    state.setLoggedIn(username, isAdmin);

    // 接收初始数据：离线消息 + 好友列表 + 群组列表
    await _receiveInitialData();

    // 启动后台消息监听
    _startListening();

    return null; // null = 成功
  }

  /// 注册
  Future<String?> register(String username, String password) async {
    if (_socket == null) return '未连接到服务器';

    await sendMessage(
      _socket!,
      'register',
      username,
      extraHeaders: {'password': password},
    );

    final (header, body) = await recvMessage(_reader!, chunkSize: 65536);
    if (header == null) return '服务器无响应';

    final type = header['type'] as String?;
    if (type == 'error') {
      return utf8.decode(body ?? Uint8List(0));
    }

    // 注册成功（type == 'chat', body == '注册成功'）
    state.setLoggedIn(username, false);

    // 接收初始数据
    await _receiveInitialData();

    // 启动后台消息监听
    _startListening();

    return null; // null = 成功
  }

  /// 接收登录/注册后的初始数据（好友列表、群组列表、离线消息）
  /// 服务器登录成功后依次发送：
  ///   1. load_offline_data(): chat/file/group_chat (history=true)
  ///   2. send_initial_data(): admin_response(list_friends) + list_groups
  Future<void> _receiveInitialData() async {
    int safetyCounter = 0;
    bool gotFriendList = false;
    bool gotGroupList = false;

    while (_running && safetyCounter < 200) {
      safetyCounter++;
      final (header, body) = await recvMessage(_reader!, chunkSize: 65536);
      if (header == null) break;

      final type = header['type'] as String?;
      final from = header['from'] as String?;
      final messageId = header['message_id'] as String? ?? _generateMessageId();
      final isHistory = header['history'] == 'true';

      switch (type) {
        case 'chat':
          // 离线消息：用 to/from 确定正确的会话 key
          // 自己发的消息按 recipient 归类，别人发的按 sender 归类
          final text = utf8.decode(body ?? Uint8List(0));
          if (isHistory) {
            final to = header['to'] as String?;
            final chatKey = (from != null && from == state.username)
                ? (to ?? from)
                : (from ?? '系统');
            state.addMessage(
              chatKey,
              ChatMessage(
                sender: from ?? '系统',
                content: text,
                type: 'chat',
                messageId: messageId,
                isHistory: true,
                status: 'delivered',
              ),
            );
          }
          break;

        case 'file':
          if (isHistory && from != null) {
            final filename = header['filename'] as String? ?? 'file';
            final to = header['to'] as String?;
            // 自己发的文件按收件人归类，别人发的按发送者归类
            final chatKey = (from == state.username && to != null)
                ? to
                : from;
            state.addMessage(
              chatKey,
              ChatMessage(
                sender: from,
                content: '[文件] $filename',
                type: 'file',
                messageId: messageId,
                filename: filename,
                fileData: body,
                isHistory: true,
                status: 'delivered',
              ),
            );
          }
          break;

        case 'group_chat':
          if (isHistory && from != null) {
            final groupId = header['group_id'] as String?;
            final chatKey = groupId != null ? 'group_$groupId' : (from);
            final text = utf8.decode(body ?? Uint8List(0));
            state.addMessage(
              chatKey,
              ChatMessage(
                sender: from,
                content: text,
                type: 'group_chat',
                messageId: messageId,
                isHistory: true,
                status: 'delivered',
                groupId: groupId != null ? int.tryParse(groupId) : null,
              ),
            );
          }
          break;

        case 'file_request':
          if (from != null) {
            state.addFileRequest(FileRequest(
              messageId: messageId,
              sender: from,
              filename: header['filename'] as String? ?? 'file',
              filesize: int.tryParse(header['filesize'] as String? ?? '0') ?? 0,
            ));
          }
          break;

        case 'group_file_request':
          if (from != null) {
            final groupId = header['group_id'] as String?;
            if (state.markGroupFileProcessed(messageId)) {
              state.addFileRequest(FileRequest(
                messageId: messageId,
                sender: from,
                filename: header['filename'] as String? ?? 'file',
                filesize:
                    int.tryParse(header['filesize'] as String? ?? '0') ?? 0,
                groupId: groupId != null ? int.tryParse(groupId) : null,
              ));
            }
          }
          break;

        case 'admin_response':
          final responseType = header['response_type'] as String?;
          if (responseType == 'list_friends') {
            final friendsJson = utf8.decode(body ?? Uint8List(0));
            try {
              final List<dynamic> list = jsonDecode(friendsJson);
              state.setFriends(list.map((e) => e.toString()).toList());
              gotFriendList = true;
            } catch (_) {}
          }
          break;

        case 'list_groups':
          final groupsJson = utf8.decode(body ?? Uint8List(0));
          try {
            final List<dynamic> list = jsonDecode(groupsJson);
            state.setGroups(
              list
                  .map((e) => Group.fromJson(e as Map<String, dynamic>))
                  .toList(),
            );
            gotGroupList = true;
          } catch (_) {}
          break;

        default:
          // 未知类型，忽略
          break;
      }

      // 如果已收到好友列表和群组列表，说明初始数据接收完毕
      if (gotFriendList && gotGroupList) {
        break;
      }
    }
  }

  // ============================================================
  // 消息监听
  // ============================================================

  /// 启动后台消息监听循环
  void _startListening() {
    _listenSub?.cancel();
    _listenSub = Stream<void>.periodic(const Duration(milliseconds: 10))
        .asyncMap((_) => _listenLoop())
        .listen(null);
  }

  Future<void> _listenLoop() async {
    while (_running && _reader != null) {
      final (header, body) = await recvMessage(_reader!, chunkSize: 65536);
      if (header == null) {
        // 连接断开
        if (_running) {
          state.log('与服务器的连接已断开');
          disconnect();
        }
        break;
      }
      _handleMessage(header, body ?? Uint8List(0));
    }
  }

  /// 处理收到的消息
  void _handleMessage(Map<String, dynamic> header, Uint8List body) {
    final type = header['type'] as String?;
    final from = header['from'] as String?;
    final messageId = header['message_id'] as String? ?? _generateMessageId();
    final isHistory = header['history'] == 'true';

    switch (type) {
      // ---- 私聊消息 ----
      case 'chat':
        final text = utf8.decode(body);
        if (isHistory) break; // 初始数据阶段已处理
        final sender = from ?? '系统';
        // 系统来源消息（公告、服务器通知等）统一归入「服务器」会话，
        // 否则按发送者归类（好友私聊）
        final isSystemSender = sender == '系统' || sender == '服务器' || sender.startsWith('[');
        // 非管理员只展示系统公告，其余系统消息一律忽略
        // 注：好友刷新逻辑必须在过滤之前，否则被加好友方看不到对方
        if (isSystemSender && !state.isAdmin && sender != '[系统公告]') {
          // 即使不展示消息，仍需检测好友请求响应以自动刷新好友列表
          if (sender == '系统' &&
              (text.contains('已接受') || text.contains('接受您的好友请求'))) {
            _requestFriendList();
          }
          break;
        }
        final chatKey = isSystemSender ? '服务器' : sender;
        state.addMessage(
          chatKey,
          ChatMessage(
            sender: sender,
            content: text,
            type: 'chat',
            messageId: messageId,
            status: 'delivered',
          ),
        );
        // 检测好友请求被接受的系统通知，自动刷新好友列表
        if (sender == '系统' && (text.contains('已接受') || text.contains('接受您的好友请求'))) {
          _requestFriendList();
        }
        // 自动发送回执（跳过系统消息）
        if (from != null && !isHistory && !isSystemSender) {
          _sendReceipt(messageId, from);
        }
        break;

      // ---- 文件请求通知 ----
      case 'file_request':
        if (from != null) {
          state.addFileRequest(FileRequest(
            messageId: messageId,
            sender: from,
            filename: header['filename'] as String? ?? 'file',
            filesize: int.tryParse(header['filesize'] as String? ?? '0') ?? 0,
          ));
        }
        break;

      // ---- 文件数据（接受后服务端转发） ----
      case 'file':
        final filename = header['filename'] as String? ?? 'received_file';
        final sender = from ?? '未知';
        state.addMessage(
          sender,
          ChatMessage(
            sender: sender,
            content: '[收到文件] $filename',
            type: 'file',
            messageId: messageId,
            filename: filename,
            fileData: body,
            status: 'delivered',
          ),
        );
        // 保存文件到本地
        _saveReceivedFile(filename, body);
        break;

      // ---- 好友请求 ----
      case 'friend_request':
        if (from != null) {
          state.addPendingRequest(from);
        }
        break;

      // ---- 好友请求响应 ----
      case 'accept_friend':
        if (from != null) {
          state.addFriend(from);
          state.removePendingRequest(from);
        }
        break;

      case 'reject_friend':
        if (from != null) {
          state.removePendingRequest(from);
        }
        break;

      // ---- 群聊消息 ----
      case 'group_chat':
        final groupId = header['group_id'] as String?;
        final chatKey =
            groupId != null ? 'group_$groupId' : (from ?? '群组');
        final text = utf8.decode(body);
        final sender = from ?? '未知';
        state.addMessage(
          chatKey,
          ChatMessage(
            sender: sender,
            content: text,
            type: 'group_chat',
            messageId: messageId,
            status: 'delivered',
            groupId: groupId != null ? int.tryParse(groupId) : null,
          ),
        );
        break;

      // ---- 群文件请求 ----
      case 'group_file_request':
        if (from != null) {
          final groupId = header['group_id'] as String?;
          if (state.markGroupFileProcessed(messageId)) {
            state.addFileRequest(FileRequest(
              messageId: messageId,
              sender: from,
              filename: header['filename'] as String? ?? 'file',
              filesize:
                  int.tryParse(header['filesize'] as String? ?? '0') ?? 0,
              groupId: groupId != null ? int.tryParse(groupId) : null,
            ));
          }
        }
        break;

      // ---- 消息状态更新 ----
      case 'status_update':
        final newStatus = header['status'] as String?;
        if (newStatus != null) {
          state.updateMessageStatus(messageId, newStatus);
        }
        break;

      // ---- 消息撤回 ----
      case 'recall':
        final recallId = header['message_id'] as String?;
        if (recallId != null) {
          state.recallMessage(recallId);
        }
        break;

      // ---- 管理员认证成功 ----
      case 'admin_auth':
        // 已在 login 中处理
        break;

      // ---- 管理员响应 ----
      case 'admin_response':
        final responseType = header['response_type'] as String?;
        final responseBody = utf8.decode(body);
        if (responseType == 'list_friends') {
          try {
            final List<dynamic> list = jsonDecode(responseBody);
            state.setFriends(list.map((e) => e.toString()).toList());
          } catch (_) {}
        } else if (responseType == 'list_users') {
          // 仅管理员可查看用户列表
          if (!state.isAdmin) break;
          try {
            final List<dynamic> list = jsonDecode(responseBody);
            final buf = StringBuffer('用户列表:\n');
            int onlineCount = 0;
            for (final item in list) {
              final uname = item[0]?.toString() ?? '?';
              final online = item[1] == true;
              final admin = item[2] == true;
              if (online) onlineCount++;
              buf.writeln('  $uname ${online ? "🟢" : "⚪"}${admin ? " [管理员]" : ""}');
            }
            buf.writeln('\n在线: $onlineCount / ${list.length}');
            state.addMessage(
              '服务器',
              ChatMessage(
                sender: '服务器',
                content: buf.toString(),
                type: 'system',
                messageId: messageId,
              ),
            );
          } catch (_) {
            state.log('解析用户列表失败: $responseBody');
          }
        } else {
          // 其他管理响应仅管理员可见
          if (!state.isAdmin) break;
          state.log('管理响应: $responseBody');
          state.addMessage(
            '服务器',
            ChatMessage(
              sender: '服务器',
              content: responseBody,
              type: 'system',
              messageId: messageId,
            ),
          );
        }
        break;

      // ---- 群组列表 ----
      case 'list_groups':
        try {
          final List<dynamic> list = jsonDecode(utf8.decode(body));
          state.setGroups(
            list
                .map((e) => Group.fromJson(e as Map<String, dynamic>))
                .toList(),
          );
        } catch (_) {}
        break;

      // ---- 错误消息 ----
      case 'error':
        final errorText = utf8.decode(body);
        state.log('错误: $errorText');
        // 非管理员不展示错误消息
        if (state.isAdmin) {
          state.addMessage(
            '服务器',
            ChatMessage(
              sender: '服务器',
              content: '错误: $errorText',
              type: 'system',
              messageId: messageId,
            ),
          );
        }
        break;

      default:
        state.log('未处理的消息类型: $type');
    }
  }

  // ============================================================
  // 发送消息（业务方法）
  // ============================================================

  /// 发送私聊消息
  Future<bool> sendChat(String to, String content) async {
    if (_socket == null) return false;
    final messageId = _generateMessageId();
    try {
      await sendMessage(_socket!, 'chat', content, extraHeaders: {
        'to': to,
        'message_id': messageId,
      });
      state.addMessage(
        to,
        ChatMessage(
          sender: state.username!,
          content: content,
          type: 'chat',
          messageId: messageId,
          status: 'sent',
        ),
      );
      return true;
    } catch (e) {
      state.log('发送失败: $e');
      return false;
    }
  }

  /// 发送群聊消息
  Future<bool> sendGroupChat(int groupId, String content) async {
    if (_socket == null) return false;
    final messageId = _generateMessageId();
    final chatKey = 'group_$groupId';
    try {
      await sendMessage(_socket!, 'group_chat', content, extraHeaders: {
        'group_id': groupId.toString(),
        'message_id': messageId,
      });
      state.addMessage(
        chatKey,
        ChatMessage(
          sender: state.username!,
          content: content,
          type: 'group_chat',
          messageId: messageId,
          status: 'sent',
          groupId: groupId,
        ),
      );
      return true;
    } catch (e) {
      state.log('群聊发送失败: $e');
      return false;
    }
  }

  /// 发送文件
  Future<bool> sendFile(String to, String filePath, String filename) async {
    if (_socket == null) return false;
    final messageId = _generateMessageId();
    try {
      final fileData = await File(filePath).readAsBytes();
      final filesize = fileData.length;
      await sendMessage(_socket!, 'file', fileData, extraHeaders: {
        'to': to,
        'filename': filename,
        'filesize': filesize.toString(),
        'message_id': messageId,
      });
      state.addMessage(
        to,
        ChatMessage(
          sender: state.username!,
          content: '[发送文件] $filename',
          type: 'file',
          messageId: messageId,
          filename: filename,
          fileData: Uint8List.fromList(fileData),
          status: 'sent',
        ),
      );
      return true;
    } catch (e) {
      state.log('文件发送失败: $e');
      return false;
    }
  }

  /// 响应文件请求
  Future<void> respondFileRequest(
    String messageId,
    String sender,
    bool accept,
  ) async {
    if (_socket == null) return;
    await sendMessage(
      _socket!,
      'file_response',
      '',
      extraHeaders: {
        'response': accept ? 'accept' : 'reject',
        'message_id': messageId,
        'to': sender,
      },
    );
    state.removeFileRequest(messageId);
  }

  /// 响应群文件请求
  Future<void> respondGroupFileRequest(
    String messageId,
    int groupId,
    bool accept,
  ) async {
    if (_socket == null) return;
    await sendMessage(
      _socket!,
      'group_file_response',
      '',
      extraHeaders: {
        'response': accept ? 'accept' : 'reject',
        'message_id': messageId,
        'group_id': groupId.toString(),
      },
    );
    state.removeFileRequest(messageId);
  }

  /// 添加好友
  Future<void> addFriend(String targetUser) async {
    if (_socket == null) return;
    await sendMessage(
      _socket!,
      'friend_request',
      '',
      extraHeaders: {'to': targetUser},
    );
    state.log('已向 $targetUser 发送好友请求');
  }

  /// 接受好友请求
  Future<void> acceptFriend(String targetUser) async {
    if (_socket == null) return;
    // 服务端 accept_friend handler 使用 header.get("from") 识别请求发起者
    await sendMessage(
      _socket!,
      'accept_friend',
      '',
      extraHeaders: {'to': targetUser, 'from': targetUser},
    );
    state.addFriend(targetUser);
    state.removePendingRequest(targetUser);
    // 刷新好友列表，确保双方同步
    await _requestFriendList();
  }

  /// 拒绝好友请求
  Future<void> rejectFriend(String targetUser) async {
    if (_socket == null) return;
    await sendMessage(
      _socket!,
      'reject_friend',
      '',
      extraHeaders: {'to': targetUser, 'from': targetUser},
    );
    state.removePendingRequest(targetUser);
  }

  /// 请求刷新好友列表
  Future<void> _requestFriendList() async {
    if (_socket == null) return;
    try {
      await sendMessage(_socket!, 'list_friends', '');
    } catch (_) {}
  }

  /// 创建群组
  Future<void> createGroup(String groupName) async {
    if (_socket == null) return;
    await sendMessage(_socket!, 'create_group', groupName);
    state.log('群组 "$groupName" 创建请求已发送');
  }

  /// 加入群组
  Future<void> joinGroup(int groupId) async {
    if (_socket == null) return;
    await sendMessage(_socket!, 'join_group', groupId.toString());
    state.log('加入群组 $groupId 请求已发送');
  }

  /// 撤回消息
  Future<void> recallMessage(String messageId, String target) async {
    if (_socket == null) return;
    // 在本地先更新状态，再发送撤回请求
    state.recallMessage(messageId);
    await sendMessage(_socket!, 'recall', '', extraHeaders: {
      'message_id': messageId,
      'to': target,
    });
  }

  /// 发送回执
  Future<void> _sendReceipt(String messageId, String to) async {
    if (_socket == null) return;
    try {
      await sendMessage(_socket!, 'receipt', '', extraHeaders: {
        'message_id': messageId,
        'to': to,
      });
    } catch (_) {}
  }

  /// 管理员命令
  Future<void> adminCommand(String action,
      {String? targetUser, String? announcement}) async {
    if (_socket == null) return;
    final extraHeaders = <String, String>{'action': action};
    String content = '';
    if (targetUser != null) {
      extraHeaders['target_user'] = targetUser;
      content = targetUser;
    }
    if (announcement != null) {
      extraHeaders['announcement'] = announcement;
      content = announcement;
    }
    await sendMessage(_socket!, 'admin_command', content,
        extraHeaders: extraHeaders);
  }

  /// 保存接收到的文件
  void _saveReceivedFile(String filename, Uint8List data) {
    try {
      final dir = Directory(AppConfig.receivedFilesDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final file = File('${dir.path}/$filename');
      file.writeAsBytesSync(data);
      state.log('文件已保存: ${file.path}');
    } catch (e) {
      state.log('文件保存失败: $e');
    }
  }
}
