/// 聊天数据模型
///
/// 包含消息、好友请求、文件请求、群组等所有业务实体。

import 'dart:typed_data';

/// 连接状态
enum ConnectionStatus { disconnected, connecting, connected }

/// 一条聊天消息
class ChatMessage {
  final String sender;
  final String content;
  final String type; // 'chat', 'group_chat', 'file', 'recalled', 'system'
  final String messageId;
  final DateTime timestamp;
  String status; // 'sent', 'delivered', 'recalled'
  bool isHistory; // 是否离线历史消息
  String? filename; // 文件消息的文件名
  Uint8List? fileData; // 文件消息的数据
  int? groupId; // 群聊消息的群组 ID

  ChatMessage({
    required this.sender,
    required this.content,
    this.type = 'chat',
    required this.messageId,
    DateTime? timestamp,
    this.status = 'sent',
    this.isHistory = false,
    this.filename,
    this.fileData,
    this.groupId,
  }) : timestamp = timestamp ?? DateTime.now();

  /// 是否已撤回
  bool get isRecalled => status == 'recalled';

  /// 显示用的消息文本
  String get displayText {
    if (isRecalled) return '$sender: [消息已撤回]';
    if (type == 'system') return content;
    if (filename != null) return '$sender: [文件] $filename';
    return '$sender: $content';
  }

  /// 用于 UI 显示的头部（发送者 + 状态）
  String get header {
    if (type == 'system') return '';
    final statusStr = switch (status) {
      'sent' => '',
      'delivered' => '',
      'recalled' => '',
      _ => '',
    };
    return '$sender $statusStr';
  }
}

/// 群组信息
class Group {
  final int id;
  final String name;
  final List<String> members;

  Group({
    required this.id,
    required this.name,
    this.members = const [],
  });

  /// 聊天窗口中使用的 key
  String get chatKey => 'group_$id';

  /// 显示用名称
  String get displayName => '$name (ID:$id)';

  factory Group.fromJson(Map<String, dynamic> json) {
    return Group(
      id: json['id'] as int,
      name: json['group_name'] as String? ?? json['name'] as String? ?? '',
      members: (json['members'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
    );
  }
}

/// 待处理的文件请求
class FileRequest {
  final String messageId;
  final String sender;
  final String filename;
  final int filesize;
  final int? groupId;

  FileRequest({
    required this.messageId,
    required this.sender,
    required this.filename,
    required this.filesize,
    this.groupId,
  });

  bool get isGroupFile => groupId != null;
}

/// 会话列表项（好友或群组）
class ChatTarget {
  final String key; // 用户名 或 "group_N"
  final String displayName; // 显示名称
  final bool isGroup;

  const ChatTarget({
    required this.key,
    required this.displayName,
    this.isGroup = false,
  });
}

/// 用户名/密码验证结果
class ValidationResult {
  final bool valid;
  final String? error;

  const ValidationResult(this.valid, [this.error]);

  static ValidationResult ok() => const ValidationResult(true);
  static ValidationResult fail(String error) => ValidationResult(false, error);
}

/// 输入验证工具
class InputValidator {
  static final RegExp _usernamePattern = RegExp(r'^[a-zA-Z0-9_\-]+$');

  static ValidationResult validateUsername(String username) {
    if (username.length < 3) {
      return ValidationResult.fail('用户名长度不能少于 3 个字符');
    }
    if (username.length > 32) {
      return ValidationResult.fail('用户名长度不能超过 32 个字符');
    }
    if (!_usernamePattern.hasMatch(username)) {
      return ValidationResult.fail('用户名只能包含字母、数字、下划线和连字符');
    }
    return ValidationResult.ok();
  }

  static ValidationResult validatePassword(String password) {
    if (password.length < 6) {
      return ValidationResult.fail('密码长度不能少于 6 个字符');
    }
    return ValidationResult.ok();
  }
}
