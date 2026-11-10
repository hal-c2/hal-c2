#!/usr/bin/env bash
# Installs apt packages for a CI step: `apt-install.sh <package>...`.
# The Azure mirror sometimes stalls mid-update and apt-get waits on it forever, so each
# attempt is bounded, and a failed or timed-out attempt is retried once.
set -uo pipefail

apt=(sudo DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)

attempt() {
  timeout -k 10 120 "${apt[@]}" update &&
    timeout -k 10 120 "${apt[@]}" install -y "$@"
}

attempt "$@" && exit 0
echo "::warning::apt-get failed or timed out, retrying in 15s"
sleep 15
# A killed install can leave dpkg half-configured, which would fail the retry.
timeout -k 10 60 sudo dpkg --configure -a
attempt "$@"
