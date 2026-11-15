/// opt9 批次 #3：Android 音频采集策略（按设备选择 WebRTC 初始化选项）
///
/// 背景：r1s8~r1s9 为修复 vivo OriginOS 采集无声全局启用
/// bypassVoiceProcessing（MIC 源 + 关硬件语音处理），代价是所有设备
/// 都失去硬件 AEC/NS（外放机型自回声风险）。本模块按设备信息分流：
///   - vivo/iQOO（OriginOS）：维持 bypass（已确认回归红线，勿删）；
///   - 其他设备：硬件音频处理（androidUseHardwareAudioProcessing=true，
///     保留厂商 AEC）；
///   - 软件兜底档（softwareApm）：androidUseHardwareAudioProcessing=false
///     （flutter_webrtc 软件路径），供编译期 dart-define 强制。
///
/// 编译期覆盖：--dart-define=CHATROOM_ANDROID_AUDIO_PROFILE=
/// default|software|bypass（大小写/空白容错；非法值忽略走设备判定）。
/// 真机回声/AEC 验证后置——本策略不承诺消除所有外部媒体声。
library;

enum AndroidAudioProfile { defaultProcessing, softwareApm, bypass }

class AndroidAudioDeviceInfo {
  const AndroidAudioDeviceInfo({
    this.manufacturer,
    this.brand,
    this.model,
    this.device,
    this.product,
    this.display,
    this.release,
    this.sdk,
  });

  factory AndroidAudioDeviceInfo.fromMap(Map<Object?, Object?> map) {
    String? str(String key) {
      final v = map[key];
      return v == null ? null : '$v';
    }

    int? sdkOf(Object? v) => v is int ? v : int.tryParse('$v');
    return AndroidAudioDeviceInfo(
      manufacturer: str('manufacturer'),
      brand: str('brand'),
      model: str('model'),
      device: str('device'),
      product: str('product'),
      display: str('display'),
      release: str('release'),
      sdk: sdkOf(map['sdk']),
    );
  }

  final String? manufacturer;
  final String? brand;
  final String? model;
  final String? device;
  final String? product;
  final String? display;
  final String? release;
  final int? sdk;

  bool get isVivoFamily {
    final fields = [manufacturer, brand].map((f) => (f ?? '').toLowerCase());
    const marks = ['vivo', 'iqoo'];
    if (fields.any((f) => marks.any(f.contains))) return true;
    return (display ?? '').toLowerCase().contains('originos');
  }

  String summary() =>
      'manufacturer=$manufacturer brand=$brand model=$model device=$device '
      'product=$product display=$display release=$release sdk=$sdk';
}

AndroidAudioProfile resolveAndroidAudioProfile(
  AndroidAudioDeviceInfo? info, {
  String? override,
}) {
  final normalized = override?.trim().toLowerCase();
  switch (normalized) {
    case 'default':
      return AndroidAudioProfile.defaultProcessing;
    case 'software':
      return AndroidAudioProfile.softwareApm;
    case 'bypass':
      return AndroidAudioProfile.bypass;
  }
  if (info == null) return AndroidAudioProfile.defaultProcessing;
  if (info.isVivoFamily) return AndroidAudioProfile.bypass;
  return AndroidAudioProfile.defaultProcessing;
}
