/// 会话侧边栏
///
/// 显示好友列表和群组列表，支持选择和操作按钮。

import 'package:flutter/material.dart';

import '../models/chat_models.dart';
import '../services/state_manager.dart';

class Sidebar extends StatelessWidget {
  final List<ChatTarget> chatTargets;
  final String? currentChat;
  final ValueChanged<String> onSelectChat;
  final VoidCallback onAddFriend;
  final VoidCallback onCreateGroup;
  final VoidCallback onJoinGroup;
  final int Function(String key) unreadOf;
  final void Function(String username)? onDeleteFriend;
  final void Function(ChatTarget target)? onGroupLongPress;

  /// 阶段 J：好友在线状态判定（null = 不显示在线标记，回归兼容）
  final bool Function(String key)? isOnline;

  /// 阶段 J：好友分组（分组名 → 好友 key 列表；null = 扁平渲染，回归兼容）
  final Map<String, List<String>>? friendGroups;

  const Sidebar({
    super.key,
    required this.chatTargets,
    required this.currentChat,
    required this.onSelectChat,
    required this.onAddFriend,
    required this.onCreateGroup,
    required this.onJoinGroup,
    required this.unreadOf,
    this.onDeleteFriend,
    this.onGroupLongPress,
    this.isOnline,
    this.friendGroups,
  });

  @override
  Widget build(BuildContext context) {
    // 分组：好友 vs 群组
    final systemTargets = chatTargets.where((t) => t.key == '服务器').toList();
    final friends =
        chatTargets.where((t) => !t.isGroup && t.key != '服务器').toList();
    final groups = chatTargets.where((t) => t.isGroup).toList();

    return Container(
      width: 270,
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          // 工具栏
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              border:
                  const Border(bottom: BorderSide(color: Color(0xFFE0E0E0))),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '会话',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.person_add, size: 20),
                  tooltip: '添加好友',
                  onPressed: onAddFriend,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 36, minHeight: 36),
                ),
                IconButton(
                  icon: const Icon(Icons.group_add, size: 20),
                  tooltip: '创建群组',
                  onPressed: onCreateGroup,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 36, minHeight: 36),
                ),
                IconButton(
                  icon: const Icon(Icons.login_rounded, size: 20),
                  tooltip: '加入群组',
                  onPressed: onJoinGroup,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 36, minHeight: 36),
                ),
              ],
            ),
          ),

          // 列表
          Expanded(
            child: ListView(
              children: [
                if (systemTargets.isNotEmpty) ...[
                  const _SectionHeader(title: '系统'),
                  ...systemTargets.map((s) => _ChatTile(
                        target: s,
                        isSelected: currentChat == s.key,
                        unread: unreadOf(s.key),
                        onTap: () => onSelectChat(s.key),
                      )),
                ],
                // 好友分区（阶段 J4：提供 friendGroups 时按分组渲染）
                if (friendGroups != null && friends.isNotEmpty) ...[
                  for (final entry in friendGroups!.entries) ...[
                    if (entry.value.any((k) => friends.any((f) => f.key == k)))
                      _SectionHeader(title: entry.key),
                    ...entry.value
                        .where((k) => friends.any((f) => f.key == k))
                        .map((k) => friends.firstWhere((f) => f.key == k))
                        .map((f) => _ChatTile(
                              target: f,
                              isSelected: currentChat == f.key,
                              unread: unreadOf(f.key),
                              isOnline: isOnline,
                              onTap: () => onSelectChat(f.key),
                              onLongPress: onDeleteFriend != null
                                  ? () => onDeleteFriend!(f.key)
                                  : null,
                            )),
                  ],
                  // 未分组好友
                  ..._renderUngroupedFriends(friends),
                ] else if (friends.isNotEmpty) ...[
                  _SectionHeader(title: '好友 (${friends.length})'),
                  ...friends.map((f) => _ChatTile(
                        target: f,
                        isSelected: currentChat == f.key,
                        unread: unreadOf(f.key),
                        isOnline: isOnline,
                        onTap: () => onSelectChat(f.key),
                        onLongPress: onDeleteFriend != null
                            ? () => onDeleteFriend!(f.key)
                            : null,
                      )),
                ],
                // 群组分组
                if (groups.isNotEmpty) ...[
                  _SectionHeader(title: '群组 (${groups.length})'),
                  ...groups.map((g) => _ChatTile(
                        target: g,
                        isSelected: currentChat == g.key,
                        unread: unreadOf(g.key),
                        onTap: () => onSelectChat(g.key),
                        onLongPress: onGroupLongPress != null
                            ? () => onGroupLongPress!(g)
                            : null,
                      )),
                ],
                if (systemTargets.isEmpty && friends.isEmpty && groups.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        Icon(
                          Icons.forum_outlined,
                          size: 40,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '暂无会话\n点击上方按钮添加好友或群组',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 未分组好友渲染（阶段 J4）：分组参数提供时，不在任何分组中的好友
  /// 归入 AppState.ungroupedLabel（"未分组"）分区
  List<Widget> _renderUngroupedFriends(List<ChatTarget> friends) {
    final groupedKeys = <String>{};
    friendGroups?.forEach((_, keys) => groupedKeys.addAll(keys));
    final ungrouped =
        friends.where((f) => !groupedKeys.contains(f.key)).toList();
    if (ungrouped.isEmpty) return const [];
    return [
      const _SectionHeader(title: AppState.ungroupedLabel),
      ...ungrouped.map((f) => _ChatTile(
            target: f,
            isSelected: currentChat == f.key,
            unread: unreadOf(f.key),
            isOnline: isOnline,
            onTap: () => onSelectChat(f.key),
            onLongPress:
                onDeleteFriend != null ? () => onDeleteFriend!(f.key) : null,
          )),
    ];
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Colors.grey[600],
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

class _ChatTile extends StatelessWidget {
  final ChatTarget target;
  final bool isSelected;
  final int unread;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// 阶段 J：在线状态判定（null = 不显示在线标记）
  final bool Function(String key)? isOnline;

  const _ChatTile({
    required this.target,
    required this.isSelected,
    required this.unread,
    required this.onTap,
    this.onLongPress,
    this.isOnline,
  });

  @override
  Widget build(BuildContext context) {
    // 阶段 J：仅好友会话显示在线标记（群组/系统会话不显示）
    final showOnlineDot =
        isOnline != null && !target.isGroup && target.key != '服务器';
    final online = showOnlineDot && isOnline!(target.key);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: ListTile(
          selected: isSelected,
          onLongPress: onLongPress,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
          leading: Icon(
            target.key == '服务器'
                ? Icons.notifications_rounded
                : target.isGroup
                    ? Icons.group_rounded
                    : Icons.person_rounded,
            color: isSelected
                ? Theme.of(context).colorScheme.primary
                : Colors.grey[600],
          ),
          title: Text(
            target.displayName,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showOnlineDot)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Icon(
                    Icons.circle,
                    size: 10,
                    color: online ? Colors.green : Colors.grey,
                  ),
                ),
              if (unread > 0)
                Badge(
                  label: Text('$unread'),
                  isLabelVisible: true,
                ),
            ],
          ),
          dense: true,
          onTap: onTap,
        ),
      ),
    );
  }
}
