#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // 阶段 Q2：WM_DROPFILES 共用入口（顶层窗口与视图子窗口两条路径）；
  // public——视图子类化窗口过程（匿名命名空间）需要调用
  void HandleDrop(HDROP drop);

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // 阶段 Q2：文件拖拽通道（WM_DROPFILES 拖入路径 → chatroom/dnd 'files'，
  // 与 Linux runner 拖拽通道同协议）
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      dnd_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
