add_executable(native_medal_recorder main.cpp)

target_include_directories(native_medal_recorder PRIVATE
  ${Boost_INCLUDE_DIRS}
  ${CMAKE_SOURCE_DIR}/native/core/include
)

target_link_libraries(native_medal_recorder PRIVATE
  native_port_core
  Threads::Threads
)

if(APPLE)
  target_link_libraries(native_medal_recorder PRIVATE native_port_macos_adapter)
endif()

target_compile_features(native_medal_recorder PRIVATE cxx_std_20)
target_compile_definitions(native_medal_recorder PRIVATE BOOST_ERROR_CODE_HEADER_ONLY)

if(CMAKE_CXX_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
  target_compile_options(native_medal_recorder PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion)
endif()
