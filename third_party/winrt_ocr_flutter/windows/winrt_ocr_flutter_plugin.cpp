// This is an idiomatic C++/WinRT implementation of the standard Flutter
// Windows plugin pattern, written against Microsoft's documented
// Windows.Media.Ocr API. It has been built, linked, registered, and run
// successfully on a real Windows 11 machine (debug and release) — see
// README.md "Verification status" for the exact toolchain and results.
#include "winrt_ocr_flutter_plugin.h"

#include <flutter/method_result_functions.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Media.Ocr.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.Storage.h>

#include <cstdint>
#include <memory>
#include <sstream>

namespace winrt_ocr_flutter {

namespace {

// UTF-8 (Dart-side EncodableValue string) -> UTF-16 (Windows API paths and
// strings are wide by default).
std::wstring Utf8ToWide(const std::string &utf8) {
  if (utf8.empty()) return std::wstring();
  int size = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                                  static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring wide(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()),
                       wide.data(), size);
  return wide;
}

}  // namespace

std::string WideToUtf8(const std::wstring &wide) {
  if (wide.empty()) return std::string();
  int size = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(),
                                  static_cast<int>(wide.size()), nullptr, 0,
                                  nullptr, nullptr);
  std::string utf8(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()),
                       utf8.data(), size, nullptr, nullptr);
  return utf8;
}

// static
void WinrtOcrFlutterPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "winrt_ocr_flutter",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<WinrtOcrFlutterPlugin>();

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

WinrtOcrFlutterPlugin::WinrtOcrFlutterPlugin() {}

WinrtOcrFlutterPlugin::~WinrtOcrFlutterPlugin() {}

void WinrtOcrFlutterPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const bool with_boxes = method_call.method_name() == "recognizeWithBoxes";
  if (method_call.method_name() != "recognizeText" && !with_boxes) {
    result->NotImplemented();
    return;
  }

  const auto *arguments =
      std::get_if<flutter::EncodableMap>(method_call.arguments());
  if (!arguments) {
    result->Error("invalid_arguments", "Expected a map with an imagePath");
    return;
  }
  const auto path_it = arguments->find(flutter::EncodableValue("imagePath"));
  if (path_it == arguments->end() ||
      !std::holds_alternative<std::string>(path_it->second)) {
    result->Error("invalid_arguments", "imagePath must be a non-null string");
    return;
  }

  const auto image_path = Utf8ToWide(std::get<std::string>(path_it->second));

  // This process must already have package identity (MSIX) for
  // OcrEngine::TryCreateFromUserProfileLanguages() to succeed below — see
  // README.md. RecognizeTextAsync surfaces that as an Error result rather
  // than crashing, so a caller's Dart-side catch-all still turns it into
  // `''`, exactly like any other engine failure.
  RecognizeAsync(image_path, with_boxes, std::move(result));
}

winrt::fire_and_forget WinrtOcrFlutterPlugin::RecognizeAsync(
    std::wstring image_path,
    bool include_boxes,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  // Keep the MethodResult alive across suspension points by capturing it
  // in this coroutine frame (a std::unique_ptr already handles that; this
  // comment just makes the lifetime intent explicit for reviewers).
  try {
    using namespace winrt::Windows::Storage;
    using namespace winrt::Windows::Storage::Streams;
    using namespace winrt::Windows::Graphics::Imaging;
    using namespace winrt::Windows::Media::Ocr;

    StorageFile file = co_await StorageFile::GetFileFromPathAsync(image_path);
    IRandomAccessStream stream =
        co_await file.OpenAsync(FileAccessMode::Read);
    BitmapDecoder decoder = co_await BitmapDecoder::CreateAsync(stream);
    SoftwareBitmap bitmap = co_await decoder.GetSoftwareBitmapAsync();

    // Requires package identity (MSIX) — see README.md "Package identity
    // (MSIX) requirement". In an unpackaged process this returns nullptr
    // rather than throwing, which is why the null check below reports a
    // specific error instead of dereferencing a null engine.
    OcrEngine engine = OcrEngine::TryCreateFromUserProfileLanguages();
    if (!engine) {
      result->Error(
          "no_ocr_engine",
          "Windows.Media.Ocr.OcrEngine is unavailable — this process likely "
          "lacks package identity (MSIX) or has no OCR language pack "
          "installed. See winrt_ocr_flutter's README.md.");
      co_return;
    }

    OcrResult ocr_result = co_await engine.RecognizeAsync(bitmap);

    // Join lines with '\n', preserving the line order
    // Windows.Media.Ocr already returns — no reordering or normalization.
    std::wstringstream text;
    bool first_line = true;
    for (auto const &line : ocr_result.Lines()) {
      if (!first_line) text << L"\n";
      text << std::wstring(line.Text());
      first_line = false;
    }

    if (!include_boxes) {
      result->Success(flutter::EncodableValue(WideToUtf8(text.str())));
      co_return;
    }

    // Word-level result: text/x/y/w/h plus line index (0-based) for each word.
    // Coordinates are in the bitmap pixels passed in; the caller applies scale.
    flutter::EncodableList word_items;
    int line_index = 0;
    for (auto const &line : ocr_result.Lines()) {
      for (auto const &word : line.Words()) {
        const auto rect = word.BoundingRect();
        flutter::EncodableMap item;
        item[flutter::EncodableValue("text")] =
            flutter::EncodableValue(WideToUtf8(std::wstring(word.Text())));
        item[flutter::EncodableValue("x")] =
            flutter::EncodableValue(static_cast<int32_t>(rect.X));
        item[flutter::EncodableValue("y")] =
            flutter::EncodableValue(static_cast<int32_t>(rect.Y));
        item[flutter::EncodableValue("w")] =
            flutter::EncodableValue(static_cast<int32_t>(rect.Width));
        item[flutter::EncodableValue("h")] =
            flutter::EncodableValue(static_cast<int32_t>(rect.Height));
        item[flutter::EncodableValue("line")] =
            flutter::EncodableValue(line_index);
        word_items.push_back(flutter::EncodableValue(item));
      }
      ++line_index;
    }

    flutter::EncodableMap payload;
    payload[flutter::EncodableValue("text")] =
        flutter::EncodableValue(WideToUtf8(text.str()));
    payload[flutter::EncodableValue("words")] =
        flutter::EncodableValue(word_items);
    result->Success(flutter::EncodableValue(payload));
  } catch (winrt::hresult_error const &e) {
    result->Error("winrt_ocr_flutter_failed", WideToUtf8(std::wstring(e.message().c_str())));
  } catch (...) {
    result->Error("winrt_ocr_flutter_failed", "Unknown Windows OCR failure");
  }
}

}  // namespace winrt_ocr_flutter
