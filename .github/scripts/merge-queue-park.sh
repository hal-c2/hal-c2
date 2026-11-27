#!/usr/bin/env bash
# Prints park=true when the queue is building an entry behind this one. That entry's commit
# holds this one's changes, so its run tests both and answers for this one (ci-result.sh).
# Also when an entry ahead has failed: this commit holds the failure, and GitHub rebuilds it
# without that entry once it leaves, or the watchdog tests it if that entry passes after all.
# Else park=false and this entry tests: it is the last one built, or it is not found yet,
# which costs runners but nothing else.
#
# Usage: merge-queue-park.sh <the entry's commit>   (GH_TOKEN, GITHUB_REPOSITORY)
set -euo pipefail

sha=${1:?commit}
# Without the listing, test: parking with no one behind would hold the queue.
if ! entries=$("$(dirname "$0")/merge-queue-entries.sh"); then
  echo "::warning::Could not list the merge queue, so this entry tests"
  echo park=false
  exit 0
fi

read -r behind failed < <(awk -F'\t' -v sha="$sha" '
  $3 == sha { mine = $1; next }
  !mine && $2 == "UNMERGEABLE" { f++ }
  mine && $1 + 0 > mine + 0 && ($2 == "AWAITING_CHECKS" || $2 == "MERGEABLE") { n++ }
  END { print n + 0, (mine ? f + 0 : 0) }' <<<"$entries")

if [ "$failed" -gt 0 ]; then
  echo "$failed entries ahead of this one failed; it waits to be rebuilt without them" >&2
  echo park=true
elif [ "$behind" -gt 0 ]; then
  echo "$behind entries behind this one are being built; the last of them tests this one" >&2
  echo park=true
else
  echo park=false
fi
