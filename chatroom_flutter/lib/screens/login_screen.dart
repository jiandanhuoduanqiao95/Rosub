/// 登录/注册界面（fcitx 兼容版）
///
/// 关键：移除 SingleChildScrollView、readOnly 延迟切换、
/// SizedBox 包裹等可能触发 Linux fcitx IME 死锁的元素。

import 'package:flutter/material.dart';

import '../config.dart';
import '../widgets/raw_text_field.dart';
import '../models/chat_models.dart';
import '../services/socket_service.dart';
import 'chat_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _socketService = SocketService();
  final _usernameFocus = FocusNode();

  bool _isLogin = true;
  bool _loading = false;
  String? _error;

  /// 在下一帧请求用户名输入框焦点，确保 rebuild 已完成
  void _refocusUsername() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _usernameFocus.context != null) {
        _usernameFocus.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _usernameFocus.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final username = _usernameCtrl.text.trim();
    final password = _passwordCtrl.text;

    final userValid = InputValidator.validateUsername(username);
    if (!userValid.valid) {
      setState(() => _error = userValid.error);
      _refocusUsername();
      return;
    }
    final passValid = InputValidator.validatePassword(password);
    if (!passValid.valid) {
      setState(() => _error = passValid.error);
      _refocusUsername();
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    final connected = await _socketService.connect();
    if (!connected) {
      setState(() {
        _loading = false;
        _error = '无法连接到服务器 ${AppConfig.serverHost}:${AppConfig.serverPort}';
      });
      _refocusUsername();
      return;
    }

    final String? result;
    if (_isLogin) {
      result = await _socketService.login(username, password);
    } else {
      result = await _socketService.register(username, password);
    }

    if (!mounted) return;

    if (result != null) {
      setState(() {
        _loading = false;
        _error = result;
      });
      _refocusUsername();
      _socketService.disconnect();
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ChatScreen(socketService: _socketService),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SizedBox(
          width: 400,
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 标题
                Icon(
                  Icons.chat_bubble_rounded,
                  size: 64,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 8),
                Text(
                  '聊天室',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  _isLogin ? '登录' : '注册新账号',
                  textAlign: TextAlign.center,
                  style:
                      Theme.of(context).textTheme.bodyLarge?.copyWith(color: Colors.grey),
                ),
                const SizedBox(height: 24),

                // 用户名
                RawTextField(
                  key: const ValueKey('username_field'),
                  controller: _usernameCtrl,
                  focusNode: _usernameFocus,
                  hintText: '用户名（3-32位字母,数字,下划线,短横线）',
                ),

                const SizedBox(height: 16),

                // 密码
                RawTextField(
                  key: const ValueKey('password_field'),
                  controller: _passwordCtrl,
                  hintText: '密码（至少6个字符）',
                  obscureText: true,
                  showVisibilityToggle: true,
                  onSubmitted: (_) => _submit(),
                ),

                const SizedBox(height: 16),

                // 错误提示
                if (_error != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.red.shade200),
                    ),
                    child: Text(_error!, style: TextStyle(color: Colors.red.shade700)),
                  ),

                const SizedBox(height: 16),

                // 按钮
                SizedBox(
                  height: 48,
                  child: FilledButton(
                    onPressed: _loading ? null : _submit,
                    child: _loading
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(_isLogin ? '登录' : '注册'),
                  ),
                ),

                const SizedBox(height: 12),

                TextButton(
                  onPressed: _loading
                      ? null
                      : () => setState(() {
                            _isLogin = !_isLogin;
                            _error = null;
                          }),
                  child: Text(_isLogin ? '没有账号？注册' : '已有账号？登录'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
