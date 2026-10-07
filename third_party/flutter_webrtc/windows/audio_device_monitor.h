// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#ifndef FLUTTER_WEBRTC_WINDOWS_AUDIO_DEVICE_MONITOR_H_
#define FLUTTER_WEBRTC_WINDOWS_AUDIO_DEVICE_MONITOR_H_

#include <windows.h>

#include <propkeydef.h>
#include <mmdeviceapi.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

namespace flutter_webrtc_plugin {

// PATCH(chatroom) diagnostics: when the CHATROOM_AUDIO_MONITOR_LOG env var
// names a file, monitor events are appended there (std::cerr is lost under
// `flutter test` output pipes; the direct file survives). Off by default.
void AudioMonitorFileLog(const std::string& line);

// Liveness verdict for a capture endpoint, used to gate recording-device
// rebinds: a default communications capture endpoint can deliver digital
// silence system-wide (observed with a Bluetooth hands-free mic whose SCO
// capture never produces samples) — rebinding the ADM onto such an endpoint
// mutes the whole call, so silence (or a user-muted endpoint) must keep the
// currently working microphone instead.
enum class CaptureProbeResult {
  kAlive,   // capture stream produced a non-silent window (peak > 1e-5)
  kSilent,  // stream ran but every window was digital silence
  kMuted,   // endpoint is muted via IAudioEndpointVolume (respect user intent)
  kError,   // endpoint could not be opened (treated as not alive)
};

// Opens |endpoint_id| in shared mode on the calling thread (must have COM
// initialized; ~1.2s) and measures the peak sample level. Safe next to a
// live ADM capture on the same endpoint (shared mode allows both).
CaptureProbeResult ProbeCaptureEndpointLiveness(
    IMMDeviceEnumerator* enumerator,
    const std::string& endpoint_id);


// Which ADM side a default-device change refers to.
enum class AudioDeviceFlow {
  kRender = 0,   // playout (default communications render endpoint)
  kCapture = 1,  // recording (default communications capture endpoint)
};

// Number of flows; indexes the pending-fire slots.
constexpr int kAudioDeviceFlowCount = 2;

// The legacy Windows ADM that the bundled libwebrtc selects with
// kPlatformDefaultAudio (AudioDeviceWindowsCore) implements no
// IMMNotificationClient and no device-change recovery: playout AND recording
// stay bound to the endpoints that were current when InitPlayout/-
// InitRecording last ran, and an invalidated (unplugged) endpoint leaves the
// call one-sided. This monitor listens to MMDevice endpoint notifications
// directly and reports default *communications* endpoint changes for both
// flows, so the embedder can re-point the ADM by matching the new endpoint
// ID against the ADM's device enumeration (legacy SetPlayoutDevice/
// SetRecordingDevice index the active endpoint collection — index 0 is NOT
// the default; only the ALSA ADM on Linux has a "default" entry at 0).
//
// The monitor is a self-owned COM object: MMDevice holds a reference for as
// long as the callback is registered, and in-flight callbacks keep the
// object alive across Stop(). The embedder owns the initial reference from
// Create() and must call Stop() before dropping it.
class AudioDeviceMonitor : public IMMNotificationClient {
 public:
  // |endpoint_id| is the UTF-8 endpoint ID string (IMMDevice::GetId) of the
  // new default communications device for |flow|. It may be empty when the
  // caller only requests a re-probe (see Probe); the monitor then resolves
  // it on the debounce thread. |force| marks resync requests that must
  // bypass the embedder's same-target skip. |capture_verdict| carries the
  // CaptureProbeResult as int for capture fires (-1 otherwise); the embedder
  // weighs it against whether the CURRENT recording endpoint still exists.
  using DefaultChangedCallback = std::function<void(
      AudioDeviceFlow flow, const std::string& endpoint_id, bool force,
      int capture_verdict)>;

  // Returns a new monitor holding one reference owned by the caller.
  static AudioDeviceMonitor* Create();

