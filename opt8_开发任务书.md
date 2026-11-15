# Rosub opt8 通话体验增强 —— 开发任务书

> 文档用途：把本轮需求、设计、代码落点、测试方案、手动验收清单和提交纪律完整交给执行 Agent。
> 执行 Agent 必须先把本文读完，再按顺序实施；本文与 `AGENTS.md` 冲突时以 `AGENTS.md` 的既有架构约束为准，但本文的**提交纪律**更严格，必须遵守。
>
> 生成日期：2026-10-28
> 目标仓库：`/home/fengyang/PycharmProjects/chatroom`
> 当前分支：`dart`
> 当前 HEAD：`096e291`（tag `v1.0.2`）
> 当前版本：`pubspec.yaml` = `1.0.2+2009`；`AppConfig.buildStamp` = `1.0.2-opt7`
> 本轮最终候选：`pubspec.yaml` = `1.1.0+2013`；`AppConfig.buildStamp` = `1.1.0`（开发自测包见 §8）
> 服务端/协议：**零改动**（协议 v1.0.0 冻结）

---

## 0. 执行 Agent 的第一条指令

1. 先读 `AGENTS.md`，重点读阶段 Q1/Q2/R1/R2/opt1~opt7 的维护注意。
2. 确认当前目录是 `/home/fengyang/PycharmProjects/chatroom`，分支是 `dart`。工作区除本任务书（untracked）外应无未提交改动；本任务书最终随唯一一次 commit 一起提交。
3. **不要**去 `chatroom-q1-android`、`chatroom-q2-windows`、`chatroom-q3-macos` 三个 worktree 开发。它们是同一仓库的历史平台快照，不包含 opt1~opt7 修复。
4. 按本文顺序实施：功能一 → 功能三 → 功能二。
5. **在用户明确说“可以提交”之前，不允许执行 `git add` / `git commit` / `git push` / `git tag`；也不允许 `git stash` / `git reset` / `git checkout` / `git merge` / `git pull` / `git rebase` 等会改变工作树、暂存区、分支或引用的命令。** 只读 `git status` / `git diff` / `git log` / `git show` 可以。**整个批次最终有且只有一次 commit，中间过程零 commit。**
6. 每个功能都要同时交付：实现代码、自动化测试、`TESTING_GUIDE.md` 手动测试章节、`opt8_验证步骤清单.md` 对应条目。
7. 自动测试全绿不等于可以提交；必须等用户在最终合并候选上手动三端测试后明确授权，且只产生一次 commit。
8. 中间开发包不要求用户手测；只对最终合并候选做一次完整三端手测。最终候选版本定稿为 `1.1.0+2013` / `buildStamp 1.1.0`。

---

## 1. 用户已经拍板的决策（不要再问）

| 决策 | 结论 |
|---|---|
| 悬浮球是否接受 `SYSTEM_ALERT_WINDOW` 特殊权限 | **接受**。用户愿意在系统设置里授予“显示在其他应用上层” |
| 通知里的“拒绝”按钮短暂把 App 拉到前台 | **接受**。v1 允许 `PendingIntent.getActivity` 打开 App 后执行拒绝，不要求完全后台拒绝 |
| Android 来电是否应用级震动 | **不做**。本轮只保证铃声；是否震动由系统通知设置/ROM 决定，不新增原生震动循环 |
| 提交时机 | **三个功能全部完成、用户在最终合并候选上手动测试确认无误并明确声明后，才允许本地 commit；整个批次有且只有一次 commit。中间过程不 commit、不 push、不 tag。** 远端 push/tag 还必须再获得明确授权 |
| 手动测试节奏 | **只对最终合并候选做一次完整三端手测**；中间开发包只做开发自测/冒烟，不算验收 |
| 最终候选版本 | `pubspec: 1.1.0+2013`；`buildStamp: 1.1.0`（开发自测包可选：`1.0.2-opt8/opt9/opt10` + `2010/2011/2012`） |
| 功能三平台范围 | **Android + Linux/Windows 桌面唤起**：Android 用系统通知/full-screen intent；Linux/Windows 来电时恢复窗口并把 `CallScreen` 带到前台，不做桌面全屏覆盖 |
| Android 解锁来电形态 | **系统标准 heads-up**（锁屏才 full-screen intent 全屏；部分国产 ROM 可能直接全屏） |
| 上下栏收起范围 | **仅 `connecting` / `active`** 可收起；`ringing` / `calling` 保持接听/拒绝/取消键可见 |
| 悬浮球显示阶段 | **`calling` / `connecting` / `active`**；`ringing` 不显示（来电通知接管） |
| 群通话通知标题 | **仅群名**；不显示邀请人（如需邀请人需额外保存 `groupInviter`） |
| 三个平台 | Android + Linux + Windows；Q3 macOS 不在本轮范围 |
| 每个新功能 | 必须附带详尽的手动测试指南，并放进仓库 |
| 测试顺序 | 先多轮自动化确认，再三端安装最新版手动测试；手测失败必须修复并重走自动化门禁 |

---

## 2. 本轮范围与非目标

### 2.1 三个功能

1. **通话页上下栏收起/展开**：点击通话舞台（或上下栏背景）让顶部信息条和底部控制排同时收起，再点一次恢复。1:1 与群通话、语音与视频都支持。
2. **Android 通话悬浮球**：通话中用户离开 Rosub 回到桌面或其他 App 时，显示一个系统级悬浮球；点击直接回到通话界面，可拖动。
3. **后台来电弹出**：来电时即使 Rosub 不在前台，也要有系统级提醒——Android 出现系统来电通知（锁屏 full-screen intent / 解锁 heads-up，带接听/拒绝）；Linux/Windows 恢复最小化/后台窗口并把 `CallScreen` 带到前台（Wayland/Windows 前台锁可能阻止抢焦点时，用任务栏 urgency/FlashWindowEx 兜底）。

### 2.2 非目标

- 不改服务端、不改协议、不改数据库。
- 不做 iOS/macOS/iPadOS 适配。
- 不接入 FCM/厂商推送。**进程被系统杀掉、force-stop、或被 ROM 深度冻结后，客户端无法收到来电**；这是侧载应用没有推送通道的硬限制，手测记录为“已知限制”，不要试图用客户端代码解决。
- 不把现有的 `CallForegroundService` 振铃期通知与来电通知强行合并成一条；v1 接受振铃期两条通知并存（详见功能三）。
- 不把 `CallForegroundService` 的启动时机从 `ringing` 延迟到 `connecting`；Android 14 后台采集要求 FGS 先就位，延迟会引入媒体采集竞态。
- 桌面端不做“全屏覆盖当前 App”的来电窗口，也不做桌面来电悬浮卡片；只做窗口恢复/置前 + 任务栏提醒。Wayland 合成器或 Windows 前台锁可能拒绝抢焦点，这是系统限制，手测记录实际表现。

---

## 3. 当前代码地图（2026-10-28 快照）

> 行号会随改动漂移；执行时以符号名为准。

| 文件 | 作用 | 关键符号 / 位置 |
|---|---|---|
| `chatroom_flutter/lib/screens/call_screen.dart` | 通话页 UI | `build`（约 228）、`showStage`（约 236-238）、舞台 `Positioned.fill`（约 269-276）、顶部信息条（约 277-282）、底部控制排（约 283-288）、自己的悬浮小窗（约 290）、`_buildStage`（约 377）、`_buildStageHeaderBar`（约 487）、`_buildStageControlsBar`（约 534）、`_buildStageSelfPip`（约 646）、`_buildControls`（约 709）、`_accept`（约 180） |
| `chatroom_flutter/lib/screens/chat_screen.dart` | 会话主界面、通话路由/悬浮条/生命周期 | `initState`（约 65）、`onCallPhaseChanged` 接线（约 75）、`didChangeAppLifecycleState`（约 134）、`_handleOpenCallIntent`（约 149）、`_syncCallForegroundService`（约 165）、`dispose`（约 176）、`_onCallChanged`（约 1326）、`_buildCallPillLayer`（约 1372） |
| `chatroom_flutter/lib/services/call_service.dart` | 通话状态机 | `incomingRingTimeout = 30s`（约 146）、`isInLiveCall`（约 196）、`_startRingtone`（约 249）、`_stopRingtone`（约 255）、`minimize`（约 278）、`restore`（约 285）、`acceptIncoming`（约 418）、`rejectIncoming`（约 502）、`call_invite`（约 560）、`_handleGroupInvite`（约 775）、`_teardown`（约 1149） |
| `chatroom_flutter/lib/services/socket_service.dart` | 信令收发与回调 | `onCallPhaseChanged`（约 54）、`_forwardCallPhase`（约 56）、通话信令路由（约 1323/1338、2345/2360） |
| `chatroom_flutter/lib/platform/android_system.dart` | Android MethodChannel 封装 | `requestCallPermissions`（约 44）、`startCallForeground`（约 79）、`stopCallForeground`（约 92）、`consumeOpenCallIntent`（约 104） |
| `chatroom_flutter/lib/platform/capabilities_android.dart` | Android 提示音能力 | `playCallRingtone`（约 65） |
| `chatroom_flutter/lib/platform/capabilities.dart` | 平台能力工厂/窗口能力扩展点 | `PlatformCapabilities` 四能力、`effectiveTargetPlatform`、`*Override`/`resetForTest`；新增 `WindowActivationCapability` |
| `chatroom_flutter/lib/services/focus_tracker.dart` | 窗口焦点状态 | `FocusTracker.instance.focused`（main.dart 聚焦时清除 urgency，桌面来电兜底相关） |
| `chatroom_flutter/lib/services/taskbar_notifier.dart` | 桌面 urgency/提示音 | `setUrgencyImpl`、`flash`、`clearUrgency` |
| `chatroom_flutter/linux/runner/my_application.cc` | Linux GTK 窗口 | `g_app_window`、`chatroom_set_urgency`、`g_idle_add` 主线程转发；新增 `chatroom_bring_to_front` |
| `chatroom_flutter/windows/runner/win32_window.cpp` | Windows 窗口基类 | `kWindowClassName = FLUTTER_RUNNER_WIN32_WINDOW`、`GetHandle`、`Show` |
| `chatroom_flutter/android/app/src/main/kotlin/com/example/chatroom_flutter/MainActivity.kt` | 原生入口/通道 | `onCreate`（约 37）、`onNewIntent`（约 51）、通道处理（约 66）、`setupCallChannel`（约 329）、`consumeOpenCallIntent`（约 136）、`openCallIntentPending`（约 665） |
| `chatroom_flutter/android/app/src/main/kotlin/com/example/chatroom_flutter/CallForegroundService.kt` | 通话 FGS | `onStartCommand`（约 34）、`startAsForeground`（约 40）、`contentIntent`（约 64）、通知 Builder（约 75）、`CHANNEL_ID = chatroom_call_v2`、`NOTIF_ID = 1003`（约 145-146） |
| `chatroom_flutter/android/app/src/main/kotlin/com/example/chatroom_flutter/KeepAliveService.kt` | 后台消息保活 FGS | `CHANNEL_ID = chatroom_keepalive_v2`、`NOTIF_ID = 1001` |
| `chatroom_flutter/android/app/src/main/AndroidManifest.xml` | 权限/组件 | 权限块约 1-28；MainActivity 约 34；KeepAliveService 约 69；CallForegroundService 约 86 |
| `chatroom_flutter/test/screens/call_screen_stage_r_test.dart` | 1:1 通话页测试 | Fake engine/signaling、CallScreen pump |
| `chatroom_flutter/test/screens/call_screen_stage_gc_test.dart` | 群通话页测试 | 群 ringing/宫格/成员收缩 |
| `chatroom_flutter/test/screens/chat_screen_call_pill_test.dart` | 悬浮条测试 | MockSocketService + 真实 CallService；捕获 `onCallPhaseChanged` 手动触发 |
| `chatroom_flutter/test/services/android_system_stage_q1_test.dart` | MethodChannel 契约 | mock `chatroom/platform` 通道 |
| `chatroom_flutter/test/services/call_keepalive_opt_test.dart` | opt1 P5/P6 契约 | `isInLiveCall`、源码扫描、Kotlin/Manifest 契约 |
| `chatroom_flutter/test/services/call_signal_e2e_test.dart` | 1:1 信令 E2E | 真实服务端子进程，端口 8099，FakeE2eEngine |
| `chatroom_flutter/test/services/group_call_signal_e2e_test.dart` | 群信令 E2E | 真实服务端子进程，端口 8100，FakeE2eEngine |
| `chatroom_flutter/integration_test/android_skeleton_test.dart` | Android 设备端骨架 | `flutter test integration_test/... -d <device>` |
| `chatroom_flutter/integration_test/group_call_device_test.dart` | R2 三端真机驱动 | 角色化 `--dart-define` / `gc_role.txt` |
| `TESTING_GUIDE.md` | 手动测试总指南 | §36.10 R2、§36.11/§36.12 opt6/opt7 |
| `TESTING_GUIDE_FLUTTER.md` | 自动化测试规约 | §21.1 分层、§21.4 门槛、§21.35 R2 |
| `AGENTS.md` | 开发操作规范 | 阶段 Q/R/opt 维护注意 |

