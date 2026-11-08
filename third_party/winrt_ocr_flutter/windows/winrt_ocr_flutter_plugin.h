#ifndef PACKAGES_WINRT_OCR_FLUTTER_WINDOWS_WINRT_OCR_FLUTTER_PLUGIN_H_
#define PACKAGES_WINRT_OCR_FLUTTER_WINDOWS_WINRT_OCR_FLUTTER_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <winrt/base.h>

#include <memory>
#include <string>

namespace winrt_ocr_flutter {

// Implements on-device Windows OCR via Windows.Media.Ocr (C++/WinRT). See
// this package's README.md for the package-identity (MSIX) requirement
// this class depends on at runtime — it compiles and registers fine in an
// unpackaged build, but `RecognizeTextAsync` will report a failure result
// (never crash the process) if the process has no package identity when
// `winrt::Windows::Media::Ocr::OcrEngine::TryCreateFromUserProfileLanguages()`
// is called, per Microsoft's documented restriction on this WinRT API.
class WinrtOcrFlutterPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  WinrtOcrFlutterPlugin();

  ~WinrtOcrFlutterPlugin() override;

  // Disallow copy and assign.
  WinrtOcrFlutterPlugin(const WinrtOcrFlutterPlugin &) = delete;
  WinrtOcrFlutterPlugin &operator=(const WinrtOcrFlutterPlugin &) = delete;

 private:
  // Handles the `recognizeText` method call — resolves/rejects
  // asynchronously so the OCR call never blocks the platform thread.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Does the actual async OCR work for `HandleMethodCall`'s "recognizeText"
  // and "recognizeWithBoxes" branches. A coroutine (winrt::fire_and_forget)
  // so the WinRT async calls (StorageFile/BitmapDecoder/OcrEngine) can be
  // awaited without blocking Flutter's platform thread; `result` is resolved
  // exactly once on every path. When `include_boxes` is true the success
  // value is a map {text, words:[{text,x,y,w,h,line}]} instead of a string.
  winrt::fire_and_forget RecognizeAsync(
      std::wstring image_path,
      bool include_boxes,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

// Converts a UTF-16 (wide) string to UTF-8, for handing OCR'd text back to
// Dart across the method channel (which encodes EncodableValue strings as
// UTF-8).
std::string WideToUtf8(const std::wstring &wide);

}  // namespace winrt_ocr_flutter

#endif  // PACKAGES_WINRT_OCR_FLUTTER_WINDOWS_WINRT_OCR_FLUTTER_PLUGIN_H_
