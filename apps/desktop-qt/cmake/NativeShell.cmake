# hal_c2_native: the shell's own half, built once for the app and the native
# tests. Every file in src/native (the node client, the store, the controllers
# that take pieces off the page, their models) plus ShellBridge, which they
# publish through. A new file there is picked up on the next build, no list to
# edit.
#
# themes.json, generated from packages/shared, is compiled in as a resource.
#
# A Device tab's H.264 screen is decoded with FFmpeg's libavcodec (and
# scaled with libswscale), found through pkg-config: QtMultimedia's player
# paces and buffers by timestamp, where a live screen wants every picture as
# soon as it decodes and a keyframe asked for when it falls behind.
#
# OBJECT, not STATIC: controllers register themselves from static
# initialisers (NativeControllerRegistrar), which an archive would drop.
#
# Include once per project, then link `hal_c2_native`.

function(hal_c2_add_native_library webchannel_script_url)
  get_filename_component(_hal_c2_src "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../src" ABSOLUTE)
  file(GLOB _sources CONFIGURE_DEPENDS "${_hal_c2_src}/native/*.cpp" "${_hal_c2_src}/native/*.h")
  add_library(hal_c2_native OBJECT ${_sources} "${_hal_c2_src}/ShellBridge.cpp" "${_hal_c2_src}/ShellBridge.h")
  set_target_properties(hal_c2_native PROPERTIES AUTOMOC ON)
  target_include_directories(hal_c2_native PUBLIC "${_hal_c2_src}" "${_hal_c2_src}/native")
  target_compile_definitions(hal_c2_native PRIVATE HAL_C2_WEBCHANNEL_SCRIPT_URL="${webchannel_script_url}")
  find_package(PkgConfig REQUIRED)
  pkg_check_modules(HAL_C2_FFMPEG REQUIRED IMPORTED_TARGET libavcodec libavutil libswscale)
  target_link_libraries(hal_c2_native PUBLIC Qt6::Core Qt6::Gui Qt6::GuiPrivate Qt6::Qml Qt6::Quick Qt6::Network Qt6::WebSockets
                                             PkgConfig::HAL_C2_FFMPEG)
  # The built-in palettes (scripts/gen-themes.mjs), as :/hal-c2/themes.json.
  qt_add_resources(hal_c2_native hal_c2_native_themes PREFIX "/hal-c2" BASE "${_hal_c2_src}/native"
                   FILES "${_hal_c2_src}/native/themes.json")
endfunction()
