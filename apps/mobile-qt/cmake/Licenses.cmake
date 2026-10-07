# The open source notices a package carries: the manifest Settings → Open
# source licenses reads (LicensesController), compiled into the binary as
# :/hal-c2/licenses/third-party-licenses.json, where MobileApp points the page.
# The desktop stages the file beside its runtime; an APK has no such place.
#
# The manifest is written when the app is built, by the script that writes
# the desktop's (apps/desktop-qt/scripts/third-party-licenses.ts --mobile),
# from the notices tagged `mobile-qt` in third-party-licenses.config.json, so
# nothing generated is committed. That takes the repo's Node and nothing
# installed with it. A license text it has not used before is fetched from
# SPDX's repository on GitHub into .generated/ at the repo's root.
#
# Include once, then call for the target that is packaged.

function(hal_c2_target_licenses target)
  get_filename_component(_repo "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../../.." ABSOLUTE)
  set(_script "${_repo}/apps/desktop-qt/scripts/third-party-licenses.ts")

  find_program(HAL_C2_NODE node DOC "The Node that writes the open source notices")
  set(_node_version "")
  set(_node_found "no node is on PATH")
  if(HAL_C2_NODE)
    execute_process(COMMAND "${HAL_C2_NODE}" --version OUTPUT_VARIABLE _node_version OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
    string(REGEX REPLACE "^v" "" _node_version "${_node_version}")
    set(_node_found "${HAL_C2_NODE} is ${_node_version}")
  endif()
  # The script is TypeScript run as it is, and asks whether it is the entry
  # point, which Node answers from 24.2.
  if(NOT _node_version OR _node_version VERSION_LESS 24.2)
    message(FATAL_ERROR "The package's open source notices are written by Node 24 or later (${_script}), and "
      "${_node_found}; `mise install` at the repo's root installs the one the repo uses")
  endif()

  set(_dir "${CMAKE_CURRENT_BINARY_DIR}/licenses")
  set(_manifest "${_dir}/third-party-licenses.json")
  add_custom_command(
    OUTPUT "${_manifest}"
    COMMAND "${HAL_C2_NODE}" "${_script}" "${_manifest}" --mobile
    DEPENDS
      "${_script}"
      "${_repo}/scripts/lib/third-party-licenses.ts"
      "${_repo}/third-party-licenses.config.json"
      "${_repo}/native/libghostty-vt/LICENSE"
    COMMENT "Writing the open source notices"
    VERBATIM
  )
  qt_add_resources(${target} hal_c2_licenses PREFIX "/hal-c2/licenses" BASE "${_dir}" FILES "${_manifest}")
endfunction()
