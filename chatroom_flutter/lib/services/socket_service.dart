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
import 'taskbar_notifier.dart';
import 'state_manager.dart';

class SocketService {
  final AppState state = AppState.instance;

  SecureSocket? _socket;
  MessageReader? _reader;
  Future<void>? _listenFuture;
  bool _running = false;

  /// 大文件传输专用连接（阶段 G4b-问题2修复）：
  /// 与主连接独立，文件数据经此通道收发。聊天消息走主连接，
  /// 传输期间发送方的文字消息不再被发送队列/接收方抑制阻塞。
  SecureSocket? _transferSocket;
  MessageReader? _transferReader;
  Future<void>? _transferListenFuture;

  /// 传输通道写队列尾（与主连接队列相互独立，互不阻塞）
  Future<void> _transferSendTail = Future.value();

  /// 主动断开标志：true 表示用户主动退出，不应触发重连
  bool _intentionalDisconnect = false;

  /// 重连相关
  bool _reconnecting = false;
  int _reconnectAttempts = 0;

  /// 保存的登录凭据（仅内存，用于重连后自动重新登录；不落盘）
  String? _savedUsername;
  String? _savedPassword;
  String? _savedAdminSecret;

  /// 修改密码请求中的新密码：服务端确认成功后用于更新重连凭据（阶段 G3）
  String? _pendingPasswordChange;

  /// 大文件直传探测等待表：messageId → Completer（阶段 G4b）
  final Map<String, Completer<bool>> _pendingFileChecks = {};

  /// 是否正在接收文件消息体（接收期间抑制心跳 ping，避免服务器回复
  /// pong 插入文件字节流导致 SSL 记录错乱）
  bool _receivingFile = false;

  /// 发送队列尾（dart:io Socket 写端为单写者：flush/addStream 挂起期间
  /// 其他 add 抛 "StreamSink is bound to a stream"，所有发送必须串行）
  Future<void> _sendTail = Future.value();

  /// 进度通知节流时间戳（100ms 内最多通知一次 UI）
  DateTime _lastTransferNotify = DateTime.fromMillisecondsSinceEpoch(0);

