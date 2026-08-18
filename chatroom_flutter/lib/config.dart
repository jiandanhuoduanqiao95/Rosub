/// 客户端配置文件
///
/// 所有配置项在此集中管理。后续可从 config.yaml 读取。
class AppConfig {
  /// 服务器地址
  static const String serverHost = '127.0.0.1';

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

  /// 文件发送目录（用于测试）
  static const String filesDir = '../files';
}
