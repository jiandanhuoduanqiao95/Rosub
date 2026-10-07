#include "flutter_webrtc/flutter_web_r_t_c_plugin.h"

#include "audio_device_monitor.h"
#include "flutter_common.h"
#include "flutter_webrtc.h"
#include "task_runner_windows.h"

#include <flutter/plugin_registrar_windows.h>
#include <flutter_messenger.h>
#include <flutter_plugin_registrar.h>

#include <iostream>
#include <string>
#include <cstdio>
#include <cstdlib>

const char* kChannelName = "FlutterWebRTC.Method";
static flutter_webrtc_plugin::FlutterWebRTC* g_shared_instance = nullptr;

namespace flutter_webrtc_plugin {

// FlutterWebRTC with switch-to-default-device entry points for the audio
// device monitor below (PATCH(chatroom): Windows mid-call output AND input
// device following; see AudioDeviceMonitor).
//
// Index semantics of the active legacy Windows ADM (AudioDeviceWindowsCore):
// SetPlayoutDevice(index) / SetRecordingDevice(index) index the ACTIVE
// ENDPOINT COLLECTION — index 0 is the first enumerated device, NOT the
// default (the ALSA ADM on Linux is the opposite: index 0 IS "default").
// The default endpoint must be located by matching its IMMDevice::GetId
// string against the enumeration reported through RTCAudioDevice::
// PlayoutDeviceName / RecordingDeviceName (which return the endpoint ID in
// their guid out-param). Note getUserMedia pins RECORDING to index 0 when
// no sourceId is given (flutter_media_stream.cc), so freshly acquired media
// must be re-pointed at the default communications device explicitly.
class FlutterWebRTCAudioFollower : public FlutterWebRTC {
 public:
  explicit FlutterWebRTCAudioFollower(FlutterWebRTCPlugin* plugin)
      : FlutterWebRTC(plugin) {}

  // getUserMedia pins RECORDING to enumeration index 0 (flutter_media_stream.cc)
  // and leaves playout on the wrapper default. Record that baseline so the
  // same-target skip below can suppress needless recording restarts from the
  // very first fire (a restart is the one operation that can kill a working
  // mic when its Stop->Set->Init->Start chain fails mid-way).
  void OnMediaAcquired() {
    char name[256];
    char guid[256];
    if (audio_device_ && audio_device_->RecordingDeviceName(0, name, guid) == 0) {
      last_capture_endpoint_ = guid;
      char buf[384];
      snprintf(buf, sizeof(buf),
               "[AudioDeviceMonitor] media acquired, capture pinned to %s",
               guid);
      AudioMonitorFileLog(buf);
    } else {
      last_capture_endpoint_.clear();
    }
    last_playout_endpoint_.clear();
  }

  // Re-points the bundled libwebrtc ADM at the playout device matching
  // |endpoint_id| (the new default communications endpoint, as resolved by
  // AudioDeviceMonitor). The wrapper-level SetPlayoutDevice restarts playout
  // on the worker thread (StopPlayout -> Set -> InitPlayout -> StartPlayout)
  // when a call is active, so this is safe mid-call: it follows speaker/
  // headphone default changes and recovers calls whose endpoint was
  // invalidated by an unplug. No-op until WebRTC media was initialized
  // (|audio_device_| is created with the peer connection factory).
  void SwitchToDefaultPlayoutDevice(const std::string& endpoint_id) {
    if (!audio_device_) {
      AudioMonitorFileLog("[AudioDeviceMonitor] no ADM yet, skip " +
                          endpoint_id);
      return;
    }
    // PATCH(chatroom): same-target skip. A default-change event whose target
    // is the endpoint the ADM already plays on still restarted playout
    // (observed with Bluetooth disconnects, where the default merely falls
    // back to the built-in speakers). The restart is wasted work; skip it
    // unless the endpoint actually changed.
    if (endpoint_id == last_playout_endpoint_) {
      AudioMonitorFileLog("[AudioDeviceMonitor] playout already on target, "
                          "skip restart " + endpoint_id);
      return;
    }
    const int16_t count = audio_device_->PlayoutDevices();
    AudioMonitorFileLog("[AudioDeviceMonitor] ADM playout devices=" +
                        std::to_string(count));
    char name[256];
    char guid[256];
    for (int16_t i = 0; i < count; ++i) {
      if (audio_device_->PlayoutDeviceName(i, name, guid) != 0) {
        AudioMonitorFileLog("[AudioDeviceMonitor] index " +
                            std::to_string(i) + " name query failed");
        continue;
      }
      AudioMonitorFileLog("[AudioDeviceMonitor] index " + std::to_string(i) +
                          " guid=" + guid + " name=" + name);
      if (endpoint_id == guid) {
        AudioMonitorFileLog("[AudioDeviceMonitor] switching playout to " +
                            std::to_string(i) + " \"" + name + "\"");
        // Fire-and-forget on the factory worker thread; returns 0 always.
        audio_device_->SetPlayoutDevice(i);
        last_playout_endpoint_ = endpoint_id;
        return;
      }
    }
    AudioMonitorFileLog("[AudioDeviceMonitor] endpoint not matched: " +
                        endpoint_id);
  }

