/// 客户端配置文件
///
/// 所有配置项在此集中管理。后续可从 config.yaml 读取。
class AppConfig {
  /// 服务器地址
  static const String serverHost = '127.0.0.1';

  /// 服务器端口
  static const int serverPort = 8090;

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

  /// 接收文件保存目录
  static const String receivedFilesDir = 'received_files';

  /// 文件发送目录（用于测试）
  static const String filesDir = '../files';
}
