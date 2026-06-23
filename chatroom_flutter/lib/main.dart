/// 聊天室 Flutter 桌面客户端 —— 入口
///
/// 应用从 LoginScreen 开始，登录成功后进入 ChatScreen。
/// 全局状态由 AppState(ChangeNotifier 单例)管理。

import 'package:flutter/material.dart';

import 'screens/login_screen.dart';
import 'services/ime_bridge.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ChatroomApp());
}

class ChatroomApp extends StatefulWidget {
  const ChatroomApp({super.key});

  @override
  State<ChatroomApp> createState() => _ChatroomAppState();
}

class _ChatroomAppState extends State<ChatroomApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      // 应用即将退出，清理 IME 桥接进程，避免窗口残留
      ImeBridgeManager.instance.shutdown();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '聊天室',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF1976D2),
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF1976D2),
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      themeMode: ThemeMode.system,
      home: const LoginScreen(),
      routes: {
        '/login': (_) => const LoginScreen(),
      },
    );
  }
}
