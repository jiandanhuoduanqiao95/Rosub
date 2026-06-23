# Dart 协议层移植 —— 测试指南 v1.0.0

> 阶段 2：Dart 协议层移植 | 2026-06-19
>
> 本文档是 `TESTING_GUIDE.md` 的姊妹篇，专注于阶段二 Dart 协议层的实操测试。

---

## 测试结果记录

**测试日期**: ___ | **测试人**: ___ | **结果**: ___

| 阶段 | 测试项数 | 结果 |
|------|---------|------|
| 自动化测试（dart test） | 15 | ☐ |
| 环境准备 | 3 | ☐ |
| 手动验证编解码兼容性 | 5 | ☐ |
| **合计** | **23** | **☐** |

---

## 目录

1. [前置准备](#1-前置准备)
2. [阶段一：环境安装与项目初始化](#2-阶段一环境安装与项目初始化)
3. [阶段二：运行自动化单元测试](#3-阶段二运行自动化单元测试)
4. [阶段三：逐组理解测试内容](#4-阶段三逐组理解测试内容)
5. [阶段四：编解码兼容性手动验证](#5-阶段四编解码兼容性手动验证)
6. [阶段五：与 Python 协议的一致性交叉验证](#6-阶段五与-python-协议的一致性交叉验证)
7. [完整测试清单](#7-完整测试清单)
8. [故障排查](#8-故障排查)

---

## 1. 前置准备

### 1.1 项目背景

**阶段二的目标**：用 Dart 语言实现 `protocol.py` 的完整编解码逻辑，并编写与其对等的 15 个单元测试。完成后，Dart 协议层可作为后续 Flutter 客户端的通信基石。

**关键约束**：
- Dart 实现必须与 Python 协议 100% 二进制兼容（同一份字节流，Python 编码 → Dart 解码要无误，反之亦然）
- 所有 15 个测试用例与 `tests/test_protocol.py` 逐一对齐
- 协议版本号 `1.0.0` 已冻结，不可修改

### 1.2 文件结构

```
dart_protocol/                    ← 新建目录（阶段二产物）
├── pubspec.yaml                  # Dart 包配置
├── lib/
│   └── protocol.dart             # 协议编解码实现（对应 protocol.py）
├── test/
│   └── protocol_test.dart        # 15 个单元测试（对应 test_protocol.py）
└── TESTING_GUIDE_DART_PROTOCOL.md  # 本文档
```

**与 Python 版本的对应关系**：

| Python 文件 | Dart 文件 | 说明 |
|------------|----------|------|
| `protocol.py` | `lib/protocol.dart` | 编解码核心 |
| `tests/test_protocol.py` | `test/protocol_test.dart` | 单元测试（15个） |
| 无（socket.socketpair） | `makeSocketPair()` in test | 测试辅助 |

### 1.3 核心 API 对比

| 功能 | Python | Dart |
|------|--------|------|
| 发送消息 | `send_message(sock, msg_type, content, extra_headers, chunk_size)` | `sendMessage(sock, msgType, content, {extraHeaders, chunkSize})` |
| 接收消息 | `recv_message(sock, chunk_size)` → `(header, body)` | `recvMessage(reader, {chunkSize})` → `(header, body)` |
| 收齐 N 字节 | `recvall(sock, n)` → `bytes` | `reader.recvall(n)` → `Uint8List?` |
| 协议版本 | `PROTOCOL_VERSION = "1.0.0"` | `protocolVersion = '1.0.0'` |

> **关键差异**：Python 的 `recv_message` 直接传入 socket；Dart 引入了 `MessageReader` 封装类来管理异步缓冲读取，这是 Dart 异步 I/O 模型所需的适配。

---

## 2. 阶段一：环境安装与项目初始化

### 2.1 安装 Dart SDK

Dart 协议层需要 Dart SDK 3.0+（支持 records 语法）。

**选项 A：通过 Flutter SDK 安装（推荐，后续阶段 3 也需要）**

```bash
# 下载 Flutter SDK
cd ~
git clone https://github.com/flutter/flutter.git -b stable
export PATH="$PATH:$HOME/flutter/bin"

# 验证
flutter doctor
dart --version    # 应输出 Dart 3.x
```

**选项 B：仅安装 Dart SDK（如果暂时不需要 Flutter）**

```bash
# Ubuntu/Debian
sudo apt-get update
sudo apt-get install apt-transport-https
wget -qO- https://dl-ssl.google.com/linux/linux_signing_key.pub | sudo gpg --dearmor -o /usr/share/keyrings/dart.gpg
echo 'deb [signed-by=/usr/share/keyrings/dart.gpg arch=amd64] https://storage.googleapis.com/download.dartlang.org/linux/debian stable main' | sudo tee /etc/apt/sources.list.d/dart_stable.list
sudo apt-get update
sudo apt-get install dart

# 验证
dart --version
```

### 2.2 获取项目依赖

```bash
cd ~/PycharmProjects/chatroom/dart_protocol
dart pub get
```

**预期输出**：

```
Resolving dependencies...
Got dependencies!
```

### 2.3 验证环境就绪

```bash
# 验证 Dart 版本
dart --version                    # 应 ≥ 3.0.0

# 验证包解析
dart pub get                      # 应输出 "Got dependencies!"

# 验证代码无语法错误
dart analyze lib/protocol.dart     # 应无错误输出
```

---

## 3. 阶段二：运行自动化单元测试

### 3.1 运行全部测试

```bash
cd ~/PycharmProjects/chatroom/dart_protocol
dart test
```

**预期输出**：

```
00:00 +0: TestSendMessage test_send_text_message
00:00 +1: TestSendMessage test_send_text_message
00:00 +1: TestSendMessage test_send_binary_message
00:00 +2: TestSendMessage test_send_binary_message
...
00:00 +14: TestDefensive test_message_length_accuracy
00:00 +15: All tests passed!
```

### 3.2 带详细输出运行

```bash
dart test -r expanded
```

### 3.3 运行特定测试组

```bash
# 仅发送测试（5 个）
dart test --name TestSendMessage

# 仅接收测试（3 个）
dart test --name TestRecvMessage

# 仅往返测试（5 个）
dart test --name TestRoundTrip

# 仅防御性测试（2 个）
dart test --name TestDefensive
```

### 3.4 运行单个测试

```bash
# 运行某个具体测试
dart test --name "test_send_text_message"

# 运行多个匹配的测试
dart test --name "roundtrip"
```

---

## 4. 阶段三：逐组理解测试内容

以下逐组说明每个测试的验证目标和关键观测点。

### 4.1 第 1 组：sendMessage 发送测试（5 个）

这组测试验证 `sendMessage()` 函数的编码正确性——从发送端发出后，接收端能正确解码。

| # | 测试名 | 测什么 | 关键断言 |
|---|--------|--------|---------|
| 1 | `test_send_text_message` | 普通文本消息编解码 | `type=="chat"`, 文本内容一致, `length` 等于 UTF-8 字节数 |
| 2 | `test_send_binary_message` | 二进制数据（含 `\x00`-`\xff` 全部 256 个字节） | body 逐字节相等, 长度 256 |
| 3 | `test_send_with_extra_headers` | 附加头字段 + 防御性类型转换 | 整数 `42`→字符串 `"42"` |
| 4 | `test_send_empty_message` | 空字符串边界 | `length==0`, body 为空 |
| 5 | `test_send_large_message_chunked` | 分块传输（100 字节, chunk=10） | 内容完整, 长度 100 |

### 4.2 第 2 组：recvMessage / recvall 接收测试（3 个）

这组测试验证 `MessageReader.recvall()` 的底层接收逻辑——TCP 分包场景下的数据组装。

| # | 测试名 | 测什么 | 关键断言 |
|---|--------|--------|---------|
| 6 | `test_recv_large_message_chunked_receive` | recvMessage 内部分块接收循环 | 500 字节完整接收 |
| 7 | `test_recvall_exact_bytes` | recvall 一次性收齐 | 数据相等 |
| 8 | `test_recvall_partial_data` | recvall 循环组装（260 字节） | 长度 260, 内容完整 |

### 4.3 第 3 组：往返测试 Round-trip（5 个）

这是最重要的测试组——验证"发出去什么，对方就收到什么"。

| # | 测试名 | 测什么 | 关键断言 |
|---|--------|--------|---------|
| 9 | `test_roundtrip_text_chinese` | 中文 UTF-8 编解码 | `"你好世界！这是一个中文测试消息"` 无损 |
| 10 | `test_roundtrip_text_with_emoji` | emoji（4字节 UTF-8） | `"Hello 😀🎉🔥 测试"` 无损 |
| 11 | `test_roundtrip_binary_with_null_bytes` | `\x00` 字节不被截断 | body 逐字节相等 |
| 12 | `test_roundtrip_multiple_messages` | 连续 3 条消息不粘包 | 每条独立解码正确 |
| 13 | `test_roundtrip_mixed_types` | 文本+二进制混合传输 | type 区分正确, PNG 幻数 `\x89PNG` 验证 |

### 4.4 第 4 组：防御性/健壮性测试（2 个）

| # | 测试名 | 测什么 | 关键断言 |
|---|--------|--------|---------|
| 14 | `test_extra_headers_type_conversion` | 整数/浮点/布尔/null 转字符串 | `100→"100"`, `3.14→"3.14"`, `true→"true"`, `null→"null"` |
| 15 | `test_message_length_accuracy` | length 字段与实际体长一致 | `header['length'] == body.length` |

---

## 5. 阶段四：编解码兼容性手动验证

以下测试验证 Dart 实现的协议编解码细节是否正确。

### 5.1 验证协议版本号

```bash
cd ~/PycharmProjects/chatroom/dart_protocol
dart _tmp.dart
```

**预期输出**: `1.0.0`

**对照**：Python 版本

```bash
cd ~/PycharmProjects/chatroom
source .venv/bin/activate
python -c "from protocol import PROTOCOL_VERSION; print(PROTOCOL_VERSION)"
```

两个输出必须一致：`1.0.0`。

### 5.2 验证帧格式——4 字节头长度（大端序）

在 Dart 中手动验证头长度编码：

```bash
cd ~/PycharmProjects/chatroom/dart_protocol
cat > /tmp/proto_test.dart << 'EOF'
import 'dart:typed_data';
import 'dart:convert';

void main() {
  final header = {'type': 'chat', 'length': 13};
  final json = utf8.encode(jsonEncode(header));
  print('JSON header bytes: $json');
  print('JSON header length: ${json.length}');

  final buf = ByteData(4);
  buf.setUint32(0, json.length, Endian.big);
  print('4-byte big-endian: ${buf.buffer.asUint8List()}');
}
EOF
dart /tmp/proto_test.dart

**预期输出**（示例）：
```
JSON header bytes: [123, 34, 116, 121, 112, 101, 34, 58, 32, 34, 99, 104, 97, 116, 34, 44, 32, 34, 108, 101, 110, 103, 116, 104, 34, 58, 32, 49, 51, 125]
JSON header length: 30
4-byte big-endian: [0, 0, 0, 30]
```

**对照** Python：

```bash
python -c "
import json, struct
header = {'type': 'chat', 'length': 13}
header_json = json.dumps(header).encode('utf-8')
print('JSON header bytes:', list(header_json))
print('JSON header length:', len(header_json))
hlen = struct.pack('!I', len(header_json))
print('4-byte big-endian:', list(hlen))
"
```

### 5.3 验证 extra_headers 字符串化

在 Dart 中确认防御性转换：

```bash
cd ~/PycharmProjects/chatroom/dart_protocol
cat > /tmp/test.dart << 'EOF'
import 'dart:convert';

void main() {
  final extra = <String, dynamic>{
    'count': 100,
    'ratio': 3.14,
    'flag': true,
  };
  final header = <String, dynamic>{'type': 'test', 'length': 0};
  for (final e in extra.entries) {
    header[e.key.toString()] = e.value.toString();
  }
  print(jsonEncode(header));
}
EOF
dart /tmp/test.dart
```

**预期输出**中，所有 extra_headers 的值必须是字符串（带引号）：
```json
{"type":"test","length":0,"count":"100","ratio":"3.14","flag":"true"}
```

注意 `"100"` 是字符串而非数字 `100`。

### 5.4 验证中文 UTF-8 编码

```bash
cd ~/PycharmProjects/chatroom/dart_protocol
dart run -e "
import 'dart:convert';

void main() {
  const text = '你好世界';
  final bytes = utf8.encode(text);
  print('UTF-8 bytes: \$bytes');
  print('Decoded: \${utf8.decode(bytes)}');
  print('Length: \${bytes.length} bytes');
}
"
```

**预期**：`你好世界` → 12 字节（每个中文字符 3 字节 UTF-8）

**对照** Python：

```bash
python -c "
text = '你好世界'
b = text.encode('utf-8')
print('UTF-8 bytes:', list(b))
print('Length:', len(b), 'bytes')
"
```

两者输出应完全一致。

### 5.5 验证二进制 \x00 字节处理

```bash
cd ~/PycharmProjects/chatroom/dart_protocol
cat > /tmp/uint8_test.dart << 'EOF'
import 'dart:typed_data';

void main() {
  final data = Uint8List.fromList([0, 0, 65, 66, 0, 67]);
  print('Data: $data');
  print('Length: ${data.length}');
  final slice = data.sublist(2, 4);
  print('Bytes at [2:4]: $slice'); // 应输出 [65, 66] = 'AB'
}
EOF
dart /tmp/uint8_test.dart
```

---

## 6. 阶段五：与 Python 协议的一致性交叉验证

这是最关键的验证——确保 Dart 和 Python 能互相解码对方编码的消息。

### 6.1 部署交叉验证脚本

虽然当前 Dart 只能在同一进程内测试（`makeSocketPair` 使用本地回环），但我们可以通过 **逐字节对比** 的方式来验证一致性：

**原理**：对于相同的输入（msgType, content, extraHeaders），Python 和 Dart 产生的字节流应该逐字节相等。

### 6.2 Python 侧：导出参考字节流

```bash
cd ~/PycharmProjects/chatroom
source .venv/bin/activate

python3 << 'PYEOF'
import socket, struct, json

# 模拟 send_message 的核心逻辑，输出字节流
content = "Hello, World!"
msg_type = "chat"
extra_headers = {"to": "alice", "group_id": 42}

# 构造消息
content_bytes = content.encode('utf-8')
extra_headers = {str(k): str(v) for k, v in extra_headers.items()}
header = {'type': msg_type, 'length': len(content_bytes)}
header.update(extra_headers)
header_json = json.dumps(header).encode('utf-8')

# 逐字节输出
print("=== 4-byte header length ===")
print(list(struct.pack('!I', len(header_json))))
print("=== JSON header ===")
print(list(header_json))
print("=== Body ===")
print(list(content_bytes))
print("=== Full frame (hex) ===")
full = struct.pack('!I', len(header_json)) + header_json + content_bytes
print(' '.join(f'{b:02x}' for b in full))
PYEOF
```

### 6.3 Dart 侧：导出参考字节流

```bash
cd ~/PycharmProjects/chatroom/dart_protocol

cat > /tmp/frame_test.dart << 'EOF'
import 'dart:convert';
import 'dart:typed_data';

void main() {
  const content = 'Hello, World!';
  const msgType = 'chat';
  final extraHeaders = {'to': 'alice', 'group_id': 42};

  final contentBytes = Uint8List.fromList(utf8.encode(content));

  final header = <String, dynamic>{
    'type': msgType,
    'length': contentBytes.length,
  };
  for (final e in extraHeaders.entries) {
    header[e.key.toString()] = e.value.toString();
  }

  final headerJson = utf8.encode(jsonEncode(header));

  final headerLenBuf = ByteData(4);
  headerLenBuf.setUint32(0, headerJson.length, Endian.big);
  final headerLen = headerLenBuf.buffer.asUint8List();

  print('=== 4-byte header length ===');
  print(headerLen.toList());
  print('=== JSON header ===');
  print(headerJson.toList());
  print('=== Body ===');
  print(contentBytes.toList());
  print('=== Full frame (hex) ===');
  final full = <int>[...headerLen, ...headerJson, ...contentBytes];
  print(full.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' '));
}
EOF
dart /tmp/frame_test.dart
```

### 6.4 逐字节对比

将 6.2 和 6.3 的输出（特别是最后一行的 hex 全帧）逐字对比。对于相同的输入，两者必须 **完全一致**。

**验证清单**：

| 输入场景 | Python hex | Dart hex | 一致？ |
|---------|-----------|----------|--------|
| 文本 `"Hello, World!"`, `to=alice` | `___` | `___` | ☐ |
| 文本 `"你好"`, 无额外头 | `___` | `___` | ☐ |
| 二进制 `\x00\x01\x02`, filename=`test.bin` | `___` | `___` | ☐ |
| 空消息 `""`, chat 类型 | `___` | `___` | ☐ |
| emoji `"😀🎉"`, group_id=1 | `___` | `___` | ☐ |

---

## 7. 完整测试清单

### 7.1 自动化测试

| # | 测试名 | ☐ |
|---|--------|----|
| 1 | `test_send_text_message` | ☐ |
| 2 | `test_send_binary_message` | ☐ |
| 3 | `test_send_with_extra_headers` | ☐ |
| 4 | `test_send_empty_message` | ☐ |
| 5 | `test_send_large_message_chunked` | ☐ |
| 6 | `test_recv_large_message_chunked_receive` | ☐ |
| 7 | `test_recvall_exact_bytes` | ☐ |
| 8 | `test_recvall_partial_data` | ☐ |
| 9 | `test_roundtrip_text_chinese` | ☐ |
| 10 | `test_roundtrip_text_with_emoji` | ☐ |
| 11 | `test_roundtrip_binary_with_null_bytes` | ☐ |
| 12 | `test_roundtrip_multiple_messages` | ☐ |
| 13 | `test_roundtrip_mixed_types` | ☐ |
| 14 | `test_extra_headers_type_conversion` | ☐ |
| 15 | `test_message_length_accuracy` | ☐ |
| **小计** | **自动化测试 15 passed** | **☐** |

### 7.2 环境验证

| # | 验证项 | 命令 | ☐ |
|---|--------|------|----|
| 16 | Dart SDK ≥ 3.0 | `dart --version` | ☐ |
| 17 | 依赖安装成功 | `dart pub get` | ☐ |
| 18 | 代码无语法错误 | `dart analyze lib/` | ☐ |

### 7.3 手动验证

| # | 验证项 | ☐ |
|---|--------|----|
| 19 | 协议版本号 = `1.0.0` | ☐ |
| 20 | 4 字节大端序头长度编码正确 | ☐ |
| 21 | extra_headers 全部字符串化 | ☐ |
| 22 | 中文 UTF-8 编解码正确 | ☐ |
| 23 | 二进制 `\x00` 字节处理正确 | ☐ |

### 7.4 交叉验证

| # | 验证项 | ☐ |
|---|--------|----|
| 24 | 纯文本 + extra_headers：Python vs Dart 字节一致 | ☐ |
| 25 | 中文文本：Python vs Dart 字节一致 | ☐ |
| 26 | 二进制数据：Python vs Dart 字节一致 | ☐ |
| 27 | 空消息：Python vs Dart 字节一致 | ☐ |
| 28 | Emoji：Python vs Dart 字节一致 | ☐ |

---

## 8. 故障排查

### 8.1 `dart: command not found`

**原因**：Dart SDK 未安装或 PATH 未配置。

**解决**：
```bash
# 如果用 Flutter 安装
export PATH="$PATH:$HOME/flutter/bin"

# 如果用 apt 安装
which dart      # 确认安装路径
```

### 8.2 `Error: Couldn't resolve the package 'dart_protocol'`

**原因**：pubspec.yaml 中的 name 与实际包名不匹配。

**解决**：确认在 `dart_protocol/` 目录下运行 `dart test`。

### 8.3 测试超时或挂起

**原因**：`MessageReader` 等待数据但 socket 没有发送任何数据。

**解决**：
```bash
# 提高测试超时时间
dart test --timeout 30s
```

### 8.4 `SocketException: Connection refused`

**原因**：`makeSocketPair()` 中的临时 server socket 未正确绑定。

**解决**：确认测试使用 `InternetAddress.loopbackIPv4` (127.0.0.1)，不依赖外部网络。

### 8.5 Dart 与 Python 字节流不一致

逐一检查以下差异点：

| 检查项 | Python | Dart | 应一致 |
|--------|--------|------|--------|
| UTF-8 编码 | `str.encode('utf-8')` | `utf8.encode(str)` | ✅ 相同标准 |
| JSON 序列化 | `json.dumps(dict)` | `jsonEncode(map)` | ⚠️ key 顺序可能不同* |
| 大端序 | `struct.pack('!I', n)` | `ByteData..setUint32(0, n, Endian.big)` | ✅ 相同 |
| 数字类型 | Python int → JSON number | Dart int → JSON number | ✅ 相同 |
| 布尔类型 | Python True → JSON true | Dart true → JSON true | ✅ 相同 |

> *JSON 对象中 key 的顺序不影响语义正确性，但会影响逐字节对比。验证时只需确认 JSON 解析后的语义一致，而非逐字节一致。

---

## 附录 A：快速命令速查

```bash
# === 环境 ===
cd ~/PycharmProjects/chatroom/dart_protocol
dart --version                                                           # 检查版本
dart pub get                                                             # 安装依赖

# === 测试 ===
dart test                                                                # 运行全部 15 个测试
dart test -v                                                             # 详细输出
dart test --name TestSendMessage                                         # 运行第 1 组
dart test --name "test_send_text_message"                                # 运行单个测试
dart test --timeout 30s                                                  # 自定义超时

# === 静态分析 ===
dart analyze lib/                                                        # 检查协议代码
dart analyze test/                                                       # 检查测试代码
dart analyze                                                             # 检查全部代码

# === 与 Python 对照 ===
source .venv/bin/activate && python -m pytest tests/test_protocol.py -v  # Python 基线
python -c "from protocol import PROTOCOL_VERSION; print(PROTOCOL_VERSION)" # Python 版本号
```

## 附录 B：Python 测试基线（参考）

在验证 Dart 协议层之前，先确认 Python 协议层测试全部通过：

```bash
cd ~/PycharmProjects/chatroom
source .venv/bin/activate
python -m pytest tests/test_protocol.py -v
```

**预期**：15 passed，0 failed。

这 15 个 Python 测试与 Dart 的 15 个测试完全对应，是 Dart 实现的"参考答案"。

---

> **阶段二完成后**，`dart_protocol/` 目录将成为阶段三（Flutter 客户端）的直接依赖。届时 Flutter 项目通过 `path: ../dart_protocol` 引用本包即可。
