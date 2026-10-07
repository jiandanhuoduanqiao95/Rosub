// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "audio_device_monitor.h"

#include <audioclient.h>
#include <endpointvolume.h>
#include <mmreg.h>

#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <cmath>

namespace flutter_webrtc_plugin {

void AudioMonitorFileLog(const std::string& line) {
  char* path = nullptr;
  if (_dupenv_s(&path, nullptr, "CHATROOM_AUDIO_MONITOR_LOG") != 0 || !path) {
    return;
  }
  FILE* f = nullptr;
  if (fopen_s(&f, path, "a") == 0 && f) {
    SYSTEMTIME st;
    GetLocalTime(&st);
    fprintf(f, "[%02u:%02u:%02u.%03u] %s\n", st.wHour, st.wMinute, st.wSecond,
            st.wMilliseconds, line.c_str());
    fclose(f);
  }
  free(path);
}

namespace {

// Notification bursts are coalesced into a single callback after this much
// quiet time: a plug/unplug raises OnDefaultDeviceChanged for the watched
// role plus device-state events that resolve right after.
constexpr std::chrono::milliseconds kDebounceInterval(300);

std::string WideToUtf8(LPCWSTR wide) {
  if (!wide) return std::string();
  const int size = WideCharToMultiByte(CP_UTF8, 0, wide, -1, nullptr, 0,
                                       nullptr, nullptr);
  if (size <= 0) return std::string();
  std::string utf8(size - 1, '\0');
  if (WideCharToMultiByte(CP_UTF8, 0, wide, -1, &utf8[0], size, nullptr,
                          nullptr) == 0) {
    return std::string();
  }
  return utf8;
}

}  // namespace

CaptureProbeResult ProbeCaptureEndpointLiveness(
    IMMDeviceEnumerator* enumerator,
    const std::string& endpoint_id) {
  if (!enumerator || endpoint_id.empty()) {
    return CaptureProbeResult::kError;
  }
  // |endpoint_id| is UTF-8; MMDevice wants wide chars.
  const int wlen = MultiByteToWideChar(CP_UTF8, 0, endpoint_id.c_str(), -1,
                                       nullptr, 0);
  if (wlen <= 0) {
    return CaptureProbeResult::kError;
  }
  std::wstring wide(wlen, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, endpoint_id.c_str(), -1, &wide[0], wlen);

  IMMDevice* device = nullptr;
  if (FAILED(enumerator->GetDevice(wide.c_str(), &device)) || !device) {
    return CaptureProbeResult::kError;
  }
  IAudioEndpointVolume* volume = nullptr;
  if (SUCCEEDED(device->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL,
                                 nullptr, (void**)&volume)) &&
      volume) {
    BOOL muted = FALSE;
    const bool have_mute = SUCCEEDED(volume->GetMute(&muted));
    volume->Release();
    if (have_mute && muted) {
      device->Release();
      return CaptureProbeResult::kMuted;
    }
  }
  IAudioClient* client = nullptr;
  if (FAILED(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                              (void**)&client)) ||
      !client) {
    device->Release();
    return CaptureProbeResult::kError;
  }
  WAVEFORMATEX* format = nullptr;
  if (FAILED(client->GetMixFormat(&format)) || !format) {
    client->Release();
    device->Release();
    return CaptureProbeResult::kError;
  }
  bool is_float = false;
  const int bits = format->wBitsPerSample;
  if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
      format->cbSize >= sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
    const WAVEFORMATEXTENSIBLE* ext =
        reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format);
    // KSDATAFORMAT_SUBTYPE_IEEE_FLOAT spelled out to avoid the uuid.lib
    // external symbol.
    static const GUID kFloatGuid = {
        0x00000003, 0x0000, 0x0010,
        {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
    is_float = IsEqualGUID(ext->SubFormat, kFloatGuid);
  } else {
    is_float = format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
  }
  if (FAILED(client->Initialize(AUDCLNT_SHAREMODE_SHARED, 0, 10000000, 0,
                                format, nullptr))) {
    CoTaskMemFree(format);
    client->Release();
    device->Release();
    return CaptureProbeResult::kError;
  }
  IAudioCaptureClient* capture = nullptr;
  if (FAILED(client->GetService(__uuidof(IAudioCaptureClient),
                                (void**)&capture)) ||
      !capture) {
    CoTaskMemFree(format);
    client->Release();
    device->Release();
    return CaptureProbeResult::kError;
  }
  if (FAILED(client->Start())) {
    capture->Release();
    CoTaskMemFree(format);
    client->Release();
    device->Release();
    return CaptureProbeResult::kError;
  }
  // PATCH(chatroom): discard the first 600ms. A Bluetooth SCO capture
  // endpoint measured from a cold link reports setup transients well into
  // the stream (floors up to 3.1e-4 observed from an endpoint whose
  // sustained output is digital silence — micprobe 6s all-zero on the same
  // endpoint); counting them green-lit re-binds that muted the whole call.
  const ULONGLONG started = GetTickCount64();
  double peak = 0.0;
  bool measuring = false;
  while (GetTickCount64() - started < 2000) {
    measuring = GetTickCount64() - started >= 600;
    UINT32 packets = 0;
    capture->GetNextPacketSize(&packets);
    while (packets > 0) {
      BYTE* data = nullptr;
      UINT32 frames = 0;
      DWORD flags = 0;
      if (SUCCEEDED(capture->GetBuffer(&data, &frames, &flags, nullptr,
                                       nullptr)) &&
          data && !(flags & AUDCLNT_BUFFERFLAGS_SILENT) && measuring) {
        const size_t count =
            (size_t)frames * (size_t)format->nChannels;
        if (is_float && bits == 32) {
          const float* samples = reinterpret_cast<const float*>(data);
          for (size_t i = 0; i < count; ++i) {
            const double a = std::fabs((double)samples[i]);
            if (a > peak) peak = a;
          }
        } else if (bits == 16) {
          const int16_t* samples = reinterpret_cast<const int16_t*>(data);
          for (size_t i = 0; i < count; ++i) {
            const double a = std::fabs((double)samples[i] / 32768.0);
            if (a > peak) peak = a;
          }
        } else if (bits == 32) {
          const int32_t* samples = reinterpret_cast<const int32_t*>(data);
          for (size_t i = 0; i < count; ++i) {
            const double a = std::fabs((double)samples[i] / 2147483648.0);
            if (a > peak) peak = a;
          }
        }
      }
      if (frames > 0) {
        capture->ReleaseBuffer(frames);
      } else {
        break;
      }
      capture->GetNextPacketSize(&packets);
    }
    Sleep(100);
  }
  client->Stop();
  capture->Release();
  CoTaskMemFree(format);
  client->Release();
  device->Release();
  char buf[160];
  snprintf(buf, sizeof(buf),
           "[AudioDeviceMonitor] capture probe %s peak=%.6f",
           endpoint_id.c_str(), peak);
  AudioMonitorFileLog(buf);
  // Alive bar 1e-3: the silent hands-free SCO floors observed in the wild
  // reach 3.1e-4 (setup transients), working-mic ambients start ~5e-4 and
  // run far higher with speech. The failure costs are wildly asymmetric —
  // a false "alive" can mute the whole call, a false "silent" merely keeps
  // the current microphone — so bias toward refusing. The embedder still
  // switches when the current endpoint has vanished (nothing to lose).
  return peak > 1e-3 ? CaptureProbeResult::kAlive
                     : CaptureProbeResult::kSilent;
}

