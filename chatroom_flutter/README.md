# Rosub Flutter 客户端

Rosub 的 Flutter 客户端，支持 **Windows / Linux / Android** 三端（同账号跨端同时在线，同平台互踢、异平台并存）。

> 总览、协议与服务端说明见仓库根目录 [README](../README.md)；5 分钟跑通见 [QUICKSTART](../QUICKSTART.md)。

## 快速开始

```bash
# 先在仓库根目录跑起服务端（详见 QUICKSTART.md）
flutter pub get
flutter run -d linux          # 或 -d windows
```

服务器地址在编译期注入，缺省 `127.0.0.1`（连本机服务端零配置）：

```bash
flutter build apk --release --split-per-abi --dart-define=CHATROOM_SERVER_HOST=<服务器IP>
flutter build linux --release --dart-define=CHATROOM_SERVER_HOST=<服务器IP>
flutter build windows --release --dart-define=CHATROOM_SERVER_HOST=<服务器IP>
```

## 测试

```bash
dart analyze lib test integration_test   # 静态分析（零问题门槛）
flutter test                             # 全量 widget/单元/E2E 测试
```

## 项目结构

```
lib/
├── config.dart            # 服务器地址（dart-define 注入）/ 协议版本 / 上限常量
├── screens/               # 登录页（含 Android 双布局）、主界面、通话页
├── widgets/               # 会话列表 / 消息气泡 / 表情面板 / 文件与预览组件
├── services/
│   ├── socket_service.dart    # 连接 + 登录 + 消息收发 + 后台监听（核心）
│   ├── state_manager.dart     # 全局状态（AppState 单例）
│   ├── call_service.dart      # 通话状态机（1:1 与群通话 mesh）
│   ├── call_engine.dart       # flutter_webrtc 封装（SDP 净化/轨道管理）
│   ├── message_cache.dart     # 本地消息缓存（离线可读，sqflite FFI）
│   ├── taskbar_notifier.dart  # 通知闪烁 / 提示音合成
│   └── ...
├── platform/              # 平台能力抽象（输入/通知/拖拽/存储路径）
├── bridge/                # Linux GTK 输入法桥接进程（persistent_ime.py）
└── l10n/                  # 中/英双语文案
```

## 平台说明

- **Linux**：中文输入经 `bridge/` 的 GTK IME 桥接（绕开引擎输入法缺陷，fcitx 环境）；首运自动安装应用图标与桌面入口
- **Android**：后台消息保活前台服务 + 通话前台服务；通知渠道应用内自动创建；侧载安装
- **Windows**：视频播放走 media_kit（libmpv）；登录/输入走系统 IME
- **证书**：客户端默认不校验服务器证书（自签场景），如需防中间人可启用 `lib/services/certificate_trust.dart` 的指纹锁定
