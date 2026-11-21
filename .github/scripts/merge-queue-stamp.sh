#!/usr/bin/env bash
# Answers for the entries ahead of a queue entry whose run passed. The queue builds each
# entry on the ones ahead, so that entry's commit holds their changes and its run tested
# them: each still waiting gets a passing `CI result` linking to the run, and the queue
# merges them with it. ci.yml's `CI result` calls this when it passes, the watchdog when
# that was missed.
#
# Usage: merge-queue-stamp.sh <the passed entry's commit> <its run's URL>
#   (GH_TOKEN with checks: write, GITHUB_REPOSITORY)
set -euo pipefail

repo=${GITHUB_REPOSITORY:?} sha=${1:?commit} url=${2:?run url}

queue=$("$(dirname "$0")/merge-queue-entries.sh")
read -r mine pr < <(awk -F'\t' -v sha="$sha" '$3 == sha { print $1, $4 }' <<<"$queue") || true
if [ -z "${mine:-}" ]; then
  echo "$sha is not in the queue; there is no entry ahead to answer for"
  exit 0
fi

while IFS=$'\t' read -r position state oid number _; do
  [ "$position" -lt "$mine" ] && [ "$state" = AWAITING_CHECKS ] && [ "$oid" != - ] || continue
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
  gh api "repos/$repo/check-runs" -f name="CI result" -f head_sha="$oid" \
    -f status=completed -f conclusion=success -f details_url="$url" \
    -f "output[title]=Passed in #$pr's queue run" \
    -f "output[summary]=#$pr is queued behind this PR, so its queue commit holds this one's changes, and its run passed: $url" >/dev/null
  echo "#$number: passed with #$pr"
done <<<"$queue"
