/// 登录/注册界面（fcitx 兼容版）
///
/// 关键：移除 SingleChildScrollView、readOnly 延迟切换、
/// SizedBox 包裹等可能触发 Linux fcitx IME 死锁的元素。
/// Q1 真机反馈二轮（问题7）：Android 端独立布局——品牌 logo/标题/
/// 介绍一概删去，功能表单全屏化（分段切换 + 账号磁贴 + 自动填充）；
/// Linux 桌面三档布局与测试基线不变（effectiveTargetPlatform 门控）。

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../config.dart';
import '../l10n/app_strings.dart';
import '../platform/android_system.dart';
import '../platform/capabilities.dart';
import '../services/theme_settings.dart';
import '../widgets/adaptive_text_field.dart';
import '../widgets/app_feedback.dart';
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
  final _passwordFocus = FocusNode();

  bool _isLogin = true;
  bool _adminMode = false;
  bool _loading = false;
  String? _error;
  // 阶段 O6（P2-10 多账号切换）：已保存的账号列表（钥匙串）
  List<StoredSession> _savedAccounts = [];

  /// Q1 三轮（问题1）：账号磁贴编辑态——长按进入（磁贴右上角出现叉号），
  /// 点叉删除、侧滑或点磁贴退出编辑态
  bool _accountEditMode = false;

  /// Q1 三轮（问题1）：勾选后本次登录不写入钥匙串（账号列表与当前
  /// 凭据均不保存，重启后无法快捷登录）
  bool _dontRecordLogin = false;

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

  /// Q1 三轮（问题1）：点击磁贴叉号 → 直接删除本机登录信息（不再弹确认；
  /// 编辑态本身即两段操作），SnackBar 反馈。SessionStore.removeAccount
  /// 同步清理钥匙串账号列表 + 当前凭据。
  Future<void> _removeAccount(StoredSession account) async {
    await SessionStore.removeAccount(account.username);
    if (!mounted) return;
    final accounts = await SessionStore.loadAccounts();
    if (!mounted) return;
    final wasFilled = _usernameCtrl.text.trim() == account.username;
    setState(() {
      _savedAccounts = accounts;
      if (_savedAccounts.isEmpty) _accountEditMode = false;
      if (wasFilled) {
        _usernameCtrl.clear();
        _passwordCtrl.clear();
      }
    });
    showNoticeBar(context, '已删除「${account.username}」的登录信息');
  }

  @override
  void dispose() {
    _usernameFocus.dispose();
    _passwordFocus.dispose();
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
      // Q1 三轮（问题1）：勾选"不记录此次登录"→ 钥匙串零写入（账号列表
      // 与当前凭据均不保存，重启后需手动输入）
      if (!_dontRecordLogin) {
        await SessionStore.saveAccount(StoredSession(
          username: username,
          password: password,
        ));
      }
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
    // 阶段 P6：监听 ThemeSettings（语言切换即时重建文案；其余主题项
    // 被专属主题屏蔽，不影响观感）。
    return ListenableBuilder(
      listenable: ThemeSettings.instance,
      builder: (context, _) => Theme(
        data: _loginTheme(),
        child: MediaQuery(
          // 字号排版独立：用户字体缩放不影响登录页
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.0)),
          child: Builder(builder: (context) => _buildLoginBody(context)),
        ),
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
      // gc6 修复：页内全新 ThemeData 会整体替换 main.dart 的全局主题，
      // 丢失 uiFontFamily（Windows→微软雅黑 UI）——中文兜底落宋体观感
      // 异常（用户实测登录/注册页中文字体不正常）；显式补回
      fontFamily: uiFontFamily(),
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
      // Q1 三轮（问题0 美化）：标准输入框（Android 等非 Linux 端）统一
      // 深色填充 + 圆角描边 + 聚焦品牌蓝光圈；Linux RawTextField 不消费
      // InputDecorationTheme，桌面渲染零影响
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF0B1428).withValues(alpha: 0.85),
        hintStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 14),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFF3B82F6), width: 1.4),
        ),
      ),
    );
  }

  /// 登录页主体：Android 独立全屏布局（Q1 真机反馈二轮问题7）；
  /// 其余平台维持三档响应式（桌面既有行为与测试基线不变）
  Widget _buildLoginBody(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (effectiveTargetPlatform() == TargetPlatform.android) {
      return _buildAndroidBody(context, width);
    }
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

  /// Q1 真机反馈二轮（问题7）：Android 登录/注册布局——去品牌区，
  /// 功能表单全屏（品牌深蓝渐变背景保留），返回键转后台不退出。
  Widget _buildAndroidBody(BuildContext context, double width) {
    final page = Scaffold(
      body: Stack(
        children: [
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
          Positioned(
            top: -160,
            right: -140,
            child: _glow(const Color(0xFF2563EB), 460, 0.22),
          ),
          Positioned(
            bottom: -180,
            left: -140,
            child: _glow(const Color(0xFF38BDF8), 460, 0.10),
          ),
          Positioned(
            top: -80,
            left: width * 0.18,
            child: IgnorePointer(
              child: Transform.rotate(
                angle: -0.5,
                child: Container(
                  width: 220,
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
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: _fadeIn(child: _buildAndroidForm(context)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        AndroidSystem.moveToBackground();
      },
      child: page,
    );
  }

  /// Android 表单本体（全屏、无卡片容器）：欢迎标语 + 动画滑块式
  /// 登录/注册切换 + 方形账号磁贴（点击回填/长按出叉删除/侧滑取消
  /// 编辑态）+ 不记录勾选 + 自动填充 + 大按钮（Q1 四轮问题1 增标语）
  Widget _buildAndroidForm(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        // gc13（用户决策）：顶部徽标去除——应用图标已表达品牌，登录页
        // 不再重复（旧渐变论坛徽标删除，标语保留）
        const Text(
          '在这里，墙没有耳朵',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: Color(0xFFF1F5F9),
          ),
        ),
        const SizedBox(height: 24),
        _LoginModeToggle(
          key: const ValueKey('login_mode_segment'),
          isLogin: _isLogin,
          enabled: !_loading,
          onChanged: (v) => setState(() {
            _isLogin = v;
            _error = null;
            _adminSecretCtrl.clear();
          }),
        ),
        const SizedBox(height: 24),

        // 已记录账号（Q1 三轮问题1：方形磁贴；长按进入编辑态出叉号，
        // 点叉直接删除，横向侧滑退出编辑态）
        if (_savedAccounts.isNotEmpty) ...[
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragEnd: (_) {
              if (_accountEditMode) {
                setState(() => _accountEditMode = false);
              }
            },
            child: Wrap(
              key: const ValueKey('saved_accounts_row'),
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final account in _savedAccounts)
                  _SavedAccountChip(
                    key: ValueKey('saved_account_${account.username}'),
                    account: account,
                    editMode: _accountEditMode,
                    onTap: () {
                      if (_accountEditMode) {
                        setState(() => _accountEditMode = false);
                        return;
                      }
                      _fillAccount(account);
                    },
                    onLongPress: () => setState(() => _accountEditMode = true),
                    onRemove: () => _removeAccount(account),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],

        AdaptiveTextField(
          key: const ValueKey('username_field'),
          controller: _usernameCtrl,
          focusNode: _usernameFocus,
          hintText: '用户名（3-32位字母,数字,下划线,短横线）',
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.username],
          onSubmitted: (_) => _passwordFocus.requestFocus(),
        ),
        const SizedBox(height: 14),
        AdaptiveTextField(
          key: const ValueKey('password_field'),
          controller: _passwordCtrl,
          focusNode: _passwordFocus,
          hintText: '密码（至少6个字符）',
          obscureText: true,
          showVisibilityToggle: true,
          keyboardType: TextInputType.visiblePassword,
          textInputAction: TextInputAction.done,
          autofillHints: _isLogin
              ? const [AutofillHints.password]
              : const [AutofillHints.newPassword],
          onSubmitted: (_) => _submit(),
        ),

        // Q1 三轮（问题1）：不记录此次登录——勾选后本次登录凭据零落盘
        Material(
          color: Colors.transparent,
          child: InkWell(
            key: const ValueKey('dont_remember_row'),
            borderRadius: BorderRadius.circular(10),
            onTap: _loading
                ? null
                : () => setState(() => _dontRecordLogin = !_dontRecordLogin),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: Checkbox(
                      key: const ValueKey('dont_remember_checkbox'),
                      value: _dontRecordLogin,
                      visualDensity: VisualDensity.compact,
                      onChanged: _loading
                          ? null
                          : (v) =>
                              setState(() => _dontRecordLogin = v ?? false),
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    '不记录此次登录',
                    style: TextStyle(fontSize: 13, color: Color(0xFFCBD5E1)),
                  ),
                ],
              ),
            ),
          ),
        ),

        Material(
          color: Colors.transparent,
          child: SwitchListTile(
            value: _adminMode,
            contentPadding: EdgeInsets.zero,
            title: Text(t('adminMode'),
                style: const TextStyle(fontSize: 14, color: Color(0xFFE2E8F0))),
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
                  padding: const EdgeInsets.only(bottom: 4),
                  child: AdaptiveTextField(
                    key: const ValueKey('admin_secret_field'),
                    controller: _adminSecretCtrl,
                    hintText: '管理员密钥',
                    obscureText: true,
                    showVisibilityToggle: true,
                    keyboardType: TextInputType.visiblePassword,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                  ),
                )
              : const SizedBox.shrink(),
        ),

        if (_error != null) ...[
          const SizedBox(height: 10),
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
                style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 13)),
          ),
        ],

        const SizedBox(height: 18),
        SizedBox(
          height: 52,
          child: FilledButton(
            key: const ValueKey('login_submit'),
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            onPressed: _loading ? null : _submit,
            child: _loading
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    _isLogin ? '登录' : '注册并登录',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                  ),
          ),
        ),
        const SizedBox(height: 14),
        Center(
          child: Text(
            'v${AppConfig.buildStamp}',
            style: TextStyle(
              fontSize: 10,
              color: Colors.white.withValues(alpha: 0.35),
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],
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

  /// 宽屏品牌展示区：产品标识 + 标语 + 特性亮点。
  /// 2026-09-01 用户反馈 #3（调窗口高度 BOTTOM OVERFLOW）：可滚动且垂直居中——
  /// Center 提供宽松约束，内容矮于视口居中、高于视口滚动，无溢出。
  Widget _buildBrandPane(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 72, vertical: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _brandMark(size: 72, radius: 22, iconSize: 40),
            const SizedBox(height: 24),
            Text(t('appTitle'),
                style: const TextStyle(
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
                          color:
                              const Color(0xFF3B82F6).withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(e.$1,
                            size: 22, color: const Color(0xFF60A5FA)),
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
      ),
    );
  }

  /// 窄屏品牌区（紧凑单行）
  Widget _buildBrandHeader(BuildContext context, {bool compact = false}) {
    // gc13：logo 图形去除（同标语块；应用图标已表达品牌）
    return Column(
      children: [
        Text(t('appTitle'),
            style: const TextStyle(
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
    // gc12：Rosub 品牌 logo（assets/rosub_login_logo.png，512 RGBA）——
    // 替换占位渐变+论坛图标；阴影/圆角保留
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF3B82F6).withValues(alpha: 0.35),
            blurRadius: 32,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Image.asset(
          'assets/rosub_login_logo.png',
          width: size,
          height: size,
          fit: BoxFit.cover,
        ),
      ),
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
            _isLogin ? t('loginToContinue') : t('registerToCreate'),
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
            child: AdaptiveTextField(
              key: const ValueKey('username_field'),
              controller: _usernameCtrl,
              focusNode: _usernameFocus,
              hintText: '用户名（3-32位字母,数字,下划线,短横线）',
            ),
          ),
          const SizedBox(height: 14),

          _loginField(
            child: AdaptiveTextField(
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
              title: Text(t('adminMode'),
                  style:
                      const TextStyle(fontSize: 14, color: Color(0xFFE2E8F0))),
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
                      child: AdaptiveTextField(
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

          // R-P27：构建标识——多客户端排查"谁在跑旧构建"（旧构建同时呈现
          // 黑白表情 + media_kit non-platform thread ERROR）时一眼可辨
          const SizedBox(height: 4),
          Text(
            'v${AppConfig.buildStamp}',
            style: TextStyle(
              fontSize: 10,
              color: Colors.white.withValues(alpha: 0.35),
            ),
          ),
        ],
      ),
    );
  }

  /// 登录页输入容器（深色填充 + 圆角描边）
  // 2026-09-01 用户反馈（内外双层框）：移除额外输入容器——
  // 单层框即 RawTextField 自身的主题描边（登录深色主题自动融入）
  Widget _loginField({required Widget child}) => child;
}

/// 宽屏三段式（2026-08-31 用户反馈 #2）：中部对话插画——
/// 三张玻璃质感气泡卡片（群消息 / 回复 / 加密系统提示）+ 缓慢浮动动画，
/// 填充大屏中部留白；仅在 >=1280px 三段式布局挂载（循环动画不影响
/// 单/双栏布局下的既有 pumpAndSettle 测试）。
/// 中部对话插画（2026-09-01 用户反馈 #2 重设计）：**滚动播放的消息流**——
/// 10 条玻璃质感消息卡片覆盖项目全部消息功能（群聊/私聊/图片/文件/引用回复/
/// 表情回应/群公告/置顶/定时消息/加密系统提示），自下而上无缝循环滚动，
/// 模拟"正在聊天"；仅在 >=1280px 三段式布局挂载（其动画为自驱循环，
/// 不依赖 pumpAndSettle——默认 800x600 单列布局不挂载，既有测试不受影响）。
class _FloatingChatArt extends StatefulWidget {
  const _FloatingChatArt();

  @override
  State<_FloatingChatArt> createState() => _FloatingChatArtState();
}

/// 消息流条目（功能类型 → 展示文案/图标/徽标）
class _ArtMessage {
  final IconData icon;
  final String kind; // 功能标签（群聊/私聊/图片/文件/回复/表情/公告/置顶/定时/加密）
  final String name;
  final String text;
  final Color tint;
  final bool self;

  const _ArtMessage(this.icon, this.kind, this.name, this.text, this.tint,
      {this.self = false});
}

class _FloatingChatArtState extends State<_FloatingChatArt>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(seconds: 16))
        ..repeat();

  static const double _itemHeight = 84.0;
  static const double _itemGap = 16.0;

  double get _cycle => _messages.length * (_itemHeight + _itemGap);

  /// 10 条消息：覆盖项目全部消息功能
  static const List<_ArtMessage> _messages = [
    _ArtMessage(Icons.groups_rounded, '群聊', '李', '明晚 8 点线上会议，记得参加 🎉',
        Color(0xFF34D399)),
    _ArtMessage(
        Icons.chat_bubble_rounded, '私聊', 'A', '收到，准时参加 ✅', Color(0xFF60A5FA),
        self: true),
    _ArtMessage(
        Icons.image_rounded, '图片', '王', '会议纪要截图.png', Color(0xFFF472B6)),
    _ArtMessage(Icons.insert_drive_file_rounded, '文件', '张', '报告.pdf · 2.3 MB',
        Color(0xFFFB923C)),
    _ArtMessage(Icons.format_quote_rounded, '回复', '李', '引用回复：原方案可行，按此执行',
        Color(0xFF34D399)),
    _ArtMessage(
        Icons.emoji_emotions_rounded, '表情', 'A', '哈哈 👍 ×3', Color(0xFF60A5FA),
        self: true),
    _ArtMessage(Icons.campaign_rounded, '公告', '群公告', '周五 18:00 团建，请准时参加',
        Color(0xFFFACC15)),
    _ArtMessage(
        Icons.push_pin_rounded, '置顶', '系统', '已置顶：重要通知', Color(0xFF38BDF8)),
    _ArtMessage(Icons.schedule_rounded, '定时', 'A', '定时提醒：今天 15:00 站会',
        Color(0xFF60A5FA),
        self: true),
    _ArtMessage(Icons.verified_user_rounded, '加密', '系统', 'TLS 加密传输 · 消息已送达',
        Color(0xFF34D399)),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, cons) {
      // 高度自适应：矮窗口取视口的 85%（不溢出，配合外层可滚动区域）
      final h = math.min(430.0, math.max(0.0, cons.maxHeight * 0.88));
      if (h < 60) return const SizedBox.shrink();
      return SizedBox(
        height: h,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final offset = _controller.value * _cycle;
            // Stack + Positioned：消息流自下而上平移，越界部分被裁剪
            //（Stack 子级不受受限高度布局约束，无 BOTTOM OVERFLOW）；
            // 双份列表保证滚动到末尾时无缝续接循环
            return ClipRect(
              child: Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    top: -offset,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final m in [..._messages, ..._messages])
                          _artCard(m),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );
    });
  }

  /// 单张玻璃质感消息卡（统一高度，滚动稳定）
  Widget _artCard(_ArtMessage m) {
    return Container(
      height: _itemHeight,
      margin: const EdgeInsets.only(bottom: _itemGap),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: (m.self ? const Color(0xFF3B82F6) : Colors.white)
            .withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: m.self
                ? const Color(0xFF3B82F6).withValues(alpha: 0.35)
                : Colors.white.withValues(alpha: 0.10)),
      ),
      child: Row(
        children: [
          // 功能图标徽标（彩色圆角方块）
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: m.tint.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(m.icon, size: 20, color: m.tint),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(m.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF94A3B8))),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: m.tint.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(m.kind,
                          style: TextStyle(fontSize: 10, color: m.tint)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(m.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, color: Color(0xFFE2E8F0))),
              ],
            ),
          ),
          if (m.self)
            const Icon(Icons.check_circle_rounded,
                size: 14, color: Color(0xFF34D399)),
        ],
      ),
    );
  }
}

