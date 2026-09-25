/// 任务栏图标闪烁（阶段 H1/H2 —— 类微信未读提醒）
///
/// 新消息到达且窗口未聚焦时，通过 GTK urgency hint 让任务栏图标闪烁
/// （GNOME / KDE 等常见桌面环境均支持），替代系统弹窗通知。
/// - flash()：开始闪烁（enabled=false 时静默；impl 异常隔离）
/// - clearUrgency()：清除闪烁（窗口重新聚焦时由 main.dart 调用，不受 enabled 限制）
/// - maybeFlashForMessage()：未聚焦窗口时收到新消息才闪烁：
///     chat / group_chat / file / file_request / group_file_request → 闪烁
///     system 且 sender='[系统公告]' → 闪烁
///     其余（自己发送 / 已读历史 / 撤回 / 普通系统消息 / 未知类型）不闪烁。
/// 调用点（接入）：SocketService._handleMessage 收到新消息后调用。
///
/// 阶段 K3（P1-13/14）扩展（用户决策修订 2026-08-18）：
/// - 逐会话静音（AppState.isMuted(chatKey)）→ 永不闪烁、永不响铃
/// - 全局免打扰（dndEnabled + dndEndTime 绝对结束时刻）：
///   dndEnabled 且 当前时刻 < dndEndTime → 全部不提醒；
///   **置顶会话（AppState.isPinned）不受免打扰限制（仍提醒）**；
///   到期后由 checkDndExpiry() 自动关闭开关并提醒用户（ChatScreen 定时器驱动）
/// - 新消息提示音（soundEnabled，可开关）：声音通道与窗口聚焦无关，
///   playSoundImpl 可注入（测试）；默认实现生成科技感和弦提示音并调用
///   paplay / aplay 播放（无音频后端时静默降级）
/// 判定顺序：enabled → status/sender → 类型规则 → 静音/免打扰（置顶豁免）→ 响铃 → 聚焦 → 闪烁

import 'dart:ffi';
import 'package:flutter/foundation.dart';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../models/chat_models.dart';
import '../platform/android_system.dart';
import '../platform/capabilities.dart';
import 'focus_tracker.dart';
import 'state_manager.dart';

class TaskbarNotifier {
  TaskbarNotifier._();

  /// 总开关
  static bool enabled = true;

  // ---- 阶段 K3（P1-13/14）免打扰与提示音设置 ----

  /// 提示音开关（默认开）
  static bool soundEnabled = true;

  /// 免打扰总开关（默认关）
  static bool dndEnabled = false;

  /// 免打扰结束时刻（绝对时间，本地时区）。
  /// 免打扰生效区间：开关开 且 当前时刻 < dndEndTime（精确到日/时/分）。
  /// 到期后 checkDndExpiry() 自动关闭开关（ChatScreen 周期定时器驱动）。
  static DateTime dndEndTime = DateTime.now().add(const Duration(hours: 1));

  /// 可注入时钟（测试）；缺省系统时间
  static DateTime Function() nowProvider = DateTime.now;

  /// 提示音实现（测试可注入；默认生成科技感和弦提示音并播放）
  static void Function() playSoundImpl = _defaultPlaySound;

  static String? _chimeWavPath;

  /// 默认提示音：生成一段双音上行 + 泛音点缀的科技感和弦 WAV
  /// 并调用 paplay/aplay 播放。无音频后端 / 播放失败时静默降级
  /// （不打断消息处理管线）。
  static void _defaultPlaySound() {
    try {
      final wav = ensureChimeWav();
      if (wav == null) return;
      // fire-and-forget：播放失败不影响调用方
      _runPlayer(wav, 'paplay');
    } catch (_) {}
  }

  static Future<void> _runPlayer(String wav, String cmd) async {
    try {
      final result = await Process.run(cmd, [wav]);
      if (result.exitCode != 0 && cmd == 'paplay') {
        // PulseAudio 失败 → 回退 ALSA
        await _runPlayer(wav, 'aplay');
      }
    } catch (_) {
      if (cmd == 'paplay') {
        await _runPlayer(wav, 'aplay');
      }
    }
  }

