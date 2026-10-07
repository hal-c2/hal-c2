# libghostty-vt for Android. QmlGhostty.cmake includes this when the build is
# for Android, and it leaves GHOSTTY_VT_LIBRARY naming a static library for
# the ABI and API level being built.
#
# qml-ghostty's script only builds for the machine it runs on, so Zig is run
# here, on the same Ghostty checkout, with an Android target. Ghostty's build
# takes libc from the NDK itself (pkg/android-ndk, told where through
# ANDROID_NDK_HOME).
#
# The library is kept beside what the script caches, in
# ~/.cache/qml-ghostty/libghostty-vt-<revision>-<target>, so another build
# directory or worktree does not build it again (under a minute here). Its
# VERSION names the Ghostty revision, the target, the Zig and the NDK it was
# built with; a change in any of them builds it again.
#
# Zig and the checkout are the script's: $GHOSTTY_ZIG, a `zig` of the pinned
# version on PATH or the one it downloaded, and $GHOSTTY_SOURCE_DIR or its
# clone. When one is missing the script is run to fetch it, which also builds
# this machine's library, unused here.

set(_ghostty_android_zig_version 0.15.2)
# One Zig target, which is also the NDK's name for it, per ABI the phone ships.
set(_ghostty_android_triple_arm64-v8a aarch64-linux-android)
if(NOT DEFINED _ghostty_android_triple_${CMAKE_ANDROID_ARCH_ABI})
  message(FATAL_ERROR "No Zig target is named for ${CMAKE_ANDROID_ARCH_ABI}; add it to QmlGhosttyAndroid.cmake")
endif()
set(_ghostty_android_triple "${_ghostty_android_triple_${CMAKE_ANDROID_ARCH_ABI}}")
# The API level, as either of the NDK's toolchain files leaves it.
set(_ghostty_android_api "${ANDROID_PLATFORM_LEVEL}")
if(NOT _ghostty_android_api)
  set(_ghostty_android_api "${CMAKE_SYSTEM_VERSION}")
endif()
set(_ghostty_android_target "${_ghostty_android_triple}.${_ghostty_android_api}")

# The script's cache, by its rules.
if(DEFINED ENV{QML_GHOSTTY_CACHE})
  set(_ghostty_android_cache "$ENV{QML_GHOSTTY_CACHE}")
elseif(DEFINED ENV{XDG_CACHE_HOME})
  set(_ghostty_android_cache "$ENV{XDG_CACHE_HOME}/qml-ghostty")
else()
  set(_ghostty_android_cache "$ENV{HOME}/.cache/qml-ghostty")
endif()
string(SUBSTRING "${_hal_c2_vt_revision}" 0 8 _ghostty_android_short)

set(_ghostty_android_prefix "${_ghostty_android_cache}/libghostty-vt-${_ghostty_android_short}-${_ghostty_android_target}")
set(GHOSTTY_VT_LIBRARY "${_ghostty_android_prefix}/lib/libghostty-vt.a")
set(_ghostty_android_stamp
  "${_hal_c2_vt_revision} ${_ghostty_android_target} zig-${_ghostty_android_zig_version} ndk-${ANDROID_NDK_REVISION}")
set(_ghostty_android_built "")
if(EXISTS "${_ghostty_android_prefix}/VERSION")
  file(READ "${_ghostty_android_prefix}/VERSION" _ghostty_android_built)
  string(STRIP "${_ghostty_android_built}" _ghostty_android_built)
endif()

