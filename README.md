# 聊天室 —— 基于 TCP+SSL 的 C/S 即时通讯系统

> 版本 3.3.0 | 2026-06-24

---

## 项目简介

基于 TCP 协议的客户端-服务器(C/S)通信程序，支持 SSL 加密、好友管理、群组聊天、文件传输。

- **服务端**: 多线程 TCP Server + SSL 加密 + SQLite 持久化（Python 3.12）
- **客户端**: 
  - **Flutter (Dart) 桌面客户端** —— Linux 桌面端主体功能已完成（`chatroom_flutter/`）
  - tkinter 图形界面 —— 保留作为功能参照（`client/gui/`）
- **协议**: 自定义二进制协议（4字节头长度 + JSON 头 + 消息体，v1.0.0 已冻结）
- **认证**: bcrypt 密码哈希
- **测试**: pytest 全量自动化（151 个测试，4 层覆盖）

---

## 快速开始

```bash
# === 1. 启动服务端 ===
cd ~/PycharmProjects/chatroom
source .venv/bin/activate
python server/server_main.py

# === 2. 启动 Flutter 客户端（推荐，Linux 桌面） ===
cd chatroom_flutter
flutter pub get
flutter run -d linux

# === 2b. 或启动 tkinter 客户端（Python） ===
cd ~/PycharmProjects/chatroom
source .venv/bin/activate
python client/gui/gui_main.py

# === 3. 运行自动化测试 ===
./run_tests.sh
```

---

## 项目结构

```
chatroom/
├── server/                         # 服务端（Python）
│   ├── server_main.py              #   入口：监听 127.0.0.1:8090
│   ├── server_client_handler.py    #   客户端连接 & bcrypt 认证
│   ├── server_message_handler.py   #   消息路由：私聊/群聊/好友/文件/撤回
│   ├── server_admin_handler.py     #   管理员命令：列出用户/删除/发公告
│   └── server_group_handler.py     #   群组管理：创建/加入/广播/群文件
├── client/gui/                     # tkinter 客户端（保留，功能参照）
│   ├── gui_main.py                 #   主窗口，全局状态管理
│   ├── gui_login_ui.py             #   登录/注册界面
│   ├── gui_chat_ui.py              #   主聊天界面（好友列表/聊天窗口）
│   ├── gui_message_handler.py      #   消息收发处理
│   ├── gui_admin_ui.py             #   管理员面板
│   └── gui_group_ui.py             #   群组管理
├── chatroom_flutter/               # 🆕 Flutter 桌面客户端（Linux）
│   ├── lib/
│   │   ├── main.dart               #   入口
│   │   ├── config.dart             #   客户端配置
│   │   ├── models/chat_models.dart #   数据模型 + 输入验证
│   │   ├── services/
│   │   │   ├── socket_service.dart #   SSL 连接 + 协议通信
│   │   │   ├── state_manager.dart  #   全局状态 (ChangeNotifier)
│   │   │   ├── ime_bridge.dart     #   中文输入法桥接管理
│   │   │   └── x11_ime.dart        #   X11 输入法 FFI 接口
│   │   ├── screens/
│   │   │   ├── login_screen.dart   #   登录/注册界面
│   │   │   └── chat_screen.dart    #   主聊天界面
│   │   └── widgets/
│   │       ├── raw_text_field.dart #   绕过系统 IME 的文本框
│   │       ├── chat_view.dart      #   消息列表 + 输入栏
│   │       ├── sidebar.dart        #   好友/群组侧边栏
│   │       └── dialogs.dart        #   全部对话框 + 文件选择器
│   ├── bridge/                     #   IME 桥接（Python GTK 进程）
│   │   ├── persistent_ime.py       #   常驻 GTK 输入法窗口
│   │   └── x11_ime_wrapper.c       #   X11 IME C 包装
│   ├── pubspec.yaml
│   └── TESTING_GUIDE_FLUTTER.md    #   Flutter 客户端测试指南
├── dart_protocol/                  # Dart 协议层（共享库）
│   └── lib/protocol.dart
├── protocol.py                     # Python 协议层（v1.0.0，已冻结）
├── database.py                     # SQLite 数据库层（9 张表）
├── config.yaml                     # 全局配置文件
├── config.py                       # 配置加载模块
├── validation.py                   # 用户名/密码格式验证
├── SSL/                            # SSL 证书（自签名）
│   ├── gen_cert.py
│   └── tsetcn.crt / .key / .pem
├── tests/                          # 自动化测试（151 个）
│   ├── test_protocol.py            #   协议层 (15)
│   ├── test_database.py            #   数据层 (36)
│   ├── test_client_logic.py        #   客户端逻辑 (19)
│   ├── test_server.py              #   服务端集成 (16)
│   ├── test_e2e.py                 #   端到端场景 (4)
│   ├── test_message_history.py     #   消息历史持久化 (20)
│   ├── test_input_validation.py    #   输入验证 (34)
│   └── test_backend_integration.py #   后端加固集成验证 (7)
├── run_tests.sh
├── pyproject.toml
└── README.md
```

