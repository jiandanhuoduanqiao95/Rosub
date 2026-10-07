#include "flutter_webrtc/flutter_web_r_t_c_plugin.h"

#include "flutter_common.h"
#include "flutter_webrtc.h"
#include "pulse_default_device_monitor.h"
#include "task_runner_linux.h"

const char* kChannelName = "FlutterWebRTC.Method";
static flutter_webrtc_plugin::FlutterWebRTC* g_shared_instance = nullptr;
//#if defined(_WINDOWS)

namespace flutter_webrtc_plugin {

// FlutterWebRTC with a re-point-to-default-mic entry point for the pulse
// default-device monitor below (PATCH(chatroom): Linux mid-call input
// device following).
//
// The bundled libwebrtc uses the ALSA ADM, whose enumeration index 0 IS the
// "default" PCM (unlike the Windows legacy ADM) and whose InitRecording
// re-resolves the device name from the index — so restarting recording on
// index 0 re-opens the "default" PCM against the CURRENT default source.
// getUserMedia already pins recording to index 0, so no initial rebind is
// needed here; only default-source CHANGES mid-call require the restart.
class FlutterWebRTCAudioFollower : public FlutterWebRTC {
 public:
  explicit FlutterWebRTCAudioFollower(FlutterWebRTCPlugin* plugin)
      : FlutterWebRTC(plugin) {}

  // Restarts capture on the ALSA "default" PCM so an active call's mic
  // follows a default-source change (headset plugged/unplugged). The
  // wrapper-level SetRecordingDevice stops/init/starts recording on the
  // factory worker thread when recording is active.
  void SwitchToDefaultRecordingDevice() {
    if (!audio_device_) {
      AudioMonitorFileLog("[AudioDeviceMonitor] no ADM yet, skip mic");
      return;
    }
    AudioMonitorFileLog(
        "[AudioDeviceMonitor] switching recording to ALSA default "
        "(devices=" +
        std::to_string(audio_device_->RecordingDevices()) + ")");
    audio_device_->SetRecordingDevice(0);
  }
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
    if (default_source_monitor_) {
      default_source_monitor_->Stop();
      delete default_source_monitor_;
      default_source_monitor_ = nullptr;
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
        task_runner_(std::make_unique<TaskRunnerLinux>()) {
    webrtc_ = std::make_unique<FlutterWebRTCAudioFollower>(this);
    g_shared_instance = webrtc_.get();
    // Follow the system default input device mid-call (PATCH(chatroom)):
    // the ALSA ADM's capture stream binds to the default source at open
    // time and the ADM learns nothing about later default changes — watch
    // pulse and restart capture (see FlutterWebRTCAudioFollower above).
    // Playout needs no counterpart: the pulse server migrates the "default"
    // PCM's sink stream when the default sink changes.
    default_source_monitor_ = new PulseDefaultDeviceMonitor();
    default_source_monitor_->Start([this]() {
      task_runner_->EnqueueTask([this]() {
        webrtc_->SwitchToDefaultRecordingDevice();
      });
    });
  }

  // Called when a method is called on |channel_|;
  void HandleMethodCall(const MethodCall& method_call,
                        std::unique_ptr<MethodResult> result) {
    // handle method call and forward to webrtc native sdk.
    auto method_call_proxy = MethodCallProxy::Create(method_call);
    webrtc_->HandleMethodCall(
        *method_call_proxy.get(),
        MethodResultProxy::Create(std::move(result), task_runner()));
  }

 private:
  std::unique_ptr<MethodChannel> channel_;
  std::unique_ptr<FlutterWebRTCAudioFollower> webrtc_;
  BinaryMessenger* messenger_;
  TextureRegistrar* textures_;
  std::unique_ptr<TaskRunner> task_runner_;
  PulseDefaultDeviceMonitor* default_source_monitor_ = nullptr;
};

}  // namespace flutter_webrtc_plugin

void flutter_web_r_t_c_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  static auto* plugin_registrar = new flutter::PluginRegistrar(registrar);
  flutter_webrtc_plugin::FlutterWebRTCPluginImpl::RegisterWithRegistrar(
      plugin_registrar);
}

flutter_webrtc_plugin::FlutterWebRTC* flutter_webrtc_plugin_get_shared_instance() {
  return g_shared_instance;
} 