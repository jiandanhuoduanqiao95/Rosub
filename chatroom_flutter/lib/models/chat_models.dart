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

/// 表情回应默认表情盘（阶段 K：P1-4，Telegram 风格彩色 emoji）
const List<String> defaultReactionEmojis = [
  '👍',
  '❤️',
  '🔥',
  '😂',
  '😮',
  '😢',
  '😡',
  '🎉',
  '👏',
  '🙏',
];

/// 一条聊天消息
class ChatMessage {
  final String sender;
  String content;
  final String type; // 'chat', 'group_chat', 'file', 'recalled', 'system'
  final String messageId;
  final DateTime timestamp;
  String status; // 'sent', 'delivered', 'recalled'
  bool isHistory; // 是否离线历史消息
  String? filename; // 文件消息的文件名
  Uint8List? fileData; // 文件消息的数据
  String? filePath; // 文件消息的本地落盘路径（阶段 N3b：内联图片展示）
  int? groupId; // 群聊消息的群组 ID
  int? filesize; // 文件消息字节数（阶段 P1：气泡大小行；null = 未知）

  // ---- 阶段 K5（P1-2/P1-4）消息操作扩展 ----
  String? replyTo; // 引用原消息 id（P1-2）
  String? replyPreview; // 引用原文缩略（P1-2）
  Map<String, List<String>> reactions; // emoji → 用户列表（P1-4）

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
    this.filePath,
    this.groupId,
    this.filesize,
    this.replyTo,
    this.replyPreview,
    this.reactions = const {},
  }) : timestamp = timestamp ?? DateTime.now();

  /// 是否已撤回
  bool get isRecalled => status == 'recalled';

  /// 是否发送中（阶段 I1：本地 pending 队列在途状态）
  bool get isSending => status == 'sending';

  /// 是否发送失败（阶段 I1：待重试状态）
  bool get isFailed => status == 'failed';

  /// 是否携带引用（阶段 K5：P1-2）
  bool get hasQuote => replyTo != null;

  /// 显示用的消息文本
  String get displayText {
    if (isRecalled) {
      // 文件撤回：保留消息体并附加"已撤回"标志（不替换为"[消息已撤回]"）
      if (type == 'file') return '$sender: $content [已撤回]';
      return '$sender: [消息已撤回]';
    }
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
  final String peerKey; // 会话 key（好友用户名 或 'group_N'，阶段 K 登录推送解析）
  final bool pinned;
  final bool muted;
  final String draft;
  final DateTime? clearedAt;

  const ConversationMeta({
    this.peerKey = '',
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
      peerKey: peerKey,
      pinned: pinned ?? this.pinned,
      muted: muted ?? this.muted,
      draft: draft ?? this.draft,
      clearedAt: identical(clearedAt, _unset)
          ? this.clearedAt
          : clearedAt as DateTime?,
    );
  }

  /// 防御性解析（阶段 K：服务端 list_conversations 登录推送）：
  /// 缺失字段/类型漂移/null 均不抛异常
  factory ConversationMeta.fromJson(Map<String, dynamic> json) {
    String asStr(dynamic v) => v == null ? '' : v.toString();
    bool asBool(dynamic v) {
      if (v is bool) return v;
      if (v is num) return v != 0;
      return v == 'true' || v == '1';
    }

    DateTime? parseClearedAt(dynamic v) {
      if (v == null || v.toString().isEmpty) return null;
      try {
        var s = v.toString().trim();
        if (s.endsWith('Z')) s = s.substring(0, s.length - 1);
        return DateTime.parse('${s}Z').toLocal();
      } catch (_) {
        return null;
      }
    }

    return ConversationMeta(
      peerKey: asStr(json['peer_key']),
      pinned: asBool(json['pinned']),
      muted: asBool(json['muted']),
      draft: asStr(json['draft']),
      clearedAt: parseClearedAt(json['cleared_at']),
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
  // 阶段 M1/M3：群主标识 / 群头像 / 新成员历史可见性（list_groups 推送扩展）
  final String owner;
  final String avatar;
  final bool historyVisible;
  final int historyLimit;
  // 阶段 M：群成员数（群组搜索结果 group_search_response 携带）
  final int memberCount;
  // 阶段 O1：群公告（list_groups 推送扩展；空 = 无公告）
  final String announcement;
  // 阶段 O2：群置顶消息 id 与内容快照（list_groups 推送扩展；空 = 未置顶；
  // 2026-08-31 多置顶并存后作为兼容快照 = 最早置顶的一条）
  final String pinnedMessageId;
  final String pinnedPreview;
  // 阶段 O2 修订（2026-08-31 多置顶并存）：全量置顶列表
  final List<GroupPinnedItem> pinnedMessages;

  Group({
    required this.id,
    required this.name,
    this.members = const [],
    this.owner = '',
    this.avatar = '',
    this.historyVisible = true,
    this.historyLimit = 50,
    this.memberCount = 0,
    this.announcement = '',
    this.pinnedMessageId = '',
    this.pinnedPreview = '',
    this.pinnedMessages = const [],
  });

  /// 聊天窗口中使用的 key
  String get chatKey => 'group_$id';

  /// 显示用名称
  String get displayName => '$name (ID:$id)';

  /// 当前用户是否为该群群主（阶段 M1）
  bool isOwner(String username) => owner.isNotEmpty && owner == username;

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
    // 阶段 M1/M3：治理字段（缺省兼容旧服务端推送）
    final rawOwner = json['created_by'];
    final owner = rawOwner is String ? rawOwner : (rawOwner?.toString() ?? '');
    final rawAvatar = json['avatar'];
    final avatar =
        rawAvatar is String ? rawAvatar : (rawAvatar?.toString() ?? '');
    final rawVisible = json['history_visible'];
    bool historyVisible = true;
    if (rawVisible is int) {
      historyVisible = rawVisible != 0;
    } else if (rawVisible is String) {
      historyVisible = rawVisible != '0';
    }
    final rawLimit = json['history_limit'];
    final historyLimit = rawLimit is int
        ? rawLimit
        : (int.tryParse(rawLimit?.toString() ?? '') ?? 50);
    final rawMemberCount = json['member_count'];
    final memberCount = rawMemberCount is int
        ? rawMemberCount
        : (int.tryParse(rawMemberCount?.toString() ?? '') ?? 0);
    // 阶段 O1/O2：公告与置顶（缺省兼容旧服务端推送）
    final rawAnnouncement = json['announcement'];
    final announcement = rawAnnouncement is String
        ? rawAnnouncement
        : (rawAnnouncement?.toString() ?? '');
    final rawPinnedId = json['pinned_message_id'];
    final pinnedMessageId =
        rawPinnedId is String ? rawPinnedId : (rawPinnedId?.toString() ?? '');
    final rawPinnedPreview = json['pinned_preview'];
    final pinnedPreview = rawPinnedPreview is String
        ? rawPinnedPreview
        : (rawPinnedPreview?.toString() ?? '');
    // 阶段 O2 修订（2026-08-31 多置顶并存）：全量置顶列表（缺省兼容旧推送）
    final rawPinnedList = json['pinned_messages'];
    final pinnedMessages = rawPinnedList is List
        ? rawPinnedList
            .whereType<Map>()
            .map((e) => GroupPinnedItem.fromJson(e.cast<String, dynamic>()))
            .toList()
        : <GroupPinnedItem>[];
    return Group(
      id: id,
      name: name,
      members: members,
      owner: owner,
      avatar: avatar,
      historyVisible: historyVisible,
      historyLimit: historyLimit,
      memberCount: memberCount,
      announcement: announcement,
      pinnedMessageId: pinnedMessageId,
      pinnedPreview: pinnedPreview,
      pinnedMessages: pinnedMessages,
    );
  }
}

/// 群置顶消息条目（阶段 O2 修订：多置顶并存，list_groups.pinned_messages）
class GroupPinnedItem {
  final String messageId;
  final String preview;
  final String pinnedBy;

  const GroupPinnedItem({
    required this.messageId,
    this.preview = '',
    this.pinnedBy = '',
  });

  factory GroupPinnedItem.fromJson(Map<String, dynamic> json) {
    String asStr(dynamic v) => v?.toString() ?? '';
    return GroupPinnedItem(
      messageId: asStr(json['message_id']),
      preview: asStr(json['preview']),
      pinnedBy: asStr(json['pinned_by']),
    );
  }
}

/// 群公告历史条目（阶段 O1 公告管理：announcements_list_response 推送）
class GroupAnnouncement {
  final String messageId;
  final String sender;
  final String content;
  final String timestamp;

  const GroupAnnouncement({
    required this.messageId,
    this.sender = '',
    required this.content,
    this.timestamp = '',
  });

  factory GroupAnnouncement.fromJson(Map<String, dynamic> json) {
    String asStr(dynamic v) => v?.toString() ?? '';
    return GroupAnnouncement(
      messageId: asStr(json['message_id']),
      sender: asStr(json['sender']),
      content: asStr(json['content']),
      timestamp: asStr(json['timestamp']),
    );
  }
}

/// 定时消息（阶段 O5：P2-5 预约发送，scheduled_list_response 推送）
class ScheduledMessageInfo {
  final String messageId;
  final String receiver; // 私聊目标（群消息为空）
  final int? groupId; // 群消息的群组 ID（私聊为 null）
  final String content;
  final DateTime scheduleAt;
  final String status; // pending / sent / cancelled

  const ScheduledMessageInfo({
    required this.messageId,
    this.receiver = '',
    this.groupId,
    required this.content,
    required this.scheduleAt,
    this.status = 'pending',
  });

  /// 是否群定时消息
  bool get isGroupMessage => groupId != null;

  factory ScheduledMessageInfo.fromJson(Map<String, dynamic> json) {
    // 防御性解析：服务端字段类型漂移（数字/字符串混用）时优雅降级，不抛异常
    final rawId = json['message_id'];
    final messageId = rawId is String ? rawId : (rawId?.toString() ?? '');
    final rawReceiver = json['receiver'];
    final receiver =
        rawReceiver is String ? rawReceiver : (rawReceiver?.toString() ?? '');
    final rawGroupId = json['group_id'];
    final groupId = rawGroupId is int
        ? rawGroupId
        : int.tryParse(rawGroupId?.toString() ?? '');
    final rawContent = json['content'];
    final content =
        rawContent is String ? rawContent : (rawContent?.toString() ?? '');
    DateTime scheduleAt = DateTime.fromMillisecondsSinceEpoch(0);
    final rawAt = json['schedule_at'];
    final atSec = rawAt is int ? rawAt : int.tryParse(rawAt?.toString() ?? '');
    if (atSec != null) {
      scheduleAt = DateTime.fromMillisecondsSinceEpoch(atSec * 1000);
    }
    final rawStatus = json['status'];
    final status = rawStatus is String ? rawStatus : '';
    return ScheduledMessageInfo(
      messageId: messageId,
      receiver: receiver,
      groupId: groupId,
      content: content,
      scheduleAt: scheduleAt,
      status: status.isEmpty ? 'pending' : status,
    );
  }
}

/// 群邀请（阶段 M2：P1-17 邀请制，group_invite 推送）
class GroupInvite {
  final int groupId;
  final String groupName;
  final String inviter;

  const GroupInvite({
    required this.groupId,
    this.groupName = '',
    this.inviter = '',
  });

  factory GroupInvite.fromJson(Map<String, dynamic> json) {
    final rawId = json['group_id'] ?? json['groupId'];
    final groupId =
        rawId is int ? rawId : (int.tryParse(rawId?.toString() ?? '') ?? 0);
    final rawName = json['group_name'] ?? json['groupName'];
    final groupName = rawName is String ? rawName : (rawName?.toString() ?? '');
    final rawInviter = json['from'] ?? json['inviter'];
    final inviter =
        rawInviter is String ? rawInviter : (rawInviter?.toString() ?? '');
    return GroupInvite(
      groupId: groupId,
      groupName: groupName,
      inviter: inviter,
    );
  }
}

/// 文件收发记录（阶段 M8：P1-7 文件收发管理页，file_list_response 推送）
class FileRecord {
  final String filename;
  final int filesize;
  final String sender;
  final String receiver;
  final String messageId;
  final DateTime timestamp;
  final int? groupId;
  final String status;

  const FileRecord({
    required this.filename,
    required this.filesize,
    required this.sender,
    required this.receiver,
    required this.messageId,
    required this.timestamp,
    this.groupId,
    this.status = 'sent',
  });

  bool get isGroupFile => groupId != null;

  factory FileRecord.fromJson(Map<String, dynamic> json) {
    final rawSize = json['filesize'];
    final filesize = rawSize is int
        ? rawSize
        : (int.tryParse(rawSize?.toString() ?? '') ?? 0);
    final rawTs = json['timestamp'];
    DateTime timestamp;
    if (rawTs is String) {
      timestamp =
          DateTime.tryParse(rawTs.replaceFirst(' ', 'T')) ?? DateTime.now();
    } else if (rawTs is DateTime) {
      timestamp = rawTs;
    } else {
      timestamp = DateTime.now();
    }
    final rawGroupId = json['group_id'] ?? json['groupId'];
    final groupId = rawGroupId is int
        ? rawGroupId
        : (rawGroupId == null
            ? null
            : (int.tryParse(rawGroupId.toString()) ?? 0));
    return FileRecord(
      filename: (json['filename'] as String?) ?? '',
      filesize: filesize,
      sender: (json['sender'] as String?) ?? '',
      receiver: (json['receiver'] as String?) ?? '',
      messageId: (json['message_id'] as String?) ?? '',
      timestamp: timestamp,
      groupId: groupId,
      status: (json['status'] as String?) ?? 'sent',
    );
  }
}

// ============================================================
// 阶段 N —— 日常使用便利性模型
// ============================================================

/// 登录设备会话（阶段 N6：P2-6 登录设备管理，sessions_response 推送）
class SessionInfo {
  final String deviceId;
  final DateTime lastActive;
  final bool isCurrent;

  const SessionInfo({
    required this.deviceId,
    required this.lastActive,
    this.isCurrent = false,
  });

  factory SessionInfo.fromJson(Map<String, dynamic> json) {
    // last_active 为 epoch 秒（数字或数字字符串）；缺失/非法 → epoch 0
    final rawActive = json['last_active'];
    var lastActive = DateTime.fromMillisecondsSinceEpoch(0);
    if (rawActive is num) {
      lastActive =
          DateTime.fromMillisecondsSinceEpoch((rawActive * 1000).round());
    } else if (rawActive is String) {
      final epoch = double.tryParse(rawActive);
      if (epoch != null) {
        lastActive =
            DateTime.fromMillisecondsSinceEpoch((epoch * 1000).round());
      }
    }
    return SessionInfo(
      deviceId: (json['device_id'] as String?) ?? '',
      lastActive: lastActive,
      isCurrent: json['is_current'] == true,
    );
  }
}

/// 审计日志条目（阶段 N7：P2-7 审计日志，admin_response audit_log 推送）
class AuditLogEntry {
  final int id;
  final String operator;
  final String action;
  final String target;
  final String detail;
  final DateTime? timestamp; // 服务端 UTC（YYYY-MM-DD HH:MM:SS）→ 本地；非法为 null

  const AuditLogEntry({
    this.id = 0,
    required this.operator,
    required this.action,
    this.target = '',
    this.detail = '',
    this.timestamp,
  });

  factory AuditLogEntry.fromJson(Map<String, dynamic> json) {
    final rawId = json['id'];
    final id =
        rawId is int ? rawId : (int.tryParse(rawId?.toString() ?? '') ?? 0);
    DateTime? ts;
    final rawTs = json['timestamp'];
    if (rawTs is String && rawTs.trim().isNotEmpty) {
      // DB 存储 UTC 时间（YYYY-MM-DD HH:MM:SS），加 Z 解析再转本地
      ts = DateTime.tryParse('${rawTs.trim()}Z')?.toLocal();
    }
    return AuditLogEntry(
      id: id,
      operator: (json['operator'] as String?) ?? '',
      action: (json['action'] as String?) ?? '',
      target: (json['target'] as String?) ?? '',
      detail: (json['detail'] as String?) ?? '',
      timestamp: ts,
    );
  }
}

/// 图片字节识别（阶段 N3：P2-4 图片粘贴直发/拖拽发送）。
/// 支持 PNG / JPEG / GIF 魔数校验。
bool isSupportedImage(Uint8List bytes) {
  if (bytes.length < 4) return false;
  // PNG: 89 50 4E 47
  if (bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return true;
  }
  // JPEG: FF D8 FF
  if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return true;
  }
  // GIF: 'GIF8'
  if (bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38) {
    return true;
  }
  return false;
}

