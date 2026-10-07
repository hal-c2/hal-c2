# Nayuki's QR Code generator (MIT), the C++ twin of the one packages/shared
# vendors in TypeScript: one source file, compiled into hal_c2_native for
# src/native/QrCode.cpp, which is all that includes it.
#
# Include once per project, before hal_c2_add_native_library().

include(FetchContent)

# v1.8.0
set(HAL_C2_QRCODEGEN_REVISION 720f62bddb7226106071d4728c292cb1df519ceb)

FetchContent_Declare(qrcodegen
  GIT_REPOSITORY https://github.com/nayuki/QR-Code-generator.git
  GIT_TAG ${HAL_C2_QRCODEGEN_REVISION}
  # Populate only: the repository has no CMake project of its own.
  SOURCE_SUBDIR populate-only
)
FetchContent_MakeAvailable(qrcodegen)
