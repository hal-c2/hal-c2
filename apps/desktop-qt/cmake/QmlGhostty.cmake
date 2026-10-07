# qml-ghostty: the `Ghostty` QML module whose Terminal item draws the terminal
# drawer. It is pinned here and built against the libghostty-vt headers the
# repo vendors in native/libghostty-vt, so the Ghostty revision it pins must
# be the one in native/libghostty-vt/VERSION.
#
# The static library comes from qml-ghostty's scripts/build-libghostty-vt.sh
# (Zig 0.15.2, downloaded if missing; Ghostty checkout and Zig cached under
# ~/.cache/qml-ghostty). Set HAL_C2_GHOSTTY_VT_LIBRARY to use a prebuilt
# libghostty-vt.a instead, and FETCHCONTENT_SOURCE_DIR_QML_GHOSTTY to build
# from a local qml-ghostty checkout.
#
# A build for Android (the phone, apps/mobile-qt) gets the library from
# QmlGhosttyAndroid.cmake instead: the script only builds for this machine.
#
# Include once per project, then link `qmlghosttyplugin`.

include(FetchContent)

set(HAL_C2_QML_GHOSTTY_REVISION 1c90f80e4bb22bc8c7f33cf6d193e62412a40e56)
set(HAL_C2_GHOSTTY_VT_LIBRARY "" CACHE FILEPATH
  "Prebuilt libghostty-vt static library; empty builds it from source")

get_filename_component(_hal_c2_vt "${CMAKE_CURRENT_LIST_DIR}/../../../native/libghostty-vt" ABSOLUTE)
file(READ "${_hal_c2_vt}/VERSION" _hal_c2_vt_revision)
string(STRIP "${_hal_c2_vt_revision}" _hal_c2_vt_revision)

FetchContent_Declare(qml_ghostty
  GIT_REPOSITORY https://github.com/hal-c2/qml-ghostty.git
  GIT_TAG ${HAL_C2_QML_GHOSTTY_REVISION}
  # Populate only: it is added below, once libghostty-vt exists.
  SOURCE_SUBDIR populate-only
)
FetchContent_MakeAvailable(qml_ghostty)

file(READ "${qml_ghostty_SOURCE_DIR}/libghostty-vt.version" _qml_ghostty_vt_revision)
string(STRIP "${_qml_ghostty_vt_revision}" _qml_ghostty_vt_revision)
if(NOT _qml_ghostty_vt_revision STREQUAL _hal_c2_vt_revision)
  message(FATAL_ERROR "qml-ghostty pins Ghostty ${_qml_ghostty_vt_revision} but native/libghostty-vt "
    "is ${_hal_c2_vt_revision}; bump HAL_C2_QML_GHOSTTY_REVISION to a qml-ghostty with the same pin")
endif()

if(HAL_C2_GHOSTTY_VT_LIBRARY)
  set(GHOSTTY_VT_LIBRARY "${HAL_C2_GHOSTTY_VT_LIBRARY}")
elseif(ANDROID)
  include("${CMAKE_CURRENT_LIST_DIR}/QmlGhosttyAndroid.cmake")
else()
  set(_qml_ghostty_vt_prefix "${qml_ghostty_SOURCE_DIR}/third_party/libghostty-vt")
  set(GHOSTTY_VT_LIBRARY
    "${_qml_ghostty_vt_prefix}/lib/${CMAKE_STATIC_LIBRARY_PREFIX}ghostty-vt${CMAKE_STATIC_LIBRARY_SUFFIX}")
  set(_qml_ghostty_vt_built "")
  if(EXISTS "${_qml_ghostty_vt_prefix}/VERSION")
    file(READ "${_qml_ghostty_vt_prefix}/VERSION" _qml_ghostty_vt_built)
    string(STRIP "${_qml_ghostty_vt_built}" _qml_ghostty_vt_built)
  endif()
  if(NOT EXISTS "${GHOSTTY_VT_LIBRARY}" OR NOT _qml_ghostty_vt_built STREQUAL _hal_c2_vt_revision)
    if(WIN32)
      message(FATAL_ERROR "Set HAL_C2_GHOSTTY_VT_LIBRARY to a libghostty-vt built for this machine")
    endif()
    message(STATUS "Building libghostty-vt ${_hal_c2_vt_revision} (first configure only)")
    execute_process(
      COMMAND "${CMAKE_COMMAND}" -E env "GHOSTTY_REVISION=${_hal_c2_vt_revision}"
        bash "${qml_ghostty_SOURCE_DIR}/scripts/build-libghostty-vt.sh"
      COMMAND_ERROR_IS_FATAL ANY
    )
  endif()
endif()

# The repo's headers stand in for the ones the script installed; the pins match.
set(GHOSTTY_VT_INCLUDE_DIR "${_hal_c2_vt}/include")
# Declared here, global, so Qt's plugin finalizer in this directory can see it;
# qml-ghostty keeps a ghostty::vt that already exists.
if(NOT TARGET ghostty::vt)
  add_library(ghostty::vt STATIC IMPORTED GLOBAL)
  set_target_properties(ghostty::vt PROPERTIES
    IMPORTED_LOCATION "${GHOSTTY_VT_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${GHOSTTY_VT_INCLUDE_DIR}")
endif()
set(QML_GHOSTTY_BUILD_EXAMPLES OFF)
set(QML_GHOSTTY_BUILD_TESTS OFF)
add_subdirectory("${qml_ghostty_SOURCE_DIR}" "${qml_ghostty_BINARY_DIR}")

# qml-ghostty links libutil, where forkpty lives on Linux, on every Unix that
# is not Apple's. Android has no libutil: its forkpty is in libc.
if(ANDROID)
  foreach(_qml_ghostty_property IN ITEMS LINK_LIBRARIES INTERFACE_LINK_LIBRARIES)
    get_target_property(_qml_ghostty_libraries qmlghostty ${_qml_ghostty_property})
    list(REMOVE_ITEM _qml_ghostty_libraries util "$<LINK_ONLY:util>")
    set_property(TARGET qmlghostty PROPERTY ${_qml_ghostty_property} "${_qml_ghostty_libraries}")
  endforeach()
endif()
