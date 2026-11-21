#!/usr/bin/env bash
# Keeps the merge queue moving, where GitHub or a parked entry (ci.yml's `park`) would hold
# it until its check timeout:
#
#   - Drops an entry whose CI run GitHub has wedged: the run ended but its `CI result` job
#     never finished (it never got a runner), or the run has sat queued without a single
#     job for STUCK_MINUTES. It gets a comment saying why; its owner re-queues it.
#   - Starts the tests of the last entry being built when its run is parked: the entry it
#     waited on left the queue. Entries whose `CI result` failed are on their way out.
#   - Answers for the entries ahead of a last entry whose run passed, when its `CI result`
#     could not (merge-queue-stamp.sh).
#   - Cancels queue runs whose commit is no longer in the queue: no one reads them.
#
# Usage: merge-queue-watchdog.sh   (GH_TOKEN, GITHUB_REPOSITORY; DRY_RUN=1 only reports)
set -euo pipefail

repo=${GITHUB_REPOSITORY:?}
stuck=${STUCK_MINUTES:-20}
here=$(dirname "$0")
now=$(date -u +%s)
park_job="Wait for a later queue entry"

failed_jobs="$(cat "$here/failed-jobs.jq") | map(.name) | join(\", \")"

age_minutes() { echo $(((now - $(date -u -d "$1" +%s)) / 60)); }
act() { if [ -n "${DRY_RUN:-}" ]; then echo "(dry run) $*"; else "$@"; fi; }

# The latest ci.yml run for a commit, a queue run or a promoted one:
#   id  status  created_at  event  head_branch  html_url
latest_run() {
  gh api "repos/$repo/actions/runs?head_sha=$1&per_page=20" \
    --jq '[.workflow_runs[] | select(.path == ".github/workflows/ci.yml")] | max_by(.created_at) // empty
          | [.id, .status, .created_at, .event, .head_branch, .html_url] | @tsv'
}

# The conclusion of a commit's latest `CI result`, or its status while it runs, or missing.
ci_result() {
  gh api "repos/$repo/commits/$1/check-runs?check_name=CI%20result" \
    --jq '.check_runs | max_by(.id) // {} | .conclusion // .status // "missing"'
}

# Whether a run parked: its wait job ran or still waits, rather than being skipped.
parked() {
  [ -n "$(gh api "repos/$repo/actions/runs/$1/jobs?per_page=100" \
    --jq ".jobs[] | select(.name == \"$park_job\" and .conclusion != \"skipped\") | .id")" ]
}

entries=$("$here/merge-queue-entries.sh")
awaiting=$(awk -F'\t' '$2 == "AWAITING_CHECKS" && $3 != "-"' <<<"$entries")
# A passed entry waits as MERGEABLE for those ahead of it.
built=$(awk -F'\t' '($2 == "AWAITING_CHECKS" || $2 == "MERGEABLE") && $3 != "-"' <<<"$entries")

# Wedged runs.
while IFS=$'\t' read -r _ _ sha number pr; do
  [ -n "${sha:-}" ] || continue
  run=$(latest_run "$sha")
  why='' failed=''
  if [ -n "$run" ]; then
    IFS=$'\t' read -r id status created _ <<<"$run"
    if [ "$status" = completed ]; then
      result=$(gh api "repos/$repo/commits/$sha/check-runs?check_name=CI%20result" \
        --jq '[.check_runs[].status] | if length == 0 then "missing" else (sort | last) end')
      # `completed` sorts first, so `last` is any status that has not finished.
      if [ "$result" != completed ]; then
        why="CI run $id ended while its \`CI result\` check is $result"
        failed=$(gh api "repos/$repo/actions/runs/$id/jobs?per_page=100" --jq "$failed_jobs")
      fi
    elif [ "$status" = queued ] && [ "$(age_minutes "$created")" -ge "$stuck" ]; then
      jobs=$(gh api "repos/$repo/actions/runs/$id/jobs?per_page=1" --jq .total_count)
      if [ "$jobs" = 0 ]; then
        why="CI run $id has sat queued without a job for $stuck minutes"
      fi
    fi
  fi
  [ -n "$why" ] || continue

  echo "#$number: $why"
  [ -z "${DRY_RUN:-}" ] || continue
  gh api graphql -F id="$pr" -f query='
    mutation($id: ID!) { dequeuePullRequest(input: {id: $id}) { clientMutationId } }' >/dev/null ||
    { echo "#$number: could not drop it, it may have left the queue already"; continue; }
  if [ -n "$failed" ]; then
    verdict="These jobs failed or timed out before it wedged, so fix them first: $failed."
  else
    verdict="No job in it failed; re-queue it."
  fi
  gh pr comment "$number" --repo "$repo" --body "Dropped from the merge queue: GitHub wedged its run ($why). Waiting would have held the queue for its check timeout. $verdict"
done <<<"$awaiting"

# The last entry being built, past those on their way out: it tests, or has passed.
while IFS=$'\t' read -r _ _ sha number _; do
  [ -n "${sha:-}" ] || continue
  result=$(ci_result "$sha")
  [ "$result" != failure ] && [ "$result" != cancelled ] || continue
  run=$(latest_run "$sha")
  [ -n "$run" ] || break # GitHub has not started it yet
  IFS=$'\t' read -r id status _ event branch url <<<"$run"
  if [ "$result" = success ]; then
    echo "#$number passed; answering for the entries ahead"
    act "$here/merge-queue-stamp.sh" "$sha" "$url"
  elif [ "$event" = merge_group ] && [ "$status" != completed ] && parked "$id"; then
    echo "#$number is the last entry but its run $id parked: testing it"
    act gh workflow run ci.yml --repo "$repo" --ref "$branch" -f queue=true
  fi
  break
done < <(tac <<<"$built")

# Runs no entry reads: the entry merged, left, or was rebuilt as another commit. Not one a
# few minutes old, which may be ahead of the queue listing.
for status in queued in_progress; do
  gh api "repos/$repo/actions/runs?status=$status&per_page=100" \
    --jq '.workflow_runs[] | select(.path == ".github/workflows/ci.yml"
                                    and (.head_branch | startswith("gh-readonly-queue/")))
          | [.id, .head_sha, .created_at] | @tsv'
done | while IFS=$'\t' read -r id sha created; do
  [ -n "${id:-}" ] || continue
  # Not `cut | grep -q`: grep exits at its match, and pipefail reads cut's SIGPIPE as no match.
  awk -F'\t' -v sha="$sha" '$3 == sha { found = 1 } END { exit !found }' <<<"$entries" && continue
  [ "$(age_minutes "$created")" -ge 5 ] || continue
  echo "run $id tests $sha, which is no longer in the queue: cancelling it"
  act gh run cancel "$id" --repo "$repo" || echo "run $id: could not cancel it, it may have ended"
done