/// Q1 三轮（问题0 美化）：登录/注册滑块式切换——深色槽体 + 品牌蓝渐变
/// 滑块（AnimatedAlign 平滑滑动 + 柔光投影），选中项白色加粗，
/// 未选中项板岩灰；替代观感生硬的 SegmentedButton。
class _LoginModeToggle extends StatelessWidget {
  final bool isLogin;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _LoginModeToggle({
    super.key,
    required this.isLogin,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: LayoutBuilder(builder: (context, cons) {
        return Stack(
          children: [
            AnimatedAlign(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: isLogin ? Alignment.centerLeft : Alignment.centerRight,
              child: Container(
                width: cons.maxWidth / 2,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF3B82F6), Color(0xFF2563EB)],
                  ),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF3B82F6).withValues(alpha: 0.4),
                      blurRadius: 14,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
              ),
            ),
            Row(
              children: [
                Expanded(child: _segment(true, '登录')),
                Expanded(child: _segment(false, '注册')),
              ],
            ),
          ],
        );
      }),
    );
  }

  Widget _segment(bool value, String label) {
    final selected = isLogin == value;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: (!enabled || selected) ? null : () => onChanged(value),
      child: Center(
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 180),
          style: TextStyle(
            fontSize: 15,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? Colors.white : const Color(0xFF94A3B8),
          ),
          child: Text(label),
        ),
      ),
    );
  }
}

