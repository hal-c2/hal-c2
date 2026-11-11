#!/usr/bin/env bash
# Drops merge queue entries whose CI run GitHub has wedged, so the queue answers in minutes
# instead of waiting out its 120-minute check timeout. Wedged means one of:
#
#   - the run ended but its `CI result` job never finished (it never got a runner);
#   - the run has sat queued without a single job for STUCK_MINUTES.
#
# A dropped entry gets a comment saying why; its owner re-queues it.
#
# Usage: merge-queue-watchdog.sh   (GH_TOKEN, GITHUB_REPOSITORY; DRY_RUN=1 only reports)
set -euo pipefail

repo=${GITHUB_REPOSITORY:?}
stuck=${STUCK_MINUTES:-20}
now=$(date -u +%s)

age_minutes() { echo $(((now - $(date -u -d "$1" +%s)) / 60)); }

entries=$(gh api graphql -F owner="${repo%/*}" -F name="${repo#*/}" -f query='
  query($owner: String!, $name: String!) {
    repository(owner: $owner, name: $name) {
      mergeQueue(branch: "main") {
        entries(first: 50) {
          nodes { state headCommit { oid } pullRequest { id number } }
        }
      }
    }
  }' --jq '.data.repository.mergeQueue.entries.nodes[]
           | select(.state == "AWAITING_CHECKS" and .headCommit != null)
           | [.headCommit.oid, .pullRequest.id, (.pullRequest.number | tostring)]
           | @tsv')

while IFS=$'\t' read -r sha pr number; do
  [ -n "$sha" ] || continue
  run=$(gh api "repos/$repo/actions/runs?head_sha=$sha&event=merge_group&per_page=20" \
    --jq '[.workflow_runs[] | select(.path == ".github/workflows/ci.yml")] | max_by(.run_attempt) // empty
          | [.id, .status, .created_at] | @tsv')
  why='' failed=''
  if [ -n "$run" ]; then
    IFS=$'\t' read -r id status created <<<"$run"
    if [ "$status" = completed ]; then
      result=$(gh api "repos/$repo/commits/$sha/check-runs?check_name=CI%20result" \
        --jq '[.check_runs[].status] | if length == 0 then "missing" else (sort | last) end')
      # `completed` sorts first, so `last` is any status that has not finished.
      if [ "$result" != completed ]; then
        why="CI run $id ended while its \`CI result\` check is $result"
        failed=$(gh api "repos/$repo/actions/runs/$id/jobs?per_page=100" \
          --jq '[.jobs[] | select(.conclusion == "failure") | .name] | join(", ")')
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
    verdict="These jobs failed before it wedged, so fix them first: $failed."
  else
    verdict="No job in it failed; re-queue it."
  fi
  gh pr comment "$number" --repo "$repo" --body "Dropped from the merge queue: GitHub wedged its run ($why). Waiting would have held the queue for the 120-minute check timeout. $verdict"
done <<<"$entries"