### 3.1 现状行为（重要）

- 来电信令已经能到 `CallService`：一对一 `call_invite`，群聊 `group_call_invite`。
- `ChatScreen._onCallChanged` 在满足 `!svc.minimized && svc.phase != CallPhase.idle && !_callRouteOpen` 时会 `Navigator.push(CallScreen)`；**前台正常，后台时这个 push 不可见**。`_callRouteOpen` 在路由 `.then` 中复位，防止重复 push。
- 振铃期 `CallService._startRingtone()` 会循环播放铃声；`ChatScreen._syncCallForegroundService` 会启动 `CallForegroundService`，于是通知栏出现静默的“Rosub 通话中”通知（`chatroom_call_v2`，IMPORTANCE_DEFAULT）。它没有 full-screen intent、没有接听/拒绝按钮。
- 因此用户说的“只能在打开 Rosub 后才能收到来电”，根因是**后台没有任何系统级来电 UI**，不是信令没到。
- 已存在 `open_call=1` 链路：`CallForegroundService` 通知点击 → `MainActivity` 置 `openCallIntentPending` → `ChatScreen` resumed 时 `_handleOpenCallIntent()` 消费 → 若 `svc.isInLiveCall && svc.minimized` 则 `restore()`。本轮悬浮球和来电通知都应复用这条链路。
- `CallService._teardown()` 后先进入 `ended` 展示 2 秒，再回 `idle`；所有与通知/悬浮球相关的清理要覆盖 `ended` 和 `idle` 两个阶段。

---

## 4. 功能一：通话页上下栏收起/展开

### 4.1 需求

- 通话接通后（`connecting` / `active`），点击通话舞台任意位置，顶部信息条和底部控制排放同时收起。
- 再点击一次恢复。
- 点击顶部/底部栏的背景区域也应能收起；点击栏内按钮仍执行按钮功能，不触发收起。
- 1:1 与群通话、语音与视频都支持。
- `ringing` / `calling` 阶段**不允许**隐藏，否则接听/拒绝/取消键消失。
- 桌面（Linux/Windows）鼠标单击与 Android 触摸行为一致。
- 收起只隐藏**顶部信息条 + 底部控制排**；远端画面、群宫格、自己的悬浮小窗（PIP）保持可见。

### 4.2 实现方案（`lib/screens/call_screen.dart`）

1. 在 `_CallScreenState` 增加：

```dart
bool _chromeVisible = true;

void _toggleChrome() => setState(() => _chromeVisible = !_chromeVisible);

void _hideChrome() {
  if (!_chromeVisible) return;
  setState(() => _chromeVisible = false);
}
```

2. 给舞台（`showStage` 分支里的 `Positioned.fill`）包 `GestureDetector`：

```dart
Positioned.fill(
  child: SafeArea(
    child: GestureDetector(
      key: const Key('call_stage'),
      behavior: HitTestBehavior.opaque,
      onTap: _toggleChrome,
      child: (_svc.type == CallType.video && !_renderersReady)
          ? _buildStagePending()
          : _buildStage(),
    ),
  ),
),
```

3. 顶部信息条包 `IgnorePointer + AnimatedOpacity`，并在容器背景加收起手势：

```dart
Positioned(
  top: topInset + 8,
  left: 12,
  right: 12,
  child: IgnorePointer(
    ignoring: !_chromeVisible,
    child: AnimatedOpacity(
      key: const Key('call_stage_header'),
      opacity: _chromeVisible ? 1 : 0,
      duration: const Duration(milliseconds: 180),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _hideChrome,
        child: _buildStageHeaderBar(),
      ),
    ),
  ),
),
```

4. 底部控制排同样处理，key 用 `call_stage_controls`。`_buildStageControlsBar` 的渐变容器外包 `GestureDetector(behavior: HitTestBehavior.opaque, onTap: _hideChrome)`，内部按钮的 InkWell 会优先响应。

5. 自己的悬浮小窗 `_buildStageSelfPip` 的 `GestureDetector` 增加 `onTap: _toggleChrome`，保留现有 `onPanUpdate` 拖动逻辑。拖动超过 touch slop 时不应触发 tap。

6. 不要在 `ringing` / `calling` 分支使用这个状态。`showStage` 之外的布局保持原样。

### 4.3 细节与坑

- 必须用 `IgnorePointer`，否则透明度为 0 的栏仍会吃点击。
- 用 `AnimatedOpacity`，不要用 `Visibility` / `Offstage` 直接移除：会触发布局跳动、影响现有 finder 和动画。
- 隐藏后用户点原挂断键位置，应该只是恢复栏，不能挂断——这是最重要的安全用例。
- `pumpAndSettle` 不可用于 active 通话页测试：`_ticker` 每秒 `setState`，容易不 settle。用 `pump(Duration(milliseconds: 200))`。
- 点击顶部/底部栏背景时，父级 `GestureDetector` 与内部按钮的 InkWell 竞争，内部按钮优先；实现后要用测试确认静音/挂断键仍然可用。
- 群通话隐藏栏时成员加入/离开，宫格应继续更新；不要因为隐藏而停止 `setState`。
- 通话进入 `ended` 时栏应可见或至少不阻塞结束原因展示；最简单做法是在 `_onPhaseChanged` 里当 `phase == ended` 时把 `_chromeVisible = true`。
- 自测时确认 1:1 视频的远端画面不断流、自己的小窗仍可拖动。
- 如果某个平台的 `RTCVideoView`（平台视图）吞掉点击，导致舞台级 `GestureDetector` 收不到 tap，再在瓦片外补一层 `GestureDetector`/`Listener`；先按舞台级实现，真机验证后再决定是否加。

### 4.4 新增测试

新文件：`chatroom_flutter/test/screens/call_screen_chrome_opt8_test.dart`

复用 `call_screen_stage_r_test.dart` / `call_screen_stage_gc_test.dart` 的 FakeEngine/FakeSignaling harness。至少覆盖：

| # | 用例 | 断言 |
|---|---|---|
| 1 | 1:1 语音 active 初始态 | `call_stage_header` / `call_stage_controls` 的 `AnimatedOpacity.opacity == 1` |
| 2 | 点 `call_stage` | 两个 opacity 变 0，`IgnorePointer.ignoring == true` |
| 3 | 再点 `call_stage` | 两个 opacity 恢复 1，`IgnorePointer.ignoring == false` |
| 4 | 点顶部栏背景 | 收起 |
| 5 | 点底部栏背景 | 收起，未挂断 |
| 6 | 点静音键 | `_svc.micMuted` 变化，栏不收起 |
| 7 | 隐藏后点原挂断键位置 | 只恢复栏，`phase` 仍为 active |
| 8 | 拖动 PIP | 不触发收起；位置变化 |
| 9 | 点 PIP | 触发收起/恢复 |
| 10 | 群视频 active | 与 1:1 同样行为 |
| 11 | 群语音 active | 与 1:1 同样行为 |
| 12 | ringing / calling | 点舞台不改变栏可见性；接听/拒绝/取消键可见 |
| 13 | ended | 结束原因可见，不卡在隐藏态 |
| 14 | 最小化 → restore | 新 CallScreen 默认栏可见 |

源码契约（可并入 `call_native_contract_opt8_test.dart`）：
- `call_screen.dart` 包含 `_chromeVisible`、`Key('call_stage')`、`Key('call_stage_header')`、`Key('call_stage_controls')`。
- 两个栏都被 `IgnorePointer` 包裹（防止后续重构删掉）。

### 4.5 手动测试指南（复制到 `TESTING_GUIDE.md §37.2`）

**前置**：任意平台；两端已建立 1:1 语音/视频；群聊至少 2 人。

| # | 平台 | 操作 | 预期 |
|---|---|---|---|
| F1-01 | 全部 | 1:1 语音接通，点画面中央 | 顶部信息条和底部控制排同时淡出；通话计时/声音不中断 |
| F1-02 | 全部 | 再点画面中央 | 上下栏恢复；按钮位置与之前一致 |
| F1-03 | 全部 | 1:1 视频接通，点远端画面 | 上下栏收起；远端画面不变形、不断流；自己的小窗仍可见 |
| F1-04 | 全部 | 视频通话中拖动自己的小窗 | 小窗跟手移动；不触发上下栏切换；松手后位置保持 |
| F1-05 | 全部 | 上下栏可见时点顶部信息条空白处 | 上下栏收起 |
| F1-06 | 全部 | 上下栏可见时点底部渐变空白处 | 上下栏收起；不触发挂断 |
| F1-07 | 全部 | 上下栏隐藏后点原挂断键所在位置 | 只恢复上下栏，不挂断 |
| F1-08 | 全部 | 上下栏可见时点静音/免提/关摄像头/挂断 | 对应功能正常；上下栏不收起 |
| F1-09 | 全部 | 群视频/群语音接通，重复 F1-01/F1-02 | 宫格不变；成员瓦片、昵称、麦克风图标正常；计时/人数正常 |
| F1-10 | 全部 | 群通话中有人加入/离开（栏隐藏时） | 宫格实时增减；栏保持隐藏；不崩溃 |
| F1-11 | 全部 | 去电 `calling` / 来电 `ringing` 阶段点画面 | 上下栏不隐藏；取消/接听/拒绝键始终可见 |
| F1-12 | 全部 | 通话结束（对方挂断）时栏处于隐藏态 | 正常显示结束原因；2 秒后返回；不卡在隐藏态 |
| F1-13 | 全部 | 上下栏隐藏时按系统返回/点最小化 → 会话页悬浮条 → 点悬浮条恢复 | 正常最小化（不挂断）；恢复后上下栏默认可见，通话未中断 |
| F1-14 | 全部 | Android 旋转屏幕；Linux/Windows 缩放窗口 | 布局重排正常；无溢出、无黑屏；栏状态不导致崩溃 |
| F1-15 | Linux/Windows | 鼠标单击画面 | 与手指点击一致；不需要双击；悬停不误触发 |

**证据**：录屏一段（收起→展开→点原挂断位不挂断）；隐藏态和恢复态截图。
**失败判定**：收起后仍能误触挂断/静音；点按钮导致收起；视频断流；群宫格错乱。

---

## 5. 功能三：后台来电弹出（Android 系统通知 + Linux/Windows 桌面唤起）

### 5.1 需求与现状

- 目标：来电时 Rosub 不在前台，也要有系统级提醒：
  - Android：系统来电通知（锁屏 full-screen intent / 解锁 heads-up）。
  - Linux/Windows：恢复最小化/后台窗口，把 `CallScreen` 带到前台；抢焦点失败时任务栏 urgency/FlashWindowEx 兜底。
- 锁屏：full-screen intent 全屏显示通话页。
- 解锁但在其他 App：Android 标准行为是 heads-up 通知（部分国产 ROM 会直接全屏）。
- 通知带“接听 / 拒绝”按钮；点击后回到通话页或直接接听/拒绝。
- 前台来电：不要发**高优先级来电通知**；现有 `CallScreen` 直接弹出即可。`CallForegroundService` 的静默“Rosub 通话中”通知仍按 P5 现有行为出现。
- 已知硬限制：进程被杀 / force-stop / ROM 深度冻结时收不到；无 FCM/厂商推送，不解决。

### 5.2 总体架构

1. **独立的来电通知通道**，不要复用 `chatroom_call_v2`。
2. **独立的来电通知 ID**（建议 1004），由 Dart 在振铃且 App 不在前台时触发。
3. **通知 full-screen intent + 接听/拒绝 action**。
4. `MainActivity` 记录 `pendingCallAction`，Dart 在 `resumed` 时消费。
5. `ChatScreen` 扩展 `_handleOpenCallIntent` 为统一的 `_handleCallIntent`。
6. 现有 `CallForegroundService` 保持振铃期启动；因此振铃期会有两条通知（来电通知 + 静默“Rosub 通话中”），v1 接受。
7. **Linux/Windows**：不走向系统通知/full-screen intent，而是新增 `WindowActivationCapability`，在来电 `ringing` 时恢复/置前，直接显示 `CallScreen`；详见 5.13。

