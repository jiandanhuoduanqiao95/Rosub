/// 各类对话框
///
/// 包含：添加好友、创建群组、加入群组、好友请求处理、
///       文件请求处理、管理员面板、文件选择辅助等。

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/chat_models.dart';
import 'raw_text_field.dart';
import '../services/socket_service.dart';
import '../services/state_manager.dart';

// ============================================================
// 用户资料对话框（阶段 J：P0-2）
// ============================================================

void showProfileDialog(
  BuildContext context, {
  required String username,
  UserProfile? profile,
  VoidCallback? onEdit,
  VoidCallback? onRefresh,
}) {
  showDialog(
    context: context,
    builder: (ctx) => ListenableBuilder(
      // 阶段 J 修复：fetchProfile 为异步拉取，资料响应到达（updateProfile 通知）
      // 后对话框实时刷新——否则首次点击恒为"资料加载中"，需二次点击才显示
      listenable: AppState.instance,
      builder: (ctx, _) {
        final current = AppState.instance.profileOf(username) ?? profile;
        return AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.account_circle_rounded),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  current?.displayName ?? username,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(username),
                if (current != null && current.signature.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(current.signature),
                ],
                if (current?.lastSeen != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    '最后在线: '
                    '${DateFormat('yyyy-MM-dd HH:mm').format(current!.lastSeen!.toLocal())}',
                  ),
                ],
                if (current == null) ...[
                  const SizedBox(height: 8),
                  Text(
                    '资料加载中…',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            if (onRefresh != null)
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: '刷新',
                onPressed: onRefresh,
              ),
            if (onEdit != null)
              IconButton(
                icon: const Icon(Icons.edit),
                tooltip: '编辑资料',
                onPressed: onEdit,
              ),
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

// ============================================================
// 用户搜索对话框（阶段 J：P1-10）
// ============================================================

void showUserSearchDialog(
  BuildContext context, {
  required void Function(String keyword) onSearch,
  required void Function(String username, String message, String note) onAdd,
}) {
  final ctrl = TextEditingController();
  final state = AppState.instance;
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('搜索用户'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: RawTextField(
                    controller: ctrl,
                    hintText: '输入用户名关键字',
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  // 阶段 J 修复：应用主题 FilledButton.minimumSize =
                  // Size.fromHeight(46)（宽度 Infinity）在对话框
                  // IntrinsicWidth 测量阶段（无界宽度）会触发
                  // "BoxConstraints forces an infinite width" 崩溃——
                  // 显式有限最小尺寸覆盖（高度保持 46 与主题一致）
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(80, 46),
                  ),
                  onPressed: () {
                    final keyword = ctrl.text.trim();
                    if (keyword.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('请输入搜索关键字')),
                      );
                      return;
                    }
                    onSearch(keyword);
                  },
                  child: const Text('搜索'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ListenableBuilder(
              listenable: state,
              builder: (ctx, _) {
                final results = state.userSearchResults;
                if (results.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text('暂无结果'),
                  );
                }
                return SizedBox(
                  height: 220,
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: results.length,
                    itemBuilder: (_, i) {
                      final name = results[i];
                      return ListTile(
                        dense: true,
                        leading: const Icon(Icons.person_rounded),
                        title: Text(name),
                        onTap: () {
                          _showAddFriendMessageDialog(ctx, name, onAdd);
                        },
                      );
                    },
                  ),
                );
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

void _showAddFriendMessageDialog(
  BuildContext context,
  String username,
  void Function(String username, String message, String note) onAdd,
) {
  final ctrl = TextEditingController();
  final noteCtrl = TextEditingController();
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('添加好友 $username'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 阶段 J：发送请求时可询问是否为对方取备注名（对方接受后自动设置）
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('是否为对方取备注名？', style: TextStyle(fontSize: 13)),
          ),
          const SizedBox(height: 4),
          RawTextField(
            controller: noteCtrl,
            hintText: '备注名（可选）',
            showChineseInput: true,
          ),
          const SizedBox(height: 8),
          RawTextField(
            controller: ctrl,
            hintText: '验证消息（可选）',
            showChineseInput: true,
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final message = ctrl.text.trim();
            final note = noteCtrl.text.trim();
            onAdd(username, message, note);
            Navigator.pop(ctx);
          },
          child: const Text('确定'),
        ),
      ],
    ),
  );
}

