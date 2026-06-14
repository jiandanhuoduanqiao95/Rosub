# 聊天室 —— 基于 TCP+SSL 的 C/S 即时通讯系统

> 版本 3.1.0 | 2026-06-14

---

## 项目简介

基于 TCP 协议的客户端-服务器(C/S)通信程序，使用 Python 实现。

- **服务端**: 多线程 TCP Server + SSL 加密 + SQLite 持久化
- **客户端**: tkinter 图形界面（当前）/ Flutter (Dart) 跨平台客户端（规划中，Windows+Linux+Android 三端统一）
- **协议**: 自定义二进制协议（4字节头长度 + JSON 头 + 消息体）
- **认证**: bcrypt 密码哈希
- **测试**: pytest 全量自动化（89 个测试，4 层覆盖）

---

## 快速开始

```bash
# 1. 激活虚拟环境
source .venv/bin/activate

# 2. 生成 SSL 证书（如过期需重新生成）
python SSL/gen_cert.py

# 3. 启动服务端
python server/server_main.py

# 4. 启动客户端（新终端）
python client/gui/gui_main.py

# 5. 运行自动化测试
./run_tests.sh
```

---

## 项目结构

```
chatroom/
├── server/                         # 服务端
│   ├── server_main.py              #   入口：监听 127.0.0.1:8090
│   ├── server_client_handler.py    #   客户端连接 & bcrypt 认证
│   ├── server_message_handler.py   #   消息路由：私聊/群聊/好友/文件/撤回
│   ├── server_admin_handler.py     #   管理员命令：列出用户/删除/发公告
│   └── server_group_handler.py     #   群组管理：创建/加入/广播/群文件
├── client/gui/                     # 客户端 (tkinter)
│   ├── gui_main.py                 #   主窗口，全局状态管理
│   ├── gui_login_ui.py             #   登录/注册界面
│   ├── gui_chat_ui.py              #   主聊天界面（好友列表/聊天窗口）
│   ├── gui_message_handler.py      #   消息收发处理
│   ├── gui_admin_ui.py             #   管理员面板
│   └── gui_group_ui.py             #   群组管理
├── protocol.py                     # 自定义二进制通信协议
├── database.py                     # SQLite 数据库层（8 张表）
├── SSL/                            # SSL 证书（自签名）
│   ├── gen_cert.py                 #   证书生成脚本
│   ├── tsetcn.crt / .key / .pem    #   证书文件
├── tests/                          # 自动化测试（89 个）
│   ├── test_protocol.py            #   协议层 (15)
│   ├── test_database.py            #   数据层 (35)
│   ├── test_client_logic.py        #   客户端逻辑 (19)
│   ├── test_server.py              #   服务端集成 (16)
│   └── test_e2e.py                 #   端到端场景 (4)
├── run_tests.sh                    # 一键测试脚本
├── pyproject.toml                  # pytest 配置
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

> **战略决策（2026-06-14）**: 经全面评估，决定采用 **Flutter (Dart)** 统一 Windows / Linux / Android 三端客户端，替代当前 tkinter。详见 `软件开发文档3.0.0.md` 第 11 章。

#### 🔴 阶段 1：后端加固（当前）

| 功能 | 说明 |
|------|------|
| **聊天记录持久化** | 服务端保存全量历史消息，客户端分页拉取，支持搜索 |
| 配置文件替代硬编码 (config.yaml) | 地址、端口、证书路径、分块大小、撤回时限等 |
| 离线消息过期清理机制 | 定期清理已投递消息（如 7 天） |
| 用户名格式验证 | 长度、字符集校验，防 SQL 注入 |
| 协议冻结 | 明确最终协议版本，作为多端共用的契约 |

#### 🟡 阶段 2–5：Flutter 客户端迁移

| 阶段 | 内容 | 周期 |
|------|------|------|
| 阶段 2 | **Dart 协议层移植** —— 用 Dart 实现 protocol.py 编解码 + 单元测试 | 1–2天 |
| 阶段 3 | **Flutter 桌面端** —— 登录/注册、好友+私聊、群聊、文件传输、管理员面板 | 2–4周 |
| 阶段 4 | **Flutter 安卓端** —— 移动端布局适配、通知推送、触控优化 | 1–2周 |
| 阶段 5 | **打包发布** —— Windows `.exe`、Linux AppImage/snap、Android `.apk` | 1周 |

#### 🟢 阶段 6+：长期展望

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
- **策略**: 先补完后端欠账（阶段1），再逐步迁移客户端（阶段2–5），保证开发期间系统始终可用

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
| 数据库 | SQLite3 |
| 密码哈希 | bcrypt |
| 证书 | 自签名 (cryptography 库) |
| 测试 | pytest 9.x |
| 包管理 | pip + venv |

---

## 变更日志

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
