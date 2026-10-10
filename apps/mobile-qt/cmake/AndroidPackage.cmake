# What androiddeployqt wraps the build in: android/ (the manifest and the
# launcher icon) and the OpenSSL the APK carries (AndroidOpenSsl.cmake).
#
# Include once, then call for the app's target.

include("${CMAKE_CURRENT_LIST_DIR}/AndroidOpenSsl.cmake")

function(hal_c2_android_package target)
  set(_source "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../android")
  set(_package "${CMAKE_CURRENT_BINARY_DIR}/android-package")
  file(GLOB_RECURSE _files CONFIGURE_DEPENDS RELATIVE "${_source}" "${_source}/*")
  foreach(_file IN LISTS _files)
    configure_file("${_source}/${_file}" "${_package}/${_file}" COPYONLY)
  endforeach()

  set_target_properties(${target} PROPERTIES
    QT_ANDROID_PACKAGE_SOURCE_DIR "${_package}"
    QT_ANDROID_EXTRA_LIBS "${HAL_C2_ANDROID_OPENSSL_LIBRARIES}"
    # Qt's default is 1.0, whatever the project says.
    QT_ANDROID_VERSION_NAME "${PROJECT_VERSION}"
  )
endfunction()