AudioDeviceMonitor* AudioDeviceMonitor::Create() {
  return new AudioDeviceMonitor();
}

AudioDeviceMonitor::AudioDeviceMonitor()
    : ref_count_(1), running_(false), fire_pending_{false, false} {
  stop_event_ = CreateEvent(nullptr, TRUE, FALSE, nullptr);
}

AudioDeviceMonitor::~AudioDeviceMonitor() {
  Stop();
  if (stop_event_) {
    CloseHandle(stop_event_);
    stop_event_ = nullptr;
  }
}

void AudioDeviceMonitor::Start(DefaultChangedCallback on_default_changed) {
  if (running_.exchange(true)) {
    return;  // already started
  }
  callback_ = std::move(on_default_changed);
  for (int i = 0; i < kAudioDeviceFlowCount; ++i) {
    fire_pending_[i] = false;
  }
  ResetEvent(stop_event_);
  debounce_thread_ = std::thread(&AudioDeviceMonitor::DebounceLoop, this);
  registration_thread_ =
      std::thread(&AudioDeviceMonitor::RegistrationLoop, this);
}

void AudioDeviceMonitor::Stop() {
  if (!running_.exchange(false)) {
    return;
  }
  SetEvent(stop_event_);
  {
    std::lock_guard<std::mutex> lock(fire_mutex_);
    for (int i = 0; i < kAudioDeviceFlowCount; ++i) {
      fire_pending_[i] = false;
    }
  }
  fire_cv_.notify_all();
  if (registration_thread_.joinable()) {
    registration_thread_.join();
  }
  if (debounce_thread_.joinable()) {
    debounce_thread_.join();
  }
}

