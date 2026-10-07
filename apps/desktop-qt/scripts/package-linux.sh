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
# MySQL's, and a distribution's may have Firebird's. So the plugin is shown the Qt
# through a qmake that names a plugin directory with the same contents apart from
# the SQL drivers, of which it holds SQLite's alone. The Qt itself is left as it is.
qmake="${QMAKE:-$(command -v qmake6 || command -v qmake || true)}"
if [ -z "${qmake}" ]; then
  echo "error: no qmake6 or qmake on the PATH; set QMAKE to the Qt's" >&2
  exit 1
fi
plugins="$("${qmake}" -query QT_INSTALL_PLUGINS)"
drivers="${plugins}/sqldrivers"
# Loaded at run time, so nothing else notices it missing: the app would start and
# fail to open its cache.
if [ ! -f "${drivers}/libqsqlite.so" ]; then
  echo "error: ${drivers} has no libqsqlite.so; install the Qt's SQLite driver" >&2
  exit 1
fi
# Absolute: the plugin runs qmake from where it likes.
wrapper="$(cd "${build_dir}" && pwd)/qmake-sqlite-only"
view="$(cd "${build_dir}" && pwd)/qt-plugins"
rm -rf "${view}"
mkdir -p "${view}/sqldrivers"
for entry in "${plugins}"/*; do
  [ "${entry}" = "${drivers}" ] || ln -s "${entry}" "${view}/"
done
cp "${drivers}/libqsqlite.so" "${view}/sqldrivers/"
# Both forms: every property (QT_INSTALL_PLUGINS:<path>), and one asked for by name.
# A qmake that fails fails the wrapper too.
cat > "${wrapper}" <<QMAKE
#!/bin/sh
out="\$("${qmake}" "\$@")" || exit \$?
printf '%s\n' "\$out" | sed -e "s|^QT_INSTALL_PLUGINS:.*|QT_INSTALL_PLUGINS:${view}|" -e "s|^${plugins}\\\$|${view}|"
QMAKE
chmod +x "${wrapper}"
export QMAKE="${wrapper}"

# The app's own QML modules are compiled into the binary. The plugin's import scanner
# is told where they were built so that it can follow their imports of Qt's modules,
# and what it then copies of them (their build directories) is taken out again
# before the image is made: a copy on disk could be loaded in place of the binary's.
export QML_MODULES_PATHS="$(cd "${build_dir}" && pwd)/qml"
export QML_SOURCES_PATHS="$(cd "$(dirname "$0")/.." && pwd)/qml"
# The plugin bundles only xcb by default, which leaves a Wayland session running
# the app through XWayland. It takes the Wayland platform plugin when asked (one
# libqwayland.so since Qt 6.10, an EGL and a generic one before), but not the
# plugins that one cannot start without (it looks for the names they had before
# Qt 6.8), so those are copied in after it: the xdg shell, EGL, and the decorations
# drawn when the compositor draws none.
wayland=""
for name in libqwayland.so libqwayland-egl.so libqwayland-generic.so; do
  [ -f "${plugins}/platforms/${name}" ] && wayland="${wayland:+${wayland};}${name}"
done
export EXTRA_PLATFORM_PLUGINS="${wayland}"
"${tools_dir}/linuxdeploy-1-alpha-20251107-1" --appdir "${app_dir}" --plugin qt
rm -rf "${app_dir}/usr/qml/HalC2" "${app_dir}/usr/qml/Ghostty"
for plugin in wayland-shell-integration/libxdg-shell.so \
  wayland-graphics-integration-client/libqt-plugin-wayland-egl.so \
  wayland-decoration-client/libbradient.so; do
  mkdir -p "${app_dir}/usr/plugins/$(dirname "${plugin}")"
  cp "${plugins}/${plugin}" "${app_dir}/usr/plugins/${plugin}"
done
"${tools_dir}/linuxdeploy-1-alpha-20251107-1" --appdir "${app_dir}" \
  --deploy-deps-only "${app_dir}/usr/plugins/wayland-shell-integration" \
  --deploy-deps-only "${app_dir}/usr/plugins/wayland-graphics-integration-client" \
  --deploy-deps-only "${app_dir}/usr/plugins/wayland-decoration-client"
export LDAI_OUTPUT="${build_dir}/hal-c2-qt-x86_64.AppImage"
"${tools_dir}/linuxdeploy-1-alpha-20251107-1" --appdir "${app_dir}" --output appimage
echo "AppImage at ${LDAI_OUTPUT}"