### 5.3 通知通道

建议新增 Kotlin 辅助对象，例如 `IncomingCallNotifier.kt`，或放在 `MainActivity` 内；推荐独立文件。

```kotlin
const val CHANNEL_ID = "chatroom_incoming_call_v1"
const val NOTIF_ID = 1004
```

通道配置：

- name: `"来电"`
- `IMPORTANCE_HIGH`（heads-up 必需）
- `setSound(null, null)`（铃声仍由 Dart `PlatformCallSound` 循环播放，避免双响）
- `enableVibration(false)`（用户决策：本轮只保证铃声，不做应用级震动；是否震动由系统通知设置/ROM 决定）
- `lockscreenVisibility = Notification.VISIBILITY_PUBLIC`
- `setShowBadge(false)`

创建时机：
- App 启动路径（例如 `setupCallChannel` 同处）创建/更新；
- `showIncomingCallNotification` 内 `create-if-absent` 兜底。
- 不要在 FGS 运行中 `deleteNotificationChannel`（opt1 真机 SecurityException 教训）。
- `showIncomingCallNotification` 内先检查 Android 13+ `POST_NOTIFICATIONS`；未授予直接 return，不崩溃（与现有 `showMessageNotification` 一致）。

### 5.4 通知内容

| 场景 | 标题 | 正文 |
|---|---|---|
| 1:1 语音 | 对方用户名 | 邀请你语音通话 |
| 1:1 视频 | 对方用户名 | 邀请你视频通话 |
| 群语音 | 群名 | 邀请你加入群语音通话 |
| 群视频 | 群名 | 邀请你加入群视频通话 |

> 群聊默认用群名作标题，不显示邀请人。若产品要求“张三邀请你加入群…”，需要在 `CallService._handleGroupInvite` 保存 `groupInviter` 并传入通知；当前按群名实现，除非用户另行要求。

Builder 关键项（`title/body` 由 Dart 的 `CallPresentation` 计算后经通道传入，原生不重复拼文案，保证文案可单测）：

```kotlin
NotificationCompat.Builder(this, CHANNEL_ID)
    .setSmallIcon(R.drawable.ic_notification_white)
    .setContentTitle(title)
    .setContentText(body)
    .setCategory(NotificationCompat.CATEGORY_CALL)
    .setPriority(NotificationCompat.PRIORITY_MAX)
    .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
    .setOngoing(true)
    .setAutoCancel(false)
    .setOnlyAlertOnce(true)
    .setContentIntent(openIntent)
    .setFullScreenIntent(openIntent, true) // Android 14+ 权限不足时系统会忽略
    .setTimeoutAfter(45_000)
    .addAction(0, "拒绝", declineIntent)
    .addAction(0, "接听", answerIntent)
```

注意：
- 不要设 `largeIcon`（vivo 通知模板会出现左右两个重复应用徽标，gc17 结论）。
- `setTimeoutAfter(45s)` 是原生兜底；Dart 30s 超时会先取消。
- Android 14+ 使用前检查 `NotificationManager.canUseFullScreenIntent()`；false 时仍发 heads-up，不要不发通知。
- 可选：Android 12+ 用 `NotificationCompat.CallStyle.forIncomingCall(...)` 获得系统通话样式；但首版建议先用普通 HIGH 通知 + 两个 action，避免国产 ROM 兼容差异。

### 5.5 PendingIntent 与 action

三个 PendingIntent，requestCode 必须不同：

1. `openIntent`：打开 `MainActivity`，extra `open_call=1` + `call_lockscreen=1`。
2. `answerIntent`：打开 `MainActivity`，extra `open_call=1` + `call_lockscreen=1` + `call_action=accept`。
3. `declineIntent`：打开 `MainActivity`，extra `open_call=1` + `call_lockscreen=1` + `call_action=decline`。

`call_lockscreen=1` 只用于**来电通知**；现有的“Rosub 通话中”FGS 通知不要带这个 extra，避免用户从锁屏点普通通话通知时也覆盖锁屏。

统一 flags：

```kotlin
Intent.FLAG_ACTIVITY_NEW_TASK or
Intent.FLAG_ACTIVITY_SINGLE_TOP or
Intent.FLAG_ACTIVITY_CLEAR_TOP
```

`PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE`。

> 用户已接受：点“拒绝”会短暂把 App 拉到前台，然后 Dart 执行 `rejectIncoming()`。不要为此引入 BroadcastReceiver 后台拒绝的复杂方案。

### 5.6 MainActivity 改造

1. companion 增加：

```kotlin
@Volatile var pendingCallAction: String? = null
```

2. 提取统一处理函数 `handleCallIntent(intent: Intent?)`：
   - 若 `open_call=1`：置 `openCallIntentPending = true`，并读取 `pendingCallAction = intent.getStringExtra(EXTRA_CALL_ACTION)`；
   - **仅当 `call_lockscreen=1` 时**设置锁屏显示（只给来电通知；FGS“通话中”通知不带该 extra）：
     - API 27+：`setShowWhenLocked(true)`、`setTurnScreenOn(true)`
     - 旧版：`window.addFlags(FLAG_SHOW_WHEN_LOCKED or FLAG_TURN_SCREEN_ON)`
   - 非 `open_call` 的普通启动不要动 `pendingCallAction`。
3. `onCreate` / `onNewIntent` 都调用 `handleCallIntent(intent)`。
4. 新增通道方法：

```kotlin
"showIncomingCallNotification" -> {
    IncomingCallNotifier.show(
        this,
        call.argument<String>("title") ?: "",
        call.argument<String>("body") ?: "",
    )
    result.success(true)
}
"cancelIncomingCallNotification" -> { IncomingCallNotifier.cancel(this); result.success(true) }
"consumeCallIntent" -> {
    result.success(mapOf(
        "open" to openCallIntentPending,
        "action" to pendingCallAction
    ))
    openCallIntentPending = false
    pendingCallAction = null
}
"hasFullScreenIntentPermission" -> result.success(canUseFullScreenIntent())
"requestFullScreenIntentPermission" -> { ... Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT ... }
"clearCallLockFlags" -> { clearLockFlags(); result.success(true) }
```

5. 保留 `consumeOpenCallIntent`（现有测试兼容），可以内部委托给新逻辑。
6. 通话结束/取消时清除锁屏标志：新增通道方法 `clearCallLockFlags`，Dart 在 `_onCallChanged` 离开 live call 时调用。
   - 不要全局在 Manifest 里设 `showWhenLocked`；只在来电 Intent 时设置，避免普通启动覆盖锁屏造成隐私问题。

### 5.7 Manifest 权限

`chatroom_flutter/android/app/src/main/AndroidManifest.xml` 增加：

```xml
<uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT"/>
```

`POST_NOTIFICATIONS` 已有，不要重复添加。
`SYSTEM_ALERT_WINDOW` 是功能二用，见后文。

### 5.8 Dart：`AndroidSystem` 新方法

在 `lib/platform/android_system.dart` 增加：

```dart
static Future<void> showIncomingCallNotification({
  required String title,
  required String body,
});

static Future<void> cancelIncomingCallNotification();

static Future<CallIntentResult> consumeCallIntent();

static Future<bool> hasFullScreenIntentPermission();

static Future<void> requestFullScreenIntentPermission();

static Future<void> clearCallLockFlags();
```

`CallIntentResult` 建议：

```dart
class CallIntentResult {
  const CallIntentResult({required this.open, this.action});
  final bool open;
  final String? action; // 'accept' | 'decline' | null
}
```

非 Android 平台全部安全 no-op/false；所有通道异常静默降级。

### 5.9 Dart：ChatScreen 接线

1. 维护 `_appResumed`（initState 默认 true，`didChangeAppLifecycleState` 更新）。
2. 扩展通话快照字段，供通知文案使用：
   - `_callSnapshotIsGroup`
   - `_callSnapshotGroupName`
   - `_callSnapshotType`
   - `_callSnapshotPeer`（已有）
3. 新增 `_syncIncomingNotification()`：

```dart
void _syncIncomingNotification() {
  if (effectiveTargetPlatform() != TargetPlatform.android) return;
  if (!CallPresentation.shouldShowIncomingNotification(
    phase: _callSnapshotPhase,
    appResumed: _appResumed,
  )) {
    unawaited(AndroidSystem.cancelIncomingCallNotification());
    return;
  }
  final title = CallPresentation.displayName(
    isGroup: _callSnapshotIsGroup,
    peer: _callSnapshotPeer,
    groupName: _callSnapshotGroupName,
  );
  final body = CallPresentation.incomingBody(
    isGroup: _callSnapshotIsGroup,
    video: _callSnapshotType == CallType.video,
  );
  unawaited(AndroidSystem.showIncomingCallNotification(
    title: title,
    body: body,
  ));
}
```

4. `_onCallChanged()`：
   - 更新快照；
   - 调用 `_syncCallForegroundService(svc)`（保持现状）；
   - 调用 `_syncIncomingNotification()`；
   - 若 `!svc.isInLiveCall`，调用 `AndroidSystem.clearCallLockFlags()` 与 `AndroidSystem.cancelIncomingCallNotification()`；
   - 现有 push `CallScreen` 逻辑保持（后台 push 不可见但不影响，通知会把 App 带回前台）。
5. `didChangeAppLifecycleState`：
   - `paused`：`_appResumed = false`；启动 KeepAlive；`_syncIncomingNotification()`（如果正在振铃，补发通知）；`_syncSystemBubble()`（功能二）。
   - `resumed`：`_appResumed = true`；停止 KeepAlive；取消来电通知；隐藏悬浮球；`_handleCallIntent()`。
6. `_handleOpenCallIntent` 改为 `_handleCallIntent`：

```dart
Future<void> _handleCallIntent() async {
  final intent = await AndroidSystem.consumeCallIntent();
  if (!intent.open || !mounted) return;
  try {
    final svc = widget.socketService.callService;
    if (!svc.isInLiveCall) {
      unawaited(AndroidSystem.cancelIncomingCallNotification());
      unawaited(AndroidSystem.clearCallLockFlags());
      return;
    }
    switch (intent.action) {
      case 'accept':
        await _acceptCallFromIntent(svc);
        break;
      case 'decline':
        unawaited(AndroidSystem.cancelIncomingCallNotification());
        svc.rejectIncoming();
        break;
      default:
        if (svc.minimized) svc.restore();
    }
  } catch (_) {
    // Mock 测试未 stub callService getter：纯增益通道静默降级
  }
}
```

7. `_acceptCallFromIntent(svc)`：
   - 先 `svc.phase == CallPhase.ringing` 判断；
   - `AndroidSystem.requestCallPermissions(video: svc.type == CallType.video)`；
   - 授权成功 → `svc.acceptIncoming()`；
   - 拒绝 → `svc.rejectIncoming()` + SnackBar 提示。
   - 建议把 `CallScreen._accept` 的逻辑提取成公共函数，避免两套权限文案。

8. `ChatScreen.initState` 的 postFrame 里也调用一次 `_handleCallIntent()`，覆盖冷启动/warm start 时 notification 带来的 pending action；不只在 `resumed` 时消费。

### 5.9.1 纯策略模块（强烈建议新增）

为了能稳定单测“什么时候发通知/显示悬浮球”，新增一个不依赖 BuildContext/平台通道的纯 Dart 文件：

`chatroom_flutter/lib/services/call_presentation.dart`

```dart
class CallPresentation {
  static bool shouldShowIncomingNotification({
    required CallPhase phase,
    required bool appResumed,
  }) => phase == CallPhase.ringing && !appResumed;

  static bool shouldShowCallBubble({
    required CallPhase phase,
    required bool appResumed,
  }) {
    if (appResumed) return false;
    return phase == CallPhase.calling ||
        phase == CallPhase.connecting ||
        phase == CallPhase.active;
  }

  static String displayName({
    required bool isGroup,
    String? peer,
    String? groupName,
  }) => isGroup ? (groupName ?? '群聊') : (peer ?? '');

  static String incomingBody({
    required bool isGroup,
    required bool video,
  }) =>
      isGroup
          ? '邀请你加入群${video ? '视频' : '语音'}通话'
          : '邀请你${video ? '视频' : '语音'}通话';

  static bool shouldBringDesktopCallToFront({
    required CallPhase phase,
    required TargetPlatform platform,
  }) =>
      phase == CallPhase.ringing &&
      (platform == TargetPlatform.linux ||
          platform == TargetPlatform.windows);
}
```

