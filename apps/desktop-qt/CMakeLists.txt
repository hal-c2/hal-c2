cmake_minimum_required(VERSION 3.21)

project(hal-c2-qt VERSION 0.0.1 LANGUAGES CXX)

if(APPLE)
  enable_language(OBJCXX)
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.9 REQUIRED COMPONENTS Core Gui GuiPrivate Quick WebEngineQuick WebChannel)
qt_standard_project_setup(REQUIRES 6.9)
qt_policy(SET QTP0001 NEW)

# Where the QML bricks live on disk. Non-release builds load them from here so
# edits hot-reload without a rebuild; release builds only use the compiled-in
# copies. HAL_C2_QML_SOURCE_DIR="" disables disk loading for any build type.
if(NOT DEFINED HAL_C2_QML_SOURCE_DIR)
  set(HAL_C2_QML_SOURCE_DIR "$<IF:$<CONFIG:Release>,,${CMAKE_CURRENT_SOURCE_DIR}/qml>")
endif()

# The Node desktop host entry. In-repo builds point at the TypeScript source.
# Release builds resolve an installed path relative to the executable.
if(NOT DEFINED HAL_C2_HOST_ENTRY)
  if(APPLE)
    set(_hal_c2_installed_host "../Resources/hal-c2/host/main.ts")
  else()
    set(_hal_c2_installed_host "../share/hal-c2/host/main.ts")
  endif()
  set(HAL_C2_HOST_ENTRY "$<IF:$<CONFIG:Release>,${_hal_c2_installed_host},${CMAKE_CURRENT_SOURCE_DIR}/host/main.ts>")
endif()

# Release packages carry the same Node executable that installed their native
# dependencies. Development builds keep using the command from PATH.
if(NOT DEFINED HAL_C2_NODE_ENTRY)
  if(APPLE)
    set(_hal_c2_installed_node "../Resources/hal-c2/bin/node")
  elseif(WIN32)
    set(_hal_c2_installed_node "../share/hal-c2/bin/node.exe")
  else()
    set(_hal_c2_installed_node "../share/hal-c2/bin/node")
  endif()
  set(HAL_C2_NODE_ENTRY "$<IF:$<CONFIG:Release>,${_hal_c2_installed_node},node>")
endif()

# qwebchannel.js is the browser half of Qt WebChannel. Qt installs it as data
# (share/qt6/webchannel); bundling it makes the injected script independent of
# whether the runtime Qt exposes it as a qrc resource.
get_filename_component(_qt_prefix "${QT6_INSTALL_PREFIX}" ABSOLUTE)
find_file(HAL_C2_QWEBCHANNEL_JS qwebchannel.js
  HINTS
    "${_qt_prefix}/${QT6_INSTALL_DATA}/webchannel"
    "${_qt_prefix}/share/qt6/webchannel"
    "${_qt_prefix}/share/qt/webchannel"
    "${_qt_prefix}/../qtwebchannel/share/qt6/webchannel"
)

qt_add_executable(hal-c2-qt
  src/main.cpp
  src/LocalFolderModel.cpp
  src/LocalFolderModel.h
  src/LocalTranscriber.cpp
  src/LocalTranscriber.h
  src/NativeNotifications.cpp
  src/NativeNotifications.h
  src/BackendProcess.cpp
  src/BackendProcess.h
  src/ShellBridge.cpp
  src/ShellBridge.h
  src/ShellRuntime.cpp
  src/ShellRuntime.h
  src/StoragePaths.cpp
  src/StoragePaths.h
  src/ThemeStore.cpp
  src/ThemeStore.h
  src/WebProfile.cpp
  src/WebProfile.h
  src/PlatformWindow.h
)

if(UNIX AND NOT APPLE)
  find_package(Qt6 6.9 REQUIRED COMPONENTS DBus)
  target_link_libraries(hal-c2-qt PRIVATE Qt6::DBus)
  target_compile_definitions(hal-c2-qt PRIVATE HAL_C2_HAS_DBUS)
endif()

if(HAL_C2_QWEBCHANNEL_JS)
  set_source_files_properties("${HAL_C2_QWEBCHANNEL_JS}" PROPERTIES QT_RESOURCE_ALIAS "qwebchannel.js")
  qt_add_resources(hal-c2-qt "hal_c2_webchannel" PREFIX "/hal-c2" FILES "${HAL_C2_QWEBCHANNEL_JS}")
  target_compile_definitions(hal-c2-qt PRIVATE HAL_C2_WEBCHANNEL_SCRIPT_URL="qrc:/hal-c2/qwebchannel.js")
else()
  message(STATUS "qwebchannel.js not found next to Qt; relying on qrc:///qtwebchannel/qwebchannel.js at runtime")
  target_compile_definitions(hal-c2-qt PRIVATE HAL_C2_WEBCHANNEL_SCRIPT_URL="qrc:///qtwebchannel/qwebchannel.js")
endif()

target_compile_definitions(hal-c2-qt PRIVATE
  HAL_C2_QML_SOURCE_DIR="${HAL_C2_QML_SOURCE_DIR}"
  HAL_C2_HOST_ENTRY="${HAL_C2_HOST_ENTRY}"
  HAL_C2_NODE_ENTRY="${HAL_C2_NODE_ENTRY}"
  HAL_C2_APP_VERSION="${PROJECT_VERSION}"
)

include(cmake/PlatformWindow.cmake)
hal_c2_target_platform_window(hal-c2-qt)

add_subdirectory(qml/HalC2/Bricks)

target_link_libraries(hal-c2-qt PRIVATE
  Qt6::Core
  Qt6::Gui
  Qt6::GuiPrivate
  Qt6::Quick
  Qt6::WebEngineQuick
  Qt6::WebChannel
  hal_c2_bricksplugin
)

set_target_properties(hal-c2-qt PROPERTIES
  MACOSX_BUNDLE TRUE
  MACOSX_BUNDLE_GUI_IDENTIFIER "io.github.halc2.desktop-qt"
  MACOSX_BUNDLE_BUNDLE_NAME "HAL-C2"
  WIN32_EXECUTABLE TRUE
)

install(TARGETS hal-c2-qt
  BUNDLE DESTINATION .
  RUNTIME DESTINATION bin
)
