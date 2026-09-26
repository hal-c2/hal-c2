#!/bin/sh
# A stand-in for cloudflared. `version` answers; `tunnel run` records its tunnel
# token in `runs.log` next to this script and stays up until it is stopped.
case "$1" in
  version) echo "cloudflared version 2026.5.2 (fake)"; exit 0 ;;
  tunnel)
    echo "$$ $TUNNEL_TOKEN" >> "$(dirname "$0")/runs.log"
    exec sleep 100000 ;;
esac
exit 2
