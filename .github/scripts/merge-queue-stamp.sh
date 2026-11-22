#!/usr/bin/env bash
# Answers for the queue entries a run tested. The queue builds each entry on the ones ahead,
# so a passed entry's commit holds their changes: each still waiting gets a passing
# `CI result` linking to the run, and the queue merges them with it.
#
# So does the entry itself, pass or fail, unless the run is its merge group's. The queue
# reads only the merge group's check suite: the `CI result` job of a run the watchdog
# started is in that run's own suite, while a check run made here lands in the merge
# group's, the commit's first.
#
# ci.yml's `CI result` calls this, and the watchdog when that was missed.
#
# Usage: merge-queue-stamp.sh <the entry's commit> <its run's URL> <success|failure>
#   (GH_TOKEN with checks: write, GITHUB_REPOSITORY, GITHUB_EVENT_NAME in a run)
set -euo pipefail

repo=${GITHUB_REPOSITORY:?} sha=${1:?commit} url=${2:?run url} conclusion=${3:?conclusion}

queue=$("$(dirname "$0")/merge-queue-entries.sh")
read -r mine pr < <(awk -F'\t' -v sha="$sha" '$3 == sha { print $1, $4 }' <<<"$queue") || true
if [ -z "${mine:-}" ]; then
  echo "$sha is not in the queue; there is no entry to answer for"
  exit 0
fi

answer() { # commit title summary
  gh api "repos/$repo/check-runs" -f name="CI result" -f head_sha="$1" \
    -f status=completed -f conclusion="$conclusion" -f details_url="$url" \
    -f "output[title]=$2" -f "output[summary]=$3" >/dev/null
}

while IFS=$'\t' read -r position state oid number _; do
  [ "$position" -le "$mine" ] && [ "$state" = AWAITING_CHECKS ] && [ "$oid" != - ] || continue
  if [ "$position" -eq "$mine" ]; then
    [ "${GITHUB_EVENT_NAME:-}" != merge_group ] || continue
    answer "$oid" "The run that tested this entry: $conclusion" \
      "This entry was parked, then tested by a run of its own: $url"
    echo "#$number: $conclusion by its own run"
    continue
  fi
  [ "$conclusion" = success ] || continue
  # Only an entry this commit holds: the queue rebuilds the entries behind one that
  # changes, so a mismatch is a run racing that rebuild.
  status=$(gh api "repos/$repo/compare/$oid...$sha" --jq .status)
  case $status in
    ahead | identical) ;;
    *)
      echo "#$number: $oid is not in $sha ($status), so that run did not test it"
      continue
      ;;
  esac
  answer "$oid" "Passed in #$pr's queue run" \
    "#$pr is queued behind this PR, so its queue commit holds this one's changes, and its run passed: $url"
  echo "#$number: passed with #$pr"
done <<<"$queue"
