#!/usr/bin/env bash
# Decides ci.yml's `CI result` from NEEDS, the run's `needs` as JSON. A skipped job passes; a
# failed or cancelled one fails the run. A queue run (QUEUE=true) where no job failed, only
# a cancel or a parked entry's wait ended it, passes once its entry has left the queue: the
# queue no longer reads the answer, and the commit reached main only if a later entry's run
# tested it.
#
# A queue run that passes answers for the entries ahead of it (merge-queue-stamp.sh).
#
# Usage: ci-result.sh   (NEEDS, QUEUE, GH_TOKEN, GITHUB_REPOSITORY, GITHUB_SHA,
#                        GITHUB_SERVER_URL, GITHUB_RUN_ID)
set -euo pipefail

repo=${GITHUB_REPOSITORY:?} sha=${GITHUB_SHA:?}
here=$(dirname "$0")

unfinished=$(jq -r 'to_entries[] | select(.value.result != "success" and .value.result != "skipped")
                    | "\(.key): \(.value.result)"' <<<"$NEEDS")
# The parked wait ends only by a cancel or GitHub dropping the job; neither is a failure.
failed=$(jq -r 'to_entries[] | select(.key != "park" and .value.result == "failure") | .key' <<<"$NEEDS")

if [ -n "$unfinished" ]; then
  echo "$unfinished" >&2
  if [ -n "${QUEUE:-}" ] && [ -z "$failed" ]; then
    # A failed lookup ends the script here, failing the run: it never reads as "left".
    queue=$("$here/merge-queue-entries.sh")
    if awk -F'\t' -v sha="$sha" '$3 == sha { found = 1 } END { exit found }' <<<"$queue"; then
      echo "This entry has left the queue, which no longer reads this answer."
      exit 0
    fi
  fi
  exit 1
fi

# This run passed whatever happens next: a missed answer leaves the entries ahead parked,
# and the watchdog answers for them.
if [ -n "${QUEUE:-}" ]; then
  "$here/merge-queue-stamp.sh" "$sha" "$GITHUB_SERVER_URL/$repo/actions/runs/$GITHUB_RUN_ID" ||
    echo "::warning::Could not answer for the entries ahead; the merge queue watchdog will"
fi