void AudioDeviceMonitor::Probe(AudioDeviceFlow flow) {
  RequestFire(flow, std::string());
}

void AudioDeviceMonitor::ForceFire(AudioDeviceFlow flow) {
  char buf[128];
  snprintf(buf, sizeof(buf), "[AudioDeviceMonitor] force fire flow=%u",
           (unsigned)flow);
  AudioMonitorFileLog(buf);
  RequestFire(flow, std::string(), true);
}

ULONG STDMETHODCALLTYPE AudioDeviceMonitor::AddRef() {
  return ++ref_count_;
}

ULONG STDMETHODCALLTYPE AudioDeviceMonitor::Release() {
  const ULONG count = --ref_count_;
  if (count == 0) {
    delete this;
  }
  return count;
}

HRESULT STDMETHODCALLTYPE AudioDeviceMonitor::QueryInterface(
    REFIID riid,
    void** ppv_object) {
  if (!ppv_object) {
    return E_POINTER;
  }
  if (riid == __uuidof(IUnknown) || riid == __uuidof(IMMNotificationClient)) {
    *ppv_object = static_cast<IMMNotificationClient*>(this);
    AddRef();
    return S_OK;
  }
  *ppv_object = nullptr;
  return E_NOINTERFACE;
}

HRESULT STDMETHODCALLTYPE AudioDeviceMonitor::OnDeviceStateChanged(
    LPCWSTR /*device_id*/,
    DWORD /*new_state*/) {
  return S_OK;
}

HRESULT STDMETHODCALLTYPE AudioDeviceMonitor::OnDeviceAdded(
    LPCWSTR /*device_id*/) {
  return S_OK;
}

HRESULT STDMETHODCALLTYPE AudioDeviceMonitor::OnDeviceRemoved(
    LPCWSTR /*device_id*/) {
  return S_OK;
}

HRESULT STDMETHODCALLTYPE AudioDeviceMonitor::OnDefaultDeviceChanged(
    EDataFlow flow,
    ERole role,
    LPCWSTR device_id) {
  if (!running_.load()) {
    return S_OK;
  }
  // Only the communications role matters: the active legacy ADM's
  // per-side selection mirrors the default communications endpoint (the
  // embedder re-points it on every change, keeping the invariant).
  const bool watched = (flow == eRender || flow == eCapture) &&
                       role == eCommunications;
  if (!watched) {
    return S_OK;
  }
  // PATCH(chatroom): |device_id| is the NEW default endpoint per the
  // IMMNotificationClient contract and is authoritative during teardown
  // storms — resolving fresh at event time lags behind the removal (observed
  // a Bluetooth disconnect resolve to the still-tearing-down headset and the
  // embedder then re-bound recording ONTO the dying endpoint). Fall back to
  // a fresh resolution only when the parameter is empty (no default left).
  std::string endpoint_id = WideToUtf8(device_id);
  if (endpoint_id.empty()) {
    endpoint_id = ResolveDefaultCommunicationsEndpointID(flow, enumerator_);
  }
  {
    char buf[384];
    snprintf(buf, sizeof(buf),
             "[AudioDeviceMonitor] OnDefaultDeviceChanged flow=%u role=%u %s",
             (unsigned)flow, (unsigned)role, endpoint_id.c_str());
    AudioMonitorFileLog(buf);
  }
  if (!endpoint_id.empty()) {
    RequestFire(flow == eRender ? AudioDeviceFlow::kRender
                                : AudioDeviceFlow::kCapture,
                endpoint_id);
  }
  return S_OK;
}