  // Mirror of SwitchToDefaultPlayoutDevice for the recording (microphone)
  // side: getUserMedia pins recording to enumeration index 0 (an arbitrary
  // endpoint), and without this the headset mic never becomes the call mic.
  // The wrapper-level SetRecordingDevice restarts recording on the worker
  // thread when a call is active. |capture_verdict| is the monitor's
  // CaptureProbeResult for this target (-1 = none): a not-alive verdict
  // keeps the CURRENT microphone when that endpoint still enumerates (the
  // silent Bluetooth SCO trap), but switches anyway once the current one
  // has vanished — an unplug leaves no other choice.
  void SwitchToDefaultRecordingDevice(const std::string& endpoint_id,
                                      bool force,
                                      int capture_verdict) {
    if (!audio_device_) {
      AudioMonitorFileLog("[AudioDeviceMonitor] no ADM yet, skip mic " +
                          endpoint_id);
      return;
    }
    // PATCH(chatroom): same-target skip — a default-change event whose target
    // equals the endpoint recording already runs on (user disconnects their
    // Bluetooth headset while the mic stayed on the built-in array) must NOT
    // restart recording: the wrapper Stop->Set->Init->Start chain is
    // fire-and-forget and a failed Init in the device-teardown storm leaves
    // the call muted for good (observed: mic dead after EDIFIER disconnect,
    // playback fine). Force fires (resync from the Dart capture watchdog)
    // still restart: a dead pipeline on the right endpoint needs exactly
    // that restart to revive.
    if (!force && endpoint_id == last_capture_endpoint_) {
      AudioMonitorFileLog("[AudioDeviceMonitor] recording already on target, "
                          "skip restart " + endpoint_id);
      return;
    }
    const int16_t count = audio_device_->RecordingDevices();
    AudioMonitorFileLog("[AudioDeviceMonitor] ADM recording devices=" +
                        std::to_string(count));
    char name[256];
    char guid[256];
    bool target_found = false;
    int16_t target_index = -1;
    bool current_still_present = last_capture_endpoint_.empty();
    for (int16_t i = 0; i < count; ++i) {
      if (audio_device_->RecordingDeviceName(i, name, guid) != 0) {
        AudioMonitorFileLog("[AudioDeviceMonitor] mic index " +
                            std::to_string(i) + " name query failed");
        continue;
      }
      AudioMonitorFileLog("[AudioDeviceMonitor] mic index " +
                          std::to_string(i) + " guid=" + guid + " name=" +
                          name);
      if (endpoint_id == guid) {
        target_found = true;
        target_index = i;
      }
      if (guid == last_capture_endpoint_) {
        current_still_present = true;
      }
    }
    if (!target_found) {
      AudioMonitorFileLog("[AudioDeviceMonitor] mic endpoint not matched: " +
                          endpoint_id);
      return;
    }
    // Liveness verdict (0 = kAlive). Not-alive: keep the working current
    // microphone; only override when the current endpoint is gone (or is
    // the same one — a forced revive) — switching is then the only option.
    if (capture_verdict != 0 && capture_verdict != -1 &&
        current_still_present && last_capture_endpoint_ != endpoint_id) {
      char buf[384];
      snprintf(buf, sizeof(buf),
               "[AudioDeviceMonitor] capture target not alive "
               "(verdict=%d, force=%d), keeping current mic",
               capture_verdict, force ? 1 : 0);
      AudioMonitorFileLog(buf);
      return;
    }
    char buf[384];
    snprintf(buf, sizeof(buf),
             "[AudioDeviceMonitor] switching recording to %d \"%s\"%s",
             (int)target_index, name, force ? " (forced)" : "");
    AudioMonitorFileLog(buf);
    audio_device_->SetRecordingDevice(target_index);
    last_capture_endpoint_ = endpoint_id;
  }

 private:
  // Endpoint the ADM was last pointed at per flow ("" = unknown). Feeds the
  // same-target skip; capture is baselined at getUserMedia (pinned index 0).
  std::string last_capture_endpoint_;
  std::string last_playout_endpoint_;
};

// A webrtc plugin for windows/linux.
class FlutterWebRTCPluginImpl : public FlutterWebRTCPlugin {
 public:
  static void RegisterWithRegistrar(PluginRegistrar* registrar) {
    auto channel = std::make_unique<MethodChannel>(
        registrar->messenger(), kChannelName,
        &flutter::StandardMethodCodec::GetInstance());

    auto* channel_pointer = channel.get();

    // Uses new instead of make_unique due to private constructor.
    std::unique_ptr<FlutterWebRTCPluginImpl> plugin(
        new FlutterWebRTCPluginImpl(registrar, std::move(channel)));
    channel_pointer->SetMethodCallHandler(
        [plugin_pointer = plugin.get()](const auto& call, auto result) {
          plugin_pointer->HandleMethodCall(call, std::move(result));
        });

    registrar->AddPlugin(std::move(plugin));
  }

