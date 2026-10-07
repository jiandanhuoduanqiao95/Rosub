// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#ifndef FLUTTER_WEBRTC_LINUX_PULSE_DEFAULT_DEVICE_MONITOR_H_
#define FLUTTER_WEBRTC_LINUX_PULSE_DEFAULT_DEVICE_MONITOR_H_

#include <functional>
#include <string>

namespace flutter_webrtc_plugin {

// PATCH(chatroom) diagnostics: when the CHATROOM_AUDIO_MONITOR_LOG env var
// names a file, monitor events are appended there. Off by default. Same
// contract as the Windows-side helper in audio_device_monitor.h.
void AudioMonitorFileLog(const std::string& line);

// Watches the PulseAudio (or PipeWire pulse-compat) default SOURCE and fires
// when it changes. The bundled libwebrtc opens its ALSA capture on the
// "default" PCM (the ALSA ADM's enumeration index 0), which binds to the
// default source *at stream-open time* — a mid-call default-source change
// (headset plugged) leaves the call mic on the old device. Re-pointing is
// cheap and safe on this ADM: SetRecordingDevice(0) restarts capture on the
// "default" PCM, which now resolves to the new default source. Only the
// capture side is watched: playout on the same "default" PCM is migrated by
// the pulse server itself when the default sink changes (verified in use).
//
// Without libpulse (HAVE_LIBPULSE undefined) the monitor compiles to a
// no-op, mirroring the guarded pulse_loopback_capturer.
class PulseDefaultDeviceMonitor {
 public:
  PulseDefaultDeviceMonitor();
  ~PulseDefaultDeviceMonitor();

  // |on_default_source_changed| is invoked on a pulse-internal thread; the
  // embedder must hop to its own task runner. Idempotent-safe to call once.
  void Start(std::function<void()> on_default_source_changed);

  // Stops the threaded mainloop and joins. Never fires after Stop().
  void Stop();

 private:
  class Impl;
  Impl* impl_ = nullptr;
};

}  // namespace flutter_webrtc_plugin

#endif  // FLUTTER_WEBRTC_LINUX_PULSE_DEFAULT_DEVICE_MONITOR_H_
