/// 各类对话框
///
/// 包含：添加好友、创建群组、加入群组、好友请求处理、
///       文件请求处理、管理员面板、文件选择辅助等。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/chat_models.dart';
import '../l10n/app_strings.dart';
import 'raw_text_field.dart';
import '../services/doc_preview.dart';
import '../services/quick_reply_store.dart';
import '../services/socket_service.dart';
import '../services/sticker_store.dart';
import '../services/state_manager.dart';
import '../services/taskbar_notifier.dart';
import '../services/theme_settings.dart';

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
  // 阶段 K1/K3：置顶与静音入口（未提供回调时不渲染，回归兼容）
  bool pinned = false,
  bool muted = false,
  ValueChanged<bool>? onTogglePin,
  ValueChanged<bool>? onToggleMute,
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
              // 阶段 K1：置顶/取消置顶
              if (onTogglePin != null)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.push_pin),
                  title: Text(pinned ? '取消置顶' : '置顶'),
                  onTap: () {
                    Navigator.pop(ctx);
                    onTogglePin(!pinned);
                  },
                ),
              // 阶段 K3：静音/取消静音
              if (onToggleMute != null)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.notifications_off_outlined),
                  title: Text(muted ? '取消静音' : '静音'),
                  onTap: () {
                    Navigator.pop(ctx);
                    onToggleMute(!muted);
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
      // 阶段 M（P1-17 申请制）：输入群组 ID 后发送入群申请，由群主审批
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RawTextField(
            controller: ctrl,
            hintText: '群组 ID',
          ),
          const SizedBox(height: 8),
          const Text('申请后将由群主审批，批准后方可加入',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
        ],
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
          child: const Text('申请加入'),
        ),
      ],
    ),
  );
}

/// 入群申请验证消息输入对话框（P-11 用户反馈：申请可附验证消息）
void _showJoinMessageDialog(
  BuildContext context,
  int groupId,
  String groupName,
  void Function(int groupId, String message) onRequestJoin,
) {
  final ctrl = TextEditingController();
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('申请加入群组'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('群组: $groupName', style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 8),
          RawTextField(
            controller: ctrl,
            hintText: '验证消息（选填，群主审批时可见）',
            showChineseInput: true,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            onRequestJoin(groupId, ctrl.text.trim());
            Navigator.pop(ctx);
          },
          child: const Text('发送申请'),
        ),
      ],
    ),
  );
}

// ============================================================
// 群组搜索对话框（阶段 M：P-11 用户反馈的群组搜索入口）
// ============================================================

