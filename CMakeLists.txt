cmake_minimum_required(VERSION 3.28)

project(NativeMedalPort VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(NATIVE_PORT_BUILD_TESTS "Build native unit tests" ON)
option(NATIVE_PORT_BUILD_MACOS "Build the macOS backend and probes" ${APPLE})

find_package(nlohmann_json 3.11 CONFIG REQUIRED)

if(NATIVE_PORT_BUILD_TESTS)
  include(CTest)
  enable_testing()
endif()

add_subdirectory(native/core)

if(APPLE AND NATIVE_PORT_BUILD_MACOS)
  enable_language(OBJCXX)
  add_subdirectory(native/backends/macos)
endif()

if(NATIVE_PORT_BUILD_TESTS)
  add_subdirectory(native/tests)
endif()
