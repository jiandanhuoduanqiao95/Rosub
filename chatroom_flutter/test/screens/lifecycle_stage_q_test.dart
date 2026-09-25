// ============================================================
// 移动生命周期接线契约（阶段 Q0-5 —— TDD，未实现）
// ============================================================
// 覆盖《软件开发文档4.1.0.md》§13.9 阶段 Q「Q0-5 移动生命周期接线」：
//
//   AppLifecycleState.resumed 时校验 socket 存活并重连（现 detached
//   仅关 IME 桥接，属桌面语义）；paused 下 socket 断开属预期，回前台
//   走既有重连 + 离线补发链路（本地缓存离线可读已落地）。
//
// 契约：
//
//   ① 新增 lib/services/session_lifecycle.dart ——
//
//      class SessionLifecycleGuard {   // 应用级单例（FocusTracker 惯例）
//        static final SessionLifecycleGuard instance;
//        void bind({required bool Function() isSocketAlive,
//                   required VoidCallback reconnect});
//        void unbind();
//        void handleResumed();         // 仅 resumed 语义
//      }
//
//      · SocketService 无全局单例（LoginScreen 持有），ChatScreen 在
//        initState/dispose bind/unbind（isSocketAlive = socket != null）
//      · handleResumed：isSocketAlive() == false → 调 reconnect()；
//        活着 → 无操作；未 bind → 无操作不崩
//      · 透传语义：guard 不做防抖，重连幂等由 reconnect 回调（
//        SocketService._reconnecting 检查）保证
//
//   ② SocketService 新增公开方法 ——
//
//      Future<void> ensureConnectedOnResume()
//
//      · 已登录（重连凭据在内存）+ 非主动断开 + socket 已死 + 未在
//        重连 → 走既有 _onConnectionLost 链路（重连循环 + 重登录 +
//        离线补发，阶段 D/I 语义复用）
//      · 其余情况 no-op（幂等）：未登录 / 主动退出 / 正在重连 / 存活
//      · 未连接契约测试仿 socket_service_stage_p_test（H5/P3 惯例）：
//        无真 socket 环境，锁定 no-op 路径安全；真实重连链路由阶段 D
//        既有测试与 8 个 E2E 守门
//
//   ③ main.dart 接线 ——
//
//      didChangeAppLifecycleState 的 resumed 分支调
//      SessionLifecycleGuard.instance.handleResumed()；detached 分支
//      关闭 IME 桥接的桌面语义原样保留（源码扫描锁定）
//
//   桌面语义兼容：Linux 窗口从最小化恢复同样触发 resumed，此时 socket
//   存活 → guard 无操作（接线在桌面天然无害，测试覆盖）。
//
// 实现前：session_lifecycle.dart 与 ensureConnectedOnResume 不存在，
// 本文件编译失败，属 TDD 红。实现后：全部转绿。
// ============================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chatroom_flutter/models/chat_models.dart';
import 'package:chatroom_flutter/services/session_lifecycle.dart';
import 'package:chatroom_flutter/services/socket_service.dart';
import 'package:chatroom_flutter/services/state_manager.dart';

String srcOf(String relPath) => File('lib/$relPath').readAsStringSync();

int countOf(String source, String needle) => source.split(needle).length - 1;

AppState get state => AppState.instance;

