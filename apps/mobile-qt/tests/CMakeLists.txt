cmake_minimum_required(VERSION 3.21)
project(hal-c2-mobile-tests LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
find_package(Qt6 6.9 REQUIRED COMPONENTS Core Gui GuiPrivate Network Quick QuickControls2 Sql Test WebSockets)
enable_testing()
if(APPLE)
  enable_language(OBJCXX)
endif()

# The phone's own C++ against the desktop's shell (hal_c2_native) and the fake
# MC its scenarios run against.
set(_desktop "${CMAKE_CURRENT_SOURCE_DIR}/../../desktop-qt")
set(_harness "${_desktop}/tests/native/features")
include("${_desktop}/cmake/PlatformWindow.cmake")
include("${_desktop}/cmake/NativeShell.cmake")
hal_c2_add_native_library()
include(../cmake/Terminal.cmake)
include(../cmake/Scanner.cmake)
include(../cmake/Push.cmake)

# The pairing class by itself: nothing here needs the QML.
add_executable(tst_Pairing
  tst_Pairing.cpp
  PairableMc.h
  ../src/Pairing.cpp
  ../src/Pairing.h
  "${_harness}/FakeMc.cpp"
  "${_harness}/FakeMc.h"
)
target_include_directories(tst_Pairing PRIVATE ../src "${_harness}")
target_link_libraries(tst_Pairing PRIVATE hal_c2_native Qt6::Test)
add_test(NAME Pairing COMMAND tst_Pairing)
set_tests_properties(Pairing PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORMTHEME=")

# The scanner by itself: codes read off camera frames, and its use of a camera
# the test scripts (FakeCamera.h).
add_executable(tst_Scanner
  tst_Scanner.cpp
  FakeCamera.h
)
target_include_directories(tst_Scanner PRIVATE ../src)
target_link_libraries(tst_Scanner PRIVATE hal_c2_native Qt6::GuiPrivate Qt6::Test)
hal_c2_target_scanner(tst_Scanner)
add_test(NAME Scanner COMMAND tst_Scanner)
set_tests_properties(Scanner PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORMTHEME=")

# The push inbox's decryption by itself, against RFC 8291's example.
add_executable(tst_PushCrypto tst_PushCrypto.cpp)
target_link_libraries(tst_PushCrypto PRIVATE Qt6::Core Qt6::Test)
hal_c2_target_push_inbox(tst_PushCrypto)
add_test(NAME PushCrypto COMMAND tst_PushCrypto)

# The phone's scenarios of features/, against the same fake MC: the app as
# main.cpp builds it (MobileApp) with its real root, the desktop runner's
# Gherkin reader and harness, and one steps file per domain (features/*.cpp,
# picked up on the next build). The QML is read from the source tree.
file(GLOB _feature_sources CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/features/*.cpp" "${CMAKE_CURRENT_SOURCE_DIR}/features/*.h")
add_executable(tst_Features
  tst_Features.cpp
  PairableMc.h
  FakeCamera.h
  ${_feature_sources}
  ../src/MobileApp.cpp
  ../src/MobileApp.h
  ../src/Pairing.cpp
  ../src/Pairing.h
  "${_harness}/FakeMc.cpp"
  "${_harness}/FakeMc.h"
  "${_harness}/Harness.h"
  "${_harness}/Runner.cpp"
  "${_harness}/Runner.h"
  "${_desktop}/src/LocalFolderModel.cpp"
  "${_desktop}/src/ShellRuntime.cpp"
  "${_desktop}/src/StoragePaths.cpp"
  "${_desktop}/src/ThemeStore.cpp"
)
target_include_directories(tst_Features PRIVATE . ../src "${_harness}")
target_compile_definitions(tst_Features PRIVATE
  HAL_C2_APP_VERSION="test"
  HAL_C2_FEATURES_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../../features"
  HAL_C2_QML_DIR="${_desktop}/qml"
  HAL_C2_MOBILE_QML_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../qml"
)
target_link_libraries(tst_Features PRIVATE hal_c2_native Qt6::GuiPrivate Qt6::Quick Qt6::QuickControls2 Qt6::Test)
hal_c2_target_platform_window(tst_Features)
hal_c2_target_terminal(tst_Features)
hal_c2_target_scanner(tst_Features)
hal_c2_target_push(tst_Features)
add_test(NAME Features COMMAND tst_Features)
set_tests_properties(Features PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORMTHEME=")
# The screens' own decisions, against the desktop's fake HalC2.Shell. Qt's own
# runner first: one on PATH can be Qt 5's, which exits 1 saying nothing.
find_program(HAL_C2_QMLTESTRUNNER NAMES qmltestrunner6 qmltestrunner HINTS "${QT6_INSTALL_PREFIX}/${QT6_INSTALL_BINS}")
if(HAL_C2_QMLTESTRUNNER)
  add_test(NAME Qml COMMAND "${HAL_C2_QMLTESTRUNNER}" -input "${CMAKE_CURRENT_SOURCE_DIR}/qml"
    -import "${_desktop}/tests/imports" -import "${_desktop}/qml" -import "${CMAKE_CURRENT_SOURCE_DIR}/../qml")
  set_tests_properties(Qml PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORMTHEME=")
endif()
# Regressions the property tests (prop/) found, one tst_*Regression.cpp each,
# picked up on the next build.
include("${_desktop}/cmake/GlobTests.cmake")
hal_c2_add_glob_tests(PATTERN "tst_*Regression.cpp" LABEL regression
  INCLUDES ../src "${_harness}"
  LIBRARIES hal_c2_native
)
foreach(_target tst_ScannerRegression)
  if(TARGET ${_target})
    hal_c2_target_scanner(${_target})
  endif()
endforeach()
