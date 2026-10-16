#!/usr/bin/env bash
# Stages desktop-qt's Bricks and this app's QML into one project directory
# (ljos does not follow symlinks), then runs `ljos check` or `ljos render` on it.
#   ljos.sh check
#   ljos.sh render [--out FILE] [--size WxH] [--settle MS]
# LJOS_BIN overrides the binary (default: the build under <root>/.hal-c2/ljos-target).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="$(cd "$here/../.." && pwd)"
ljos="${LJOS_BIN:-$root/.hal-c2/ljos-target/release/ljos}"
stage="$root/.hal-c2/desktop-ljos-stage"
[ -x "$ljos" ] || { echo "no ljos binary at $ljos (see apps/desktop-ljos/README.md)" >&2; exit 1; }

rm -rf "$stage"
mkdir -p "$stage/HalC2"
cp -R "$here/qml/." "$stage/"
cp -R "$root/apps/desktop-qt/qml/HalC2/Bricks" "$stage/HalC2/Bricks"

# Ljós routes a component's own children into its `default property alias`
# (`Item { id: body }` into body.data, itself), so ShellWindow, ShellCard,
# PluginSlot, SettingsPage and ModelPicker lose their body and the render is
# blank. Qt gives a component's own children to the base type. Until that is
# fixed in Ljós, the staged copy (never the source) drops `default` from those
# five; content placed in them then lands in the root instead of the body.
# LJOS_KEEP_DEFAULT_ALIAS=1 stages the files untouched.
if [ -z "${LJOS_KEEP_DEFAULT_ALIAS:-}" ]; then
  (cd "$stage/HalC2/Bricks" && perl -pi -e 's/^(\s*)default property alias (content|builtIn):/$1property alias $2:/' \
    ShellWindow.qml ShellCard.qml PluginSlot.qml SettingsPage.qml ModelPicker.qml)
fi

cmd="${1:?check or render}"
shift
case "$cmd" in
  check) exec "$ljos" check "$@" "$stage" ;;
  render)
    out="$root/.hal-c2/desktop-ljos.png"
    args=(--size 1280x800 --settle 1500)
    while [ $# -gt 0 ]; do
      case "$1" in
        --out) out="$2"; shift 2 ;;
        *) args+=("$1"); shift ;;
      esac
    done
    exec "$ljos" render --out "$out" --entry Main.qml "${args[@]}" "$stage"
    ;;
  *) echo "usage: ljos.sh check|render" >&2; exit 2 ;;
esac
