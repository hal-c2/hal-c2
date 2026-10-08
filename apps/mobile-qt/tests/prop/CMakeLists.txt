cmake_minimum_required(VERSION 3.21)
project(hal-c2-mobile-property-tests LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
find_package(Qt6 6.9 REQUIRED COMPONENTS Core Gui GuiPrivate Network Quick Sql Test WebSockets)
enable_testing()
if(APPLE)
  enable_language(OBJCXX)
endif()

# Stateful property tests of the phone's own C++, on the desktop's harness
# (apps/desktop-qt/tests/prop/README.md).
set(_desktop "${CMAKE_CURRENT_SOURCE_DIR}/../../../desktop-qt")
include("${_desktop}/cmake/NativeShell.cmake")
hal_c2_add_native_library()
include("${_desktop}/cmake/RapidCheck.cmake")
include("${_desktop}/cmake/GlobTests.cmake")
include(../../cmake/Scanner.cmake)
hal_c2_add_glob_tests(PATTERN "tst_*Prop.cpp" LABEL prop
  INCLUDES ../../src .. "${_desktop}/tests/prop" "${_desktop}/tests/native/features"
  LIBRARIES hal_c2_native rapidcheck
)
# The regressions the properties found, which the phone's tests also run.
hal_c2_add_glob_tests(DIRECTORY .. PATTERN "tst_*Regression.cpp" LABEL regression
  INCLUDES ../../src .. "${_desktop}/tests/native/features"
  LIBRARIES hal_c2_native
)
# The scanner's tests read codes with zxing-cpp.
foreach(_target tst_ScannerProp tst_ScannerRegression)
  if(TARGET ${_target})
    hal_c2_target_scanner(${_target})
  endif()
endforeach()
