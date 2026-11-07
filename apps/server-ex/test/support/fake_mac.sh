#!/bin/sh
# Stands in for the macOS tools the MC runs to find an application's icon (mdfind, mdls,
# plutil, sips), under whichever of those names it is linked as. $FAKE_MAC_DIR holds:
#   mdfind.out        what mdfind prints
#   used/<bundle>     the kMDItemLastUsedDate mdls prints for an application bundle
# plutil reads `key=value` lines from the Info.plist it is given, and sips copies its
# source to its --out. Every call is appended to $FAKE_MAC_DIR/calls.log.
name=$(basename "$0")
printf '%s\t%s\n' "$name" "$*" >> "$FAKE_MAC_DIR/calls.log"
case "$name" in
  mdfind) cat "$FAKE_MAC_DIR/mdfind.out" ;;
  mdls)
    for last; do :; done
    cat "$FAKE_MAC_DIR/used/$(basename "$last")" 2>/dev/null
    ;;
  plutil)
    # plutil -extract KEY raw -o - FILE
    key=$2
    for last; do :; done
    value=$(sed -n "s/^$key=//p" "$last" 2>/dev/null | head -n 1)
    [ -n "$value" ] || exit 1
    printf '%s\n' "$value"
    ;;
  sips)
    src=""; out=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --out) out=$2; shift ;;
        -z|-s) shift 2 ;;
        *) src=$1 ;;
      esac
      shift
    done
    cp "$src" "$out"
    ;;
esac
