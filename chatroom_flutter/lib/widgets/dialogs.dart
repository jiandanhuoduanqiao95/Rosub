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
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final name = ctrl.text.trim();
            if (name.isNotEmpty) {
              onAdd(name);
              Navigator.pop(ctx);
            }
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
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
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
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final id = int.tryParse(ctrl.text.trim());
            if (id != null) {
              onJoin(id);
              Navigator.pop(ctx);
            }
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
                  final sizeStr =
                      req.filesize > 1024 * 1024
                          ? '${(req.filesize / (1024 * 1024)).toStringAsFixed(1)} MB'
                          : req.filesize > 1024
                              ? '${(req.filesize / 1024).toStringAsFixed(1)} KB'
                              : '${req.filesize} B';
                  return ListTile(
                    leading:
                        const Icon(Icons.insert_drive_file_rounded),
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

void showAdminPanel(
    BuildContext context, SocketService service, AppState state) {
  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setDialogState) {
        return AlertDialog(
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
                  leading:
                      const Icon(Icons.people_rounded),
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
        );
      },
    ),
  );
}

void _showAnnouncementDialog(
    BuildContext context, SocketService service) {
  final ctrl = TextEditingController();
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('发送系统公告'),
      content: RawTextField(
        controller: ctrl,
        hintText: '公告内容',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
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

void _showDeleteUserDialog(
    BuildContext context, SocketService service) {
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
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () {
            final name = ctrl.text.trim();
            if (name.isNotEmpty) {
              service.adminCommand('delete_user', targetUser: name);
              Navigator.pop(ctx);
            }
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