  /// 串行执行 socket 写入任务
  Future<T> _enqueueSend<T>(Future<T> Function() task) {
    final result = _sendTail.then((_) => task());
    _sendTail = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// 串行执行传输通道写入任务（与主连接队列独立，互不阻塞）
  Future<T> _transferEnqueue<T>(Future<T> Function() task) {
    final result = _transferSendTail.then((_) => task());
    _transferSendTail = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// 排队发送协议消息
  Future<void> _sendMessage(String type, dynamic content,
      {Map<String, dynamic>? extraHeaders}) {
    return _enqueueSend(
        () => sendMessage(_socket!, type, content, extraHeaders: extraHeaders));
  }

  /// 节流更新传输进度（100ms 合并一次，完成时必须更新）
  ///
  /// 进度回调运行在 socket 数据管线内（文件流 map / readFileBody），
  /// 若 UI 监听器抛出异常（如 debug 模式 "markNeedsBuild during build"）
  /// 会沿回调链传播并中断传输。这里吞掉 UI 侧异常，传输不受影响。
  void _updateTransferThrottled(String messageId, int transferred, int total,
      {bool isSend = false}) {
    final now = DateTime.now();
    final done = transferred >= total;
    if (done || now.difference(_lastTransferNotify).inMilliseconds >= 100) {
      _lastTransferNotify = now;
      try {
        state.updateTransfer(messageId, transferred, total, isSend: isSend);
      } catch (_) {}
    }
  }

  /// 心跳相关
  Timer? _keepaliveTimer;

  /// pong 看门狗（阶段 G4b 修复）：判断断线的依据是「发出 ping 后 45s 内
  /// 未收到对应 pong」，而非「距上次 pong 的时间」。
  ///
  /// 原实现检查距上次 pong 的时长：大文件传输期间 ping 被抑制/排队、
  /// 服务端转发期间 pong 被抑制，导致基线陈旧，传输结束后首个
  /// ping 的检查必然误判超时 → 双方断线重连（重连竞态可能弄丢发送方
  /// 排队中的消息，甚至中断接收导致文件损坏）。
  Timer? _pongWatchdog;
  bool _pingOutstanding = false;

  /// 已连接的 socket（供外部查询）
  SecureSocket? get socket => _socket;

  /// 当前是否处于重连流程
  bool get isReconnecting => _reconnecting;

  /// 生成唯一的消息 ID
  String _generateMessageId() {
    final rand = Random().nextInt(999999);
    return '${DateTime.now().millisecondsSinceEpoch}_$rand';
  }

  /// 解析服务端时间戳（UTC 字符串 → 本地 DateTime）
  DateTime _parseTimestamp(String? tsStr) {
    if (tsStr == null || tsStr.isEmpty) return DateTime.now();
    try {
      return DateTime.parse('${tsStr.trim()}Z').toLocal();
    } catch (_) {
      return DateTime.now();
    }
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
      _intentionalDisconnect = false;
      state.log('已连接到 ${AppConfig.serverHost}:${AppConfig.serverPort}');
      return true;
    } catch (e) {
      state.log('连接失败: $e');
      return false;
    }
  }

  /// 主动断开连接（用户退出）—— 清空状态、回登录页，不触发重连
  void disconnect() {
    _intentionalDisconnect = true;
    _stopKeepalive();
    _cancelReconnect();
    _running = false;
    _receivingFile = false;
    _closeTransferSocket();
    _reader?.close();
    try {
      _socket?.close();
    } catch (_) {}
    _socket = null;
    _reader = null;
    _clearSavedCredentials();
    state.setLoggedOut();
  }

  /// 关闭传输通道并清理引用
  void _closeTransferSocket() {
    _transferListenFuture = null;
    _transferReader?.close();
    _transferReader = null;
    try {
      _transferSocket?.close();
    } catch (_) {}
    _transferSocket = null;
  }

  // ============================================================
  // 凭据管理（仅内存，用于重连）
  // ============================================================

  void _saveCredentials(String username, String password, String? adminSecret) {
    _savedUsername = username;
    _savedPassword = password;
    _savedAdminSecret = adminSecret;
  }

  void _clearSavedCredentials() {
    _savedUsername = null;
    _savedPassword = null;
    _savedAdminSecret = null;
  }

  // ============================================================
  // 心跳（keepalive）
  // ============================================================

  /// 启动心跳定时器：每 30s 发送 ping，超过 45s 未收到 pong 判定断开
  void _startKeepalive() {
    _stopKeepalive();
    _pingOutstanding = false;
    _keepaliveTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!_running || _socket == null) {
        _stopKeepalive();
        return;
      }
      // 接收大文件期间不心跳：服务器转发通道禁止插入任何数据（含 pong）
      if (_receivingFile) return;
      _enqueueSend(() async {
        if (_socket == null) return;
        try {
          await sendMessage(_socket!, 'ping', '');
          state.log('发送心跳 ping');
        } catch (e) {
          state.log('心跳发送失败: $e');
          _onConnectionLost();
          return;
        }
        // 标记等待 pong，并启动看门狗（45s 内未收到对应 pong 判定断开）
        _pingOutstanding = true;
        _schedulePongWatchdog();
      });
    });
  }

  void _stopKeepalive() {
    _keepaliveTimer?.cancel();
    _keepaliveTimer = null;
    _pongWatchdog?.cancel();
    _pongWatchdog = null;
    _pingOutstanding = false;
  }

  /// pong 看门狗：ping 发出后 45s 内未收到对应 pong 判定连接断开。
  ///
  /// 收到 pong 时由 pong 处理器取消（见 _handleMessage 'pong' 分支）。
  /// 接收大文件期间服务端会抑制 pong，此时不判死，顺延等待下一周期。
  void _schedulePongWatchdog() {
    _pongWatchdog?.cancel();
    _pongWatchdog = Timer(const Duration(seconds: 45), () {
      if (!_running || _socket == null) return;
      if (!_pingOutstanding) return; // pong 已收到
      if (_receivingFile) {
        // 接收期间 pong 可能被服务端抑制，顺延一个周期再判
        _schedulePongWatchdog();
        return;
      }
      state.log('心跳超时（45s 未收到 pong），判定连接断开');
      _onConnectionLost();
    });
  }

  // ============================================================
  // 断线重连
  // ============================================================

  /// 网络断开时调用：切到 reconnecting 状态并启动重连循环
  /// 与 disconnect() 的区别：不清空好友/群组/消息，不回登录页
  void _onConnectionLost() {
    if (_intentionalDisconnect || _reconnecting) return;
    _reconnecting = true;
    _stopKeepalive();
    _running = false;
    _receivingFile = false;
    _closeTransferSocket();
    try {
      _reader?.close();
    } catch (_) {}
    try {
      _socket?.close();
    } catch (_) {}
    _socket = null;
    _reader = null;
    _reconnectAttempts = 0;
    state.setReconnecting();
    state.log('连接断开，开始自动重连…');
    _reconnectLoop();
  }

  /// 指数退避重连循环：1→2→4→8→16→30s（上限 30s）
  Future<void> _reconnectLoop() async {
    while (_reconnecting && !_intentionalDisconnect) {
      try {
        _reconnectAttempts++;
        state.setReconnectAttempt(_reconnectAttempts);
        final delay = _backoffSeconds(_reconnectAttempts);
        state.log('第 $_reconnectAttempts 次重连，${delay}s 后尝试…');
        await Future.delayed(Duration(seconds: delay));
        if (_intentionalDisconnect || !_reconnecting) break;

        final ok = await connect();
        if (!ok) {
          state.setReconnecting();
          continue;
        }

        // 重连成功 → 重新登录并同步离线消息
        final err = await _relogin();
        if (err != null) {
          state.log('重连后重新登录失败: $err');
          // 登录失败通常凭据失效，停止重连
          _reconnecting = false;
          state.setLoggedOut();
          return;
        }

        // 重连 + 重登录成功
        _reconnecting = false;
        _reconnectAttempts = 0;
        state.setLoggedIn(_savedUsername!,
            _savedAdminSecret != null && _savedAdminSecret!.isNotEmpty);
        _startListening();
        _startKeepalive();
        state.log('重连成功，已恢复连接');
        // 阶段 I1：重连成功后自动补发本地 pending 队列（断线期间的消息）
        unawaited(flushPendingQueue());
        return;
      } catch (e) {
        // 重连过程中异常（连接被拒、读写失败等）→ 继续退避重试
        state.log('第 $_reconnectAttempts 次重连异常: $e');
        state.setReconnecting();
        continue;
      }
    }
    // 循环退出且非成功 → 用户主动取消
    if (_reconnecting) {
      _reconnecting = false;
      state.setLoggedOut();
    }
  }

  /// 取消正在进行的重连循环
  void _cancelReconnect() {
    _reconnecting = false;
  }

  /// 退避秒数：1,2,4,8,16,30,30,30…
  int _backoffSeconds(int attempt) {
    if (attempt <= 0) return 1;
    final seconds = 1 << (attempt - 1); // 2^(n-1)
    return seconds > 30 ? 30 : seconds;
  }

  /// 重连后用保存的凭据重新登录（不触发首次登录的 _receiveInitialData 以外逻辑）
  Future<String?> _relogin() async {
    if (_socket == null || _savedUsername == null || _savedPassword == null) {
      return '凭据缺失';
    }
    final extraHeaders = <String, String>{'password': _savedPassword!};
    if (_savedAdminSecret != null && _savedAdminSecret!.isNotEmpty) {
      extraHeaders['admin_secret'] = _savedAdminSecret!;
    }
    await _sendMessage('login', _savedUsername!, extraHeaders: extraHeaders);

    final (header, _) = await recvMessage(_reader!, chunkSize: 65536);
    if (header == null) return '服务器无响应';
    final type = header['type'] as String?;
    if (type == 'error') return '登录被拒（凭据可能已失效）';
    // 同步离线期间消息（依赖 addMessage 的 messageId 去重兜底重复）
    await _receiveInitialData();
    // 重建大文件传输通道（阶段 G4b-问题2）
    unawaited(_ensureTransferConnection());
    return null;
  }

  // ============================================================
  // 大文件传输通道（阶段 G4b-问题2）
  // ============================================================

  /// 建立大文件传输专用连接：以 transfer=1 登录，注册到服务端
  /// transfer_sockets。文件数据在此通道收发，聊天走主连接。
  /// 传输通道登录不踢主会话、不加载离线数据。
  Future<bool> _ensureTransferConnection() async {
    if (_transferSocket != null && _transferReader != null) return true;
    if (_savedUsername == null || _savedPassword == null) return false;
    try {
      final s = await SecureSocket.connect(
        AppConfig.serverHost,
        AppConfig.serverPort,
        onBadCertificate: (_) => true,
        timeout: const Duration(seconds: 10),
      );
      _transferSocket = s;
      _transferReader = MessageReader(s);
      final extraHeaders = <String, String>{
        'password': _savedPassword!,
        'transfer': '1',
      };
      await sendMessage(s, 'login', _savedUsername!,
          extraHeaders: extraHeaders);
      final (header, _) = await recvMessage(_transferReader!, chunkSize: 65536);
      if (header == null || header['type'] == 'error') {
        _closeTransferSocket();
        return false;
      }
      _startTransferListen();
      state.log('传输通道已就绪');
      return true;
    } catch (e) {
      state.log('传输通道建立失败: $e');
      _closeTransferSocket();
      return false;
    }
  }

  /// 传输通道后台监听：仅处理 file 消息（接收大文件）与探测响应/错误
  void _startTransferListen() {
    if (_transferListenFuture != null) return;
    _transferListenFuture = _transferListenLoop().whenComplete(() {
      _transferListenFuture = null;
    });
  }

  Future<void> _transferListenLoop() async {
    while (_running && _transferReader != null) {
      try {
        final header = await readHeader(_transferReader!);
        if (header == null) break;
        final type = header['type'] as String?;
        final bodyLen = (header['length'] as num?)?.toInt() ?? 0;
        if (type == 'file' && bodyLen > 0) {
          // 接收大文件：流式落盘（气泡 + 进度条宿主）
          final filename = header['filename'] as String? ?? 'received_file';
          final target = _prepareReceiveTarget(filename);
          final fileId =
              header['message_id'] as String? ?? _generateMessageId();
          _handleFileMessage(header, target);
          state.updateTransfer(fileId, 0, bodyLen);
          final written = await readFileBody(
            _transferReader!,
            bodyLen,
            target,
            onProgress: (received, total) {
              _updateTransferThrottled(fileId, received, total);
            },
          );
          state.removeTransfer(fileId);
          if (written != bodyLen) break;
        } else {
          final body = await readBody(_transferReader!, bodyLen);
          if (body == null) break;
          _handleTransferMessage(header, body);
        }
      } catch (e) {
        state.log('传输通道异常: $e');
        break;
      }
    }
    // 通道关闭：清理引用（发送方探测等待表一并唤醒，避免悬挂）
    for (final c in _pendingFileChecks.values.toList()) {
      if (!c.isCompleted) c.complete(false);
    }
    _pendingFileChecks.clear();
    _closeTransferSocket();
  }

  /// 传输通道消息分发：探测响应 / 错误提示
  void _handleTransferMessage(Map<String, dynamic> header, Uint8List body) {
    final type = header['type'] as String?;
    switch (type) {
      case 'file_check_response':
        final checkId = header['message_id'] as String?;
        if (checkId != null) {
          _pendingFileChecks.remove(checkId)?.complete(header['ok'] == '1');
        }
        break;
      case 'error':
        final errorText = utf8.decode(body);
        for (final c in _pendingFileChecks.values.toList()) {
          if (!c.isCompleted) c.complete(false);
        }
        _pendingFileChecks.clear();
        state.log('传输通道错误: $errorText');
        state.showNotice('错误: $errorText');
        break;
      default:
        state.log('传输通道未处理的消息类型: $type');
    }
  }

  // ============================================================
  // 认证
  // ============================================================

  /// 登录
  Future<String?> login(
    String username,
    String password, {
    String? adminSecret,
  }) async {
    if (_socket == null) return '未连接到服务器';

    final extraHeaders = <String, String>{'password': password};
    if (adminSecret != null && adminSecret.isNotEmpty) {
      extraHeaders['admin_secret'] = adminSecret;
    }

    await _sendMessage('login', username, extraHeaders: extraHeaders);

    // 等待登录响应（阻塞式，在启动监听前处理初始数据）
    final (header, body) = await recvMessage(_reader!, chunkSize: 65536);
    if (header == null) return '服务器无响应';

    final type = header['type'] as String?;
    if (type == 'error') {
      return utf8.decode(body ?? Uint8List(0));
    }

    final isAdmin = type == 'admin_auth';
    state.setLoggedIn(username, isAdmin);

    // 保存凭据以备重连（仅内存）
    _saveCredentials(username, password, adminSecret);

    // 接收初始数据：离线消息 + 好友列表 + 群组列表
    await _receiveInitialData();

    // 启动后台消息监听
    _startListening();

    // 启动心跳
    _startKeepalive();

    // 建立大文件传输通道（异步，不阻塞登录流程）
    unawaited(_ensureTransferConnection());

    return null; // null = 成功
  }

  /// 注册
  Future<String?> register(
    String username,
    String password, {
    String? adminSecret,
  }) async {
    if (_socket == null) return '未连接到服务器';

    final extraHeaders = <String, String>{'password': password};
    if (adminSecret != null && adminSecret.isNotEmpty) {
      extraHeaders['admin_secret'] = adminSecret;
    }

    await _sendMessage('register', username, extraHeaders: extraHeaders);

    final (header, body) = await recvMessage(_reader!, chunkSize: 65536);
    if (header == null) return '服务器无响应';

    final type = header['type'] as String?;
    if (type == 'error') {
      return utf8.decode(body ?? Uint8List(0));
    }

    final isAdmin = type == 'admin_auth';
    state.setLoggedIn(username, isAdmin);

    // 保存凭据以备重连（仅内存）
    _saveCredentials(username, password, adminSecret);

    // 接收初始数据
    await _receiveInitialData();

    // 启动后台消息监听
    _startListening();

    // 启动心跳
    _startKeepalive();

    // 建立大文件传输通道（异步，不阻塞注册流程）
    unawaited(_ensureTransferConnection());

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
      final header = await readHeader(_reader!);
      if (header == null) break;

      final type = header['type'] as String?;
      final bodyLen = (header['length'] as num?)?.toInt() ?? 0;
      final initMsgId = header['message_id'] as String? ?? '';
      final from = header['from'] as String?;
      final isHistory = header['history'] == 'true';
      final msgTimestamp = _parseTimestamp(header['timestamp'] as String?);
      final msgStatus = header['status'] as String? ?? 'delivered';
      // file 消息体流式落盘（阶段 G 大文件支持），其余读入内存
      final dynamic body;
      if (type == 'file' && bodyLen > 0) {
        final filename = header['filename'] as String? ?? 'file';
        final target = _prepareReceiveTarget(filename);
        // 先添加历史消息气泡（进度条宿主），再流式接收
        if (isHistory && from != null) {
          final to = header['to'] as String?;
          final chatKey = (from == state.username && to != null) ? to : from;
          state.addMessage(
            chatKey,
            ChatMessage(
              sender: from,
              content: '[文件] $filename',
              type: 'file',
              messageId: initMsgId,
              filename: filename,
              timestamp: msgTimestamp,
              isHistory: false,
              status: msgStatus,
            ),
          );
        }
        _receivingFile = true;
        // 接收期间 pong 会被服务端抑制：清掉未决 ping 状态，
        // 避免看门狗在传输结束后用陈旧基线误判超时
        _pingOutstanding = false;
        _pongWatchdog?.cancel();
        _pongWatchdog = null;
        state.updateTransfer(initMsgId, 0, bodyLen);
        final written = await readFileBody(
          _reader!,
          bodyLen,
          target,
          onProgress: (received, total) {
            _updateTransferThrottled(initMsgId, received, total);
          },
        );
        _receivingFile = false;
        state.removeTransfer(initMsgId);
        if (written != bodyLen) break;
        body = target;
      } else {
        body = await readBody(_reader!, bodyLen);
        if (body == null) break;
      }

      final messageId = header['message_id'] as String? ?? _generateMessageId();

      switch (type) {
        case 'chat':
          final text = utf8.decode(body as Uint8List);
          if (isHistory) {
            final sender = from ?? '系统';
            final isSystemSender =
                sender == '系统' || sender == '服务器' || sender.startsWith('[');
            if (isSystemSender) {
              if (sender == '[系统公告]') {
                state.addMessage(
                  '服务器',
                  ChatMessage(
                    sender: sender,
                    content: text,
                    type: 'system',
                    messageId: messageId,
                    timestamp: msgTimestamp,
                    status: msgStatus,
                  ),
                );
              } else {
                state.showNotice(text);
              }
            } else {
              final to = header['to'] as String?;
              final chatKey = (from != null && from == state.username)
                  ? (to ?? from)
                  : sender;
              state.addMessage(
                chatKey,
                ChatMessage(
                  sender: sender,
                  content: text,
                  type: 'chat',
                  messageId: messageId,
                  timestamp: msgTimestamp,
                  isHistory: false,
                  status: msgStatus,
                ),
              );
            }
          }
          break;

        case 'file':
          // history=true 的离线文件：气泡与进度已在流式接收前添加
          // （String 路径情况直接跳过；bytes 为旧路径防御保留）
          if (isHistory && from != null && body is Uint8List) {
            final filename = header['filename'] as String? ?? 'file';
            final to = header['to'] as String?;
            final chatKey = (from == state.username && to != null) ? to : from;
            _saveReceivedFile(filename, body);
            state.addMessage(
              chatKey,
              ChatMessage(
                sender: from,
                content: '[文件] $filename',
                type: 'file',
                messageId: messageId,
                filename: filename,
                fileData: body,
                timestamp: msgTimestamp,
                isHistory: false,
                status: msgStatus,
              ),
            );
          }
          break;

        case 'group_chat':
          if (isHistory && from != null) {
            final groupId = header['group_id'] as String?;
            final chatKey = groupId != null ? 'group_$groupId' : (from);
            final text = utf8.decode(body as Uint8List);
            state.addMessage(
              chatKey,
              ChatMessage(
                sender: from,
                content: text,
                type: 'group_chat',
                messageId: messageId,
                timestamp: msgTimestamp,
                isHistory: false,
                status: msgStatus,
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

        case 'friend_request':
          if (from != null) {
            state.addPendingRequest(from);
            state.log('收到好友请求: $from');
          }
          break;

        case 'admin_response':
          final responseType = header['response_type'] as String?;
          if (responseType == 'list_friends') {
            final friendsJson = utf8.decode(body as Uint8List);
            try {
              final List<dynamic> list = jsonDecode(friendsJson);
              state.setFriends(list.map((e) => e.toString()).toList());
              gotFriendList = true;
            } catch (_) {}
          }
          break;

        case 'list_groups':
          final groupsJson = utf8.decode(body as Uint8List);
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
    if (_listenFuture != null) return;
    _listenFuture = _listenLoop().whenComplete(() {
      _listenFuture = null;
    });
  }

  Future<void> _listenLoop() async {
    while (_running && _reader != null) {
      try {
        // 分步读取：file 消息体流式落盘（阶段 G 大文件支持），其余读入内存
        final header = await readHeader(_reader!);
        if (header == null) {
          // 连接断开
          if (_running && !_intentionalDisconnect) {
            // 网络断开：触发自动重连（保留状态）
            state.log('与服务器的连接已断开（recv 返回 null）');
            _onConnectionLost();
          } else if (_running && _intentionalDisconnect) {
            state.log('已主动断开连接');
          }
          break;
        }
        final type = header['type'] as String?;
        final bodyLen = (header['length'] as num?)?.toInt() ?? 0;
        if (type == 'file' && bodyLen > 0) {
          final filename = header['filename'] as String? ?? 'received_file';
          final target = _prepareReceiveTarget(filename);
          final fileId =
              header['message_id'] as String? ?? _generateMessageId();
          // 先添加消息气泡（进度条宿主），再流式接收
          _handleFileMessage(header, target);
          _receivingFile = true;
          // 接收期间 pong 会被服务端抑制：清掉未决 ping 状态，
          // 避免看门狗在传输结束后用陈旧基线误判超时
          _pingOutstanding = false;
          _pongWatchdog?.cancel();
          _pongWatchdog = null;
          state.updateTransfer(fileId, 0, bodyLen);
          final written = await readFileBody(
            _reader!,
            bodyLen,
            target,
            onProgress: (received, total) {
              _updateTransferThrottled(fileId, received, total);
            },
          );
          _receivingFile = false;
          state.removeTransfer(fileId);
          if (written != bodyLen) {
            // 文件接收不完整 → 视为连接断开
            if (_running && !_intentionalDisconnect) {
              state.log('文件接收不完整（$written/$bodyLen），判定连接断开');
              _onConnectionLost();
            }
            break;
          }
        } else {
          final body = await readBody(_reader!, bodyLen);
          if (body == null) {
            if (_running && !_intentionalDisconnect) {
              state.log('与服务器的连接已断开（body 读取失败）');
              _onConnectionLost();
            }
            break;
          }
          _handleMessage(header, body);
        }
      } catch (e) {
        // recvMessage 抛异常（SocketException / FormatException 等）
        // 视为连接断开，触发重连而非静默退出
        state.log('监听循环异常，判定连接断开: $e');
        if (_running && !_intentionalDisconnect) {
          _onConnectionLost();
        }
        break;
      }
    }
  }

  /// 处理收到的文件消息（内容已流式落盘到 [filePath]）
  void _handleFileMessage(Map<String, dynamic> header, String filePath) {
    final filename = header['filename'] as String? ?? 'received_file';
    final sender = header['from'] ?? '未知';
    final messageId = header['message_id'] as String? ?? _generateMessageId();
    final isHistory = header['history'] == 'true';

    if (isHistory) {
      // 离线文件历史（history=true）
      final to = header['to'] as String?;
      final chatKey = (sender == state.username && to != null) ? to : sender;
      state.addMessage(
        chatKey,
        ChatMessage(
          sender: sender,
          content: '[文件] $filename',
          type: 'file',
          messageId: messageId,
          filename: filename,
          isHistory: false,
          status: header['status'] as String? ?? 'delivered',
        ),
      );
      return;
    }

    state.addMessage(
      sender,
      ChatMessage(
        sender: sender,
        content: '[收到文件] $filename',
        type: 'file',
        messageId: messageId,
        filename: filename,
        status: 'delivered',
      ),
    );
  }

  /// 任务栏闪烁（阶段 H2，类微信）：新消息到达时交给 TaskbarNotifier
  /// 判定是否闪烁。文件/公告气泡使用 delivered 状态，但提醒语义为"新到达"，
  /// 统一以 sent 判定。
  void _notifyIncoming(ChatMessage msg, String chatKey) {
    TaskbarNotifier.maybeFlashForMessage(
      ChatMessage(
        sender: msg.sender,
        content: msg.content,
        type: msg.type,
        messageId: msg.messageId,
        status: 'sent',
        filename: msg.filename,
      ),
      chatKey,
    );
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
        // 系统来源消息：公告 → 系统消息会话；其余 → 临时通知
        final isSystemSender =
            sender == '系统' || sender == '服务器' || sender.startsWith('[');
        if (isSystemSender) {
          if (sender == '[系统公告]') {
            // 管理员公告 → 进入系统消息会话
            final msg = ChatMessage(
              sender: sender,
              content: text,
              type: 'system',
              messageId: messageId,
              status: 'delivered',
            );
            state.addMessage('服务器', msg);
            // 桌面通知（阶段 H2）：未聚焦窗口时通知系统公告
            _notifyIncoming(msg, '服务器');
          } else {
            // 其他系统消息（操作确认、离线提示等）→ SnackBar 通知
            state.showNotice(text);
            // 修改密码成功（阶段 G3）：更新内存凭据，保证断线重连仍可登录
            if (text.contains('密码修改成功') && _pendingPasswordChange != null) {
              _savedPassword = _pendingPasswordChange;
              _pendingPasswordChange = null;
            }
          }
          // 检测好友请求被接受的系统通知，自动刷新好友列表
          if (sender == '系统' &&
              (text.contains('已接受') || text.contains('接受您的好友请求'))) {
            _requestFriendList();
          }
        } else {
          // 好友私聊
          final msg = ChatMessage(
            sender: sender,
            content: text,
            type: 'chat',
            messageId: messageId,
            status: 'sent',
          );
          state.addMessage(sender, msg);
          // 桌面通知（阶段 H2）：未聚焦窗口时通知新私聊消息
          _notifyIncoming(msg, sender);
          // 自动发送回执
          if (from != null && !isHistory) {
            _sendReceipt(messageId, from);
          }
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
          // 桌面通知（阶段 H2）：未聚焦窗口时通知收到文件请求
          _notifyIncoming(
            ChatMessage(
              sender: from,
              content: '[文件请求] ${header['filename'] as String? ?? 'file'}',
              type: 'file_request',
              messageId: messageId,
              status: 'sent',
              filename: header['filename'] as String?,
            ),
            from,
          );
        }
        break;

      // ---- 文件数据（接受后服务端转发） ----
      case 'file':
        final filename = header['filename'] as String? ?? 'received_file';
        final sender = from ?? '未知';
        final msg = ChatMessage(
          sender: sender,
          content: '[收到文件] $filename',
          type: 'file',
          messageId: messageId,
          filename: filename,
          fileData: body,
          status: 'delivered',
        );
        state.addMessage(sender, msg);
        // 桌面通知（阶段 H2）：未聚焦窗口时通知收到文件
        _notifyIncoming(msg, sender);
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
        final chatKey = groupId != null ? 'group_$groupId' : (from ?? '群组');
        final text = utf8.decode(body);
        final sender = from ?? '未知';
        final msg = ChatMessage(
          sender: sender,
          content: text,
          type: 'group_chat',
          messageId: messageId,
          status: 'sent',
          groupId: groupId != null ? int.tryParse(groupId) : null,
        );
        state.addMessage(chatKey, msg);
        // 桌面通知（阶段 H2）：未聚焦窗口时通知群聊消息
        _notifyIncoming(msg, chatKey);
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
              filesize: int.tryParse(header['filesize'] as String? ?? '0') ?? 0,
              groupId: groupId != null ? int.tryParse(groupId) : null,
            ));
            // 桌面通知（阶段 H2）：未聚焦窗口时通知收到群文件请求
            _notifyIncoming(
              ChatMessage(
                sender: from,
                content: '[群文件请求] ${header['filename'] as String? ?? 'file'}',
                type: 'group_file_request',
                messageId: messageId,
                status: 'sent',
                filename: header['filename'] as String?,
              ),
              groupId != null ? 'group_$groupId' : from,
            );
          }
        }
        break;

      // ---- 心跳响应 ----
      case 'pong':
        // pong 已到：取消看门狗，允许下一个 ping 周期
        _pingOutstanding = false;
        _pongWatchdog?.cancel();
        _pongWatchdog = null;
        break;

      // ---- 大文件直传探测响应（阶段 G4b）----
      case 'file_check_response':
        final checkId = header['message_id'] as String?;
        if (checkId != null) {
          _pendingFileChecks.remove(checkId)?.complete(header['ok'] == '1');
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

      // ---- 删除好友通知（阶段 F）----
      case 'delete_friend':
        final deleter = header['from'] as String?;
        if (deleter != null) {
          state.removeFriend(deleter);
          state.showNotice('$deleter 已与你解除好友关系');
        }
        break;

      // ---- 历史消息分页响应（阶段 E）----
      case 'history_response':
        final withUser = header['to'] as String?;
        final groupId = header['group_id'] as String?;
        final chatKey = (groupId != null && groupId.isNotEmpty)
            ? 'group_$groupId'
            : ((withUser != null && withUser.isNotEmpty) ? withUser : null);
        if (chatKey == null) break;
        try {
          final List<dynamic> batch = jsonDecode(utf8.decode(body));
          final msgs = <ChatMessage>[];
          for (final item in batch) {
            final m = item as Map<String, dynamic>;
            final tsStr = m['timestamp'] as String?;
            DateTime? ts;
            if (tsStr != null) {
              try {
                // DB 存储的是 UTC 时间（YYYY-MM-DD HH:MM:SS），
                // 加 Z 后缀解析为 UTC，再转本地时间
                ts = DateTime.parse('${tsStr.trim()}Z').toLocal();
              } catch (_) {}
            }
            msgs.add(ChatMessage(
              sender: m['sender'] as String? ?? '',
              content: m['content'] as String? ?? '',
              type: m['type'] as String? ?? 'chat',
              messageId: m['message_id'] as String? ?? _generateMessageId(),
              filename: m['filename'] as String?,
              groupId:
                  m['group_id'] != null ? (m['group_id'] as num).toInt() : null,
              timestamp: ts,
              isHistory: true,
              status: m['status'] as String? ?? 'delivered',
            ));
          }
          if (batch.isEmpty) {
            // 服务端返回空 → 没有更旧的历史了
            state.setNoMoreHistory(chatKey);
          } else {
            state.prependHistoryMessages(chatKey, msgs);
          }
        } catch (e) {
          state.log('解析历史消息失败: $e');
        }
        break;

      // ---- 消息搜索响应（阶段 H5）----
      case 'search_response':
        final withUser = header['to'] as String?;
        final groupId = header['group_id'] as String?;
        final keyword = header['keyword'] as String? ?? '';
        final chatKey = (groupId != null && groupId.isNotEmpty)
            ? 'group_$groupId'
            : ((withUser != null && withUser.isNotEmpty) ? withUser : null);
        if (chatKey == null) break;
        try {
          final List<dynamic> batch = jsonDecode(utf8.decode(body));
          final msgs = <ChatMessage>[];
          for (final item in batch) {
            final m = item as Map<String, dynamic>;
            final tsStr = m['timestamp'] as String?;
            DateTime? ts;
            if (tsStr != null) {
              try {
                // DB 存储的是 UTC 时间（YYYY-MM-DD HH:MM:SS），
                // 加 Z 后缀解析为 UTC，再转本地时间
                ts = DateTime.parse('${tsStr.trim()}Z').toLocal();
              } catch (_) {}
            }
            msgs.add(ChatMessage(
              sender: m['sender'] as String? ?? '',
              content: m['content'] as String? ?? '',
              type: m['type'] as String? ?? 'chat',
              messageId: m['message_id'] as String? ?? _generateMessageId(),
              filename: m['filename'] as String?,
              groupId:
                  m['group_id'] != null ? (m['group_id'] as num).toInt() : null,
              timestamp: ts,
              isHistory: true,
              status: m['status'] as String? ?? 'delivered',
            ));
          }
          // 服务端按时间倒序返回（最新在前），聊天展示需旧→新，翻转后写入
          state.setSearchResults(chatKey, msgs.reversed.toList(),
              query: keyword);
        } catch (e) {
          state.log('解析搜索结果失败: $e');
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
              buf.writeln(
                  '  $uname ${online ? "🟢" : "⚪"}${admin ? " [管理员]" : ""}');
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
        } else if (responseType == 'list_group_members') {
          final groupId = header['group_id'] as String?;
          if (groupId != null) {
            try {
              final List<dynamic> list = jsonDecode(responseBody);
              final members = list.map((e) => e.toString()).toList();
              final gid = int.tryParse(groupId);
              if (gid != null) {
                state.updateGroupMembers(gid, members);
              }
            } catch (_) {
              state.log('解析群成员列表失败: $responseBody');
            }
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
            list.map((e) => Group.fromJson(e as Map<String, dynamic>)).toList(),
          );
        } catch (_) {}
        break;

      // ---- 错误消息 ----
      case 'error':
        final errorText = utf8.decode(body);
        // 大文件探测失败（离线/群组/不存在）→ 唤醒等待的发送流程
        if (_pendingFileChecks.isNotEmpty) {
          for (final c in _pendingFileChecks.values.toList()) {
            if (!c.isCompleted) c.complete(false);
          }
          _pendingFileChecks.clear();
        }
        if (errorText.contains('已在其他地方登录')) {
          // 重复登录被强制下线（阶段 G1）：不触发重连，通知后回登录页
          state.log('已在其他地方登录，强制下线');
          state.showNotice(errorText);
          disconnect();
        } else {
          state.log('错误: $errorText');
          state.showNotice('错误: $errorText');
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
  /// 阶段 I1：断线（未连接）时消息进入本地 pending 队列（'sending' 气泡），
  /// 重连成功后自动补发；已连接时直接发送，异常转为 failed 入队（不静默丢失）。
  Future<bool> sendChat(String to, String content) async {
    if (!state.isLoggedIn) return false;
    final text = content.trim();
    if (text.isEmpty) return false;
    final messageId = _generateMessageId();
    if (_socket == null) {
      final msg = ChatMessage(
        sender: state.username!,
        content: text,
        type: 'chat',
        messageId: messageId,
        status: 'sending',
      );
      state.addMessage(to, msg);
      state.enqueuePendingMessage(to, msg);
      return true;
    }
    try {
      await _sendMessage('chat', text, extraHeaders: {
        'to': to,
        'message_id': messageId,
      });
      state.addMessage(
        to,
        ChatMessage(
          sender: state.username!,
          content: text,
          type: 'chat',
          messageId: messageId,
          status: 'sent',
        ),
      );
      return true;
    } catch (e) {
      final msg = ChatMessage(
        sender: state.username!,
        content: text,
        type: 'chat',
        messageId: messageId,
        status: 'sending',
      );
      state.addMessage(to, msg);
      state.enqueuePendingMessage(to, msg);
      state.markPendingFailed(messageId);
      state.log('发送失败，已加入待重试队列: $e');
      return false;
    }
  }

  /// 发送群聊消息
  /// 阶段 I1：断线时入队（chatKey='group_N'），失败标记 failed 可重试。
  Future<bool> sendGroupChat(int groupId, String content) async {
    if (!state.isLoggedIn) return false;
    final text = content.trim();
    if (text.isEmpty) return false;
    final messageId = _generateMessageId();
    final chatKey = 'group_$groupId';
    if (_socket == null) {
      final msg = ChatMessage(
        sender: state.username!,
        content: text,
        type: 'group_chat',
        messageId: messageId,
        status: 'sending',
        groupId: groupId,
      );
      state.addMessage(chatKey, msg);
      state.enqueuePendingMessage(chatKey, msg);
      return true;
    }
    try {
      await _sendMessage('group_chat', text, extraHeaders: {
        'group_id': groupId.toString(),
        'message_id': messageId,
      });
      state.addMessage(
        chatKey,
        ChatMessage(
          sender: state.username!,
          content: text,
          type: 'group_chat',
          messageId: messageId,
          status: 'sent',
          groupId: groupId,
        ),
      );
      return true;
    } catch (e) {
      final msg = ChatMessage(
        sender: state.username!,
        content: text,
        type: 'group_chat',
        messageId: messageId,
        status: 'sending',
        groupId: groupId,
      );
      state.addMessage(chatKey, msg);
      state.enqueuePendingMessage(chatKey, msg);
      state.markPendingFailed(messageId);
      state.log('群聊发送失败，已加入待重试队列: $e');
      return false;
    }
  }

  /// 重试发送失败的 pending 消息（阶段 I1）
  /// 未连接：复位为"发送中"，等待重连自动补发（返回 false）；
  /// 已连接：立即重发，成功出队（true）/ 失败保持 failed（false）。
  Future<bool> retryPendingMessage(String messageId) async {
    PendingMessage? entry;
    for (final e in state.pendingMessages) {
      if (e.message.messageId == messageId) {
        entry = e;
        break;
      }
    }
    if (entry == null) return false;
    state.markPendingSending(messageId);
    if (_socket == null) return false;
    try {
      final msg = entry.message;
      if (entry.chatKey.startsWith('group_')) {
        final groupId = int.tryParse(entry.chatKey.substring(6));
        if (groupId == null) {
          state.markPendingFailed(messageId);
          return false;
        }
        await _sendMessage('group_chat', msg.content, extraHeaders: {
          'group_id': groupId.toString(),
          'message_id': messageId,
        });
      } else {
        await _sendMessage('chat', msg.content, extraHeaders: {
          'to': entry.chatKey,
          'message_id': messageId,
        });
      }
      state.markPendingSent(messageId);
      return true;
    } catch (e) {
      state.markPendingFailed(messageId);
      state.log('重试发送失败: $e');
      return false;
    }
  }

  /// 补发 pending 队列（阶段 I1：重连成功后自动调用，也可手动触发）
  /// 返回本次实际发出的条数。
  ///
  /// 每次重连都尝试补发**全部**队列条目（含此前补发失败的 failed 条目）：
  /// 服务端按 (message_id, sender) 幂等去重，已送达的重发会被丢弃，不会二次
  /// 下发；重连时的离线历史回显也会先把已入库消息自动出队。因此"每次重连
  /// 全量补发"既能保证断线消息最终送达（不再依赖第二次重连），又不产生重复。
  Future<int> flushPendingQueue() async {
    if (_socket == null) return 0;
    final entries = state.pendingMessages.toList();
    int sent = 0;
    for (final entry in entries) {
      if (await retryPendingMessage(entry.message.messageId)) sent++;
    }
    return sent;
  }

  /// 发送文件
  /// 阶段 G4：发送前预检查文件大小（不先读入内存）；大文件流式分块发送
  /// 阶段 G4b：>300MB 走专用传输通道（探测在线 + 在线直传 / 离线提示失败）。
  ///   大文件在主连接之外收发：传输期间发送方的文字消息不被阻塞，
  ///   接收方的聊天也不被抑制——这是问题2（传输中消息无法送达）的根治。
  /// 小文件（<= 阈值）仍走主连接（秒级完成，无阻塞问题）。
  /// 进度条显示在本地消息气泡上（非模态局部刷新）。
  Future<bool> sendFile(String to, String filePath, String filename) async {
    if (_socket == null) return false;
    final messageId = _generateMessageId();
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        state.showNotice('文件不存在');
        return false;
      }
      final size = await file.length();
      if (size > AppConfig.maxFileSize) {
        final limitStr = AppConfig.maxFileSize >= 1024 * 1024 * 1024
            ? '${(AppConfig.maxFileSize / (1024 * 1024 * 1024)).floor()} GB'
            : '${(AppConfig.maxFileSize / (1024 * 1024)).floor()} MB';
        state.showNotice('文件过大，超出大小限制（最大 $limitStr）');
        return false;
      }
      final isLarge = size > AppConfig.largeFileThreshold;
      if (isLarge) {
        // 大文件：确保传输通道就绪，再探测目标是否在线
        final channelOk = await _ensureTransferConnection();
        if (!channelOk) {
          state.showNotice('传输通道不可用，请重试');
          return false;
        }
        final ok = await _checkLargeFileTransfer(to, size, filename, messageId);
        if (!ok) {
          state.showNotice('对方离线或不可用，无法传输大文件');
          return false;
        }
      }
      // 先添加本地消息气泡（进度条宿主），再开始流式发送
      state.addMessage(
        to,
        ChatMessage(
          sender: state.username!,
          content: '[发送文件] $filename',
          type: 'file',
          messageId: messageId,
          filename: filename,
          status: 'sent',
        ),
      );
      state.updateTransfer(messageId, 0, size, isSend: true);
      if (isLarge) {
        // 大文件：经传输通道发送，主连接保持空闲（聊天畅通）
        await _transferEnqueue(() => sendFileMessage(
              _transferSocket!,
              'file',
              filePath,
              extraHeaders: {
                'to': to,
                'filename': filename,
                'filesize': size.toString(),
                'message_id': messageId,
              },
              onProgress: (sent, total) {
                _updateTransferThrottled(messageId, sent, total, isSend: true);
              },
            ));
      } else {
        await _enqueueSend(() => sendFileMessage(
              _socket!,
              'file',
              filePath,
              extraHeaders: {
                'to': to,
                'filename': filename,
                'filesize': size.toString(),
                'message_id': messageId,
              },
              onProgress: (sent, total) {
                _updateTransferThrottled(messageId, sent, total, isSend: true);
              },
            ));
      }
      state.removeTransfer(messageId);
      return true;
    } catch (e) {
      state.removeTransfer(messageId);
      state.log('文件发送失败: $e');
      // 主连接发送失败通常意味着连接已死 → 触发重连恢复；
      // 传输通道失败只影响本次传输（主连接不受影响，不重连）
      if (e is SocketException || e is StateError) {
        _onConnectionLost();
      }
      return false;
    }
  }

  /// 大文件直传探测（阶段 G4b）：等待服务器确认目标在线。
  /// 经传输通道发送，主连接不占用。
  Future<bool> _checkLargeFileTransfer(
      String to, int size, String filename, String messageId) async {
    if (_transferSocket == null) return false;
    final completer = Completer<bool>();
    _pendingFileChecks[messageId] = completer;
    try {
      await _transferEnqueue(() => sendMessage(
            _transferSocket!,
            'file_transfer_check',
            '',
            extraHeaders: {
              'to': to,
              'filesize': size.toString(),
              'filename': filename,
              'message_id': messageId,
            },
          ));
      return await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          _pendingFileChecks.remove(messageId);
          return false;
        },
      );
    } catch (e) {
      _pendingFileChecks.remove(messageId);
      state.log('大文件探测失败: $e');
      return false;
    }
  }

  /// 修改密码（阶段 G3）
  /// 发送 change_password 协议；结果由服务端响应（SnackBar 通知）反馈，
  /// 成功时自动更新内存凭据以支持断线重连。
  Future<bool> changePassword(String oldPassword, String newPassword) async {
    if (_socket == null) return false;
    try {
      _pendingPasswordChange = newPassword;
      await _sendMessage('change_password', '', extraHeaders: {
        'old_password': oldPassword,
        'new_password': newPassword,
      });
      return true;
    } catch (e) {
      _pendingPasswordChange = null;
      state.log('修改密码请求失败: $e');
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
    await _sendMessage(
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
    await _sendMessage(
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
    await _sendMessage(
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
    await _sendMessage(
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
    await _sendMessage(
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
      await _sendMessage('list_friends', '');
    } catch (_) {}
  }

  /// 创建群组
  Future<void> createGroup(String groupName) async {
    if (_socket == null) return;
    await _sendMessage('create_group', groupName);
    state.log('群组 "$groupName" 创建请求已发送');
  }

  /// 加入群组
  Future<void> joinGroup(int groupId) async {
    if (_socket == null) return;
    await _sendMessage('join_group', groupId.toString());
    state.log('加入群组 $groupId 请求已发送');
  }

  /// 撤回消息
  Future<void> recallMessage(String messageId, String target) async {
    if (_socket == null) return;
    // 不在此处乐观更新本地状态；等服务端撤回成功后回发 recall 确认再更新
    // 这样撤回失败（超时等）时消息保持原样，不会丢失内容
    await _sendMessage('recall', '', extraHeaders: {
      'message_id': messageId,
      'to': target,
    });
  }

  /// 拉取历史消息（阶段 E 分页）
  /// [to] 私聊对方用户名；[groupId] 群组 ID；两者二选一
  /// [beforeMessageId] 游标：拉取此消息之前的消息；首次拉取传 null
  /// [limit] 每页数量，默认 50
  Future<void> fetchHistory({
    String? to,
    int? groupId,
    String? beforeMessageId,
    int limit = 50,
  }) async {
    if (_socket == null) return;
    final extra = <String, String>{'limit': limit.toString()};
    if (to != null) extra['to'] = to;
    if (groupId != null) extra['group_id'] = groupId.toString();
    if (beforeMessageId != null) extra['before_message_id'] = beforeMessageId;
    try {
      await _sendMessage('fetch_history', '', extraHeaders: extra);
    } catch (e) {
      state.log('拉取历史消息失败: $e');
    }
  }

  /// 搜索历史消息（阶段 H5）
  /// [to] 私聊对方用户名（可选，缺省全局搜索）
  /// [groupId] 群组 ID（可选，群聊范围搜索）
  /// [limit] 返回数量上限，默认 50
  Future<void> searchHistory(String keyword,
      {String? to, int? groupId, int limit = 50}) async {
    if (_socket == null) return;
    final extra = <String, String>{
      'keyword': keyword,
      'limit': limit.toString(),
    };
    if (to != null) extra['to'] = to;
    if (groupId != null) extra['group_id'] = groupId.toString();
    try {
      await _sendMessage('search_history', '', extraHeaders: extra);
    } catch (e) {
      state.log('搜索消息失败: $e');
    }
  }

  /// 发送回执
  Future<void> _sendReceipt(String messageId, String to) async {
    if (_socket == null) return;
    try {
      await _sendMessage('receipt', '', extraHeaders: {
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
    await _sendMessage('admin_command', content, extraHeaders: extraHeaders);
  }

  /// 删除好友（阶段 F）
  Future<void> deleteFriend(String targetUser) async {
    if (_socket == null) return;
    await _sendMessage('delete_friend', '', extraHeaders: {
      'to': targetUser,
    });
    state.removeFriend(targetUser);
    state.showNotice('已删除好友 $targetUser');
    await _requestFriendList();
  }

  /// 退出群组（阶段 F）
  Future<void> leaveGroup(int groupId) async {
    if (_socket == null) return;
    await _sendMessage('leave_group', '', extraHeaders: {
      'group_id': groupId.toString(),
    });
  }

  /// 拉取群成员列表（阶段 F）
  Future<void> fetchGroupMembers(int groupId) async {
    if (_socket == null) return;
    try {
      await _sendMessage('list_group_members', '',
          extraHeaders: {'group_id': groupId.toString()});
    } catch (e) {
      state.log('拉取群成员列表失败: $e');
    }
  }

  /// 文件名安全过滤（阶段 G5）：去除路径分隔符，防止路径穿越。
  /// 返回 basename；空 / "." / ".." 时回退为 received_file。
  static String sanitizeFilename(String filename) {
    final base = filename.split(RegExp(r'[/\\]')).last;
    if (base.isEmpty || base == '.' || base == '..') {
      return 'received_file';
    }
    return base;
  }

  /// 准备接收文件的目标路径（安全文件名 + 确保目录存在）
  String _prepareReceiveTarget(String filename) {
    final safeName = sanitizeFilename(filename);
    final dir = Directory(AppConfig.receivedFilesDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return '${dir.path}/$safeName';
  }

  /// 保存接收到的文件
  void _saveReceivedFile(String filename, Uint8List data) {
    try {
      final safeName = sanitizeFilename(filename);
      final dir = Directory(AppConfig.receivedFilesDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final file = File('${dir.path}/$safeName');
      file.writeAsBytesSync(data);
      state.log('文件已保存: ${file.path}');
    } catch (e) {
      state.log('文件保存失败: $e');
    }
  }
}
