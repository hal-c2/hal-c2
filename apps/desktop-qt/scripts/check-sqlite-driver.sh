#!/usr/bin/env bash
# Fails unless a bundle's sqldrivers directory holds Qt's SQLite driver. The app opens its
# cache through that driver at run time, so a bundle without it starts and fails there.
# Usage: check-sqlite-driver.sh <bundle sqldrivers directory>
set -euo pipefail

drivers="${1:?sqldrivers directory}"
if ! compgen -G "${drivers}/libqsqlite*" > /dev/null; then
  echo "error: ${drivers} has no libqsqlite*; the bundle would have no SQLite driver" >&2
  exit 1
fi
