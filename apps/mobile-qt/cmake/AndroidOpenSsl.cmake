# The OpenSSL the APK carries. AndroidPackage.cmake includes this, and it
# leaves HAL_C2_ANDROID_OPENSSL_LIBRARIES naming libcrypto_3.so and
# libssl_3.so for the ABI and API level being built.
#
# Qt for Android has no TLS of its own: its OpenSSL backend loads those two
# from the APK at run time, by those names, and without them every https and
# wss connection fails. Qt 6.11.1 is itself built against OpenSSL 3.5.4.
#
# They are built here from OpenSSL's release tarball, because nobody
# publishes them for a supported OpenSSL: KDAB's prebuilt ones, which Qt's
# "Adding OpenSSL Support for Android" names, are 3.1.8, of a branch OpenSSL
# no longer supports (KDAB/android_openssl#77). The pin is the 3.5
# long-term branch, supported until April 2030; a newer 3.5.x is a new
# version and hash here, and a new version in the notice
# (third-party-licenses.config.json). https://openssl-library.org/policies/releasestrat/
# says which branches are supported; one that is not 3.x has not been tried
# with this Qt, which refuses anything older.
#
# The build is OpenSSL's own for Android with the NDK's clang, as that page
# of Qt's describes, and needs perl and make. The `_3` in the names comes
# from a target of our own that inherits OpenSSL's and sets `shlib_variant`,
# so nothing has to rename the libraries afterwards (Qt's page uses patchelf)
# and no source is patched; OpenSSL then puts the variant in its symbol
# versions as well (OPENSSL_3_3.0.0), which only matters to code linked
# against the libraries, and Qt looks every symbol up by name.
#
# The two libraries are kept in ~/.cache/qt-android-openssl, so another build
# directory or worktree does not build them again (the tarball is 53 MB and
# the build takes about 20 seconds here). VERSION there names what they were
# built from and with; a change in any of it builds them again.

set(HAL_C2_ANDROID_OPENSSL_VERSION 3.5.9)
set(HAL_C2_ANDROID_OPENSSL_SHA256 603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a)

# One OpenSSL target per ABI the phone ships.
set(_openssl_target_arm64-v8a android-arm64)
if(NOT DEFINED _openssl_target_${CMAKE_ANDROID_ARCH_ABI})
  message(FATAL_ERROR "No OpenSSL target is named for ${CMAKE_ANDROID_ARCH_ABI}; add it to AndroidOpenSsl.cmake")
endif()
set(_openssl_target "${_openssl_target_${CMAKE_ANDROID_ARCH_ABI}}")
# The API level, as either of the NDK's toolchain files leaves it.
set(_openssl_api "${ANDROID_PLATFORM_LEVEL}")
if(NOT _openssl_api)
  set(_openssl_api "${CMAKE_SYSTEM_VERSION}")
endif()
# Qt for Android is built for 16 KB pages, which the NDK's linker only
# defaults to from r28.
set(_openssl_options shared -U__ANDROID_API__ -D__ANDROID_API__=${_openssl_api} -Wl,-z,max-page-size=16384)

if(DEFINED ENV{XDG_CACHE_HOME})
  set(_openssl_cache "$ENV{XDG_CACHE_HOME}/qt-android-openssl")
else()
  set(_openssl_cache "$ENV{HOME}/.cache/qt-android-openssl")
endif()
set(_openssl_prefix "${_openssl_cache}/openssl-${HAL_C2_ANDROID_OPENSSL_VERSION}-${_openssl_target}.${_openssl_api}")
set(HAL_C2_ANDROID_OPENSSL_LIBRARIES "${_openssl_prefix}/libcrypto_3.so" "${_openssl_prefix}/libssl_3.so")
set(_openssl_stamp
  "openssl-${HAL_C2_ANDROID_OPENSSL_VERSION} ${HAL_C2_ANDROID_OPENSSL_SHA256} ${_openssl_target} ndk-${ANDROID_NDK_REVISION} ${_openssl_options}")
set(_openssl_built "")
if(EXISTS "${_openssl_prefix}/VERSION")
  file(READ "${_openssl_prefix}/VERSION" _openssl_built)
  string(STRIP "${_openssl_built}" _openssl_built)
endif()
set(_openssl_missing FALSE)
foreach(_openssl_library IN LISTS HAL_C2_ANDROID_OPENSSL_LIBRARIES)
  if(NOT EXISTS "${_openssl_library}")
    set(_openssl_missing TRUE)
  endif()
endforeach()

