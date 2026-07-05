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
  final _adminSecretCtrl = TextEditingController();
  final _socketService = SocketService();
  final _usernameFocus = FocusNode();

  bool _isLogin = true;
  bool _adminMode = false;
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
    _adminSecretCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final username = _usernameCtrl.text.trim();
    final password = _passwordCtrl.text;
    final adminSecret = _adminSecretCtrl.text.trim();

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
    if (_adminMode && adminSecret.isEmpty) {
      setState(() => _error = '管理员模式需要填写管理员密钥');
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
      result = await _socketService.login(
        username,
        password,
        adminSecret: _adminMode ? adminSecret : null,
      );
    } else {
      result = await _socketService.register(
        username,
        password,
        adminSecret: _adminMode ? adminSecret : null,
      );
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
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              colorScheme.primaryContainer.withValues(alpha: 0.65),
              colorScheme.surface,
              colorScheme.secondaryContainer.withValues(alpha: 0.45),
            ],
          ),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Card(
              elevation: 0,
              color: colorScheme.surface.withValues(alpha: 0.92),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: BorderSide(color: colorScheme.outlineVariant),
              ),
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
                      color: colorScheme.primary,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '聊天室',
                      textAlign: TextAlign.center,
                      style:
                          Theme.of(context).textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _isLogin ? '登录' : '注册新账号',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
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

                    const SizedBox(height: 12),

                    SwitchListTile(
                      value: _adminMode,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('管理员模式'),
                      subtitle: Text(
                        _isLogin ? '管理员登录需要二次密钥' : '使用密钥注册管理员账号',
                      ),
                      onChanged: _loading
                          ? null
                          : (value) => setState(() {
                                _adminMode = value;
                                _error = null;
                                if (!value) _adminSecretCtrl.clear();
                              }),
                    ),

                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: _adminMode
                          ? Padding(
                              key: const ValueKey('admin_secret_field_wrap'),
                              padding: const EdgeInsets.only(top: 4),
                              child: RawTextField(
                                key: const ValueKey('admin_secret_field'),
                                controller: _adminSecretCtrl,
                                hintText: '管理员密钥',
                                obscureText: true,
                                showVisibilityToggle: true,
                                onSubmitted: (_) => _submit(),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),

                    const SizedBox(height: 16),

                    // 错误提示
                    if (_error != null)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.red.shade200),
                        ),
                        child: Text(_error!,
                            style: TextStyle(color: Colors.red.shade700)),
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
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
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
                                _adminSecretCtrl.clear();
                              }),
                      child: Text(_isLogin ? '没有账号？注册' : '已有账号？登录'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
