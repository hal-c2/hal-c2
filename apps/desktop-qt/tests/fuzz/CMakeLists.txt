cmake_minimum_required(VERSION 3.21)
project(hal-c2-qt-fuzz-tests LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
find_package(Qt6 6.9 REQUIRED COMPONENTS Core Gui GuiPrivate Network Quick Sql Test WebSockets)
enable_testing()
if(APPLE)
  enable_language(OBJCXX)
endif()

# Fuzz tests of the desktop's C++ (README.md). FuzzTest.cmake comes first so
# fuzzing mode instruments hal_c2_native as well as the tests.
include(../../cmake/FuzzTest.cmake)
set(CMAKE_AUTOMOC ON)
include(../../cmake/NativeShell.cmake)
hal_c2_add_native_library()
hal_c2_add_fuzz_tests(PATTERN "tst_*Fuzz.cpp"
  INCLUDES ../../src ../../src/native ../native/features
  LIBRARIES hal_c2_native
)