/// Q1 三轮（问题1）：已记录账号方形磁贴——圆角方框 + 人物图标 + 用户名
/// （与桌面 ActionChip 方形观感对齐）；编辑态右上角浮现红底叉号，
/// 点击叉号直接删除；进入编辑态 = 长按任意磁贴。
class _SavedAccountChip extends StatelessWidget {
  final StoredSession account;
  final bool editMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onRemove;

  const _SavedAccountChip({
    super.key,
    required this.account,
    required this.editMode,
    required this.onTap,
    required this.onLongPress,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: editMode
                    ? const Color(0xFF60A5FA).withValues(alpha: 0.55)
                    : Colors.white.withValues(alpha: 0.14),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.person_outline_rounded,
                    size: 18, color: Color(0xFF93C5FD)),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 120),
                  child: Text(
                    account.username,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(fontSize: 14, color: Color(0xFFE2E8F0)),
                  ),
                ),
              ],
            ),
          ),
          if (editMode)
            Positioned(
              top: -7,
              right: -7,
              child: GestureDetector(
                key: ValueKey('saved_account_remove_${account.username}'),
                onTap: onRemove,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: const Color(0xFFEF4444),
                    shape: BoxShape.circle,
                    border:
                        Border.all(color: const Color(0xFF070D1A), width: 2),
                  ),
                  child: const Icon(Icons.close_rounded,
                      size: 13, color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
