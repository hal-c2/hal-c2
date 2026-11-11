#!/usr/bin/env bash
# Installs apt packages for a CI step: `apt-install.sh <package>...`.
# The Azure mirror sometimes stalls mid-update and apt-get waits on it forever, so each
# attempt is bounded, and a failed or timed-out attempt is retried once.
set -uo pipefail

apt=(sudo DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)

# At most 90+120 per attempt, 465s in all (515s with every kill grace), so the steps'
# `timeout-minutes: 10` only fires if this script itself hangs.
attempt() {
  timeout -k 10 90 "${apt[@]}" update &&
    timeout -k 10 120 "${apt[@]}" install -y "$@"
}

# A package the runner image already has needs no mirror at all.
missing=()
for package in "$@"; do
  dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q '^install ok installed$' || missing+=("$package")
done
[ ${#missing[@]} -eq 0 ] && echo "Already installed: $*" && exit 0
set -- "${missing[@]}"

attempt "$@" && exit 0
echo "::warning::apt-get failed or timed out, retrying in 15s"
sleep 15
# A killed install can leave dpkg half-configured, which would fail the retry.
timeout -k 10 30 sudo dpkg --configure -a
# The retry goes straight to the Ubuntu archive: the runner's mirror list falls back to
# it only after the stalled Azure mirror's timeouts have used up the attempt.
sudo sed -i 's|azure\.archive\.ubuntu\.com|archive.ubuntu.com|g' \
  /etc/apt/apt-mirrors.txt /etc/apt/sources.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true
attempt "$@"