> `call_presentation.dart` 需要 `import 'package:flutter/foundation.dart' show TargetPlatform;` 与 `import 'call_service.dart';`。`ChatScreen._syncIncomingNotification()`、`_syncSystemBubble()`、桌面来电唤起都调用这里；`call_notification_policy_opt8_test.dart` / `call_bubble_policy_opt8_test.dart` / `window_activation_opt8_test.dart` 直接测这个文件，不依赖 Widget 树。

### 5.10 重要边界

- 前台振铃不发**高优先级来电通知**；`_syncIncomingNotification` 只在 `!_appResumed` 时发。`CallForegroundService` 的静默“Rosub 通话中”通知仍按 P5 出现，不要误判为来电通知。
- 用户从桌面通过图标打开 App（不是通知）时，`resumed` 会取消通知；如果还在振铃，通话页已由 `_onCallChanged` push。
- 来电通知取消点：
  - 接听（phase → connecting）
  - 拒绝（phase → ended）
  - 30s 超时（`_teardown`）
  - 主叫取消（`call_cancel` → `_teardown`）
  - 其他设备接听（`call_active` → `_teardown`）
  - 群通话 `group_call_left` / `ended` 收敛
- `setTimeoutAfter(45s)` 仅原生兜底；Dart 的 30s 定时器应先取消通知。
- Android 14+ 全屏权限不足时仍要发 heads-up；不要因为 `canUseFullScreenIntent() == false` 就 return。
- 锁屏标志必须在通话结束或非来电启动时清除，避免普通启动覆盖锁屏。

### 5.11 两条通知的取舍（已定，不要擅自改）

振铃期会同时存在：

1. 新的高优先级来电通知（`chatroom_incoming_call_v1`）；
2. `CallForegroundService` 的静默“Rosub 通话中”通知（`chatroom_call_v2`）。

vivo 可能把两条聚合成组，点组展开。v1 接受。
**不要**为了只留一条而把 FGS 延迟到 `connecting`：Android 14 后台采集要求 FGS 先就位，延迟会引入媒体采集竞态。若二期要单条，再把 FGS 通知本身做成来电样式，成本更高。

### 5.12 新增测试

新文件：`chatroom_flutter/test/services/call_intent_opt8_test.dart`
- `consumeCallIntent` 的 open/accept/decline/未知 action 映射。
- `CallIntentResult` 解析。

新文件：`chatroom_flutter/test/services/call_notification_policy_opt8_test.dart`
- 直接测 `lib/services/call_presentation.dart`：`CallPresentation.shouldShowIncomingNotification`。
- `ringing + 后台` → true。
- `ringing + 前台` → false。
- `active/ended/idle` → false。
- `CallPresentation.displayName`：1:1 用用户名、群聊用群名、空值兜底。
- `CallPresentation.incomingBody`：1:1 语音/视频、群语音/视频四种文案。

扩展：`chatroom_flutter/test/screens/chat_screen_call_lifecycle_opt8_test.dart`
- 使用 MockSocketService + 真实 CallService（FakeEngine/FakeSignaling）。
- mock `chatroom/platform` 通道：`consumeCallIntent`（默认 `{open:false}`）、`requestCallPermissions`、`showIncomingCallNotification`、`cancelIncomingCallNotification`、`showCallBubble`、`hideCallBubble`、`clearCallLockFlags`；ChatScreen initState 的 `setupMessageChannel`/`setupCallChannel`/`requestNotificationPermission` 也要有返回，避免 MissingPluginException。
- `tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused)` → `showIncomingCallNotification`。
- `resumed` → `cancelIncomingCallNotification`。
- `consumeCallIntent` mock 返回 `{open:true, action:'decline'}` → phase ended。
- `accept` + 权限授予 → phase connecting / `call_accept` 已发送。
- `accept` + 权限拒绝 → `rejectIncoming`。
- 非 ringing 时 action 到达 → 忽略。
- 测试结束把 lifecycle 恢复 `resumed`，并移除 platform override。

扩展：`chatroom_flutter/test/services/android_system_stage_q1_test.dart` 或新建 `android_system_opt8_test.dart`
- 新通道方法名、参数、返回值。
- `consumeCallIntent` 的 map 解析。
- 非 Android 平台 no-op。

新文件：`chatroom_flutter/test/services/call_native_contract_opt8_test.dart`（源码扫描）
- Manifest 含 `USE_FULL_SCREEN_INTENT`。
- Kotlin 含 `chatroom_incoming_call_v1`、`CATEGORY_CALL`、`setFullScreenIntent`、`EXTRA_CALL_ACTION`、`call_lockscreen`、`pendingCallAction`、`consumeCallIntent`、`setShowWhenLocked`、`setTurnScreenOn`、`canUseFullScreenIntent`、`clearCallLockFlags`。
- `MainActivity.onCreate` 与 `onNewIntent` 都处理 call intent。
- `AndroidSystem` 暴露新方法。

新文件：`chatroom_flutter/test/services/window_activation_opt8_test.dart`
- 见 5.13.5：`CallPresentation.shouldBringDesktopCallToFront` 矩阵、`WindowActivationCapability` 工厂/override、桌面 FFI 源码契约。

回归：`call_service_stage_r_test.dart`、`call_service_stage_gc_test.dart`、`call_signal_e2e_test.dart`（8099）、`group_call_signal_e2e_test.dart`（8100）全绿。

### 5.13 桌面端唤起（Linux/Windows）

目标：来电 `ringing` 时，若 Rosub 最小化/不在前台，恢复窗口并把 `CallScreen` 带到前台；不做桌面全屏覆盖。

#### 5.13.1 新能力接口

在 `lib/platform/capabilities.dart` 增加：

```dart
abstract class WindowActivationCapability {
  bool get isSupported;
  Future<void> bringToFront();
}
```

并接入 `PlatformCapabilities` 的 override/默认工厂/resetForTest：

- `windowOverride`、`window` getter、`_window` 缓存、`resetForTest()` 清理；`_resolve()` 的缓存命中条件同时检查 `_window != null`（避免只初始化了其他能力时 window 为 null）；
- Linux：`LinuxWindowActivationCapability`；
- Windows：`WindowsWindowActivationCapability`；
- Android/iOS/macOS：`DesktopWindowActivationStub`（`isSupported=false`）。

#### 5.13.2 Linux（GTK runner + FFI）

`linux/runner/my_application.cc` 新增导出函数（与 `chatroom_set_urgency` 同样的 `extern "C"` / `used` / `visibility("default")` / `g_idle_add` 模式）：

```cpp
static gboolean apply_bring_to_front_cb(gpointer user_data) {
  auto* win = static_cast<GtkWindow*>(user_data);
  if (win != nullptr) {
    // 已经 active 时不要设 urgency，否则 FocusTracker 不会再触发
    // clearUrgency，任务栏可能一直闪。
    if (!gtk_window_is_active(win)) {
      gtk_window_set_urgency_hint(win, TRUE);
    }
    gtk_window_deiconify(win);
    gtk_window_present(win);
  }
  return G_SOURCE_REMOVE;
}

extern "C" __attribute__((used, visibility("default")))
void chatroom_bring_to_front() {
  g_idle_add(apply_bring_to_front_cb, g_app_window);
}
```

Dart 侧 `LinuxWindowActivationCapability` 经 `DynamicLibrary.process()` 查找 `chatroom_bring_to_front`；符号缺失/FFI 异常静默降级。`linux/runner/CMakeLists.txt` 的 `-Wl,--export-dynamic` 不能删（H2 既有约定）。

#### 5.13.3 Windows（user32 FFI）

`WindowsWindowActivationCapability` 复用现有 `FindWindowW('FLUTTER_RUNNER_WIN32_WINDOW')` 取 HWND，然后通过 user32 FFI：

1. `IsIconic(hwnd)` 为真 → `ShowWindow(hwnd, SW_RESTORE /* 9 */)`；
2. `SetWindowPos(hwnd, HWND_TOP /* 0 */, 0,0,0,0,
   SWP_NOMOVE|SWP_NOSIZE|SWP_SHOWWINDOW)`；
3. `SetForegroundWindow(hwnd)`；
4. 若 `SetForegroundWindow` 返回 0（Windows 前台锁拒绝），回退 `FlashWindowEx(FLASHW_ALL|FLASHW_TIMERNOFG)`；可复用 `WindowsNotificationCapability` 的 `_Flashwinfo`/`_resolveWindowHandle` 逻辑，抽成共享 helper。

> Windows 前台锁（foreground lock）可能让 `SetForegroundWindow` 失败，这是系统行为；任务栏闪烁是兜底，不要用 `AttachThreadInput`/模拟按键等侵入手段。

#### 5.13.4 ChatScreen 接线

在 `CallPresentation` 增加纯策略：

```dart
static bool shouldBringDesktopCallToFront({
  required CallPhase phase,
  required TargetPlatform platform,
}) =>
    phase == CallPhase.ringing &&
    (platform == TargetPlatform.linux || platform == TargetPlatform.windows);
```

`ChatScreen._onCallChanged()` 在完成快照更新、`Navigator.push(CallScreen)` 之后调用：

```dart
bool _desktopCallBrought = false;

// _onCallChanged 末尾、push 之后：
if (_callSnapshotPhase != CallPhase.ringing) {
  _desktopCallBrought = false;
} else if (!_desktopCallBrought &&
    CallPresentation.shouldBringDesktopCallToFront(
      phase: _callSnapshotPhase,
      platform: effectiveTargetPlatform(),
    )) {
  _desktopCallBrought = true;
  unawaited(PlatformCapabilities.window.bringToFront());
}
```

约束：
- 只在**来电 ringing** 调用；去电 `calling` 不抢焦点。
- 平台能力是幂等的：已在前台时 `gtk_window_present`/`SetForegroundWindow` 无副作用，不需要依赖 `FocusTracker`（避免焦点状态滞后导致漏唤起）。
- Android 不调用（走系统通知/full-screen intent）。
- `_onCallChanged` 可能在振铃期被多次调用；加 `_desktopCallBrought` 标志防止重复抢焦点，离开 ringing/进入 ended 时复位。
- 桌面来电铃声已由 `PlatformCallSound` 循环播放，本能力只负责窗口。
- 若窗口已最小化，先恢复再显示 `CallScreen`；由于 `_onCallChanged` 已 push 路由，窗口激活后会直接看到通话页。

#### 5.13.5 测试

新文件：`chatroom_flutter/test/services/window_activation_opt8_test.dart`
- `CallPresentation.shouldBringDesktopCallToFront` 矩阵：ringing + Linux/Windows → true；calling/active/ended → false；Android/iOS → false。
- `PlatformCapabilities.windowOverride` 注入 fake，断言 `bringToFront` 被调用；`resetForTest` 清理。
- 工厂选择：Linux/Windows 为 supported；Android/iOS 为 stub。

扩展 `chat_screen_call_lifecycle_opt8_test.dart`：
- 注入 `PlatformCapabilities.windowOverride = fake`，避免真实 FFI。
- 模拟来电 ringing + platform override Linux/Windows → `bringToFront` 被调用。
- Android → 不调用。
- ringing 期间多次 `_onCallChanged` 只调用一次；进入 ended 后复位，新来电可再次调用。
- 测试结束恢复 platform override，并 `PlatformCapabilities.resetForTest()`。

源码契约（并入 `call_native_contract_opt8_test.dart`）：
- `linux/runner/my_application.cc` 含 `chatroom_bring_to_front`、`gtk_window_present`、`g_idle_add`。
- `linux/runner/CMakeLists.txt` 仍含 `--export-dynamic`。
- `capabilities.dart` 含 `WindowActivationCapability`、`SetForegroundWindow`、`ShowWindow`、`FlashWindowEx`。
- `chat_screen.dart` 含 `bringToFront` 接线。

### 5.14 手动测试指南（复制到 `TESTING_GUIDE.md §37.4`）

**前置**：Android 被叫端已登录并退到后台/锁屏；通知权限、全屏通知权限已授予；电池白名单；PC 端主叫。默认可先关闭免打扰，单独跑一轮免打扰场景。
**桌面前置**：Linux/Windows 与主叫账号已登录；App 可最小化/被其他窗口遮挡；桌面环境允许任务栏/焦点操作（Wayland 合成器/Windows 前台锁的限制记录为系统行为）。

