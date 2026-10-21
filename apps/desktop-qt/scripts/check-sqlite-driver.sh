#!/usr/bin/env bash
# Fails unless a bundle's sqldrivers directory holds Qt's SQLite driver. The app opens its
# cache through that driver at run time, so a bundle without it starts and fails there.
# Usage: check-sqlite-driver.sh <bundle sqldrivers directory> <libqsqlite.so | libqsqlite.dylib>
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: check-sqlite-driver.sh <bundle sqldrivers directory> <libqsqlite.so | libqsqlite.dylib>" >&2
  exit 1
fi
drivers="${1:?sqldrivers directory}"
# A trailing slash would make -L follow a linked directory; strip them all so
# the checks below do not depend on the caller's spelling.
while [ "${drivers}" != "/" ] && [ "${drivers}" != "${drivers%/}" ]; do
  drivers="${drivers%/}"
done
name="${2:?driver file name (libqsqlite.so on Linux, libqsqlite.dylib on macOS)}"
case "${name}" in
  libqsqlite.so | libqsqlite.dylib) ;;
  *)
    echo "error: ${name} is not a driver file name" >&2
    exit 1
    ;;
esac
# Ancestors above the bundle root are not checked: they are not archived, and
# they routinely are links (macOS /tmp, a linked build dir). Inside the bundle
# the deploy tools create the directories fresh rather than linking them; what
# they can still produce is a linked sqldrivers directory or driver file, and
# those are checked here.
if [ -L "${drivers}" ]; then
  echo "error: ${drivers} is a symlink; the bundle must carry the sqldrivers directory itself" >&2
  exit 1
fi
if [ ! -d "${drivers}" ]; then
  echo "error: ${drivers} is not a directory; the bundle has no sqldrivers directory" >&2
  exit 1
fi
# The file the bundle's platform loads, there and not empty; this does not check that it loads.
# A directory, an empty file, a differently named copy (libqsqlite.so.bak) or the other
# platform's file is not the driver, and neither is a symlink: what it points at need not be
# in the bundle or exist on the machine that runs the app.
driver="${drivers}/${name}"
if [ -L "${driver}" ]; then
  echo "error: ${driver} is a symlink; the bundle must carry the driver file itself" >&2
  exit 1
fi
if [ ! -f "${driver}" ]; then
  echo "error: ${drivers} has no ${name} as a regular file; the bundle would have no SQLite driver" >&2
  exit 1
fi
if [ ! -s "${driver}" ]; then
  echo "error: ${driver} is empty; the bundle would have no SQLite driver" >&2
  exit 1
fi
