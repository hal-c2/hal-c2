cmake_minimum_required(VERSION 3.21)

project(hal-c2-mobile VERSION 0.0.1 LANGUAGES CXX)

if(APPLE)
  enable_language(OBJCXX)
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.9 REQUIRED COMPONENTS Core Gui GuiPrivate Network Quick QuickControls2 Sql WebSockets)
qt_standard_project_setup(REQUIRES 6.9)
qt_policy(SET QTP0001 NEW)

# The phone client is the desktop's shell with another root: the same MC
# client and controllers (hal_c2_native) and the same bricks, laid out for a
# phone by HalC2.Mobile.
set(HAL_C2_DESKTOP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../desktop-qt")

# Where the QML lives on disk. A build for this machine loads it from there so
# edits hot-reload, as the desktop does; a device only has the compiled-in copies.
if(ANDROID OR IOS OR CMAKE_BUILD_TYPE STREQUAL "Release")
  set(_hal_c2_bricks_dir "")
  set(_hal_c2_mobile_dir "")
else()
  set(_hal_c2_bricks_dir "${HAL_C2_DESKTOP_DIR}/qml")
  set(_hal_c2_mobile_dir "${CMAKE_CURRENT_SOURCE_DIR}/qml")
endif()

qt_add_executable(hal-c2-mobile
  src/main.cpp
  src/MobileApp.cpp
  src/MobileApp.h
  src/Pairing.cpp
  src/Pairing.h
  "${HAL_C2_DESKTOP_DIR}/src/LocalFolderModel.cpp"
  "${HAL_C2_DESKTOP_DIR}/src/LocalFolderModel.h"
  "${HAL_C2_DESKTOP_DIR}/src/ScriptedRun.cpp"
  "${HAL_C2_DESKTOP_DIR}/src/ScriptedRun.h"
  "${HAL_C2_DESKTOP_DIR}/src/ShellRuntime.cpp"
  "${HAL_C2_DESKTOP_DIR}/src/ShellRuntime.h"
  "${HAL_C2_DESKTOP_DIR}/src/StoragePaths.cpp"
  "${HAL_C2_DESKTOP_DIR}/src/StoragePaths.h"
  "${HAL_C2_DESKTOP_DIR}/src/ThemeStore.cpp"
  "${HAL_C2_DESKTOP_DIR}/src/ThemeStore.h"
)

include("${HAL_C2_DESKTOP_DIR}/cmake/NativeShell.cmake")
hal_c2_add_native_library()
include("${HAL_C2_DESKTOP_DIR}/cmake/PlatformWindow.cmake")
hal_c2_target_platform_window(hal-c2-mobile)
include(cmake/Terminal.cmake)
hal_c2_target_terminal(hal-c2-mobile)
include(cmake/Scanner.cmake)
hal_c2_target_scanner(hal-c2-mobile)

target_compile_definitions(hal-c2-mobile PRIVATE
  HAL_C2_QML_SOURCE_DIR="${_hal_c2_bricks_dir}"
  HAL_C2_MOBILE_QML_SOURCE_DIR="${_hal_c2_mobile_dir}"
  HAL_C2_APP_VERSION="${PROJECT_VERSION}"
)

add_subdirectory("${HAL_C2_DESKTOP_DIR}/qml/HalC2/Bricks" bricks)
add_subdirectory(qml/HalC2/Mobile)

target_link_libraries(hal-c2-mobile PRIVATE
  Qt6::Core
  Qt6::Gui
  Qt6::GuiPrivate
  Qt6::Quick
  Qt6::QuickControls2
  Qt6::WebSockets
  hal_c2_native
  hal_c2_bricksplugin
  hal_c2_mobileplugin
)

if(ANDROID)
  include(cmake/AndroidPackage.cmake)
  hal_c2_android_package(hal-c2-mobile)
endif()