  /// 生成/复用科技感和弦提示音 WAV 并返回落盘路径（阶段 Q1-2 公开化）。
  ///
  /// 原 _ensureChimeWav 私有实现收敛为公开静态：Android 提示音
  /// （AndroidSoundCapability）经媒体通道复用同一音色文件，避免双份
  /// 生成代码漂移。生成/落盘失败返回 null（调用方静默降级）。
  static String? ensureChimeWav() {
    if (_chimeWavPath != null) return _chimeWavPath;
    try {
      final file =
          File('${Directory.systemTemp.path}/chatroom_notify_chime.wav');
      if (!file.existsSync()) {
        file.writeAsBytesSync(_generateChimeWav());
      }
      _chimeWavPath = file.path;
      return _chimeWavPath;
    } catch (_) {
      return null;
    }
  }

  /// 通话铃声 WAV 落盘（gc8：单遍旋律 ~1.6s，Android 原生 looping /
  /// 桌面 Dart Timer 重播）。与新消息提示音同一音色与音集（A 大调
  /// 三和弦），形成统一产品语言。生成/落盘失败返回 null。
  static String? ensureCallRingtoneWav() {
    if (_callRingtoneWavPath != null) return _callRingtoneWavPath;
    try {
      final file =
          File('${Directory.systemTemp.path}/chatroom_call_ringtone.wav');
      if (!file.existsSync()) {
        file.writeAsBytesSync(_generateCallRingtoneWav());
      }
      _callRingtoneWavPath = file.path;
      return _callRingtoneWavPath;
    } catch (_) {
      return null;
    }
  }

  /// 挂断音 WAV 落盘（gc8：下行 A6→E6→A5 ~0.7s，"结束"语义——铃声
  /// 旋律的倒序）。
  static String? ensureHangupWav() {
    if (_hangupWavPath != null) return _hangupWavPath;
    try {
      final file =
          File('${Directory.systemTemp.path}/chatroom_call_hangup.wav');
      if (!file.existsSync()) {
        file.writeAsBytesSync(_generateHangupWav());
      }
      _hangupWavPath = file.path;
      return _hangupWavPath;
    } catch (_) {
      return null;
    }
  }

  static String? _callRingtoneWavPath;
  static String? _hangupWavPath;

  /// 往 16-bit 单声道 PCM 缓冲叠加一个带泛音的音符（4ms 快速起音 +
  /// 指数衰减包络；正弦基波 + 0.35 二次谐波 + 0.12 三次谐波——chime
  /// 音色合成器，铃声/挂断音共用以保持产品语言一致）
  static void _addNote(List<double> buffer, int sampleRate, double freq,
      int startMs, int durMs, double amp) {
    final start = sampleRate * startMs ~/ 1000;
    final len = sampleRate * durMs ~/ 1000;
    final int end = math.min(start + len, buffer.length);
    for (int i = start; i < end; i++) {
      final int rel = i - start;
      final double t = i / sampleRate;
      final double attack = (rel / (sampleRate * 0.004)).clamp(0.0, 1.0);
      final double decay =
          math.exp(-(rel / (sampleRate * (durMs / 1000.0))) * 4.2);
      final double env = attack * decay;
      double s = math.sin(2 * math.pi * freq * t);
      s += 0.35 * math.sin(2 * math.pi * freq * 2 * t);
      s += 0.12 * math.sin(2 * math.pi * freq * 3 * t);
      buffer[i] += s * amp * env;
    }
  }