/// 文件名是否为图片（阶段 N3b：小图片自动接收，扩展名判断，大小写不敏感）。
/// 支持 PNG / JPG / JPEG / GIF。
bool isImageFilename(String filename) {
  final lower = filename.toLowerCase();
  return lower.endsWith('.png') ||
      lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.gif');
}

/// 文件名是否为视频（阶段 P1：富媒体视频气泡，大小写不敏感）。
/// 支持 MP4 / MOV / WEBM / M4V / AVI / MKV（仅按最终扩展名判定）。
bool isVideoFilename(String filename) {
  final lower = filename.toLowerCase();
  const extensions = ['.mp4', '.mov', '.webm', '.m4v', '.avi', '.mkv'];
  return extensions.any(lower.endsWith);
}

/// 文件名是否为本应用表情包贴纸（Q1 三轮问题4：通知正文显示
/// "[动画表情]"而非原始文件名，参考微信）。贴纸发送经 sendFileBytes
/// 复用图片通道，文件名恒为 StickerStore 命名 'sticker_<id>.png'。
bool isStickerFilename(String filename) {
  final base = filename.toLowerCase().split(RegExp(r'[/\\]')).last;
  return base.startsWith('sticker_') && base.endsWith('.png');
}

/// 文件字节数转人类可读大小（阶段 P1：富媒体气泡大小行）。
/// <1KB 显示整数 B；KB/MB/GB 显示 1 位小数；0 → '0 B'。
String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  return '${(mb / 1024).toStringAsFixed(1)} GB';
}