void resetState() {
  state
    ..setLoggedOut()
    ..setConnectionStatus(ConnectionStatus.disconnected);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(resetState);
  tearDown(resetState);

  group('Q0-5 —— SessionLifecycleGuard 行为（resumed 校验存活并重连）', () {
    test('应用级单例', () {
      expect(
          identical(
              SessionLifecycleGuard.instance, SessionLifecycleGuard.instance),
          isTrue);
    });

    test('未 bind 时 handleResumed 无操作不崩', () {
      SessionLifecycleGuard.instance.unbind();
      expect(() => SessionLifecycleGuard.instance.handleResumed(),
          returnsNormally);
    });

    test('socket 已死 → handleResumed 触发 reconnect（恰一次）', () {
      var reconnectCount = 0;
      SessionLifecycleGuard.instance.bind(
        isSocketAlive: () => false,
        reconnect: () => reconnectCount++,
      );
      SessionLifecycleGuard.instance.handleResumed();
      expect(reconnectCount, 1, reason: 'paused 下 socket 断开属预期，回前台须走重连链路');
      SessionLifecycleGuard.instance.unbind();
    });

    test('socket 存活 → handleResumed 无操作（桌面最小化恢复场景无害）', () {
      var reconnectCount = 0;
      SessionLifecycleGuard.instance.bind(
        isSocketAlive: () => true,
        reconnect: () => reconnectCount++,
      );
      SessionLifecycleGuard.instance.handleResumed();
      expect(reconnectCount, 0);
      SessionLifecycleGuard.instance.unbind();
    });

    test('unbind 后 handleResumed 无操作（防跨界面串扰，FileDrop 惯例）', () {
      var reconnectCount = 0;
      SessionLifecycleGuard.instance.bind(
        isSocketAlive: () => false,
        reconnect: () => reconnectCount++,
      );
      SessionLifecycleGuard.instance.unbind();
      SessionLifecycleGuard.instance.handleResumed();
      expect(reconnectCount, 0);
    });

    test('连续多次 resumed（socket 持续死亡）→ 逐次透传（幂等责任在 reconnect 回调）', () {
      var reconnectCount = 0;
      SessionLifecycleGuard.instance.bind(
        isSocketAlive: () => false,
        reconnect: () => reconnectCount++,
      );
      SessionLifecycleGuard.instance.handleResumed();
      SessionLifecycleGuard.instance.handleResumed();
      SessionLifecycleGuard.instance.handleResumed();
      expect(reconnectCount, 3,
          reason: 'guard 不做防抖；重连幂等由 SocketService._reconnecting 保证');
      SessionLifecycleGuard.instance.unbind();
    });

    test('Q1 五轮：handlePaused 透传（onPause 回调；未 bind 不崩）', () {
      var pauseCount = 0;
      SessionLifecycleGuard.instance.unbind();
      expect(
          () => SessionLifecycleGuard.instance.handlePaused(), returnsNormally);
      SessionLifecycleGuard.instance.bind(
        isSocketAlive: () => false,
        reconnect: () {},
        onPause: () => pauseCount++,
      );
      SessionLifecycleGuard.instance.handlePaused();
      expect(pauseCount, 1, reason: 'paused 透传给 SocketService.markAppPaused');
      SessionLifecycleGuard.instance.unbind();
      SessionLifecycleGuard.instance.handlePaused();
      expect(pauseCount, 1, reason: 'unbind 后无操作');
    });

    test('重复 bind 覆盖旧回调（新 reconnect 生效、旧的不触发）', () {
      var oldCount = 0;
      var newCount = 0;
      SessionLifecycleGuard.instance.bind(
        isSocketAlive: () => false,
        reconnect: () => oldCount++,
      );
      SessionLifecycleGuard.instance.bind(
        isSocketAlive: () => false,
        reconnect: () => newCount++,
      );
      SessionLifecycleGuard.instance.handleResumed();
      expect(oldCount, 0);
      expect(newCount, 1);
      SessionLifecycleGuard.instance.unbind();
    });

    test('判定读取实时 socket 状态（死→活后 resumed 不再触发）', () {
      var alive = false;
      var reconnectCount = 0;
      SessionLifecycleGuard.instance.bind(
        isSocketAlive: () => alive,
        reconnect: () => reconnectCount++,
      );
      SessionLifecycleGuard.instance.handleResumed();
      expect(reconnectCount, 1);
      alive = true;
      SessionLifecycleGuard.instance.handleResumed();
      expect(reconnectCount, 1, reason: '重连成功后回前台不再重复触发');
      SessionLifecycleGuard.instance.unbind();
    });
  });

  group(
      'Q0-5 —— SocketService.ensureConnectedOnResume 未连接契约'
      '（仿 socket_service_stage_p_test 惯例）', () {
    test('未登录状态调用：不崩、不触发重连、无副作用', () async {
      final service = SocketService();
      await service.ensureConnectedOnResume();
      expect(service.isReconnecting, isFalse, reason: '未登录无凭据，不得进入重连循环');
      expect(state.noticeQueue, isEmpty);
      expect(state.messages.length, state.messages.length, reason: '不触碰既有消息状态');
    });

    test('状态登录但服务未真正 login（无保存凭据）→ no-op（防无限重连循环）', () async {
      final service = SocketService();
      state.setLoggedIn('alice', false);
      await service.ensureConnectedOnResume();
      expect(service.isReconnecting, isFalse,
          reason: '凭据缺失时必须静默返回——否则测试/边界态会启动无限重连循环');
      expect(state.noticeQueue, isEmpty);
    });

    test('主动退出（disconnect）后调用 → no-op（不回连）', () async {
      final service = SocketService();
      service.disconnect();
      await service.ensureConnectedOnResume();
      expect(service.isReconnecting, isFalse,
          reason: '_intentionalDisconnect 语义：用户主动退出不自动重连');
      expect(state.noticeQueue, isEmpty);
    });

    test('重复调用安全（幂等）', () async {
      final service = SocketService();
      state.setLoggedIn('alice', false);
      await service.ensureConnectedOnResume();
      await service.ensureConnectedOnResume();
      await service.ensureConnectedOnResume();
      expect(service.isReconnecting, isFalse);
    });
  });

  group('Q0-5 —— main.dart / ChatScreen 接线（源码扫描锁定）', () {
    test('session_lifecycle.dart 存在', () {
      expect(File('lib/services/session_lifecycle.dart').existsSync(), isTrue);
    });

    test('main.dart resumed 分支接线 SessionLifecycleGuard.handleResumed', () {
      final src = srcOf('main.dart');
      expect(src.contains('SessionLifecycleGuard'), isTrue);
      expect(src.contains('handleResumed'), isTrue);
    });

    test('main.dart detached 分支保留 IME 桥接清理（桌面语义不变）', () {
      final src = srcOf('main.dart');
      expect(src.contains('AppLifecycleState.detached'), isTrue);
      expect(src.contains('ImeBridgeManager.instance.shutdown'), isTrue,
          reason: '现 detached 仅关 IME 桥接属桌面语义，Q0-5 不删除');
    });

    test('main.dart resumed 分支保留 FocusTracker 桌面焦点语义', () {
      final src = srcOf('main.dart');
      expect(src.contains('updateFocus'), isTrue,
          reason: 'resumed=聚焦 / inactive,paused=失焦（H1）不回退');
    });

    test('chat_screen.dart bind/unbind 接线（initState/dispose）', () {
      final src = srcOf('screens/chat_screen.dart');
      expect(countOf(src, 'SessionLifecycleGuard'), greaterThanOrEqualTo(2),
          reason: 'ChatScreen 持有 SocketService，进出界面绑定/解绑 guard');
      expect(src.contains('isSocketAlive'), isTrue);
    });
  });

  group('Q1 五轮 —— 僵尸连接自愈加固（源码扫描锁定，问题1 重大回归）', () {
    test('ChatScreen 接线 isSocketAlive 恒 false（僵尸 socket 不得短路探测）', () {
      final src = srcOf('screens/chat_screen.dart');
      expect(src.contains('isSocketAlive: () => false'), isTrue,
          reason: 'socket 对象存在不代表连接存活——resume 恒走'
              'ensureConnectedOnResume（内部僵死探测）');
      expect(
          src.contains(
              'isSocketAlive: () => widget.socketService.socket != null'),
          isFalse,
          reason: '旧判定把服务端已踢线的僵尸连接当存活，前台永不重连');
      expect(
          src.contains('onPause: () => widget.socketService.markAppPaused()'),
          isTrue,
          reason: 'paused 透传记录真后台时刻');
    });

    test('main.dart paused 分支透传 guard（源码扫描）', () {
      final src = srcOf('main.dart');
      expect(src.contains('SessionLifecycleGuard.instance.handlePaused()'),
          isTrue);
    });

    test('心跳 ping 带超时（flush 挂起不死锁发送队列）+ 入站新鲜度哨兵', () {
      final src = srcOf('services/socket_service.dart');
      expect(src.contains(".timeout(const Duration(seconds: 5));"), isTrue,
          reason: '阶段 J 已知 dart:io flush 挂起竞态——ping 挂起会卡死'
              '_sendTail（全部发送停摆且永不判死）');
      expect(src.contains('_lastIncomingAt'), isTrue);
      expect(src.contains('120s 未收到任何服务端消息'), isTrue,
          reason: 'pong 链路失效兜底：120s 无入站强制重连');
      expect(src.contains('pausedDuringReceive'), isTrue,
          reason: '_receivingFile 卡真 + 真后台暂停 → 判死重连'
              '（离线补发恢复），不得跳过探测形成死锁');
    });
  });
}
