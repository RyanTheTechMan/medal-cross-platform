find_library(APPKIT_FRAMEWORK AppKit REQUIRED)
find_library(AUDIOTOOLBOX_FRAMEWORK AudioToolbox REQUIRED)
find_library(AVFOUNDATION_FRAMEWORK AVFoundation REQUIRED)
find_library(COREAUDIO_FRAMEWORK CoreAudio REQUIRED)
find_library(COREMEDIA_FRAMEWORK CoreMedia REQUIRED)
find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
find_library(IMAGEIO_FRAMEWORK ImageIO REQUIRED)
find_library(METAL_FRAMEWORK Metal REQUIRED)
find_library(QUARTZCORE_FRAMEWORK QuartzCore REQUIRED)
find_library(SCREENCAPTUREKIT_FRAMEWORK ScreenCaptureKit REQUIRED)
find_library(VIDEOTOOLBOX_FRAMEWORK VideoToolbox REQUIRED)
find_library(CARBON_FRAMEWORK Carbon REQUIRED)

find_library(COREVIDEO_FRAMEWORK CoreVideo REQUIRED)

add_library(native_port_macos_adapter STATIC
  audio_encoder.mm
  mp4_writer.mm
  platform_adapter.mm
  screen_capture_session.mm
)
target_include_directories(native_port_macos_adapter PUBLIC ${CMAKE_SOURCE_DIR}/native/core/include)
target_link_libraries(native_port_macos_adapter PUBLIC
  nlohmann_json::nlohmann_json
  ${APPKIT_FRAMEWORK}
  ${AUDIOTOOLBOX_FRAMEWORK}
  ${AVFOUNDATION_FRAMEWORK}
  ${CARBON_FRAMEWORK}
  ${COREAUDIO_FRAMEWORK}
  ${COREMEDIA_FRAMEWORK}
  ${COREVIDEO_FRAMEWORK}
  ${METAL_FRAMEWORK}
  ${QUARTZCORE_FRAMEWORK}
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

add_executable(native_port_macos_encoder_probe encoder_probe.mm)
target_link_libraries(native_port_macos_encoder_probe PRIVATE
  nlohmann_json::nlohmann_json
  ${COREMEDIA_FRAMEWORK}
  ${COREVIDEO_FRAMEWORK}
  ${FOUNDATION_FRAMEWORK}
  ${IMAGEIO_FRAMEWORK}
  ${VIDEOTOOLBOX_FRAMEWORK}
)
target_compile_features(native_port_macos_encoder_probe PRIVATE cxx_std_20)
target_compile_options(native_port_macos_encoder_probe PRIVATE -fobjc-arc -Wall -Wextra -Wpedantic)

add_executable(native_port_macos_audio_encoder_probe
  audio_encoder_probe.mm
  audio_encoder.mm
)
target_include_directories(native_port_macos_audio_encoder_probe PRIVATE ${CMAKE_SOURCE_DIR}/native/core/include)
target_link_libraries(native_port_macos_audio_encoder_probe PRIVATE
  native_port_core
  nlohmann_json::nlohmann_json
  ${AUDIOTOOLBOX_FRAMEWORK}
  ${COREMEDIA_FRAMEWORK}
  ${FOUNDATION_FRAMEWORK}
)
target_compile_features(native_port_macos_audio_encoder_probe PRIVATE cxx_std_20)
target_compile_options(native_port_macos_audio_encoder_probe PRIVATE -fobjc-arc -Wall -Wextra -Wpedantic)

add_executable(native_port_macos_mp4_writer_probe mp4_writer_probe.mm)
target_include_directories(native_port_macos_mp4_writer_probe PRIVATE ${CMAKE_SOURCE_DIR}/native/core/include)
target_link_libraries(native_port_macos_mp4_writer_probe PRIVATE
  native_port_macos_adapter
  native_port_core
  nlohmann_json::nlohmann_json
  ${AUDIOTOOLBOX_FRAMEWORK}
  ${AVFOUNDATION_FRAMEWORK}
  ${COREMEDIA_FRAMEWORK}
  ${COREVIDEO_FRAMEWORK}
  ${FOUNDATION_FRAMEWORK}
  ${VIDEOTOOLBOX_FRAMEWORK}
)
target_compile_features(native_port_macos_mp4_writer_probe PRIVATE cxx_std_20)
target_compile_options(native_port_macos_mp4_writer_probe PRIVATE -fobjc-arc -Wall -Wextra -Wpedantic)

add_executable(native_port_macos_hotkey_event_pump_probe hotkey_event_pump_probe.mm)
target_include_directories(native_port_macos_hotkey_event_pump_probe PRIVATE
  ${CMAKE_SOURCE_DIR}/native/core/include
)
target_link_libraries(native_port_macos_hotkey_event_pump_probe PRIVATE
  native_port_macos_adapter
  native_port_core
  nlohmann_json::nlohmann_json
  ${APPKIT_FRAMEWORK}
  ${CARBON_FRAMEWORK}
)
target_compile_features(native_port_macos_hotkey_event_pump_probe PRIVATE cxx_std_20)
target_compile_options(native_port_macos_hotkey_event_pump_probe PRIVATE
  -fobjc-arc -Wall -Wextra -Wpedantic
)

add_executable(native_port_macos_avfoundation_file_probe avfoundation_file_probe.mm)
target_link_libraries(native_port_macos_avfoundation_file_probe PRIVATE
  nlohmann_json::nlohmann_json
  ${AUDIOTOOLBOX_FRAMEWORK}
  ${AVFOUNDATION_FRAMEWORK}
  ${COREMEDIA_FRAMEWORK}
  ${COREVIDEO_FRAMEWORK}
  ${FOUNDATION_FRAMEWORK}
)
target_compile_features(native_port_macos_avfoundation_file_probe PRIVATE cxx_std_20)
target_compile_options(native_port_macos_avfoundation_file_probe PRIVATE
  -fobjc-arc -Wall -Wextra -Wpedantic
)

if(BUILD_TESTING)
  add_test(NAME native_port_macos_api_probe COMMAND native_port_macos_api_probe)
  add_test(NAME native_port_macos_encoder_probe COMMAND native_port_macos_encoder_probe)
  add_test(NAME native_port_macos_audio_encoder_probe COMMAND native_port_macos_audio_encoder_probe)
  add_test(NAME native_port_macos_mp4_writer_probe COMMAND native_port_macos_mp4_writer_probe)
  add_test(NAME native_port_macos_hotkey_event_pump_probe COMMAND native_port_macos_hotkey_event_pump_probe)
endif()