HRESULT STDMETHODCALLTYPE AudioDeviceMonitor::OnPropertyValueChanged(
    LPCWSTR /*device_id*/,
    const PROPERTYKEY /*key*/) {
  return S_OK;
}

void AudioDeviceMonitor::RegistrationLoop() {
  const HRESULT init_hr = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool com_initialized = SUCCEEDED(init_hr);
  if (com_initialized) {
    const HRESULT hr = ::CoCreateInstance(
        __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
        __uuidof(IMMDeviceEnumerator),
        reinterpret_cast<void**>(&enumerator_));
    if (SUCCEEDED(hr) && enumerator_) {
      // MMDevice AddRefs |this| for the lifetime of the registration; the
      // matching release happens inside UnregisterEndpointNotification-
      // Callback below.
      const HRESULT reg_hr =
          enumerator_->RegisterEndpointNotificationCallback(this);
      {
        char buf[128];
        snprintf(buf, sizeof(buf),
                 "[AudioDeviceMonitor] registered hr=0x%08lX", (long)reg_hr);
        AudioMonitorFileLog(buf);
      }
      if (FAILED(reg_hr)) {
        enumerator_->Release();
        enumerator_ = nullptr;
      }
    } else {
      char buf[128];
      snprintf(buf, sizeof(buf),
               "[AudioDeviceMonitor] CoCreateInstance failed hr=0x%08lX",
               (long)hr);
      AudioMonitorFileLog(buf);
    }
  } else {
    char buf[128];
    snprintf(buf, sizeof(buf),
             "[AudioDeviceMonitor] CoInitializeEx failed hr=0x%08lX",
             (long)init_hr);
    AudioMonitorFileLog(buf);
  }
  WaitForSingleObject(stop_event_, INFINITE);
  if (enumerator_) {
    enumerator_->UnregisterEndpointNotificationCallback(this);
    enumerator_->Release();
    enumerator_ = nullptr;
  }
  if (com_initialized) {
    ::CoUninitialize();
  }
}