void showGroupSearchDialog(
  BuildContext context, {
  required void Function(String keyword) onSearch,
  required void Function(int groupId, String message) onRequestJoin,
}) {
  final ctrl = TextEditingController();
  final idCtrl = TextEditingController();
  final state = AppState.instance;
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('搜索群组'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: RawTextField(
                    controller: ctrl,
                    hintText: '输入群组名称关键字',
                    showChineseInput: true,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
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
                final results = state.groupSearchResults;
                if (results.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text('暂无结果', style: TextStyle(color: Colors.grey)),
                  );
                }
                return SizedBox(
                  height: 220,
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: results.length,
                    itemBuilder: (_, i) {
                      final g = results[i];
                      return ListTile(
                        dense: true,
                        leading: const Icon(Icons.group_rounded),
                        title: Text(g.name, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          'ID:${g.id} · 群主:${g.owner.isEmpty ? '?' : g.owner}'
                          ' · ${g.memberCount} 人',
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: FilledButton.tonal(
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(72, 34),
                            padding: EdgeInsets.zero,
                          ),
                          onPressed: () {
                            // P-11 用户反馈：申请可附验证消息（仿好友申请）
                            _showJoinMessageDialog(
                                ctx, g.id, g.name, onRequestJoin);
                          },
                          child: const Text('申请加入'),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
            const Divider(),
            Row(
              children: [
                Expanded(
                  child: RawTextField(
                    controller: idCtrl,
                    hintText: '或输入群组 ID 申请加入',
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(72, 46),
                  ),
                  onPressed: () {
                    final id = int.tryParse(idCtrl.text.trim());
                    if (id == null || id <= 0) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('请输入有效的群组 ID')),
                      );
                      return;
                    }
                    _showJoinMessageDialog(ctx, id, '群组 $id', onRequestJoin);
                  },
                  child: const Text('申请'),
                ),
              ],
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
        child: SingleChildScrollView(
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
              const Divider(),
              // 服务端状态面板（阶段 M4：P1-19）+ 存储治理（阶段 M6：P1-21）
              ListTile(
                leading: const Icon(Icons.monitor_heart_outlined),
                title: const Text('服务端状态'),
                subtitle: const Text('在线/存储/磁盘/日志 + 存储清理'),
                onTap: () {
                  Navigator.pop(ctx);
                  showServerStatusDialog(context, service);
                },
              ),
              const Divider(),
              // 审计日志（阶段 N7：P2-7 敏感操作记录）
              ListTile(
                leading: const Icon(Icons.receipt_long_rounded),
                title: const Text('审计日志'),
                subtitle: const Text('删除用户/重置密码/公告/群组治理记录'),
                onTap: () {
                  Navigator.pop(ctx);
                  showAuditLogDialog(context, service);
                },
              ),
            ],
          ),
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
  void Function(int groupId) onLeaveGroup, {
  // 阶段 K1/K3：置顶与静音入口（未提供回调时不渲染，回归兼容）
  bool pinned = false,
  bool muted = false,
  ValueChanged<bool>? onTogglePin,
  ValueChanged<bool>? onToggleMute,
  // 阶段 M1：群管理入口（仅群主提供回调时渲染）
  VoidCallback? onAdmin,
  // 阶段 O1：群公告编辑入口（仅群主提供回调时渲染）
  VoidCallback? onAnnouncement,
}) {
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
                // 阶段 K1：置顶/取消置顶
                if (onTogglePin != null)
                  ListTile(
                    leading: const Icon(Icons.push_pin),
                    title: Text(pinned ? '取消置顶' : '置顶'),
                    onTap: () {
                      Navigator.pop(ctx);
                      onTogglePin(!pinned);
                    },
                  ),
                // 阶段 K3：静音/取消静音
                if (onToggleMute != null)
                  ListTile(
                    leading: const Icon(Icons.notifications_off_outlined),
                    title: Text(muted ? '取消静音' : '静音'),
                    onTap: () {
                      Navigator.pop(ctx);
                      onToggleMute(!muted);
                    },
                  ),
                // 阶段 O1：群公告（仅群主提供回调时渲染）
                if (onAnnouncement != null)
                  ListTile(
                    leading: const Icon(Icons.campaign_rounded),
                    title: const Text('群公告'),
                    onTap: () {
                      Navigator.pop(ctx);
                      onAnnouncement();
                    },
                  ),
                // 阶段 M1：群管理（群主可见：踢人/转让/改名/审批/邀请）
                if (onAdmin != null)
                  ListTile(
                    leading: const Icon(Icons.admin_panel_settings),
                    title: const Text('群管理'),
                    onTap: () {
                      Navigator.pop(ctx);
                      onAdmin();
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

// ============================================================
// 设置对话框（阶段 K3：P1-13/14 提示音 + 免打扰）
// ============================================================

void showSettingsDialog(BuildContext context) {
  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final dndEnd = TaskbarNotifier.dndEndTime;
        return AlertDialog(
          title: const Text('设置'),
          // 阶段 O7：设置项增多（深色模式/字体/主题色/背景），内容可滚动
          // 避免免打扰时段展开后溢出（K3 回归保护）
          content: SizedBox(
            width: 380,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('提示音'),
                    value: TaskbarNotifier.soundEnabled,
                    onChanged: (v) =>
                        setState(() => TaskbarNotifier.soundEnabled = v),
                  ),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('免打扰'),
                    subtitle: TaskbarNotifier.dndEnabled
                        ? Text(
                            '至 ${DateFormat('yyyy-MM-dd HH:mm').format(dndEnd)} 自动结束',
                            style: const TextStyle(fontSize: 12),
                          )
                        : null,
                    value: TaskbarNotifier.dndEnabled,
                    onChanged: (v) => setState(() {
                      TaskbarNotifier.dndEnabled = v;
                      if (v) TaskbarNotifier.ensureDndEndInFuture();
                    }),
                  ),
                  if (TaskbarNotifier.dndEnabled)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Text('结束日期'),
                              const SizedBox(width: 8),
                              TextButton.icon(
                                icon: const Icon(Icons.calendar_month_rounded,
                                    size: 18),
                                label: Text(DateFormat('yyyy-MM-dd')
                                    .format(TaskbarNotifier.dndEndTime)),
                                onPressed: () async {
                                  final now = DateTime.now();
                                  final firstDate =
                                      DateTime(now.year, now.month, now.day);
                                  final lastDate = DateTime(
                                      now.year + 1, now.month, now.day);
                                  final dndEnd = TaskbarNotifier.dndEndTime;
                                  final picked = await showDatePicker(
                                    context: ctx,
                                    // 防御：dndEndTime 早于今天（如跨天后未到期巡检）
                                    // 时钳制为今天，避免 initialDate < firstDate 断言崩溃
                                    initialDate: dndEnd.isBefore(firstDate)
                                        ? firstDate
                                        : dndEnd,
                                    firstDate: firstDate,
                                    lastDate: lastDate,
                                  );
                                  if (picked != null) {
                                    final old = TaskbarNotifier.dndEndTime;
                                    TaskbarNotifier.dndEndTime = DateTime(
                                      picked.year,
                                      picked.month,
                                      picked.day,
                                      old.hour,
                                      old.minute,
                                    );
                                    if (ctx.mounted) setState(() {});
                                  }
                                },
                              ),
                            ],
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Text('结束时刻'),
                              const SizedBox(width: 8),
                              DropdownButton<int>(
                                value: TaskbarNotifier.dndEndTime.hour,
                                items: [
                                  for (var h = 0; h < 24; h++)
                                    DropdownMenuItem(
                                        value: h, child: Text('$h 时')),
                                ],
                                onChanged: (h) {
                                  if (h != null) {
                                    final old = TaskbarNotifier.dndEndTime;
                                    TaskbarNotifier.dndEndTime = DateTime(
                                        old.year,
                                        old.month,
                                        old.day,
                                        h,
                                        old.minute);
                                    setState(() {});
                                  }
                                },
                              ),
                              const SizedBox(width: 12),
                              DropdownButton<int>(
                                value: TaskbarNotifier.dndEndTime.minute,
                                items: [
                                  for (var m = 0; m < 60; m++)
                                    DropdownMenuItem(
                                        value: m, child: Text('$m 分')),
                                ],
                                onChanged: (m) {
                                  if (m != null) {
                                    final old = TaskbarNotifier.dndEndTime;
                                    TaskbarNotifier.dndEndTime = DateTime(
                                        old.year,
                                        old.month,
                                        old.day,
                                        old.hour,
                                        m);
                                    setState(() {});
                                  }
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            '免打扰到期后自动关闭并提醒',
                            style: TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),

                  // ---- 阶段 O7（P2-9 字体大小/聊天背景/自定义主题色）----
                  ListenableBuilder(
                    listenable: ThemeSettings.instance,
                    builder: (ctx, _) {
                      final settings = ThemeSettings.instance;
                      Widget sectionLabel(String text) => SizedBox(
                            width: 64,
                            child: Text(text,
                                style: const TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w600)),
                          );
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Divider(),
                          Row(
                            children: [
                              sectionLabel('深色模式'),
                              Expanded(
                                child: Wrap(
                                  spacing: 8,
                                  runSpacing: 4,
                                  children: [
                                    for (final entry in {
                                      AppThemeMode.system: '跟随系统',
                                      AppThemeMode.light: '浅色',
                                      AppThemeMode.dark: '深色',
                                    }.entries)
                                      ChoiceChip(
                                        label: Text(entry.value),
                                        selected: settings.mode == entry.key,
                                        onSelected: (_) =>
                                            settings.mode = entry.key,
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          Row(
                            children: [
                              sectionLabel('字体大小'),
                              Expanded(
                                child: Slider(
                                  min: 0.8,
                                  max: 1.5,
                                  divisions: 14,
                                  label: settings.fontScale.toStringAsFixed(2),
                                  value: settings.fontScale,
                                  onChanged: (v) => settings.fontScale = v,
                                ),
                              ),
                            ],
                          ),
                          Row(
                            children: [
                              sectionLabel('主题色'),
                              Expanded(
                                child: Wrap(
                                  spacing: 10,
                                  children: [
                                    for (final c in ThemeSettings.presetColors)
                                      GestureDetector(
                                        key: ValueKey('o7_theme_color_$c'),
                                        onTap: () => settings.themeColor = c,
                                        child: CircleAvatar(
                                          radius: 13,
                                          backgroundColor: Color(c),
                                          child: settings.themeColor == c
                                              ? const Icon(Icons.check_rounded,
                                                  size: 15, color: Colors.white)
                                              : null,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          Row(
                            children: [
                              sectionLabel('聊天背景'),
                              Expanded(
                                child: Wrap(
                                  spacing: 8,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    ChoiceChip(
                                      label: const Text('无背景'),
                                      selected: settings.chatBackground == null,
                                      onSelected: (_) =>
                                          settings.chatBackground = null,
                                    ),
                                    for (final c
                                        in ThemeSettings.presetBackgrounds)
                                      if (c != null)
                                        GestureDetector(
                                          key: ValueKey('o7_bg_$c'),
                                          onTap: () =>
                                              settings.chatBackground = c,
                                          child: CircleAvatar(
                                            radius: 13,
                                            backgroundColor: Color(c),
                                            child: settings.chatBackground == c
                                                ? const Icon(
                                                    Icons.check_rounded,
                                                    size: 15,
                                                    color: Colors.grey)
                                                : null,
                                          ),
                                        ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          // 阶段 P6（多语言界面）：语言选择
                          Row(
                            children: [
                              sectionLabel(t('language')),
                              Expanded(
                                child: DropdownButton<AppLocale>(
                                  value: settings.locale,
                                  items: const [
                                    DropdownMenuItem(
                                        value: AppLocale.zh, child: Text('中文')),
                                    DropdownMenuItem(
                                        value: AppLocale.en,
                                        child: Text('English')),
                                    DropdownMenuItem(
                                        value: AppLocale.system,
                                        child: Text('跟随系统')),
                                  ],
                                  onChanged: (v) {
                                    if (v != null) settings.locale = v;
                                  },
                                ),
                              ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
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

// ============================================================
// 阶段 M —— 群管理 / 群邀请 / 服务端状态 / 文件管理对话框
// ============================================================

String _formatBytes(num? bytes) {
  if (bytes == null) return '0 B';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// 阶段 M1/M2/M3：群管理对话框（仅群主可见入口）
/// 成员移出 / 转让群主 / 改名 / 历史可见性 / 入群审批 / 邀请成员
/// （2026-08-25 用户决策：头像功能已废除，个人与群聊均不支持自定义头像）
void showGroupAdminDialog(
    BuildContext context, Group group, SocketService service) {
  final state = AppState.instance;
  // 打开即拉取待审批入群申请列表（P1-17 审批数据源）
  service.fetchJoinRequests(group.id);
  showDialog(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: state,
      builder: (ctx, _) {
        final current = state.groups.where((g) => g.id == group.id).firstOrNull;
        final members = current?.members ?? group.members;
        final owner = current?.owner ?? group.owner;
        final requests = state.joinRequestsOf(group.id);
        return AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.admin_panel_settings),
              const SizedBox(width: 8),
              Expanded(
                child: Text('群管理 - ${group.displayName}',
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 16, bottom: 4),
                    child: Text('成员（${members.length} 人）',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  ...members.map((m) {
                    final isOwnerSelf = m == owner;
                    return ListTile(
                      dense: true,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 16),
                      leading: CircleAvatar(
                        radius: 14,
                        child: Text(m.isNotEmpty ? m[0].toUpperCase() : '?'),
                      ),
                      title: Text(
                        m,
                        style: TextStyle(
                          fontWeight:
                              isOwnerSelf ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      subtitle: isOwnerSelf
                          ? const Text('群主', style: TextStyle(fontSize: 11))
                          : null,
                      trailing: isOwnerSelf
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.person_remove_outlined),
                              tooltip: '移出成员',
                              onPressed: () =>
                                  service.kickGroupMember(group.id, m),
                            ),
                    );
                  }),
                  const Divider(),
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.swap_horiz_rounded),
                    title: const Text('转让群主'),
                    subtitle: const Text('将群主移交给指定成员'),
                    onTap: () {
                      Navigator.pop(ctx);
                      _showTransferOwnerDialog(
                          context, group, members, service);
                    },
                  ),
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.edit_rounded),
                    title: const Text('修改群名'),
                    onTap: () {
                      Navigator.pop(ctx);
                      _showRenameGroupDialog(context, group, service);
                    },
                  ),
                  SwitchListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: const Text('新成员历史可见'),
                    subtitle: Text(
                      current?.historyVisible == true
                          ? '新成员可见加入前最近 ${current?.historyLimit ?? 50} 条'
                          : '新成员仅可见自己加入后的消息',
                      style: const TextStyle(fontSize: 11),
                    ),
                    value: current?.historyVisible ?? true,
                    onChanged: (v) => service.setGroupHistoryVisible(
                        group.id, v,
                        limit: current?.historyLimit ?? 50),
                  ),
                  const Divider(),
                  if (requests.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(left: 16, bottom: 4),
                      child: Text('暂无待审批的入群申请',
                          style: TextStyle(fontSize: 12, color: Colors.grey)),
                    )
                  else ...[
                    const Padding(
                      padding: EdgeInsets.only(left: 16, bottom: 4),
                      child: Text('入群申请',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    ...requests.map((u) {
                      final reqMsg = state.joinRequestMessageOf(group.id, u);
                      return ListTile(
                        dense: true,
                        leading: const Icon(Icons.person_add_alt),
                        title: Text(u),
                        subtitle: reqMsg.isNotEmpty
                            ? Text('验证消息: $reqMsg',
                                style: const TextStyle(fontSize: 11))
                            : null,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.check_circle,
                                  color: Colors.green),
                              tooltip: '批准',
                              onPressed: () {
                                service.approveJoinRequest(group.id, u);
                                state.removeJoinRequest(group.id, u);
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.cancel, color: Colors.red),
                              tooltip: '拒绝',
                              onPressed: () {
                                service.rejectJoinRequest(group.id, u);
                                state.removeJoinRequest(group.id, u);
                              },
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                  const Divider(),
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.person_add_alt_1),
                    title: const Text('邀请成员'),
                    subtitle: const Text('输入用户名发送群邀请'),
                    onTap: () {
                      Navigator.pop(ctx);
                      _showInviteMemberDialog(context, group, service);
                    },
                  ),
                ],
              ),
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

void _showTransferOwnerDialog(BuildContext context, Group group,
    List<String> members, SocketService service) {
  final owner = AppState.instance.groups
      .where((g) => g.id == group.id)
      .firstOrNull
      ?.owner;
  final candidates = members
      .where((m) => m != owner && m != AppState.instance.username)
      .toList();
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('转让群主'),
      content: candidates.isEmpty
          ? const Text('群内没有可转让的成员')
          : SizedBox(
              width: 300,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: candidates.length,
                itemBuilder: (_, i) => ListTile(
                  dense: true,
                  leading: const Icon(Icons.person_rounded),
                  title: Text(candidates[i]),
                  onTap: () {
                    Navigator.pop(ctx);
                    service.transferGroupOwner(group.id, candidates[i]);
                  },
                ),
              ),
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
      ],
    ),
  );
}

void _showRenameGroupDialog(
    BuildContext context, Group group, SocketService service) {
  final controller = TextEditingController(text: group.name);
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('修改群名'),
      content: RawTextField(
        controller: controller,
        hintText: '新群名',
        showChineseInput: true,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final name = controller.text.trim();
            if (name.isNotEmpty) {
              service.renameGroup(group.id, name);
            }
            Navigator.pop(ctx);
          },
          child: const Text('保存'),
        ),
      ],
    ),
  );
}

void _showInviteMemberDialog(
    BuildContext context, Group group, SocketService service) {
  final controller = TextEditingController();
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('邀请成员'),
      content: RawTextField(controller: controller, hintText: '用户名'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final name = controller.text.trim();
            if (name.isNotEmpty) {
              service.inviteGroupMember(group.id, name);
            }
            Navigator.pop(ctx);
          },
          child: const Text('邀请'),
        ),
      ],
    ),
  );
}

/// 阶段 M2：群邀请入口列表（P-11 用户反馈：邀请像好友申请一样保留入口，
/// 而非即时弹窗——离线用户登录后由服务端补发 group_invite 进入此列表）
void showGroupInvitesDialog(
  BuildContext context, {
  required List<GroupInvite> invites,
  required void Function(GroupInvite invite, bool accept) onRespond,
}) {
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.group_add_rounded),
          SizedBox(width: 8),
          Text('群邀请'),
        ],
      ),
      content: SizedBox(
        width: 320,
        child: invites.isEmpty
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('暂无待处理的群邀请', style: TextStyle(color: Colors.grey)),
              )
            : ListView.builder(
                shrinkWrap: true,
                itemCount: invites.length,
                itemBuilder: (_, i) {
                  final invite = invites[i];
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.group_rounded),
                    title: Text(invite.groupName.isEmpty
                        ? '群组 ID:${invite.groupId}'
                        : invite.groupName),
                    subtitle: Text('来自 ${invite.inviter}',
                        style: const TextStyle(fontSize: 11)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.check, color: Colors.green),
                          tooltip: '接受',
                          onPressed: () {
                            onRespond(invite, true);
                            Navigator.pop(ctx);
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.red),
                          tooltip: '拒绝',
                          onPressed: () {
                            onRespond(invite, false);
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

/// 阶段 M4/M6：服务端状态面板 + 存储治理（管理员）
void showServerStatusDialog(BuildContext context, SocketService service) {
  final state = AppState.instance;
  service.fetchServerStatus();
  showDialog(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: state,
      builder: (ctx, _) {
        final s = state.serverStatus;
        final cleanup = state.storageCleanupResult;
        final logs = (s?['recent_logs'] as List?) ?? const [];
        // 阶段 O8：证书过期自检（旧服务端无 cert 字段时不渲染，向后兼容）
        final cert = s?['cert'];
        final certMap = cert is Map ? cert : null;
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.monitor_heart_outlined),
              SizedBox(width: 8),
              Text('服务端状态'),
            ],
          ),
          content: SizedBox(
            width: 440,
            child: s == null
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _statusRow('在线用户', '${s['online_users']}'),
                        _statusRow('总连接数', '${s['online_sessions']}'),
                        _statusRow('用户总数', '${s['total_users']}'),
                        _statusRow('消息总数', '${s['total_messages']}'),
                        _statusRow('待处理文件请求', '${s['pending_file_requests']}'),
                        const Divider(),
                        _statusRow('文件存储占用',
                            _formatBytes(s['storage']?['file_store_bytes'])),
                        _statusRow('文件数', '${s['storage']?['file_count']}'),
                        _statusRow(
                            '数据库大小', _formatBytes(s['storage']?['db_bytes'])),
                        const Divider(),
                        _statusRow(
                            '磁盘剩余', _formatBytes(s['disk']?['disk_free'])),
                        _statusRow(
                            '磁盘总量', _formatBytes(s['disk']?['disk_total'])),
                        _statusRow(
                            '磁盘预警',
                            s['disk']?['warn'] == true
                                ? '⚠ 剩余空间不足，请及时清理'
                                : '正常'),
                        const Divider(),
                        // 阶段 O8：证书剩余有效期与续期入口
                        if (certMap != null) ...[
                          _statusRow(
                            '证书剩余天数',
                            certMap['expired'] == true
                                ? '已过期'
                                : '${certMap['days_left'] ?? '?'} 天',
                          ),
                          const Divider(),
                        ],
                        if (cleanup != null) ...[
                          Text(
                            '上次清理: 文件请求 ${cleanup['expired_file_requests']} '
                            '个 / 已读消息 ${cleanup['expired_delivered_messages']} 条',
                            style: const TextStyle(fontSize: 12),
                          ),
                          const Divider(),
                        ],
                        const Text('最近日志',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        ...logs.take(8).map((l) => Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text('$l',
                                  style: const TextStyle(
                                      fontSize: 11, color: Colors.grey)),
                            )),
                      ],
                    ),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                service.runStorageCleanup();
              },
              child: const Text('存储清理'),
            ),
            // 阶段 O8：证书一键续期（旧服务端无 cert 字段时不显示）
            if (certMap != null)
              TextButton(
                onPressed: () {
                  service.renewCert();
                },
                child: const Text('一键续期'),
              ),
            // 2026-08-25 用户反馈：面板数据刷新（无需反复进入退出）
            TextButton(
              onPressed: () {
                service.fetchServerStatus();
              },
              child: const Text('刷新'),
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

Widget _statusRow(String label, String value) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 13)),
        Text(value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ],
    ),
  );
}

/// 阶段 M8：文件收发管理页（按会话聚合）
void showFileListDialog(BuildContext context, SocketService service,
    {String? to, int? groupId}) {
  final state = AppState.instance;
  service.fetchFileList(to: to, groupId: groupId);
  showDialog(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: state,
      builder: (ctx, _) {
        final files = state.fileRecords;
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.folder_open_rounded),
              SizedBox(width: 8),
              Text('文件管理'),
            ],
          ),
          content: SizedBox(
            width: 440,
            height: 380,
            child: files.isEmpty
                ? const Center(
                    child: Text('暂无文件记录', style: TextStyle(color: Colors.grey)))
                : ListView.builder(
                    itemCount: files.length,
                    itemBuilder: (_, i) {
                      final f = files[i];
                      final ts = f.timestamp
                          .toString()
                          .replaceFirst('.000', '')
                          .substring(0, 16);
                      return ListTile(
                        dense: true,
                        leading: const Icon(Icons.insert_drive_file_outlined),
                        title:
                            Text(f.filename, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          '${f.sender} → ${f.isGroupFile ? '群组' : f.receiver} · '
                          '${_formatBytes(f.filesize)} · $ts',
                          style: const TextStyle(fontSize: 11),
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
        );
      },
    ),
  );
}

// ============================================================
// 阶段 N6（P2-6 登录设备管理）/ N7（P2-7 审计日志）面板
// ============================================================

String _formatActiveTime(DateTime dt) {
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${pad(dt.hour)}:${pad(dt.minute)}';
}

/// 设备管理对话框（阶段 N6：P2-6 登录设备管理）
///
/// 列出当前账号全部在线会话（device_id/当前标记/最后活跃），可远程下线
/// （复用服务端 _kick_old_session 逻辑；"同类别互踢、异类别并存"语义由
/// 登录模型保证）。打开即拉取，下线后刷新。
void showDeviceManagementDialog(BuildContext context, SocketService service) {
  final state = AppState.instance;
  service.fetchSessions();
  showDialog(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: state,
      builder: (ctx, _) {
        final sessions = state.sessions;
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.devices_rounded),
              SizedBox(width: 8),
              Text('设备管理'),
            ],
          ),
          content: SizedBox(
            width: 400,
            child: sessions.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: Text('加载中...')),
                  )
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final s in sessions)
                          ListTile(
                            leading: Icon(
                              s.isCurrent
                                  ? Icons.desktop_windows_rounded
                                  : Icons.devices_other_rounded,
                            ),
                            title: Text(s.deviceId),
                            subtitle:
                                Text('最后活跃: ${_formatActiveTime(s.lastActive)}'
                                    '${s.isCurrent ? ' · 当前' : ''}'),
                            trailing: s.isCurrent
                                ? null
                                : TextButton(
                                    onPressed: () {
                                      service.kickSession(s.deviceId);
                                      service.fetchSessions();
                                    },
                                    child: const Text('下线'),
                                  ),
                          ),
                        if (sessions.length <= 1)
                          const Padding(
                            padding: EdgeInsets.all(16),
                            child: Text('暂无其他设备'),
                          ),
                      ],
                    ),
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

/// 审计日志对话框（阶段 N7：P2-7 审计日志，管理面板可查）
///
/// 展示敏感操作记录（操作者/操作/对象/时间），打开即拉取。
void showAuditLogDialog(BuildContext context, SocketService service) {
  final state = AppState.instance;
  service.fetchAuditLogs();
  showDialog(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: state,
      builder: (ctx, _) {
        final logs = state.auditLogs;
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.receipt_long_rounded),
              SizedBox(width: 8),
              Text('审计日志'),
            ],
          ),
          content: SizedBox(
            width: 460,
            child: logs.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('暂无审计记录'),
                  )
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final e in logs)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(e.operator,
                                        style: const TextStyle(fontSize: 13)),
                                    const Text('  ·  ',
                                        style: TextStyle(fontSize: 13)),
                                    Text(e.action,
                                        style: const TextStyle(fontSize: 13)),
                                    const Text('  ·  ',
                                        style: TextStyle(fontSize: 13)),
                                    Text(e.target,
                                        style: const TextStyle(fontSize: 13)),
                                  ],
                                ),
                                if (e.detail.isNotEmpty)
                                  Text(
                                    e.detail,
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey.shade600),
                                  ),
                                Text(
                                  e.timestamp == null
                                      ? ''
                                      : '${e.timestamp!.year}-'
                                          '${e.timestamp!.month.toString().padLeft(2, '0')}-'
                                          '${e.timestamp!.day.toString().padLeft(2, '0')} '
                                          '${e.timestamp!.hour.toString().padLeft(2, '0')}:'
                                          '${e.timestamp!.minute.toString().padLeft(2, '0')}',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey.shade500),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
            // 阶段 N7 补充（用户反馈）：审计日志支持导出（TXT/JSON）
            TextButton.icon(
              onPressed:
                  logs.isEmpty ? null : () => _exportAuditLogs(context, logs),
              icon: const Icon(Icons.ios_share_rounded, size: 18),
              label: const Text('导出'),
            ),
          ],
        );
      },
    ),
  );
}

