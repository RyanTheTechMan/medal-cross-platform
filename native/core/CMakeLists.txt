add_library(native_port_core STATIC
  src/audio_routing.cpp
  src/capture_geometry.cpp
  src/capture_settings.cpp
  src/clip_action.cpp
  src/json_rpc.cpp
  src/replay_store.cpp
  src/settings_store.cpp
)

target_include_directories(native_port_core
  PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_link_libraries(native_port_core
  PUBLIC
    nlohmann_json::nlohmann_json
)

target_compile_features(native_port_core PUBLIC cxx_std_20)

if(CMAKE_CXX_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
  target_compile_options(native_port_core PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion)
endif()
