# hal_c2_check_qmldir(<module files...>): call beside a qt_add_qml_module with
# NO_GENERATE_QMLDIR, passing its QML_FILES and RESOURCES. A hand-written qmldir
# can name a file the module never compiles in; a dev build still finds it on
# disk, but a release build loads the module from qrc only, where the type is
# "unavailable". So every .qml or .js file the qmldir names must be listed.
function(hal_c2_check_qmldir)
  file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/qmldir" _lines)
  set(_missing)
  foreach(_line IN LISTS _lines)
    if(_line MATCHES "([^ \t]+\\.(qml|js))[ \t]*$" AND NOT CMAKE_MATCH_1 IN_LIST ARGN)
      list(APPEND _missing "${CMAKE_MATCH_1}")
    endif()
  endforeach()
  if(_missing)
    list(JOIN _missing ", " _missing)
    message(FATAL_ERROR "${CMAKE_CURRENT_SOURCE_DIR}/qmldir names files the module does not compile in: ${_missing}")
  endif()
endfunction()
