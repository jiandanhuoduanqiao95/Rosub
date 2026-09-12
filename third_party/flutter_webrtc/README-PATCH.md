# flutter_webrtc（本地补丁副本）

上游：`flutter_webrtc 1.6.2+hotfix.1`（pub.dev，2026-09-08 发布，当前最新）
引入：阶段 R1 真机三轮（构建 r1s4，2026-09-12）

## 为什么存在这个副本

阶段 R1 真机测试：Android 端（OneUI）在「对方接听 / 自己接听」的瞬间必然闪退
（语音、视频皆然；拒绝路径正常；Linux 同代码正常）。r1s3 曾按 AudioSwitchManager
假说修复（无效），真根因在插件 Android 侧：

- 插件捆绑的 libwebrtc m150 预编译包（`io.github.webrtc-sdk:android:150.7871.01`）
  中，`org.webrtc.PeerConnection.getTransceivers()` 的实现是
  **「先 dispose 上一次返回的全部 Java wrapper，再从 native 取新列表」**
  （javap 字节码核实），非线程安全，且 `RtpTransceiver.dispose()` 对已释放
  wrapper 会抛 `IllegalStateException("RtpTransceiver has been disposed")`。
- 插件 `PeerConnectionObserver.onAddTrack`（上游崩溃栈中的
  PeerConnectionObserver.java:525）在 **WebRTC 信令线程** 回调里调用它：
  被叫应用 offer、主叫应用 answer 的那一刻 `onAddTrack` 逐远端轨道触发
  （语音也有 audio 轨），两次调用 / 与主线程 `getTransceiversTrack` 查找并发
  即双重 dispose → 信令线程抛异常 → SIGABRT 进程即死。
- 上游 issue：https://github.com/flutter-webrtc/flutter-webrtc/issues/2162
  （1.6.1/1.6.2 复现，已关闭但无代码修复；main 分支该行仍在）。

## 相对上游的改动（android/.../PeerConnectionObserver.java，grep `PATCH(chatroom`）

1. `onAddTrack`：删除 unified-plan 分支的 `getTransceivers()` enrichment
   （`if (false && ...)` 保留原代码备查）。onTrack 事件不再携带 `transceiver`
   字段——Dart 侧本就把它当可选项处理（`rtc_peerconnection_impl.dart`
   `map['transceiver'] != null ? ... : null`），本项目也未使用该字段。
2. `getRtpTransceiverById` / `getTransceivers(Result)` / `getTransceiversTrack`：
   包 try/catch(IllegalStateException) 防御 m150 的 dispose-all 语义。

## 剥离内容（减体积，可自动再生）

- `example/`（示例工程）
- `third_party/downloads/`、`third_party/libwebrtc/`（桌面端 libwebrtc 预编译
  缓存；Linux/Windows 构建时由 `third_party/CMakeLists.txt` 按
  `libwebrtc_version.ini` 从 GitHub releases 自动下载解压。下载超时可参照
  media_kit libmpv 的先例手动 curl 补齐至该目录）

## 移除条件

上游发布含 #2162 修复的版本后：删除本目录、去掉
`chatroom_flutter/pubspec.yaml` 的 `dependency_overrides`（及 `.gitignore`
相关条目），`flutter pub upgrade flutter_webrtc` 回到 hosted 依赖。
