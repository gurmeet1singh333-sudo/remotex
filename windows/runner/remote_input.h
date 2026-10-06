#ifndef RUNNER_REMOTE_INPUT_H_
#define RUNNER_REMOTE_INPUT_H_

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>
#include <set>
#include <string>

class WindowsRemoteInput {
 public:
  void Handle(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void ReleaseAll();

 private:
  bool SendKey(const std::string& key, bool down);
  bool PressKey(const std::string& key);

  std::set<unsigned short> pressed_keys_;
  std::set<DWORD> pressed_buttons_;
};

#endif  // RUNNER_REMOTE_INPUT_H_
