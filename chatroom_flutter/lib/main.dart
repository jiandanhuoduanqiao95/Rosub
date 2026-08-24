/// 聊天室 Flutter 桌面客户端 —— 入口
///
/// 应用从 LoginScreen 开始，登录成功后进入 ChatScreen。
/// 全局状态由 AppState(ChangeNotifier 单例)管理。

import 'package:flutter/material.dart';

import 'screens/login_screen.dart';
import 'services/focus_tracker.dart';
import 'services/ime_bridge.dart';
import 'services/message_cache.dart';
import 'services/taskbar_notifier.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 阶段 L3（P0-4）：初始化本地消息缓存（启动秒开 + 离线可读）；失败不阻塞启动
  MessageCache.init().then((_) {}, onError: (_) {});
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
    // 窗口焦点检测（阶段 H1）：resumed = 聚焦，inactive/paused = 失焦。
    // 任务栏闪烁（H2）仅在未聚焦时触发。
    FocusTracker.instance.updateFocus(state == AppLifecycleState.resumed);
  }

  @override
  Widget build(BuildContext context) {
    const seedColor = Color(0xFF2563EB);
    return MaterialApp(
      title: '聊天室',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(Brightness.light, seedColor),
      darkTheme: _buildTheme(Brightness.dark, seedColor),
      themeMode: ThemeMode.system,
      home: const LoginScreen(),
      routes: {
        '/login': (_) => const LoginScreen(),
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
