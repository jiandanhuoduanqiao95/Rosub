// ============================================================
// state_manager.dart 攻击性 / 边界测试（测试强化新增）
// ============================================================
// 以"破坏者"视角打击 AppState 的每个状态流转：
//   - 登出清理的遗漏项（noMoreHistory / transfers / processedGroupFileRequests）
//   - 未读计数在未登录 / 重复登录下的行为
//   - addMessage 去重与跨会话状态更新
//   - prependHistoryMessages 全重复 / 同时间戳 / 大列表
//   - 内部可变集合泄漏（messages 直接返回内部引用）
//   - displayNameForChat 畸形 key、chatTargets 碰撞
//   - 状态日志截断边界、通知队列空消费
// ============================================================

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/state_manager.dart';

AppState get state => AppState.instance;

void resetState() {
  state
    ..setLoggedOut()
    ..setConnectionStatus(ConnectionStatus.disconnected);
}

void main() {
  setUp(resetState);

  group('登出清理的遗漏项（记录现状）', () {
    test('setLoggedOut 不清除 noMoreHistory 之外的其他集合以外, groups 消息清空', () {
      state.setLoggedIn('alice', false);
      state.setGroups([Group(id: 1, name: 'g')]);
      state.setFriends(['bob']);
      state.addMessage(
          'bob', ChatMessage(sender: 'bob', content: 'x', messageId: 'm1'));
      state.addFileRequest(FileRequest(
          messageId: 'f1', sender: 'bob', filename: 'a', filesize: 1));
      state.updateTransfer('t1', 10, 100);
      state.setNoMoreHistory('bob');

      state.setLoggedOut();

      expect(state.groups, isEmpty);
      expect(state.friends, isEmpty);
      expect(state.messages, isEmpty);
      expect(state.pendingFileRequests, isEmpty);
      expect(state.transferFraction('t1'), isNull);
      expect(state.hasMoreHistory('bob'), isTrue,
          reason: '登出后 noMoreHistory 被清空');
      expect(state.unreadOf('bob'), 0);
      expect(state.noticeQueue, isEmpty);
    });

    test('setLoggedOut 不清除 processedGroupFileRequests（跨会话去重状态泄漏，记录现状）', () {
      expect(state.markGroupFileProcessed('gmsg1'), isTrue);
      state.setLoggedIn('alice', false);
      state.setLoggedOut();
      // 重新登录后同一 messageId 的群文件请求不再入队
      expect(state.markGroupFileProcessed('gmsg1'), isFalse,
          reason: '去重集合跨登出存活 —— 潜在状态泄漏，记录行为');
    });

    test('setLoggedOut 不重置 reconnectAttempts（记录现状）', () {
      state.setLoggedIn('alice', false);
      state.setReconnectAttempt(4);
      state.setLoggedOut();
      expect(state.reconnectAttempts, 4,
          reason: '登出不清零重连计数，由下次 setLoggedIn 清零');
    });

    test('setLoggedOut 保留 statusLog（日志跨会话保留，记录现状）', () {
      state.setLoggedIn('alice', false);
      state.log('first session');
      state.setLoggedOut();
      expect(state.statusLog.any((l) => l.contains('first session')), isTrue);
    });
  });

  group('未读计数攻击', () {
    test('未登录（username=null）时他人消息计入未读', () {
      // 不调用 setLoggedIn，直接收消息
      state.addMessage(
          'bob',
          ChatMessage(
              sender: 'bob', content: 'x', messageId: 'm1', status: 'sent'));
      expect(state.unreadOf('bob'), 1);
    });

    test('未登录时 status=sent 的自身消息也计入未读（_username 为 null 无法比对）', () {
      state.addMessage(
          'bob',
          ChatMessage(
              sender: 'alice', content: 'x', messageId: 'm1', status: 'sent'));
      expect(state.unreadOf('bob'), 1, reason: '未登录时无法判断"自己"，任何 sent 消息都计未读');
    });

    test('重复登录不清空旧未读（记录现状：依赖 setLoggedOut 清理）', () {
      state.setLoggedIn('alice', false);
      state.addMessage(
          'bob',
          ChatMessage(
              sender: 'bob', content: 'x', messageId: 'm1', status: 'sent'));
      expect(state.unreadOf('bob'), 1);

      // 不登出直接重新登录
      state.setLoggedIn('bob', false);
      expect(state.unreadOf('bob'), 1, reason: 'setLoggedIn 不清未读');
    });

    test('selectChat(null) 不清除当前会话未读', () {
      state.setLoggedIn('alice', false);
      state.addMessage(
          'bob',
          ChatMessage(
              sender: 'bob', content: 'x', messageId: 'm1', status: 'sent'));
      state.selectChat(null);
      expect(state.unreadOf('bob'), 1);
    });

    test('未读计数超大不溢出（int 累加）', () {
      state.setLoggedIn('alice', false);
      for (var i = 0; i < 50000; i++) {
        state.addMessage(
            'bob',
            ChatMessage(
                sender: 'bob',
                content: '$i',
                messageId: 'm$i',
                status: 'sent'));
      }
      expect(state.unreadOf('bob'), 50000);
      expect(state.totalUnread, 50000);
    });
  });

  group('addMessage 去重与状态更新', () {
    setUp(() => state.setLoggedIn('alice', false));

    test('重复 messageId 只更新状态，不重复计未读', () {
      state.addMessage(
          'bob',
          ChatMessage(
              sender: 'bob', content: '1', messageId: 'm1', status: 'sent'));
      expect(state.unreadOf('bob'), 1);
      // 服务器回显同 id 不同 status
      state.addMessage(
          'bob',
          ChatMessage(
              sender: 'bob',
              content: '1',
              messageId: 'm1',
              status: 'delivered'));
      expect(state.getMessages('bob').length, 1);
      expect(state.getMessages('bob').first.status, 'delivered');
      expect(state.unreadOf('bob'), 1, reason: '去重路径不再重复计未读');
    });

    test('重复 messageId 但内容/发送者不同：保留旧内容（记录现状）', () {
      state.addMessage(
          'bob', ChatMessage(sender: 'bob', content: '原内容', messageId: 'm1'));
      state.addMessage(
          'bob',
          ChatMessage(
              sender: 'malice',
              content: '篡改内容',
              messageId: 'm1',
              status: 'delivered'));
      final msg = state.getMessages('bob').first;
      expect(msg.sender, 'bob');
      expect(msg.content, '原内容');
      expect(msg.status, 'delivered');
    });

    test('【已修复】空 messageId 的消息各自保存而非合并（回归锁定）', () {
      // 回归锁定：两条不同内容的消息（messageId 均为 ''）都应入列。
      // 曾因 _messageMap[''] 命中同一条，第二条被吞 → 只剩 1 条。
      state.addMessage(
          'bob', ChatMessage(sender: 'bob', content: 'a', messageId: ''));
      state.addMessage(
          'bob', ChatMessage(sender: 'bob', content: 'b', messageId: ''));
      expect(state.getMessages('bob').length, 2, reason: '2 条消息均保留（缺陷修复后应成立）');
      final contents = state.getMessages('bob').map((m) => m.content).toSet();
      expect(contents, {'a', 'b'});
    });

    test('同一消息 id 跨会话：状态更新作用于首次注册的会话（记录现状）', () {
      state.addMessage(
          'bob', ChatMessage(sender: 'bob', content: 'x', messageId: 'dup'));
      state.addMessage(
          'carol',
          ChatMessage(
              sender: 'carol',
              content: 'y',
              messageId: 'dup',
              status: 'delivered'));
      expect(state.getMessages('bob').length, 1);
      expect(state.getMessages('carol'), isEmpty);
      expect(state.getMessages('bob').first.status, 'delivered');
    });
  });

  group('prependHistoryMessages 攻击', () {
    setUp(() => state.setLoggedIn('alice', false));

    test('全部重复时列表不排序、无重复添加', () {
      final t1 = DateTime(2026, 1, 1, 10);
      final t2 = DateTime(2026, 1, 1, 9);
      state.addMessage(
          'bob',
          ChatMessage(
              sender: 'bob', content: 'a', messageId: 'm1', timestamp: t1));
      state.prependHistoryMessages('bob', [
        ChatMessage(
            sender: 'bob', content: 'a', messageId: 'm1', timestamp: t1),
        ChatMessage(
            sender: 'bob', content: 'a', messageId: 'm1', timestamp: t2),
      ]);
      expect(state.getMessages('bob').length, 1);
    });

    test('同时间戳消息保持集合等价（排序不稳定不校验顺序）', () {
      final t = DateTime(2026, 1, 1, 10);
      state.prependHistoryMessages('bob', [
        ChatMessage(sender: 'bob', content: 'x', messageId: 'a', timestamp: t),
        ChatMessage(sender: 'bob', content: 'y', messageId: 'b', timestamp: t),
        ChatMessage(sender: 'bob', content: 'z', messageId: 'c', timestamp: t),
      ]);
      final contents = state.getMessages('bob').map((m) => m.content).toSet();
      expect(contents, {'x', 'y', 'z'});
    });

    test('1000 条历史消息去重后数量正确', () {
      final base = DateTime(2026, 1, 1);
      final msgs = List.generate(
          1000,
          (i) => ChatMessage(
                sender: 'bob',
                content: 'h$i',
                messageId: 'hid$i',
                timestamp: base.add(Duration(minutes: i)),
              ));
      state.prependHistoryMessages('bob', msgs);
      expect(state.getMessages('bob').length, 1000);
      // 再追加 500 条旧的
      final older = List.generate(
          500,
          (i) => ChatMessage(
                sender: 'bob',
                content: 'o$i',
                messageId: 'oid$i',
                timestamp: base.subtract(Duration(minutes: 500 - i)),
              ));
      state.prependHistoryMessages('bob', older);
      expect(state.getMessages('bob').length, 1500);
      // 时间有序：最旧的在前
      expect(state.getMessages('bob').first.messageId, 'oid0');
      expect(state.getMessages('bob').last.messageId, 'hid999');
    });

    test('prependHistoryMessages 不产生未读（历史消息不计未读）', () {
      state.prependHistoryMessages('bob', [
        ChatMessage(
            sender: 'bob', content: 'h', messageId: 'm1', status: 'sent'),
      ]);
      expect(state.unreadOf('bob'), 0);
      expect(state.totalUnread, 0);
    });
  });

  group('集合可变性泄漏（记录现状）', () {
    test('messages getter 暴露内部 Map，外部可直接修改', () {
      state.setLoggedIn('alice', false);
      state.messages['hacked'] = [
        ChatMessage(sender: 'x', content: 'y', messageId: 'h1'),
      ];
      expect(state.getMessages('hacked').length, 1,
          reason: '内部消息表被外部直接注入 —— 无防御拷贝');
    });

    test('getMessages 返回内部 List 引用，外部可绕过去重直接添加', () {
      state.setLoggedIn('alice', false);
      // 先让 'bob' 会话存在，getMessages 才会返回内部列表引用
      state.addMessage(
          'bob', ChatMessage(sender: 'bob', content: '合法', messageId: 'm1'));
      final list = state.getMessages('bob');
      list.add(ChatMessage(sender: 'hack', content: 'x', messageId: 'hm1'));
      expect(state.getMessages('bob').length, 2,
          reason: 'getMessages 返回内部可变引用，可绕过去重添加');
      // 注意：getMessages('不存在') 返回的是临时空列表，修改无效（对照行为）
      final ghost = state.getMessages('ghost');
      ghost.add(ChatMessage(sender: 'h', content: 'h', messageId: 'g1'));
      expect(state.getMessages('ghost'), isEmpty);
    });

    test('pendingFileRequests 返回内部 List（与消息表同级别泄漏）', () {
      state.pendingFileRequests.add(
          FileRequest(messageId: 'z', sender: 'z', filename: 'z', filesize: 1));
      expect(state.hasPendingFileRequests, isTrue);
    });
  });

  group('displayNameForChat 与 chatTargets 攻击', () {
    test('畸形 group key 全部回退原值', () {
      for (final k in [
        'group_',
        'group_abc',
        'group_9999999999999999999999',
        'group'
      ]) {
        expect(state.displayNameForChat(k), k, reason: k);
      }
    });

    test('超大 groupId 溢出 int 时回退原 key', () {
      expect(state.displayNameForChat('group_9223372036854775808'),
          'group_9223372036854775808');
    });

    test('好友名与群组 key 字符串碰撞（好友名 group_1）', () {
      state.setLoggedIn('alice', false);
      state.setFriends(['group_1']);
      state.setGroups([Group(id: 1, name: '群')]);
      final keys = state.chatTargets.map((t) => t.key).toList();
      // 两个 key 相同的目标同时存在（好友 + 群组）
      expect(keys.where((k) => k == 'group_1').length, 2);
      final groupTarget = state.chatTargets.firstWhere((t) => t.isGroup);
      expect(groupTarget.key, 'group_1');
      final friendTarget = state.chatTargets.firstWhere((t) => !t.isGroup);
      expect(friendTarget.key, 'group_1');
    });

    test('getGroupName 对已 leaveGroup 的群返回 null', () {
      state.setLoggedIn('alice', false);
      state.addGroup(Group(id: 1, name: 'g'));
      state.leaveGroup(1);
      expect(state.getGroupName(1), isNull);
      expect(state.displayNameForChat('group_1'), '群组 1');
    });
  });

  group('状态日志与通知', () {
    test('日志截断保持上限 500，且移除最旧 100 条', () {
      state.setLoggedIn('alice', false);
      for (var i = 0; i < 600; i++) {
        state.log('TRUNC$i');
      }
      // 注意：statusLog 为跨测试累积的单例（登出不清理），只断言相对顺序
      expect(state.statusLog.length, lessThanOrEqualTo(500));
      expect(state.statusLog.last.contains('TRUNC599'), isTrue);
      // 600 条超上限：最旧的 TRUNC0 必然被整体截掉，头部必然是某条 TRUNC
      // （_log 前缀 '[HH:MM:SS] '，故用 contains 而非 startsWith）
      expect(state.statusLog.first.contains('TRUNC'), isTrue);
      expect(state.statusLog.any((l) => l.contains('TRUNC0')), isFalse);
    });

    test('consumeNotice 空队列不抛异常', () {
      expect(() => state.consumeNotice(), returnsNormally);
    });

    test('showNotice 大量通知不重复消费', () {
      for (var i = 0; i < 50; i++) {
        state.showNotice('n$i');
      }
      expect(state.noticeQueue.length, 50);
      for (var i = 0; i < 50; i++) {
        state.consumeNotice();
      }
      expect(state.noticeQueue, isEmpty);
    });
  });

  group('传输进度与文件请求攻击', () {
    test('transferred 超过 total 时 isTransferring 判定为完成', () {
      state.setLoggedIn('alice', false);
      state.updateTransfer('t1', 999, 100);
      expect(state.isTransferring('t1'), isFalse);
      expect(state.transferFraction('t1'), 1.0);
    });

    test('removeTransfer 不存在的 id 不崩溃', () {
      expect(() => state.removeTransfer('ghost'), returnsNormally);
    });

    test('addFileRequest 大量请求不重复', () {
      for (var i = 0; i < 100; i++) {
        state.addFileRequest(FileRequest(
            messageId: 'f1', sender: 's', filename: 'a', filesize: 1));
      }
      expect(state.pendingFileRequests.length, 1);
    });

    test('removeFileRequest 批量移除', () {
      for (var i = 0; i < 10; i++) {
        state.addFileRequest(FileRequest(
            messageId: 'f$i', sender: 's', filename: 'a', filesize: 1));
      }
      for (var i = 0; i < 10; i++) {
        state.removeFileRequest('f$i');
      }
      expect(state.pendingFileRequests, isEmpty);
    });
  });

  group('幂等与空操作', () {
    test('leaveGroup 不存在的群不崩溃', () {
      expect(() => state.leaveGroup(999), returnsNormally);
    });

    test('removeFriend 不存在的用户不崩溃', () {
      expect(() => state.removeFriend('nobody'), returnsNormally);
    });

    test('updateGroupMembers 空列表可清空成员', () {
      state.setLoggedIn('alice', false);
      state.addGroup(Group(id: 1, name: 'g'));
      state.updateGroupMembers(1, ['a', 'b']);
      state.updateGroupMembers(1, []);
      expect(state.groups.first.members, isEmpty);
    });

    test('selectChat 重复选择同一会话不崩溃', () {
      state.setLoggedIn('alice', false);
      state.selectChat('bob');
      state.selectChat('bob');
      expect(state.currentChat, 'bob');
    });

    test('addGroup 同 id 不同名：保留第一个', () {
      state.setLoggedIn('alice', false);
      state.addGroup(Group(id: 1, name: '原名'));
      state.addGroup(Group(id: 1, name: '改名'));
      expect(state.groups.length, 1);
      expect(state.groups.first.name, '原名');
    });
  });
}
