# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(bluedot_clicker LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "bluedot_clicker")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
# pp_ocr 需要 OpenCV：优先使用 tool/setup_opencv.ps1 下载到 third_party/opencv，
# 其次使用环境变量 OpenCV_DIR，最后交给 pp_ocr 的 CMake 报错提示。
if(NOT DEFINED OpenCV_DIR)
  if(DEFINED ENV{OpenCV_DIR})
    set(OpenCV_DIR "$ENV{OpenCV_DIR}" CACHE PATH "OpenCV build dir" FORCE)
  elseif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/opencv/opencv/build/OpenCVConfig.cmake")
    set(OpenCV_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/opencv/opencv/build" CACHE PATH "OpenCV build dir" FORCE)
  endif()
endif()
include(flutter/generated_plugins.cmake)

# pp_ocr 源码为不带 BOM 的 UTF-8 中文注释，MSVC 默认按系统代码页(936)解析
# 会把部分字节吞进注释/字符串，触发 C4819 与成片的语法错误；显式按 UTF-8 编译。
# 该第三方源码在 /W4 /WX 下还有 getenv 弃用等告警，这里只对本插件关闭告警即错误。
if(TARGET pp_ocr_plugin)
  target_compile_options(pp_ocr_plugin PRIVATE /utf-8 /wd4819 /WX-)
endif()


if(TARGET ${BINARY_NAME})
  target_compile_options(${BINARY_NAME} PRIVATE /wd4819)
  # 源码为不带 BOM 的 UTF-8，显式指定编码，避免 MSVC 按系统代码页(936)解析导致中文窗口标题乱码
  target_compile_options(${BINARY_NAME} PRIVATE /utf-8)
endif()


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# pp_ocr 通过 find_package 使用动态 OpenCV，DLL 不会由插件自动打包，
# 这里按构建配置复制对应的 opencv_world*.dll（Debug 用 *d.dll）。
if(DEFINED OpenCV_DIR)
  file(GLOB _OPENCV_RELEASE_DLLS "${OpenCV_DIR}/x64/vc*/bin/opencv_world[0-9]*[0-9].dll")
  file(GLOB _OPENCV_DEBUG_DLLS "${OpenCV_DIR}/x64/vc*/bin/opencv_world*d.dll")
  if(_OPENCV_RELEASE_DLLS)
    install(FILES ${_OPENCV_RELEASE_DLLS}
      DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
      COMPONENT Runtime
      CONFIGURATIONS Release;Profile)
  endif()
  if(_OPENCV_DEBUG_DLLS)
    install(FILES ${_OPENCV_DEBUG_DLLS}
      DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
      COMPONENT Runtime
      CONFIGURATIONS Debug)
  endif()
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
