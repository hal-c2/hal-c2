#!/usr/bin/env bash
# Runs one test executable under Memcheck: `memcheck.sh <exe> [args...]`. It is
# CMAKE_TEST_LAUNCHER of the `mise prop:valgrind` build and fit for any other test
# runner (the fuzz targets) that wants the same flags and qt.supp.
#
#   HAL_C2_VALGRIND_LOGS   where <exe>.log goes (default $TMPDIR/hal-c2-valgrind)
#   HAL_C2_VALGRIND_FLAGS  extra valgrind flags, e.g. --gen-suppressions=all
#   HAL_C2_TEST_TIME_SCALE multiplier for the tests' wait deadlines (native/features/
#                          TestTime.h), 20 here unless set, as Memcheck is 10-50x slower
#   HAL_C2_VALGRIND_LD     a glibc ld.so to run the test with when the system's is
#                          stripped ("Fatal error at startup ... memcmp") and its
#                          debuginfo cannot be fetched: unpack a glibc and its
#                          glibc-debug package of the same version into a scratch
#                          directory, point this at its usr/lib/ld-linux-x86-64.so.2
#                          and add --extra-debuginfo-path=<scratch>/usr/lib/debug
#                          to HAL_C2_VALGRIND_FLAGS. Its libc then also serves Qt.
#
# Exits 97 when Memcheck reports an error (a definite or indirect leak counts),
# else with the test's own status.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exe=$1
shift
# PCRE2's JIT code has no unwind info and reads past its subject, which Memcheck
# reports as uninitialised jumps under two nameless frames; the interpreter is exact.
export QT_ENABLE_REGEXP_JIT=0
export HAL_C2_TEST_TIME_SCALE=${HAL_C2_TEST_TIME_SCALE:-20}
logs=${HAL_C2_VALGRIND_LOGS:-${TMPDIR:-/tmp}/hal-c2-valgrind}
mkdir -p "$logs"
log=$logs/$(basename "$exe").log
rm -f "$log"
loader=()
[[ -z ${HAL_C2_VALGRIND_LD:-} ]] || loader=("$HAL_C2_VALGRIND_LD" --library-path "$(dirname "$HAL_C2_VALGRIND_LD")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}")
# shellcheck disable=SC2086
valgrind --tool=memcheck \
  --leak-check=full --show-leak-kinds=definite,indirect --errors-for-leak-kinds=definite,indirect \
  --track-origins=yes --num-callers=40 --error-exitcode=97 \
  --suppressions="$here/qt.supp" --log-file="$log" ${HAL_C2_VALGRIND_FLAGS:-} \
  ${loader[@]+"${loader[@]}"} "$exe" "$@"
status=$?
if grep -q 'Fatal error at startup' "$log" 2>/dev/null; then
  echo "memcheck: valgrind cannot start here (stripped ld.so, see HAL_C2_VALGRIND_LD in $0), log $log" >&2
elif ((status == 97)); then
  echo "memcheck: $(basename "$exe") has errors, full report in $log" >&2
  # The first errors with their stacks, then the totals.
  { sed -n '/^==[0-9]*== Parent PID/,/^==[0-9]*== HEAP SUMMARY/p' "$log" | grep -v 'Parent PID\|HEAP SUMMARY' | head -60
    grep -E 'ERROR SUMMARY|(definitely|indirectly) lost' "$log"; } | sed 's/^==[0-9]*== /  /' >&2
fi
exit "$status"
