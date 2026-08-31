/// 登录/注册界面（fcitx 兼容版）
///
/// 关键：移除 SingleChildScrollView、readOnly 延迟切换、
/// SizedBox 包裹等可能触发 Linux fcitx IME 死锁的元素。

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../config.dart';
import '../widgets/raw_text_field.dart';
import '../models/chat_models.dart';
import '../services/session_store.dart';
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
  // 阶段 O6（P2-10 多账号切换）：已保存的账号列表（钥匙串）
  List<StoredSession> _savedAccounts = [];

  /// 在下一帧请求用户名输入框焦点，确保 rebuild 已完成
  void _refocusUsername() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _usernameFocus.context != null) {
        _usernameFocus.requestFocus();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _initSession();
  }

  /// 读取已保存的 session（H3，记住我）：启动时自动回填用户名/密码，不自动登录。
  /// 阶段 O6：同时读取账号列表（登录页渲染账号条目，点击回填快速切换）。
  /// 安全：管理员密钥不持久化，启动时**不**自动开启管理员模式、不回填密钥，
  /// 需管理员每次手动输入（密钥仅内存中用于重连，退出/重启后即消失）。
  Future<void> _initSession() async {
    final results = await Future.wait([
      SessionStore.load(),
      SessionStore.loadAccounts(),
    ]);
    final session = results[0] as StoredSession?;
    final accounts = results[1] as List<StoredSession>;
    if (!mounted) return;
    setState(() => _savedAccounts = accounts);
    if (session == null) return;
    setState(() {
      _usernameCtrl.text = session.username;
      _passwordCtrl.text = session.password;
      _error = null;
    });
  }

  /// 阶段 O6：点击账号条目 → 回填用户名/密码（不自动登录，H3 语义）
  void _fillAccount(StoredSession account) {
    setState(() {
      _usernameCtrl.text = account.username;
      _passwordCtrl.text = account.password;
      _error = null;
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
      // 登录成功：持久化 session（H3，记住我）并加入账号列表
      // （阶段 O6：saveAccount 按 username upsert + 置为当前，登录页可切换）
      // 安全：管理员密钥不写入 session（不落盘），仅保留在内存中用于断线重连。
      await SessionStore.saveAccount(StoredSession(
        username: username,
        password: password,
      ));
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ChatScreen(socketService: _socketService),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // ---- 登录页专属主题（与用户自定义主题完全隔离）----
    // 登录/注册页使用固定的品牌深色沉浸主题：不受 ThemeSettings（深色模式/
    // 字体缩放/主题色/聊天背景）影响——用户设置登录后在主界面生效，登录页
    // 恒定为品牌形象，观感稳定且与主界面默认品牌蓝自然衔接。
    return Theme(
      data: _loginTheme(),
      child: MediaQuery(
        // 字号排版独立：用户字体缩放不影响登录页
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(1.0)),
        child: Builder(builder: (context) => _buildLoginBody(context)),
      ),
    );
  }

  /// 登录页专属主题：品牌深蓝夜空（Material 3）
  ThemeData _loginTheme() {
    const scheme = ColorScheme.dark(
      primary: Color(0xFF3B82F6),
      onPrimary: Color(0xFFFFFFFF),
      secondary: Color(0xFF38BDF8),
      onSecondary: Color(0xFF0B1220),
      surface: Color(0xFF111C36),
      onSurface: Color(0xFFF1F5F9),
      onSurfaceVariant: Color(0xFF94A3B8),
      surfaceContainerHighest: Color(0xFF0B1428),
      surfaceContainerLow: Color(0xFF0B1428),
      outline: Color(0xFF334155),
      outlineVariant: Color(0xFF24314F),
      error: Color(0xFFFCA5A5),
      onError: Color(0xFF450A0A),
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xFF070D1A),
      appBarTheme: const AppBarTheme(backgroundColor: Colors.transparent),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? const Color(0xFF3B82F6)
                : const Color(0xFF64748B)),
        trackColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? const Color(0xFF3B82F6).withValues(alpha: 0.45)
                : const Color(0xFF24314F)),
      ),
      textTheme: const TextTheme(
        titleLarge: TextStyle(color: Color(0xFFF1F5F9)),
        bodyLarge: TextStyle(color: Color(0xFFF1F5F9)),
        bodyMedium: TextStyle(color: Color(0xFFCBD5E1)),
        bodySmall: TextStyle(color: Color(0xFF94A3B8)),
      ),
    );
  }

  /// 登录页主体：宽屏双栏（品牌展示 + 表单卡片），窄屏单列自适应
  Widget _buildLoginBody(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final xl = width >= 1280; // 三段式：品牌 + 中间插画 + 表单
    final wide = width >= 960; // 双段式：品牌 + 表单
    final form = SizedBox(
      width: wide ? 420 : double.infinity,
      child: _buildFormCard(context),
    );

    final Widget body;
    if (xl) {
      // 三段式（2026-08-31 用户反馈 #2）：左品牌 + 中间对话插画 + 右表单，
      // 填充大屏中部留白
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(flex: 4, child: _buildBrandPane(context)),
          const Expanded(flex: 4, child: _FloatingChatArt()),
          Expanded(
            flex: 4,
            child: Center(
              child: SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                child: form,
              ),
            ),
          ),
        ],
      );
    } else if (wide) {
      body = Row(
        children: [
          Expanded(flex: 5, child: _fadeIn(child: _buildBrandPane(context))),
          Expanded(
            flex: 4,
            child: Center(
              child: SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                child: _fadeIn(child: form),
              ),
            ),
          ),
        ],
      );
    } else {
      body = SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildBrandHeader(context, compact: true),
              const SizedBox(height: 20),
              form,
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: Stack(
        children: [
          // 品牌深蓝夜空渐变背景
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFF070D1A),
                    Color(0xFF0C1631),
                    Color(0xFF0F1D3F)
                  ],
                ),
              ),
            ),
          ),
          // 品牌蓝色光晕（纯绘制装饰，无图片资源）
          Positioned(
            top: -160,
            left: -120,
            child: _glow(const Color(0xFF2563EB), 420, 0.20),
          ),
          Positioned(
            bottom: -180,
            right: -140,
            child: _glow(const Color(0xFF38BDF8), 460, 0.10),
          ),
          // 斜向光带（低调高级感光效）
          Positioned(
            top: -80,
            right: width * 0.28,
            child: IgnorePointer(
              child: Transform.rotate(
                angle: -0.5,
                child: Container(
                  width: 260,
                  height: 900,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        const Color(0xFF60A5FA).withValues(alpha: 0),
                        const Color(0xFF60A5FA).withValues(alpha: 0.06),
                        const Color(0xFF60A5FA).withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(child: body),
        ],
      ),
    );
  }

  /// 入场动效（淡入 + 上移 16px，600ms 一次性——pumpAndSettle 兼容）
  Widget _fadeIn({required Widget child}) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 16 * (1 - t)),
          child: child,
        ),
      ),
      child: child,
    );
  }

  /// 径向光晕装饰
  Widget _glow(Color color, double size, double alpha) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              color.withValues(alpha: alpha),
              color.withValues(alpha: 0)
            ],
          ),
        ),
      ),
    );
  }

  /// 宽屏品牌展示区：产品标识 + 标语 + 特性亮点
  Widget _buildBrandPane(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 72, vertical: 48),
      alignment: Alignment.centerLeft,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _brandMark(size: 72, radius: 22, iconSize: 40),
          const SizedBox(height: 24),
          const Text('聊天室',
              style: TextStyle(
                  fontSize: 40,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFF1F5F9))),
          const SizedBox(height: 10),
          const Text('私有化部署的即时通讯',
              style: TextStyle(fontSize: 18, color: Color(0xFF94A3B8))),
          const SizedBox(height: 40),
          ...[
            (Icons.forum_rounded, '实时群聊', '群组消息与文件，即发即达'),
            (Icons.cloud_off_outlined, '离线暂存', '离线消息与公告，上线即同步'),
            (Icons.verified_user_outlined, '私有部署', '数据完全自有，TLS 加密传输'),
          ].map((e) => Padding(
                padding: const EdgeInsets.only(bottom: 18),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xFF3B82F6).withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child:
                          Icon(e.$1, size: 22, color: const Color(0xFF60A5FA)),
                    ),
                    const SizedBox(width: 14),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(e.$2,
                            style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFFE2E8F0))),
                        Text(e.$3,
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF94A3B8))),
                      ],
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  /// 窄屏品牌区（紧凑单行）
  Widget _buildBrandHeader(BuildContext context, {bool compact = false}) {
    return Column(
      children: [
        _brandMark(size: 56, radius: 18, iconSize: 32),
        const SizedBox(height: 12),
        const Text('聊天室',
            style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Color(0xFFF1F5F9))),
        const SizedBox(height: 4),
        const Text('私有化部署的即时通讯',
            style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8))),
      ],
    );
  }

  /// 品牌标识（圆角方块 + 气泡图标，品牌蓝渐变）
  Widget _brandMark(
      {required double size,
      required double radius,
      required double iconSize}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF3B82F6), Color(0xFF2563EB)],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF3B82F6).withValues(alpha: 0.35),
            blurRadius: 32,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Icon(Icons.forum_rounded, size: iconSize, color: Colors.white),
    );
  }

  /// 登录/注册表单卡片（深色半透明 + 细边框）
  Widget _buildFormCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: const Color(0xFF111C36).withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF000000).withValues(alpha: 0.35),
            blurRadius: 40,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _isLogin ? '欢迎回来' : '创建新账号',
            style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Color(0xFFF1F5F9)),
          ),
          const SizedBox(height: 4),
          Text(
            _isLogin ? '登录以继续' : '注册新账号',
            style: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
          ),
          const SizedBox(height: 20),

          // 阶段 O6（P2-10 多账号切换）：已保存账号条目，点击回填
          if (_savedAccounts.isNotEmpty) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final account in _savedAccounts)
                  ActionChip(
                    backgroundColor: Colors.white.withValues(alpha: 0.06),
                    side:
                        BorderSide(color: Colors.white.withValues(alpha: 0.12)),
                    avatar: const Icon(Icons.person_outline_rounded,
                        size: 18, color: Color(0xFF93C5FD)),
                    label: Text(account.username,
                        style: const TextStyle(color: Color(0xFFE2E8F0))),
                    tooltip: '使用 ${account.username} 登录',
                    onPressed: () => _fillAccount(account),
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],

          _loginField(
            child: RawTextField(
              key: const ValueKey('username_field'),
              controller: _usernameCtrl,
              focusNode: _usernameFocus,
              hintText: '用户名（3-32位字母,数字,下划线,短横线）',
            ),
          ),
          const SizedBox(height: 14),

          _loginField(
            child: RawTextField(
              key: const ValueKey('password_field'),
              controller: _passwordCtrl,
              hintText: '密码（至少6个字符）',
              obscureText: true,
              showVisibilityToggle: true,
              onSubmitted: (_) => _submit(),
            ),
          ),
          const SizedBox(height: 10),

          Material(
            color: Colors.transparent,
            child: SwitchListTile(
              value: _adminMode,
              contentPadding: EdgeInsets.zero,
              title: const Text('管理员模式',
                  style: TextStyle(fontSize: 14, color: Color(0xFFE2E8F0))),
              subtitle: Text(
                _isLogin ? '管理员登录需要二次密钥' : '使用密钥注册管理员账号',
                style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
              ),
              onChanged: _loading
                  ? null
                  : (value) => setState(() {
                        _adminMode = value;
                        _error = null;
                        if (!value) _adminSecretCtrl.clear();
                      }),
            ),
          ),

          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: _adminMode
                ? Padding(
                    key: const ValueKey('admin_secret_field_wrap'),
                    padding: const EdgeInsets.only(top: 4),
                    child: _loginField(
                      child: RawTextField(
                        key: const ValueKey('admin_secret_field'),
                        controller: _adminSecretCtrl,
                        hintText: '管理员密钥',
                        obscureText: true,
                        showVisibilityToggle: true,
                        onSubmitted: (_) => _submit(),
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),

          const SizedBox(height: 14),

          // 错误提示（深色适配）
          if (_error != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF7F1D1D).withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: const Color(0xFFFCA5A5).withValues(alpha: 0.35)),
              ),
              child: Text(_error!,
                  style:
                      const TextStyle(color: Color(0xFFFCA5A5), fontSize: 13)),
            ),

          const SizedBox(height: 16),

          // 按钮（品牌蓝，与主界面默认主题同源）
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

          const SizedBox(height: 8),

          TextButton(
            onPressed: _loading
                ? null
                : () => setState(() {
                      _isLogin = !_isLogin;
                      _error = null;
                      _adminSecretCtrl.clear();
                    }),
            child: Text(_isLogin ? '没有账号？注册' : '已有账号？登录',
                style: const TextStyle(color: Color(0xFF93C5FD))),
          ),
        ],
      ),
    );
  }

  /// 登录页输入容器（深色填充 + 圆角描边）
  Widget _loginField({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0B1428),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF24314F)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: child,
    );
  }
}