  virtual ~FlutterWebRTCPluginImpl() {
    if (audio_monitor_) {
      audio_monitor_->Stop();
      audio_monitor_->Release();
      audio_monitor_ = nullptr;
    }
  }

  BinaryMessenger* messenger() { return messenger_; }

  TextureRegistrar* textures() { return textures_; }

  TaskRunner* task_runner() { return task_runner_.get(); }

 private:
  // Creates a plugin that communicates on the given channel.
  FlutterWebRTCPluginImpl(PluginRegistrar* registrar,
                          std::unique_ptr<MethodChannel> channel)
      : channel_(std::move(channel)),
        messenger_(registrar->messenger()),
        textures_(registrar->texture_registrar()),
        task_runner_(std::make_unique<TaskRunnerWindows>()) {
    webrtc_ = std::make_unique<FlutterWebRTCAudioFollower>(this);
    g_shared_instance = webrtc_.get();
    // Follow the system default input/output devices mid-call
    // (PATCH(chatroom)): the bundled libwebrtc legacy Windows ADM implements
    // no IMMNotificationClient, so it never learns about device changes —
    // listen here and re-point playout/recording at the matching enumeration
    // index via the task runner (the same platform thread the method
    // handlers call the ADM's wrapper on).
    audio_monitor_ = AudioDeviceMonitor::Create();
    audio_monitor_->Start([this](AudioDeviceFlow flow,
                                 const std::string& endpoint_id, bool force,
                                 int capture_verdict) {
      task_runner_->EnqueueTask(
          [this, flow, endpoint_id, force, capture_verdict]() {
        if (flow == AudioDeviceFlow::kRender) {
          webrtc_->SwitchToDefaultPlayoutDevice(endpoint_id);
        } else {
          webrtc_->SwitchToDefaultRecordingDevice(endpoint_id, force,
                                                  capture_verdict);
        }
      });
    });
  }

  // Called when a method is called on |channel_|;
  void HandleMethodCall(const MethodCall& method_call,
                        std::unique_ptr<MethodResult> result) {
    // PATCH(chatroom): capture-resync entry point for the Dart capture-death
    // watchdog (outbound audio stuck at digital silence mid-call). Forces a
    // recording re-bind to the current default — the only cure for a wrapper
    // Stop->Set->Init->Start chain that failed mid-way. Other platforms
    // return notImplemented and the Dart side ignores the error.
    if (method_call.method_name() == "chatroomAudioResync") {
      if (audio_monitor_) {
        audio_monitor_->ForceFire(AudioDeviceFlow::kCapture);
      }
      result->Success();
      return;
    }
    const bool is_get_user_media =
        method_call.method_name() == "getUserMedia";
    if (is_get_user_media) {
      // Baseline the same-target skip memory before media is acquired: the
      // ADM records from enumeration index 0 after getUserMedia returns.
      task_runner_->EnqueueTask([this]() {
        webrtc_->OnMediaAcquired();
      });
    }
    // handle method call and forward to webrtc native sdk.
    auto method_call_proxy = MethodCallProxy::Create(method_call);
    webrtc_->HandleMethodCall(*method_call_proxy.get(),
                              MethodResultProxy::Create(std::move(result)));
    if (is_get_user_media && audio_monitor_) {
      // PATCH(chatroom): getUserMedia pins RECORDING to enumeration index 0
      // (flutter_media_stream.cc), which is an arbitrary endpoint — ask the
      // monitor to re-probe and re-point the mic at the default
      // communications capture device (no-op before media init; the switch
      // itself restarts recording on the worker thread when active).
      audio_monitor_->Probe(AudioDeviceFlow::kCapture);
    }
  }

 private:
  std::unique_ptr<MethodChannel> channel_;
  std::unique_ptr<FlutterWebRTCAudioFollower> webrtc_;
  BinaryMessenger* messenger_;
  TextureRegistrar* textures_;
  std::unique_ptr<TaskRunner> task_runner_;
  AudioDeviceMonitor* audio_monitor_ = nullptr;
};

}  // namespace flutter_webrtc_plugin


void FlutterWebRTCPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  // Capture the host messenger before creating the plugin, so that the event
  // channels can check whether the engine is still running before they
  // unregister their stream handlers; see ~EventChannelProxyImpl in
  // common/cpp/src/flutter_common.cc.
  SetEventChannelHostMessenger(
      FlutterDesktopPluginRegistrarGetMessenger(registrar));
  flutter_webrtc_plugin::FlutterWebRTCPluginImpl::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}

flutter_webrtc_plugin::FlutterWebRTC* FlutterWebRTCPluginSharedInstance() {
  return g_shared_instance;
} 