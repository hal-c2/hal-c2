#!/usr/bin/env bash
# The Qt desktop in a headless sandbox that cua-driver (https://cua.ai) drives: its own sway
# with XWayland, its own session bus and AT-SPI registry, a scratch MC and a scratch app home.
# The user's display, bus and HAL-C2 files are never touched. Linux only.
#
#   cua-sandbox.sh start [--seed <hal-c2.sqlite>] [--url <pairing link>] [<hal-c2-qt args>]
#   cua-sandbox.sh call <tool> [<json>]
#   cua-sandbox.sh stop
#
# start brings up what is not running and (re)launches the app, so it also picks up a QML
# change. --seed snapshots an MC database (read-only) into a fresh scratch MC, which takes no
# automatic action (turns nobody sent, boot pulls), since a seeded project is a real checkout;
# --url attaches to another MC instead. call fills in the app's pid, a shared session label and foreground
# delivery where the tool takes them. Files go under HAL_C2_CUA_HOME, default
# <checkout>/.hal-c2/cua.
set -euo pipefail

root="$(cd "$(dirname "$0")/../../.." && pwd)"
home="${HAL_C2_CUA_HOME:-$root/.hal-c2/cua}"
# Socket paths have a short length limit: they go in the user's runtime dir, keyed by home.
runtime="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
[[ -d $runtime ]] || runtime=/tmp
run="$runtime/hal-c2-cua-$(printf %s "$home" | cksum | cut -d' ' -f1)"
session=hal-c2

die() {
  echo "desktop:cua: $*" >&2
  exit 1
}

# A pid is recorded with its start time, so a stale file never names another process.
track() { echo "$1 $(sed 's/.*) //' "/proc/$1/stat" | cut -d' ' -f20)" > "$home/$2.pid"; }
pid_of() {
  local pid start
  read -r pid start 2> /dev/null < "$home/$1.pid" || return 1
  [[ $(sed 's/.*) //' "/proc/$pid/stat" 2> /dev/null | cut -d' ' -f20) == "$start" ]] && echo "$pid"
}
stop_one() {
  local pid
  if pid=$(pid_of "$1"); then
    kill "$pid"
    for _ in $(seq 100); do
      pid_of "$1" > /dev/null || break
      sleep 0.1
    done
  fi
  rm -f "$home/$1.pid"
}

# wait_for <seconds> <what> <command...>: until the command succeeds.
wait_for() {
  local deadline=$((SECONDS + $1)) what=$2
  shift 2
  until "$@"; do
    ((SECONDS < deadline)) || die "timed out waiting for $what"
    sleep 0.2
  done
}

sandbox_env=()
load_sandbox() {
  [[ -s $home/display && -s $home/bus ]] || die "the sandbox is not running: mise run desktop:cua"
  sandbox_env=(env -u WAYLAND_DISPLAY -u SWAYSOCK -u AT_SPI_BUS_ADDRESS -u HYPRLAND_INSTANCE_SIGNATURE
    DISPLAY="$(< "$home/display")" XDG_RUNTIME_DIR="$run" DBUS_SESSION_BUS_ADDRESS="$(< "$home/bus")"
    CUA_DRIVER_RS_HOME="$home/cua" CUA_DRIVER_RS_TELEMETRY_ENABLED=0 CUA_DRIVER_RS_UPDATE_CHECK=0)
}

