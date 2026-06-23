/// 聊天主界面
///
/// 布局：左侧边栏（好友/群组列表）+ 右侧聊天区域
/// 管理员可见额外"管理面板"按钮

import 'package:flutter/material.dart';

import '../services/ime_bridge.dart';
import '../services/socket_service.dart';
import '../services/state_manager.dart';
import '../widgets/chat_view.dart';
import '../widgets/dialogs.dart';
import '../widgets/sidebar.dart';

class ChatScreen extends StatefulWidget {
  final SocketService socketService;

  const ChatScreen({super.key, required this.socketService});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _state = AppState.instance;
  final _inputCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _state.addListener(_onStateChanged);
  }

  @override
  void dispose() {
    _state.removeListener(_onStateChanged);
    _inputCtrl.dispose();
    // ChatScreen 退出时释放 IME 桥接焦点，但保留进程（后续登录界面可能需要）
    ImeBridgeManager.instance.releaseFocus();
    super.dispose();
  }

  void _onStateChanged() {
    if (!_state.isLoggedIn) {
      // 被踢出或断开连接 → 返回登录
      Navigator.of(context).pushReplacementNamed('/login');
    }
  }

  void _sendMessage() {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty) return;

    final current = _state.currentChat;
    if (current == null) return;

    if (current.startsWith('group_')) {
      final groupId = int.tryParse(current.substring(6));
      if (groupId != null) {
        widget.socketService.sendGroupChat(groupId, text);
      }
    } else {
      widget.socketService.sendChat(current, text);
    }

    _inputCtrl.clear();
  }

  void _sendFile() async {
    final current = _state.currentChat;
    if (current == null) return;

    final result = await showFilePicker(context);
    if (result != null) {
      widget.socketService.sendFile(current, result.path, result.name);
    }
  }

  void _showAddFriendDialog() {
    showAddFriendDialog(context, (username) {
      widget.socketService.addFriend(username);
    });
  }

  void _showCreateGroupDialog() {
    showCreateGroupDialog(context, (name) {
      widget.socketService.createGroup(name);
    });
  }

  void _showJoinGroupDialog() {
    showJoinGroupDialog(context, (id) {
      widget.socketService.joinGroup(id);
    });
  }

  void _showAdminPanel() {
    showAdminPanel(context, widget.socketService, _state);
  }

  void _logout() {
    widget.socketService.disconnect();
    if (mounted) {
      Navigator.of(context).pushReplacementNamed('/login');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _state,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: Text('聊天室 - ${_state.username ?? ""}'),
            actions: [
              // 文件请求指示器
              if (_state.hasPendingFileRequests)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Badge(
                    label: Text('${_state.pendingFileRequests.length}'),
                    child: IconButton(
                      icon: const Icon(Icons.folder_rounded),
                      tooltip: '待处理文件请求',
                      onPressed: _showFileRequests,
                    ),
                  ),
                ),

              // 好友请求指示器
              if (_state.pendingRequests.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Badge(
                    label: Text('${_state.pendingRequests.length}'),
                    child: IconButton(
                      icon: const Icon(Icons.people_rounded),
                      tooltip: '待处理好友请求',
                      onPressed: _showFriendRequests,
                    ),
                  ),
                ),

              // 管理员面板
              if (_state.isAdmin)
                IconButton(
                  icon: const Icon(Icons.admin_panel_settings),
                  tooltip: '管理面板',
                  onPressed: _showAdminPanel,
                ),

              // 退出
              IconButton(
                icon: const Icon(Icons.logout),
                tooltip: '退出',
                onPressed: _logout,
              ),
            ],
          ),
          body: Row(
            children: [
              // === 左侧：会话列表 ===
              Sidebar(
                chatTargets: _state.chatTargets,
                currentChat: _state.currentChat,
                onSelectChat: (key) => _state.selectChat(key),
                onAddFriend: _showAddFriendDialog,
                onCreateGroup: _showCreateGroupDialog,
                onJoinGroup: _showJoinGroupDialog,
              ),

              // 分隔线
              const VerticalDivider(width: 1),

              // === 右侧：聊天区域 ===
              Expanded(
                child: _state.currentChat != null
                    ? ChatView(
                        chatKey: _state.currentChat!,
                        messages: _state.getMessages(_state.currentChat!),
                        username: _state.username!,
                        inputCtrl: _inputCtrl,
                        onSend: _sendMessage,
                        onSendFile: _sendFile,
                        onRecall: (msgId) {
                          widget.socketService.recallMessage(
                            msgId,
                            _state.currentChat!,
                          );
                        },
                      )
                    : const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.chat_rounded, size: 64, color: Colors.grey),
                            SizedBox(height: 16),
                            Text(
                              '选择一个会话开始聊天',
                              style: TextStyle(color: Colors.grey, fontSize: 16),
                            ),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showFriendRequests() {
    showFriendRequestsDialog(context, _state.pendingRequests.toList(),
        (username, accept) {
      if (accept) {
        widget.socketService.acceptFriend(username);
      } else {
        widget.socketService.rejectFriend(username);
      }
    });
  }

  void _showFileRequests() {
    showFileRequestsDialog(context, _state.pendingFileRequests.toList(),
        (request, accept) {
      if (request.isGroupFile) {
        widget.socketService.respondGroupFileRequest(
          request.messageId,
          request.groupId!,
          accept,
        );
      } else {
        widget.socketService.respondFileRequest(
          request.messageId,
          request.sender,
          accept,
        );
      }
    });
  }
}
