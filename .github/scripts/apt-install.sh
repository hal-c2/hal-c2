#!/usr/bin/env bash
# Installs apt packages for a CI step: `apt-install.sh <deb-dir> <package>...`, run by
# .github/actions/apt-install, which keeps <deb-dir> in the Actions cache.
# The Ubuntu mirrors have stalled on plain HTTP for whole runs, Azure's and the main
# archive alike, while HTTPS hosts answered (#1535). So the packages install from the
# cached .debs without the network, and only a cold cache downloads them, over HTTPS, in
# bounded attempts. Writes `fetched=true` to $GITHUB_OUTPUT when it downloaded them.
set -uo pipefail

debs=$1
shift

missing=()
for package in "$@"; do
  # shellcheck disable=SC2016 # ${Status} is dpkg-query's field, not a shell variable.
  [ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null)" = "install ok installed" ] ||
    missing+=("$package")
done
if [ ${#missing[@]} -eq 0 ]; then
  echo "Already installed: $*"
  exit 0
fi

install_debs() {
  compgen -G "$debs/*.deb" >/dev/null && timeout -k 10 90 sudo dpkg -i "$debs"/*.deb
}

if install_debs; then
  exit 0
elif compgen -G "$debs/*.deb" >/dev/null; then
  echo "::warning::The cached .debs didn't install, downloading them again"
  rm -f "$debs"/*.deb
fi

apt=(sudo DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)

# Every Ubuntu mirror serves HTTPS, so every source naming one over HTTP, the runner's
# mirror list (apt-mirrors.txt, read through `mirror+file:`) included, switches to it.
sudo grep -rlZ 'http://[a-z.]*ubuntu\.com/' \
  /etc/apt/apt-mirrors.txt /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null |
  xargs -0r sudo sed -i 's|http://\([a-z.]*ubuntu\.com\)/|https://\1/|g'

# Only what is missing, dependencies included, into <deb-dir>, for install_debs. At most
# 100+70 per attempt, and with the cache's try and the install, 555s with every kill
# grace, so the steps' `timeout-minutes: 10` only fires if this script itself hangs.
mkdir -p "$debs/partial"
fetch() {
  timeout -k 10 90 "${apt[@]}" update &&
    timeout -k 10 60 "${apt[@]}" install -y --fix-broken --download-only \
      -o Dir::Cache::Archives="$debs" "${missing[@]}"
}

fetch || {
  echo "::warning::apt-get failed or timed out, retrying in 15s"
  sleep 15
  fetch
} || exit 1
sudo rm -rf "$debs/partial" "$debs/lock"
install_debs || exit 1
[ -z "${GITHUB_OUTPUT:-}" ] || echo "fetched=true" >>"$GITHUB_OUTPUT"