start_sway() {
  if pid_of sway > /dev/null; then
    load_sandbox
    return
  fi
  command -v sway > /dev/null || die "needs sway, with Xwayland, for the headless display"
  command -v dbus-run-session > /dev/null || die "needs dbus-run-session (dbus)"
  # What ran on a previous sandbox's display and bus goes with it.
  stop_one app
  stop_one cua
  stop_one registry
  mkdir -p "$run" && chmod 700 "$run"
  rm -f "$home/display" "$home/bus" "$home/sway.raw"
  cat > "$home/sway.config" << EOF
output HEADLESS-1 resolution 1600x1000
default_border none
xwayland enable
exec printenv DISPLAY > "$home/display"
EOF
  # shellcheck disable=SC2016 # expanded by the sandbox's shell
  (cd "$home" && exec env -u WAYLAND_DISPLAY -u DISPLAY -u SWAYSOCK -u DBUS_SESSION_BUS_ADDRESS \
    XDG_RUNTIME_DIR="$run" WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
    setsid dbus-run-session -- sh -c 'echo "$DBUS_SESSION_BUS_ADDRESS" > bus; echo $$ > sway.raw; exec sway -c sway.config' \
    > "$home/sway.log" 2>&1) &
  wait_for 20 "sway (see $home/sway.log)" test -s "$home/sway.raw"
  track "$(< "$home/sway.raw")" sway
  # Xwayland needs a free display and room in /tmp for its lock file.
  wait_for 20 "Xwayland (see $home/sway.log; mise run desktop:cua:stop cleans up)" test -s "$home/display"
  load_sandbox
}

