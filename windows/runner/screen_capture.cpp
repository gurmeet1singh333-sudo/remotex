#include "screen_capture.h"

#include <d3d11_4.h>
#include <windows.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <cmath>
#include <iterator>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace {
constexpr UINT kMaximumSourcePixels = 17'000'000;
constexpr UINT kMaximumFramePixels = 960 * 540;
constexpr size_t kMaximumJpegBytes = 1024 * 1024;

bool EncodeJpeg(const WICPixelFormatGUID& input_format,
                const uint8_t* pixels,
                UINT source_width,
                UINT source_height,
                UINT stride,
                UINT width,
                UINT height,
                std::vector<uint8_t>* jpeg) {
  ComPtr<IWICImagingFactory> factory;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                              CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&factory)))) {
    return false;
  }
  ComPtr<IWICBitmap> bitmap;
  if (FAILED(factory->CreateBitmapFromMemory(
          source_width, source_height, input_format, stride,
          stride * source_height, const_cast<BYTE*>(pixels), &bitmap))) {
    return false;
  }
  ComPtr<IWICBitmapScaler> scaler;
  if (FAILED(factory->CreateBitmapScaler(&scaler)) ||
      FAILED(scaler->Initialize(bitmap.Get(), width, height,
                                WICBitmapInterpolationModeFant))) {
    return false;
  }
  ComPtr<IWICFormatConverter> converter;
  if (FAILED(factory->CreateFormatConverter(&converter)) ||
      FAILED(converter->Initialize(scaler.Get(), GUID_WICPixelFormat24bppBGR,
                                   WICBitmapDitherTypeNone, nullptr, 0,
                                   WICBitmapPaletteTypeCustom))) {
    return false;
  }

  const double qualities[] = {0.5, 0.35, 0.25};
  for (const double quality : qualities) {
    ComPtr<IStream> stream;
    if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &stream))) return false;
    ComPtr<IWICBitmapEncoder> encoder;
    if (FAILED(factory->CreateEncoder(GUID_ContainerFormatJpeg, nullptr,
                                      &encoder)) ||
        FAILED(encoder->Initialize(stream.Get(),
                                   WICBitmapEncoderNoCache))) {
      return false;
    }
    ComPtr<IWICBitmapFrameEncode> frame;
    ComPtr<IPropertyBag2> properties;
    if (FAILED(encoder->CreateNewFrame(&frame, &properties))) return false;
    PROPBAG2 quality_property = {};
    quality_property.pstrName = const_cast<wchar_t*>(L"ImageQuality");
    VARIANT value;
    VariantInit(&value);
    value.vt = VT_R4;
    value.fltVal = static_cast<float>(quality);
    if (FAILED(properties->Write(1, &quality_property, &value)) ||
        FAILED(frame->Initialize(properties.Get())) ||
        FAILED(frame->SetSize(width, height))) {
      VariantClear(&value);
      return false;
    }
    VariantClear(&value);
    WICPixelFormatGUID output_format = GUID_WICPixelFormat24bppBGR;
    if (FAILED(frame->SetPixelFormat(&output_format)) ||
        FAILED(frame->WriteSource(converter.Get(), nullptr)) ||
        FAILED(frame->Commit()) || FAILED(encoder->Commit())) {
      return false;
    }
    STATSTG stream_stats = {};
    if (FAILED(stream->Stat(&stream_stats, STATFLAG_NONAME)) ||
        stream_stats.cbSize.QuadPart == 0) {
      return false;
    }
    const ULONGLONG size = stream_stats.cbSize.QuadPart;
    if (size > kMaximumJpegBytes) continue;
    HGLOBAL memory = nullptr;
    if (FAILED(GetHGlobalFromStream(stream.Get(), &memory))) return false;
    const auto* bytes = static_cast<const uint8_t*>(GlobalLock(memory));
    if (bytes == nullptr) return false;
    jpeg->assign(bytes, bytes + size);
    GlobalUnlock(memory);
    return true;
  }
  return false;
}
}  // namespace

bool WindowsScreenCapture::Start(int* width, int* height) {
  std::lock_guard<std::mutex> lock(mutex_);
  StopLocked();
  if (!StartLocked()) {
    StopLocked();
    return false;
  }
  *width = output_width_;
  *height = output_height_;
  return true;
}

