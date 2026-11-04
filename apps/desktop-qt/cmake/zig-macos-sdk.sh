#!/usr/bin/env bash
# Runs a command that runs Zig 0.15 (`zig-macos-sdk.sh zig build ...`) so Zig
# can link on Apple silicon Macs with the SDKs Apple ships since late 2026.
#
# Their libSystem stubs (usr/lib/libSystem.B.tbd and usr/lib/system/*.tbd)
# name only arm64e-macos, and Zig 0.15 looks for arm64-macos, so every native
# link fails with undefined _abort, _exit and the rest, the build runner of
# `zig build` first. Ghostty's build takes Zig 0.15 only, and 0.15.2 is the
# last of it.
#
# When the SDK xcrun names lacks arm64-macos, this builds an overlay of a
# macOS 26 SDK whose libSystem stubs also name arm64-macos (everything else is
# a symlink into the real SDK), and runs the command with an xcrun on PATH
# that names the overlay, which is how Zig finds the SDK. A 26 SDK because
# Zig 0.15's libc++ cannot read the macOS 27 headers (INFINITY goes
# undeclared). The overlay is removed when the command exits.
#
# Anywhere else, or with an SDK Zig can read, it runs the command as it is.

set -euo pipefail

[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || exec "$@"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
# The stub's own targets, the first `targets: [...]`; symbol groups further
# down may name arm64-macos when the stub does not.
stub_targets() { awk '/^targets:/ { on = 1 } on { print } on && /]/ { exit }' "$1"; }
stub_targets "${sdk}/usr/lib/libSystem.B.tbd" | grep -q 'arm64-macos' && exec "$@"

base=""
for candidate in \
  "$(xcode-select -p)/Platforms/MacOSX.platform/Developer/SDKs"/MacOSX26*.sdk \
  /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk; do
  # MacOSX26.sdk is a symlink to the versioned one.
  [[ -d "${candidate}" && ! -L "${candidate}" ]] || continue
  [[ -z "${base}" || "$(basename "${candidate}")" > "$(basename "${base}")" ]] && base="${candidate}"
done
if [[ -z "${base}" ]]; then
  printf '[zig-macos-sdk] error: Zig 0.15 cannot link with %s and no macOS 26 SDK is installed to stand in;\n' "${sdk}" >&2
  printf '[zig-macos-sdk] install the macOS 26 Command Line Tools, or set HAL_C2_GHOSTTY_VT_LIBRARY to a prebuilt libghostty-vt.a\n' >&2
  exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/zig-macos-sdk.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
overlay="${work}/MacOSX.sdk"

# Links every entry of $1 into $2 except the names after them.
link_except() {
  local from="$1" to="$2" entry
  shift 2
  mkdir -p "${to}"
  for entry in "${from}"/*; do
    [[ " $* " == *" $(basename "${entry}") "* ]] || ln -s "${entry}" "${to}/"
  done
}
link_except "${base}" "${overlay}" usr
link_except "${base}/usr" "${overlay}/usr" lib
link_except "${base}/usr/lib" "${overlay}/usr/lib" libSystem.B.tbd libSystem.tbd system
mkdir -p "${overlay}/usr/lib/system"
for stub in "${base}/usr/lib"/libSystem.B.tbd "${base}/usr/lib"/libSystem.tbd "${base}/usr/lib/system"/*; do
  target="${overlay}/usr/lib/${stub#"${base}/usr/lib/"}"
  if [[ -L "${stub}" ]]; then
    cp -P "${stub}" "${target}" # relative, so it names the patched copy
  elif [[ "${stub}" == *.tbd ]]; then
    sed -E 's/(^|[^-[:alnum:]_])arm64e-macos/\1arm64-macos, arm64e-macos/g' "${stub}" > "${target}"
  else
    ln -s "${stub}" "${target}"
  fi
done

mkdir -p "${work}/bin"
cat > "${work}/bin/xcrun" <<EOF
#!/bin/sh
case " \$* " in *" --show-sdk-path "*) echo "${overlay}"; exit 0 ;; esac
exec /usr/bin/xcrun "\$@"
EOF
chmod +x "${work}/bin/xcrun"

printf '[zig-macos-sdk] Zig 0.15 cannot link with %s; using %s with arm64-macos stubs\n' "${sdk}" "${base}" >&2
PATH="${work}/bin:${PATH}" "$@"