  /// PCM 缓冲 → 16-bit 单声道 WAV 字节（RIFF 容器）
  static List<int> _renderWav(List<double> buffer, int sampleRate) {
    final int n = buffer.length;
    final BytesBuilder data = BytesBuilder();
    void writeU32(int v) {
      data.addByte(v & 0xFF);
      data.addByte((v >> 8) & 0xFF);
      data.addByte((v >> 16) & 0xFF);
      data.addByte((v >> 24) & 0xFF);
    }

    void writeU16(int v) {
      data.addByte(v & 0xFF);
      data.addByte((v >> 8) & 0xFF);
    }

    data.add('RIFF'.codeUnits);
    writeU32(36 + n * 2);
    data.add('WAVE'.codeUnits);
    data.add('fmt '.codeUnits);
    writeU32(16);
    writeU16(1);
    writeU16(1);
    writeU32(sampleRate);
    writeU32(sampleRate * 2);
    writeU16(2);
    writeU16(16);
    data.add('data'.codeUnits);
    writeU32(n * 2);
    for (int i = 0; i < n; i++) {
      final double sample = buffer[i].clamp(-1.0, 1.0);
      final int value = (sample * 32767).round().clamp(-32768, 32767);
      writeU16(value & 0xFFFF);
    }
    return data.toBytes();
  }

  /// 通话铃声（gc8，单遍旋律 ~1.5s）：A5→E6→A6 琶音（chime 旋律紧凑
  /// 版）+ E6→A5 回落小尾音，尾部 0.35s 静音缓冲供循环呼吸——同音色
  /// 同音集，与新消息提示音形成统一产品语言。
  static List<int> _generateCallRingtoneWav() {
    const int sampleRate = 44100;
    const int durationMs = 1500;
    final List<double> buffer =
        List.filled(sampleRate * durationMs ~/ 1000, 0.0);
    _addNote(buffer, sampleRate, 880.0, 0, 140, 0.30);
    _addNote(buffer, sampleRate, 1318.5, 100, 180, 0.26);
    _addNote(buffer, sampleRate, 1760.0, 220, 160, 0.12);
    _addNote(buffer, sampleRate, 1318.5, 480, 140, 0.18);
    _addNote(buffer, sampleRate, 880.0, 620, 260, 0.22);
    return _renderWav(buffer, sampleRate);
  }

  /// 挂断音（gc8，~0.7s）：A6→E6→A5 下行三音（铃声/提示音旋律的倒序，
  /// "结束"语义），整体衰减更快更轻。
  static List<int> _generateHangupWav() {
    const int sampleRate = 44100;
    const int durationMs = 700;
    final List<double> buffer =
        List.filled(sampleRate * durationMs ~/ 1000, 0.0);
    _addNote(buffer, sampleRate, 1760.0, 0, 140, 0.16);
    _addNote(buffer, sampleRate, 1318.5, 120, 160, 0.18);
    _addNote(buffer, sampleRate, 880.0, 260, 320, 0.24);
    return _renderWav(buffer, sampleRate);
  }

