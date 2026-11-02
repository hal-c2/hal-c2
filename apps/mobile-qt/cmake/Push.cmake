# The phone's notifications (src/Notifications.h): the push inbox, which
# decrypts the MC's messages with OpenSSL's libcrypto (RFC 8291), and the
# device's side of them (src/push/PushSystem.h). On Android that libcrypto is
# the one the APK carries (AndroidOpenSsl.cmake); elsewhere it is the
# system's, for a development build and the scenarios.
#
# Include once per project, then call for each target that builds the app.

if(ANDROID)
  include("${CMAKE_CURRENT_LIST_DIR}/AndroidOpenSsl.cmake")
  if(NOT TARGET hal_c2_openssl_crypto)
    add_library(hal_c2_openssl_crypto SHARED IMPORTED)
    list(GET HAL_C2_ANDROID_OPENSSL_LIBRARIES 0 _push_crypto)
    set_target_properties(hal_c2_openssl_crypto PROPERTIES
      IMPORTED_LOCATION "${_push_crypto}"
      INTERFACE_INCLUDE_DIRECTORIES "${HAL_C2_ANDROID_OPENSSL_INCLUDE_DIR}"
    )
  endif()
  set(_push_crypto_target hal_c2_openssl_crypto)
else()
  find_package(OpenSSL 3 REQUIRED COMPONENTS Crypto)
  set(_push_crypto_target OpenSSL::Crypto)
endif()

function(hal_c2_target_push target)
  set(_src "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../src")
  target_sources(${target} PRIVATE
    "${_src}/Notifications.cpp"
    "${_src}/Notifications.h"
    "${_src}/push/PushCrypto.cpp"
    "${_src}/push/PushCrypto.h"
    "${_src}/push/PushInbox.cpp"
    "${_src}/push/PushInbox.h"
    "${_src}/push/PushSystem.cpp"
    "${_src}/push/PushSystem.h"
  )
  target_link_libraries(${target} PRIVATE ${_push_crypto_target})
endfunction()

# The inbox alone, for the tests that need no app.
function(hal_c2_target_push_inbox target)
  set(_src "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../src")
  target_sources(${target} PRIVATE
    "${_src}/push/PushCrypto.cpp"
    "${_src}/push/PushCrypto.h"
    "${_src}/push/PushInbox.cpp"
    "${_src}/push/PushInbox.h"
  )
  target_include_directories(${target} PRIVATE "${_src}/push")
  target_link_libraries(${target} PRIVATE ${_push_crypto_target})
endfunction()
