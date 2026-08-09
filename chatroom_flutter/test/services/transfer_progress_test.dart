// ============================================================
// 文件传输进度状态测试（阶段 G：传输可视化）
// ============================================================
// 覆盖 AppState 的传输进度状态：
//   - updateTransfer / removeTransfer / transferFraction / isTransferring
//   - 多传输互不影响、登出清空
//   - TransferProgress 模型边界（total=0、完成判断）
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

  group('TransferProgress 模型', () {
    test('fraction 正确计算', () {
      const p = TransferProgress(messageId: 'x', total: 200, transferred: 50);
      expect(p.fraction, closeTo(0.25, 0.001));
      expect(p.done, isFalse);
    });

    test('total=0 时 fraction 为 0，不崩溃', () {
      const p = TransferProgress(messageId: 'x', total: 0, transferred: 0);
      expect(p.fraction, 0);
    });

    test('transferred >= total 视为完成', () {
      const p = TransferProgress(messageId: 'x', total: 100, transferred: 100);
      expect(p.done, isTrue);
      expect(p.fraction, 1.0);
    });
  });

  group('AppState 传输进度', () {
    test('updateTransfer 记录进度并可查询 fraction', () {
      state.setLoggedIn('alice', false);
      state.updateTransfer('t1', 50, 200);
      expect(state.transferFraction('t1'), closeTo(0.25, 0.001));
      expect(state.isTransferring('t1'), isTrue);
    });

    test('多次 updateTransfer 覆盖进度', () {
      state.updateTransfer('t1', 50, 200);
      state.updateTransfer('t1', 150, 200);
      expect(state.transferFraction('t1'), closeTo(0.75, 0.001));
    });

    test('removeTransfer 移除进度', () {
      state.updateTransfer('t1', 100, 200);
      state.removeTransfer('t1');
      expect(state.transferFraction('t1'), isNull);
      expect(state.isTransferring('t1'), isFalse);
    });

    test('多个传输互不影响', () {
      state.updateTransfer('t1', 10, 100);
      state.updateTransfer('t2', 90, 100);
      expect(state.transferFraction('t1'), closeTo(0.1, 0.001));
      expect(state.transferFraction('t2'), closeTo(0.9, 0.001));
      state.removeTransfer('t1');
      expect(state.transferFraction('t2'), closeTo(0.9, 0.001));
    });

    test('未知 messageId 返回 null', () {
      expect(state.transferFraction('ghost'), isNull);
      expect(state.isTransferring('ghost'), isFalse);
    });

    test('setLoggedOut 清空全部传输状态', () {
      state.setLoggedIn('alice', false);
      state.updateTransfer('t1', 5, 100);
      state.setLoggedOut();
      expect(state.transferFraction('t1'), isNull);
      expect(state.isTransferring('t1'), isFalse);
    });
  });
}
