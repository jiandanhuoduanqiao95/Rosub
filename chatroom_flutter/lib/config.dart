/// 客户端配置文件
///
/// 所有配置项在此集中管理。后续可从 config.yaml 读取。
class AppConfig {
  /// 服务器地址（可变静态量，仿 serverPort：E2E 测试覆盖为本机回环）。
  /// 真机安装包经构建参数编译期注入：--dart-define=CHATROOM_SERVER_HOST=<开发机局域网 IP>
  /// （Q1 曾误提交硬编码局域网 IP，现默认值恒 127.0.0.1、源码不再为真机验证临时改动）
  static String serverHost = const String.fromEnvironment(
    'CHATROOM_SERVER_HOST',
    defaultValue: '127.0.0.1',
  );

  /// 服务器端口（E2E 测试可覆盖，避免多 E2E 文件并发争用同一端口）
  static int serverPort = 8090;

  /// SSL 证书路径（相对于项目根目录）
  static const String sslCertPath = '../SSL/tsetcn.crt';

  /// SSL 证书主机名
  static const String serverHostname = 'tset.cn';

  /// 消息分块大小（字节）
  static const int chunkSize = 4 * 1024 * 1024;

  /// 协议版本
  static const String protocolVersion = '1.0.0';

  /// 用户名最小长度
  static const int usernameMinLen = 3;

  /// 用户名最大长度
  static const int usernameMaxLen = 32;

  /// 密码最小长度
  static const int passwordMinLen = 6;

  /// 文件大小上限（字节），与服务端 file.max_file_size 对齐（默认 5GB，阶段 G4）
  static const int maxFileSize = 5 * 1024 * 1024 * 1024;

  /// 大文件直传阈值（字节），与服务端 file.large_file_threshold 对齐（默认 300MB）
  /// 超过阈值：先探测对方在线，在线则直接流式传输（服务器不存储）
  static const int largeFileThreshold = 300 * 1024 * 1024;

  /// 接收文件保存目录
  static const String receivedFilesDir = 'received_files';

  /// 自定义表情包落盘目录（R-P11：与 received_files 同级的相对目录，
  /// main() 启动时注入 StickerStore 并确保存在）
  static const String stickerStoreDir = 'stickers';

  /// 文件发送目录（用于测试）
  static const String filesDir = '../files';

  /// 小图片自动接收阈值（字节，5MB，阶段 N3b）：扩展名为图片
  /// 且 ≤ 此值的文件请求自动接受并内联展示（参考微信）。
  static const int autoAcceptImageMaxSize = 5 * 1024 * 1024;

  /// 构建标识（R-P27，2026-09-05 用户复测"表情黑白"轮换出现）：随修订
  /// 递增，显示在登录页页脚并打印到启动日志——多客户端排查"谁在跑
  /// 旧构建"（旧构建同时呈现黑白表情 + media_kit non-platform thread
  /// ERROR）时一眼可辨。每次修订轮次更新此值。
  static const String buildStamp = 'gc8';

  /// 彩色 emoji 字体栈（R-P26 硬化）：首选内置 COLRv1 字体，第二兜底
  /// 系统 Noto Color Emoji（CBDT 彩色位图，Ubuntu 默认安装、覆盖全部
  /// emoji 码点）——内置字体加载失败/缺码点时落到系统彩字而非
  /// fontconfig 的黑白符号字体（DejaVu/Noto Sans Symbols）。独立成格
  /// 的 emoji 用 [emojiFontFamily] 打头（R-P10 契约）；混排文本用
  /// [emojiFontFallback] 兜底（主字体链在前，emoji 缺字形时兜底）。
  /// COLRv1 打头仅限 Linux 渲染语义：Windows 桌面引擎认领 COLRv1 字形
  /// 却栅格化输出空白（Q2 真机实测），网格主字体走
  /// emojiPickerFontFamily()（capabilities.dart 平台分发）。
  static const List<String> emojiFontStack = [
    'NotoColorEmoji',
    'Noto Color Emoji',
  ];
}
