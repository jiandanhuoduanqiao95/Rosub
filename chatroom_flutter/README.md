# chatroom_flutter —— Flutter 桌面客户端

> 聊天室系统的 Flutter (Dart) 桌面客户端，当前支持 Linux 桌面端。

---

## 快速开始

```bash
# 1. 启动服务端（需要先设置管理员密钥）
cd ~/PycharmProjects/chatroom
source .venv/bin/activate
export CHATROOM_ADMIN_SECRET='<你的管理员密钥>'
python server/server_main.py

# 2. 启动 Flutter 客户端
cd chatroom_flutter
flutter pub get
flutter run -d linux
```

## 测试

```bash
dart analyze lib test    # 静态分析（必须零 error）
flutter test             # widget 测试
flutter build linux --debug   # 编译验证
```

## 项目结构

```
lib/
├── main.dart                     # 入口 + Material 3 主题
├── config.dart                   # 客户端配置
├── models/chat_models.dart       # 数据模型 + 输入验证
├── services/
│   ├── socket_service.dart       # SSL 连接 + 协议通信 + 消息监听
│   ├── state_manager.dart        # 全局状态 (ChangeNotifier)
│   ├── ime_bridge.dart           # 中文输入法桥接管理
│   └── x11_ime.dart              # X11 FFI 接口（未使用，保留）
├── screens/
│   ├── login_screen.dart         # 登录/注册 + 管理员模式
│   └── chat_screen.dart          # 主聊天界面
└── widgets/
    ├── raw_text_field.dart       # 绕过系统 IME 的文本框
    ├── chat_view.dart            # 消息气泡 + 输入栏
    ├── sidebar.dart              # 会话侧边栏
    └── dialogs.dart              # 对话框 + 文件选择器

bridge/
└── persistent_ime.py             # GTK 输入法桥接进程（fcitx 兼容）
```

## 中文输入法

Flutter Linux 嵌入器与 fcitx IME 存在死锁问题。本项目通过独立的 Python GTK 进程桥接输入法：

- `bridge/persistent_ime.py`：常驻 GTK 透明窗口，接收 fcitx 输入
- `ime_bridge.dart`：管理桥接进程生命周期，通过 stdin/stdout 通信
- `raw_text_field.dart`：Flutter 侧文本框，绕过系统 IME，ASCII 直接捕获，中文通过桥接

支持光标位置同步（方向键移动）、文本设置/清空、焦点切换。

## 依赖

- ffi, file_picker, intl, dart_protocol（见 `pubspec.yaml`）