---

## 功能清单

### 已完成 ✅

| 分类 | 功能 | 说明 |
|------|------|------|
| 通信 | SSL 加密传输 | 自签名证书，TLS 1.2+ |
| 通信 | 自定义二进制协议 | 4字节帧头 + JSON 元数据 + 二进制体，支持分块 |
| 用户 | 注册/登录 | bcrypt 密码哈希 |
| 用户 | 管理员角色 | 查看用户列表、删除用户、发送系统公告 |
| 聊天 | 一对一私聊（仅限好友） | 在线实时投递 + 离线消息存储 |
| 聊天 | 消息回执 | sent → delivered 状态流转 |
| 聊天 | 消息撤回（2分钟内） | 私聊、群聊、文件请求均可撤回 |
| 聊天 | 离线消息 | 登录时自动推送，标记 history=true |
| 好友 | 好友系统 | 添加/接受/拒绝/列表/在线状态 |
| 群组 | 群组管理 | 创建/加入/成员列表 |
| 群组 | 群聊广播 | 消息实时广播到全部在线成员 |
| 群组 | 群文件共享 | 请求-响应模式，支持多成员确认 |
| 文件 | 文件传输 | 先请求后确认，支持私聊和群聊 |
| 文件 | 分块传输 | 默认 4MB 块大小，支持大文件 |
| 架构 | 模块解耦 | 服务端按功能拆分 4 个 handler |
| 测试 | 自动化测试 | pytest，89 个测试，4 层覆盖 |

### 计划中 📋

#### 🟡 Flutter 客户端优化（当前）

> Flutter Linux 桌面客户端重构已**初步完成**（33/35 项功能测试通过），存在以下待优化问题：

| 优化项 | 说明 |
|--------|------|
| 🔧 输入法切换卡顿/无效 | Linux 下 fcitx IME 与 Flutter GTK 嵌入器存在死锁风险，当前通过 Python GTK 桥接进程绕过，切换延迟约 200-300ms |
| 🎨 操作逻辑与显示打磨 | 消息气泡边距、长消息换行、列表滚动行为等可进一步优化 |
| ✨ 美观增进 | 聊天气泡圆角、渐入动画、自定义主题色等视觉增强 |
| 🔒 安全性增强 | 管理员注册与登录需增加额外验证（配置文件预设管理员密钥等） |

#### 阶段完成状态

| 阶段 | 内容 | 状态 |
|------|------|------|
| 阶段 1 | 后端加固 | ✅ 已完成 |
| 阶段 2 | Dart 协议层移植 + 单元测试 | ✅ 已完成 |
| 阶段 3 | Flutter Linux 桌面端（主体功能） | ✅ 已完成 |
| — | Flutter Windows / Android 适配 | 🔜 待进行 |
| 阶段 5 | 打包发布 | 🔜 待进行 |

#### 🟢 长期展望