  /// 生成 16-bit 单声道科技感和弦提示音 WAV（约 520ms）。
  ///
  /// 音色设计：A5(880Hz) 起音 → E6(1318.5Hz) 五度上行接续 → A6(1760Hz)
  /// 高音泛音点缀，正弦基波 + 二次/三次谐波叠加出明亮通透的
  /// "未来感"音色；短促起音 + 指数衰减包络，清脆不刺耳。
  static List<int> _generateChimeWav() {
    const int sampleRate = 44100;
    const int durationMs = 520;
    const int n = sampleRate * durationMs ~/ 1000;
    final List<double> buffer = List.filled(n, 0.0);

    void addNote(double freq, int startMs, int durMs, double amp) {
      final start = sampleRate * startMs ~/ 1000;
      final len = sampleRate * durMs ~/ 1000;
      final int end = math.min(start + len, n);
      for (int i = start; i < end; i++) {
        final int rel = i - start;
        final double t = i / sampleRate;
        // 4ms 快速起音 + 指数衰减（衰减速率随音长归一化）
        final double attack = (rel / (sampleRate * 0.004)).clamp(0.0, 1.0);
        final double decay =
            math.exp(-(rel / (sampleRate * (durMs / 1000.0))) * 4.2);
        final double env = attack * decay;
        double s = math.sin(2 * math.pi * freq * t);
        s += 0.35 * math.sin(2 * math.pi * freq * 2 * t);
        s += 0.12 * math.sin(2 * math.pi * freq * 3 * t);
        buffer[i] += s * amp * env;
      }
    }

    // 上行三音：A5 → E6 → A6（五度 + 八度，明亮上扬的科技感）
    addNote(880.0, 0, 180, 0.30);
    addNote(1318.5, 80, 340, 0.26);
    addNote(1760.0, 200, 300, 0.10);

    final BytesBuilder data = BytesBuilder();
    void writeU32(int v) {
      data.addByte(v & 0xFF);
      data.addByte((v >> 8) & 0xFF);
      data.addByte((v >> 16) & 0xFF);
      data.addByte((v >> 24) & 0xFF);
    }

    void writeU16(int v) {
      data.addByte(v & 0xFF);
      data.addByte((v >> 8) & 0xFF);
    }

    data.add('RIFF'.codeUnits);
    writeU32(36 + n * 2);
    data.add('WAVE'.codeUnits);
    data.add('fmt '.codeUnits);
    writeU32(16);
    writeU16(1);
    writeU16(1);
    writeU32(sampleRate);
    writeU32(sampleRate * 2);
    writeU16(2);
    writeU16(16);
    data.add('data'.codeUnits);
    writeU32(n * 2);

    for (int i = 0; i < n; i++) {
      final double sample = buffer[i].clamp(-1.0, 1.0);
      final int value = (sample * 32767).round().clamp(-32768, 32767);
      writeU16(value & 0xFFFF);
    }
    return data.toBytes();
  }

  /// 播放提示音（异常隔离：响铃失败不影响消息处理管线）。
  /// 阶段 Q0-3：经平台能力抽象分发（paplay/aplay 仅 Linux 默认链）；
  /// 同步与异步（Future）错误均吞掉，不传播到调用方
  static void playSound() {
    try {
      PlatformCapabilities.sound
          .playNotifySound()
          .then((_) {}, onError: (_) {});
    } catch (_) {}
  }

  /// 是否处于免打扰时段（now 缺省用 nowProvider）。
  /// 规则：dndEnabled 开 且 当前时刻 < dndEndTime（绝对结束时刻，精确到日/时/分）。
  static bool inDndWindow([DateTime? now]) {
    final t = (now ?? nowProvider()).toLocal();
    return t.isBefore(dndEndTime);
  }

  /// 检查免打扰是否到期：到期则自动关闭开关并返回 true（调用方提醒用户）。
  /// 由 ChatScreen 周期定时器驱动（每 30s）。
  static bool checkDndExpiry() {
    if (!dndEnabled) return false;
    if (inDndWindow()) return false;
    dndEnabled = false;
    return true;
  }

  /// 确保免打扰结束时刻在未来（开启开关时调用）：
  /// 缺省取今天 23:00，已过则取次日 23:00。
  static void ensureDndEndInFuture() {
    final now = nowProvider();
    var end = DateTime(now.year, now.month, now.day, 23, 0);
    if (!end.isAfter(now)) end = end.add(const Duration(days: 1));
    dndEndTime = end;
  }

  /// 紧急提示实现（测试可注入 fake；默认调用 runner 的 GTK urgency 桥接）
  static void Function(bool urgent) setUrgencyImpl = _defaultSetUrgency;

  static void _defaultSetUrgency(bool urgent) {
    try {
      final lib = DynamicLibrary.process();
      final fn = lib.lookupFunction<_SetUrgencyNative, _SetUrgencyDart>(
          'chatroom_set_urgency');
      fn(urgent ? 1 : 0);
    } catch (_) {
      // 非桌面环境（测试 / 无窗口管理器）静默降级
    }
  }

  /// 任务栏图标开始闪烁（未聚焦收到新消息时）。
  /// 阶段 Q0-3：经平台能力抽象分发（override 注入优先；Linux 默认链
  /// 走 setUrgencyImpl 既有注入点，非 Linux 端按能力实现降级）
  static void flash() {
    if (!enabled) return;
    try {
      PlatformCapabilities.notification.flash();
    } catch (_) {
      // 闪烁失败不影响消息处理管线
    }
  }

