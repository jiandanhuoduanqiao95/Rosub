# 聊天室 —— 基于 TCP+SSL 的 C/S 即时通讯系统

> 版本 6.0.0 | 2026-08-13

---

## 项目简介

基于 TCP 协议的客户端-服务器(C/S)即时通讯系统，支持 SSL 加密、好友管理、群组聊天、文件传输。

- **服务端**: 多线程 TCP Server + SSL 加密 + SQLite 持久化（Python 3.12）
- **客户端**:
  - **Flutter (Dart) 桌面客户端** —— Linux 桌面端已完成（`chatroom_flutter/`）
  - tkinter 图形界面 —— 保留作为功能参照（`client/gui/`）
- **协议**: 自定义二进制协议（4 字节头长度 + JSON 头 + 消息体，v1.0.0 已冻结）
- **认证**: bcrypt 密码哈希 + 管理员二次密钥
- **测试**: pytest 612 个（pytest-xdist 并行）+ Flutter widget 测试 773 个 + Dart 协议 42 个

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
./run_tests.sh --all
```

> **管理员密钥**: 不要把真实密钥写入任何被 git 跟踪的文件。仅通过 `export CHATROOM_ADMIN_SECRET` 环境变量传入。`config.yaml` 中 `security.admin_secret` 留空即可。

---

## 项目结构

```
chatroom/
├── server/                            # 服务端（Python）
│   ├── server_main.py                 #   入口：监听 127.0.0.1:8090
│   ├── server_client_handler.py       #   连接 & 认证（含管理员密钥校验）
│   ├── server_message_handler.py      #   消息路由：私聊/群聊/好友/文件/撤回/删除好友
│   ├── server_admin_handler.py        #   管理员命令：列出用户/删除/发公告
│   └── server_group_handler.py        #   群组管理：创建/加入/退出/广播/成员列表/群文件
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
├── database.py                        # SQLite 数据库层（12 张表）
├── config.py                          # 配置加载模块
├── config.yaml                        # 全局配置文件
├── validation.py                      # 用户名/密码格式验证
├── admin.py                           # 管理员账号创建脚本
├── SSL/                               # SSL 证书（自签名）
│   ├── gen_cert.py
│   └── tsetcn.crt / .key / .pem
├── tests/                             # 自动化测试（283 个 + conftest 共享设施）
│   ├── conftest.py                    #   共享测试基础设施（ServerHarness/客户端封装）
│   ├── test_protocol.py               #   协议层 (15)
│   ├── test_database.py               #   数据层 (33)
│   ├── test_database_ext.py           #   数据层扩展 (32)
│   ├── test_stage_f_db.py             #   阶段 F 数据库 (17)
│   ├── test_client_logic.py           #   客户端逻辑 (19)
│   ├── test_server.py                 #   服务端集成 (29)
│   ├── test_server_ext.py             #   服务端扩展 (31)
│   ├── test_stage_f_server.py         #   阶段 F 服务端 (16)
│   ├── test_e2e.py                    #   端到端 (4)
│   ├── test_async_e2e.py              #   异步端到端 (3)
│   ├── test_message_history.py        #   消息历史 (20)
│   ├── test_input_validation.py       #   输入验证 (19)
│   ├── test_hypothesis.py             #   属性+状态机 (9)
│   ├── test_socket_guard.py           #   socket 守护 (8)
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
| 好友 | 删除好友 | 长按好友 → 确认框 → 双向解除关系 + 双方通知 + 离线补发 |
| 群组 | 群组管理 | 创建/加入/退出/成员列表 |
| 群组 | 退出群组 | 长按群组 → 菜单 → 退出；成员通知；空群组自动删除（含历史） |
| 群组 | 群成员列表 | 打开群组菜单即预取，群信息对话框实时显示成员与创建者 |
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
| 身份 | 用户资料 | 昵称/头像/签名/最后在线时间；资料页查看与编辑（J1） |
| 身份 | 在线状态 | presence 广播 + 登录快照；好友侧边栏在线圆点；黑名单双向隐藏（J2） |
| 身份 | 管理员重置密码 | 无需旧密码直接重置；目标用户在线时被强制下线（J3） |
| 身份 | 好友备注/分组 | 备注名显示于侧边栏；分组分区渲染；登录自动同步（J4） |
| 身份 | 黑名单 | 拦截消息/文件/好友请求；跨登录保持；解除恢复（J4） |
| 身份 | 好友请求验证消息 + 用户搜索 | 搜索用户名发请求；可附验证消息；发送请求时可预填备注名（J4） |
| 测试 | 自动化测试 | pytest 612 个 + Flutter 773 个 + Dart 42 个 |

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

