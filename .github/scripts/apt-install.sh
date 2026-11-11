#!/usr/bin/env bash
# Installs apt packages for a CI step: `apt-install.sh <package>...`.
# The Azure mirror sometimes stalls mid-update and apt-get waits on it forever, so each
# attempt is bounded, and a failed or timed-out attempt is retried once on archive.ubuntu.com.
set -uo pipefail

apt=(sudo DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)

# At most 90+120 per attempt, 465s in all (515s with every kill grace), so the steps'
# `timeout-minutes: 10` only fires if this script itself hangs.
attempt() {
  timeout -k 10 90 "${apt[@]}" update &&
    timeout -k 10 120 "${apt[@]}" install -y "$@"
}

# The runner lists Azure first in /etc/apt/apt-mirrors.txt (read by ubuntu.sources through
# `mirror+file:`). When Azure stalls, apt spends ~20s per suite on it without reaching the
# next mirror inside an attempt's bound, and retrying Azure doesn't help when it is down, so
# point every source that names it at the main archive. Files that don't exist or don't name Azure are left alone.
use_other_mirror() {
  sudo grep -rlZ --fixed-strings azure.archive.ubuntu.com \
    /etc/apt/apt-mirrors.txt /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null |
    xargs -0r sudo sed -i 's|https\?://azure\.archive\.ubuntu\.com/ubuntu|http://archive.ubuntu.com/ubuntu|g'
}

attempt "$@" && exit 0
echo "::warning::apt-get failed or timed out, retrying in 15s on archive.ubuntu.com"
use_other_mirror
sleep 15
# A killed install can leave dpkg half-configured, which would fail the retry.
timeout -k 10 30 sudo dpkg --configure -a
attempt "$@"
