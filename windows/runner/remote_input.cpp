#include "remote_input.h"

#include <windows.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <variant>

namespace {
const flutter::EncodableValue* Find(
    const flutter::EncodableMap& values,
    const char* key) {
  const auto found = values.find(flutter::EncodableValue(key));
  return found == values.end() ? nullptr : &found->second;
}

const std::string* StringValue(const flutter::EncodableMap& values,
                               const char* key) {
  const auto* value = Find(values, key);
  return value == nullptr ? nullptr : std::get_if<std::string>(value);
}

bool NumberValue(const flutter::EncodableMap& values, const char* key,
                 double* output) {
  const auto* value = Find(values, key);
  if (value == nullptr) return false;
  if (const auto* floating = std::get_if<double>(value)) {
    *output = *floating;
    return std::isfinite(*floating);
  }
  if (const auto* integer = std::get_if<int32_t>(value)) {
    *output = static_cast<double>(*integer);
    return true;
  }
  if (const auto* integer = std::get_if<int64_t>(value)) {
    *output = static_cast<double>(*integer);
    return true;
  }
  return false;
}

WORD VirtualKey(const std::string& key) {
  if (key.size() == 1) {
    const SHORT translated = VkKeyScanA(key[0]);
    return translated == -1 ? 0 : LOBYTE(translated);
  }
  if (key == "Space") return VK_SPACE;
  if (key == "Enter") return VK_RETURN;
  if (key == "Backspace") return VK_BACK;
  if (key == "Tab") return VK_TAB;
  if (key == "Escape") return VK_ESCAPE;
  if (key == "ArrowUp") return VK_UP;
  if (key == "ArrowDown") return VK_DOWN;
  if (key == "ArrowLeft") return VK_LEFT;
  if (key == "ArrowRight") return VK_RIGHT;
  if (key == "Shift") return VK_SHIFT;
  if (key == "Control") return VK_CONTROL;
  if (key == "Alt") return VK_MENU;
  if (key == "Meta") return VK_LWIN;
  return 0;
}

DWORD ButtonFlag(const std::string& button, bool down) {
  if (button == "left") return down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP;
  if (button == "right") return down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP;
  if (button == "middle") return down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP;
  return 0;
}

bool SendMouse(DWORD flags, LONG data = 0, LONG x = 0, LONG y = 0) {
  INPUT input = {};
  input.type = INPUT_MOUSE;
  input.mi.dx = x;
  input.mi.dy = y;
  input.mi.mouseData = static_cast<DWORD>(data);
  input.mi.dwFlags = flags;
  return SendInput(1, &input, sizeof(INPUT)) == 1;
}
}  // namespace

void WindowsRemoteInput::Handle(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* arguments =
      std::get_if<flutter::EncodableMap>(call.arguments());
  if (call.method_name() == "releaseAll") {
    ReleaseAll();
    result->Success();
    return;
  }
  if (arguments == nullptr) {
    result->Error("invalid_input", "Invalid remote input command.");
    return;
  }

  if (call.method_name() == "movePointer") {
    double x = 0;
    double y = 0;
    const int width = GetSystemMetrics(SM_CXSCREEN);
    const int height = GetSystemMetrics(SM_CYSCREEN);
    if (!NumberValue(*arguments, "x", &x) ||
        !NumberValue(*arguments, "y", &y) || x < 0 || x > 1 || y < 0 ||
        y > 1 || width <= 0 || height <= 0) {
      result->Error("invalid_input", "Invalid pointer coordinates.");
      return;
    }
    const LONG absolute_x = static_cast<LONG>(std::llround(x * 65535.0));
    const LONG absolute_y = static_cast<LONG>(std::llround(y * 65535.0));
    if (!SendMouse(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE, 0, absolute_x,
                   absolute_y)) {
      result->Error("input_failed", "Windows rejected pointer input.");
      return;
    }
    result->Success();
    return;
  }

  if (call.method_name() == "mouseButton") {
    const auto* button = StringValue(*arguments, "button");
    const auto* action = StringValue(*arguments, "action");
    if (button == nullptr || action == nullptr ||
        ButtonFlag(*button, true) == 0 ||
        (*action != "down" && *action != "up" && *action != "click" &&
         *action != "double_click")) {
      result->Error("invalid_input", "Invalid mouse button command.");
      return;
    }
    const auto send = [this, button](bool down) {
      const DWORD flag = ButtonFlag(*button, down);
      if (!SendMouse(flag)) return false;
      if (down) {
        pressed_buttons_.insert(flag);
      } else {
        pressed_buttons_.erase(ButtonFlag(*button, true));
      }
      return true;
    };
    bool success = true;
    if (*action == "down") {
      success = send(true);
    } else if (*action == "up") {
      success = send(false);
    } else {
      const int count = *action == "double_click" ? 2 : 1;
      for (int index = 0; index < count && success; ++index) {
        success = send(true) && send(false);
      }
    }
    if (!success) {
      result->Error("input_failed", "Windows rejected mouse input.");
      return;
    }
    result->Success();
    return;
  }

  if (call.method_name() == "scroll") {
    double delta_x = 0;
    double delta_y = 0;
    if (!NumberValue(*arguments, "deltaX", &delta_x) ||
        !NumberValue(*arguments, "deltaY", &delta_y) ||
        std::abs(delta_x) > 2000 || std::abs(delta_y) > 2000 ||
        (delta_x == 0 && delta_y == 0)) {
      result->Error("invalid_input", "Invalid scroll command.");
      return;
    }
    bool success = true;
    if (delta_y != 0) {
      const auto amount = static_cast<LONG>(
          std::clamp(-delta_y * WHEEL_DELTA / 120.0, -2000.0, 2000.0));
      success = SendMouse(MOUSEEVENTF_WHEEL, amount);
    }
    if (success && delta_x != 0) {
      const auto amount = static_cast<LONG>(
          std::clamp(-delta_x * WHEEL_DELTA / 120.0, -2000.0, 2000.0));
      success = SendMouse(MOUSEEVENTF_HWHEEL, amount);
    }
    if (!success) {
      result->Error("input_failed", "Windows rejected scroll input.");
      return;
    }
    result->Success();
    return;
  }

  if (call.method_name() == "keyboardKey") {
    const auto* key = StringValue(*arguments, "key");
    const auto* action = StringValue(*arguments, "action");
    if (key == nullptr || action == nullptr || VirtualKey(*key) == 0 ||
        (*action != "down" && *action != "up" && *action != "press")) {
      result->Error("invalid_input", "Invalid keyboard command.");
      return;
    }
    bool success = true;
    if (*action == "down") {
      success = SendKey(*key, true);
    } else if (*action == "up") {
      success = SendKey(*key, false);
    } else {
      success = PressKey(*key);
    }
    if (!success) {
      result->Error("input_failed", "Windows rejected keyboard input.");
      return;
    }
    result->Success();
    return;
  }

  result->NotImplemented();
}