void AudioDeviceMonitor::DebounceLoop() {
  // Own COM apartment + enumerator: resolves endpoints for Probe() requests
  // (the Flutter main thread may be STA, so MMDevice calls stay off it).
  const bool com_initialized =
      SUCCEEDED(::CoInitializeEx(nullptr, COINIT_MULTITHREADED));
  IMMDeviceEnumerator* enumerator = nullptr;
  if (com_initialized) {
    ::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                       __uuidof(IMMDeviceEnumerator),
                       reinterpret_cast<void**>(&enumerator));
  }
  std::unique_lock<std::mutex> lock(fire_mutex_);
  while (running_.load()) {
    if (!fire_pending_[0] && !fire_pending_[1]) {
      fire_cv_.wait(lock, [this] {
        return fire_pending_[0] || fire_pending_[1] || !running_.load();
      });
      continue;
    }
    // Notifications are pending; fire once the deadline passes with no
    // further notifications (each new one pushes |fire_deadline_| out).
    const bool timed_out =
        fire_cv_.wait_until(lock, fire_deadline_) == std::cv_status::timeout;
    if (!running_.load()) {
      break;
    }
    if (timed_out && std::chrono::steady_clock::now() >= fire_deadline_) {
      PendingFire fires[kAudioDeviceFlowCount];
      const bool pending[kAudioDeviceFlowCount] = {fire_pending_[0],
                                                   fire_pending_[1]};
      for (int i = 0; i < kAudioDeviceFlowCount; ++i) {
        fires[i] = pending_[i];
        fire_pending_[i] = false;
      }
      lock.unlock();
      for (int i = 0; i < kAudioDeviceFlowCount; ++i) {
        if (!pending[i]) {
          continue;
        }
        PendingFire fire = fires[i];
        if (fire.probe) {
          fire.endpoint_id = ResolveDefaultCommunicationsEndpointID(
              fire.flow == AudioDeviceFlow::kRender ? eRender : eCapture,
              enumerator);
        }
        if (fire.endpoint_id.empty()) {
          continue;
        }
        {
          char buf[384];
          snprintf(buf, sizeof(buf),
                   "[AudioDeviceMonitor] firing switch flow=%u force=%d "
                   "endpoint %s",
                   (unsigned)fire.flow, fire.force ? 1 : 0,
                   fire.endpoint_id.c_str());
          AudioMonitorFileLog(buf);
        }
        if (!fire.force) {
          // PATCH(chatroom): drop stale targets. The debounce window plus
          // the liveness probe can outlive the device topology that raised
          // the event (a Bluetooth disconnect fires, the probe measures the
          // endpoint's dying gasp, and by now the "new default" is gone and
          // a further change is pending). Re-binding onto a dying endpoint
          // kills that side of the call for good — only ever re-bind to the
          // endpoint that is STILL the default right now. Forced resyncs
          // are exempt (their purpose is restarting the pipeline on the
          // current default, which the re-resolve below would just confirm).
          const std::string current_default =
              ResolveDefaultCommunicationsEndpointID(
                  fire.flow == AudioDeviceFlow::kRender ? eRender : eCapture,
                  enumerator);
          if (!current_default.empty() && current_default != fire.endpoint_id) {
            char buf[384];
            snprintf(buf, sizeof(buf),
                     "[AudioDeviceMonitor] stale target (now %s), drop fire",
                     current_default.c_str());
            AudioMonitorFileLog(buf);
            continue;
          }
        }
        int capture_verdict = -1;  // -1: render flow / not probed
        if (fire.flow == AudioDeviceFlow::kCapture) {
          // PATCH(chatroom): probe the capture target's liveness and hand
          // the verdict to the embedder — it decides between keeping the
          // current microphone (target silent/muted/broken: a Bluetooth
          // hands-free SCO capture delivers digital silence system-wide and
          // rebinding onto it mutes the call) and switching anyway (the
          // current endpoint has vanished — nothing to lose). This gate
          // applies to forced resyncs too: force exists to restart a
          // pipeline that died ON its endpoint, never to migrate onto a
          // dead one.
          const CaptureProbeResult probe =
              ProbeCaptureEndpointLiveness(enumerator, fire.endpoint_id);
          capture_verdict = static_cast<int>(probe);
          // The probe's own capture client just closed on the target
          // endpoint; on a Bluetooth SCO link that teardown races the ADM
          // re-open. Give the stack a moment to settle before rebinding.
          Sleep(250);
        }
        if (callback_) {
          callback_(fire.flow, fire.endpoint_id, fire.force, capture_verdict);
        }
      }
      lock.lock();
    }
  }
  lock.unlock();
  if (enumerator) {
    enumerator->Release();
  }
  if (com_initialized) {
    ::CoUninitialize();
  }
}

void AudioDeviceMonitor::RequestFire(AudioDeviceFlow flow,
                                     const std::string& endpoint_id,
                                     bool force) {
  {
    std::lock_guard<std::mutex> lock(fire_mutex_);
    const int slot = static_cast<int>(flow);
    pending_[slot].flow = flow;
    pending_[slot].endpoint_id = endpoint_id;
    pending_[slot].probe = endpoint_id.empty();
    pending_[slot].force = force;
    fire_deadline_ = std::chrono::steady_clock::now() + kDebounceInterval;
    fire_pending_[slot] = true;
  }
  fire_cv_.notify_all();
}

std::string AudioDeviceMonitor::ResolveDefaultCommunicationsEndpointID(
    EDataFlow flow,
    IMMDeviceEnumerator* enumerator) {
  if (!enumerator) {
    return std::string();
  }
  IMMDevice* device = nullptr;
  const HRESULT hr =
      enumerator->GetDefaultAudioEndpoint(flow, eCommunications, &device);
  if (FAILED(hr) || !device) {
    char buf[128];
    snprintf(buf, sizeof(buf),
             "[AudioDeviceMonitor] GetDefaultAudioEndpoint(flow=%u) "
             "failed hr=0x%08lX",
             (unsigned)flow, (long)hr);
    AudioMonitorFileLog(buf);
    return std::string();
  }
  LPWSTR id = nullptr;
  std::string result;
  if (SUCCEEDED(device->GetId(&id)) && id) {
    result = WideToUtf8(id);
    ::CoTaskMemFree(id);
  }
  device->Release();
  return result;
}

}  // namespace flutter_webrtc_plugin