| # | 平台 | 操作 | 预期 |
|---|---|---|---|
| F3-01 | Android | Android 停留在聊天页（前台），PC 呼叫 | 直接弹出通话页；**不**出现来电横幅/全屏；FGS 静默“Rosub 通话中”通知可能存在（P5 现有行为）；接听/拒绝正常 |
| F3-02 | Android | Android 按 Home 在桌面，PC 呼叫语音 | 顶部 heads-up 通知：标题=主叫名，正文=邀请你语音通话；有拒绝/接听按钮；铃声正常（部分 ROM 可能直接全屏） |
| F3-03 | Android | 同上，点通知正文 | 打开 App 并显示通话页；通话仍处于 ringing |
| F3-04 | Android | 同上，点“接听” | App 到前台；首次使用会弹麦克风权限；授权后接通；主叫看到已接听 |
| F3-05 | Android | 同上，点“拒绝” | 按已确认 v1 取舍：App 短暂到前台，随后通话结束；主叫看到“对方已拒绝”；通知清除 |
| F3-06 | Android | Android 锁屏，PC 呼叫视频 | 屏幕点亮并显示全屏通话页（锁屏上）；接听/拒绝可用 |
| F3-07 | Android | 锁屏接听后正常通话；结束后按 Home 再普通打开 App | 不再覆盖锁屏；普通启动行为正常（锁屏标志已清除） |
| F3-08 | Android | 后台振铃 30 秒不操作 | 通知消失、铃声停止；主叫看到超时/未接听；无残留通知 |
| F3-09 | Android | 后台振铃时主叫取消 | 通知立即消失；铃声停止；无残留 |
| F3-10 | Android | 同账号另一台设备接听 | 本机通知消失、停铃；状态显示“已在其他设备接听”；不重复弹通话页 |
| F3-11 | Android | 群通话邀请（后台） | 通知标题=群名，正文=邀请你加入群语音/视频通话；接听进入群宫格；拒绝后群内看到成员离开 |
| F3-12 | Android | 关闭通知权限后重复 F3-02 | 无来电通知/横幅（FGS 通知行为按系统）；前台来电仍正常；记录当前行为 |
| F3-13 | Android | Android 14+ 关闭“全屏通知”权限后锁屏来电 | 仍应有 heads-up/普通通知；不应崩溃；设置页可跳转授权；授权后恢复全屏 |
| F3-14 | Android | 开启免打扰/静音模式后来电 | 铃声按系统设置；应用不主动震动；通知仍可见（或按系统策略）；记录实际表现 |
| F3-15 | Android | 后台放置 10 分钟后再来电 | 仍能收到通知（KeepAlive/FGS 存活）；若 ROM 已杀进程则记录为已知限制 |
| F3-16 | Android | force-stop App 后呼叫 | 收不到来电（预期限制：无厂商推送）；无残留通知；重新打开可正常登录 |
| F3-17 | Android | 回归：前台通话、最小化悬浮条、悬浮球、FGS“通话中”通知、音视频质量 | 与 opt7 基线一致 |
| F3-18 | Linux | App 最小化/被其他窗口遮挡/在其他工作区，PC 呼叫 | 窗口恢复并置前，直接看到 `CallScreen` ringing；接听/拒绝可用；若合成器拒绝抢焦点，任务栏 urgency 闪烁，记录实际表现 |
| F3-19 | Windows | App 最小化/被其他窗口遮挡，PC 呼叫 | 窗口恢复（SW_RESTORE）并置前，直接看到 `CallScreen` ringing；若前台锁拒绝 `SetForegroundWindow`，任务栏 FlashWindowEx 闪烁，记录实际表现 |

**证据**：锁屏全屏页截图、桌面 heads-up 截图、通知栏展开截图；Linux/Windows 窗口恢复/任务栏闪烁录屏；`adb shell dumpsys notification --noredact | grep -A 30 -i chatroom_incoming_call`；`adb shell dumpsys activity activities | grep -i MainActivity`；`adb logcat -d -b crash`；主叫端结果截图。
**失败判定**：后台只有铃声没有通知；锁屏不亮屏/不显示；接听后媒体断；拒绝后主叫仍振铃；通知残留；全屏标志未清除导致普通启动覆盖锁屏。

---

## 6. 功能二：Android 通话悬浮球

### 6.1 需求

- 通话中用户离开 Rosub（按 Home、切到其他 App、从会话页按返回退出到桌面）时，显示一个系统级圆形悬浮球。
- 点击悬浮球直接回到通话界面（已最小化则恢复通话页；未最小化则原通话页回前台）。
- 可拖动，位置不跑出屏幕。
- 通话结束/退出登录/被强制下线时自动消失。
- 仅 Android；应用在前台时不显示（应用内已有悬浮条）。

### 6.2 架构选择

推荐把 overlay 宿主放在 `CallForegroundService`，原因：

- 该服务在通话期间已经运行（`isInLiveCall` 时启动），不需要新增 Service；
- 避免 Android 8+ 后台启动普通 Service 的限制；
- 服务 `onDestroy` 可以统一清理球。

不推荐单独新建 `CallBubbleService`：多一个 Service、多一份生命周期，收益不大。

### 6.3 Manifest

```xml
<uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW"/>
```

特殊权限，不能 `requestPermissions`，只能跳系统设置：

```kotlin
Settings.canDrawOverlays(this)
startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
    Uri.parse("package:$packageName")))
```

### 6.4 原生：CallForegroundService

1. `onStartCommand` 增加 action。**气泡 action 绝不能把进行中的视频 FGS 降级成纯 microphone 类型**，也不要重复 `startForeground`；用 `foregroundStarted` 标志判断：

```kotlin
private var foregroundStarted = false

when (intent?.action) {
    ACTION_SHOW_BUBBLE -> {
        ensureForeground(intent?.getBooleanExtra(EXTRA_VIDEO, false) ?: false)
        showBubble()
        return START_STICKY
    }
    ACTION_HIDE_BUBBLE -> {
        ensureForeground(intent?.getBooleanExtra(EXTRA_VIDEO, false) ?: false)
        hideBubble()
        return START_STICKY
    }
}

private fun ensureForeground(video: Boolean) {
    if (!foregroundStarted) startAsForeground(video)
}
```

`startAsForeground()` 成功后置 `foregroundStarted = true`；`onDestroy()` 复位为 false。Dart 的 `showCallBubble/hideCallBubble` 必须携带当前通话的 `video` 标志（见 6.5/6.6）。

2. `showBubble()`：
   - `if (!Settings.canDrawOverlays(this)) return`
   - `WindowManager` + `ImageView`，56dp 圆形；
   - API 26+ 用 `WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY`，旧版 `TYPE_PHONE`；
   - flags：`FLAG_NOT_FOCUSABLE or FLAG_NOT_TOUCH_MODAL or FLAG_LAYOUT_IN_SCREEN`；
   - 初始位置：右边缘、垂直居中；
   - 背景：`GradientDrawable` 椭圆 + 半透明深色；
   - 图标：新增 `res/drawable/ic_call_bubble.xml` 白色电话矢量图（不要用自适应图标位图）。
3. 拖动 + 点击：
   - `OnTouchListener` 记录 `ACTION_DOWN` 的 `rawX/rawY` 和 `params.x/y`；
   - `ACTION_MOVE` 更新 `params.x/y`，`updateViewLayout`；
   - `ACTION_UP` 时移动距离 < `ViewConfiguration.getScaledTouchSlop()` 才触发点击；
   - 点击：`PendingIntent.getActivity(... open_call=1 ...).send()`；
   - 边界 clamp，保留 8~16dp 边距；
   - `onConfigurationChanged`（旋转/分屏）时用新的屏幕尺寸重新 clamp 当前 `params.x/y`。
4. 清理：
   - `hideBubble()` 移除 View；
   - `onDestroy()` 移除；
   - `onTaskRemoved()` 隐藏球并 `stopSelf()`（任务被划掉后 Flutter engine 已不可用，通话状态无法继续；避免幽灵球和幽灵 FGS）。
5. 服务不在时的防御：
   - Dart 侧只在 `isInLiveCall` 时调用 `showCallBubble()`，正常路径服务已运行；
   - 若服务意外不在，`showCallBubble` 用 `startForegroundService` 启动，action 分支先 `startAsForeground(video=false)` 再显示球；
   - `hideCallBubble` 用 `startService`；服务不在时 catch 异常即可，最终 `onDestroy()` 也会移除 View；
   - 不要用 `startForegroundService` 启动一个只做 hide 的服务，避免无意义 FGS 通知。

### 6.5 Dart：AndroidSystem

新增：

```dart
static Future<bool> hasOverlayPermission();
static Future<void> requestOverlayPermission();
static Future<void> showCallBubble({required bool video});
static Future<void> hideCallBubble({required bool video});
```

`MainActivity` 通道处理：

```kotlin
"hasOverlayPermission" -> result.success(Settings.canDrawOverlays(this))
"requestOverlayPermission" -> {
    try {
        startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:$packageName")))
        result.success(true)
    } catch (e: Exception) { result.success(false) }
}
"showCallBubble" -> {
    CallForegroundService.showBubble(
        this, call.argument<Boolean>("video") ?: false)
    result.success(true)
}
"hideCallBubble" -> {
    CallForegroundService.hideBubble(
        this, call.argument<Boolean>("video") ?: false)
    result.success(true)
}
```

非 Android 平台 no-op / false。

`CallForegroundService.showBubble(context, video)` / `hideBubble(context, video)` 的 companion 方法必须把 `video` 写入 `EXTRA_VIDEO`，再分别用 `startForegroundService` / `startService` 发 action；否则进行中的视频通话会被降级成纯 microphone FGS。

### 6.6 Dart：ChatScreen 生命周期

1. 使用 `CallPresentation.shouldShowCallBubble`（定义见 5.9.1），不要重复实现一套：

```dart
bool _bubbleRequested = false;

void _syncSystemBubble() {
  if (effectiveTargetPlatform() != TargetPlatform.android) return;
  final visible = CallPresentation.shouldShowCallBubble(
    phase: _callSnapshotPhase,
    appResumed: _appResumed,
  );
  final video = _callSnapshotType == CallType.video;
  if (visible) {
    if (_bubbleRequested) return;
    _bubbleRequested = true;
    unawaited(AndroidSystem.showCallBubble(video: video));
  } else {
    if (!_bubbleRequested) return;
    _bubbleRequested = false;
    unawaited(AndroidSystem.hideCallBubble(video: video));
  }
}
```

`ringing` 不显示球（来电通知接管）。`_bubbleRequested` 是防止在从未显示过球时调用 hide——否则前台 idle/resume 会无端给 `CallForegroundService` 发 hide action，甚至在服务未运行时启动一个无意义的 FGS。

2. `didChangeAppLifecycleState`：
   - `paused`：`_appResumed = false`；`startKeepAlive()`；`_syncSystemBubble()`；`_syncIncomingNotification()`。
   - `resumed`：`_appResumed = true`；`stopKeepAlive()`；`_syncSystemBubble()`（会在 `_bubbleRequested` 时 hide）；`cancelIncomingCallNotification()`；`_handleCallIntent()`。
3. `_onCallChanged`：
   - 更新快照；
   - `_syncSystemBubble()`（通话结束/进入 ringing 会自动 hide）。
4. `dispose`：若 `_bubbleRequested` 为 true，先 `hideCallBubble(video: ...)` 再 `stopCallForeground()` 双保险，避免 hide 反而启动服务。
5. 非 Android 平台不调用；Mock 未 stub `callService` 时 try/catch 静默。

### 6.7 权限 UX

- 不要 App 启动就申请。
- 在 `showSettingsDialog`（`lib/widgets/dialogs.dart`，约 1467）增加 Android-only 的“通话悬浮球”入口，显示当前状态；点击跳系统设置。
- 默认只加设置页入口，**首次通话不弹提示**（避免打扰）；如果用户要求首次提示，再加一次性 SnackBar/小横幅并用 `shared_preferences` 记住“不再提示”。
- 用户拒绝权限：不显示球、不崩溃；现有 P6“通话中”通知仍可回通话；应用内悬浮条正常。
- vivo/三星可能还有“后台弹出界面”开关；文档中提示用户开启。

### 6.8 新增测试

新文件：`chatroom_flutter/test/services/call_bubble_policy_opt8_test.dart`
- 直接测 `CallPresentation.shouldShowCallBubble`：前台→false；后台 + calling/connecting/active→true；后台 + ringing/ended/idle→false。
- 平台门控由 `ChatScreen` 负责（仅 Android 调用），不在纯策略里判断平台。

