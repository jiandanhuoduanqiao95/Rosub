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

## 相对上游的改动（桌面端音频路由，仅 windows/ 与 linux/ 子目录，grep `PATCH(chatroom`）

opt3~opt7 音频路由轮引入（`common/cpp/`、`android/`、`lib/` 与预编译包零改动）：

- **windows/audio_device_monitor.{h,cc}**：MMDevice 默认**通信**端点监听
  （自有 MTA 注册线程 + 300ms 防抖线程，**pending 按 flow 分槽**——单槽曾
  让断连风暴中 render/capture 事件互覆）。渲染端变化 → 与 ADM 枚举 GUID
  逐项匹配 → `SetPlayoutDevice`（wrapper 层 Stop→Set→Init→Start 全重启）；
  采集端变化 → **先做活性探测**（`ProbeCaptureEndpointLiveness`：共享模式
  开流 2s、**丢弃前 600ms 建链瞬态**、峰值 >1e-3 判活 + IAudioEndpointVolume
  静音检查），判定随回调交 follower 权衡（见下）。opt6 实证：EDIFIER
  W820NB 的蓝牙免提（HFP SCO）采集端点在系统级输出纯数字静音（独立
  WASAPI 探针 12s 全零；SCO 建链瞬态底噪可至 3e-4，故阈值取 1e-3——
  误拒仅"保持当前麦"，误放会整场静音，代价极不对称），盲切会把整场
  通话变成单向无声。事件处理以 **OnDefaultDeviceChanged 的 device_id
  （新默认）为准**，现解析在拆除风暴中滞后（曾解析到正在摘除的旧耳机
  并把录音切上去）；fire 前再校验目标**仍是当前默认**，否则丢弃陈旧
  fire。`ForceFire`（Dart 看门狗 resync 入口）只豁免同目标跳过、**不豁免
  活性判定**。
- **windows/flutter_webrtc_plugin.cc**：`FlutterWebRTCAudioFollower` 子类
  （protected `audio_device_` 的合规访问通道）+ getUserMedia 返回后
  `Probe(kCapture)` 纠偏（common 层 getUserMedia 把采集钉死到枚举
  index 0 = 任意端点）。opt7 核心修复——**同目标跳过**：follower 记忆
  每侧最后端点（采集基线 = getUserMedia 时的 index 0），fire 目标 ==
  记忆端点时**不重启**（蓝牙断开致默认回落内置麦时，旧逻辑会对正在
  使用的设备做一次 Stop→Set→Init→Start；该链 fire-and-forget 无重试，
  拆除风暴中 Init 失败 = 录音永久死亡，用户报障"断开耳机后对方再也
  听不到我"的真根因）。判定权衡：目标非活且**当前端点仍在** → 保持
  当前麦；当前端点已消失 → 无视判定照切（只剩它可选）。另有
  `chatroomAudioResync` 方法拦截（Dart 采集死亡看门狗的强制重绑入口）。
- **chatroom_flutter/lib/services/call_engine.dart（配套 Dart 侧）**：
  Windows 采集死亡看门狗——通话中出站 audioLevel 连续 24s 数字静音
  （且曾活过、未静音）→ 调 `chatroomAudioResync` 强制重绑（每媒体会话
  ≤3 次、30s 限频），兜底任何未预见的管道死亡。
- **linux/pulse_default_device_monitor.{h,cc}**：pa_threaded_mainloop 监听
  默认源**名**变化（SUBSCRIPTION_MASK_SERVER；无 libpulse 时编译为 no-op）。
  **linux/flutter_webrtc_plugin.cc**：默认源变化 → `SetRecordingDevice(0)`
  重启（ALSA ADM 的 index 0 恒为 "default" PCM，重启即按新默认源重开流；
  与 Windows 相反的 index 语义勿混淆）。播放侧无需对应物（pulse 服务器
  自动迁移流）。已实测端到端生效（source-output 真实搬家 + 电平随动）。
- 诊断：环境变量 `CHATROOM_AUDIO_MONITOR_LOG=<文件>` 开启事件/枚举/探测/
  切换全链路日志（生产不设即静默；`std::cerr` 在 `flutter test` 输出管道
  下全丢，opt3 实证）。

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