/// 自定义贴纸（阶段 P2：表情包体系）
class Sticker {
  final String id;
  final String name;

  const Sticker({required this.id, this.name = ''});

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  factory Sticker.fromJson(Map<String, dynamic> json) {
    String asStr(dynamic v) => v?.toString() ?? '';
    return Sticker(id: asStr(json['id']), name: asStr(json['name']));
  }
}

/// 表情选择分类（R-P3 修订：内置表情形式与数量向微信看齐——
/// 10 分类约 600 个；首分类 '常用' 完整包含 defaultReactionEmojis，
/// 阶段 K 表情盘不丢失）。
const List<(String, List<String>)> emojiPickerCategories = [
  (
    '常用',
    [
      '👍',
      '❤️',
      '🔥',
      '😂',
      '😮',
      '😢',
      '😡',
      '🎉',
      '👏',
      '🙏',
      '🤣',
      '😍',
      '😭',
      '😊',
      '😅',
      '👌',
      '🌹',
      '💪',
      '✌️',
      '🍉',
      '🎂',
      '⚽',
      '🎁',
      '☕',
    ]
  ),
  (
    '笑脸',
    [
      '😀',
      '😃',
      '😄',
      '😁',
      '😆',
      '🙂',
      '😉',
      '😇',
      '🥰',
      '🤩',
      '😘',
      '😗',
      '😚',
      '😙',
      '🥲',
      '😋',
      '😛',
      '😜',
      '🤪',
      '😝',
      '🤑',
      '🤗',
      '🤭',
      '🤫',
      '🤔',
      '🤐',
      '🤨',
      '😐',
      '😑',
      '😶',
      '😏',
      '😒',
      '🙄',
      '😬',
      '🤥',
      '😌',
      '😔',
      '😪',
      '🤤',
      '😴',
      '😷',
      '🤒',
      '🤕',
      '🤢',
      '🤮',
      '🥵',
      '🥶',
      '😵',
      '🤯',
      '🤠',
      '🥳',
      '🥸',
      '😎',
      '🤓',
      '🧐',
      '😕',
      '😟',
      '🙁',
      '☹️',
      '😯',
      '😲',
      '😳',
      '🥺',
      '😦',
      '😧',
      '😨',
      '😰',
      '😥',
      '😓',
      '😱',
      '😖',
      '😣',
      '😞',
      '😽',
      '💋',
      '🐱',
    ]
  ),
  (
    '手势与人',
    [
      '👋',
      '🤚',
      '🖐️',
      '✋',
      '🖖',
      '🤌',
      '🤏',
      '🤞',
      '🤟',
      '🤘',
      '🤙',
      '👈',
      '👉',
      '👆',
      '🖕',
      '👇',
      '☝️',
      '👎',
      '✊',
      '👊',
      '🤛',
      '🤜',
      '🙌',
      '👐',
      '🤲',
      '🤝',
      '🦵',
      '🦶',
      '👶',
      '👦',
      '👧',
      '👨',
      '👩',
      '🧑',
      '👴',
      '👵',
      '🙋',
      '🙇',
      '🤦',
      '🤷',
      '💃',
      '🕺',
      '🧘',
    ]
  ),
  (
    '爱心',
    [
      '💖',
      '💘',
      '💝',
      '💟',
      '🩷',
      '💙',
      '💚',
      '💛',
      '🧡',
      '💜',
      '🖤',
      '🩶',
      '🤍',
      '🤎',
      '💔',
      '❣️',
      '💕',
      '💞',
      '💓',
      '💗',
      '♥️',
      '💌',
      '💤',
      '💦',
    ]
  ),
  (
    '动物自然',
    [
      '🐶',
      '🐭',
      '🐹',
      '🐰',
      '🦊',
      '🐻',
      '🐼',
      '🐨',
      '🐯',
      '🦁',
      '🐮',
      '🐷',
      '🐸',
      '🐵',
      '🙈',
      '🙉',
      '🙊',
      '🐔',
      '🐧',
      '🐦',
      '🐤',
      '🦆',
      '🦅',
      '🦉',
      '🦇',
      '🐺',
      '🐗',
      '🐴',
      '🦄',
      '🐝',
      '🐛',
      '🦋',
      '🐌',
      '🐞',
      '🐜',
      '🕷️',
      '🦂',
      '🐢',
      '🐍',
      '🦎',
      '🐙',
      '🦑',
      '🦐',
      '🦞',
      '🦀',
      '🐡',
      '🐠',
      '🐟',
      '🐬',
      '🐳',
      '🐋',
      '🦈',
      '🌸',
      '🌺',
      '🌻',
      '🌼',
      '🌷',
      '🌴',
      '🌵',
      '🍀',
      '🍁',
      '🍂',
      '🌊',
      '⭐',
      '🌟',
      '✨',
      '⚡',
      '☀️',
      '🌙',
      '💧',
    ]
  ),
  (
    '食物',
    [
      '🍏',
      '🍎',
      '🍐',
      '🍊',
      '🍋',
      '🍌',
      '🍇',
      '🍓',
      '🫐',
      '🍈',
      '🍒',
      '🍑',
      '🥭',
      '🍍',
      '🥥',
      '🥝',
      '🍅',
      '🍆',
      '🥑',
      '🥦',
      '🥬',
      '🥒',
      '🌶️',
      '🌽',
      '🥕',
      '🧄',
      '🧅',
      '🥔',
      '🍠',
      '🥐',
      '🥯',
      '🍞',
      '🥖',
      '🧀',
      '🥚',
      '🍳',
      '🧇',
      '🥞',
      '🧈',
      '🍤',
      '🍗',
      '🍖',
      '🌭',
      '🍔',
      '🍟',
      '🍕',
      '🥪',
      '🌮',
      '🌯',
      '🥗',
      '🍜',
      '🍲',
      '🍛',
      '🍣',
      '🍱',
      '🥟',
      '🍚',
      '🍥',
      '🥠',
      '🍦',
      '🍰',
      '🧁',
      '🥧',
      '🍫',
      '🍬',
      '🍭',
      '🍩',
      '🍪',
      '🥛',
      '🍼',
      '🍵',
      '🧃',
      '🥤',
      '🍺',
      '🍻',
      '🥂',
      '🍷',
    ]
  ),
  (
    '活动',
    [
      '🏀',
      '🏈',
      '⚾',
      '🥎',
      '🎾',
      '🏐',
      '🏉',
      '🥏',
      '🎱',
      '🪀',
      '🏓',
      '🏸',
      '🥊',
      '🥋',
      '⛳',
      '⛸️',
      '🎣',
      '🤿',
      '🎿',
      '🛷',
      '🥌',
      '🎯',
      '🪁',
      '🎮',
      '🕹️',
      '🎲',
      '🧩',
      '🎰',
      '🎳',
      '🚴',
      '🏆',
      '🥇',
      '🥈',
      '🥉',
      '🏅',
      '🎖️',
      '🎗️',
      '🎫',
      '🎪',
      '🤹',
      '🎭',
      '🎨',
      '🎬',
      '🎤',
      '🎧',
      '🎼',
      '🎹',
      '🥁',
      '🎷',
      '🎺',
      '🎸',
      '🪕',
      '🎻',
    ]
  ),
  (
    '旅行',
    [
      '🚗',
      '🚕',
      '🚙',
      '🚌',
      '🚎',
      '🏎️',
      '🚓',
      '🚑',
      '🚒',
      '🚐',
      '🛻',
      '🚚',
      '🚛',
      '🚜',
      '🛵',
      '🏍️',
      '🚲',
      '🛴',
      '🚨',
      '🚔',
      '🚍',
      '🚀',
      '🛸',
      '🚁',
      '✈️',
      '🛩️',
      '🚢',
      '⛵',
      '🚤',
      '🛥️',
      '⚓',
      '🗺️',
      '🗽',
      '🗼',
      '🏰',
      '🏯',
      '🏟️',
      '🎡',
      '🎢',
      '🎠',
      '⛲',
      '⛱️',
      '🏖️',
      '🏝️',
      '🌋',
      '⛰️',
      '🏔️',
      '🗻',
      '🏕️',
      '🏠',
      '🏡',
      '🏢',
      '🏬',
      '🏣',
      '🏥',
      '🏦',
      '🏨',
      '🏪',
      '🏫',
      '💒',
      '🚉',
      '🚥',
      '🚏',
    ]
  ),
  (
    '物品',
    [
      '⌚',
      '📱',
      '💻',
      '⌨️',
      '🖥️',
      '🖨️',
      '🖱️',
      '💽',
      '💾',
      '💿',
      '📀',
      '📷',
      '📸',
      '📹',
      '🎥',
      '📞',
      '☎️',
      '📟',
      '📺',
      '📻',
      '🎙️',
      '⏰',
      '⏳',
      '📡',
      '🔋',
      '🔌',
      '💡',
      '🔦',
      '🕯️',
      '💸',
      '💵',
      '💰',
      '💳',
      '💎',
      '⚖️',
      '🔧',
      '🔨',
      '⚒️',
      '🔩',
      '⚙️',
      '🔫',
      '💣',
      '🔪',
      '🛡️',
      '🚬',
      '⚰️',
      '🔮',
      '📿',
      '⚗️',
      '🔭',
      '🔬',
      '💊',
      '💉',
      '🩹',
      '🧸',
      '📌',
      '📎',
      '📏',
      '📐',
      '✂️',
      '🔒',
      '🔓',
      '🔏',
      '🔐',
      '🔑',
      '🗝️',
      '🔔',
      '📢',
      '📯',
      '📖',
      '📚',
      '📕',
      '📗',
      '📘',
      '📙',
      '📔',
      '📒',
      '📓',
      '📃',
      '📜',
      '📄',
      '📰',
      '📑',
      '🔖',
      '💼',
      '📁',
      '📂',
      '🗂️',
      '📅',
      '📆',
      '🗒️',
      '📝',
      '📤',
      '📥',
      '🎈',
      '🎀',
      '🎊',
      '🪄',
      '🖼️',
      '🧵',
      '🧶',
      '👞',
      '👟',
      '👠',
      '👡',
      '👢',
      '👑',
      '👒',
      '🎩',
      '🎓',
      '💄',
      '💅',
      '🤳',
      '👔',
      '👕',
      '👖',
      '🧢',
    ]
  ),
  (
    '符号',
    [
      '✅',
      '❌',
      '❓',
      '❗',
      '💯',
      '🌈',
      '☑️',
      '✔️',
      '✖️',
      '✴️',
      '✳️',
      '❇️',
      '©️',
      '®️',
      '™️',
      '🔱',
      '⚜️',
      '🔰',
      '⭕',
      '🛑',
      '⛔',
      '🚫',
      '💢',
      '♨️',
      '🚭',
      '🔞',
      '📵',
      '🚯',
      '🚱',
      '🚳',
      '📶',
      '🆒️',
      '🆕',
      '🆗',
      '🆙',
      '🆓',
      '🔝',
      '🔄',
      '➕',
      '➖',
      '➗',
      '💲',
      '💱',
      'ℹ️',
      '🆔',
      'Ⓜ️',
      '🈯',
      '❎',
      '🈸',
      '🈲',
      '🉑',
      '⛩️',
      '🎏',
    ]
  ),
];