扩展：`chatroom_flutter/test/screens/chat_screen_call_lifecycle_opt8_test.dart`
- `paused` + 语音 active → `showCallBubble(video: false)`；视频 active → `showCallBubble(video: true)`（断言 `video` 参数被正确透传）。
- 前台 idle / 从未显示过球 → **不调用** `hideCallBubble`（防止无意义启动/更新 FGS）。
- `resumed` → `hideCallBubble(video: ...)`（仅当之前 show 过）。
- 通话结束/ringing → `hideCallBubble(video: ...)`（仅当之前 show 过）。
- dispose → hide（仅当之前 show 过）。
- Mock 未 stub `callService` 不崩。

扩展：`chatroom_flutter/test/services/android_system_stage_q1_test.dart` 或新建 `android_system_opt8_test.dart`
- 四个新方法名/参数/返回值（`video` 必传）。
- 非 Android no-op。

新文件/扩展：`chatroom_flutter/test/services/call_native_contract_opt8_test.dart`
- Manifest 含 `SYSTEM_ALERT_WINDOW`。
- Kotlin 含 `TYPE_APPLICATION_OVERLAY`、`ACTION_SHOW_BUBBLE`、`ACTION_HIDE_BUBBLE`、`Settings.canDrawOverlays`、`FLAG_NOT_FOCUSABLE`、`FLAG_NOT_TOUCH_MODAL`、`foregroundStarted`/`ensureForeground`。
- 球点击 PendingIntent 带 `open_call`。
- `onDestroy`/`onTaskRemoved` 有清理。

设备端：`integration_test/call_ui_device_test.dart`
- 用假引擎进入 active，真机触摸验证上下栏收起/展开（功能一）。
- 调用 `AndroidSystem.hasOverlayPermission()` / `showCallBubble(video: false)` / `hideCallBubble(video: false)` 不抛异常（权限未授予时也只返回 false，不崩）。

### 6.9 手动测试指南（复制到 `TESTING_GUIDE.md §37.3`）

**前置**：Android 真机；已授予“显示在其他应用上层”；通知权限已授予；电池白名单；与 PC 端建立通话。

| # | 平台 | 操作 | 预期 |
|---|---|---|---|
| F2-01 | Android | 设置页找到“通话悬浮球”，查看状态 | 显示当前是否已授权；点“去开启”跳系统“显示在其他应用上层”页面 |
| F2-02 | Android | 授权后返回 App，重新打开设置 | 状态变为“已开启” |
| F2-03 | Android | 1:1 语音通话接通，按 Home 回桌面 | 约 1~2 秒内出现圆形悬浮球（右边缘偏中）；通话声音不断 |
| F2-04 | Android | 拖动悬浮球到屏幕四角 | 跟手移动，不跑出屏幕；不遮挡状态栏/导航栏关键区域 |
| F2-05 | Android | 点悬浮球 | 直接回到通话界面；通话未中断；对方仍能听到/看到你 |
| F2-06 | Android | 通话中打开微信/浏览器，再观察 | 悬浮球显示在其他 App 上层；点它回到通话界面 |
| F2-07 | Android | 通话页点“‹”最小化 → 按 Home → 点悬浮球 | 直接回到**通话页**（不是只回会话列表）；悬浮条/路由不重复 |
| F2-08 | Android | 通话页未最小化 → 按 Home → 点悬浮球 | 回到原来的通话页；返回键只回一层，不出现双 CallScreen |
| F2-09 | Android | 通话中按 Home，等对方挂断 | 悬浮球自动消失；“Rosub 通话中”通知消失；无残留可点球 |
| F2-10 | Android | 通话中按 Home，等 5 分钟 | 悬浮球仍在、通话仍在；点回正常（验证后台存活） |
| F2-11 | Android | 群语音/群视频通话重复 F2-03/F2-05 | 悬浮球出现并可回到群宫格；成员/画面正常 |
| F2-12 | Android | 拒绝悬浮窗权限后通话并 Home | 不显示悬浮球、不崩溃；通知栏“通话中”仍可回通话；应用内悬浮条正常 |
| F2-13 | Android | 通话中到系统设置撤销悬浮窗权限，再回 App/Home | 不崩溃；球消失或不再出现；下次授权后恢复 |
| F2-14 | Android | 横屏/分屏下按 Home | 球位置合理、可点击；不覆盖系统手势区 |
| F2-15 | Android | 通话中从最近任务划掉 App | 球随服务清理消失；重新打开 App 不残留幽灵球 |
| F2-16 | Android | 退出登录/被强制下线 | 球消失；无残留；重新登录后不出现 |
| F2-17 | Android/Linux/Windows | 回归：Android 检查“Rosub 通话中”“Rosub 在线中”通知与音视频；Linux/Windows 检查通话、最小化/恢复、无 Android 专属副作用 | 与 opt7 基线一致，无新增通知/断流/耗电异常；桌面不出现悬浮球 |
| F2-18 | Android | 去电 `calling` 阶段（对方未接）按 Home，再点悬浮球 | 悬浮球出现；点击回到原呼叫页（仍 calling/ringing）；对方接听后正常进入通话 |

**证据**：桌面/其他 App 上的悬浮球截图；点回通话后的截图；`adb shell appops get com.example.chatroom_flutter SYSTEM_ALERT_WINDOW`；`adb logcat -d -s CallForegroundService:V`。
**失败判定**：球挡住系统手势导致无法返回桌面；点球回到会话列表而非通话页；通话结束球残留；权限拒绝时崩溃。

---

## 7. 跨功能契约（不要破坏）

1. **pop 职责只在通话页**：`CallScreen` 自己 pop（idle 或 minimized）；`ChatScreen` 只 push，不能 pop。否则会出现双 pop 弹空导航栈黑屏（r1s10 回归）。
2. **`open_call` P6 链路**：通知/悬浮球点击 → `MainActivity` 置 pending → Dart resumed 消费 → 最小化才 `restore()`。不要另起一套“直接 push CallScreen”的逻辑。
3. **FGS/KeepAlive 门控**：`CallForegroundService` 与 `KeepAliveService` 并存，生命周期门控不要动；`_onConnectionLost` / `ensureConnectedOnResume` 的 `isInLiveCall` 豁免不要动；`disconnect()` 仍无条件拆场。
4. **平台判定**：统一用 `effectiveTargetPlatform()`，不要直接读 `defaultTargetPlatform`；widget 测试用 `debugDefaultTargetPlatformOverride` 并在 body 内恢复。
5. **Mock 安全**：`ChatScreen.build` 不得直读 `callService` getter；使用快照字段或 try/catch。新增生命周期通道调用要能被 MockSocketService 测试容忍。
6. **服务端/协议零改动**：不要新增消息类型、不要改 `protocol.py` / `dart_protocol` / `server/`。
7. **通知渠道**：
   - 消息 `chatroom_messages_v2` / id 2001
   - 传输 `chatroom_transfer_v2` / id 2002
   - 通话中 `chatroom_call_v2` / id 1003
   - 保活 `chatroom_keepalive_v2` / id 1001
   - 新来电 `chatroom_incoming_call_v1` / id 1004
   - 渠道 id 一旦发布不要降级/复用；vivo SystemUI 有渠道级渲染缓存。
8. **FGS 内禁止 `deleteNotificationChannel`**（opt1 真机 SecurityException）；渠道删除重建只放 `MainActivity` 启动路径。
9. **不要设置通知 largeIcon**（gc17 vivo 重复徽标结论），除非用户另行要求并走 `Icon.createWithResource`。
10. **不要移除 `ACCESS_NETWORK_STATE`**（R1 接听闪退真根因）。
11. **不要改动 `bypassVoiceProcessing` 初始化顺序**（vivo 采集静音修复，r1s9）。
12. **不要移除通话 FGS 的 specialUse 降级**（opt5 权限回收防闪退）。
13. **气泡 action 不得降级 FGS 类型**：进行中的视频通话必须保持 `microphone|camera`。`ensureForeground` 只在该服务尚未前台时启动，并且 Dart 的 `showCallBubble/hideCallBubble` 必须携带当前 `video` 标志；否则视频通话中显示/隐藏球会把 FGS 重置成纯 microphone，后台摄像头可能被系统切断。
14. **桌面来电唤起只在 `ringing` + Linux/Windows**：平台能力可幂等调用（已在前台时无副作用）；Android 走系统通知。Linux 的 `chatroom_bring_to_front` 必须走 `g_idle_add` 主线程 + `-Wl,--export-dynamic`；Windows 用 `SetForegroundWindow`，失败回退 `FlashWindowEx`，不要用 `AttachThreadInput`/模拟按键等侵入手段。

---

## 8. 实施顺序、候选构建与唯一一次提交

### 8.1 实施顺序

按 **功能一 → 功能三 → 功能二** 的顺序开发。三项全部实现、自动化 Gate A/B 全绿后，才构建**唯一最终候选**交给用户做权威手测。

中间开发包（**可选**，仅用于开发自测/冒烟，**不构成验收，不提交，不要求用户三端手测**）：

| 阶段 | 开发 buildStamp | 开发 versionCode | 用途 |
|---|---|---|---|
| 功能一完成 | `1.0.2-opt8` | `1.0.2+2010` | 开发自测、快速冒烟 |
| 功能三完成 | `1.0.2-opt9` | `1.0.2+2011` | 开发自测、快速冒烟 |
| 功能二完成 | `1.0.2-opt10` | `1.0.2+2012` | 开发自测、快速冒烟 |

这些开发包可以不构建；如果要装到手机上试玩，也不计入验收。最终验收只认 8.2 的合并候选。

### 8.2 最终候选（权威手测 + 唯一一次 commit 的对象）

定稿：

- `pubspec.yaml`：`version: 1.1.0+2013`
- `AppConfig.buildStamp`：`1.1.0`
- 三端从**同一棵工作树**构建，记录 `git rev-parse HEAD`、候选指纹（§9.3 命令）、buildStamp、versionCode。
- 用户只对这一版做最终三端手测；通过并明确说“可以提交”后，将这棵工作树原样提交为**一次 commit**。
- 若手测前修改任何文件（包括格式化、注释、buildStamp、文档），该候选作废，重新构建、重新手测。
- 若手测发现缺陷：修复、重跑 Gate A/B、递增 versionCode（如 `1.1.0+2014`）、重新构建三端、重新完整手测；仍然只有最后通过的那一次 commit。

### 8.3 为什么不再分三次提交

- 用户要求整个批次**有且只有一次 commit**；
- 三项共享 `call_screen.dart`、`chat_screen.dart`、`android_system.dart`、`capabilities.dart`、`MainActivity.kt`、`CallForegroundService.kt`、`linux/runner/my_application.cc` 与 Manifest，分开提交容易出现“中间 commit 从未经过完整手测”的不可回滚点；
- 单次 commit + 单次最终候选，保证**测试对象 = 提交对象**。

### 8.4 版本号规则

- 开发包用 `opt8/opt9/opt10`，versionCode 2010/2011/2012，仅用于自测，不提交。
- 最终候选固定 `versionName 1.1.0`，versionCode 从 2013 起；每次重出包 +1。
- `buildStamp` 最终候选为 `1.1.0`；`test/services/windows_storage_stage_q2_test.dart` 的正则接受语义版本，不需要改测试。
- 不要用未登记的新前缀（如 `call1`），除非同步修改契约正则。
- `versionCode` 必须单调递增，避免 `INSTALL_FAILED_VERSION_DOWNGRADE`（opt1 真机踩过）。

---

## 9. 版本控制与提交纪律（硬规则）

### 9.1 只允许在 `dart` 分支开发

- 主工作区：`/home/fengyang/PycharmProjects/chatroom`，分支 `dart`。
- 不要用 `chatroom-q1-android` / `chatroom-q2-windows` / `chatroom-q3-macos` 三个 worktree；它们是历史快照，不包含 opt1~opt7。
- 不要在 `master` 开发。GitHub 默认分支是 `master`，但日常开发只落 `dart`；发版里程碑再由用户决定是否同步 `master`。

### 9.2 用户未授权前，禁止一切 Git 写操作

禁止：
- `git add`
- `git commit`
- `git push`
- `git tag`
- `git stash`
- `git reset`
- `git checkout` / `git switch` / `git restore`
- `git clean`
- `git merge` / `git pull` / `git rebase`
- 修改 worktree / 分支 / 引用

