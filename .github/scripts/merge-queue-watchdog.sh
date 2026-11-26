#!/usr/bin/env bash
# Keeps the merge queue moving, where GitHub or a parked entry (ci.yml's `park`) would hold
# it until its check timeout:
#
#   - Drops an entry whose CI run GitHub has wedged: the run ended but its `CI result` job
#     never finished (it never got a runner), or the run has sat queued without a single
#     job for STUCK_MINUTES. It gets a comment saying why; its owner re-queues it.
#   - Looks for the culprit when an entry fails: every entry ahead of it whose run parked
#     tests at once. The first of them to fail is the culprit, and those ahead of it pass and
#     merge, in one round of runs rather than one round per entry walked back. Entries
#     behind a failed one are built on it; GitHub rebuilds them once it leaves.
#   - Starts the tests of the last entry being built when its run is parked: the entry it
#     waited on left the queue.
#   - Answers for a last entry whose run passed and the entries ahead of it, or for one
#     whose promoted run failed, when `CI result` could not (merge-queue-stamp.sh).
#   - Cancels queue runs whose commit is no longer in the queue: no one reads them.
#
# A queue commit is public and can be anyone's PR head, so neither a run nor a `CI result`
# counts for being on it: only queue runs, and the checks in their own suites.
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

# The latest queue run of ci.yml for a commit, the merge group's or a promoted one:
#   id  status  created_at  event  head_branch  html_url  check_suite_id  run_attempt
# Asked by event, which a pull request can neither fake nor crowd out of the page.
latest_run() {
  local event
  for event in merge_group workflow_dispatch; do
    gh api "repos/$repo/actions/runs?head_sha=$1&event=$event&per_page=20" \
      --jq '.workflow_runs[] | select(.path == ".github/workflows/ci.yml"
                                      and (.head_branch | startswith("gh-readonly-queue/")))
            | [.id, .status, .created_at, .event, .head_branch, .html_url, .check_suite_id, .run_attempt] | @tsv' ||
      return
  done | sort -t $'\t' -k 3,3 | tail -n 1
}

# The conclusion of a queue run's `CI result`, or its status while it runs, or missing. A
# merge group's is the latest in its suite, where the queue reads and a later entry's stamp
# lands. A promoted run's is its job in that attempt: a retry's predecessor doesn't count.
run_result() { # id event suite attempt
  if [ "$2" = merge_group ]; then
    gh api "repos/$repo/check-suites/$3/check-runs?check_name=CI%20result" \
      --jq '.check_runs | max_by(.id) // {} | .conclusion // .status // "missing"'
  else
    gh api "repos/$repo/actions/runs/$1/attempts/$4/jobs?per_page=100" \
      --jq '[.jobs[] | select(.name == "CI result")] | max_by(.id) // {} | .conclusion // .status // "missing"'
  fi
}

# Waits up to two minutes for a commit's promoted run to be listed. Watchdog runs are serial,
# so the next one then finds it as the latest run and doesn't promote the entry again.
promoted() {
  for _ in $(seq 24); do
    [ "$(latest_run "$1" | cut -f4)" = workflow_dispatch ] && return 0
    sleep 5
  done
  return 1
}

