#!/usr/bin/env bash
# Fails unless a bundle's sqldrivers directory holds Qt's SQLite driver. The app opens its
# cache through that driver at run time, so a bundle without it starts and fails there.
# Usage: check-sqlite-driver.sh <bundle sqldrivers directory>
set -euo pipefail

drivers="${1:?sqldrivers directory}"
if [ ! -d "${drivers}" ]; then
  echo "error: ${drivers} is not a directory; the bundle has no sqldrivers directory" >&2
  exit 1
fi
# Only the part after the directory is a pattern; the bundle path is matched literally, and a
# directory or broken symlink named like a driver is not one.
shopt -s nullglob
found=""
for driver in "${drivers}"/libqsqlite*; do
  if [ -f "${driver}" ]; then
    found=1
    break
  fi
done
if [ -z "${found}" ]; then
  echo "error: ${drivers} has no libqsqlite*; the bundle would have no SQLite driver" >&2
  exit 1
fi
