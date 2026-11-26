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

# The phone's own C++ against the shared shell (hal_c2_native) and the fake
# MC its scenarios run against (native/features, desktop-qt's harness).
set(_harness "${CMAKE_CURRENT_SOURCE_DIR}/native/features")
include(../cmake/PlatformWindow.cmake)
include(../cmake/NativeShell.cmake)
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
  ../src/Maintenance.cpp
  ../src/Maintenance.h
  ../src/MobileTerminal.cpp
  ../src/MobileTerminal.h
  ../src/Pairing.cpp
  ../src/Pairing.h
  ../src/Resume.cpp
  ../src/Resume.h
  ../src/TurnAgents.cpp
  ../src/TurnAgents.h
  "${_harness}/FakeMc.cpp"
  "${_harness}/FakeMc.h"
  "${_harness}/FakeFiles.cpp"
  "${_harness}/FakeFiles.h"
  "${_harness}/MediaFixtures.h"
  "${_harness}/Harness.h"
  "${_harness}/Runner.cpp"
  "${_harness}/Runner.h"
  ../src/LocalFolderModel.cpp
  ../src/ShellRuntime.cpp
  ../src/StoragePaths.cpp
  ../src/ThemeStore.cpp
)
target_include_directories(tst_Features PRIVATE . ../src "${_harness}")
target_compile_definitions(tst_Features PRIVATE
  HAL_C2_APP_VERSION="test"
  HAL_C2_FEATURES_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../../features"
  HAL_C2_QML_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../../packages/qml"
  HAL_C2_MOBILE_QML_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../qml"
)
target_link_libraries(tst_Features PRIVATE hal_c2_native Qt6::GuiPrivate Qt6::Quick Qt6::QuickControls2 Qt6::Test)
hal_c2_target_platform_window(tst_Features)
hal_c2_target_terminal(tst_Features)
hal_c2_target_scanner(tst_Features)
hal_c2_target_push(tst_Features)
add_test(NAME Features COMMAND tst_Features)
set_tests_properties(Features PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORMTHEME=")
# The screens' own decisions, against the fake HalC2.Shell (imports/). Qt's own
# runner first: one on PATH can be Qt 5's, which exits 1 saying nothing.
# NO_DEFAULT_PATH: with CMAKE_PREFIX_PATH=/usr (Arch) the prefix's bin/ would
# come before the HINTS, and hold Qt 5's runner.
# An older build dir may have cached Qt 5's runner: drop a cached path that is
# not under Qt 6's bin/.
if(HAL_C2_QMLTESTRUNNER)
  set(QT6_BINDIR "${QT6_INSTALL_PREFIX}/${QT6_INSTALL_BINS}")
  cmake_path(IS_PREFIX QT6_BINDIR "${HAL_C2_QMLTESTRUNNER}" NORMALIZE _qmltest_in_qt6)
  if(NOT _qmltest_in_qt6)
    unset(HAL_C2_QMLTESTRUNNER CACHE)
  endif()
endif()
find_program(HAL_C2_QMLTESTRUNNER NAMES qmltestrunner6 qmltestrunner
  PATHS "${QT6_INSTALL_PREFIX}/${QT6_INSTALL_BINS}" NO_DEFAULT_PATH)
if(NOT HAL_C2_QMLTESTRUNNER)
  find_program(HAL_C2_QMLTESTRUNNER NAMES qmltestrunner6 qmltestrunner)
endif()
if(HAL_C2_QMLTESTRUNNER)
  add_test(NAME Qml COMMAND "${HAL_C2_QMLTESTRUNNER}" -input "${CMAKE_CURRENT_SOURCE_DIR}/qml"
    -import "${CMAKE_CURRENT_SOURCE_DIR}/imports" -import "${CMAKE_CURRENT_SOURCE_DIR}/../../../packages/qml" -import "${CMAKE_CURRENT_SOURCE_DIR}/../qml")
  set_tests_properties(Qml PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORMTHEME=")
endif()
# Regressions the property tests (prop/) found, one tst_*Regression.cpp each,
# picked up on the next build. native/ holds the shared shell's, which were
# desktop-qt's, with their plain unit tests below.
include(../cmake/GlobTests.cmake)
hal_c2_add_glob_tests(PATTERN "tst_*Regression.cpp" LABEL regression
  INCLUDES ../src "${_harness}"
  LIBRARIES hal_c2_native
)
hal_c2_add_glob_tests(DIRECTORY native PATTERN "tst_*Regression.cpp" LABEL regression
  INCLUDES ../src ../src/native "${_harness}"
  LIBRARIES hal_c2_native
)

# The shared shell's plain unit tests (native/), each on the sources it names.
if(APPLE)
  add_executable(tst_PlatformWindow native/tst_PlatformWindow.mm)
  target_include_directories(tst_PlatformWindow PRIVATE ../src)
  target_link_libraries(tst_PlatformWindow PRIVATE Qt6::Quick Qt6::Test)
  hal_c2_target_platform_window(tst_PlatformWindow)
  add_test(NAME PlatformWindow COMMAND tst_PlatformWindow)
endif()
add_executable(tst_FolderExplorer native/tst_FolderExplorer.cpp ../src/LocalFolderModel.cpp ../src/ShellBridge.cpp ../src/ThemeStore.cpp)
target_include_directories(tst_FolderExplorer PRIVATE ../src)
target_compile_definitions(tst_FolderExplorer PRIVATE HAL_C2_TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/..")
target_link_libraries(tst_FolderExplorer PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick Qt6::Test)
add_test(NAME FolderExplorer COMMAND tst_FolderExplorer)
set_tests_properties(FolderExplorer PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORMTHEME=;QT_QUICK_BACKEND=software")
# What links from untrusted text (pull requests, reviews) may open.
add_executable(tst_WebLinks native/tst_WebLinks.cpp ../src/ShellBridge.cpp)
target_include_directories(tst_WebLinks PRIVATE ../src)
target_link_libraries(tst_WebLinks PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Test)
add_test(NAME WebLinks COMMAND tst_WebLinks)
add_executable(tst_LocalFolderModel native/tst_LocalFolderModel.cpp ../src/LocalFolderModel.cpp)
target_include_directories(tst_LocalFolderModel PRIVATE ../src)
target_link_libraries(tst_LocalFolderModel PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Test)
add_test(NAME LocalFolderModel COMMAND tst_LocalFolderModel)
set_tests_properties(LocalFolderModel PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORMTHEME=")
add_executable(tst_StoragePaths native/tst_StoragePaths.cpp ../src/StoragePaths.cpp)
target_include_directories(tst_StoragePaths PRIVATE ../src)
target_link_libraries(tst_StoragePaths PRIVATE Qt6::Core Qt6::Test)
add_test(NAME StoragePaths COMMAND tst_StoragePaths)
# The client's cache of its MC, on a database of its own.
add_executable(tst_LocalCache native/tst_LocalCache.cpp ../src/native/LocalCache.cpp ../src/native/LocalCache.h)
target_include_directories(tst_LocalCache PRIVATE ../src/native)
target_link_libraries(tst_LocalCache PRIVATE Qt6::Core Qt6::Sql Qt6::Test)
add_test(NAME LocalCache COMMAND tst_LocalCache)
# What a group of tool calls did, in a sentence.
add_executable(tst_TimelineSummary native/tst_TimelineSummary.cpp ../src/native/TimelineSummary.cpp)
target_include_directories(tst_TimelineSummary PRIVATE ../src/native)
target_link_libraries(tst_TimelineSummary PRIVATE Qt6::Core Qt6::Test)
add_test(NAME TimelineSummary COMMAND tst_TimelineSummary)
# The update button's release notes, from a GitHub release's body.
add_executable(tst_ReleaseNotes native/tst_ReleaseNotes.cpp ../src/native/DesktopUpdateLogic.cpp)
target_include_directories(tst_ReleaseNotes PRIVATE ../src/native)
target_link_libraries(tst_ReleaseNotes PRIVATE Qt6::Core Qt6::Test)
add_test(NAME ReleaseNotes COMMAND tst_ReleaseNotes)
# What the pull request thread dialog reads from a pasted reference.
add_executable(tst_PullRequestReference native/tst_PullRequestReference.cpp ../src/native/PullRequestReference.cpp)
target_include_directories(tst_PullRequestReference PRIVATE ../src/native)
target_link_libraries(tst_PullRequestReference PRIVATE Qt6::Core Qt6::Test)
add_test(NAME PullRequestReference COMMAND tst_PullRequestReference)
# The fake MC's code fences against what the MC itself reads and writes.
add_executable(tst_CodeFence native/tst_CodeFence.cpp "${_harness}/CodeFence.h")
target_include_directories(tst_CodeFence PRIVATE "${_harness}")
target_compile_definitions(tst_CodeFence PRIVATE
  HAL_C2_CODE_FENCES="${CMAKE_CURRENT_SOURCE_DIR}/../../../apps/server-ex/test/fixtures/space/code-fences.json")
target_link_libraries(tst_CodeFence PRIVATE Qt6::Core Qt6::Test)
add_test(NAME CodeFence COMMAND tst_CodeFence)
# Windows are closed as the user closes them, through their ShellRuntime.
add_executable(tst_ShellRuntime
  native/tst_ShellRuntime.cpp
  ../src/ShellRuntime.cpp
  ../src/ShellBridge.cpp
  ../src/ThemeStore.cpp
  # Composer.qml's rich text and Markdown.qml's code; they register
  # themselves, as in the app.
  ../src/native/ComposerHighlighter.cpp
  ../src/native/CodeHighlighter.cpp
  ../src/native/CodeReader.cpp
)
target_include_directories(tst_ShellRuntime PRIVATE ../src ../src/native)
target_compile_definitions(tst_ShellRuntime PRIVATE
  HAL_C2_APP_VERSION="test"
  HAL_C2_TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/.."
)
target_link_libraries(tst_ShellRuntime PRIVATE Qt6::Core Qt6::Gui Qt6::GuiPrivate Qt6::Quick Qt6::Test)
if(HAL_C2_TERMINAL)
  target_link_libraries(tst_ShellRuntime PRIVATE qmlghosttyplugin)
endif()
hal_c2_link_syntax(tst_ShellRuntime)
hal_c2_target_platform_window(tst_ShellRuntime)
add_test(NAME ShellRuntime COMMAND tst_ShellRuntime)
set_tests_properties(ShellRuntime PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORMTHEME=;QML_DISABLE_DISK_CACHE=1")
# How the shell resolves its theme: the lookup order, the halves, the fallbacks.
add_executable(tst_ThemeResolution native/tst_ThemeResolution.cpp ../src/ThemeStore.cpp)
target_include_directories(tst_ThemeResolution PRIVATE ../src)
target_compile_definitions(tst_ThemeResolution PRIVATE HAL_C2_TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/..")
target_link_libraries(tst_ThemeResolution PRIVATE hal_c2_native Qt6::Test)
add_test(NAME ThemeResolution COMMAND tst_ThemeResolution)
add_executable(tst_ThisMachine native/tst_ThisMachine.cpp)
target_link_libraries(tst_ThisMachine PRIVATE hal_c2_native Qt6::Test)
add_test(NAME ThisMachine COMMAND tst_ThisMachine)
# What plugin pages format times with (Format.qml).
add_executable(tst_TimeFormat native/tst_TimeFormat.cpp)
target_link_libraries(tst_TimeFormat PRIVATE hal_c2_native Qt6::Test)
add_test(NAME TimeFormat COMMAND tst_TimeFormat)
# Which links in the conversation are pull requests, and which project reads one.
add_executable(tst_PullRequestLinks native/tst_PullRequestLinks.cpp)
target_link_libraries(tst_PullRequestLinks PRIVATE hal_c2_native Qt6::Test)
add_test(NAME PullRequestLinks COMMAND tst_PullRequestLinks)
set_tests_properties(ThemeResolution PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORMTHEME=")
foreach(_target tst_ScannerRegression)
  if(TARGET ${_target})
    hal_c2_target_scanner(${_target})
  endif()
endforeach()
