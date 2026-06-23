/// 会话侧边栏
///
/// 显示好友列表和群组列表，支持选择和操作按钮。

import 'package:flutter/material.dart';

import '../models/chat_models.dart';

class Sidebar extends StatelessWidget {
  final List<ChatTarget> chatTargets;
  final String? currentChat;
  final ValueChanged<String> onSelectChat;
  final VoidCallback onAddFriend;
  final VoidCallback onCreateGroup;
  final VoidCallback onJoinGroup;

  const Sidebar({
    super.key,
    required this.chatTargets,
    required this.currentChat,
    required this.onSelectChat,
    required this.onAddFriend,
    required this.onCreateGroup,
    required this.onJoinGroup,
  });

  @override
  Widget build(BuildContext context) {
    // 分组：好友 vs 群组
    final friends =
        chatTargets.where((t) => !t.isGroup).toList();
    final groups =
        chatTargets.where((t) => t.isGroup).toList();

    return SizedBox(
      width: 250,
      child: Column(
        children: [
          // 工具栏
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              border: const Border(bottom: BorderSide(color: Color(0xFFE0E0E0))),
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
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                ),
                IconButton(
                  icon: const Icon(Icons.group_add, size: 20),
                  tooltip: '创建群组',
                  onPressed: onCreateGroup,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                ),
                IconButton(
                  icon: const Icon(Icons.login_rounded, size: 20),
                  tooltip: '加入群组',
                  onPressed: onJoinGroup,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                ),
              ],
            ),
          ),

          // 列表
          Expanded(
            child: ListView(
              children: [
                // 好友分组
                if (friends.isNotEmpty) ...[
                  _SectionHeader(title: '好友 (${friends.length})'),
                  ...friends.map((f) => _ChatTile(
                        target: f,
                        isSelected: currentChat == f.key,
                        onTap: () => onSelectChat(f.key),
                      )),
                ],
                // 群组分组
                if (groups.isNotEmpty) ...[
                  _SectionHeader(title: '群组 (${groups.length})'),
                  ...groups.map((g) => _ChatTile(
                        target: g,
                        isSelected: currentChat == g.key,
                        onTap: () => onSelectChat(g.key),
                      )),
                ],
                if (friends.isEmpty && groups.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      '暂无会话\n点击上方按钮添加好友或群组',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
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
  final VoidCallback onTap;

  const _ChatTile({
    required this.target,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      selected: isSelected,
      selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
      leading: Icon(
        target.isGroup ? Icons.group_rounded : Icons.person_rounded,
        color: isSelected
            ? Theme.of(context).colorScheme.primary
            : Colors.grey[600],
      ),
      title: Text(
        target.displayName,
        style: TextStyle(
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      dense: true,
      onTap: onTap,
    );
  }
}