| 缺口 | 说明 | 状态 |
|------|------|------|
| 消息历史分页 | 仅能看最近 500 条，DB 有 API 但协议/UI 未接入 | ✅ 已完成 |
| 未读消息徽标 | 侧边栏会话无未读计数 | ✅ 已完成 |
| 删除好友 | 无协议、无 UI，好友关系不可撤销 | ✅ 已完成 |
| 退出群组 | 无协议、无 UI，加入后永久接收消息 | ✅ 已完成 |
| 群成员列表 | 服务端不向客户端发送成员列表 | ✅ 已完成 |
| 重复登录踢出 | 同账号登录不踢旧会话，旧客户端"冻结" | ✅ 已完成（阶段 G1：旧会话强制下线） |
| 修改密码 | 无协议、无 UI | ✅ 已完成（阶段 G2/G3：服务端校验 + UI） |
| 文件大小限制 | 无上限，大文件可 OOM | ✅ 已完成（阶段 G4：5GB 上限 + 大小文件分流） |
| 文件名安全过滤 | 未过滤路径穿越 | ✅ 已完成（阶段 G5） |
| 消息搜索 | DB 有 API 但协议/UI 未接入 | ✅ 已完成（私聊/群聊两类范围，系统会话只读无搜索入口） |
| 登录速率限制 | 无暴力破解防护 | ✅ 已完成 |
| Session 持久化 | 重启需重新输入凭据 | ✅ 已完成（记住我回填；管理员密钥不落盘） |

#### 开发路线图

```
阶段 D：断线重连              ← ✅ 已完成
阶段 E：历史分页 + 未读徽标    ← ✅ 已完成
阶段 F：社交管理              ← ✅ 已完成（删除好友/退出群组/群成员列表）
阶段 G：安全加固 + 文件改进    ← ✅ 已完成
阶段 H：提醒 + Session + 搜索 ← ✅ 已完成（任务栏闪烁/记住我/消息搜索）
    ↓
阶段 I：消息可靠性 + 数据地基  ← ✅ 已完成（发送队列/conversations 表/备份恢复）
    ↓
阶段 J：身份与社交            ← ✅ 已完成（资料/在线状态/密码重置/黑名单/备注分组/验证消息）
    ↓
阶段 K：会话体验              ← ✅ 已完成（置顶/草稿/静音/免打扰绝对时刻+置顶豁免/科技感提示音/引用/转发/反应/文件撤回新菜单）
    ↓
阶段 L：多端前置              ← ⏳ 规划中（多会话并存/钥匙串/本地缓存）
    ↓
阶段 M：群组治理 + 运维        ← ⏳ 规划中（群主权限/入群审批/状态面板/存储治理）
```

> **2026-08-11 需求挖掘**：完整功能需求挖掘报告（P0/P1/P2 全量清单、排除项与理由）见
> `软件开发文档4.1.0.md` 第 13 章；路线图详见第 11 章。已确认排除：已读/未读回执、正在输入、
> 群角色、群公告已读回执、关键词屏蔽/消息过滤。

### 长期展望

| 功能 | 说明 |
|------|------|
| Flutter Windows / Android 适配 | 同一代码库编译三端（前置依赖：阶段 L 多会话模型） |
| 多语言界面 | Flutter i18n |
| 并发优化 | 数据库连接池、细化锁粒度 |
| 端到端加密 | ⏸ 降级 P3：已有 TLS + bcrypt，≤10 人自部署规模不推荐（见开发文档 §13.7） |
| 安全审计日志 | ✅ 已列入 P2-7（阶段 M 后） |

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
| `friend_request` / `accept_friend` / `reject_friend` / `delete_friend` | 双向 | 好友系统 |
| `create_group` / `join_group` / `leave_group` / `list_groups` / `list_group_members` | C→S | 群组管理 |
| `recall` | 双向 | 撤回消息 |
| `admin_command` / `admin_response` / `admin_auth` | 双向 | 管理员操作 |
| `error` | S→C | 服务端错误 |

