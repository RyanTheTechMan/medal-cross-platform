if(APPLE)
  add_executable(native_medal_recorder MACOSX_BUNDLE main.cpp)
  set_target_properties(native_medal_recorder PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
    MACOSX_BUNDLE_BUNDLE_NAME "Native Medal Recorder"
    MACOSX_BUNDLE_GUI_IDENTIFIER "com.squirrel.medal.medal.recorder"
  )
  set_property(TARGET native_medal_recorder APPEND PROPERTY
    LINK_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in")
else()
  add_executable(native_medal_recorder main.cpp)
endif()

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
  if(NATIVE_PORT_MACOS_DEVELOPMENT_SIGNING_IDENTITY)
    add_custom_command(TARGET native_medal_recorder POST_BUILD
      COMMAND /usr/bin/codesign --force --options runtime --timestamp=none
              --sign "${NATIVE_PORT_MACOS_DEVELOPMENT_SIGNING_IDENTITY}"
              "$<TARGET_BUNDLE_DIR:native_medal_recorder>"
      COMMAND /usr/bin/codesign --verify --strict --verbose=2
              "$<TARGET_BUNDLE_DIR:native_medal_recorder>"
      COMMENT "Signing the stable Native Medal Recorder development identity"
      VERBATIM
    )
  else()
    message(WARNING
      "native_medal_recorder will be unsigned. It must not be used for TCC testing until "
      "NATIVE_PORT_MACOS_DEVELOPMENT_SIGNING_IDENTITY is configured and the bundle is rebuilt.")
  endif()
endif()

target_compile_features(native_medal_recorder PRIVATE cxx_std_20)
target_compile_definitions(native_medal_recorder PRIVATE BOOST_ERROR_CODE_HEADER_ONLY)

if(CMAKE_CXX_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
  target_compile_options(native_medal_recorder PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion)
endif()