// ============================================================
// 拉黑确认对话框（阶段 J：P1-9）
// ============================================================

void showBlockConfirmDialog(
    BuildContext context, String username, VoidCallback onBlock) {
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('拉黑确认'),
      content: Text('确定将 $username 加入黑名单吗？\n'
          '拉黑后对方将无法给您发送消息、文件或好友请求，也看不到您的在线状态。'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () {
            onBlock();
            Navigator.pop(ctx);
          },
          child: const Text('拉黑'),
        ),
      ],
    ),
  );
}

// ============================================================
// 好友管理对话框（阶段 J：P1-8/9）
// ============================================================

void showFriendManageDialog(
  BuildContext context,
  String username, {
  required VoidCallback onViewProfile,
  required VoidCallback onSetNote,
  required VoidCallback onSetGroup,
  required VoidCallback onBlock,
  required VoidCallback onUnblock,
  required VoidCallback onDelete,
}) {
  final state = AppState.instance;
  showDialog(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: state,
      builder: (ctx, _) {
        final blocked = state.isBlocked(username);
        return AlertDialog(
          title: Text('好友管理 - $username'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                dense: true,
                leading: const Icon(Icons.account_circle_rounded),
                title: const Text('查看资料'),
                onTap: () {
                  Navigator.pop(ctx);
                  onViewProfile();
                },
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.edit_note_rounded),
                title: const Text('设置备注'),
                onTap: () {
                  Navigator.pop(ctx);
                  onSetNote();
                },
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.folder_outlined),
                title: const Text('设置分组'),
                onTap: () {
                  Navigator.pop(ctx);
                  onSetGroup();
                },
              ),
              const Divider(),
              Text(
                '确定删除好友 $username 吗？\n删除后双方的好友关系将解除。',
                style: const TextStyle(fontSize: 14),
              ),
            ],
          ),
          actions: [
            if (blocked)
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  onUnblock();
                },
                child: const Text('解除拉黑'),
              )
            else
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  onBlock();
                },
                child: const Text('拉黑'),
              ),
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              // 删除确认文本已在此对话框内容中展示，直接触发删除
              onPressed: () {
                Navigator.pop(ctx);
                onDelete();
              },
              child: const Text('删除'),
            ),
          ],
        );
      },
    ),
  );
}

// ============================================================
// 设置备注 / 设置分组对话框（阶段 J：P1-8）
// ============================================================

void showSetFriendNoteDialog(
    BuildContext context, String username, ValueChanged<String> onSave) {
  final ctrl = TextEditingController();
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('设置备注 - $username'),
      content: RawTextField(
        controller: ctrl,
        hintText: '备注名（留空清除）',
        showChineseInput: true,
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            onSave(ctrl.text.trim());
            Navigator.pop(ctx);
          },
          child: const Text('保存'),
        ),
      ],
    ),
  );
}

