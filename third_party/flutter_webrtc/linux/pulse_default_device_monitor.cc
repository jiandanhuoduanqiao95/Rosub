// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "pulse_default_device_monitor.h"

#include <cstdio>
#include <cstdlib>
#include <ctime>

namespace flutter_webrtc_plugin {

void AudioMonitorFileLog(const std::string& line) {
  const char* path = std::getenv("CHATROOM_AUDIO_MONITOR_LOG");
  if (!path) {
    return;
  }
  FILE* f = fopen(path, "a");
  if (!f) {
    return;
  }
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  struct tm tm_parts;
  localtime_r(&ts.tv_sec, &tm_parts);
  fprintf(f, "[%02d:%02d:%02d.%03ld] %s\n", tm_parts.tm_hour, tm_parts.tm_min,
          tm_parts.tm_sec, ts.tv_nsec / 1000000, line.c_str());
  fclose(f);
}

#ifdef HAVE_LIBPULSE

#include <pulse/pulseaudio.h>

class PulseDefaultDeviceMonitor::Impl {
 public:
  explicit Impl(std::function<void()> on_default_source_changed)
      : callback_(std::move(on_default_source_changed)) {}

  ~Impl() { Stop(); }

  void Start() {
    if (mainloop_) {
      return;
    }
    mainloop_ = pa_threaded_mainloop_new();
    if (!mainloop_) {
      AudioMonitorFileLog("[AudioDeviceMonitor] pa_threaded_mainloop_new "
                          "failed");
      return;
    }
    mainloop_api_ = pa_threaded_mainloop_get_api(mainloop_);
    context_ = pa_context_new(mainloop_api_, "flutter_webrtc_devicemon");
    if (!context_) {
      AudioMonitorFileLog("[AudioDeviceMonitor] pa_context_new failed");
      Cleanup();
      return;
    }
    pa_context_set_state_callback(context_, OnContextState, this);
    pa_context_set_subscribe_callback(context_, OnSubscribe, this);
    if (pa_context_connect(context_, nullptr, PA_CONTEXT_NOFLAGS,
                           nullptr) < 0) {
      AudioMonitorFileLog(
          "[AudioDeviceMonitor] pa_context_connect failed: " +
          std::string(pa_strerror(pa_context_errno(context_))));
      Cleanup();
      return;
    }
    if (pa_threaded_mainloop_start(mainloop_) < 0) {
      AudioMonitorFileLog("[AudioDeviceMonitor] mainloop start failed");
      Cleanup();
      return;
    }
    mainloop_running_ = true;
  }

  void Stop() {
    if (mainloop_running_) {
      pa_threaded_mainloop_stop(mainloop_);
      mainloop_running_ = false;
    }
    Cleanup();
  }

 private:
  static void OnContextState(pa_context* c, void* userdata) {
    auto* self = static_cast<Impl*>(userdata);
    switch (pa_context_get_state(c)) {
      case PA_CONTEXT_READY:
        AudioMonitorFileLog("[AudioDeviceMonitor] pulse context ready");
        pa_operation_unref(
            pa_context_subscribe(c, PA_SUBSCRIPTION_MASK_SERVER, nullptr,
                                 self));
        pa_operation_unref(pa_context_get_server_info(c, OnServerInfo, self));
        break;
      case PA_CONTEXT_FAILED:
      case PA_CONTEXT_TERMINATED:
        AudioMonitorFileLog("[AudioDeviceMonitor] pulse context lost");
        break;
      default:
        break;
    }
  }

  static void OnSubscribe(pa_context* c,
                          pa_subscription_event_type_t type,
                          uint32_t /*idx*/,
                          void* userdata) {
    if ((type & PA_SUBSCRIPTION_EVENT_FACILITY_MASK) !=
        PA_SUBSCRIPTION_EVENT_SERVER) {
      return;
    }
    // Server-wide change (default sink/source among them): fetch fresh info
    // and compare against the last observed default source.
    pa_operation_unref(pa_context_get_server_info(c, OnServerInfo, userdata));
  }

  static void OnServerInfo(pa_context* /*c*/,
                           const pa_server_info* info,
                           void* userdata) {
    auto* self = static_cast<Impl*>(userdata);
    if (!info || !info->default_source_name) {
      return;
    }
    const std::string source = info->default_source_name;
    if (source == self->last_default_source_) {
      return;
    }
    if (!self->last_default_source_.empty()) {
      AudioMonitorFileLog("[AudioDeviceMonitor] default source changed: " +
                          self->last_default_source_ + " -> " + source);
      if (self->callback_) {
        self->callback_();
      }
    } else {
      AudioMonitorFileLog("[AudioDeviceMonitor] initial default source: " +
                          source);
    }
    self->last_default_source_ = source;
  }

  void Cleanup() {
    if (context_) {
      pa_context_disconnect(context_);
      pa_context_unref(context_);
      context_ = nullptr;
    }
    if (mainloop_) {
      pa_threaded_mainloop_free(mainloop_);
      mainloop_ = nullptr;
      mainloop_api_ = nullptr;
    }
  }

  std::function<void()> callback_;
  std::string last_default_source_;
  pa_threaded_mainloop* mainloop_ = nullptr;
  pa_mainloop_api* mainloop_api_ = nullptr;
  pa_context* context_ = nullptr;
  bool mainloop_running_ = false;
};

#else  // !HAVE_LIBPULSE

class PulseDefaultDeviceMonitor::Impl {
 public:
  explicit Impl(std::function<void()> on_default_source_changed)
      : callback_(std::move(on_default_source_changed)) {}
  void Start() {}
  void Stop() {}

 private:
  std::function<void()> callback_;
};

#endif  // HAVE_LIBPULSE

PulseDefaultDeviceMonitor::PulseDefaultDeviceMonitor()
    : impl_(new Impl([] {})) {}

PulseDefaultDeviceMonitor::~PulseDefaultDeviceMonitor() { delete impl_; }

void PulseDefaultDeviceMonitor::Start(
    std::function<void()> on_default_source_changed) {
  impl_->Stop();
  delete impl_;
  impl_ = new Impl(std::move(on_default_source_changed));
  impl_->Start();
}

void PulseDefaultDeviceMonitor::Stop() { impl_->Stop(); }

}  // namespace flutter_webrtc_plugin