| 功能 | 说明 |
|------|------|
| 数据库连接池 | 减少频繁开/关连接的开销 |
| 端到端加密 | 客户端预哈希密码 + 消息内容加密 |
| 安全审计日志 | 记录敏感操作 |
| 并发优化 | 细化服务器锁粒度 |
| Web 端移植 | Flutter Web 编译 |
| 音视频通话 | WebRTC 集成 |
| 表情包 & 图片预览 | Flutter 原生组件支持 |
| 消息搜索 | Elasticsearch 全文索引 |
| 多语言界面 | Flutter i18n |

### 重点规划

#### 聊天记录持久化

当前消息仅在**离线消息表**中暂存，接收后即删除。需要改造为：

- 新增 `message_history` 表，永久保存所有消息（chat / group_chat / file）
- 客户端登录后**分页拉取**历史（而不是一次性推送全部离线消息）
- 向上滚动聊天窗口时**自动请求更早的消息**
- 支持按关键字搜索本地历史

#### 三端统一客户端（Flutter）

- **当前**: tkinter 桌面客户端（Linux 验证通过），UI 美观性有限
- **问题**: tkinter 无法实现聊天气泡、平滑动画、深色模式等现代 UI 特性；Windows/Android 需独立客户端
- **决策**: 采用 **Flutter (Dart)** 统一三端（Windows / Linux / Android），同一代码库编译
- **优势**: Material Design 3 开箱即用，`dart:io` 的 Socket API 可直接对接现有自定义二进制协议
- **不变**: 服务端 (`server/`) 和数据库层 (`database.py`) 完全保留不动
- **策略**: 先补完后端欠账（阶段1 ✅ 已完成），再逐步迁移客户端（阶段2–5），保证开发期间系统始终可用

---

## 协议设计

```
┌──────────────────────────────────────────────────────┐
│  4 bytes (big-endian)  │  JSON Header (UTF-8)  │  Body  │
│   header length        │  {type, length, ...}  │  bytes │
└──────────────────────────────────────────────────────┘
```

### 消息类型

| type | 方向 | 用途 |
|------|------|------|
| `login` / `register` | C→S | 认证 |
| `chat` | 双向 | 私聊消息 |
| `file` / `file_request` / `file_response` | 双向 | 文件传输 |
| `group_chat` / `group_file_*` | 双向 | 群组消息和文件 |
| `friend_request` / `accept_friend` / `reject_friend` | 双向 | 好友系统 |
| `create_group` / `join_group` / `list_groups` | C→S | 群组管理 |
| `recall` / `receipt` | 双向 | 撤回和回执 |
| `admin_command` / `admin_response` | 双向 | 管理员操作 |
| `error` | S→C | 服务端错误 |

---

## 数据库设计（8 张表）

| 表 | 字段 | 用途 |
|----|------|------|
| `users` | username(UNIQUE), password_hash(bcrypt), is_admin | 用户认证 |
| `offline_messages` | message_id, sender, receiver, content(BLOB), status | 离线消息 |
| `friends` | user1+user2(PK), status(pending/accepted) | 好友关系 |
| `file_requests` | message_id, sender, receiver, content(BLOB) | 私聊文件请求 |
| `groups` | id, group_name(UNIQUE), created_by | 群组定义 |
| `group_members` | group_id+username(PK) | 群成员 |
| `group_file_requests` | message_id, group_id, sender, content(BLOB) | 群文件请求 |
| `group_file_responses` | message_id+group_id+username(PK), response | 群文件响应 |

---

## 测试体系

```bash
./run_tests.sh              # 运行全部 89 个测试 (~55s)
./run_tests.sh --quick      # 快速测试，跳过 E2E (~30s)
./run_tests.sh --db         # 仅数据库测试
./run_tests.sh --e2e        # 仅端到端测试
```