/// 宽屏三段式（2026-08-31 用户反馈 #2）：中部对话插画——
/// 三张玻璃质感气泡卡片（群消息 / 回复 / 加密系统提示）+ 缓慢浮动动画，
/// 填充大屏中部留白；仅在 >=1280px 三段式布局挂载（循环动画不影响
/// 单/双栏布局下的既有 pumpAndSettle 测试）。
class _FloatingChatArt extends StatefulWidget {
  const _FloatingChatArt();

  @override
  State<_FloatingChatArt> createState() => _FloatingChatArtState();
}

class _FloatingChatArtState extends State<_FloatingChatArt>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(seconds: 5))
        ..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 相位浮移（-6 ~ +6px）
  double _float(double phase) =>
      6 * math.sin((_controller.value + phase) * 2 * math.pi);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _chatBubble(
              dy: _float(0.0),
              align: CrossAxisAlignment.start,
              avatarColor: const Color(0xFF34D399),
              avatarText: '李',
              text: '明晚 8 点线上会议，记得参加 🎉',
              time: '刚刚',
            ),
            const SizedBox(height: 22),
            _chatBubble(
              dy: _float(0.35),
              align: CrossAxisAlignment.end,
              avatarColor: const Color(0xFF60A5FA),
              avatarText: 'A',
              text: '收到，准时参加 ✅',
              time: '1 分钟前',
              self: true,
            ),
            const SizedBox(height: 22),
            _systemCard(dy: _float(0.7)),
          ],
        );
      },
    );
  }

  /// 对话气泡卡片（玻璃质感 + 头像 + 时间戳）
  Widget _chatBubble({
    required double dy,
    required CrossAxisAlignment align,
    required Color avatarColor,
    required String avatarText,
    required String text,
    required String time,
    bool self = false,
  }) {
    return Transform.translate(
      offset: Offset(0, dy),
      child: FractionallySizedBox(
        widthFactor: 0.82,
        child: Column(
          crossAxisAlignment: align,
          children: [
            Row(
              mainAxisAlignment:
                  self ? MainAxisAlignment.end : MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (!self) ...[
                  _avatar(avatarColor, avatarText),
                  const SizedBox(width: 10)
                ],
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: self
                          ? const Color(0xFF3B82F6).withValues(alpha: 0.30)
                          : Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(16),
                        topRight: const Radius.circular(16),
                        bottomLeft: Radius.circular(self ? 16 : 4),
                        bottomRight: Radius.circular(self ? 4 : 16),
                      ),
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.10)),
                    ),
                    child: Text(
                      text,
                      style: const TextStyle(
                          fontSize: 14, color: Color(0xFFE2E8F0)),
                    ),
                  ),
                ),
                if (self) ...[
                  const SizedBox(width: 10),
                  _avatar(avatarColor, avatarText)
                ],
              ],
            ),
            const SizedBox(height: 6),
            Padding(
              padding: self
                  ? const EdgeInsets.only(right: 46)
                  : const EdgeInsets.only(left: 46),
              child: Text(time,
                  style:
                      const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
            ),
          ],
        ),
      ),
    );
  }

  Widget _avatar(Color color, String text) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.22),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      alignment: Alignment.center,
      child: Text(text,
          style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: color.withValues(alpha: 0.95))),
    );
  }

  /// 加密系统提示卡（盾图标 + 呼吸绿点）
  Widget _systemCard({required double dy}) {
    return Transform.translate(
      offset: Offset(0, dy),
      child: FractionallySizedBox(
        widthFactor: 0.82,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: const Color(0xFF34D399).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.verified_user_outlined,
                    size: 20, color: Color(0xFF34D399)),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('连接已加密',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFE2E8F0))),
                    SizedBox(height: 2),
                    Text('TLS 加密传输 · 消息已送达',
                        style:
                            TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
                  ],
                ),
              ),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF34D399),
                  boxShadow: [
                    BoxShadow(
                        color: const Color(0xFF34D399).withValues(alpha: 0.5),
                        blurRadius: 8),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