if(_openssl_missing OR NOT _openssl_built STREQUAL _openssl_stamp)
  find_program(_openssl_perl perl NO_CACHE)
  find_program(_openssl_make make NO_CACHE)
  if(NOT _openssl_perl OR NOT _openssl_make)
    message(FATAL_ERROR "The APK carries an OpenSSL built from source, which needs perl and make on PATH; "
      "one of them was not found")
  endif()

  message(STATUS "Building OpenSSL ${HAL_C2_ANDROID_OPENSSL_VERSION} for ${_openssl_target}, API ${_openssl_api} (once per machine)")
  set(_openssl_work "${CMAKE_CURRENT_BINARY_DIR}/openssl")
  set(_openssl_source "${_openssl_work}/openssl-${HAL_C2_ANDROID_OPENSSL_VERSION}")
  set(_openssl_log "${CMAKE_CURRENT_BINARY_DIR}/openssl-build.log")
  file(REMOVE_RECURSE "${_openssl_work}")
  file(DOWNLOAD
    "https://github.com/openssl/openssl/releases/download/openssl-${HAL_C2_ANDROID_OPENSSL_VERSION}/openssl-${HAL_C2_ANDROID_OPENSSL_VERSION}.tar.gz"
    "${_openssl_work}/openssl.tar.gz"
    EXPECTED_HASH SHA256=${HAL_C2_ANDROID_OPENSSL_SHA256}
    TLS_VERIFY ON
  )
  file(ARCHIVE_EXTRACT INPUT "${_openssl_work}/openssl.tar.gz" DESTINATION "${_openssl_work}")
  # OpenSSL reads the architecture off the end of the target's name.
  file(WRITE "${_openssl_work}/qt.conf"
    "my %targets = (\n  \"qt-${_openssl_target}\" => { inherit_from => [ \"${_openssl_target}\" ], shlib_variant => \"_3\" },\n);\n")

  # OpenSSL's Android targets want the NDK named and its clang first on PATH.
  get_filename_component(_openssl_toolchain "${CMAKE_CXX_COMPILER}" DIRECTORY)
  set(_openssl_env "${CMAKE_COMMAND}" -E env "ANDROID_NDK_ROOT=${ANDROID_NDK}" "PATH=${_openssl_toolchain}:$ENV{PATH}")
  include(ProcessorCount)
  ProcessorCount(_openssl_jobs)
  if(_openssl_jobs EQUAL 0)
    set(_openssl_jobs 1)
  endif()
  execute_process(
    COMMAND ${_openssl_env} "${_openssl_perl}" Configure "--config=${_openssl_work}/qt.conf" "qt-${_openssl_target}" ${_openssl_options}
    WORKING_DIRECTORY "${_openssl_source}"
    OUTPUT_FILE "${_openssl_log}" ERROR_FILE "${_openssl_log}"
    RESULT_VARIABLE _openssl_result
  )
  if(_openssl_result EQUAL 0)
    execute_process(
      COMMAND ${_openssl_env} "${_openssl_make}" -j${_openssl_jobs} build_libs
      WORKING_DIRECTORY "${_openssl_source}"
      OUTPUT_FILE "${_openssl_log}" ERROR_FILE "${_openssl_log}"
      RESULT_VARIABLE _openssl_result
    )
  endif()
  if(NOT _openssl_result EQUAL 0 OR NOT EXISTS "${_openssl_source}/libssl_3.so")
    message(FATAL_ERROR "OpenSSL ${HAL_C2_ANDROID_OPENSSL_VERSION} did not build for ${_openssl_target}; "
      "its output is in ${_openssl_log} and its tree in ${_openssl_source}")
  endif()

  file(REMOVE_RECURSE "${_openssl_prefix}")
  file(MAKE_DIRECTORY "${_openssl_prefix}")
  foreach(_openssl_library IN LISTS HAL_C2_ANDROID_OPENSSL_LIBRARIES)
    get_filename_component(_openssl_name "${_openssl_library}" NAME)
    execute_process(
      COMMAND "${_openssl_toolchain}/llvm-strip" --strip-all -o "${_openssl_library}" "${_openssl_source}/${_openssl_name}"
      COMMAND_ERROR_IS_FATAL ANY
    )
  endforeach()
  file(WRITE "${_openssl_prefix}/VERSION" "${_openssl_stamp}\n")
  # 200 MB of sources and objects; only the two libraries are kept.
  file(REMOVE_RECURSE "${_openssl_work}")
  file(REMOVE "${_openssl_log}")
endif()
