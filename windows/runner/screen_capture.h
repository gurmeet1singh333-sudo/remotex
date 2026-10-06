#ifndef RUNNER_SCREEN_CAPTURE_H_
#define RUNNER_SCREEN_CAPTURE_H_

#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>

#include <cstdint>
#include <mutex>
#include <vector>

class WindowsScreenCapture {
 public:
  struct Frame {
    std::vector<uint8_t> jpeg;
    int width = 0;
    int height = 0;
  };

  bool Start(int* width, int* height);
  bool Capture(Frame* frame);
  void Stop();

 private:
  bool StartLocked();
  void StopLocked();

  std::mutex mutex_;
  Microsoft::WRL::ComPtr<ID3D11Device> device_;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
  Microsoft::WRL::ComPtr<IDXGIOutputDuplication> duplication_;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> staging_;
  UINT desktop_width_ = 0;
  UINT desktop_height_ = 0;
  int output_width_ = 0;
  int output_height_ = 0;
};

#endif  // RUNNER_SCREEN_CAPTURE_H_
