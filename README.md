# 聊天室 —— 基于 TCP+SSL 的 C/S 即时通讯系统

> 版本 4.3.0 | 2026-07-16

---

## 项目简介

基于 TCP 协议的客户端-服务器(C/S)即时通讯系统，支持 SSL 加密、好友管理、群组聊天、文件传输。

- **服务端**: 多线程 TCP Server + SSL 加密 + SQLite 持久化（Python 3.12）
- **客户端**:
  - **Flutter (Dart) 桌面客户端** —— Linux 桌面端已完成（`chatroom_flutter/`）
  - tkinter 图形界面 —— 保留作为功能参照（`client/gui/`）
- **协议**: 自定义二进制协议（4 字节头长度 + JSON 头 + 消息体，v1.0.0 已冻结）
- **认证**: bcrypt 密码哈希 + 管理员二次密钥
- **测试**: pytest 164 个 + Flutter widget 测试

---

## 快速开始

```bash
# === 1. 启动服务端 ===
cd ~/PycharmProjects/chatroom
source .venv/bin/activate
export CHATROOM_ADMIN_SECRET='<你的管理员密钥>'   # 管理员注册/登录需要
python server/server_main.py

# === 2. 启动 Flutter 客户端（推荐） ===
cd chatroom_flutter
flutter pub get
flutter run -d linux

# === 2b. 或启动 tkinter 客户端 ===
cd ~/PycharmProjects/chatroom
source .venv/bin/activate
python client/gui/gui_main.py

# === 3. 运行自动化测试 ===
./run_tests.sh
```

> **管理员密钥**: 不要把真实密钥写入任何被 git 跟踪的文件。仅通过 `export CHATROOM_ADMIN_SECRET` 环境变量传入。`config.yaml` 中 `security.admin_secret` 留空即可。

---

## 项目结构

```
chatroom/
├── server/                            # 服务端（Python）
│   ├── server_main.py                 #   入口：监听 127.0.0.1:8090
│   ├── server_client_handler.py       #   连接 & 认证（含管理员密钥校验）
│   ├── server_message_handler.py      #   消息路由：私聊/群聊/好友/文件/撤回
│   ├── server_admin_handler.py        #   管理员命令：列出用户/删除/发公告
│   └── server_group_handler.py        #   群组管理：创建/加入/广播/群文件
├── client/gui/                        # tkinter 客户端（保留）
│   ├── gui_main.py                    #   主窗口
│   ├── gui_login_ui.py                #   登录/注册（含管理员密钥输入框）
│   ├── gui_chat_ui.py                 #   聊天主界面
│   ├── gui_message_handler.py         #   消息收发处理
│   ├── gui_admin_ui.py                #   管理员面板
│   └── gui_group_ui.py                #   群组管理
├── chatroom_flutter/                  # Flutter 桌面客户端（Linux）
│   ├── lib/
│   │   ├── main.dart                  #   入口 + 主题
│   │   ├── config.dart                #   客户端配置
│   │   ├── models/chat_models.dart    #   数据模型 + 输入验证
│   │   ├── services/
│   │   │   ├── socket_service.dart    #   SSL 连接 + 协议通信 + 消息监听
│   │   │   ├── state_manager.dart     #   全局状态 (ChangeNotifier)
│   │   │   ├── ime_bridge.dart        #   中文输入法桥接管理
│   │   │   └── x11_ime.dart           #   X11 输入法 FFI 接口（未使用）
│   │   ├── screens/
│   │   │   ├── login_screen.dart      #   登录/注册 + 管理员模式
│   │   │   └── chat_screen.dart       #   主聊天界面
│   │   └── widgets/
│   │       ├── raw_text_field.dart    #   绕过系统 IME 的文本框
│   │       ├── chat_view.dart         #   消息气泡 + 输入栏
│   │       ├── sidebar.dart           #   会话侧边栏
│   │       └── dialogs.dart           #   对话框 + 文件选择器
│   ├── bridge/                        #   IME 桥接（Python GTK 进程）
│   │   └── persistent_ime.py          #   常驻 GTK 输入法窗口
│   ├── test/widget_test.dart          #   Flutter widget 测试
│   └── pubspec.yaml
├── dart_protocol/                     # Dart 协议层（共享库）
│   ├── lib/protocol.dart              #   编解码 + MessageReader
│   └── test/protocol_test.dart        #   15 个单元测试
├── protocol.py                        # Python 协议层（v1.0.0，已冻结）
├── database.py                        # SQLite 数据库层（9 张表）
├── config.py                          # 配置加载模块
├── config.yaml                        # 全局配置文件
├── validation.py                      # 用户名/密码格式验证
├── admin.py                           # 管理员账号创建脚本
├── SSL/                               # SSL 证书（自签名）
│   ├── gen_cert.py
│   └── tsetcn.crt / .key / .pem
├── tests/                             # 自动化测试（157 个）
│   ├── test_protocol.py               #   协议层 (15)
│   ├── test_database.py               #   数据层 (37)
│   ├── test_client_logic.py           #   客户端逻辑 (19)
│   ├── test_server.py                 #   服务端集成 (22)
│   ├── test_e2e.py                    #   端到端 (4)
│   ├── test_message_history.py        #   消息历史 (20)
│   ├── test_input_validation.py       #   输入验证 (33)
│   └── test_backend_integration.py    #   后端集成 (7)
├── run_tests.sh
├── pyproject.toml
├── AGENTS.md                          # 开发操作规范
├── TESTING_GUIDE.md                   # 全功能测试指南
├── 软件开发文档4.1.0.md                # 软件开发文档
└── README.md
```