start_registry() {
  pid_of registry > /dev/null && return
  local bin
  for bin in /usr/lib/at-spi2-registryd /usr/libexec/at-spi2-registryd /usr/lib/at-spi2-core/at-spi2-registryd /usr/lib/*/at-spi2-registryd; do
    [[ -x $bin ]] && break
  done
  [[ -x $bin ]] || die "needs at-spi2-core (at-spi2-registryd) for the accessibility tree"
  # Its D-Bus activation goes through systemd, which the private bus cannot reach.
  "${sandbox_env[@]}" setsid "$bin" --use-gnome-session=false > "$home/registry.log" 2>&1 &
  track $! registry
}

mc_up() {
  pid_of mc > /dev/null || die "the MC quit; see $home/mc.log"
  ss -H -ltn "sport = :$(< "$home/mc.port")" | grep -q .
}
start_mc() {
  if pid_of mc > /dev/null; then
    [[ -z $seed ]] || die "--seed needs a fresh MC: mise run desktop:cua:stop first"
    return
  fi
  local port=3890
  while ss -H -ltn "sport = :$port" | grep -q .; do port=$((port + 1)); done
  echo "$port" > "$home/mc.port"
  if [[ -n $seed ]]; then
    command -v sqlite3 > /dev/null || die "--seed needs sqlite3"
    rm -rf "$home/mc" && mkdir -p "$home/mc/data"
    sqlite3 -readonly "$seed" "VACUUM INTO '$home/mc/data/hal-c2.sqlite'"
  fi
  (cd "$root/apps/server-ex" && HAL_C2_MC_HOME="$home/mc" HAL_C2_MC_PORT="$port" HAL_C2_MC_NO_AUTO_ACTIONS=1 exec setsid mix hal_c2.server > "$home/mc.log" 2>&1) &
  track $! mc
  wait_for 300 "the MC on port $port" mc_up
}
pairing_link() {
  local port
  port=$(< "$home/mc.port")
  (cd "$root/apps/server-ex" && HAL_C2_MC_HOME="$home/mc" HAL_C2_MC_PORT="$port" mix hal_c2.pair "http://127.0.0.1:$port") | grep -E '^https?://' | tail -1
}

start_cua() {
  pid_of cua > /dev/null && return
  command -v cua-driver > /dev/null || die "needs cua-driver on the PATH: https://cua.ai"
  rm -f "$run/cua.sock"
  "${sandbox_env[@]}" setsid cua-driver serve --socket "$run/cua.sock" > "$home/cua.log" 2>&1 &
  track $! cua
  wait_for 20 "cua-driver (see $home/cua.log)" test -S "$run/cua.sock"
  # Its agent cursor is a window over the whole screen that takes the clicks meant for the app.
  "${sandbox_env[@]}" cua-driver call --socket "$run/cua.sock" set_agent_cursor_enabled \
    "{\"session\":\"$session\",\"enabled\":false}" > /dev/null
}

app_window() {
  local pid
  pid=$(pid_of app) || die "the app quit; see $home/app.log"
  "${sandbox_env[@]}" cua-driver call --socket "$run/cua.sock" list_windows "{\"session\":\"$session\"}" 2> /dev/null |
    grep -qE "\"pid\": *${pid}[^0-9]"
}
start_app() {
  stop_one app
  local binary="${HAL_C2_DESKTOP_BINARY:-}"
  if [[ -z $binary ]]; then
    for binary in "$root/apps/desktop-qt/build/debug/hal-c2-qt" "$root/apps/desktop-qt/build/release/hal-c2-qt"; do
      [[ -x $binary ]] && break
    done
  fi
  [[ -x $binary ]] || die "the desktop app is not built: mise run desktop:build, or set HAL_C2_DESKTOP_BINARY"
  local link=$url
  [[ -n $link ]] || link=$(pairing_link)
  [[ -n $link ]] || die "the scratch MC gave no pairing link; see $home/mc.log"
  mkdir -p "$home/app"
  # xcb, through XWayland: cua-driver's input and capture are X11's. The bridge is
  # off unless something asks for it, and nothing on the private bus does.
  "${sandbox_env[@]}" QT_QPA_PLATFORM=xcb QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1 QT_FORCE_STDERR_LOGGING=1 HAL_C2_HOME="$home/app" \
    setsid "$binary" --home-dir "$home/app" --url "$link" "${app_args[@]}" > "$home/app.log" 2>&1 &
  track $! app
  wait_for 60 "the app's window (see $home/app.log)" app_window
}

start() {
  seed="" url="" app_args=()
  while (($#)); do
    case $1 in
      --seed) seed=$2 && shift ;;
      --seed=*) seed=${1#--seed=} ;;
      --url) url=$2 && shift ;;
      --url=*) url=${1#--url=} ;;
      --) ;;
      *) app_args+=("$1") ;;
    esac
    shift
  done
  [[ $(uname -s) == Linux ]] || die "runs on Linux only"
  [[ -z $seed || -r $seed ]] || die "cannot read $seed"
  mkdir -p "$home"
  start_sway
  start_registry
  [[ -n $url ]] || start_mc
  start_cua
  start_app
  cat << EOF
hal-c2-qt (pid $(pid_of app)) is up in the sandbox. Drive it with, for example:
  mise run desktop:cua:call get_window_state '{"screenshot_out_file":"$home/shot.png"}'
  mise run desktop:cua:call scroll '{"x":700,"y":400,"direction":"up","amount":1}'
Logs and state are in $home. mise run desktop:cua:stop ends it.
EOF
}

# Adds "key":value to the json object unless it has the key or the tool does not take it.
with() {
  [[ $json == *"\"$1\""* || $schema != *"\"$1\""* ]] && return
  if [[ $json =~ ^[[:space:]]*\{[[:space:]]*\}[[:space:]]*$ ]]; then
    json="{\"$1\":$2}"
  else
    json="{\"$1\":$2,${json#*\{}"
  fi
}
call() {
  (($#)) || die "usage: mise run desktop:cua:call <tool> [<json>]   (cua-driver list-tools names them)"
  pid_of cua > /dev/null || die "the sandbox is not running: mise run desktop:cua"
  load_sandbox
  local tool=$1 app
  json=${2:-'{}'}
  schema=$(cua-driver describe "$tool") || exit
  # Screenshot-relative coordinates need the session the screenshot was taken in.
  with session "\"$session\""
  app=$(pid_of app) && with pid "$app"
  # Background delivery (XInput2 on a second master pointer) crashes Qt's xcb plugin.
  with delivery_mode '"foreground"'
  exec "${sandbox_env[@]}" cua-driver call --socket "$run/cua.sock" "$tool" "$json"
}

stop() {
  for part in app cua registry mc sway; do stop_one "$part"; done
  rm -f "$home/display" "$home/bus"
  rm -rf "$run"
}

case ${1:-} in
  start | call | stop)
    verb=$1
    shift
    "$verb" "$@"
    ;;
  *) die "usage: cua-sandbox.sh start|call|stop" ;;
esac