/// 阶段 N7 补充：审计日志导出（TXT 每行一条 / JSON 完整字段）
Future<void> _exportAuditLogs(
    BuildContext context, List<AuditLogEntry> logs) async {
  final format = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('导出审计日志'),
      content: const Text('TXT：每行一条记录\nJSON：完整字段（含 id/详情/时间）'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.pop(ctx, 'txt'),
          child: const Text('TXT'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.pop(ctx, 'json'),
          child: const Text('JSON'),
        ),
      ],
    ),
  );
  if (format == null) return;
  String tsOf(DateTime? t) {
    if (t == null) return '';
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${pad(t.month)}-${pad(t.day)} '
        '${pad(t.hour)}:${pad(t.minute)}:${pad(t.second)}';
  }

  final path = await FilePicker.platform.saveFile(
    dialogTitle: '导出审计日志',
    fileName: 'audit_logs.$format',
  );
  if (path == null) return;
  final content = format == 'txt'
      ? [
          for (final e in logs)
            '${tsOf(e.timestamp)} | ${e.operator} | ${e.action}'
                ' | ${e.target} | ${e.detail}',
        ].join('\n')
      : jsonEncode([
          for (final e in logs)
            {
              'id': e.id,
              'operator': e.operator,
              'action': e.action,
              'target': e.target,
              'detail': e.detail,
              'timestamp': tsOf(e.timestamp),
            },
        ]);
  try {
    File(path).writeAsStringSync(content);
    AppState.instance.showNotice('已导出 ${logs.length} 条审计记录到 $path');
  } catch (e) {
    AppState.instance.showNotice('审计导出失败: $e');
  }
}