---

## 功能清单

### 已完成

| 分类 | 功能 | 说明 |
|------|------|------|
| 通信 | SSL 加密传输 | 自签名证书，TLS 1.2+ |
| 通信 | 自定义二进制协议 | 4 字节帧头 + JSON 元数据 + 二进制体，支持分块 |
| 用户 | 注册/登录 | bcrypt 密码哈希 + 服务端输入验证 |
| 用户 | 管理员角色 | 二次密钥保护注册/登录；查看用户/删除/发公告 |
| 聊天 | 一对一私聊（仅限好友） | 在线实时投递 + 离线消息存储 |
| 聊天 | 消息撤回（2 分钟内） | 私聊、群聊、文件请求均可撤回 |
| 聊天 | 聊天记录持久化 | 登录时按时间戳顺序加载历史（含已送达消息），无"历史"标签 |
| 好友 | 好友系统 | 添加/接受/拒绝/列表；拒绝后可重新请求；离线请求登录时推送 |
| 群组 | 群组管理 | 创建/加入/成员列表 |
| 群组 | 群聊广播 | 消息实时广播到全部在线成员 |
| 群组 | 群文件共享 | 请求-响应模式，支持多成员确认 |
| 文件 | 文件传输 | 先请求后确认，支持私聊和群聊 |
| 文件 | 分块传输 | 默认 4MB 块大小 |
| 文件 | 过期清理 | 启动时自动清理 7 天前的文件请求 |
| 离线 | 好友请求补发 | 离线期间收到的好友请求，登录时自动推送 |
| 离线 | 好友接受通知 | 离线期间好友请求被接受，登录后收到通知 |
| 离线 | 公告持久化 | 离线期间管理员发的公告，登录后在系统消息中可见 |
| 离线 | 撤回占位符 | 离线期间被撤回的消息，登录后看到"撤回了一条消息"提示 |
| UI | Flutter Linux 桌面端 | Material 3 主题、深色模式、聊天气泡、侧边栏分组 |
| UI | 中文输入法桥接 | Python GTK 透明窗口桥接 fcitx，避免 Flutter 死锁 |
| UI | 光标同步 | 方向键移动光标时 Flutter 视觉光标与 GTK 输入框同步 |
| 测试 | 自动化测试 | pytest 157 个 + Flutter widget 测试 |

### 下一步开发

> 完整的缺口分析和开发路线图详见 `软件开发文档4.1.0.md` 第 10-11 章。

#### 离线功能全链路优化