# Sets `out` to a Zig of the pinned version, or to nothing.
function(_ghostty_android_find_zig out)
  set(${out} "" PARENT_SCOPE)
  find_program(_on_path zig NO_CACHE)
  foreach(_zig IN ITEMS "$ENV{GHOSTTY_ZIG}" "${_on_path}" "${_ghostty_android_cache}/zig-${_ghostty_android_zig_version}/zig")
    if(_zig AND EXISTS "${_zig}")
      execute_process(COMMAND "${_zig}" version OUTPUT_VARIABLE _version OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
      if(_version STREQUAL _ghostty_android_zig_version)
        set(${out} "${_zig}" PARENT_SCOPE)
        return()
      endif()
    endif()
  endforeach()
endfunction()

if(NOT EXISTS "${GHOSTTY_VT_LIBRARY}" OR NOT _ghostty_android_built STREQUAL _ghostty_android_stamp)
  if(NOT EXISTS "${CMAKE_SYSROOT}/usr/lib/${_ghostty_android_triple}/${_ghostty_android_api}/libc.so")
    message(FATAL_ERROR "The NDK at ${ANDROID_NDK} has no ${_ghostty_android_triple} libc for API "
      "${_ghostty_android_api}, which libghostty-vt is built against; -DHAL_C2_TERMINAL=OFF builds the phone without the terminal")
  endif()

  if(DEFINED ENV{GHOSTTY_SOURCE_DIR})
    set(_ghostty_android_source "$ENV{GHOSTTY_SOURCE_DIR}")
  else()
    set(_ghostty_android_source "${_ghostty_android_cache}/ghostty-${_ghostty_android_short}")
  endif()
  _ghostty_android_find_zig(_ghostty_android_zig)
  if(NOT _ghostty_android_zig OR NOT EXISTS "${_ghostty_android_source}/build.zig")
    message(STATUS "Fetching Zig ${_ghostty_android_zig_version} and Ghostty ${_hal_c2_vt_revision} with qml-ghostty's script")
    # Not fatal: only what it fetched is needed, which is checked below.
    execute_process(
      COMMAND "${CMAKE_COMMAND}" -E env "GHOSTTY_REVISION=${_hal_c2_vt_revision}"
        bash "${qml_ghostty_SOURCE_DIR}/scripts/build-libghostty-vt.sh"
    )
    _ghostty_android_find_zig(_ghostty_android_zig)
  endif()
  if(NOT _ghostty_android_zig)
    message(FATAL_ERROR "Zig ${_ghostty_android_zig_version}, which builds libghostty-vt, is not on PATH or in "
      "${_ghostty_android_cache} and could not be downloaded; -DHAL_C2_TERMINAL=OFF builds the phone without the terminal")
  endif()
  set(_ghostty_android_head "")
  if(EXISTS "${_ghostty_android_source}/build.zig")
    execute_process(COMMAND git -C "${_ghostty_android_source}" rev-parse HEAD
      OUTPUT_VARIABLE _ghostty_android_head OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
  endif()
  if(NOT _ghostty_android_head STREQUAL _hal_c2_vt_revision)
    message(FATAL_ERROR "No Ghostty checkout at ${_hal_c2_vt_revision} in ${_ghostty_android_source} and it could not "
      "be cloned; -DHAL_C2_TERMINAL=OFF builds the phone without the terminal")
  endif()

  message(STATUS "Building libghostty-vt ${_hal_c2_vt_revision} for ${_ghostty_android_target} (once per machine)")
  # The script's build, with a target. Zig's intermediate files go to the
  # build tree and are dropped: only the installed library is kept.
  set(_ghostty_android_work "${CMAKE_CURRENT_BINARY_DIR}/libghostty-vt-zig-cache")
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -E env "ANDROID_NDK_HOME=${ANDROID_NDK}"
      "${_ghostty_android_zig}" build -Demit-lib-vt -Demit-xcframework=false -Doptimize=ReleaseFast
      "-Dtarget=${_ghostty_android_target}" -p "${_ghostty_android_prefix}" --cache-dir "${_ghostty_android_work}"
    WORKING_DIRECTORY "${_ghostty_android_source}"
    RESULT_VARIABLE _ghostty_android_result
  )
  file(REMOVE_RECURSE "${_ghostty_android_work}")
  if(NOT _ghostty_android_result EQUAL 0 OR NOT EXISTS "${GHOSTTY_VT_LIBRARY}")
    message(FATAL_ERROR "libghostty-vt did not build for ${_ghostty_android_target} (Zig's output is above); "
      "-DHAL_C2_TERMINAL=OFF builds the phone without the terminal")
  endif()
  file(WRITE "${_ghostty_android_prefix}/VERSION" "${_ghostty_android_stamp}\n")
endif()
