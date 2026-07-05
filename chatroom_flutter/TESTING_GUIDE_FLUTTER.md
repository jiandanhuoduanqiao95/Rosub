# 聊天室项目 —— Flutter 桌面客户端测试指南 v2.0.0

> 阶段 3：Flutter 桌面端 | 最后更新：2026-07-05
>
> 本文档是 `TESTING_GUIDE.md` 和 `TESTING_GUIDE_DART_PROTOCOL.md` 的姊妹篇，
> 专注于 Flutter 桌面客户端的启动、功能测试和验证。
> v2.0.0 更新：管理员模式、IME 光标同步、消息持久化、SnackBar 通知、撤回确认框。

---

## 测试结果记录

**测试日期**: ___ | **测试人**: ___ | **结果**: ___

| 阶段 | 测试项数 | 结果 |
|------|---------|------|
| 前置准备 (Flutter 环境 + 编译) | 3 | ☐ |
| 服务端启动 | 1 | ☐ |
| 用户注册与登录 | 6 | ☐ |
| 好友系统 | 6 | ☐ |
| 私聊消息 | 4 | ☐ |
| 群组系统 | 4 | ☐ |
| 文件传输 | 3 | ☐ |
| 消息撤回 | 2 | ☐ |
| 管理员功能 | 4 | ☐ |
| 断线重连与异常处理 | 2 | ☐ |
| **合计** | **35** | **☐** |

> **说明**：消息历史持久化、配置文件验证、文件过期清理 3 项已在阶段一验证通过
> （服务端功能，无需在客户端重复测试），故本指南共计 35 项。

---

## 目录

