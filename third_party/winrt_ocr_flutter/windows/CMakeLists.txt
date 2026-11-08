# Mirrors the structure Flutter's own `flutter create --template=plugin
# --platforms=windows` generates, and the shape used by standard federated
# Windows plugins (camera_windows, file_selector_windows, etc.) so
# `add_subdirectory(...)` picks it up the same way once it's declared as a
# pub dependency. Built, linked, and registered successfully (debug and
# release) — see ../README.md "Verification status".
cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "winrt_ocr_flutter")
project(${PROJECT_NAME} LANGUAGES CXX)

# C++/WinRT's coroutine support (co_await/winrt::fire_and_forget) needs
# the standard C++20 <coroutine> header. Flutter's generated app-level
# CMakeLists.txt defines apply_standard_settings() to hard-pin every
# target (including plugins) to C++17 via
# `target_compile_features(${TARGET} PUBLIC cxx_std_17)` — under C++17,
# <winrt/base.h> falls back to the deprecated
# <experimental/coroutine> header, which this toolchain's STL rejects
# outright (MSVC's own STL1011 static-assert error). That function lives
# in the app's generated `windows/CMakeLists.txt`, not this plugin, so it
# can't be edited here — instead, request cxx_std_20 for this target
# specifically, after apply_standard_settings() has already run on it.
# CMake resolves a target's actual /std: flag as the highest standard any
# of its (possibly repeated) target_compile_features calls require, so
# this raises only winrt_ocr_flutter_plugin to C++20 without touching the
# app's own C++17 setting or any other plugin target.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(PLUGIN_NAME "winrt_ocr_flutter_plugin")

add_library(${PLUGIN_NAME} SHARED
  "winrt_ocr_flutter_plugin.cpp"
  "winrt_ocr_flutter_plugin_c_api.cpp"
)

apply_standard_settings(${PLUGIN_NAME})
target_compile_features(${PLUGIN_NAME} PUBLIC cxx_std_20)

# Sources may contain UTF-8 comments; force UTF-8 so MSVC on a non-UTF-8
# system code page does not mis-parse multi-byte characters.
if(MSVC)
  target_compile_options(${PLUGIN_NAME} PRIVATE /utf-8)
endif()

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)

target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")

target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

# windowsapp.lib is the umbrella import library for WinRT (Windows.*)
# namespaces, including Windows.Media.Ocr and Windows.Storage — required
# to link against `winrt::Windows::Media::Ocr::OcrEngine` etc.
target_link_libraries(${PLUGIN_NAME} PRIVATE windowsapp)

# List of absolute paths to libraries that should be bundled with the
# plugin. This list could contain prebuilt libraries, or libraries created
# by an external build triggered from this build file — empty here since
# this plugin only links against the Windows SDK's own windowsapp.lib
# (already present on every Windows 10+ machine), no third-party binaries
# to bundle.
set(winrt_ocr_flutter_bundled_libraries
  ""
  PARENT_SCOPE
)