| 改进项 | 说明 | 状态 |
|--------|------|------|
| 好友请求离线补发 | 登录时推送待处理好友请求 | ✅ 已完成 |
| 好友接受离线通知 | 离线期间请求被接受，登录后收到通知 | ✅ 已完成 |
| 公告持久化 | 离线用户的公告存储，登录后在系统消息中可见 | ✅ 已完成 |
| 撤回离线占位符 | 离线期间被撤回的消息，登录后显示占位符 | ✅ 已完成 |
| 消息历史分页拉取 | 上滑加载更旧消息，`before_message_id` 游标分页 | ✅ 已完成 |
| 已读/未读状态区分 | `status` 字段驱动未读计数徽标 | ✅ 已完成 |

#### 日常使用缺口（2026-07-15 审计）

**致命级**（不修则无法日常使用）：

| 缺口 | 说明 |
|------|------|
| 断线重连 | 网络断开直接踢回登录页，需自动重连+消息同步 |
| 桌面通知 | 窗口在后台时收消息无任何提示 |

**重要级**（日常使用明显不便）：

| 缺口 | 说明 |
|------|------|
| 消息历史分页 | 仅能看最近 500 条，DB 有 API 但协议/UI 未接入 |
| 未读消息徽标 | 侧边栏会话无未读计数 |
| 删除好友 | 无协议、无 UI，好友关系不可撤销 |
| 退出群组 | 无协议、无 UI，加入后永久接收消息 |
| 群成员列表 | 服务端不向客户端发送成员列表 |
| 重复登录踢出 | 同账号登录不踢旧会话，旧客户端"冻结" |
| 修改密码 | 无协议、无 UI |
| 文件大小限制 | 无上限，大文件可 OOM |
| 文件名安全过滤 | 未过滤路径穿越 |
| 消息搜索 | DB 有 API 但协议/UI 未接入 |
| 登录速率限制 | 无暴力破解防护 |
| Session 持久化 | 重启需重新输入凭据 |

#### 开发路线图

```
阶段 D：断线重连              ← ✅ 已完成
阶段 E：历史分页 + 未读徽标    ← ✅ 已完成
阶段 F：社交管理              ← 删除好友/退出群组/群成员列表
阶段 G：安全加固              ← 重复登录/密码修改/文件限制/速率限制
阶段 H：桌面通知 + Session    ← 通知/自动登录/消息搜索
```

### 长期展望

| 功能 | 说明 |
|------|------|
| Flutter Windows / Android 适配 | 同一代码库编译三端 |
| 端到端加密 | 客户端预哈希密码 + 消息内容加密 |
| 安全审计日志 | 记录敏感操作 |
| 并发优化 | 数据库连接池、细化锁粒度 |
| 多语言界面 | Flutter i18n |

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
| `login` / `register` | C→S | 认证（密码 + 可选 admin_secret） |
| `chat` | 双向 | 私聊消息 |
| `file` / `file_request` / `file_response` | 双向 | 文件传输 |
| `group_chat` / `group_file_*` | 双向 | 群组消息和文件 |
| `friend_request` / `accept_friend` / `reject_friend` | 双向 | 好友系统 |
| `create_group` / `join_group` / `list_groups` | C→S | 群组管理 |
| `recall` | 双向 | 撤回消息 |
| `admin_command` / `admin_response` / `admin_auth` | 双向 | 管理员操作 |
| `error` | S→C | 服务端错误 |

> 协议版本 v1.0.0 已冻结。所有 extra_headers 的 key 和 value 强制转为字符串。

---

## 数据库设计（9 张表）

| 表 | 用途 |
|----|------|
| `users` | 用户认证（username, bcrypt hash, is_admin） |
| `offline_messages` | 聊天消息持久化（sent/delivered/recalled） |
| `message_history` | 永久消息历史（分页查询 + 关键字搜索） |
| `friends` | 好友关系（pending/accepted） |
| `file_requests` | 私聊文件请求 |
| `groups` | 群组定义 |
| `group_members` | 群成员 |
| `group_file_requests` | 群文件请求 |
| `group_file_responses` | 群文件响应 |

---

## 测试体系

```bash
./run_tests.sh              # 全部 164 个测试 (~90s)
./run_tests.sh --quick      # 跳过 E2E (~40s)
./run_tests.sh --db         # 仅数据库
./run_tests.sh --e2e        # 仅端到端
```

