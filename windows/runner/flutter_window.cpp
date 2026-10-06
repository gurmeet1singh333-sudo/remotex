#include "flutter_window.h"

#include <algorithm>
#include <optional>
#include <thread>

#include "flutter/generated_plugin_registrant.h"
#include <flutter/standard_method_codec.h>

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
  screen_capture_ = std::make_shared<WindowsScreenCapture>();
  screen_capture_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "remotex/screen_capture",
          &flutter::StandardMethodCodec::GetInstance());
  screen_capture_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "cursorPosition") {
          CURSORINFO cursor_info = {};
          cursor_info.cbSize = sizeof(cursor_info);
          const int width = GetSystemMetrics(SM_CXSCREEN);
          const int height = GetSystemMetrics(SM_CYSCREEN);
          if (width <= 0 || height <= 0 || !GetCursorInfo(&cursor_info)) {
            result->Error("cursor_unavailable",
                          "The Windows cursor position is unavailable.");
            return;
          }
          const POINT cursor_position = cursor_info.ptScreenPos;
          const bool on_primary_screen =
              cursor_position.x >= 0 && cursor_position.x < width &&
              cursor_position.y >= 0 && cursor_position.y < height;
          flutter::EncodableMap cursor;
          cursor[flutter::EncodableValue("x")] = flutter::EncodableValue(
              std::clamp(cursor_position.x, 0, width - 1));
          cursor[flutter::EncodableValue("y")] = flutter::EncodableValue(
              std::clamp(cursor_position.y, 0, height - 1));
          cursor[flutter::EncodableValue("width")] =
              flutter::EncodableValue(width);
          cursor[flutter::EncodableValue("height")] =
              flutter::EncodableValue(height);
          cursor[flutter::EncodableValue("visible")] =
              flutter::EncodableValue(
                  (cursor_info.flags & CURSOR_SHOWING) != 0 &&
                  on_primary_screen);
          result->Success(flutter::EncodableValue(cursor));
          return;
        }
        if (call.method_name() == "start") {
          int width = 0;
          int height = 0;
          if (!screen_capture_->Start(&width, &height)) {
            result->Error("capture_unavailable",
                          "The Windows desktop could not be captured.");
            return;
          }
          flutter::EncodableMap dimensions;
          dimensions[flutter::EncodableValue("width")] =
              flutter::EncodableValue(width);
          dimensions[flutter::EncodableValue("height")] =
              flutter::EncodableValue(height);
          result->Success(flutter::EncodableValue(dimensions));
          return;
        }
        if (call.method_name() == "stop") {
          screen_capture_->Stop();
          result->Success();
          return;
        }
        if (call.method_name() != "frame") {
          result->NotImplemented();
          return;
        }
        {
          std::lock_guard<std::mutex> lock(capture_calls_mutex_);
          ++pending_capture_calls_;
        }
        const auto capture = screen_capture_;
        std::thread(
            [this, capture,
             result = std::move(result)]() mutable {
              try {
                WindowsScreenCapture::Frame frame;
                const bool ok = capture->Capture(&frame);
                if (!ok) {
                  result->Error("capture_failed",
                                "Windows desktop capture failed.");
                } else if (!frame.jpeg.empty()) {
                  flutter::EncodableMap encoded_frame;
                  encoded_frame[flutter::EncodableValue("width")] =
                      flutter::EncodableValue(frame.width);
                  encoded_frame[flutter::EncodableValue("height")] =
                      flutter::EncodableValue(frame.height);
                  encoded_frame[flutter::EncodableValue("data")] =
                      flutter::EncodableValue(std::move(frame.jpeg));
                  result->Success(flutter::EncodableValue(encoded_frame));
                } else {
                  result->Success(
                      flutter::EncodableValue(flutter::EncodableMap{}));
                }
              } catch (...) {
                result->Error("capture_failed",
                              "Windows desktop capture failed.");
              }
              {
                std::lock_guard<std::mutex> lock(capture_calls_mutex_);
                --pending_capture_calls_;
              }
              capture_calls_changed_.notify_all();
            })
            .detach();
      });
  remote_input_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "remotex/remote_input",
          &flutter::StandardMethodCodec::GetInstance());
  remote_input_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        remote_input_.Handle(call, std::move(result));
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

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
  if (screen_capture_channel_) {
    screen_capture_channel_->SetMethodCallHandler(nullptr);
  }
  if (remote_input_channel_) {
    remote_input_channel_->SetMethodCallHandler(nullptr);
  }
  remote_input_.ReleaseAll();
  if (screen_capture_) screen_capture_->Stop();
  {
    std::unique_lock<std::mutex> lock(capture_calls_mutex_);
    capture_calls_changed_.wait(
        lock, [this] { return pending_capture_calls_ == 0; });
  }
  screen_capture_channel_.reset();
  remote_input_channel_.reset();
  screen_capture_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
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
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
