/// 各类对话框
///
/// 包含：添加好友、创建群组、加入群组、好友请求处理、
///       文件请求处理、管理员面板、文件选择辅助等。

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/chat_models.dart';
import 'raw_text_field.dart';
import '../services/socket_service.dart';
import '../services/state_manager.dart';

// ============================================================
// 添加好友对话框
// ============================================================

void showAddFriendDialog(BuildContext context, ValueChanged<String> onAdd) {
  final ctrl = TextEditingController();
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('添加好友'),
      content: RawTextField(
        controller: ctrl,
        hintText: '好友用户名',
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final name = ctrl.text.trim();
            final valid = InputValidator.validateUsername(name);
            if (!valid.valid) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(valid.error ?? '用户名不合法')),
              );
              return;
            }
            onAdd(name);
            Navigator.pop(ctx);
          },
          child: const Text('添加'),
        ),
      ],
    ),
  );
}

// ============================================================
// 创建群组对话框
// ============================================================

void showCreateGroupDialog(
    BuildContext context, ValueChanged<String> onCreate) {
  final ctrl = TextEditingController();
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('创建群组'),
      content: RawTextField(
        controller: ctrl,
        hintText: '群组名称',
        showChineseInput: true,
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final name = ctrl.text.trim();
            if (name.isNotEmpty) {
              onCreate(name);
              Navigator.pop(ctx);
            }
          },
          child: const Text('创建'),
        ),
      ],
    ),
  );
}

// ============================================================
// 加入群组对话框
// ============================================================

void showJoinGroupDialog(BuildContext context, ValueChanged<int> onJoin) {
  final ctrl = TextEditingController();
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('加入群组'),
      content: RawTextField(
        controller: ctrl,
        hintText: '群组 ID',
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final id = int.tryParse(ctrl.text.trim());
            if (id == null || id <= 0) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('请输入有效的群组 ID')),
              );
              return;
            }
            onJoin(id);
            Navigator.pop(ctx);
          },
          child: const Text('加入'),
        ),
      ],
    ),
  );
}

// ============================================================
// 好友请求处理对话框
// ============================================================

void showFriendRequestsDialog(
  BuildContext context,
  List<String> requests,
  Function(String username, bool accept) onRespond,
) {
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('好友请求'),
      content: SizedBox(
        width: 300,
        child: requests.isEmpty
            ? const Text('暂无待处理的好友请求')
            : ListView.builder(
                shrinkWrap: true,
                itemCount: requests.length,
                itemBuilder: (_, i) {
                  final name = requests[i];
                  return ListTile(
                    leading: const Icon(Icons.person_rounded),
                    title: Text(name),
                    subtitle: const Text('请求添加您为好友'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.check, color: Colors.green),
                          tooltip: '接受',
                          onPressed: () {
                            onRespond(name, true);
                            Navigator.pop(ctx);
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.red),
                          tooltip: '拒绝',
                          onPressed: () {
                            onRespond(name, false);
                            Navigator.pop(ctx);
                          },
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

// ============================================================
// 文件请求处理对话框
// ============================================================

void showFileRequestsDialog(
  BuildContext context,
  List<FileRequest> requests,
  Function(FileRequest request, bool accept) onRespond,
) {
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('文件请求'),
      content: SizedBox(
        width: 350,
        child: requests.isEmpty
            ? const Text('暂无待处理的文件请求')
            : ListView.builder(
                shrinkWrap: true,
                itemCount: requests.length,
                itemBuilder: (_, i) {
                  final req = requests[i];
                  final sizeStr = req.filesize > 1024 * 1024
                      ? '${(req.filesize / (1024 * 1024)).toStringAsFixed(1)} MB'
                      : req.filesize > 1024
                          ? '${(req.filesize / 1024).toStringAsFixed(1)} KB'
                          : '${req.filesize} B';
                  return ListTile(
                    leading: const Icon(Icons.insert_drive_file_rounded),
                    title: Text(req.filename),
                    subtitle: Text(
                      '${req.sender} · $sizeStr${req.isGroupFile ? " · 群文件" : ""}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.check, color: Colors.green),
                          tooltip: '接受',
                          onPressed: () {
                            onRespond(req, true);
                            Navigator.pop(ctx);
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.red),
                          tooltip: '拒绝',
                          onPressed: () {
                            onRespond(req, false);
                            Navigator.pop(ctx);
                          },
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

// ============================================================
// 管理员面板
// ============================================================

void showAdminPanel(BuildContext context, SocketService service, AppState _) {
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.admin_panel_settings),
          SizedBox(width: 8),
          Text('管理面板'),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 查看所有用户
            ListTile(
              leading: const Icon(Icons.people_rounded),
              title: const Text('查看所有用户'),
              subtitle: const Text('获取在线/离线状态'),
              onTap: () {
                Navigator.pop(ctx);
                service.adminCommand('list_users');
              },
            ),
            const Divider(),
            // 发送公告
            ListTile(
              leading: const Icon(Icons.campaign_rounded),
              title: const Text('发送系统公告'),
              onTap: () {
                Navigator.pop(ctx);
                _showAnnouncementDialog(context, service);
              },
            ),
            const Divider(),
            // 删除用户
            ListTile(
              leading: const Icon(Icons.person_remove_rounded),
              title: const Text('删除用户'),
              onTap: () {
                Navigator.pop(ctx);
                _showDeleteUserDialog(context, service);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

void _showAnnouncementDialog(BuildContext context, SocketService service) {
  final ctrl = TextEditingController();
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('发送系统公告'),
      content: RawTextField(
        controller: ctrl,
        hintText: '公告内容',
        showChineseInput: true,
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final text = ctrl.text.trim();
            if (text.isNotEmpty) {
              service.adminCommand('announcement', announcement: text);
              Navigator.pop(ctx);
            }
          },
          child: const Text('发送'),
        ),
      ],
    ),
  );
}

void _showDeleteUserDialog(BuildContext context, SocketService service) {
  final ctrl = TextEditingController();
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('删除用户'),
      content: RawTextField(
        controller: ctrl,
        hintText: '要删除的用户名',
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () {
            final name = ctrl.text.trim();
            final valid = InputValidator.validateUsername(name);
            if (!valid.valid) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(valid.error ?? '用户名不合法')),
              );
              return;
            }
            service.adminCommand('delete_user', targetUser: name);
            Navigator.pop(ctx);
          },
          child: const Text('删除'),
        ),
      ],
    ),
  );
}

// ============================================================
// 文件选择器（使用 file_picker 打开原生文件选择对话框）
// ============================================================

/// 返回所选文件的 (path, name)，null 表示取消
Future<({String path, String name})?> showFilePicker(
    BuildContext context) async {
  try {
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.isEmpty) return null;

    final file = result.files.single;
    final path = file.path;
    if (path == null) return null;

    return (path: path, name: file.name);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('文件选择失败: $e')),
      );
    }
    return null;
  }
}