bool WindowsRemoteInput::SendKey(const std::string& key, bool down) {
  const WORD virtual_key = VirtualKey(key);
  if (virtual_key == 0) return false;
  if (down && pressed_keys_.find(virtual_key) != pressed_keys_.end()) {
    return true;
  }
  if (!down && pressed_keys_.find(virtual_key) == pressed_keys_.end()) {
    return true;
  }

  INPUT input = {};
  input.type = INPUT_KEYBOARD;
  input.ki.wVk = virtual_key;
  input.ki.dwFlags = down ? 0 : KEYEVENTF_KEYUP;
  if (SendInput(1, &input, sizeof(INPUT)) != 1) return false;
  if (down) {
    pressed_keys_.insert(virtual_key);
  } else {
    pressed_keys_.erase(virtual_key);
  }
  return true;
}

bool WindowsRemoteInput::PressKey(const std::string& key) {
  if (key.size() != 1) {
    return SendKey(key, true) && SendKey(key, false);
  }
  const SHORT translated = VkKeyScanA(key[0]);
  if (translated == -1) return false;
  const WORD virtual_key = LOBYTE(translated);
  const bool needs_shift = (HIBYTE(translated) & 1) != 0;
  const bool shift_already_held =
      pressed_keys_.find(VK_SHIFT) != pressed_keys_.end();
  INPUT inputs[4] = {};
  UINT count = 0;
  if (needs_shift && !shift_already_held) {
    inputs[count].type = INPUT_KEYBOARD;
    inputs[count++].ki.wVk = VK_SHIFT;
  }
  inputs[count].type = INPUT_KEYBOARD;
  inputs[count++].ki.wVk = virtual_key;
  inputs[count].type = INPUT_KEYBOARD;
  inputs[count].ki.wVk = virtual_key;
  inputs[count++].ki.dwFlags = KEYEVENTF_KEYUP;
  if (needs_shift && !shift_already_held) {
    inputs[count].type = INPUT_KEYBOARD;
    inputs[count].ki.wVk = VK_SHIFT;
    inputs[count++].ki.dwFlags = KEYEVENTF_KEYUP;
  }
  return SendInput(count, inputs, sizeof(INPUT)) == count;
}

void WindowsRemoteInput::ReleaseAll() {
  for (const auto key : pressed_keys_) {
    INPUT input = {};
    input.type = INPUT_KEYBOARD;
    input.ki.wVk = key;
    input.ki.dwFlags = KEYEVENTF_KEYUP;
    SendInput(1, &input, sizeof(INPUT));
  }
  pressed_keys_.clear();
  for (const auto down_flag : pressed_buttons_) {
    DWORD up_flag = 0;
    if (down_flag == MOUSEEVENTF_LEFTDOWN) up_flag = MOUSEEVENTF_LEFTUP;
    if (down_flag == MOUSEEVENTF_RIGHTDOWN) up_flag = MOUSEEVENTF_RIGHTUP;
    if (down_flag == MOUSEEVENTF_MIDDLEDOWN) up_flag = MOUSEEVENTF_MIDDLEUP;
    if (up_flag != 0) SendMouse(up_flag);
  }
  pressed_buttons_.clear();
}