| 层 | 文件 | 数量 | 覆盖内容 |
|----|------|------|---------|
| L0 协议 | `test_protocol.py` | 15 | 编解码、分块、粘包 |
| L1 数据 | `test_database.py` | 37 | CRUD、好友、群组、文件、持久化 |
| L2 客户端逻辑 | `test_client_logic.py` | 19 | 状态追踪、队列、解析 |
| L3 服务端集成 | `test_server.py` | 22 | 认证、私聊、好友、群组、管理员、离线补发 |
| L4 端到端 | `test_e2e.py` | 4 | 多客户端完整业务场景 |
| 消息历史 | `test_message_history.py` | 20 | 持久化、分页、搜索 |
| 输入验证 | `test_input_validation.py` | 33 | 合法/非法输入、SQL 注入 |
| 后端集成 | `test_backend_integration.py` | 7 | 运行时路径验证 |

Flutter 测试：

```bash
cd chatroom_flutter
dart analyze lib test    # 静态分析
flutter test             # widget 测试
```

---

## 技术栈

| 组件 | 技术 |
|------|------|
| 服务端 | Python 3.12 |
| 客户端 | Flutter (Dart) / tkinter (保留) |
| 网络 | TCP socket + SSL/TLS |
| 数据库 | SQLite3（9 张表） |
| 密码 | bcrypt |
| 配置 | config.yaml + PyYAML |
| 测试 | pytest 9.x / flutter_test |
| 管理员安全 | 环境变量密钥 (CHATROOM_ADMIN_SECRET) |

---

## 变更日志

### v4.1.0 (2026-07-12)

- **离线功能全链路优化（阶段 A：离线补发）**:
  - 好友请求离线补发：登录时自动推送待处理好友请求
  - 好友接受离线通知：离线期间好友请求被接受，登录后收到通知消息
  - 公告持久化：离线用户的公告存储到 `offline_messages`，登录后在系统消息中可见
  - 撤回离线占位符：离线期间被撤回的消息，登录后显示"撤回了一条消息"提示（微信风格）
  - Flutter 客户端 `_receiveInitialData` 新增 `friend_request` 处理
- **测试**: 新增 4 个离线功能集成测试，共 164 个
- **文档**: 更新 README、软件开发文档、TESTING_GUIDE.md

### v4.0.0 (2026-07-05)

- **Flutter Linux 客户端优化完成**:
  - 输入法桥接重构：稳定焦点管理、光标位置同步、发送后清空
  - 管理员安全增强：注册/登录二次密钥（环境变量 `CHATROOM_ADMIN_SECRET`）
  - 界面美化：Material 3 主题、渐变登录页、聊天气泡圆角、深色模式
  - 操作逻辑打磨：系统消息会话仅显示公告、SnackBar 通知、撤回确认框
  - 消息持久化：按时间戳排序、去除"历史"标签、含已送达消息
  - 删除多余服务端确认消息（群聊发送/撤回/加入群组/文件接受）
  - 修复好友拒绝后无法重新请求
  - 修复文件撤回误报失败
  - 修复 ListTile ColoredBox 异常
- **服务端改进**:
  - `get_offline_messages` 改为单查询按时间戳排序，含 delivered 状态（持久化）
  - `update_message_status` 修复 SQLite rowcount 误报
  - `reject_friend_request` 删除所有状态行，`add_friend_request` 仅阻止 pending/accepted
  - 管理员不能删除自己
  - 登录/注册均做输入验证
- **测试**: 新增 2 个管理员密钥测试，更新数据库/服务端测试，共 153 个
- **文档**: 全面重构所有项目文档

### v3.3.0 (2026-06-24)

- Flutter Linux 桌面客户端初步完成（33/35 项功能测试通过）
- 服务端适配 Flutter 客户端
- 集成审计与修复（5 个缺陷）

### v3.2.0 (2026-06-15)

- 后端加固：message_history 表、config.yaml、validation.py、协议冻结、文件过期清理
- 测试扩展至 151 个

### v3.1.0 (2026-06-14)

- 技术栈决策：Flutter (Dart) 统一三端

### v2.0.0 (2026-06-14)

- 测试体系搭建、import 修复、datetime 修复、SSL 证书更新
