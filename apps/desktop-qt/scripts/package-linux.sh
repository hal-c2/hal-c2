#!/usr/bin/env bash
# Builds an AppImage from a Release build directory with linuxdeploy and its
# Qt plugin (downloaded on first use). Usage: package-linux.sh <build-dir>
set -euo pipefail

build_dir="${1:?build directory}"
app_dir="${build_dir}/AppDir"
tools_dir="${build_dir}/tools"
mkdir -p "${tools_dir}"

fetch() {
  local url="$1" out="$2" digest="$3"
  if [ ! -f "${out}" ]; then
    curl -fsSL "${url}" -o "${out}"
  fi
  printf '%s  %s\n' "${digest}" "${out}" | sha256sum --check --status
  chmod +x "${out}"
}
fetch "https://github.com/linuxdeploy/linuxdeploy/releases/download/1-alpha-20251107-1/linuxdeploy-x86_64.AppImage" "${tools_dir}/linuxdeploy-1-alpha-20251107-1" "c20cd71e3a4e3b80c3483cef793cda3f4e990aca14014d23c544ca3ce1270b4d"
fetch "https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/1-alpha-20250213-1/linuxdeploy-plugin-qt-x86_64.AppImage" "${tools_dir}/linuxdeploy-plugin-qt" "15106be885c1c48a021198e7e1e9a48ce9d02a86dd0a1848f00bdbf3c1c92724"

rm -rf "${app_dir}"
cmake --install "${build_dir}" --prefix "${app_dir}/usr"

# Desktop entry + icon: the app id (hal-c2) must match what the shell sets so
# compositor rules can target the window.
mkdir -p "${app_dir}/usr/share/applications" "${app_dir}/usr/share/icons/hicolor/1024x1024/apps"
cat > "${app_dir}/usr/share/applications/hal-c2.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=HAL-C2
Exec=hal-c2-qt
Icon=hal-c2
Categories=Development;
StartupWMClass=hal-c2
DESKTOP
icon_source="$(dirname "$0")/../../../assets/prod/black-universal-1024.png"
cp "${icon_source}" "${app_dir}/usr/share/icons/hicolor/1024x1024/apps/hal-c2.png"

node "$(dirname "$0")/stage-runtime.mjs" "${app_dir}/usr/share/hal-c2"

# The app opens SQLite and no other database, but linuxdeploy's Qt plugin bundles
# every SQL driver of the Qt it finds and stops at the first whose client library is
# not installed. A Qt from its installer ships Mimer's, ODBC's, PostgreSQL's and
# MySQL's, and a distribution's may have Firebird's. In a Qt this user can write to
# they are set aside while it runs and put back when this script ends. Any other Qt
# (a distribution's) is shown to the plugin through a qmake that names a plugin
# directory with the same contents, apart from the SQL drivers.
qmake="${QMAKE:-$(command -v qmake6 || command -v qmake || true)}"
plugins=""
if [ -n "${qmake}" ]; then
  plugins="$("${qmake}" -query QT_INSTALL_PLUGINS 2>/dev/null || true)"
fi
drivers="${plugins}/sqldrivers"
set_aside="${build_dir}/sqldrivers-set-aside"
restore_drivers() {
  [ -d "${set_aside}" ] || return 0
  find "${set_aside}" -name '*.so' -exec mv {} "${drivers}/" \;
  rmdir "${set_aside}"
}
trap restore_drivers EXIT
# What a run that was cut short left behind.
restore_drivers
if [ -d "${drivers}" ] && [ -w "${drivers}" ]; then
  mkdir -p "${set_aside}"
  find "${drivers}" -maxdepth 1 -name '*.so' ! -name 'libqsqlite.so' -exec mv {} "${set_aside}/" \;
elif [ -d "${drivers}" ]; then
  # Absolute: the plugin runs qmake from where it likes.
  wrapper="$(cd "${build_dir}" && pwd)/qmake-sqlite-only"
  view="$(cd "${build_dir}" && pwd)/qt-plugins"
  rm -rf "${view}"
  mkdir -p "${view}/sqldrivers"
  for entry in "${plugins}"/*; do
    [ "${entry}" = "${drivers}" ] || ln -s "${entry}" "${view}/"
  done
  cp "${drivers}/libqsqlite.so" "${view}/sqldrivers/"
  cat > "${wrapper}" <<QMAKE
#!/bin/sh
"${qmake}" "\$@" | sed "s|^QT_INSTALL_PLUGINS:.*|QT_INSTALL_PLUGINS:${view}|"
QMAKE
  chmod +x "${wrapper}"
  export QMAKE="${wrapper}"
fi

export QML_SOURCES_PATHS="$(cd "$(dirname "$0")/.." && pwd)/qml"
export OUTPUT="${build_dir}/hal-c2-qt-x86_64.AppImage"
"${tools_dir}/linuxdeploy-1-alpha-20251107-1" --appdir "${app_dir}" --plugin qt --output appimage
echo "AppImage at ${OUTPUT}"
