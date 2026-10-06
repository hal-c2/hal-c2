# What androiddeployqt wraps the build in: android/ (the manifest and the
# launcher icon) and the OpenSSL the APK carries.
#
# The icon's layers are the legacy app's, which scripts/export-android-icons.ts
# renders into apps/mobile/assets. They are copied next to android/ in the
# build tree, and that copy is the package directory, so git keeps them once.
#
# Qt for Android has no TLS of its own: its OpenSSL backend loads libssl_3.so
# and libcrypto_3.so from the APK at run time, and without them every https
# and wss connection fails. They are KDAB's prebuilt ones, which Qt's "Adding
# OpenSSL Support for Android" names, fetched one file at a time from a
# pinned commit: the archive that page fetches carries every ABI and OpenSSL
# 1.1 as well, about 200 MB.
#
# Include once, then call for the app's target.

set(HAL_C2_ANDROID_OPENSSL_REVISION b71f1470962019bd89534a2919f5925f93bc5779)
set(HAL_C2_ANDROID_OPENSSL_SHA256_arm64-v8a_libcrypto_3.so 1e6c12ae0c2dadfe9d178d7f80f0ab248a1877a234066098bf5594e5205e5740)
set(HAL_C2_ANDROID_OPENSSL_SHA256_arm64-v8a_libssl_3.so 01d2bd0baac626efd3309f35f99c4b826dd9b885a7e4d14d5b12b3603d3a407f)

function(hal_c2_android_package target)
  set(_source "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../android")
  set(_package "${CMAKE_CURRENT_BINARY_DIR}/android-package")
  file(GLOB_RECURSE _files CONFIGURE_DEPENDS RELATIVE "${_source}" "${_source}/*")
  foreach(_file IN LISTS _files)
    configure_file("${_source}/${_file}" "${_package}/${_file}" COPYONLY)
  endforeach()
  # 432 px is the 108 dp adaptive canvas at xxxhdpi; Android scales it down.
  set(_assets "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../../mobile/assets")
  configure_file("${_assets}/android-icon-foreground.png" "${_package}/res/mipmap-xxxhdpi/ic_launcher_foreground.png" COPYONLY)
  configure_file("${_assets}/android-icon-mark.png" "${_package}/res/mipmap-xxxhdpi/ic_launcher_monochrome.png" COPYONLY)

  set(_openssl "")
  foreach(_library libcrypto_3.so libssl_3.so)
    if(NOT DEFINED HAL_C2_ANDROID_OPENSSL_SHA256_${CMAKE_ANDROID_ARCH_ABI}_${_library})
      message(FATAL_ERROR "No OpenSSL is pinned for ${CMAKE_ANDROID_ARCH_ABI}; add its hashes to AndroidPackage.cmake")
    endif()
    set(_path "${CMAKE_CURRENT_BINARY_DIR}/openssl/${CMAKE_ANDROID_ARCH_ABI}/${_library}")
    # A file that is already there and matches the hash is not fetched again.
    file(DOWNLOAD
      "https://raw.githubusercontent.com/KDAB/android_openssl/${HAL_C2_ANDROID_OPENSSL_REVISION}/ssl_3/${CMAKE_ANDROID_ARCH_ABI}/${_library}"
      "${_path}"
      EXPECTED_HASH SHA256=${HAL_C2_ANDROID_OPENSSL_SHA256_${CMAKE_ANDROID_ARCH_ABI}_${_library}}
      TLS_VERIFY ON
    )
    list(APPEND _openssl "${_path}")
  endforeach()

  set_target_properties(${target} PROPERTIES
    QT_ANDROID_PACKAGE_SOURCE_DIR "${_package}"
    QT_ANDROID_EXTRA_LIBS "${_openssl}"
    # Qt's default is 1.0, whatever the project says.
    QT_ANDROID_VERSION_NAME "${PROJECT_VERSION}"
  )
endfunction()
