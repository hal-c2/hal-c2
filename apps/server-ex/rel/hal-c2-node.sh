#!/bin/sh
# The HAL-C2 node @VERSION@ in one file: this script, then the release bundle
# (`mix hal_c2.bundle` appends it). The first run unpacks the release into the node's
# data directory; every run then starts bin/hal-c2-service there with the given
# arguments (`install`, `status`, `restart` and `uninstall` manage the background
# service). Versions the node upgrades itself to are installed in the same place, so
# running this file again starts whatever version the node last moved to.
set -eu
version="@VERSION@"
erts="@ERTS@"

@DATA_DIR@

root="$hal_c2_data/release"
if [ ! -d "$root/releases/$version" ]; then
  mkdir -p "$hal_c2_data"
  tmp="$(mktemp -d "$hal_c2_data/.release.XXXXXX")"
  tail -n +@PAYLOAD_LINE@ "$0" | tar -xzf - -C "$tmp"
  mkdir -p "$root/bin" "$root/lib" "$root/releases"
  # Versioned directories never change once written; only missing ones move in. Every
  # file lands by rename and the release directory moves in last, as the mark of a
  # finished install, so an interrupted unpack runs again.
  for dir in "$tmp"/lib/* "$tmp"/erts-*; do
    target="$root/${dir#"$tmp"/}"
    [ -e "$target" ] || mv "$dir" "$target"
  done
  for file in "$tmp"/bin/*; do mv -f "$file" "$root/bin/"; done
  if [ ! -f "$root/releases/COOKIE" ]; then
    (umask 077 && od -An -N32 -tx1 /dev/urandom | tr -d ' \n' >"$tmp/COOKIE")
    mv "$tmp/COOKIE" "$root/releases/COOKIE"
  fi
  printf '%s %s\n' "$erts" "$version" >"$tmp/start_erl.data"
  mv -f "$tmp/start_erl.data" "$root/releases/start_erl.data"
  mv "$tmp/releases/$version" "$root/releases/$version"
  rm -rf "$tmp"
fi
exec "$root/bin/hal-c2-service" "$@"
