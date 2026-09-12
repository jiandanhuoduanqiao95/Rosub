/// 聊天室 Flutter 桌面客户端 —— 入口
///
/// 应用从 LoginScreen 开始，登录成功后进入 ChatScreen。
/// 全局状态由 AppState(ChangeNotifier 单例)管理。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:media_kit/media_kit.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show NativeLogsListener, WebRTC;

import 'dev/webrtc_spike.dart';
import 'screens/login_screen.dart';
import 'services/app_paths.dart';
import 'services/focus_tracker.dart';
import 'services/ime_bridge.dart';
import 'services/message_cache.dart';
import 'services/sent_file_store.dart';
import 'services/session_lifecycle.dart';
import 'services/sticker_store.dart';
import 'services/taskbar_notifier.dart';
import 'services/theme_settings.dart';
import 'platform/android_system.dart';

import 'config.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 阶段 R1 Spike：环境变量门控的平台可用性验证（不进正常应用流程）
  if (const bool.fromEnvironment('dart.vm.product') == false &&
      Platform.environment['CHATROOM_WEBRTC_SPIKE'] == '1') {
    runApp(const WebrtcSpikeApp());
    return;
  }
  // R-P27（用户复测"表情黑白"轮换出现）：构建标识打印到启动日志——
  // 多客户端排查"谁在跑旧构建"时与登录页页脚互为印证；旧构建同时呈现
  // 黑白表情 + media_kit non-platform thread ERROR
  // ignore: avoid_print
  print('[chatroom] build: ${AppConfig.buildStamp}');
  // 阶段 Q0-4：解析平台存储目录（Linux 兼容既有 CWD 相对路径；
  // 其余平台走 path_provider 文档目录）——先于任何落盘调用
  await AppPaths.ensureInitialized();
  // Q1 五轮（问题2）：已发送文件路径映射预载（文件管理页同步回看）
  await SentFileStore.init();
  // 阶段 L3（P0-4）：初始化本地消息缓存（启动秒开 + 离线可读）；失败不阻塞启动
  MessageCache.init().then((_) {}, onError: (_) {});
  // R-P8（视频画面黑屏修复）：media_kit 要求在 runApp 前完成初始化
  // （官方约定）；缺失 libmpv 环境不阻塞启动（查看器回退系统播放器）
  try {
    MediaKit.ensureInitialized();
  } catch (_) {}
  // R1 真机六轮（r1s8→r1s9 修正生效顺序）：vivo OriginOS 上默认
  // VOICE_COMMUNICATION 音频源 + 硬件 AEC/NS 采到纯底噪（REC level 0——
  // 电脑端听不到手机的根因）。bypassVoiceProcessing 改用 MIC 源并关闭
  // 硬件语音处理（软件 APM 兜底）。r1s8 未生效原因：必须先于任何
  // WebRTC.invokeMethod（setLogger 会先触发无参 initialize 并置位
  // initialized 标志，后续带参 initialize 被跳过）。
  if (Platform.isAndroid) {
    try {
      await WebRTC.initialize(options: {'bypassVoiceProcessing': true});
    } catch (_) {}
  }
  // R1 真机排障（r1s6，定位后移除）：转发 libwebrtc 原生日志到控制台/
  // logcat——默认 LS_NONE 会吞掉 native 层 FATAL CHECK 文本（Android
  // network_thread SIGABRT 的唯一现场证据）；info 级覆盖全部 fatal/error
  if (Platform.isAndroid || Platform.isLinux) {
    NativeLogsListener.instance
        .setLogger(Logger(printer: SimplePrinter(printTime: false)), 'info');
  }
  // R-P11（贴纸添加无反应修复）：生产入口注入贴纸落盘目录
  // （未 init 时 addSticker/stickerBytes 静默返回 null——根因）。
  // Q0-4：目录改由 AppPaths 按平台解析
  StickerStore.instance.init(baseDir: AppPaths.stickerStoreDir);
  runApp(const ChatroomApp());
}

class ChatroomApp extends StatefulWidget {
  const ChatroomApp({super.key});

  @override
  State<ChatroomApp> createState() => _ChatroomAppState();
}

class _ChatroomAppState extends State<ChatroomApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 窗口重新聚焦时清除任务栏闪烁（类微信：点击窗口后停止闪烁）
    FocusTracker.instance.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    FocusTracker.instance.removeListener(_onFocusChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onFocusChanged() {
    if (FocusTracker.instance.focused) {
      TaskbarNotifier.clearUrgency();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      // 应用即将退出，清理 IME 桥接进程，避免窗口残留
      ImeBridgeManager.instance.shutdown();
    }
    if (state == AppLifecycleState.paused) {
      // Q1 五轮（问题1）：真后台暂停透传——SocketService 记录暂停
      // 时刻，回前台探测据此把"冻结打断的文件接收"判死重连
      SessionLifecycleGuard.instance.handlePaused();
    }
    if (state == AppLifecycleState.resumed) {
      // 阶段 Q0-5：回前台校验 socket 存活并重连——paused（退后台）
      // 下断开属预期，恢复后走既有重连 + 离线补发链路；桌面最小化
      // 恢复时 socket 存活，此调用无操作（接线天然无害）
      SessionLifecycleGuard.instance.handleResumed();
      // Q1 真机反馈二轮（问题5）：回前台清除应用外消息通知（已读语义；
      // 仅 Android 生效，其余平台安全 no-op）
      AndroidSystem.cancelMessageNotifications();
    }
    // 窗口焦点检测（阶段 H1）：resumed = 聚焦，inactive/paused = 失焦。
    // 任务栏闪烁（H2）仅在未聚焦时触发。
    FocusTracker.instance.updateFocus(state == AppLifecycleState.resumed);
  }

  @override
  Widget build(BuildContext context) {
    // 阶段 O7（P2-9 字体大小/聊天背景/自定义主题色）：设置集中由
    // ThemeSettings 管理，监听变化即全局重建（默认值即既有渲染）
    final settings = ThemeSettings.instance;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final seedColor = Color(settings.themeColor);
        // mode 为 dark 时 theme 亦使用深色（测试锁定 theme.colorScheme 亮度
        // 与 themeMode 一致）；system/light 下 theme 保持浅色
        final themeBrightness = settings.mode == AppThemeMode.dark
            ? Brightness.dark
            : Brightness.light;
        return MaterialApp(
          title: '聊天室',
          debugShowCheckedModeBanner: false,
          theme: _buildTheme(themeBrightness, seedColor),
          darkTheme: _buildTheme(Brightness.dark, seedColor),
          themeMode: switch (settings.mode) {
            AppThemeMode.system => ThemeMode.system,
            AppThemeMode.light => ThemeMode.light,
            AppThemeMode.dark => ThemeMode.dark,
          },
          // 阶段 O7：全局字体缩放（MediaQuery.textScaler 对全部路由生效）
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(settings.fontScale)),
            child: child!,
          ),
          home: const LoginScreen(),
          routes: {
            '/login': (_) => const LoginScreen(),
          },
        );
      },
    );
  }

  ThemeData _buildTheme(Brightness brightness, Color seedColor) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        clipBehavior: Clip.antiAlias,
        surfaceTintColor: scheme.surfaceTint,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(46),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }
}
