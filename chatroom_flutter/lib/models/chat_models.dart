/// 聊天数据模型
///
/// 包含消息、好友请求、文件请求、群组等所有业务实体。

import 'dart:typed_data';

/// 连接状态
enum ConnectionStatus {
  disconnected,
  connecting,
  connected,
  reconnecting,
}

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

  /// 是否发送中（阶段 I1：本地 pending 队列在途状态）
  bool get isSending => status == 'sending';

  /// 是否发送失败（阶段 I1：待重试状态）
  bool get isFailed => status == 'failed';

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
      'sending' => '（发送中）',
      'failed' => '（发送失败）',
      _ => '',
    };
    return '$sender $statusStr';
  }
}

/// 待发送消息（阶段 I1：本地 pending 队列条目）
///
/// 断线/发送失败时消息先进入队列，重连成功后自动补发；
/// [chatKey] 为会话 key（好友用户名 或 'group_N'），补发时据此定位目标。
class PendingMessage {
  final String chatKey;
  final ChatMessage message;

  const PendingMessage({required this.chatKey, required this.message});
}

/// 会话元数据（阶段 I2：conversations 表的客户端状态镜像）
///
/// 支撑会话置顶（K1）/ 逐会话草稿（K2）/ 静音（K3）/ 清空标记（K4）。
class ConversationMeta {
  final bool pinned;
  final bool muted;
  final String draft;
  final DateTime? clearedAt;

  const ConversationMeta({
    this.pinned = false,
    this.muted = false,
    this.draft = '',
    this.clearedAt,
  });

  static const Object _unset = Object();

  /// 部分复制：未传入字段保持原值；clearedAt 传 null 可显式清除
  ConversationMeta copyWith({
    bool? pinned,
    bool? muted,
    String? draft,
    Object? clearedAt = _unset,
  }) {
    return ConversationMeta(
      pinned: pinned ?? this.pinned,
      muted: muted ?? this.muted,
      draft: draft ?? this.draft,
      clearedAt: identical(clearedAt, _unset)
          ? this.clearedAt
          : clearedAt as DateTime?,
    );
  }
}

/// 用户资料（阶段 J：P0-2）
class UserProfile {
  final String username;
  final String nickname;
  final String avatar;
  final String signature;
  final DateTime? lastSeen;
  final bool isAdmin;

  UserProfile({
    required this.username,
    this.nickname = '',
    this.avatar = '',
    this.signature = '',
    this.lastSeen,
    this.isAdmin = false,
  });

  /// 显示名：昵称非空用昵称，否则用户名；纯空白昵称视为未设置
  String get displayName =>
      (nickname.isNotEmpty && nickname.trim().isNotEmpty) ? nickname : username;

  /// 是否已设置资料（任一字段非空）
  bool get hasProfile =>
      nickname.isNotEmpty || avatar.isNotEmpty || signature.isNotEmpty;

  /// 防御性解析：缺失字段/类型漂移/null 均不抛异常
  factory UserProfile.fromJson(Map<String, dynamic> json) {
    String asStr(dynamic v) => v == null ? '' : v.toString();
    DateTime? parseLastSeen(dynamic v) {
      if (v == null || v.toString().isEmpty) return null;
      try {
        var s = v.toString().trim();
        if (s.endsWith('Z')) s = s.substring(0, s.length - 1);
        return DateTime.parse('${s}Z').toLocal();
      } catch (_) {
        return null;
      }
    }

    bool asBool(dynamic v) {
      if (v is bool) return v;
      if (v is num) return v != 0;
      return v == 'true' || v == '1';
    }

    return UserProfile(
      username: asStr(json['username']),
      nickname: asStr(json['nickname']),
      avatar: asStr(json['avatar']),
      signature: asStr(json['signature']),
      lastSeen: parseLastSeen(json['last_seen']),
      isAdmin: asBool(json['is_admin']),
    );
  }

  Map<String, dynamic> toJson() => {
        'username': username,
        'nickname': nickname,
        'avatar': avatar,
        'signature': signature,
        'last_seen': lastSeen?.toUtc().toIso8601String(),
        'is_admin': isAdmin ? 1 : 0,
      };
}

/// 好友元数据（阶段 J：P1-8）——备注名 + 分组
class FriendMeta {
  final String username;
  final String note;
  final String groupName;

  const FriendMeta({
    required this.username,
    this.note = '',
    this.groupName = '',
  });

  /// 防御性解析：缺失字段/类型漂移/null 均不抛异常
  factory FriendMeta.fromJson(Map<String, dynamic> json) {
    String asStr(dynamic v) => v == null ? '' : v.toString();
    return FriendMeta(
      username: asStr(json['username']),
      note: asStr(json['note']),
      groupName: asStr(json['group_name']),
    );
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
    // 防御性解析：服务端字段类型漂移（数字/字符串混用）时优雅降级，不抛异常
    final rawId = json['id'];
    final id =
        rawId is int ? rawId : (int.tryParse(rawId?.toString() ?? '') ?? 0);
    final rawName = json['group_name'] ?? json['name'];
    final name = rawName is String ? rawName : (rawName?.toString() ?? '');
    final rawMembers = json['members'];
    final members = rawMembers is List
        ? rawMembers.map((e) => e.toString()).toList()
        : <String>[];
    return Group(
      id: id,
      name: name,
      members: members,
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

/// 文件传输进度（阶段 G：传输可视化）
class TransferProgress {
  final String messageId;
  final int total;
  final int transferred;
  final bool isSend; // true=发送中，false=接收中

  const TransferProgress({
    required this.messageId,
    required this.total,
    required this.transferred,
    this.isSend = false,
  });

  /// 进度比例 0.0 ~ 1.0（total 为 0 时返回 0）
  double get fraction => total <= 0 ? 0 : (transferred / total).clamp(0.0, 1.0);

  /// 是否已完成
  bool get done => total > 0 && transferred >= total;
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

  /// 密码校验（与服务端 validation.py validate_password 保持一致：P-17）
  ///
  /// 规则：非空；长度 6–128；不含控制字符（Unicode Cc 类别：
  /// U+0000–U+001F、U+007F–U+009F）。错误文案与服务端逐字一致。
  static ValidationResult validatePassword(String password) {
    if (password.isEmpty) {
      return ValidationResult.fail('密码不能为空');
    }
    if (password.length < 6) {
      return ValidationResult.fail('密码长度不能少于 6 个字符');
    }
    if (password.length > 128) {
      return ValidationResult.fail('密码长度不能超过 128 个字符');
    }
    for (final unit in password.codeUnits) {
      if (unit < 0x20 || (unit >= 0x7F && unit <= 0x9F)) {
        return ValidationResult.fail('密码不能包含控制字符');
      }
    }
    return ValidationResult.ok();
  }
}