// ============================================================
// 阶段 O —— 群组与消息增强对话框
// ============================================================

/// 阶段 O1（群公告）管理对话框（2026-08-30 用户反馈 #2）：
/// 两个选项页——「发布公告」（输入文本确定发布；空文本语义已由独立清除取代）
/// 与「清除公告」（查看全部公告历史并选择性删除；删除当前公告时横幅同步消失）。
/// 发布经 [onConfirm]（上层 set_group_announcement）；
/// 查看经 [onListAnnouncements]（上层 fetchGroupAnnouncements，结果在
/// AppState.groupAnnouncements）；删除经 [onDelete]（上层 deleteGroupAnnouncement，
/// 服务端删除当前公告会广播 list_groups 刷新）。
void showGroupAnnouncementDialog(
  BuildContext context, {
  String? initial,
  required ValueChanged<String> onConfirm,
  required VoidCallback onListAnnouncements,
  required ValueChanged<String> onDelete,
}) {
  final ctrl = TextEditingController(text: initial ?? '');
  var tab = 0; // 0=发布公告 1=清除公告
  var loadedList = false;

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => ListenableBuilder(
        listenable: AppState.instance,
        builder: (ctx, _) {
          final state = AppState.instance;
          if (tab == 1 && !loadedList) {
            loadedList = true;
            onListAnnouncements();
          }
          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.campaign_rounded),
                SizedBox(width: 8),
                Text('群公告'),
              ],
            ),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      ChoiceChip(
                        label: const Text('发布公告'),
                        selected: tab == 0,
                        onSelected: (_) => setState(() => tab = 0),
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: const Text('清除公告'),
                        selected: tab == 1,
                        onSelected: (_) => setState(() => tab = 1),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (tab == 0) ...[
                    const Text('公告将推送给全体成员',
                        style: TextStyle(fontSize: 12, color: Colors.grey)),
                    const SizedBox(height: 8),
                    RawTextField(
                      controller: ctrl,
                      hintText: '输入群公告内容...',
                      showChineseInput: true,
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 40)),
                      onPressed: () {
                        final text = ctrl.text.trim();
                        Navigator.pop(ctx);
                        onConfirm(text);
                      },
                      child: const Text('发布'),
                    ),
                  ] else
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 300),
                      child: state.groupAnnouncements.isEmpty
                          ? const Padding(
                              padding: EdgeInsets.all(16),
                              child: Text('暂无公告历史',
                                  style: TextStyle(color: Colors.grey)),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              itemCount: state.groupAnnouncements.length,
                              itemBuilder: (ctx, i) {
                                final a = state.groupAnnouncements[i];
                                final isCurrent = a.content == initial;
                                return ListTile(
                                  dense: true,
                                  title: Text(
                                    a.content,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    isCurrent ? '当前公告' : a.timestamp,
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                  trailing: IconButton(
                                    key: ValueKey(
                                        'announcement_delete_${a.messageId}'),
                                    icon: const Icon(
                                        Icons.delete_outline_rounded,
                                        size: 20),
                                    tooltip: '删除',
                                    onPressed: () {
                                      onDelete(a.messageId);
                                      setState(() {
                                        loadedList = false;
                                      });
                                    },
                                  ),
                                );
                              },
                            ),
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
    ),
  );
}

