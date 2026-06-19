// ============================================================
// 聊天室自定义二进制协议 —— Dart 实现
// ============================================================
//
// 协议版本 —— 已冻结 (1.0.0)
// 此版本号作为所有客户端与服务端的通信契约。
// 任何破坏性修改必须递增版本号，旧版本客户端应收到兼容性错误。
//
// 帧格式:
//   ┌──────────────────────────────────────────────────────┐
//   │  4 bytes (big-endian)  │  JSON Header (UTF-8)  │  Body  │
//   │   header length        │  {type, length, ...}  │  bytes  │
//   └──────────────────────────────────────────────────────┘
//
// 本文件是 protocol.py 的 Dart 等价实现，目标：
//   - 编解码逻辑与 Python 版本 100% 兼容
//   - 支持文本消息和二进制文件传输
//   - 支持分块传输（默认 4MB chunk）
//   - 防御性类型转换（extra_headers 全部转为字符串）
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 协议版本号（已冻结，不可随意修改）
const String protocolVersion = '1.0.0';

// ============================================================
// 发送消息
// ============================================================

/// 通过 [sock] 发送一条协议消息。
///
/// [sock] 已连接的 Socket
/// [msgType] 消息类型，如 'chat', 'file', 'login' 等
/// [content] 消息体：文本消息传 String，文件传 Uint8List 或 List<int>
/// [extraHeaders] 可选的附加头部字段（key/value 均会强制转为字符串）
/// [chunkSize] 消息体分块大小（字节），默认 4MB
///
/// 发送流程：
///   1. 将 content 转为字节（字符串用 UTF-8 编码）
///   2. 把 extraHeaders 的所有 key/value 转为字符串
///   3. 构造 JSON 头: {"type": msgType, "length": len, ...extraHeaders}
///   4. 发送：4字节头长度(大端) → JSON头字节 → 分块发送消息体
Future<void> sendMessage(
  Socket sock,
  String msgType,
  dynamic content, {
  Map<String, dynamic>? extraHeaders,
  int chunkSize = 4 * 1024 * 1024,
}) async {
  extraHeaders ??= {};

  // --- 将消息体转为字节 ---
  final Uint8List contentBytes;
  if (content is String) {
    contentBytes = Uint8List.fromList(utf8.encode(content));
  } else if (content is Uint8List) {
    contentBytes = content;
  } else if (content is List<int>) {
    contentBytes = Uint8List.fromList(content);
  } else {
    throw ArgumentError(
      'content must be String, Uint8List, or List<int>, got ${content.runtimeType}',
    );
  }

  // --- 构造消息头 ---
  // length 字段为整数（JSON 序列化为数字），与 Python 版本一致
  final Map<String, dynamic> header = {
    'type': msgType,
    'length': contentBytes.length,
  };
  // 防御性类型转换：extra_headers 的所有 key/value 强制转为字符串
  // 防止数字类型的用户名/ID 导致 JSON 序列化异常
  for (final entry in extraHeaders.entries) {
    header[entry.key.toString()] = entry.value.toString();
  }

  final List<int> headerJson = utf8.encode(jsonEncode(header));

  // --- 打包 4 字节头长度（大端序） ---
  final ByteData headerLenBuf = ByteData(4);
  headerLenBuf.setUint32(0, headerJson.length, Endian.big);

  // --- 发送 ---
  // 1. 4字节头长度
  sock.add(headerLenBuf.buffer.asUint8List());
  // 2. JSON 消息头
  sock.add(headerJson);
  // 3. 消息体（分块发送）
  for (int i = 0; i < contentBytes.length; i += chunkSize) {
    final int end =
        (i + chunkSize < contentBytes.length) ? i + chunkSize : contentBytes.length;
    sock.add(contentBytes.sublist(i, end));
  }

  // 确保数据刷新到底层 socket
  await sock.flush();
}

// ============================================================
// 消息读取器（封装 socket 的缓冲式读取）
// ============================================================

/// 封装 Socket 的缓冲式字节读取器。
///
/// TCP 是流协议，一次 recv() 可能返回任意数量的字节。
/// MessageReader 在内部维护接收缓冲区，提供 [recvall] 方法
/// 确保精确读取 N 字节——与 Python 版 recvall() 行为一致。
class MessageReader {
  final Socket _socket;
  StreamSubscription<Uint8List>? _subscription;

  /// 内部字节缓冲区，累积所有已收到但尚未被消费的数据
  final List<int> _buffer = [];

  /// 当有新数据到达或流结束时触发，唤醒等待中的 recvall
  Completer<void>? _dataCompleter;