允许（只读）：
- `git status`
- `git diff`
- `git diff --stat`
- `git log`
- `git show`
- `git rev-parse`
- `git worktree list`

### 9.3 候选冻结与指纹

在交付手测前，执行并记录（**只读命令，不修改 index**）：

```bash
git rev-parse HEAD
git status -sb
{
  git rev-parse HEAD
  git diff --binary
  git ls-files --others --exclude-standard -z | sort -z | xargs -0 -r sha256sum
} | sha256sum
```

最后一条输出即**候选指纹**，必须同时覆盖：
- 已跟踪文件的修改（`git diff --binary`）；
- 新增但未跟踪的源码/测试/文档（`git ls-files --others` 的逐文件哈希）。

生成指纹前先确认 `git status -sb` 只有本轮文件；临时日志/构建产物/无关文件不要留在工作树，否则会污染指纹或误入提交。

不要用裸 `git diff | sha256sum` 做候选指纹——它**不包含新增未跟踪文件**（本轮会新增 Kotlin 文件、测试文件、文档，漏掉这些文件会导致“手测对象”和“提交对象”不一致）。

同时记录：
- buildStamp
- versionCode / versionName
- 三端构建时间
- 服务端 commit（客户端尚未 commit，记录客户端基线 `git rev-parse HEAD` + 候选指纹即可）

从候选交付到用户说“可以提交”之间，**不得修改任何文件**（包括格式化、注释、buildStamp、文档）。如果必须改，该候选作废，重新构建、重新手测。

### 9.4 触发词

| 用户说的话 | 执行 Agent 的动作 |
|---|---|
| “测试通过 / 没问题” | 只汇总候选指纹、改动清单、测试结果；**不提交**，等待明确提交指令 |
| “可以提交” | 整个批次只做**一次**本地 `git add` + `git commit`；**不 push**；不拆成多个 commit |
| “可以推送” | 只 `git push origin dart`，不再 commit |
| “提交并推送” | 做唯一一次本地 commit，然后 `git push origin dart` |
| “可以打 tag” | 创建 tag 并 `git push origin <tag>` |
| 用户未说话 | 什么都不做 |

> 如果用户明确说“以后‘测试通过’就等于可以提交”，再按该解释执行；默认按上表严格版本。

### 9.5 提交粒度：整个批次只有一次 commit

- 三个功能 + 所有测试 + 所有文档（`TESTING_GUIDE.md §37`、`TESTING_GUIDE_FLUTTER.md §21.36`、`opt8_验证步骤清单.md`、`AGENTS.md` 维护注意、本任务书）**合并为一次 commit**。
- 中间过程不产生任何 commit；开发阶段只保留未提交的工作树。
- commit message 建议：

```text
opt8 通话体验增强：上下栏收起 + 后台来电（Android 系统通知/桌面唤起）+ Android 通话悬浮球（用户三端手测通过）
```

- 不要为了“方便回滚”拆成多个 commit；用户明确要求有且只有一次提交。
- 如果用户后续改变主意要求拆分，必须重新获得明确授权，不能自行拆分或改写历史。
- 不要在 commit 后自动 push；push 仍需单独授权。
- 不要在 commit 后自动打 tag；tag 仍需单独授权。

### 9.6 授权后的命令模板

本地 commit（整个批次唯一一次）：

```bash
cd /home/fengyang/PycharmProjects/chatroom
git status -sb
git diff --stat
# 确认工作区只有本轮文件；若有无关文件，逐项 add，不要盲目 -A
git add <本轮代码/测试/文档文件，包含本任务书>
git commit -m "opt8 通话体验增强：上下栏收起 + 后台来电（Android 系统通知/桌面唤起）+ Android 通话悬浮球（用户三端手测通过）"
```

提交后立即 `git show --stat HEAD` 确认只产生了一个 commit，并核对文件清单与候选 `git status` 一致；`git status -sb` 应为 clean（忽略文件除外）。然后停下；不要自动 push。

推送（必须再次获得授权）：

```bash
git push origin dart
```

打 tag（必须再次获得授权）：

```bash
git tag -a v1.1.0 -m "v1.1.0 通话体验增强"
git push origin v1.1.0
```

禁止 `--force` / `--force-with-lease`，除非用户明确要求。

---

## 10. 自动化测试计划

### 10.1 三层门禁

| 层 | 内容 | 通过标准 |
|---|---|---|
| Gate A 单功能 | 该功能新测试 + 相关存量测试 | 新增测试全绿、`dart analyze` 零问题、无既有测试回归 |
| Gate B 批次 | 全量 Flutter + Python + E2E | 连续两轮全量绿（同一候选指纹，§9.3 命令、中间无代码改动）+ E2E 两轮绿；Gate B 通过后再构建三端候选 |
| Gate C 三端手测 | 按 `TESTING_GUIDE.md §37` 执行 | 全部用例通过；失败项修复后重走 Gate B + 重新构建三端并重测 |

### 10.2 每轮固定命令

```bash
cd /home/fengyang/PycharmProjects/chatroom/chatroom_flutter

dart analyze lib test integration_test

# 新功能定向测试（开发期反复跑）
flutter test test/screens/call_screen_chrome_opt8_test.dart
flutter test test/screens/chat_screen_call_lifecycle_opt8_test.dart
flutter test test/services/call_intent_opt8_test.dart
flutter test test/services/call_notification_policy_opt8_test.dart
flutter test test/services/call_bubble_policy_opt8_test.dart
flutter test test/services/call_native_contract_opt8_test.dart
flutter test test/services/window_activation_opt8_test.dart

# Android 设备端最小集成（可选，连接真机后）
flutter test integration_test/call_ui_device_test.dart -d <device>

# 全量（Gate B，连续两轮）
flutter test > /tmp/opt8_full_1.log 2>&1
flutter test > /tmp/opt8_full_2.log 2>&1

# 真实服务端 E2E（单独跑，避免并行负载）
flutter test --concurrency=1 test/services/call_signal_e2e_test.dart \
  > /tmp/opt8_call_e2e.log 2>&1
flutter test --concurrency=1 test/services/group_call_signal_e2e_test.dart \
  > /tmp/opt8_group_call_e2e.log 2>&1

# Python 全量
cd /home/fengyang/PycharmProjects/chatroom
./run_tests.sh --all
```

E2E 前提：
- 仓库根 `.venv` 可用；
- `SSL/` 证书齐全；
- 端口 8099/8100 未被占用；
- 输出重定向到文件（管道消费可能导致偶发 pacing 失败）；
- 先清理残留测试服务端进程，不要误杀开发服务器 8090。

### 10.3 多轮确认标准

> Gate B 只在三项合并后的最终候选上执行；单个功能阶段只需 Gate A + 定向测试多次绿，不必每个功能都跑两轮全量。

- 第 1 轮：测试先行（TDD 红）→ 实现 → 定向测试绿。
- 第 2 轮：全量 Flutter + Python + 两条通话 E2E；修掉偶发/时序问题。
- 第 3 轮：同一工作树（同一候选指纹，§9.3 命令）再跑一次全量，必须连续两轮零失败；然后构建三端。
- 手测后每个缺陷：补回归测试 → 修复 → 重走第 2/3 轮 → 递增 versionCode → 重新出三端 → 重测失败项 + 相关回归。
- 时序敏感测试用循环跑 3 次：

```bash
for i in 1 2 3; do
  flutter test test/screens/call_screen_chrome_opt8_test.dart || break
done
```

### 10.4 测试替身与写法

| 场景 | 做法 |
|---|---|
| ChatScreen 测试 | `MockSocketService`（mocktail），stub `callService` getter 返回真实 `CallService`；stub setter 捕获 `onCallPhaseChanged`，手动触发 |
| CallService 测试 | FakeEngine + FakeSignaling（参考 `call_screen_stage_r_test.dart`） |
| 平台模拟 | `debugDefaultTargetPlatformOverride = TargetPlatform.android`；在 test body 内 try/finally 恢复 null |
| MethodChannel | `TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(platformChannel, ...)` |
| 生命周期 | `tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused/resumed)`；tearDown 恢复 `resumed` |
| 源码扫描 | `File('lib/…')` / `File('android/…')` / `File('linux/…')` 读取（flutter test CWD 即包根），断言关键符号存在 |
| 动画测试 | `pump(Duration(milliseconds: 200))`，不要 `pumpAndSettle`（active 通话有 1s ticker） |

### 10.5 自动化覆盖不到的（必须手测）

- 系统通知实际展示、heads-up/锁屏全屏形态；
- 悬浮球在桌面/其他 App 上层的真实表现、ROM 额外权限；
- Android 14+ 全屏通知特殊权限；
- 真实音视频在退后台/锁屏/悬浮球返回后的连续性；
- 进程被 ROM 冻结/杀掉；
- 三端 UI 观感、误触、拖动跟手、机型差异。

---

## 11. 三端手动测试总则

> 本轮只对**最终合并候选**做一次完整三端手测。中间开发包只做开发自测/冒烟，不要求用户手测；最终候选通过后才有唯一一次 commit。
> 三端手测含义：功能一在 Android/Linux/Windows 全测；功能二在 Android 主测，Linux/Windows 做回归（确认无悬浮球、无 Android 通知副作用、通话/最小化正常）；功能三在 Android 测系统通知/full-screen intent，在 Linux/Windows 测桌面唤起（窗口恢复/置前，失败时任务栏提醒）。

### 11.1 通用准备

| 项 | 要求 |
|---|---|
| 服务端 | 与客户端同一候选基线（服务端 commit + 客户端候选指纹 §9.3）；`0.0.0.0:8090`；SSL 证书齐全；防火墙放行；不要与 E2E 的 8099/8100 冲突 |
| 账号 | `alice`（PC 主叫）、`bob`（Android 被叫）、`carol`（群聊第三端）；互为好友；建一个测试群 |
| 三端产物 | 同一候选指纹（§9.3）、同一 `buildStamp`、同一 `versionCode`；Android APK、Linux bundle、Windows Release |
| Android 权限 | 通知权限已授予；悬浮窗权限已授予；Android 14+ 全屏通知权限已授予；电池优化白名单；vivo/三星自启动/后台弹窗允许 |
| 网络 | 同一局域网；三端构建时 `--dart-define=CHATROOM_SERVER_HOST=<局域网IP>`；或 `adb reverse tcp:8090 tcp:8090` + `127.0.0.1` |
| 记录 | 日期、基线 `git rev-parse HEAD`、候选指纹（§9.3）、buildStamp/versionCode、设备型号/系统、结果、截图/录屏/logcat |

### 11.2 构建命令

```bash
cd /home/fengyang/PycharmProjects/chatroom/chatroom_flutter

flutter build apk --release --target-platform android-arm64 \
  --dart-define=CHATROOM_SERVER_HOST=192.168.x.x

flutter build linux --release \
  --dart-define=CHATROOM_SERVER_HOST=192.168.x.x

# Windows 按 TESTING_GUIDE.md §36.9.0 远程流程，同一候选工作树、同一 dart-define
```

安装/运行：

```bash
# Android（vivo/三星可能弹安装确认，需人在设备旁）
adb install -r build/app/outputs/flutter-apk/app-release.apk
# vivo PackageIntercept 约 40 秒无人点击会自动拒绝并回滚；同一字节重装通常静默

# Linux：运行 release bundle 内的可执行文件
# Windows：按 §36.9.0 用计划任务进入交互桌面后运行 Release exe
```

安装后核对：
- 登录页页脚 buildStamp；
- `adb shell dumpsys package com.example.chatroom_flutter | grep versionCode`；
- 三端登录的是同一服务端 commit。

### 11.3 证据采集

```bash
adb exec-out screencap -p > /tmp/opt8_<case>.png
adb logcat -d -b crash > /tmp/opt8_crash.log
adb logcat -d -s flutter:V CallForegroundService:V > /tmp/opt8_logcat.log
adb shell dumpsys notification --noredact > /tmp/opt8_notification.txt
adb shell dumpsys activity services com.example.chatroom_flutter > /tmp/opt8_services.txt
adb shell appops get com.example.chatroom_flutter SYSTEM_ALERT_WINDOW
```

### 11.4 结果记录模板

```markdown
### 执行记录
- 日期：
- 基线 commit（`git rev-parse HEAD`）：
- 候选指纹（§9.3 命令）：
- buildStamp / versionCode：
- 服务端 commit：
- 设备：Android（型号/系统）/ Linux（发行版）/ Windows（版本）
- 结果：功能一 __/15；功能二 __/18；功能三 __/19
- 失败项与证据：
- 已知限制/待跟进：
```