> 协议版本 v1.0.0 已冻结。所有 extra_headers 的 key 和 value 强制转为字符串。

---

## 数据库设计（11 张表）

> 阶段 J 已落地：`users` 表新增 nickname/avatar/signature/last_seen（P0-2）、
> `friends` 表新增 note/group_name/request_message（P1-8/P1-10）、第 10 张
> `conversations` 会话元数据表（P0-8，阶段 I 落地）、第 11 张 `blocked_users`
> 黑名单表（P1-9，阶段 J 落地）。

| 表 | 用途 |
|----|------|
| `users` | 用户认证与资料（username, bcrypt hash, is_admin, nickname/avatar/signature/last_seen） |
| `offline_messages` | 聊天消息持久化（sent/delivered/recalled） |
| `message_history` | 永久消息历史（分页查询 + 关键字搜索） |
| `friends` | 好友关系（pending/accepted；备注名/分组/请求验证消息） |
| `file_requests` | 私聊文件请求 |
| `groups` | 群组定义 |
| `group_members` | 群成员 |
| `group_file_requests` | 群文件请求 |
| `group_file_responses` | 群文件响应 |
| `conversations` | 会话元数据（pinned/muted/draft/cleared_at，阶段 I） |
| `blocked_users` | 黑名单（单向拉黑关系，阶段 J） |

---

## 测试体系

```bash
./run_tests.sh --all          # 全部 612 个测试（pytest-xdist 并行 ~60s）
./run_tests.sh --quick        # 快速测试（跳过 E2E/异步/状态机）
./run_tests.sh --db           # 仅数据库（含阶段 F 扩展）
./run_tests.sh --e2e          # 仅端到端（含异步 E2E）
./run_tests.sh --no-parallel  # 串行执行
```

> 注：下表为阶段 F 快照（283 个）；最新计数 612 个（Python）+ 42 个（Dart）+ 773 个（Flutter）= 1427 项，
> 逐文件明细见 `TESTING_GUIDE_FLUTTER.md` §3。

| 层 | 文件 | 数量 | 覆盖内容 |
|----|------|------|---------|
| L0 协议 | `test_protocol.py` | 15 | 编解码、分块、粘包 |
| L1 数据 | `test_database.py` + `test_database_ext.py` | 65 | CRUD、好友、群组、文件、阶段 E 游标分页 |
| L1 阶段 F | `test_stage_f_db.py` | 17 | 删除好友、退出群组、删除空群组 |
| L2 客户端逻辑 | `test_client_logic.py` | 19 | 状态追踪、队列、解析 |
| L3 服务端集成 | `test_server.py` + `test_server_ext.py` | 60 | 认证、私聊、好友、群组、管理员、离线补发、文件、撤回 |
| L3 阶段 F | `test_stage_f_server.py` | 16 | delete_friend / leave_group / list_group_members |
| L4 端到端 | `test_e2e.py` + `test_async_e2e.py` | 7 | 多客户端完整业务场景（线程 + asyncio） |
| 消息历史 | `test_message_history.py` | 20 | 持久化、分页、搜索 |
| 输入验证 | `test_input_validation.py` | 19 | 合法/非法输入、SQL 注入 |
| 属性/状态机 | `test_hypothesis.py` | 9 | Hypothesis 属性 + RuleBasedStateMachine |
| 守护测试 | `test_socket_guard.py` | 8 | pytest-socket 纯逻辑不触网 |
| 后端集成 | `test_backend_integration.py` | 7 | 运行时路径验证 |

Flutter 测试（773 个）：

```bash
cd chatroom_flutter
dart analyze lib test integration_test   # 静态分析（零 error）
flutter test                            # widget 测试
flutter test integration_test/chatroom_app_test.dart -d linux   # 集成绑定
```

---

## 技术栈