/// 阶段 O4（P2-3 快捷回复）：常用语面板——点击短语即 [onSend] 并关闭；
/// 可添加/删除（经 QuickReplyStore 本地持久化，[onChanged] 通知列表变化）。
void showQuickReplyPanel(
  BuildContext context, {
  required ValueChanged<String> onSend,
  VoidCallback? onChanged,
}) {
  final addCtrl = TextEditingController();
  List<String> phrases = const [];
  var loaded = false;

  Future<void> reload(void Function(void Function()) setState) async {
    final list = await QuickReplyStore.load();
    setState(() => phrases = list);
  }

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        if (!loaded) {
          loaded = true;
          reload(setState);
        }
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.bolt_rounded),
              SizedBox(width: 8),
              Text('快捷回复'),
            ],
          ),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 280),
                  child: phrases.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('暂无常用语，先添加一条吧',
                              style: TextStyle(color: Colors.grey)),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: phrases.length,
                          itemBuilder: (ctx, i) {
                            final phrase = phrases[i];
                            return ListTile(
                              dense: true,
                              title: Text(phrase),
                              onTap: () {
                                Navigator.pop(ctx);
                                onSend(phrase);
                              },
                              trailing: IconButton(
                                key: ValueKey('quick_reply_delete_$phrase'),
                                icon: const Icon(Icons.delete_outline_rounded,
                                    size: 20),
                                tooltip: '删除',
                                onPressed: () async {
                                  await QuickReplyStore.remove(phrase);
                                  await reload(setState);
                                  onChanged?.call();
                                },
                              ),
                            );
                          },
                        ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: RawTextField(
                        controller: addCtrl,
                        hintText: '输入新常用语...',
                        showChineseInput: true,
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () async {
                        await QuickReplyStore.add(addCtrl.text);
                        addCtrl.clear();
                        await reload(setState);
                        onChanged?.call();
                      },
                      child: const Text('添加'),
                    ),
                  ],
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