### 11.5 三端回归表

| 平台 | 回归项 |
|---|---|
| Android | 登录/收发消息/文件、前后台切换、通知权限、FGS 通知、最小化悬浮条、1:1 与群通话、来电/去电、媒体路由 |
| Linux | 登录/中文输入、收发消息/文件、1:1 与群通话、最小化/恢复、来电桌面唤起（窗口恢复/置前，失败时 urgency）、无 Android 专属通知副作用 |
| Windows | 登录/拖拽/文件、1:1 与群通话、最小化/恢复、来电桌面唤起（SW_RESTORE/SetForegroundWindow，失败时 FlashWindowEx）、无 Android 专属通知副作用 |
| 服务端 | 无协议改动；`./run_tests.sh --all` 全绿；无新增端口/配置 |

---

## 12. 文档落点

每个功能在开发过程中就必须同步准备以下内容；最终那一次 commit 必须全部包含：

1. **`TESTING_GUIDE.md` 新增 `## 37. 通话体验增强（opt8）`**
   - `37.1` 通用准备与构建
   - `37.2` 功能一：上下栏收起/展开（F1-01~F1-15）
   - `37.3` 功能二：Android 通话悬浮球（F2-01~F2-18）
   - `37.4` 功能三：后台来电弹出（Android 系统通知 + Linux/Windows 桌面唤起，F3-01~F3-19）
   - `37.5` 三端回归与结果记录
   - `37.6` 已知限制与判定口径
   - 表格格式仿 `TESTING_GUIDE.md §36.7/§36.10`：`# | 平台 | 操作 | 预期`。

2. **`TESTING_GUIDE_FLUTTER.md` 新增 `### 21.36 opt8 通话体验增强测试规约`**
   - 按 §21.35 格式列出：测试文件 → 用例 → 预期；包含 `window_activation_opt8_test.dart`。
   - 写明测试替身、平台 override、生命周期恢复、源码扫描（含 Linux runner `chatroom_bring_to_front` 与 Windows FFI）。
   - 写明“原生通知/悬浮窗/全屏 Intent 不做 flutter test，归设备端 integration_test + 手动矩阵”。

3. **根目录 `opt8_验证步骤清单.md`**
   - 仿 `opt1_验证步骤清单.md`，面向最终手测。
   - 标题、构建标识、每项操作步骤/预期/反馈栏。
   - 包含功能一/二/三和三端回归；功能三必须含 Linux/Windows 桌面唤起（F3-18/F3-19）。
   - 末尾放“执行记录”模板。

4. **`AGENTS.md` 维护注意**
   - 新增 opt8 小节，记录：
     - 上下栏收起的 `IgnorePointer`/key 契约；
     - 来电通知渠道 id、full-screen intent、action/锁屏标志清理；
     - 桌面来电唤起（Linux `chatroom_bring_to_front` / Windows FFI、ringing 门控、抢焦点失败兜底）；
     - 悬浮球 overlay 权限/服务清理；
     - 提交纪律（手测后才提交）；
     - 已知限制（进程被杀无推送、Android 14 全屏权限、两条通知、拒绝按钮拉前台）。

---

## 13. 构建与候选交付清单

交给用户手测前，执行 Agent 必须提供：

- [ ] `git rev-parse HEAD`
- [ ] 候选指纹（§9.3 命令）
- [ ] `git status -sb`
- [ ] buildStamp / versionCode / versionName
- [ ] 三端产物路径：
  - Android APK
  - Linux bundle 目录
  - Windows exe/zip（按 §36.9.0 流程）
- [ ] 服务端 commit 与服务端启动命令
- [ ] 测试账号/群组信息
- [ ] 自动化测试结果：
  - `dart analyze` 结果
  - 新功能定向测试结果
  - 全量 Flutter 两轮结果
  - Python 全量结果
  - 两条 E2E 结果
- [ ] 手动测试指南文件路径和本次要执行的用例编号
- [ ] 已知限制/未覆盖项

**不要**在候选交付时执行任何 git 写操作。

---

## 14. 验收标准（Definition of Done）

### 14.1 每个功能（Gate A）

- 代码实现符合本文行为契约。
- 新增自动化测试全绿，存量相关测试无回归。
- `dart analyze lib test integration_test` 零问题。
- `TESTING_GUIDE.md` / `TESTING_GUIDE_FLUTTER.md` / `opt8_验证步骤清单.md` 对应内容已写。
- 注意：单个功能完成不等于可以提交；整个批次只在最终候选手测通过、用户明确授权后提交一次。

### 14.2 批次（Gate B + Gate C）

- 三个功能全部完成。
- 连续两轮全量 Flutter 绿 + Python 全量绿 + 两条 E2E 两轮绿。
- Android/Linux/Windows 三端从同一棵工作树构建通过，同一 buildStamp/versionCode。
- 最终合并候选在三端手动测试通过（功能一全三端；功能二 Android 主测 + Linux/Windows 回归；功能三 Android 系统通知 + Linux/Windows 桌面唤起全测）；已知限制已记录。
- 用户明确授权后，整个批次只产生**一次本地 commit**；push/tag 另行授权，不能自动执行。

---

## 15. 已知限制（手测时按“预期”记录，不算缺陷）

1. **进程被杀/force-stop/ROM 深度冻结后收不到来电**：侧载应用无 FCM/厂商推送，客户端代码无法解决。
2. **Android 14+ 全屏通知权限**：可能默认未授予；此时来电仍应有 heads-up，用户可在设置中开启全屏通知。
3. **部分国产 ROM 需要额外权限**：vivo/三星的“悬浮窗”“后台弹出界面”“自启动”“锁屏显示”可能需要手动开启。
4. **振铃期两条通知**：来电通知 + 静默“Rosub 通话中” FGS 通知并存；vivo 可能聚合成组。
5. **通知“拒绝”会短暂打开 App**：v1 已由用户接受；完全后台拒绝留到二期。
6. **后台来电在解锁状态下可能是 heads-up 而非全屏**：Android 标准行为；部分 ROM 会全屏。若要求任何界面强制全屏，需要额外 overlay 方案，不在本轮。
7. **悬浮球依赖 `SYSTEM_ALERT_WINDOW`**：权限被拒/被撤销时功能降级为通知入口，不影响通话。
8. **桌面端来电只做“恢复窗口 + 置前/任务栏提醒”**：Linux `gtk_window_present` 在部分 Wayland 合成器会被焦点窃取防护拦截；Windows `SetForegroundWindow` 可能被前台锁拒绝；此时分别回退 GTK urgency / `FlashWindowEx`。不做桌面全屏覆盖，也不保证在所有窗口管理器/工作区下都能强制抢到焦点。
9. **两条通知/悬浮球同时存在**：通话中退后台时，FGS“通话中”通知与悬浮球并存属预期。
10. **Windows 构建需走 §36.9.0 远程流程**：Windows 机是 tar 快照，不能直接提交；构建产物必须来自同一候选工作树。
11. **来电不主动震动**：用户决策本轮只保证铃声；应用不新增原生震动循环，是否震动由系统通知设置/ROM 决定。

---

## 16. 常见坑与排查顺序

| 现象 | 优先检查 |
|---|---|
| 后台来电只有铃声没有通知 | `POST_NOTIFICATIONS` 是否授予；`showIncomingCallNotification` 是否被调用；通道 importance 是否 HIGH；Dart 是否认为 `_appResumed == true` |
| 锁屏不显示全屏 | `USE_FULL_SCREEN_INTENT` 是否声明；Android 14+ `canUseFullScreenIntent()`；ROM 锁屏显示/悬浮通知开关；`setFullScreenIntent` 是否设置 |
| 点通知不接听 | `pendingCallAction` 是否写入；`consumeCallIntent` 是否被消费；`resumed` 是否触发；`phase` 是否仍 ringing |
| 接听无媒体 | 麦克风/摄像头权限；`requestCallPermissions`；FGS 是否启动；`bypassVoiceProcessing` 顺序 |
| 悬浮球不出现 | `SYSTEM_ALERT_WINDOW` 权限；`Settings.canDrawOverlays`；`showCallBubble` 是否调用；服务是否运行；`TYPE_APPLICATION_OVERLAY` |
| 悬浮球点回只到会话列表 | `open_call` extra；`_handleCallIntent` 是否 restore；`svc.minimized` 是否为 true |
| 球残留 | `hideCallBubble` 是否在 ended/idle 调用；`onDestroy`/`onTaskRemoved` 是否移除 View |
| 桌面最小化来电不置前 | Linux：`chatroom_bring_to_front` 是否导出（`-Wl,--export-dynamic`）、`g_idle_add`/`gtk_window_present`、Wayland 焦点窃取防护；Windows：`FindWindowW` 类名、`ShowWindow(SW_RESTORE)`、`SetForegroundWindow` 前台锁、`FlashWindowEx` 兜底；`ChatScreen` 是否满足 `ringing + desktop` |
| 上下栏隐藏后误触挂断 | 是否漏了 `IgnorePointer`；按钮是否在隐藏层仍可命中 |
| 测试出现 `TypeError` | MockSocketService 未 stub `callService` getter；build 直读 getter；改用快照/try-catch |
| 测试 `pumpAndSettle` 超时 | active 通话 `_ticker` 每秒 setState；改用 `pump(Duration)` |
| 通知渠道崩溃 | FGS 运行中 `deleteNotificationChannel`；移到 MainActivity 启动路径 |
| 安装报 VERSION_DOWNGRADE | `versionCode` 未递增；pubspec 必须带 `+NNNN` |
| 三端日志/构建对不上 | 先核对登录页 buildStamp、`git rev-parse HEAD`、服务端 commit |

---

## 17. 给执行 Agent 的开工检查表

- [ ] 已读 `AGENTS.md` 和本文。
- [ ] `pwd` = `/home/fengyang/PycharmProjects/chatroom`。
- [ ] `git status -sb` 显示 `## dart`；除本任务书（untracked）外无未提交改动。
- [ ] 没有切换到 q1/q2/q3 worktree。
- [ ] 已理解“用户明确授权前不执行任何 Git 写操作”。
- [ ] 已理解“中间开发包不要求用户手测；只对最终合并候选做一次完整三端手测”。
- [ ] 已理解“整个批次最终只有一次 commit，不拆成多个 commit”。
- [ ] 已理解“功能三桌面唤起：Linux runner 需导出 `chatroom_bring_to_front`，Windows 用 user32 FFI；只在 `ringing + Linux/Windows` 调用”。
- [ ] 已理解“候选构建后不得改文件，否则手测作废”。
- [ ] 已准备按功能一 → 功能三 → 功能二顺序实施。
- [ ] 已准备每个功能同时交付代码、自动化测试、`TESTING_GUIDE.md §37`、`opt8_验证步骤清单.md`。
- [ ] 已准备在交付手测时提供候选指纹、buildStamp、三端产物路径、自动化结果。

---

## 18. 需求原文（供对照）

> - 点击通话界面上下栏目缩回，再点击一次后重新弹出
> - 设置一个快速返回悬浮球，安卓用户（即移动端用户）在音视频通话中退出 Rosub 后回到主界面或者桌面后点击后能直接回到音视频通话界面（类似于微信）
> - 收到音视频通话来电直接在当前窗口弹出（类似于微信），现在用户只能在打开 Rosub 后才能收到来电，这完全不能正常使用

---

## 19. 结论

三项功能都可以在客户端内完成，服务端与协议零改动。实施顺序建议：

1. **功能一**：纯 Flutter，风险最低，先建立测试节奏。
2. **功能三**：后台来电是可用性刚需；Android 原生通知 + 生命周期接线，Linux/Windows 窗口唤起；最需要真机验证。
3. **功能二**：悬浮球依赖系统特殊权限，ROM 适配最费时间，放最后。

每个功能在开发阶段必须经过：

```text
TDD 契约 → 定向测试绿（Gate A）
```

三项全部完成后，最终合并候选再经过：

```text
全量 Flutter 两轮 + Python 全量 + E2E 两轮（Gate B）
→ 三端候选构建 → 用户完整三端手测（Gate C）
→ 用户明确“可以提交” → 整个批次唯一一次本地 commit
→ 用户明确“可以推送” → push origin dart
```

**自动化全绿不等于可以提交；只有用户在最终合并候选上手动测试确认并明确声明后，才能提交，而且整个批次只有一次 commit。**