// ============================================================
// 删除好友确认对话框（阶段 F）
// ============================================================

void showDeleteFriendDialog(
    BuildContext context, String username, VoidCallback onDelete) {
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('删除好友'),
      content: Text('确定删除好友 $username 吗？\n删除后双方的好友关系将解除。'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () {
            onDelete();
            Navigator.pop(ctx);
          },
          child: const Text('删除'),
        ),
      ],
    ),
  );
}

// ============================================================
// 群组菜单对话框（阶段 F）
// ============================================================

void showGroupMenuDialog(
  BuildContext context,
  Group group,
  void Function(Group group) onShowMembers,
  void Function(int groupId) onLeaveGroup,
) {
  final state = AppState.instance;
  showDialog(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: state,
      builder: (ctx, _) {
        final current = state.groups.where((g) => g.id == group.id).firstOrNull;
        final members = current?.members ?? group.members;
        return AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.group_rounded),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  group.displayName,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 300,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.people_rounded),
                  title: const Text('群成员'),
                  subtitle: Text(members.isEmpty
                      ? '加载中…'
                      : '${members.length} 人'),
                  onTap: () {
                    Navigator.pop(ctx);
                    onShowMembers(group);
                  },
                ),
                const Divider(),
                ListTile(
                  leading: Icon(Icons.exit_to_app_rounded,
                      color: Colors.red.shade400),
                  title: Text('退出群组',
                      style: TextStyle(color: Colors.red.shade400)),
                  onTap: () {
                    Navigator.pop(ctx);
                    onLeaveGroup(group.id);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
          ],
        );
      },
    ),
  );
}

// ============================================================
// 群组信息对话框（阶段 F）
// ============================================================

void showGroupInfoDialog(BuildContext context, Group group) {
  final state = AppState.instance;
  showDialog(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: state,
      builder: (ctx, _) {
        final current = state.groups.where((g) => g.id == group.id).firstOrNull;
        final members = current?.members ?? group.members;
        return AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.group_rounded),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '群信息 - ${group.displayName}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 320,
            child: members.isEmpty
                ? const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(height: 12),
                      CircularProgressIndicator(strokeWidth: 2),
                      SizedBox(height: 12),
                      Text('加载成员列表中…'),
                    ],
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: members.length,
                    itemBuilder: (_, i) {
                      final member = members[i];
                      final isCreator = members.isNotEmpty && i == 0;
                      return ListTile(
                        leading: CircleAvatar(
                          radius: 16,
                          child: Text(member.isNotEmpty
                              ? member[0].toUpperCase()
                              : '?'),
                        ),
                        title: Text(member),
                        subtitle: isCreator
                            ? const Text('创建者',
                                style: TextStyle(fontSize: 12))
                            : null,
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    ),
  );
}
