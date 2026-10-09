# google/fuzztest (Apache-2.0), the fuzz tests' engine and domains (tests/fuzz).
# Only the fuzz tests link it; nothing ships it. It fetches Abseil, RE2,
# GoogleTest and the ANTLR runtime, none of them built unless a fuzz test
# needs them (EXCLUDE_FROM_ALL), and none of their own tests.
#
# Two builds, chosen by FUZZTEST_FUZZING_MODE:
#   ON   Clang only. Everything after this file is included gets coverage
#        instrumentation, AddressSanitizer (with LeakSanitizer) and
#        UndefinedBehaviorSanitizer, so `--fuzz` and `--fuzz_for` work.
#   OFF  Unit-test mode: each FUZZ_TEST runs its seeds, the corpus database and
#        a bounded number of random inputs, with no instrumentation, for
#        Valgrind's Memcheck (which cannot run sanitized code).
#
# Include once per project, before any target a fuzz test links (so fuzzing
# mode instruments them), then call hal_c2_add_fuzz_tests().

include(FetchContent)

# main, 2026-10-07
set(HAL_C2_FUZZTEST_REVISION b30b2fe08bad4a7c3df5918e07a828b3c45d2c0c)

# A function, so what fuzztest and its dependencies are built with stays out of
# the fuzz tests' own build.
function(_hal_c2_add_fuzztest)
  set(CMAKE_AUTOMOC OFF)
  set(BUILD_SHARED_LIBS OFF)
  set(FUZZTEST_BUILD_TESTING OFF CACHE BOOL "" FORCE)
  set(ABSL_BUILD_TESTING OFF CACHE BOOL "" FORCE)
  set(INSTALL_GTEST OFF CACHE BOOL "" FORCE)
  set(ANTLR_BUILD_CPP_TESTS OFF CACHE BOOL "" FORCE)
  set(ANTLR_BUILD_SHARED OFF CACHE BOOL "" FORCE)
  FetchContent_Declare(fuzztest
    GIT_REPOSITORY https://github.com/google/fuzztest.git
    GIT_TAG ${HAL_C2_FUZZTEST_REVISION}
    EXCLUDE_FROM_ALL
  )
  FetchContent_MakeAvailable(fuzztest)
  # fuzztest builds itself and Abseil as C++17; the tests are C++20, and
  # Abseil's types differ between the two (absl/base/options.h), so all of it
  # is built as the tests are.
  _hal_c2_cxx_standard("${fuzztest_SOURCE_DIR}")
endfunction()
function(_hal_c2_cxx_standard dir)
  get_property(_targets DIRECTORY "${dir}" PROPERTY BUILDSYSTEM_TARGETS)
  foreach(_target IN LISTS _targets)
    get_target_property(_type ${_target} TYPE)
    if(NOT _type STREQUAL "INTERFACE_LIBRARY" AND NOT _type STREQUAL "UTILITY")
      set_target_properties(${_target} PROPERTIES CXX_STANDARD ${CMAKE_CXX_STANDARD})
    endif()
  endforeach()
  get_property(_dirs DIRECTORY "${dir}" PROPERTY SUBDIRECTORIES)
  foreach(_dir IN LISTS _dirs)
    _hal_c2_cxx_standard("${_dir}")
  endforeach()
endfunction()
_hal_c2_add_fuzztest()

# Fuzzing mode's flags for what follows (a macro: it sets this scope's
# CMAKE_CXX_FLAGS). It brings coverage and ASan; UBSan is ours, and stops at
# the first report so the engine sees it as a crash.
fuzztest_setup_fuzzing_flags()
if(FUZZTEST_FUZZING_MODE)
  string(APPEND CMAKE_CXX_FLAGS " -fsanitize=undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer")
  string(APPEND CMAKE_EXE_LINKER_FLAGS " -fsanitize=undefined")
endif()

include("${CMAKE_CURRENT_LIST_DIR}/GlobTests.cmake")

# Adds one fuzz test executable per file matching PATTERN, as
# hal_c2_add_glob_tests does (a `.sources` list beside one adds sources), each
# with tests/fuzz/FuzzMain.cpp for its main. ctest runs each executable whole,
# in unit-test mode.
#
#   hal_c2_add_fuzz_tests(PATTERN tst_*Fuzz.cpp INCLUDES <dirs>... LIBRARIES <targets>...)
function(hal_c2_add_fuzz_tests)
  cmake_parse_arguments(PARSE_ARGV 0 arg "" "PATTERN" "INCLUDES;LIBRARIES")
  set(_fuzz "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../tests/fuzz")
  hal_c2_add_glob_tests(PATTERN "${arg_PATTERN}" LABEL fuzz
    SOURCES "${_fuzz}/FuzzMain.cpp"
    INCLUDES "${_fuzz}" ${arg_INCLUDES}
    LIBRARIES ${arg_LIBRARIES} fuzztest::fuzztest fuzztest::init_fuzztest GTest::gtest
              absl::failure_signal_handler absl::symbolize
  )
endfunction()