void showSetFriendGroupDialog(
    BuildContext context, String username, ValueChanged<String> onSave) {
  final ctrl = TextEditingController();
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('设置分组 - $username'),
      content: RawTextField(
        controller: ctrl,
        hintText: '分组名（留空移回未分组）',
        showChineseInput: true,
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            onSave(ctrl.text.trim());
            Navigator.pop(ctx);
          },
          child: const Text('保存'),
        ),
      ],
    ),
  );
}

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
  void Function(String username, bool accept, String note) onRespond,
) {
  final state = AppState.instance;
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
                  // 阶段 J：展示请求者附带的验证消息（P1-10）
                  final message = state.pendingRequestMessageOf(name) ?? '';
                  return ListTile(
                    leading: const Icon(Icons.person_rounded),
                    title: Text(name),
                    subtitle: Text(
                      message.isNotEmpty ? '验证消息: $message' : '请求添加您为好友',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.check, color: Colors.green),
                          tooltip: '接受',
                          onPressed: () {
                            // 阶段 J：接受时询问是否添加备注（P1-8）
                            Navigator.pop(ctx);
                            _showAcceptNoteDialog(context, name, onRespond);
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.red),
                          tooltip: '拒绝',
                          onPressed: () {
                            onRespond(name, false, '');
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

void _showAcceptNoteDialog(
  BuildContext context,
  String username,
  void Function(String username, bool accept, String note) onRespond,
) {
  final ctrl = TextEditingController();
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('接受好友请求 - $username'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('是否添加备注？'),
          const SizedBox(height: 8),
          RawTextField(
            controller: ctrl,
            hintText: '备注名（可选，留空跳过）',
            showChineseInput: true,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            onRespond(username, true, '');
            Navigator.pop(ctx);
          },
          child: const Text('跳过'),
        ),
        FilledButton(
          onPressed: () {
            final note = ctrl.text.trim();
            onRespond(username, true, note);
            Navigator.pop(ctx);
          },
          child: const Text('确定'),
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
            const Divider(),
            // 重置用户密码（阶段 J：P0-5）
            ListTile(
              leading: const Icon(Icons.password_rounded),
              title: const Text('重置用户密码'),
              subtitle: const Text('无需旧密码，直接重置'),
              onTap: () {
                Navigator.pop(ctx);
                _showResetPasswordDialog(context, service);
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

void _showResetPasswordDialog(BuildContext context, SocketService service) {
  final userCtrl = TextEditingController();
  final pwCtrl = TextEditingController();
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('重置用户密码'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RawTextField(
              controller: userCtrl,
              hintText: '目标用户名',
            ),
            const SizedBox(height: 8),
            RawTextField(
              controller: pwCtrl,
              hintText: '新密码（6-128 位，无控制字符）',
              obscureText: true,
              showVisibilityToggle: true,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () {
            final username = userCtrl.text.trim();
            final newPassword = pwCtrl.text;
            final valid = InputValidator.validatePassword(newPassword);
            if (!valid.valid) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(valid.error ?? '新密码不合法')),
              );
              return;
            }
            service.adminResetPassword(username, newPassword);
            Navigator.pop(ctx);
          },
          child: const Text('重置'),
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
// 修改密码对话框（阶段 G3）
// ============================================================

void showChangePasswordDialog(BuildContext context, SocketService service) {
  final oldCtrl = TextEditingController();
  final newCtrl = TextEditingController();
  final confirmCtrl = TextEditingController();
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('修改密码'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RawTextField(
              controller: oldCtrl,
              hintText: '当前密码',
              obscureText: true,
              showVisibilityToggle: true,
            ),
            const SizedBox(height: 8),
            RawTextField(
              controller: newCtrl,
              hintText: '新密码',
              obscureText: true,
              showVisibilityToggle: true,
            ),
            const SizedBox(height: 8),
            RawTextField(
              controller: confirmCtrl,
              hintText: '确认新密码',
              obscureText: true,
              showVisibilityToggle: true,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final old = oldCtrl.text;
            final newPw = newCtrl.text;
            final confirm = confirmCtrl.text;
            final valid = InputValidator.validatePassword(newPw);
            if (!valid.valid) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(valid.error ?? '新密码不合法')),
              );
              return;
            }
            if (newPw != confirm) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('两次输入的新密码不一致')),
              );
              return;
            }
            service.changePassword(old, newPw);
            Navigator.pop(ctx);
          },
          child: const Text('确认'),
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
                  subtitle:
                      Text(members.isEmpty ? '加载中…' : '${members.length} 人'),
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
                            ? const Text('创建者', style: TextStyle(fontSize: 12))
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