# Whether a run parked: its wait job ran or still waits, rather than being skipped.
parked() {
  [ -n "$(gh api "repos/$repo/actions/runs/$1/jobs?per_page=100" \
    --jq ".jobs[] | select(.name == \"$park_job\" and .conclusion != \"skipped\") | .id")" ]
}

# Fails an entry whose promoted run failed, when the run's `CI result` could not answer.
fail_promoted() { # id attempt sha url number result
  # Read last, as a retry may have started since. One can still start as the stamp posts.
  if [ "$(gh api "repos/$repo/actions/runs/$1" --jq .run_attempt)" != "$2" ]; then
    echo "#$5's promoted run $1 is no longer known to be at attempt $2; not failing it"
    return 1
  fi
  echo "#$5's promoted run ended $6; failing the entry"
  act "$here/merge-queue-stamp.sh" "$3" "$4" failure
}

entries=$("$here/merge-queue-entries.sh")
awaiting=$(awk -F'\t' '$2 == "AWAITING_CHECKS" && $3 != "-"' <<<"$entries")
# The entries ahead of the first failed one: those behind it hold its failure. A passed entry
# waits as MERGEABLE for those ahead of it.
built=$(awk -F'\t' '$2 == "UNMERGEABLE" { exit }
  ($2 == "AWAITING_CHECKS" || $2 == "MERGEABLE") && $3 != "-"' <<<"$entries")

# Wedged runs.
while IFS=$'\t' read -r _ _ sha number pr; do
  [ -n "${sha:-}" ] || continue
  run=$(latest_run "$sha")
  why='' failed=''
  if [ -n "$run" ]; then
    IFS=$'\t' read -r id status created _ _ _ suite _ <<<"$run"
    if [ "$status" = completed ]; then
      # This run's own: the commit's may hold a parked run's too, which a promoted run ended.
      result=$(gh api "repos/$repo/check-suites/$suite/check-runs?check_name=CI%20result" \
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

# Promoted runs that ended, answered where their `CI result` could not, whether or not a run
# behind them still goes (which stops the walk from the back below). The last one to pass
# answers for the entries ahead of it too. A failed one sets off the culprit search below.
answered='' failed_one=''
while IFS=$'\t' read -r _ state sha number _; do
  [ "${state:-}" = AWAITING_CHECKS ] || continue
  run=$(latest_run "$sha")
  [ -n "$run" ] || continue
  IFS=$'\t' read -r id _ _ event _ url suite attempt <<<"$run"
  [ "$event" = workflow_dispatch ] || continue
  result=$(run_result "$id" "$event" "$suite" "$attempt")
  if [ "$result" = success ]; then
    echo "#$number's promoted run passed; answering for it and the entries ahead"
    GITHUB_EVENT_NAME=$event act "$here/merge-queue-stamp.sh" "$sha" "$url" success
    answered="$answered $sha"
    break
  elif [ "$result" = failure ] || [ "$result" = cancelled ]; then
    ! fail_promoted "$id" "$attempt" "$sha" "$url" "$number" "$result" || answered="$answered $sha" failed_one=$sha
  fi
done < <(tac <<<"$built")

# The last entry being built ahead of any failed one: it tests, or has passed.
started='' passed='' searching=''
while IFS=$'\t' read -r _ state sha number _; do
  [ -n "${sha:-}" ] || continue
  run=$(latest_run "$sha")
  [ -n "$run" ] || break # GitHub has not started it yet
  IFS=$'\t' read -r id status _ event branch url suite attempt <<<"$run"
  result=$(run_result "$id" "$event" "$suite" "$attempt")
  if [ "$result" = failure ] || [ "$result" = cancelled ]; then
    if [ "$event" = workflow_dispatch ] && [ "$state" = AWAITING_CHECKS ] &&
      [[ " $answered " != *" $sha "* ]]; then
      fail_promoted "$id" "$attempt" "$sha" "$url" "$number" "$result" || break
    fi
    failed_one=$sha
    continue
  fi
  if [ "$result" = success ]; then
    passed=$sha
    if [[ " $answered " != *" $sha "* ]]; then
      echo "#$number passed; answering for it and the entries ahead"
      GITHUB_EVENT_NAME=$event act "$here/merge-queue-stamp.sh" "$sha" "$url" success
    fi
  elif [ "$event" = merge_group ] && [ "$status" != completed ] && parked "$id"; then
    echo "#$number is the last entry but its run $id parked: testing it"
    act gh workflow run ci.yml --repo "$repo" --ref "$branch" -f queue=true
    started=$sha
    [ -n "${DRY_RUN:-}" ] || promoted "$sha" ||
      echo "::warning::#$number's promoted run is not listed yet; the next watchdog may start it again"
  fi
  break
done < <(tac <<<"$built")

# An entry failed: test every parked entry ahead of it at once, to find the culprit. GitHub
# lists one as UNMERGEABLE a little after its `CI result` fails. Not when one ahead passed:
# so did all ahead of it.
if [ -z "$passed" ] && { [ -n "$failed_one" ] || awk -F'\t' '$2 == "UNMERGEABLE" { f = 1 } END { exit !f }' <<<"$entries"; }; then
  while IFS=$'\t' read -r _ state sha number _; do
    [ "${state:-}" = AWAITING_CHECKS ] && [[ " $started " != *" $sha "* ]] || continue
    run=$(latest_run "$sha")
    [ -n "$run" ] || continue
    IFS=$'\t' read -r id status _ event branch _ suite attempt <<<"$run"
    [ "$event" = merge_group ] && [ "$status" != completed ] || continue
    case $(run_result "$id" "$event" "$suite" "$attempt") in success | failure | cancelled) continue ;; esac
    parked "$id" || continue
    echo "#$number parked ahead of a failed entry: testing it"
    act gh workflow run ci.yml --repo "$repo" --ref "$branch" -f queue=true
    started="$started $sha" searching="$searching $sha"
  done <<<"$built"
  for sha in $searching; do
    [ -n "${DRY_RUN:-}" ] || promoted "$sha" ||
      echo "::warning::$sha's promoted run is not listed yet; the next watchdog may start it again"
  done
fi

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