/// 日期/时刻下拉组（阶段 O5/O9 定时对话框共用）。
/// 返回控件；通过 [onChangedDate]/[onChangedTime] 回传选择结果。
class _SchedulePickers extends StatelessWidget {
  final DateTime selectedDate;
  final int hour;
  final int minute;
  final ValueChanged<DateTime> onChangedDate;
  final ValueChanged<int> onChangedHour;
  final ValueChanged<int> onChangedMinute;

  const _SchedulePickers({
    required this.selectedDate,
    required this.hour,
    required this.minute,
    required this.onChangedDate,
    required this.onChangedHour,
    required this.onChangedMinute,
  });

  static String _dayLabel(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(d.year, d.month, d.day);
    final diff = target.difference(today).inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '明天';
    return '${d.month}-${d.day}';
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final base = DateTime(now.year, now.month, now.day);
    final days = [
      for (var i = 0; i <= 7; i++) base.add(Duration(days: i)),
    ];
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        DropdownButton<DateTime>(
          value: selectedDate,
          items: [
            for (final d in days)
              DropdownMenuItem(
                value: d,
                child: Text(_dayLabel(d)),
              ),
          ],
          onChanged: (d) {
            if (d != null) onChangedDate(d);
          },
        ),
        const SizedBox(width: 12),
        DropdownButton<int>(
          value: hour,
          items: [
            for (var h = 0; h < 24; h++)
              DropdownMenuItem(value: h, child: Text('$h 时')),
          ],
          onChanged: (h) {
            if (h != null) onChangedHour(h);
          },
        ),
        const SizedBox(width: 12),
        DropdownButton<int>(
          value: minute,
          items: [
            for (var m = 0; m < 60; m++)
              DropdownMenuItem(value: m, child: Text('$m 分')),
          ],
          onChanged: (m) {
            if (m != null) onChangedMinute(m);
          },
        ),
      ],
    );
  }
}

/// 阶段 O5（P2-5 定时消息）：定时发送对话框。
/// 默认时刻 = 明天 09:00；空文本禁用确定；确认回调 [onSchedule](时刻, 文本)。

/// 阶段 O5（P2-5 定时消息）：定时发送对话框。
/// 默认时刻 = 明天 09:00；空文本禁用确定；确认回调 [onSchedule](时刻, 文本)。
void showScheduleMessageDialog(
  BuildContext context, {
  required Future<void> Function(DateTime at, String text) onSchedule,
}) {
  final textCtrl = TextEditingController();
  final now = DateTime.now();
  var selectedDate = DateTime(now.year, now.month, now.day + 1);
  var hour = 9;
  var minute = 0;
  var listenerBound = false;

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        if (!listenerBound) {
          listenerBound = true;
          // RawTextField 无 onChanged：文本变化经 controller listener 触发重建
          textCtrl.addListener(() => setState(() {}));
        }
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.schedule_rounded),
              SizedBox(width: 8),
              Text('定时消息'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RawTextField(
                controller: textCtrl,
                hintText: '输入定时消息内容...',
                showChineseInput: true,
              ),
              const SizedBox(height: 12),
              _SchedulePickers(
                selectedDate: selectedDate,
                hour: hour,
                minute: minute,
                onChangedDate: (d) => setState(() => selectedDate = d),
                onChangedHour: (h) => setState(() => hour = h),
                onChangedMinute: (m) => setState(() => minute = m),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
              onPressed: textCtrl.text.trim().isEmpty
                  ? null
                  : () async {
                      final at = DateTime(selectedDate.year, selectedDate.month,
                          selectedDate.day, hour, minute);
                      Navigator.pop(ctx);
                      await onSchedule(at, textCtrl.text.trim());
                    },
              child: const Text('定时发送'),
            ),
          ],
        );
      },
    ),
  );
}

/// 阶段 O5（2026-08-30 用户反馈 #7）：定时管理对话框——列出本人全部
/// pending 定时任务并选择性取消。打开时经 [onList]（fetchScheduled）
/// 拉取，渲染 AppState.scheduledMessages；删除经 [onDelete]（cancelScheduled
/// + 重新拉取）。
void showScheduledManageDialog(
  BuildContext context, {
  required VoidCallback onList,
  required ValueChanged<String> onDelete,
}) {
  var loaded = false;
  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => ListenableBuilder(
        listenable: AppState.instance,
        builder: (ctx, _) {
          final state = AppState.instance;
          if (!loaded) {
            loaded = true;
            onList();
          }
          String two(int v) => v.toString().padLeft(2, '0');
          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.schedule_rounded),
                SizedBox(width: 8),
                Text('定时任务管理'),
              ],
            ),
            content: SizedBox(
              width: 360,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: state.scheduledMessages.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text('暂无定时任务',
                            style: TextStyle(color: Colors.grey.shade600)),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: state.scheduledMessages.length,
                        itemBuilder: (ctx, i) {
                          final s = state.scheduledMessages[i];
                          final target = s.isGroupMessage
                              ? '群 ${s.groupId}'
                              : '发给 ${s.receiver}';
                          return ListTile(
                            dense: true,
                            title: Text(s.content,
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                                '$target · '
                                '${s.scheduleAt.month}-${s.scheduleAt.day} '
                                '${two(s.scheduleAt.hour)}:${two(s.scheduleAt.minute)}',
                                style: const TextStyle(fontSize: 11)),
                            trailing: IconButton(
                              key: ValueKey('scheduled_cancel_${s.messageId}'),
                              icon: const Icon(Icons.cancel_outlined, size: 20),
                              tooltip: '取消定时',
                              onPressed: () {
                                onDelete(s.messageId);
                                setState(() => loaded = false);
                              },
                            ),
                          );
                        },
                      ),
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
    ),
  );
}

