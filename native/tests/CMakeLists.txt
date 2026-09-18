add_executable(native_port_core_tests core_tests.cpp)

target_link_libraries(native_port_core_tests PRIVATE native_port_core)
target_compile_features(native_port_core_tests PRIVATE cxx_std_20)

if(CMAKE_CXX_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
  target_compile_options(native_port_core_tests PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion)
endif()

add_test(NAME native_port_core_tests COMMAND native_port_core_tests)