| 组件 | 技术 |
|------|------|
| 服务端 | Python 3.12 |
| 客户端 | Flutter (Dart) / tkinter (保留) |
| 网络 | TCP socket + SSL/TLS |
| 数据库 | SQLite3（11 张表，含阶段 I conversations + 阶段 J blocked_users） |
| 密码 | bcrypt |
| 配置 | config.yaml + PyYAML |
| 测试 | pytest 9.x / flutter_test / mocktail / integration_test |
| 管理员安全 | 环境变量密钥 (CHATROOM_ADMIN_SECRET) |

---

## 变更日志

### v7.0.0 (2026-08-15)

- **阶段 J：身份与社交完成**
  - J1 用户资料：`users` 表扩展 nickname/avatar/signature/last_seen；get_profile/set_profile 协议 + 资料页
  - J2 在线状态：presence 广播（登录/登出）+ 新登录者快照；黑名单双向隐藏；侧边栏在线圆点
  - J3 管理员重置密码：`admin_reset_password` 命令 + 管理面板入口；重置后目标用户强制下线（shutdown+close 唤醒阻塞线程并广播下线）
  - J4 好友备注/分组、黑名单（拦截 chat/文件/好友请求）、好友请求验证消息、用户搜索；发送请求时可预填备注名（接受后自动设置）
  - 密码格式校验客户端与服务端对齐（6-128 位、无控制字符，P-17）
  - 修复 dart:io SecureSocket 发送随机丢失缺陷的三层根因：好友元数据/黑名单改由服务端登录初始数据推送、传输通道按需建立、`_receiveInitialData` 同步消费推送（防旧推送覆盖新操作）、发送 5s 超时触发重连、关键操作先乐观更新后发送
  - 测试：Python 522（410 + 112 阶段 J）+ Dart 42 + Flutter 595（480 + 103 阶段 J + 2 真实服务端 E2E）= 1159 项全绿

### v6.0.0 (2026-08-13)

- **阶段 I：消息可靠性 + 数据地基完成**
  - 发送队列：断线可输入、消息入队暂存（"发送中…"气泡）、重连自动补发、失败气泡手动重试
  - `conversations` 会话元数据表（pinned/muted/draft/cleared_at，旧库自动迁移）
  - 一键备份/恢复（`backup/` 包：SQLite `.backup` 在线快照 + 目录打包）
  - 可靠性：重发幂等去重（服务端按 message_id）、瞬时异常不杀连接、群聊回显 id 无损还原
  - 测试：Python 410 + Dart 42 + Flutter 480 = 932 项全绿；手动测试见 `TESTING_GUIDE.md` §23

### v5.0.0 (2026-08-11)

- **功能需求挖掘（产品层规划）**: 完整报告落地 `软件开发文档4.1.0.md` 第 13 章；新增阶段 I-M 路线图（发送队列 / 用户资料 / 在线状态 / 本地缓存 / 备份恢复 / 密码重置 / 多会话并存 / conversations 表 → 群组治理与运维）
- **已确认排除**: 已读/未读回执、正在输入、群角色、群公告已读回执、关键词屏蔽/消息过滤
- **设计决策恢复**: 在线状态（P0-3）确认纳入路线图；端到端加密降级 P3，审计日志列入 P2-7
- **文档**: README / 开发文档 / AGENTS.md / 测试指南同步更新；测试计数对齐 344 + 42 + 408

### v4.2.0 (2026-08-07)

- **阶段 F：社交管理功能完成**
  - 删除好友：长按好友 → 确认框 → 双向解除关系 + 双方通知（在线推送/离线补发）
  - 退出群组：长按群组 → 菜单 → 退出 + 群成员通知；最后一人离开自动删除空群组（含历史与离线消息）
  - 群成员列表：打开群组菜单即预取成员，群信息对话框实时显示成员与创建者
- **测试体系重构**: 引入 pytest-asyncio / pytest-socket / hypothesis / pytest-xdist / mocktail / integration_test；Python 测试 151 → 283，Flutter 测试 1 → 106
- **修复**: 管理员列表 is_admin 序列化、Unicode 控制字符校验、IME 桥接 python 解释器探测、群成员 0 人、空群组残留
- **文档**: 更新 README、软件开发文档、AGENTS.md、测试指南

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
