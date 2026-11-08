#include "include/winrt_ocr_flutter/winrt_ocr_flutter_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "winrt_ocr_flutter_plugin.h"

void WinrtOcrFlutterPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  winrt_ocr_flutter::WinrtOcrFlutterPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
