# The pairing-code scanner (src/Scanner.h): camera frames from Qt Multimedia,
# read by zxing-cpp (Apache-2.0). It is this client's alone; the desktop has
# no camera and links neither.
#
# zxing-cpp is pinned here and only its core is built, as a static library
# with the QR reader and nothing else: no writers, no C API, none of the
# other symbologies. src/QrReader.cpp is all that includes it.
#
# Include once per project, then call for each target that builds the app.

include(FetchContent)
find_package(Qt6 REQUIRED COMPONENTS Concurrent Multimedia)

# v3.1.1
set(HAL_C2_ZXING_REVISION 287c85df6f961c8efbfb5ffd736cd9457b8b890e)

# A function, so what zxing-cpp is built with stays out of the app's own build.
function(_hal_c2_add_zxing)
  set(BUILD_SHARED_LIBS OFF)
  # It is no Qt code, though one of its headers (ZXingQt.h) has a Q_OBJECT.
  set(CMAKE_AUTOMOC OFF)
  set(ZXING_READERS ON)
  set(ZXING_WRITERS OFF)
  set(ZXING_C_API OFF)
  set(ZXING_ENABLE_QRCODE ON)
  foreach(_format 1D AZTEC DATAMATRIX MAXICODE PDF417)
    set(ZXING_ENABLE_${_format} OFF)
  endforeach()
  FetchContent_Declare(zxing
    GIT_REPOSITORY https://github.com/zxing-cpp/zxing-cpp.git
    GIT_TAG ${HAL_C2_ZXING_REVISION}
    # Its top level adds examples, wrappers and a docs target that downloads.
    SOURCE_SUBDIR core
    EXCLUDE_FROM_ALL
  )
  FetchContent_MakeAvailable(zxing)
endfunction()
_hal_c2_add_zxing()

function(hal_c2_target_scanner target)
  set(_src "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../src")
  target_sources(${target} PRIVATE
    "${_src}/QrReader.cpp"
    "${_src}/QrReader.h"
    "${_src}/ScanCamera.cpp"
    "${_src}/ScanCamera.h"
    "${_src}/Scanner.cpp"
    "${_src}/Scanner.h"
  )
  target_link_libraries(${target} PRIVATE Qt6::Concurrent Qt6::Multimedia ZXing::ZXing)
  # Qt Multimedia for Android comes with two backends, and a package gets
  # both unless told: FFmpeg, its default, with 16 MB of libav* libraries, and
  # the one over Android's own camera and codecs. A camera's preview is all
  # that is asked of it here, so the package carries the second alone, and Qt
  # then has no other to choose.
  if(ANDROID)
    qt_import_plugins(${target} INCLUDE_BY_TYPE multimedia Qt6::QAndroidMediaPlugin)
  endif()
endfunction()
