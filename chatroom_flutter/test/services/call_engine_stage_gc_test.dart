// 阶段 R2 gc3：SDP H264 剔除（桌面门控）纯函数契约测试
//
// 背景：m150 桌面预编译 libwebrtc 的 H264 解码产纯黑帧（Q2 实锤、剔除
// 修复迟至 gc3 才实现）；vendored Android 版 answer 主动选 H264 触发
// 桌面黑帧——桌面端 offer/answer 剔除 H264 载荷（含 apt 引用的 RTX），
// Android answer 自然落 VP8。测试宿主为 Linux，桌面门控生效。
import 'package:chatroom_flutter/services/call_engine.dart';
import 'package:flutter_test/flutter_test.dart';

final _sdpWithH264 = [
  'v=0',
  'o=- 123 2 IN IP4 127.0.0.1',
  's=-',
  't=0 0',
  'm=audio 9 UDP/TLS/RTP/SAVPF 111',
  'a=rtpmap:111 opus/48000/2',
  'm=video 9 UDP/TLS/RTP/SAVPF 96 97 98 99 100 101',
  'a=rtpmap:96 H264/90000',
  'a=fmtp:96 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e029',
  'a=rtcp-fb:96 nack',
  'a=rtpmap:97 rtx/90000',
  'a=fmtp:97 apt=96',
  'a=rtpmap:100 H265/90000',
  'a=rtpmap:101 rtx/90000',
  'a=fmtp:101 apt=100',
  'a=rtpmap:98 VP8/90000',
  'a=rtcp-fb:98 nack',
  'a=rtpmap:99 rtx/90000',
  'a=fmtp:99 apt=98',
  'a=extmap:3 urn:ietf:params:rtp-hdrext:toffset',
].join('\r\n');

void main() {
  group('sanitizeDesktopSdp（gc3：桌面 H264 剔除）', () {
    test('剔除 H264 主载荷 + apt 引用的 RTX，保留 VP8 链', () {
      final out = WebRtcCallEngine.sanitizeDesktopSdp(_sdpWithH264);
      expect(out, isNot(contains('H264')));
      expect(out, isNot(contains('H265')),
          reason: 'H265 同族剔除（gc3 三方实测桌面 answer 落 H265）');
      expect(out, isNot(contains('a=fmtp:101 apt=100')),
          reason: 'H265 的 RTX 同步剔除');
      expect(out, isNot(contains('a=rtpmap:96')));
      expect(out, isNot(contains('a=fmtp:97 apt=96')),
          reason: 'H264 的 RTX 同步剔除');
      expect(out, isNot(contains('a=rtcp-fb:96')));
      expect(out, contains('a=rtpmap:98 VP8/90000'));
      expect(out, contains('a=fmtp:99 apt=98'), reason: 'VP8 的 RTX 保留');
      expect(out, contains('a=rtpmap:111 opus/48000/2'), reason: '音频不受影响');
      expect(out, contains('a=extmap:3'), reason: 'extmap 不受影响');
      final mLine =
          out.split('\r\n').firstWhere((l) => l.startsWith('m=video'));
      expect(mLine, 'm=video 9 UDP/TLS/RTP/SAVPF 98 99',
          reason: 'm 行载荷表剔除 96/97/100/101');
    });

    test('无 H264/H265 的 SDP 原样返回', () {
      final noH = _sdpWithH264
          .replaceAll('96 H264/90000', '96 VP9/90000')
          .replaceAll('100 H265/90000', '100 VP9/90000');
      expect(WebRtcCallEngine.sanitizeDesktopSdp(noH), noH);
    });

    test('gc4：Windows offer 仅 H264/H265 时注入 VP8+RTX，m-line 恒存', () {
      final winOffer = [
        'v=0',
        'o=- 123 2 IN IP4 127.0.0.1',
        's=-',
        't=0 0',
        'm=audio 9 UDP/TLS/RTP/SAVPF 111',
        'a=rtpmap:111 opus/48000/2',
        'm=video 9 UDP/TLS/RTP/SAVPF 100 101',
        'a=rtpmap:100 H264/90000',
        'a=rtcp-fb:100 nack',
        'a=rtpmap:101 rtx/90000',
        'a=fmtp:101 apt=100',
      ].join('\r\n');
      final out = WebRtcCallEngine.sanitizeDesktopSdp(winOffer);
      expect(out, contains('m=video 9 UDP/TLS/RTP/SAVPF 96 97'),
          reason: '视频 m-line 不得消失');
      expect(out, contains('a=rtpmap:96 VP8/90000'));
      expect(out, contains('a=fmtp:97 apt=96'));
      expect(out, isNot(contains('H264')));
      expect(WebRtcCallEngine.primaryVideoCodec(out), 'VP8');
    });

    test('primaryVideoCodec 对剔除后 SDP 报 VP8', () {
      final out = WebRtcCallEngine.sanitizeDesktopSdp(_sdpWithH264);
      expect(WebRtcCallEngine.primaryVideoCodec(out), 'VP8');
    });
  });
}
