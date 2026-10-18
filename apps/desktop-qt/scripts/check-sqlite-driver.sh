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
# Qt ships the driver as libqsqlite.so on Linux and libqsqlite.dylib on macOS. This checks the
# file is there and not empty, not that it loads; a directory, a broken symlink, an empty file or
# a differently named copy (libqsqlite.so.bak) is not the driver.
found=""
for driver in "${drivers}/libqsqlite.so" "${drivers}/libqsqlite.dylib"; do
  if [ -f "${driver}" ] && [ -s "${driver}" ]; then
    found=1
    break
  fi
done
if [ -z "${found}" ]; then
  echo "error: ${drivers} has no libqsqlite.so or libqsqlite.dylib; the bundle would have no SQLite driver" >&2
  exit 1
fi
