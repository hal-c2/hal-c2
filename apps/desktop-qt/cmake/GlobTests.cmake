# Adds one test per file matching PATTERN in DIRECTORY (default: the calling
# directory), picked up on the next build, named after the file without its
# `tst_` and labelled LABEL. Sources one needs beyond what LIBRARIES bring go in
# <file name>.sources beside it, one per line, relative to that directory;
# SOURCES go into every one.
#
#   hal_c2_add_glob_tests(PATTERN tst_*Prop.cpp LABEL prop [DIRECTORY <dir>]
#                         [SOURCES <files>...] INCLUDES <dirs>... LIBRARIES <targets>...)
function(hal_c2_add_glob_tests)
  cmake_parse_arguments(PARSE_ARGV 0 arg "" "DIRECTORY;PATTERN;LABEL" "SOURCES;INCLUDES;LIBRARIES")
  set(_dir "${CMAKE_CURRENT_SOURCE_DIR}")
  if(arg_DIRECTORY)
    get_filename_component(_dir "${arg_DIRECTORY}" ABSOLUTE)
  endif()
  file(GLOB _files CONFIGURE_DEPENDS "${_dir}/${arg_PATTERN}")
  foreach(_file IN LISTS _files)
    get_filename_component(_name "${_file}" NAME_WE)
    string(REGEX REPLACE "^tst_" "" _test "${_name}")
    set(_extra)
    set(_list "${_dir}/${_name}.sources")
    if(EXISTS "${_list}")
      set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${_list}")
      file(STRINGS "${_list}" _lines REGEX "^[^#]")
      foreach(_line IN LISTS _lines)
        list(APPEND _extra "${_dir}/${_line}")
      endforeach()
    endif()
    add_executable(${_name} "${_file}" ${_extra} ${arg_SOURCES})
    target_include_directories(${_name} PRIVATE "${_dir}" ${arg_INCLUDES})
    target_link_libraries(${_name} PRIVATE ${arg_LIBRARIES} Qt6::Test)
    add_test(NAME ${_test} COMMAND ${_name})
    # A soak (RC_PARAMS="max_success=1000") runs one slot far past QtTest's 300 s.
    set_tests_properties(${_test} PROPERTIES LABELS "${arg_LABEL}"
      ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORMTHEME=;QTEST_FUNCTION_TIMEOUT=1800000")
  endforeach()
endfunction()