/// 模糊日期选择（R-P28 修订：托盘式年/月/日滚轮，单入口）。
/// 三档精度：仅年（month/day 皆 null）/ 年月（day 为 null）/ 年月日。
/// 每档展开为本地时间范围（from 当档起点零点 / to 当档终点 23:59:59），
/// 交由服务端 time_from/time_to 做范围搜索。
class SearchDateSelection {
  final int year;
  final int? month;
  final int? day;

  const SearchDateSelection({required this.year, this.month, this.day});

  DateTime get from =>
      month == null ? DateTime(year) : DateTime(year, month!, day ?? 1);

  DateTime get to {
    if (month == null) return DateTime(year, 12, 31, 23, 59, 59);
    if (day == null) {
      final lastDay = DateTime(year, month! + 1, 0).day;
      return DateTime(year, month!, lastDay, 23, 59, 59);
    }
    return DateTime(year, month!, day!, 23, 59, 59);
  }

  String get label => month == null
      ? '$year年'
      : (day == null ? '$year年$month月' : '$year年$month月$day日');
}

/// 复合条件消息搜索过滤（阶段 P3：按发送者/时间/关键词/会话组合检索）。
/// 会话范围由既有 to / group_id 头承载，不纳入本模型。
/// R-P28 修订：senders 多发送者（私聊双方/群成员单选多选，协议头逗号
/// 分隔——用户名字符集不含逗号）；date 模糊日期（单入口托盘，见
/// [SearchDateSelection]）。
class MessageSearchFilter {
  final String keyword;
  final List<String> senders;
  final SearchDateSelection? date;

  const MessageSearchFilter({
    this.keyword = '',
    this.senders = const [],
    this.date,
  });

  DateTime? get from => date?.from;
  DateTime? get to => date?.to;

  /// 是否携带任一过滤条件（全空时不触发搜索）
  bool get hasFilters =>
      keyword.trim().isNotEmpty || senders.isNotEmpty || date != null;

  /// 协议头契约：keyword 恒在（trim）；senders 非空才带 'sender'
  /// （逗号分隔）；date 非空才带 'time_from'/'time_to'（epoch 秒，
  /// 与 O5 schedule_at 口径一致）
  Map<String, String> toHeaders() {
    return {
      'keyword': keyword.trim(),
      if (senders.isNotEmpty) 'sender': senders.join(','),
      if (date != null)
        'time_from': (from!.millisecondsSinceEpoch ~/ 1000).toString(),
      if (date != null)
        'time_to': (to!.millisecondsSinceEpoch ~/ 1000).toString(),
    };
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
