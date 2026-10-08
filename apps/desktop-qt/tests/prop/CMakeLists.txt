cmake_minimum_required(VERSION 3.21)
project(hal-c2-qt-property-tests LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
find_package(Qt6 6.9 REQUIRED COMPONENTS Core Gui GuiPrivate Network Quick Sql Test WebSockets)
enable_testing()
if(APPLE)
  enable_language(OBJCXX)
endif()

# Stateful property tests of the desktop's C++ (README.md), apart from the
# native tests: they need neither the QML nor the terminal.
include(../../cmake/NativeShell.cmake)
hal_c2_add_native_library()
include(../../cmake/RapidCheck.cmake)
include(../../cmake/GlobTests.cmake)
hal_c2_add_glob_tests(PATTERN "tst_*Prop.cpp" LABEL prop
  INCLUDES ../../src ../../src/native ../native/features
  LIBRARIES hal_c2_native rapidcheck
)
# The regressions the properties found, which the native tests also run, built
# here too so a fix is checked without the terminal.
hal_c2_add_glob_tests(DIRECTORY ../native PATTERN "tst_*Regression.cpp" LABEL regression
  INCLUDES ../../src ../../src/native ../native/features
  LIBRARIES hal_c2_native
)
