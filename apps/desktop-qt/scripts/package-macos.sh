#!/usr/bin/env bash
# Builds a zipped app bundle from a Release build directory with macdeployqt.
# Usage: package-macos.sh <build-dir>
set -euo pipefail

build_dir="${1:?build directory}"
package_dir="${build_dir}/package"
app="${package_dir}/HAL-C2.app"

# macdeployqt rewrites the bundle it is given, so it gets a copy and the build
# directory's own stays as the linker left it.
rm -rf "${package_dir}"
cmake --install "${build_dir}" --prefix "${package_dir}"
mv "${package_dir}/hal-c2-qt.app" "${app}"

node "$(dirname "$0")/stage-runtime.mjs" "${app}/Contents/Resources/hal-c2"

# QT_ROOT_DIR is where CI's Qt is (install-qt-action); else the Qt qmake6 belongs to.
qt_bins="${QT_ROOT_DIR:+${QT_ROOT_DIR}/bin}"
qt_bins="${qt_bins:-$("${QMAKE:-qmake6}" -query QT_INSTALL_BINS)}"
"${qt_bins}/macdeployqt" "${app}" -qmldir="$(cd "$(dirname "$0")/.." && pwd)/qml"

# A Qt with every module installed (Homebrew's) has plugins for modules the app does
# not link (PDF, 3D, the virtual keyboard). macdeployqt copies those plugins without
# their frameworks, so they could never load; they are left out.
find "${app}/Contents/PlugIns" -name '*.dylib' | while read -r plugin; do
  for dep in $(otool -L "${plugin}" | awk 'NR > 1 && $1 ~ /^@rpath\// { print substr($1, 8) }'); do
    if [ ! -e "${app}/Contents/Frameworks/${dep}" ]; then
      rm "${plugin}"
      break
    fi
  done
done
# Each QML module links to its plugin; a link to one just removed fails the signature check.
find "${app}/Contents/Resources/qml" -type l ! -exec test -e {} \; -delete
# Apple silicon runs only signed code, and the bundle changed after macdeployqt signed it.
codesign --force --deep --sign - "${app}"

output="${build_dir}/hal-c2-qt-macos.zip"
rm -f "${output}"
ditto -c -k --keepParent "${app}" "${output}"
echo "App bundle zipped at ${output}"
