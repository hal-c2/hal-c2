# The terminal: qml-ghostty's `Ghostty` module, which the desktop's terminal
# bricks import, built as the desktop builds it
# (apps/desktop-qt/cmake/QmlGhostty.cmake, which cross-builds its library for
# Android). A target that has it is compiled with HAL_C2_HAS_TERMINAL, and
# only such a target may load a brick that imports Ghostty.
#
# -DHAL_C2_TERMINAL=OFF leaves it out, for a machine that cannot get Zig or
# build libghostty-vt. It is on wherever that build is known to work: not on
# Windows, where the desktop wants a prebuilt library, and not for iOS, which
# nothing builds it for yet.
#
# Include once per project, then call for each target that loads the bricks.

if(CMAKE_HOST_WIN32 OR IOS)
  set(_hal_c2_terminal_default OFF)
else()
  set(_hal_c2_terminal_default ON)
endif()
option(HAL_C2_TERMINAL "Build the terminal (qml-ghostty; its libghostty-vt needs Zig 0.15.2)" ${_hal_c2_terminal_default})

if(HAL_C2_TERMINAL)
  include("${CMAKE_CURRENT_LIST_DIR}/../../desktop-qt/cmake/QmlGhostty.cmake")
endif()

function(hal_c2_target_terminal target)
  if(HAL_C2_TERMINAL)
    target_link_libraries(${target} PRIVATE qmlghosttyplugin)
    target_compile_definitions(${target} PRIVATE HAL_C2_HAS_TERMINAL)
  endif()
endfunction()
