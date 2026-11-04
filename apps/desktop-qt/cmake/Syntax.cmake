# The code highlighter (native/syntax): a Rust static library cargo builds into
# this build directory, linked into hal_c2_native (src/native/CodeHighlighter).
# Always cargo's release profile: a debug syntect is too slow to read code with.
#
# Android takes the crate's pure-Rust regex engine, so cargo needs no C
# compiler for the target, only rustup's target for its ABI
# (`rustup target add aarch64-linux-android`). Its cargo is rustup's, since the
# one on PATH may be a system Rust without Android's standard library;
# HAL_C2_CARGO names another.

function(hal_c2_link_syntax target)
  if(NOT TARGET hal_c2_syntax)
    _hal_c2_add_syntax()
  endif()
  # What Rust's standard library needs from the system (`--print native-static-libs`).
  if(ANDROID)
    set(_system dl log unwind m)
  elseif(WIN32)
    set(_system ws2_32 userenv bcrypt ntdll)
  elseif(APPLE)
    set(_system "-framework CoreFoundation" iconv)
  else()
    set(_system pthread dl m rt util)
  endif()
  target_link_libraries(${target} PUBLIC hal_c2_syntax ${_system})
endfunction()

function(_hal_c2_add_syntax)
  if(ANDROID AND NOT HAL_C2_CARGO)
    find_program(_rustup rustup)
    if(_rustup)
      execute_process(COMMAND "${_rustup}" which cargo OUTPUT_VARIABLE _cargo OUTPUT_STRIP_TRAILING_WHITESPACE)
      set(HAL_C2_CARGO "${_cargo}" CACHE FILEPATH "The cargo that builds native/syntax")
    endif()
  endif()
  find_program(HAL_C2_CARGO cargo REQUIRED)
  get_filename_component(_crate "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../../../native/syntax" ABSOLUTE)
  set(_target_dir "${CMAKE_BINARY_DIR}/cargo/syntax")
  set(_args build --release --locked --manifest-path "${_crate}/Cargo.toml" --target-dir "${_target_dir}")
  set(_out "${_target_dir}/release")
  if(ANDROID)
    set(_triples_arm64-v8a aarch64-linux-android)
    set(_triples_armeabi-v7a armv7-linux-androideabi)
    set(_triples_x86_64 x86_64-linux-android)
    set(_triples_x86 i686-linux-android)
    set(_triple "${_triples_${ANDROID_ABI}}")
    if(NOT _triple)
      message(FATAL_ERROR "native/syntax: no Rust target for the Android ABI ${ANDROID_ABI}")
    endif()
    list(APPEND _args --target "${_triple}" --no-default-features --features fancy)
    set(_out "${_target_dir}/${_triple}/release")
  endif()
  if(MSVC)
    set(_library "${_out}/hal_c2_syntax.lib")
  else()
    set(_library "${_out}/libhal_c2_syntax.a")
  endif()
  file(GLOB _sources CONFIGURE_DEPENDS "${_crate}/src/*.rs" "${_crate}/themes/*.json")
  add_custom_command(
    OUTPUT "${_library}"
    COMMAND "${HAL_C2_CARGO}" ${_args}
    DEPENDS ${_sources} "${_crate}/Cargo.toml" "${_crate}/Cargo.lock"
    COMMENT "Building the code highlighter (native/syntax)"
    USES_TERMINAL
    VERBATIM)
  add_custom_target(hal_c2_syntax_build DEPENDS "${_library}")
  add_library(hal_c2_syntax STATIC IMPORTED GLOBAL)
  set_target_properties(hal_c2_syntax PROPERTIES
    IMPORTED_LOCATION "${_library}"
    INTERFACE_INCLUDE_DIRECTORIES "${_crate}/include")
  add_dependencies(hal_c2_syntax hal_c2_syntax_build)
endfunction()
