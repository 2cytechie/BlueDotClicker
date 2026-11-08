#ifndef PACKAGES_WINRT_OCR_FLUTTER_WINDOWS_INCLUDE_WINRT_OCR_FLUTTER_WINRT_OCR_FLUTTER_PLUGIN_C_API_H_
#define PACKAGES_WINRT_OCR_FLUTTER_WINDOWS_INCLUDE_WINRT_OCR_FLUTTER_WINRT_OCR_FLUTTER_PLUGIN_C_API_H_

#include <flutter_plugin_registrar.h>

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FLUTTER_PLUGIN_EXPORT __declspec(dllimport)
#endif

#if defined(__cplusplus)
extern "C" {
#endif

// Registered by Flutter's generated_plugin_registrant.cc exactly like any
// other federated Windows plugin — no manual registration step needed
// once this package is a declared pub dependency.
FLUTTER_PLUGIN_EXPORT void WinrtOcrFlutterPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#if defined(__cplusplus)
}  // extern "C"
#endif

#endif  // PACKAGES_WINRT_OCR_FLUTTER_WINDOWS_INCLUDE_WINRT_OCR_FLUTTER_WINRT_OCR_FLUTTER_PLUGIN_C_API_H_
