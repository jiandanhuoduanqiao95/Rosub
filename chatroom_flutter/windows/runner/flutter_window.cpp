#include "flutter_window.h"

#include <optional>
#include <string>
#include <vector>

#include <shellapi.h>

#include "flutter/generated_plugin_registrant.h"

namespace {
// 阶段 Q2：DragQueryFileW 返回宽字符路径，通道按协议传 UTF-8
std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) {
    return std::string();
  }
  int size = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(),
                                 static_cast<int>(wide.size()), nullptr, 0,
                                 nullptr, nullptr);
  std::string utf8(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()),
                      utf8.data(), size, nullptr, nullptr);
  return utf8;
}

// 阶段 Q2 真机补丁（2026-09-19）：拖放事件派发给光标下的窗口——Flutter
// 视图是铺满客户区的子窗口，DragAcceptFiles 仅注册顶层窗口时，拖到视图
// 上不会产生任何事件（真机实测：无放置光标、无 WM_DROPFILES）。子类化
// 视图窗口把 WM_DROPFILES 转回 FlutterWindow 处理。
FlutterWindow* g_drop_target_window = nullptr;
WNDPROC g_view_original_proc = nullptr;

LRESULT CALLBACK FlutterViewChildProc(HWND hwnd, UINT const message,
                                     WPARAM const wparam,
                                     LPARAM const lparam) {
  if (message == WM_DROPFILES && g_drop_target_window) {
    g_drop_target_window->HandleDrop(reinterpret_cast<HDROP>(wparam));
    return 0;
  }
  return CallWindowProc(g_view_original_proc, hwnd, message, wparam, lparam);
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  // 阶段 Q2：启用窗口文件拖拽（DragAcceptFiles → WM_DROPFILES），拖入
  // 路径经 chatroom/dnd 通道 'files' 方法转发给 Dart 侧 FileDrop 监听
  // （与 Linux runner 拖拽通道同协议：直接传路径 List）
  dnd_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "chatroom/dnd",
          &flutter::StandardMethodCodec::GetInstance());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // 阶段 Q2 真机补丁：视图子窗口同样接受拖放并子类化转发（见匿名
  // 命名空间内说明）；顶层窗口的注册保留作为兜底。
  g_drop_target_window = this;
  HWND view_hwnd = flutter_controller_->view()->GetNativeWindow();
  g_view_original_proc = reinterpret_cast<WNDPROC>(
      SetWindowLongPtr(view_hwnd, GWLP_WNDPROC,
                       reinterpret_cast<LONG_PTR>(FlutterViewChildProc)));
  DragAcceptFiles(view_hwnd, TRUE);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // 阶段 Q2：先还原视图子类化窗口过程，再释放控制器
  if (flutter_controller_ && g_view_original_proc) {
    SetWindowLongPtr(flutter_controller_->view()->GetNativeWindow(),
                     GWLP_WNDPROC,
                     reinterpret_cast<LONG_PTR>(g_view_original_proc));
    g_view_original_proc = nullptr;
  }
  g_drop_target_window = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }
  dnd_channel_ = nullptr;

  Win32Window::OnDestroy();
}

void FlutterWindow::HandleDrop(HDROP drop) {
  UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  flutter::EncodableList files;
  for (UINT i = 0; i < count; ++i) {
    UINT length = DragQueryFileW(drop, i, nullptr, 0);
    if (length == 0) {
      continue;
    }
    std::wstring wide(length + 1, L'\0');
    DragQueryFileW(drop, i, wide.data(), length + 1);
    wide.resize(length);
    files.emplace_back(WideToUtf8(wide));
  }
  DragFinish(drop);
  if (dnd_channel_ && !files.empty()) {
    dnd_channel_->InvokeMethod("files",
                               std::make_unique<flutter::EncodableValue>(files));
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_DROPFILES:
      HandleDrop(reinterpret_cast<HDROP>(wparam));
      return 0;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