  /// 底层流是否已结束（socket 关闭或出错）
  bool _streamDone = false;

  /// 创建读取器并开始监听 [socket] 的数据流。
  MessageReader(this._socket) {
    _subscription = _socket.listen(
      _onData,
      onDone: _onDone,
      onError: _onError,
    );
  }

  void _onData(Uint8List data) {
    _buffer.addAll(data);
    _resolvePending();
  }

  void _onDone() {
    _streamDone = true;
    _resolvePending();
  }

  void _onError(Object error) {
    _streamDone = true;
    _resolvePending();
  }

  /// 唤醒所有等待中的 recvall 调用
  void _resolvePending() {
    if (_dataCompleter != null && !_dataCompleter!.isCompleted) {
      _dataCompleter!.complete();
      _dataCompleter = null;
    }
  }

  /// 确保从 socket 精确读取 [n] 字节。
  ///
  /// 如果缓冲区中已有足够数据，立即返回。
  /// 否则等待新数据到达，循环直到收齐 [n] 字节或流结束。
  ///
  /// 返回 null 表示连接已关闭且数据不足（EOF）。
  Future<Uint8List?> recvall(int n) async {
    // 循环等待直到缓冲区中有足够数据，或流已结束
    while (_buffer.length < n && !_streamDone) {
      _dataCompleter = Completer<void>();
      await _dataCompleter!.future;
    }

    // 流已结束但数据不够 → EOF
    if (_buffer.length < n) {
      return null;
    }

    // 从缓冲区提取 n 字节
    final result = Uint8List.fromList(_buffer.sublist(0, n));
    _buffer.removeRange(0, n);
    return result;
  }

  /// 关闭读取器，取消底层流订阅。
  void close() {
    _subscription?.cancel();
    _streamDone = true;
    _resolvePending();
  }
}

// ============================================================
// 接收消息
// ============================================================

/// 从 [reader] 接收一条协议消息。
///
/// [reader] 是对已连接 Socket 的 MessageReader 封装
/// [chunkSize] 消息体分块读取大小（字节），默认 4MB
///
/// 返回 `(header, body)` 记录：
///   - header: Map<String, dynamic>，JSON 消息头
///   - body: Uint8List，消息体字节
///   - 两者均为 null 表示连接关闭或解码失败
///
/// 接收流程：
///   1. 读 4 字节头长度（大端序 uint32）
///   2. 读 N 字节 JSON 头并解析
///   3. 根据 header['length'] 分块读取消息体
Future<(Map<String, dynamic>?, Uint8List?)> recvMessage(
  MessageReader reader, {
  int chunkSize = 4 * 1024 * 1024,
}) async {
  // 1. 读取 4 字节消息头长度
  final rawHeaderLen = await reader.recvall(4);
  if (rawHeaderLen == null) return (null, null);

  final int headerLen =
      ByteData.view(rawHeaderLen.buffer).getUint32(0, Endian.big);

  // 2. 读取 JSON 消息头
  final headerJson = await reader.recvall(headerLen);
  if (headerJson == null) return (null, null);

  final Map<String, dynamic> header =
      jsonDecode(utf8.decode(headerJson)) as Map<String, dynamic>;

  // 3. 读取消息体（分块接收，与 Python 版本循环逻辑一致）
  final int length = (header['length'] as num).toInt();
  final BytesBuilder bodyBuffer = BytesBuilder(copy: false);
  int remaining = length;

  while (remaining > 0) {
    final int toRead = remaining < chunkSize ? remaining : chunkSize;
    final Uint8List? packet = await reader.recvall(toRead);
    if (packet == null) return (null, null);
    bodyBuffer.add(packet);
    remaining -= packet.length;
  }

  return (header, bodyBuffer.toBytes());
}

// ============================================================
// 便捷函数：发送接收一站完成（主要用于测试）
// ============================================================

/// 在 [sendSock] 上发送消息，并从 [recvReader] 接收。
/// 这是 sendMessage + recvMessage 的组合便捷调用。
///
/// 主要用于单元测试中验证编解码的往返正确性。
Future<(Map<String, dynamic>?, Uint8List?)> sendAndRecv(
  Socket sendSock,
  MessageReader recvReader,
  String msgType,
  dynamic content, {
  Map<String, dynamic>? extraHeaders,
  int chunkSize = 4 * 1024 * 1024,
}) async {
  await sendMessage(sendSock, msgType, content,
      extraHeaders: extraHeaders, chunkSize: chunkSize);
  return recvMessage(recvReader, chunkSize: chunkSize);
}