  /// 清除紧急提示（窗口重新聚焦后调用；不受 enabled 限制）
  static void clearUrgency() {
    try {
      PlatformCapabilities.notification.clearUrgency();
    } catch (_) {}
  }

  /// 触发规则：未聚焦窗口时收到新消息才闪烁；
  /// 提示音与窗口聚焦无关（声音通道互补，P1-14）。
  /// 阶段 K3：静音会话永不提醒；免打扰时段内不提醒，
  /// **但置顶会话豁免免打扰**（P-16 修订：置顶会话在免打扰时段内仍提醒）。
  static void maybeFlashForMessage(ChatMessage msg, String chatKey) {
    if (!enabled) return;
    if (msg.status != 'sent') return;
    if (msg.sender == AppState.instance.username) return;
    final matched = switch (msg.type) {
      'chat' ||
      'group_chat' ||
      'file' ||
      'file_request' ||
      'group_file_request' =>
        true,
      // 阶段 O1/O9：群公告与名片/位置/日程卡片同文本消息提醒
      'group_announcement' ||
      'share_contact' ||
      'share_location' ||
      'schedule_card' =>
        true,
      'system' => msg.sender == '[系统公告]',
      _ => false,
    };
    if (!matched) return;
    // 阶段 K3：静音会话永不提醒；免打扰时段内不提醒（置顶会话豁免）
    final muted = AppState.instance.isMuted(chatKey);
    final inDnd =
        dndEnabled && inDndWindow() && !AppState.instance.isPinned(chatKey);
    if (muted || inDnd) return;
    // Q1 真机反馈二轮：Android 应用外提醒 = 系统通知（横幅+震动+提示音，
    // 渠道承载）——后台时跳过应用内提示音避免双响；前台仍走生成式提示音
    final background = !FocusTracker.instance.focused;
    final androidBackground =
        background && effectiveTargetPlatform() == TargetPlatform.android;
    if (soundEnabled && !androidBackground) playSound();
    if (!background) return;
    flash();
    _notifyOutsideApp(msg, chatKey);
  }

  /// Q1 真机反馈二轮（问题5）：应用外新消息通知（仅 Android）。
  /// 标题 = 会话显示名（群名/好友名/服务器）；正文 = 内容摘要
  /// （群聊带发送者前缀；文件类消息展示 "[文件] 文件名"），超长截断。
  static void _notifyOutsideApp(ChatMessage msg, String chatKey) {
    if (effectiveTargetPlatform() != TargetPlatform.android) return;
    try {
      final state = AppState.instance;
      String title;
      if (chatKey.startsWith('group_')) {
        final gid = int.tryParse(chatKey.substring(6));
        final group = gid == null
            ? null
            : state.groups.where((g) => g.id == gid).firstOrNull;
        title = group?.name ?? '群消息';
      } else if (chatKey == '服务器') {
        title = '服务器消息';
      } else {
        title = state.displayNameForChat(chatKey);
      }
      final isFileKind = msg.type == 'file' ||
          msg.type == 'file_request' ||
          msg.type == 'group_file_request';
      // Q1 三轮（问题4，参考微信）：表情包贴纸通知显示 "[动画表情]"
      // 而非原始文件名
      var body = isFileKind
          ? (msg.filename != null && isStickerFilename(msg.filename!)
              ? '[动画表情]'
              : '[文件] ${msg.filename ?? msg.content}')
          : (chatKey.startsWith('group_') && msg.sender.isNotEmpty
              ? '${msg.sender}: ${msg.content}'
              : msg.content);
      if (body.length > 80) body = '${body.substring(0, 80)}…';
      AndroidSystem.showMessageNotification(title: title, body: body);
    } catch (_) {}
  }
}

typedef _SetUrgencyNative = Void Function(Int);
typedef _SetUrgencyDart = void Function(int);