// ============================================================
// 阶段 P —— 表情包面板 / 高级搜索对话框
// ============================================================

/// R-P3（表情包体系重构，微信式双模块面板）：
///   - 表情模块：内置表情（emojiPickerCategories，微信规模），点击插入输入框
///   - 表情包模块："我的表情包"扁平网格（无包名）——首格"添加表情包"
///     （多选图片，恒可用），点击贴纸即发送，长按贴纸删除
/// 收藏他人表情：图片消息长按菜单"添加到表情包"（ChatView onSaveSticker）。
void showStickerPickerDialog(
  BuildContext context, {
  required ValueChanged<Sticker> onPick,
  required ValueChanged<String> onEmojiPicked,
}) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _StickerPickerPanel(
      onPick: onPick,
      onEmojiPicked: onEmojiPicked,
    ),
  );
}

class _StickerPickerPanel extends StatefulWidget {
  final ValueChanged<Sticker> onPick;
  final ValueChanged<String> onEmojiPicked;

  const _StickerPickerPanel(
      {required this.onPick, required this.onEmojiPicked});

  @override
  State<_StickerPickerPanel> createState() => _StickerPickerPanelState();
}

class _StickerPickerPanelState extends State<_StickerPickerPanel> {
  static const _panelHeight = 340.0;
  int _tab = 0; // 0 = 表情；1 = 表情包
  List<Sticker> _stickers = const [];
  var _emojiCategory = 0;
  var _loaded = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final list = await StickerStore.instance.loadStickers();
    if (mounted) setState(() => _stickers = list);
  }

  Future<void> _addStickersFromPicker() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      withData: true,
    );
    if (result == null) return;
    var added = 0;
    for (final file in result.files) {
      Uint8List? bytes;
      if (file.bytes != null) {
        bytes = file.bytes;
      } else if (file.path != null) {
        bytes = await File(file.path!).readAsBytes();
      }
      if (bytes != null &&
          isSupportedImage(bytes) &&
          await StickerStore.instance.addSticker(bytes) != null) {
        added++;
      }
    }
    await _reload();
    if (!mounted) return;
    if (added > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('已添加 $added 张表情'),
            duration: const Duration(seconds: 2)),
      );
    } else {
      // R-P11：不再静默失败——魔数校验未通过/落盘失败给明确反馈
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('添加失败：仅支持 PNG/JPG/GIF 图片'),
            duration: Duration(seconds: 2)),
      );
    }
  }

  Future<void> _confirmDelete(Sticker sticker) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('删除表情'),
        content: const Text('确定删除这张表情吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await StickerStore.instance.removeSticker(sticker.id);
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      _loaded = true;
      _reload();
    }
    return Container(
      height: _panelHeight,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          Expanded(
            child: _tab == 0 ? _buildEmojiGrid() : _buildStickerGrid(),
          ),
          _buildTabBar(),
        ],
      ),
    );
  }

  // ---- 表情模块（内置，点击插入输入框）----

  Widget _buildEmojiGrid() {
    final (name, emojis) = emojiPickerCategories[_emojiCategory];
    return Column(
      children: [
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(10),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 10,
              childAspectRatio: 1,
            ),
            itemCount: emojis.length,
            itemBuilder: (ctx, i) => InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => widget.onEmojiPicked(emojis[i]),
              child: Center(
                // R-P10：指定 COLRv1 彩色字体——缺省时落到系统兜底字体
                // （DejaVu/Noto Symbols 等），部分表情渲染为黑白字形
                child: Text(emojis[i],
                    style: const TextStyle(
                        fontSize: 24, fontFamily: 'NotoColorEmoji')),
              ),
            ),
          ),
        ),
        // 分类切换条
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              for (var i = 0; i < emojiPickerCategories.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceChip(
                    label: Text(emojiPickerCategories[i].$1,
                        style: const TextStyle(fontSize: 12)),
                    selected: _emojiCategory == i,
                    onSelected: (_) => setState(() => _emojiCategory = i),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  // ---- 表情包模块（我的表情，扁平网格）----

  Widget _buildStickerGrid() {
    return GridView.builder(
      padding: const EdgeInsets.all(10),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 5,
        childAspectRatio: 1,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: _stickers.length + 1,
      itemBuilder: (ctx, i) {
        if (i == 0) {
          // 添加表情包（R-P3：恒可用，多选图片；空态不再一片空白）
          return InkWell(
            key: const ValueKey('sticker_add_tile'),
            borderRadius: BorderRadius.circular(8),
            onTap: _addStickersFromPicker,
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey, width: 1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add_rounded,
                      size: 26, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 2),
                  const Text('添加表情包',
                      style: TextStyle(fontSize: 10, color: Colors.grey)),
                ],
              ),
            ),
          );
        }
        final sticker = _stickers[i - 1];
        return GestureDetector(
          onLongPress: () => _confirmDelete(sticker),
          onTap: () {
            Navigator.pop(context);
            widget.onPick(sticker);
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              StickerStore.instance.stickerBytes(sticker.id) ?? Uint8List(0),
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                color: Colors.grey.shade200,
                child: const Icon(Icons.broken_image_outlined),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTabBar() {
    return Container(
      decoration: BoxDecoration(
        border: Border(
            top: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () => setState(() => _tab = 0),
              child: SizedBox(
                height: 44,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.emoji_emotions_outlined,
                        size: 20,
                        color: _tab == 0
                            ? Theme.of(context).colorScheme.primary
                            : Colors.grey),
                    const SizedBox(width: 6),
                    Text('表情',
                        style: TextStyle(
                            fontSize: 13,
                            color: _tab == 0
                                ? Theme.of(context).colorScheme.primary
                                : Colors.grey)),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: InkWell(
              onTap: () => setState(() => _tab = 1),
              child: SizedBox(
                height: 44,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.favorite_rounded,
                        size: 20,
                        color: _tab == 1
                            ? Theme.of(context).colorScheme.primary
                            : Colors.grey),
                    const SizedBox(width: 6),
                    Text('表情包',
                        style: TextStyle(
                            fontSize: 13,
                            color: _tab == 1
                                ? Theme.of(context).colorScheme.primary
                                : Colors.grey)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 阶段 P3（复合条件消息搜索）：高级搜索对话框——关键词/发送者 +
/// 起始日期/结束日期（R-P4 修订：日期下拉选择，参考定时消息的日期
/// 选择形式，不再手输）。全空不触发；确认回调 onSearch(MessageSearchFilter)。
void showAdvancedSearchDialog(
  BuildContext context, {
  required ValueChanged<MessageSearchFilter> onSearch,
}) {
  final keywordCtrl = TextEditingController();
  final senderCtrl = TextEditingController();
  var listening = false;
  DateTime? from;
  DateTime? to;

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        // RawTextField 输入只写 controller：挂监听驱动对话框重建
        // （按钮可用态随输入刷新）
        if (!listening) {
          listening = true;
          for (final c in [keywordCtrl, senderCtrl]) {
            c.addListener(() => setState(() {}));
          }
        }
        final toEnd = to == null
            ? null
            : DateTime(to!.year, to!.month, to!.day, 23, 59, 59);
        final filter = MessageSearchFilter(
          keyword: keywordCtrl.text,
          sender: senderCtrl.text,
          from: from,
          to: toEnd,
        );
        final canSearch = filter.hasFilters;
        return AlertDialog(
          title: const Text('高级搜索'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RawTextField(
                  key: const ValueKey('adv_search_keyword'),
                  controller: keywordCtrl,
                  hintText: '关键词（可选）',
                  showChineseInput: true,
                ),
                const SizedBox(height: 8),
                RawTextField(
                  key: const ValueKey('adv_search_sender'),
                  controller: senderCtrl,
                  hintText: '发送者（可选）',
                  showChineseInput: true,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _searchDayDropdown(
                        key: const ValueKey('adv_search_from'),
                        value: from,
                        hint: '起始日期',
                        onChanged: (v) => setState(() => from = v),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _searchDayDropdown(
                        key: const ValueKey('adv_search_to'),
                        value: to,
                        hint: '结束日期',
                        onChanged: (v) => setState(() => to = v),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
              onPressed: canSearch
                  ? () {
                      Navigator.pop(ctx);
                      onSearch(filter);
                    }
                  : null,
              child: const Text('搜索'),
            ),
          ],
        );
      },
    ),
  );
}

/// R-P4：搜索日期下拉（近 30 天 + 不限；样式对齐定时消息的日期选择）
Widget _searchDayDropdown({
  required Key key,
  required DateTime? value,
  required String hint,
  required ValueChanged<DateTime?> onChanged,
}) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final days = [
    for (var i = 0; i < 30; i++) today.subtract(Duration(days: i)),
  ];
  String label(DateTime d) {
    final diff = today.difference(DateTime(d.year, d.month, d.day)).inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '昨天';
    return '${d.month}-${d.day}';
  }

  return SizedBox(
    key: key,
    child: DropdownButton<DateTime?>(
      value: value,
      isExpanded: true,
      hint: Text(hint, style: const TextStyle(fontSize: 13)),
      items: [
        const DropdownMenuItem<DateTime?>(
            value: null, child: Text('不限', style: TextStyle(fontSize: 13))),
        for (final d in days)
          DropdownMenuItem<DateTime?>(
              value: d,
              child: Text(label(d), style: const TextStyle(fontSize: 13))),
      ],
      onChanged: onChanged,
    ),
  );
}

/// R-P2（文件预览，参考微信）：文件卡片点击 → 预览。
/// 文本类文件（≤1MB）与 Office/PDF（R-P9：docx/xlsx/pptx/pdf，纯 Dart
/// 文本提取，尽力而为）内嵌预览；其余显示类型图标 + 基本信息；
/// 提供"打开文件/打开所在目录"（系统默认程序，xdg-open）。
void showFilePreviewDialog(
  BuildContext context, {
  required String filename,
  String? path,
  int? filesize,
  String? sender,
  DateTime? timestamp,
}) {
  final exists = path != null && File(path).existsSync();
  final sizeLine = filesize != null ? formatFileSize(filesize) : null;
  final textPreview = _readTextPreview(path, filesize) ??
      _readDocumentPreview(path, filesize);

  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.insert_drive_file_rounded),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              filename,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('大小：${sizeLine ?? '未知'}',
                    style: const TextStyle(fontSize: 12)),
                const SizedBox(width: 16),
                if (sender != null)
                  Text('来自：$sender', style: const TextStyle(fontSize: 12)),
              ],
            ),
            const SizedBox(height: 10),
            if (textPreview != null)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      textPreview,
                      style: const TextStyle(
                          fontSize: 12, fontFamily: 'monospace'),
                    ),
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 18),
                child: Center(
                  child: Column(
                    children: [
                      Icon(_fileIconFor(filename),
                          size: 56, color: Colors.grey),
                      const SizedBox(height: 8),
                      Text(
                        exists ? '该类型暂不支持内嵌预览' : '文件尚未下载到本地',
                        style:
                            const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        if (exists)
          TextButton.icon(
            onPressed: () => Process.run('xdg-open', [File(path).parent.path]),
            icon: const Icon(Icons.folder_open_rounded, size: 18),
            label: const Text('打开所在目录'),
          ),
        if (exists)
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () => Process.run('xdg-open', [path]),
            child: const Text('打开文件'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

/// 文本类扩展名（≤1MB 时内嵌预览）
const List<String> _textPreviewExtensions = [
  '.txt',
  '.md',
  '.log',
  '.json',
  '.csv',
  '.yaml',
  '.yml',
  '.xml',
  '.ini',
  '.cfg',
  '.py',
  '.dart',
  '.js',
  '.ts',
  '.html',
  '.css',
  '.sql',
];

String? _readTextPreview(String? path, int? filesize) {
  if (path == null) return null;
  final lower = path.toLowerCase();
  if (!_textPreviewExtensions.any(lower.endsWith)) return null;
  final file = File(path);
  if (!file.existsSync()) return null;
  if (filesize != null && filesize > 1024 * 1024) return null;
  try {
    final content = file.readAsStringSync();
    final clipped = content.length > 20000
        ? '${content.substring(0, 20000)}\n...（已截断）'
        : content;
    return clipped;
  } catch (_) {
    return null;
  }
}

/// R-P9：Office/PDF 内嵌预览（纯 Dart 文本提取，尽力而为）。
/// 50MB 上限防大文件整包读入内存；提取失败回退"打开文件"信息页。
String? _readDocumentPreview(String? path, int? filesize) {
  if (path == null) return null;
  final lower = path.toLowerCase();
  const extensions = ['.docx', '.xlsx', '.pptx', '.pdf'];
  if (!extensions.any(lower.endsWith)) return null;
  if (filesize != null && filesize > 50 * 1024 * 1024) return null;
  final file = File(path);
  if (!file.existsSync()) return null;
  return extractDocumentPreview(path);
}

IconData _fileIconFor(String filename) {
  final lower = filename.toLowerCase();
  if (lower.endsWith('.pdf')) return Icons.picture_as_pdf_rounded;
  if (['.zip', '.rar', '.7z', '.tar', '.gz'].any(lower.endsWith)) {
    return Icons.folder_zip_rounded;
  }
  if (['.doc', '.docx'].any(lower.endsWith)) {
    return Icons.description_rounded;
  }
  if (['.xls', '.xlsx', '.csv'].any(lower.endsWith)) {
    return Icons.table_chart_rounded;
  }
  if (['.ppt', '.pptx'].any(lower.endsWith)) return Icons.slideshow_rounded;
  if (['.mp3', '.wav', '.flac', '.m4a'].any(lower.endsWith)) {
    return Icons.audio_file_rounded;
  }
  return Icons.insert_drive_file_rounded;
}