| 层 | 文件 | 数量 | 覆盖内容 |
|----|------|------|---------|
| L0 协议层 | `test_protocol.py` | 15 | 编解码、分块、粘包、类型转换 |
| L1 数据层 | `test_database.py` | 35 | 用户/好友/群组/文件/离线消息 CRUD |
| L2 客户端逻辑 | `test_client_logic.py` | 19 | 状态追踪、队列、解析、撤回映射 |
| L3 服务端集成 | `test_server.py` | 16 | 认证、私聊路由、好友/群组/管理命令 |
| L4 端到端 | `test_e2e.py` | 4 | 多客户端注册加好友私聊、群聊、撤回 |

---

## 技术栈

| 组件 | 技术 |
|------|------|
| 语言 | Python 3.12 |
| GUI | tkinter (ttk) —— 当前 / Flutter (Dart) —— 规划中 |
| 网络 | TCP socket, SSL/TLS |
| 数据库 | SQLite3（9 张表）|
| 密码哈希 | bcrypt |
| 配置 | config.yaml + PyYAML |
| 输入验证 | validation.py |
| 证书 | 自签名 (cryptography 库) |
| 测试 | pytest 9.x |
| 包管理 | pip + venv |

---

## 变更日志

### v3.3.0 (2026-06-24)

- **Flutter Linux 桌面客户端初步完成**: 33/35 项功能测试通过，覆盖注册/登录、好友系统、私聊、群聊、文件传输、消息撤回、管理员功能
- 新增 `chatroom_flutter/` 完整项目：含配置、数据模型、网络服务、状态管理、IME桥接、4 个界面和 4 个 widget
- 服务端适配 Flutter 客户端（群组文件前缀 `group_`、发送者离线消息回显等）
- 修复多项集成问题（输入框焦点、群组列表覆盖、消息撤回 UI 更新、系统公告投递等）
- 已知待优化：输入法切换卡顿、操作逻辑打磨、美观增进、管理员注册安全性增强

- **集成审计与修复**: 发现并修复 5 个集成缺陷（validation/save_message_history/cleanup 未被调用、密码未验证、E2E 密码过短），确保所有后端加固功能已集成到运行时路径
- 新增 `tests/test_backend_integration.py`（7 个集成验证测试），测试总数 144 → 151
- `validation.py` 已集成到客户端（`gui_login_ui.py`）和服务端（`server_client_handler.py`）注册流程
- `save_message_history()` 已集成到私聊/群聊/文件消息处理路径
- `cleanup_expired_file_requests()` 在服务端启动时自动调用

### v3.2.0 (2026-06-15)

- **阶段 1 后端加固全部完成**: ① `message_history` 表（4方法）; ② `config.yaml` 替代全部硬编码; ③ `validation.py` 输入验证; ④ 协议冻结 `PROTOCOL_VERSION 1.0.0`; ⑤ 离线文件过期清理
- 测试体系扩展至 144 个（新增 `test_message_history.py` 20 个 + `test_input_validation.py` 34 个）
- 数据库表数 8→9（新增 `message_history`）

### v3.1.0 (2026-06-14)

- **技术栈决策**: 经全面评估，确定 Flutter (Dart) 为统一三端（Windows/Linux/Android）客户端技术栈
- tkinter 现状评估与跨平台方案对比（详见 `软件开发文档3.0.0.md` 第 11 章）
- 明确 5 阶段迁移路线图：后端加固 → Dart 协议层 → Flutter 桌面 → Flutter 安卓 → 打包发布
- 更新计划优先级：阶段 1 后端加固为当前最高优先级

### v2.0.0 (2026-06-14)

- **测试体系**: 从零搭建 89 个 pytest 自动化测试，4 层覆盖
- **服务端 import 修复**: 统一使用 `server.xxx` 包导入，支持测试框架
- **datetime 修复**: `utcnow()` → `datetime.now(UTC)`，解决 Python 3.12 废弃警告
- **SSL 证书**: 旧证书过期，使用 cryptography 库重新生成（2036 年到期）
- **项目配置**: 新增 `pyproject.toml`、`run_tests.sh`
