# RapidCheck (BSD-2-Clause), the property tests' generator, shrinker and state
# machine runner (tests/prop). Only the tests link it; nothing ships it.
#
# Include once per project, then link `rapidcheck`.

include(FetchContent)

# master, 2026-10-05
set(HAL_C2_RAPIDCHECK_REVISION 2c3c4365aca21ef4e612768fdc95b1ce8b39a651)

set(RC_ENABLE_TESTS OFF CACHE BOOL "" FORCE)
set(RC_ENABLE_EXAMPLES OFF CACHE BOOL "" FORCE)
FetchContent_Declare(rapidcheck
  GIT_REPOSITORY https://github.com/emil-e/rapidcheck.git
  GIT_TAG ${HAL_C2_RAPIDCHECK_REVISION}
)
FetchContent_MakeAvailable(rapidcheck)

