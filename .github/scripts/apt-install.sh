#!/usr/bin/env bash
# Installs apt packages for a CI step: `apt-install.sh <deb-dir> <package>...`, run by
# .github/actions/apt-install, which keeps <deb-dir> in the Actions cache.
# The Ubuntu mirrors have stalled on plain HTTP for whole runs, Azure's and the main
# archive alike, while HTTPS hosts answered (#1535). So the packages install from the
# cached .debs without the network, and only a cold or stale cache downloads them, over
# HTTPS, in bounded attempts. Writes `fetched=true` to $GITHUB_OUTPUT when it downloaded
# them, for the action to save under a fresh key.
# At most 510s with every kill grace, so the steps' `timeout-minutes: 10` only fires if
# this script itself hangs.
set -uo pipefail

debs=$1
shift

installed() {
  # shellcheck disable=SC2016 # ${Status} is dpkg-query's field, not a shell variable.
  [ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" = "install ok installed" ]
}
missing() {
  missing=()
  for package in "$@"; do installed "$package" || missing+=("$package"); done
}
install_debs() {
  [ $# -gt 0 ] && timeout -k 10 60 sudo dpkg -i "$@"
}

missing "$@"
if [ ${#missing[@]} -eq 0 ]; then
  echo "Already installed: $*"
  exit 0
fi

if compgen -G "$debs/*.deb" >/dev/null; then
  # Only what the cached .debs add to the image: a package the image already has may be
  # newer there than in the cache. Also what to take back out if they don't install.
  added=() fresh=()
  for deb in "$debs"/*.deb; do
    package=$(dpkg-deb -f "$deb" Package) && ! installed "$package" &&
      added+=("$package") fresh+=("$deb")
  done
  if install_debs "${fresh[@]}"; then
    missing "$@"
    [ ${#missing[@]} -eq 0 ] && exit 0
  fi
  # A failed `dpkg -i` leaves its packages unpacked, which apt counts as present, so a
  # download would skip them and the fresh cache entry would lack them. Purged, the
  # image is back as it was, and the download fetches what a cold cache would.
  echo "::warning::The cached .debs didn't install, downloading them again"
  [ ${#added[@]} -eq 0 ] || timeout -k 10 30 sudo dpkg --purge --force-depends "${added[@]}"
  rm -f "$debs"/*.deb
  missing "$@"
fi

apt=(sudo DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)

# Every Ubuntu mirror serves HTTPS, so every source naming one over HTTP, the runner's
# mirror list (apt-mirrors.txt, read through `mirror+file:`) included, switches to it.
sudo grep -rlZ 'http://[a-z.]*ubuntu\.com/' \
  /etc/apt/apt-mirrors.txt /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null |
  xargs -0r sudo sed -i 's|http://\([a-z.]*ubuntu\.com\)/|https://\1/|g'

# Only what is missing, dependencies included, into <deb-dir>, for install_debs.
mkdir -p "$debs/partial"
fetch() {
  timeout -k 10 75 "${apt[@]}" update &&
    timeout -k 10 45 "${apt[@]}" install -y --fix-broken --download-only \
      -o Dir::Cache::Archives="$debs" "${missing[@]}"
}

fetch || {
  echo "::warning::apt-get failed or timed out, retrying in 10s"
  sleep 10
  fetch
} || exit 1
sudo rm -rf "$debs/partial" "$debs/lock"
install_debs "$debs"/*.deb
# Configures whatever an install left unpacked, then holds it to every package asked for.
timeout -k 10 30 sudo dpkg --configure -a
missing "$@"
if [ ${#missing[@]} -ne 0 ]; then
  echo "::error::Not installed: ${missing[*]}"
  exit 1
fi
[ -z "${GITHUB_OUTPUT:-}" ] || echo "fetched=true" >>"$GITHUB_OUTPUT"