  // Starts listening; |on_default_changed| is invoked on an internal worker
  // thread, coalescing notification bursts. |force| marks fires that must
  // bypass the embedder's same-target skip (capture-resync requests: the ADM
  // recording pipeline can die on the endpoint it is already pinned to, and
  // reviving it requires an unconditional Stop->Set->Init->Start restart).
  // Never fires after Stop().
  void Start(DefaultChangedCallback on_default_changed);

  // Unregisters from MMDevice and joins the internal threads. Idempotent;
  // must be called before the owner releases its reference.
  void Stop();

  // Requests a re-probe of the current default communications endpoint for
  // |flow| (debounced like real events). Used to re-bind freshly acquired
  // media: getUserMedia pins recording to enumeration index 0 regardless of
  // the system default, and the embedder corrects that right after.
  void Probe(AudioDeviceFlow flow);

  // Forces an immediate re-bind of |flow| to the CURRENT default
  // communications endpoint, bypassing the debounce-liveness gate only in
  // that the embedder's same-target skip is bypassed (a dead pipeline on the
  // right endpoint needs exactly one restart to revive); the endpoint
  // liveness probe still applies — force never migrates onto a dead device.
  // Recovery path for a recording pipeline that died mid-call (e.g. a
  // wrapper restart that failed during a Bluetooth teardown storm): the Dart
  // layer detects outbound digital silence and asks for this resync.
  void ForceFire(AudioDeviceFlow flow);

  // IUnknown
  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                           void** ppv_object) override;

  // IMMNotificationClient
  HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR device_id,
                                                 DWORD new_state) override;
  HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR device_id) override;
  HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR device_id) override;
  HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(EDataFlow flow,
                                                   ERole role,
                                                   LPCWSTR device_id) override;
  HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(
      LPCWSTR device_id,
      const PROPERTYKEY key) override;

 private:
  AudioDeviceMonitor();
  // Not virtual: COM interfaces have no virtual destructor (lifetime is
  // governed by Release(), which deletes the object at refcount zero).
  ~AudioDeviceMonitor();

  void RegistrationLoop();
  void DebounceLoop();
  void RequestFire(AudioDeviceFlow flow,
                   const std::string& endpoint_id,
                   bool force = false);
  std::string ResolveDefaultCommunicationsEndpointID(
      EDataFlow flow,
      IMMDeviceEnumerator* enumerator);

  std::atomic<ULONG> ref_count_;
  std::atomic<bool> running_;
  DefaultChangedCallback callback_;

  // Owns the COM apartment the registration lives on; also holds
  // |enumerator_| for default-endpoint resolution at event time.
  std::thread registration_thread_;
  // The debounce thread carries its own MTA + enumerator so it can resolve
  // endpoints for Probe() requests (the Flutter main thread may be STA, so
  // MMDevice calls stay off it).
  std::thread debounce_thread_;
  HANDLE stop_event_;
  IMMDeviceEnumerator* enumerator_ = nullptr;

  struct PendingFire {
    AudioDeviceFlow flow;
    std::string endpoint_id;
    bool probe;  // resolve |endpoint_id| on the debounce thread before firing
    bool force;  // skip the liveness probe and the embedder's same-target skip
  };
  // PATCH(chatroom): one slot PER FLOW. A single slot let a render event
  // overwrite a pending capture event (or vice versa) inside the debounce
  // window during plug/unplug storms — the swallowed capture re-bind left
  // recording on a vanished endpoint for the rest of the call.
  std::mutex fire_mutex_;
  std::condition_variable fire_cv_;
  bool fire_pending_[kAudioDeviceFlowCount];
  PendingFire pending_[kAudioDeviceFlowCount];
  std::chrono::steady_clock::time_point fire_deadline_;

  AudioDeviceMonitor(AudioDeviceMonitor const&) = delete;
  AudioDeviceMonitor& operator=(AudioDeviceMonitor const&) = delete;
};

}  // namespace flutter_webrtc_plugin

#endif  // FLUTTER_WEBRTC_WINDOWS_AUDIO_DEVICE_MONITOR_H_
