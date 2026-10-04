cmake_minimum_required(VERSION 3.21)
project(hal-c2-qt-runtime-tests LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_AUTOMOC ON)
find_package(Qt6 6.9 REQUIRED COMPONENTS Core Gui GuiPrivate Network Quick Test WebSockets)
enable_testing()
if(APPLE)
  enable_language(OBJCXX)
endif()
include(../../cmake/PlatformWindow.cmake)
# The bricks the layout tests load import Ghostty (the terminal drawer).
include(../../cmake/QmlGhostty.cmake)
include(../../cmake/NativeShell.cmake)
hal_c2_add_native_library()
if(APPLE)
  add_executable(tst_PlatformWindow tst_PlatformWindow.mm)
  target_include_directories(tst_PlatformWindow PRIVATE ../../src)
  target_link_libraries(tst_PlatformWindow PRIVATE Qt6::Quick Qt6::Test)
  hal_c2_target_platform_window(tst_PlatformWindow)
  add_test(NAME PlatformWindow COMMAND tst_PlatformWindow)
endif()
add_executable(tst_FolderExplorer tst_FolderExplorer.cpp ../../src/LocalFolderModel.cpp ../../src/ShellBridge.cpp ../../src/ThemeStore.cpp)
target_include_directories(tst_FolderExplorer PRIVATE ../../src)
target_compile_definitions(tst_FolderExplorer PRIVATE HAL_C2_TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../..")
target_link_libraries(tst_FolderExplorer PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick Qt6::Test)
add_test(NAME FolderExplorer COMMAND tst_FolderExplorer)
set_tests_properties(FolderExplorer PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORMTHEME=;QT_QUICK_BACKEND=software")
add_executable(tst_LocalFolderModel tst_LocalFolderModel.cpp ../../src/LocalFolderModel.cpp)
target_include_directories(tst_LocalFolderModel PRIVATE ../../src)
target_link_libraries(tst_LocalFolderModel PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Test)
add_test(NAME LocalFolderModel COMMAND tst_LocalFolderModel)
set_tests_properties(LocalFolderModel PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORMTHEME=")
add_executable(tst_StoragePaths tst_StoragePaths.cpp ../../src/StoragePaths.cpp)
target_include_directories(tst_StoragePaths PRIVATE ../../src)
target_link_libraries(tst_StoragePaths PRIVATE Qt6::Core Qt6::Test)
add_test(NAME StoragePaths COMMAND tst_StoragePaths)
add_executable(tst_BackendProcess tst_BackendProcess.cpp ../../src/BackendProcess.cpp)
target_include_directories(tst_BackendProcess PRIVATE ../../src)
target_link_libraries(tst_BackendProcess PRIVATE Qt6::Core Qt6::Test)
add_test(NAME BackendProcess COMMAND tst_BackendProcess)
# The native scenarios of features/, against a fake MC: the harness, the fake
# MC, and one steps file per domain (features/*.cpp, picked up on the next build).
file(GLOB _feature_sources CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/features/*.cpp" "${CMAKE_CURRENT_SOURCE_DIR}/features/*.h")
# Windows are closed as the user closes them, through their ShellRuntime.
add_executable(tst_Features tst_Features.cpp ${_feature_sources} ../../src/ThemeStore.cpp ../../src/ShellRuntime.cpp ../../src/ShellWindows.cpp ../../src/SingleInstance.cpp)
target_compile_definitions(tst_Features PRIVATE
  HAL_C2_APP_VERSION="test"
  HAL_C2_FEATURES_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../../../features"
  HAL_C2_QML_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../qml"
  HAL_C2_DEVICE_FIXTURE="${CMAKE_CURRENT_SOURCE_DIR}/features/fixtures/device-72x160.h264"
)
target_link_libraries(tst_Features PRIVATE hal_c2_native Qt6::GuiPrivate Qt6::Quick Qt6::Test)
hal_c2_target_platform_window(tst_Features)
# The terminal bricks draw with qml-ghostty's Terminal.
target_link_libraries(tst_Features PRIVATE qmlghosttyplugin)
add_test(NAME Features COMMAND tst_Features)
set_tests_properties(Features PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORMTHEME=")
add_executable(tst_LocalTranscriber tst_LocalTranscriber.cpp ../../src/LocalTranscriber.cpp)
target_include_directories(tst_LocalTranscriber PRIVATE ../../src)
target_link_libraries(tst_LocalTranscriber PRIVATE Qt6::Core Qt6::Qml Qt6::Test)
add_test(NAME LocalTranscriber COMMAND tst_LocalTranscriber)
foreach(test_name IN ITEMS ShellRuntime ShellExamples)
  add_executable(tst_${test_name}
    tst_${test_name}.cpp
    ../../src/ShellRuntime.cpp
    ../../src/ShellBridge.cpp
    ../../src/ThemeStore.cpp
    # Composer.qml's rich text; it registers itself, as in the app.
    ../../src/native/ComposerHighlighter.cpp
  )
  target_include_directories(tst_${test_name} PRIVATE ../../src ../../src/native)
  target_compile_definitions(tst_${test_name} PRIVATE
    HAL_C2_APP_VERSION="test"
    HAL_C2_TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../.."
  )
  target_link_libraries(tst_${test_name} PRIVATE
    Qt6::Core Qt6::Gui Qt6::GuiPrivate Qt6::Quick Qt6::Test qmlghosttyplugin
  )
  hal_c2_target_platform_window(tst_${test_name})
  add_test(NAME ${test_name} COMMAND tst_${test_name})
  # The examples are copied over one shell.qml in turn, and a copy keeps its
  # source's timestamp: the QML disk cache would hand back the previous one.
  set_tests_properties(${test_name} PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORMTHEME=;QML_DISABLE_DISK_CACHE=1")
endforeach()

target_sources(tst_ShellExamples PRIVATE ../../src/LocalFolderModel.cpp)

if(UNIX AND NOT APPLE)
  find_package(Qt6 6.9 REQUIRED COMPONENTS DBus)
  find_program(HAL_C2_DBUS_RUN_SESSION dbus-run-session REQUIRED)
  add_executable(tst_NativeNotifications tst_NativeNotifications.cpp ../../src/NativeNotifications.cpp)
  target_include_directories(tst_NativeNotifications PRIVATE ../../src)
  target_compile_definitions(tst_NativeNotifications PRIVATE HAL_C2_HAS_DBUS)
  target_link_libraries(tst_NativeNotifications PRIVATE Qt6::Core Qt6::Test Qt6::DBus)
  add_test(NAME NativeNotifications COMMAND "${HAL_C2_DBUS_RUN_SESSION}" -- $<TARGET_FILE:tst_NativeNotifications>)
endif()
# How the shell resolves its theme: the lookup order, the halves, the fallbacks.
add_executable(tst_ThemeResolution tst_ThemeResolution.cpp)
target_link_libraries(tst_ThemeResolution PRIVATE hal_c2_native Qt6::Test)
add_test(NAME ThemeResolution COMMAND tst_ThemeResolution)
set_tests_properties(ThemeResolution PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORMTHEME=")
