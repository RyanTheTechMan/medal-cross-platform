find_library(APPKIT_FRAMEWORK AppKit REQUIRED)
find_library(AUDIOTOOLBOX_FRAMEWORK AudioToolbox REQUIRED)
find_library(AVFOUNDATION_FRAMEWORK AVFoundation REQUIRED)
find_library(COREAUDIO_FRAMEWORK CoreAudio REQUIRED)
find_library(COREMEDIA_FRAMEWORK CoreMedia REQUIRED)
find_library(METAL_FRAMEWORK Metal REQUIRED)
find_library(SCREENCAPTUREKIT_FRAMEWORK ScreenCaptureKit REQUIRED)
find_library(VIDEOTOOLBOX_FRAMEWORK VideoToolbox REQUIRED)
find_library(CARBON_FRAMEWORK Carbon REQUIRED)

find_library(COREVIDEO_FRAMEWORK CoreVideo REQUIRED)

add_library(native_port_macos_adapter STATIC
  platform_adapter.mm
  screen_capture_session.mm
)
target_include_directories(native_port_macos_adapter PUBLIC ${CMAKE_SOURCE_DIR}/native/core/include)
target_link_libraries(native_port_macos_adapter PUBLIC
  nlohmann_json::nlohmann_json
  ${APPKIT_FRAMEWORK}
  ${AVFOUNDATION_FRAMEWORK}
  ${COREAUDIO_FRAMEWORK}
  ${COREMEDIA_FRAMEWORK}
  ${COREVIDEO_FRAMEWORK}
  ${SCREENCAPTUREKIT_FRAMEWORK}
  ${VIDEOTOOLBOX_FRAMEWORK}
)
target_compile_features(native_port_macos_adapter PUBLIC cxx_std_20)
target_compile_options(native_port_macos_adapter PRIVATE -fobjc-arc -Wall -Wextra -Wpedantic)

add_executable(native_port_macos_api_probe api_surface_probe.mm)

target_link_libraries(native_port_macos_api_probe PRIVATE
  native_port_core
  ${APPKIT_FRAMEWORK}
  ${AUDIOTOOLBOX_FRAMEWORK}
  ${AVFOUNDATION_FRAMEWORK}
  ${COREAUDIO_FRAMEWORK}
  ${COREMEDIA_FRAMEWORK}
  ${METAL_FRAMEWORK}
  ${SCREENCAPTUREKIT_FRAMEWORK}
  ${VIDEOTOOLBOX_FRAMEWORK}
  ${CARBON_FRAMEWORK}
)

target_compile_features(native_port_macos_api_probe PRIVATE cxx_std_20)
target_compile_options(native_port_macos_api_probe PRIVATE -fobjc-arc -Wall -Wextra -Wpedantic)

if(BUILD_TESTING)
  add_test(NAME native_port_macos_api_probe COMMAND native_port_macos_api_probe)
endif()