bool WindowsScreenCapture::StartLocked() {
  ComPtr<IDXGIFactory1> factory;
  if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) return false;

  ComPtr<IDXGIAdapter1> selected_adapter;
  ComPtr<IDXGIOutput> selected_output;
  for (UINT adapter_index = 0; !selected_output; ++adapter_index) {
    ComPtr<IDXGIAdapter1> adapter;
    if (factory->EnumAdapters1(adapter_index, &adapter) == DXGI_ERROR_NOT_FOUND)
      break;
    for (UINT output_index = 0;; ++output_index) {
      ComPtr<IDXGIOutput> output;
      if (adapter->EnumOutputs(output_index, &output) == DXGI_ERROR_NOT_FOUND)
        break;
      DXGI_OUTPUT_DESC description = {};
      if (SUCCEEDED(output->GetDesc(&description)) &&
          description.AttachedToDesktop) {
        MONITORINFO monitor = {};
        monitor.cbSize = sizeof(monitor);
        if (GetMonitorInfo(description.Monitor, &monitor) &&
            (monitor.dwFlags & MONITORINFOF_PRIMARY) != 0) {
          selected_adapter = adapter;
          selected_output = output;
          break;
        }
      }
    }
  }
  if (!selected_output && FAILED(factory->EnumAdapters1(0, &selected_adapter)))
    return false;
  if (!selected_output &&
      FAILED(selected_adapter->EnumOutputs(0, &selected_output))) {
    return false;
  }

  DXGI_OUTPUT_DESC output_description = {};
  if (FAILED(selected_output->GetDesc(&output_description))) return false;
  desktop_width_ =
      static_cast<UINT>(output_description.DesktopCoordinates.right -
                        output_description.DesktopCoordinates.left);
  desktop_height_ =
      static_cast<UINT>(output_description.DesktopCoordinates.bottom -
                        output_description.DesktopCoordinates.top);
  if (desktop_width_ == 0 || desktop_height_ == 0 ||
      static_cast<uint64_t>(desktop_width_) * desktop_height_ >
          kMaximumSourcePixels) {
    return false;
  }

  D3D_FEATURE_LEVEL feature_level;
  const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1,
                                      D3D_FEATURE_LEVEL_11_0,
                                      D3D_FEATURE_LEVEL_10_1,
                                      D3D_FEATURE_LEVEL_10_0};
  if (FAILED(D3D11CreateDevice(
          selected_adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr,
          D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels,
          static_cast<UINT>(std::size(levels)), D3D11_SDK_VERSION, &device_,
          &feature_level, &context_))) {
    return false;
  }
  ComPtr<ID3D11Multithread> multithread;
  if (SUCCEEDED(context_.As(&multithread))) {
    multithread->SetMultithreadProtected(TRUE);
  }
  ComPtr<IDXGIOutput1> output1;
  if (FAILED(selected_output.As(&output1)) ||
      FAILED(output1->DuplicateOutput(device_.Get(), &duplication_))) {
    return false;
  }

  D3D11_TEXTURE2D_DESC staging_description = {};
  staging_description.Width = desktop_width_;
  staging_description.Height = desktop_height_;
  staging_description.MipLevels = 1;
  staging_description.ArraySize = 1;
  staging_description.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  staging_description.SampleDesc.Count = 1;
  staging_description.Usage = D3D11_USAGE_STAGING;
  staging_description.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  if (FAILED(device_->CreateTexture2D(&staging_description, nullptr, &staging_)))
    return false;

  const double scale = std::min(
      {1.0, 960.0 / desktop_width_, 540.0 / desktop_height_});
  output_width_ = std::max(1, static_cast<int>(std::floor(desktop_width_ * scale)));
  output_height_ =
      std::max(1, static_cast<int>(std::floor(desktop_height_ * scale)));
  if (static_cast<uint64_t>(output_width_) * output_height_ >
      kMaximumFramePixels) {
    return false;
  }
  return true;
}

bool WindowsScreenCapture::Capture(Frame* frame) {
  const HRESULT com_status = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(com_status)) return false;
  std::lock_guard<std::mutex> lock(mutex_);
  if (!duplication_ || !device_ || !context_ || !staging_) {
    CoUninitialize();
    return false;
  }
  DXGI_OUTDUPL_FRAME_INFO frame_info = {};
  ComPtr<IDXGIResource> resource;
  const HRESULT acquire =
      duplication_->AcquireNextFrame(0, &frame_info, &resource);
  if (acquire == DXGI_ERROR_WAIT_TIMEOUT) {
    CoUninitialize();
    return true;
  }
  if (FAILED(acquire)) {
    CoUninitialize();
    return false;
  }
  bool success = false;
  do {
    ComPtr<ID3D11Texture2D> desktop_texture;
    if (FAILED(resource.As(&desktop_texture))) break;
    D3D11_TEXTURE2D_DESC source_description = {};
    desktop_texture->GetDesc(&source_description);
    if (source_description.Width != desktop_width_ ||
        source_description.Height != desktop_height_ ||
        source_description.Format != DXGI_FORMAT_B8G8R8A8_UNORM) {
      break;
    }
    context_->CopyResource(staging_.Get(), desktop_texture.Get());
    D3D11_MAPPED_SUBRESOURCE mapped = {};
    if (FAILED(context_->Map(staging_.Get(), 0, D3D11_MAP_READ, 0, &mapped)))
      break;
    std::vector<uint8_t> jpeg;
    const bool encoded = EncodeJpeg(
        GUID_WICPixelFormat32bppBGRA,
        static_cast<const uint8_t*>(mapped.pData), desktop_width_,
        desktop_height_, mapped.RowPitch, output_width_, output_height_, &jpeg);
    context_->Unmap(staging_.Get(), 0);
    if (!encoded) break;
    frame->jpeg = std::move(jpeg);
    frame->width = output_width_;
    frame->height = output_height_;
    success = true;
  } while (false);
  duplication_->ReleaseFrame();
  CoUninitialize();
  return success;
}

void WindowsScreenCapture::Stop() {
  std::lock_guard<std::mutex> lock(mutex_);
  StopLocked();
}

void WindowsScreenCapture::StopLocked() {
  duplication_.Reset();
  staging_.Reset();
  context_.Reset();
  device_.Reset();
  desktop_width_ = 0;
  desktop_height_ = 0;
  output_width_ = 0;
  output_height_ = 0;
}