1. [前置准备](#1-前置准备)
2. [阶段一：编译与启动 Flutter 客户端](#2-阶段一编译与启动-flutter-客户端)
3. [阶段二：服务端启动](#3-阶段二服务端启动)
4. [阶段三：用户注册与登录](#4-阶段三用户注册与登录)
5. [阶段四：好友系统](#5-阶段四好友系统)
6. [阶段五：私聊消息](#6-阶段五私聊消息)
7. [阶段六：群组系统](#7-阶段六群组系统)
8. [阶段七：文件传输](#8-阶段七文件传输)
9. [阶段八：消息撤回](#9-阶段八消息撤回)
10. [阶段九：管理员功能](#10-阶段九管理员功能)
11. [阶段十：断线重连与异常处理](#11-阶段十断线重连与异常处理)
12. [完整测试清单](#12-完整测试清单)
13. [Flutter 与 tkinter 行为差异说明](#13-flutter-与-tkinter-行为差异说明)

---

## 1. 前置准备

### 1.1 项目文件结构

```
chatroom/
├── server/                         # Python 服务端（不变）
├── protocol.py                     # Python 协议（不变）
├── database.py                     # Python 数据层（不变）
├── SSL/                            # SSL 证书（不变）
├── dart_protocol/                  # 阶段二产物：Dart 协议层
│   └── lib/protocol.dart
├── chatroom_flutter/               # 🆕 阶段三产物：Flutter 客户端
│   ├── pubspec.yaml
│   ├── lib/
│   │   ├── main.dart               #   入口
│   │   ├── config.dart             #   配置
│   │   ├── models/
│   │   │   └── chat_models.dart    #   数据模型 + 输入验证
│   │   ├── services/
│   │   │   ├── socket_service.dart #   SSL 连接 + 协议通信 + 消息处理
│   │   │   └── state_manager.dart  #   全局状态 (ChangeNotifier)
│   │   ├── screens/
│   │   │   ├── login_screen.dart   #   登录/注册界面
│   │   │   └── chat_screen.dart    #   主聊天界面
│   │   └── widgets/
│   │       ├── sidebar.dart        #   好友/群组列表
│   │       ├── chat_view.dart      #   消息列表 + 输入栏
│   │       └── dialogs.dart        #   全部对话框
│   └── TESTING_GUIDE_FLUTTER.md    #   本文档
└── TESTING_GUIDE.md                # Python tkinter 测试指南
```

### 1.2 环境确认

```bash
# 1. 确认 Flutter 环境
flutter doctor
# 应看到: [✓] Linux toolchain - develop for Linux desktop

# 2. 确认 Dart SDK
dart --version
# 应 ≥ 3.0.0

# 3. 确认 Python 服务端环境
cd ~/PycharmProjects/chatroom
source .venv/bin/activate
python --version   # 应 3.12.x

# 4. 确认 SSL 证书存在
ls SSL/tsetcn.crt SSL/tsetcn.key SSL/tsetcn.pem
# 如缺失，运行: python SSL/gen_cert.py
```

### 1.3 获取 Flutter 项目依赖

```bash
cd ~/PycharmProjects/chatroom/chatroom_flutter
flutter pub get
```

**预期输出**：

```
Resolving dependencies...
  dart_protocol 1.0.0 from path ../dart_protocol
  file_picker 8.x.x
  ...
Got dependencies!
```

### 1.4 创建 Linux 桌面平台支持

如果你的 Flutter 项目还没有 Linux 平台文件，需要生成：

```bash
cd ~/PycharmProjects/chatroom/chatroom_flutter
flutter create --platforms=linux .
```

这会在 `chatroom_flutter/linux/` 下生成 CMake 构建文件。如果已有则跳过。

> **注意**：`flutter create --platforms=linux .` 会覆盖 `pubspec.yaml` 等文件。
> 执行后请重新 `flutter pub get`。

### 1.5 Dart 静态分析

```bash
cd ~/PycharmProjects/chatroom/chatroom_flutter
dart analyze lib/
```

**预期**：`No issues found!`（0 errors, 0 warnings）。

---

## 2. 阶段一：编译与启动 Flutter 客户端

### 2.1 编译 Linux 桌面版-flutter run -d linux

```bash
cd ~/PycharmProjects/chatroom/chatroom_flutter
flutter build linux --debug
```

**预期**：编译成功，输出 `build/linux/x64/release/bundle/chatroom_flutter`。

### 2.2 运行

```bash
cd ~/PycharmProjects/chatroom/chatroom_flutter
./build/linux/x64/debug/bundle/chatroom_flutter
```

Flutter 启动后弹出桌面窗口，标题栏显示"聊天室"，主界面为登录卡片。

### 2.3 验证界面初始状态

| 步骤 | 操作 | 预期 |
|------|------|------|
| 1 | 窗口弹出 | 标题"聊天室"，居中卡片包含：聊天图标、"聊天室"标题、"登录"副标题 |
| 2 | 查看卡片 | 包含用户名输入框、密码输入框（密文）、"登录"按钮、"没有账号？注册"链接 |
| 3 | 点击"没有账号？注册" | 副标题变为"注册新账号"，按钮变为"注册" |
| 4 | 再点击"已有账号？登录" | 切回登录模式 |

---

## 3. 阶段二：服务端启动

打开**独立终端**（非 Flutter 终端）：

```bash
cd ~/PycharmProjects/chatroom
source .venv/bin/activate
python server/server_main.py
```

**预期输出**：

```
数据库路径: 项目根目录/users.db
[INFO] 服务器启动，监听 127.0.0.1:8090
```

---

## 4. 阶段三：用户注册与登录

### 4.1 注册 alice（客户端 1）

| 步骤 | 操作 | 预期 |
|------|------|------|
| 1 | 在 Flutter 窗口，切换到"注册"模式 | — |
| 2 | 用户名输入 `alice`，密码输入 `alice123`（≥6字符） | — |
| 3 | 点击 **注册** | （如数据库无残留数据）界面切换到聊天主界面，左侧侧边栏为空，右侧显示"选择一个会话开始聊天" |
| 4 | 查看标题栏 | 显示"聊天室 - alice" |

> 如果提示"用户已存在"，说明之前测试遗留了 `alice` 账号。
> 清除方法：`sqlite3 ~/PycharmProjects/chatroom/users.db "DELETE FROM users WHERE username='alice';"`

### 4.2 测试：客户端预验证——短用户名

| 步骤 | 操作 | 预期 |
|------|------|------|
| 1 | 点击右上角 **退出** 按钮，回到登录界面 | — |
| 2 | 选择**注册**，用户名输入 `a`（<3字符） | — |
| 3 | 点击 **注册** | 卡片中出现红色错误提示"用户名长度不能少于 3 个字符" |

### 4.3 测试：客户端预验证——SQL 注入尝试

| 步骤 | 操作 | 预期 |
|------|------|------|
| 1 | 用户名输入 `alice'; DROP TABLE users; --` | — |
| 2 | 点击确定 | 红色错误提示"用户名只能包含字母、数字、下划线和连字符" |

### 4.4 测试：短密码被拒绝

| 步骤 | 操作 | 预期 |
|------|------|------|
| 1 | 用户名输入 `testuser`，密码输入 `12345`（5字符） | — |
| 2 | 点击确定 | 红色错误提示"密码长度不能少于 6 个字符" |

### 4.5 测试：重复注册被拒绝

| 步骤 | 操作 | 预期 |
|------|------|------|
| 1 | 重新启动一个 Flutter 窗口（新终端 `flutter run -d linux`） | — |
| 2 | 选择**注册**，用户名输入 `alice`，密码 ≥6字符 | — |
| 3 | 点击注册 | 红色错误提示"用户已存在" |

### 4.6 测试：错误密码登录被拒

| 步骤 | 操作 | 预期 |
|------|------|------|
| 1 | 切换到**登录**，输入 `alice`，密码输入 `wrongpass` | — |
| 2 | 点击登录 | 红色错误提示"错误：密码错误" |

---

## 5. 阶段四：好友系统

> **前提**：alice 已登录在窗口1中。

### 5.1 启动第二个 Flutter 客户端（bob）

打开**新终端**：

```bash
cd ~/PycharmProjects/chatroom/chatroom_flutter
flutter run -d linux
```

在弹出的第二个窗口中，注册 `bob` / `bob123`（≥6字符），然后登录。

**此时**：两个 Flutter 窗口并列，双方的会话列表均为空。

### 5.2 Alice 添加 Bob 为好友

| 步骤 | 操作 | 预期 |
|------|------|------|
| 1 | **Alice** 窗口：点击侧边栏 **👤+**（添加好友） | 弹出对话框 |
| 2 | 输入 `bob`，点击 **添加** | 对话框关闭 |
| 3 | **Bob** 窗口：标题栏右侧出现红色徽标数字 | — |
| 4 | **Bob**：点击 **👥**（好友请求）图标 | 弹出对话框，显示"bob 请求添加您为好友"，有 ✓ 和 ✗ 按钮 |
| 5 | **Bob**：点击 ✓ **接受** | 双方侧边栏出现对方名称 |

**验证**：

- Alice 侧边栏显示 `bob`（在"好友 (1)"分组下）
- Bob 侧边栏显示 `alice`（在"好友 (1)"分组下）

### 5.3 测试：拒绝好友请求

| 步骤 | 操作 | 预期 |
|------|------|------|
| 1 | **Alice**：点击添加好友，输入 `ghost`（不存在的用户） | 对话框关闭，无报错 |
| 2 | 服务端日志应显示"好友请求发送失败" | — |

> ⚠️ 当前服务端对"向不存在用户发好友请求"是静默失败——消息被保存但目标永远收不到。这是已知行为。

---

## 6. 阶段五：私聊消息

### 6.1 在线私聊

| 步骤 | 操作 | 预期 |
|------|------|------|
| 1 | **Alice**：点击侧边栏中的 `bob` | 右侧聊天区标题变为"与 bob 的聊天" |
| 2 | 底部输入框输入 `Hello Bob!`，点击 **发送** 或按 Enter | Alice 聊天区出现自己的消息气泡（右对齐，浅蓝色） |
| 3 | **Bob**：点击侧边栏中的 `alice` | Bob 聊天区出现 `alice: Hello Bob!` 消息气泡（左对齐，浅灰色） |

### 6.2 双向聊天

| 步骤 | 操作 | 预期 |
|------|------|------|
| 1 | **Bob** 输入 `Hi Alice!`，发送 | Bob 看到自己的消息（右对齐），Alice 同时收到消息（左对齐） |
| 2 | 查看消息时间戳 | 每条消息左下角显示 HH:MM 格式时间 |

### 6.3 向非好友发消息被阻止

此功能由服务端强制执行——客户端向非好友发消息时，服务端会返回 error。

Flutter 客户端目前允许向侧边栏中任意选中的人发送，但**服务端会拦截非好友私聊**。

| 步骤 | 操作 | 预期 |
|------|------|------|
| 1 | 注册第三个用户 `charlie`（新窗口），不添加好友 | — |
| 2 | Alice 无法在侧边栏看到 charlie（因为不是好友） | 不能直接发送 |

### 6.4 离线消息

| 步骤 | 操作 | 预期 |
|------|------|------|
| 1 | **关闭 Bob 的 Flutter 窗口**（直接关窗口或 Ctrl+C 停止） | — |
| 2 | **Alice** 给 bob 发送 `Are you there?` | Alice 看到自己的消息气泡（右对齐） |
| 3 | **重新启动 Bob 的 Flutter 窗口**，登录 `bob` / `bob123` | — |
| 4 | Bob 点击侧边栏 `alice` | 聊天区出现 `alice: Are you there?`，标记为 **[历史]** 标签 |

---

## 7. 阶段六：群组系统

### 7.1 创建群组

| 步骤 | 操作 | 预期 |
|------|------|------|
| 1 | **Alice**：点击侧边栏 **👥+**（创建群组）按钮 | 弹出"创建群组"对话框 |
| 2 | 输入 `开发小组`，点击 **创建** | 对话框关闭，侧边栏"群组 (1)"下出现"开发小组 (ID:1)" |

### 7.2 加入群组

| 步骤 | 操作 | 预期 |
|------|------|------|
| 1 | **Bob**：点击侧边栏 **→**（加入群组）按钮 | 弹出"加入群组"对话框 |
| 2 | 输入 `1`，点击 **加入** | Bob 侧边栏出现"开发小组 (ID:1)" |

### 7.3 群聊消息广播

| 步骤 | 操作 | 预期 |
|------|------|------|
| 1 | **Alice**：点击侧边栏中的 `开发小组 (ID:1)` | 聊天区标题变为"群组 1 的聊天" |
| 2 | 输入 `大家好！`，点击发送 | Alice 看到自己的消息 |
| 3 | **Bob**：点击 `开发小组 (ID:1)` | 看到 `alice: 大家好！` |

### 7.4 群聊消息撤回

| 步骤 | 操作 | 预期 |
|------|------|------|
| 1 | Alice 在群组中发送 `test recall` | — |
| 2 | **立刻**点击该消息气泡 | 消息变为灰色斜体"alice: [消息已撤回]"，Bob 端同步变化 |

---

## 8. 阶段七：文件传输

### 8.1 私聊文件（接受）

| 步骤 | 操作 | 预期 |
|------|------|------|
| 1 | 准备测试文件：`echo "test content from flutter" > /tmp/flutter_test.txt` | — |
| 2 | **Alice**：选择好友 bob，点击输入栏旁的 **📎**（附件）按钮 | 弹出系统原生文件选择对话框 |
| 3 | 在文件选择器中导航到 `/tmp/flutter_test.txt`，点击 **打开** | Alice 聊天区出现"[发送文件] flutter_test.txt"气泡 |
| 4 | **Bob**：标题栏右侧出现文件夹图标 + 红色徽标 | — |
| 5 | **Bob**：点击 📁 图标 | 弹出文件请求对话框，显示文件名、大小、发送者 |
| 6 | **Bob**：点击 ✓ 接受 | 文件传输成功，Bob 聊天区出现"[收到文件] flutter_test.txt" |

**验证文件保存**：

```bash
ls ~/PycharmProjects/chatroom/chatroom_flutter/received_files/
cat ~/PycharmProjects/chatroom/chatroom_flutter/received_files/flutter_test.txt
# 应输出: test content from flutter
```

### 8.2 私聊文件（拒绝）

| 步骤 | 操作 | 预期 |
|------|------|------|
| 1 | Alice 再向 Bob 发送一个文件 | Bob 收到文件请求 |
| 2 | Bob 点击 ✗ 拒绝 | 对话框关闭，文件请求消失 |

### 8.3 群组文件

| 步骤 | 操作 | 预期 |
|------|------|------|
| 1 | Alice 选择 `开发小组 (ID:1)`，点击 📎 发送文件 | — |
| 2 | Bob 收到群文件请求（📁 徽标），点击接受 | 文件传输成功 |

---

## 9. 阶段八：消息撤回

### 9.1 撤回自己的消息

| 步骤 | 操作 | 预期 |
|------|------|------|
| 1 | Alice 给 Bob 发送一条消息 `secret123` | — |
| 2 | **立刻**在 Alice 窗口点击这条消息的气泡 | 服务端窗口无弹窗（撤回由客户端直接发送 recall 消息） |
| 3 | 观察双方窗口 | Alice 和 Bob 的消息均变为灰色斜体"alice: [消息已撤回]" |

> ⚠️ **与 tkinter 区别**：tkinter 客户端点击消息会弹出"是否撤回"确认框。
> Flutter 版本当前直接撤回（无确认弹窗）。后续可添加确认逻辑。

### 9.2 撤回他人消息被阻止

| 步骤 | 操作 | 预期 |
|------|------|------|
| 1 | Bob 点击 Alice 发的一条消息气泡 | 无反应（只有自己的消息可点击撤回） |
| 2 | 服务端日志 | 如尝试撤回他人消息，服务端返回 error |

---

## 10. 阶段九：管理员功能

### 10.1 创建管理员账号

```bash
cd ~/PycharmProjects/chatroom
source .venv/bin/activate
export CHATROOM_ADMIN_SECRET='<你的管理员密钥>'
python admin.py
# 按提示输入管理员用户名和密码
```

> **安全须知**：管理员密钥仅通过环境变量传入，不写入任何被 git 跟踪的文件。服务端启动时也必须设置同一环境变量。

### 10.2 管理员登录

| 步骤 | 操作 | 预期 |
|------|------|------|
| 1 | 启动服务端时设置 `CHATROOM_ADMIN_SECRET` 环境变量 | 服务端正常启动 |
| 2 | 启动 Flutter 客户端，切换「管理员模式」开关 | 出现管理员密钥输入框 |
| 3 | 输入管理员用户名、密码、管理员密钥，点击登录 | 进入聊天主界面 |
| 4 | 标题栏出现管理面板按钮 | 普通用户无此按钮 |

### 10.3 查看所有用户

| 步骤 | 操作 | 预期 |
|------|------|------|
| 1 | 点击 **🛡️** → **查看所有用户** | 对话框关闭，聊天区或状态栏显示用户列表（服务器返回 admin_response） |

> 与 tkinter 不同：tkinter 弹出独立表格窗口显示用户列表。Flutter 版本通过服务器返回的 JSON 数据显示。

### 10.4 发送系统公告

| 步骤 | 操作 | 预期 |
|------|------|------|
| 1 | **🛡️** → **发送系统公告** | 弹出输入对话框 |
| 2 | 输入 `系统将于今晚 23:00 维护`，点击发送 | — |
| 3 | **Alice 和 Bob 窗口** | 聊天区出现"服务器"来源的系统消息 |

### 10.5 删除用户

| 步骤 | 操作 | 预期 |
|------|------|------|
| 1 | **🛡️** → **删除用户** | 弹出输入对话框 |
| 2 | 输入 `charlie`（如果存在），点击删除 | 用户被删除 |

---

## 11. 阶段十：断线重连与异常处理

### 11.1 服务端断开后客户端表现

| 步骤 | 操作 | 预期 |
|------|------|------|
| 1 | 停止服务端（Ctrl+C） | — |
| 2 | 观察 Flutter 客户端 | 客户端检测到连接断开，自动返回登录界面 |

### 11.2 客户端关闭后服务端表现

| 步骤 | 操作 | 预期 |
|------|------|------|
| 1 | 重启服务端 | — |
| 2 | 启动 Flutter 客户端，登录 alice | — |
| 3 | 直接关闭 Flutter 窗口 | 服务端日志显示"客户端断开连接" |

---

## 12. 完整测试清单

| # | 测试项 | ☐ |
|---|--------|----|
| 1 | Flutter 环境确认 (flutter doctor) | ☐ |
| 2 | 依赖安装成功 (flutter pub get) | ☐ |
| 3 | Dart 静态分析通过 (dart analyze lib/) | ☐ |
| 4 | 服务端启动正常 | ☐ |
| 5 | Flutter 编译成功 (flutter build linux) | ☐ |
| 6 | 正常注册（合法用户名+密码） | ☐ |
| 7 | 客户端预验证——短用户名（<3字符） | ☐ |
| 8 | 客户端预验证——非法字符（SQL注入） | ☐ |
| 9 | 客户端预验证——短密码（<6字符） | ☐ |
| 10 | 重复注册被拒绝 | ☐ |
| 11 | 正常登录 | ☐ |
| 12 | 错误密码登录被拒 | ☐ |
| 13 | 添加好友 + 对方收到请求通知 | ☐ |
| 14 | 接受好友请求 → 双方列表更新 | ☐ |
| 15 | 拒绝好友请求 → 请求消失 | ☐ |
| 16 | 向不存在用户发好友请求 | ☐ |
| 17 | 在线私聊（好友）→ 双方实时收到 | ☐ |
| 18 | 双向聊天 | ☐ |
| 19 | 向非好友发消息被服务端拦截 | ☐ |
| 20 | 离线消息投递（含 [历史] 标记） | ☐ |
| 21 | 创建群组 → 侧边栏出现 | ☐ |
| 22 | 加入群组 → 侧边栏出现 | ☐ |
| 23 | 群聊消息广播到所有在线成员 | ☐ |
| 24 | 群聊消息撤回（双方同步） | ☐ |
| 25 | 私聊文件传输（请求→接受→接收→本地保存） | ☐ |
| 26 | 私聊文件传输（请求→拒绝） | ☐ |
| 27 | 群组文件传输 | ☐ |
| 28 | 撤回自己的消息（点击气泡） | ☐ |
| 29 | 撤回他人消息被阻止（无操作） | ☐ |
| 30 | 管理员登录（标题栏出现🛡️按钮） | ☐ |
| 31 | 查看所有用户 | ☐ |
| 32 | 发送系统公告 | ☐ |
| 33 | 删除用户 | ☐ |
| 34 | 服务端断开 → 客户端返回登录界面 | ☐ |
| 35 | 客户端关闭 → 服务端日志正常 | ☐ |

---

## 13. Flutter 与 tkinter 行为差异说明

| 功能 | tkinter 客户端 | Flutter 客户端 | 原因 |
|------|---------------|---------------|------|
| 在线状态显示 | 好友列表显示在线/离线 | 不显示 | v3.2.2 设计决策：参照微信风格 |
| 消息送达状态 [sent]/[delivered] | 显示在消息旁 | 不显示 | v3.2.2 设计决策：简化消息展示 |
| 消息回执确认弹窗 | 点击消息弹窗确认 | 直接发送 recall | Flutter 简化交互 |
| 管理员"查看用户" | 弹出独立表格窗口 | 以消息形式展示 | 实现简化 |
| 文件选择 | 系统原生文件对话框 | 系统原生文件对话框 (via file_picker) | Flutter 使用 file_picker 插件 |
| 深色模式 | ❌ 不支持 | ✅ 自动跟随系统 | Flutter Material 3 原生支持 |
| 聊天气泡 | ❌ 无（纯文本） | ✅ 圆角气泡 | Flutter 原生 UI 能力 |
| 窗口大小 | 固定 | ✅ 可自由缩放 | Flutter 响应式布局 |

---

## 附录 A：快速命令速查

```bash
# === 项目位置 ===
cd ~/PycharmProjects/chatroom

# === 服务端 ===
source .venv/bin/activate
python server/server_main.py                                    # 启动服务端

# === Flutter 客户端 ===
cd chatroom_flutter
flutter pub get                                                  # 安装依赖
dart analyze lib/                                                # 静态检查
flutter run -d linux                                             # 调试运行
flutter build linux                                              # 发布编译

# === 多客户端测试 ===
# 每个终端启动一个 flutter run -d linux 实例

# === 数据库管理 ===
sqlite3 users.db "SELECT username, is_admin FROM users;"         # 查看用户
sqlite3 users.db " DELETE FROM users WHERE username='alice';"    # 删除测试用户
sqlite3 users.db "SELECT * FROM message_history ORDER BY id DESC LIMIT 10;"  # 最近消息

# === Dart 协议层测试（阶段二基线） ===
cd dart_protocol
dart test -r expanded                                            # 15 个协议测试
```

## 附录 B：常见问题

### Q: `flutter run -d linux` 报 "No Linux desktop project configured"

运行 `flutter create --platforms=linux .` 生成 Linux 平台文件，然后重新 `flutter pub get`。

### Q: 连接被拒绝 (Connection refused)

确认服务端已启动并监听 `127.0.0.1:8090`：
```bash
ss -tlnp | grep 8090
```

### Q: SSL 错误

确认证书存在且未过期：
```bash
openssl x509 -in SSL/tsetcn.crt -text -noout | grep "Not After"
```
如过期，运行 `python SSL/gen_cert.py` 重新生成。

### Q: `dart_protocol` 包找不到

确认 `pubspec.yaml` 中的路径正确：
```yaml
dart_protocol:
  path: ../dart_protocol
```
路径相对于 `chatroom_flutter/` 目录。

---

> **阶段三完成后**，继续阶段四（安卓端布局适配）或阶段五（打包发布 .exe / AppImage / .apk）。
