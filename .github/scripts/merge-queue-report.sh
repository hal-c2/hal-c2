#!/usr/bin/env bash
# Comments on a pull request why its merge queue run failed: the jobs that failed or timed
# out, and from each job's log the failed tests (ExUnit's numbered failures), or else the
# log's last lines before the step failed. The queue itself only says the PR left it.
#
# Usage: merge-queue-report.sh <run id> <run attempt> <queue branch>
#   (GH_TOKEN, GITHUB_REPOSITORY; DRY_RUN=1 prints the comment instead of posting it)
set -euo pipefail

repo=${GITHUB_REPOSITORY:?}
run=${1:?run id} attempt=${2:?run attempt} branch=${3:?queue branch}
number=$(sed -nE 's|^gh-readonly-queue/[^/]+/pr-([0-9]+)-.*|\1|p' <<<"$branch")
[ -n "$number" ] || { echo "$branch is not a merge queue branch"; exit 0; }

marker="<!-- merge-queue-report:$run/$attempt -->"
if gh api "repos/$repo/issues/$number/comments?per_page=100" --paginate --jq '.[].body' |
  grep -qF "$marker"; then
  echo "#$number already has the report for run $run attempt $attempt"
  exit 0
fi

sha=$(gh api "repos/$repo/actions/runs/$run" --jq .head_sha)

# A group rebuilt because a PR ahead left the queue: its old run may fail or be cancelled
# while this PR waits on in a newer group, so the run is not this PR's to report.
queued=$(gh api graphql -F owner="${repo%/*}" -F name="${repo#*/}" -f query='
  query($owner: String!, $name: String!) {
    repository(owner: $owner, name: $name) {
      mergeQueue(branch: "main") {
        entries(first: 100) { nodes { headCommit { oid } pullRequest { number } } }
      }
    }
  }' --jq ".data.repository.mergeQueue.entries.nodes[]
           | select(.pullRequest.number == $number and .headCommit.oid != \"$sha\") | .headCommit.oid")
if [ -n "$queued" ]; then
  echo "#$number is still queued as $queued; run $run belonged to an older group"
  exit 0
fi

# A run whose CI result never finished is a wedge, which the watchdog drops and explains.
result=$(gh api "repos/$repo/commits/$sha/check-runs?check_name=CI%20result" \
  --jq '[.check_runs[].status] | if length == 0 then "missing" else (sort | last) end')
if [ "$result" != completed ]; then
  echo "run $run's CI result is $result: a wedge, which the watchdog reports"
  exit 0
fi

jobs=$(gh api "repos/$repo/actions/runs/$run/attempts/$attempt/jobs?per_page=100" \
  --jq "$(cat "$(dirname "$0")/failed-jobs.jq") | .[] | [.id, .name, .url, .timed_out] | @tsv")

# A job's log, without timestamps or colour.
log() {
  curl -fsSL -H "Authorization: Bearer $GH_TOKEN" \
    "https://api.github.com/repos/$repo/actions/jobs/$1/logs" |
    sed -E 's/^[0-9T:.-]+Z ?//; s/\x1b\[[0-9;]*m//g; s/^##\[(error|warning)\]//'
}

# ExUnit's failures, each from its "N) test …" line to its stacktrace and each once (a
# retried property fails twice), with a PropCheck exception's first lines; else the log's
# last 25 lines before the step failed (or before it was cut off). 80 lines at most.
excerpt() {
  awk '
    /^Result: \{:exception/ { x = 3 }
    x > 0 { x--; if (!seen[$0]++) print; next }
    /^ +[0-9]+\) (test|property|doctest|feature|scenario) / { on = !seen[$0]++; found = 1; if (!on) next }
    on && /^ +stacktrace:/ { on = 0; print ""; next }
    on { print; next }
    /^(Process completed with exit code|The operation was canceled|Post job cleanup)/ { exit }
    { tail[n % 25] = $0; n++ }
    END { if (!found) for (i = (n > 25 ? n - 25 : 0); i < n; i++) print tail[i % 25] }
  ' | head -80
}

body="The merge queue run for this PR failed, so it left the queue: [run $run]"
body+="(https://github.com/$repo/actions/runs/$run/attempts/$attempt)."$'\n'
if [ -z "$jobs" ]; then
  body+=$'\nNo job failed or timed out in it; the run was cancelled. Re-queue it.\n'
fi
while IFS=$'\t' read -r id name url timed_out; do
  [ -n "$id" ] || continue
  if [ "$timed_out" = true ]; then
    body+=$'\n'"### [$name]($url) timed out"$'\n'
  else
    body+=$'\n'"### [$name]($url) failed"$'\n'
  fi
  text=$(log "$id" | excerpt || true)
  [ -n "$text" ] && body+=$'\n```\n'"$text"$'\n```\n'
done <<<"$jobs"
body+=$'\n'"$marker"

if [ -n "${DRY_RUN:-}" ]; then
  printf '#%s:\n%s\n' "$number" "$body"
else
  gh pr comment "$number" --repo "$repo" --body "$body"
fi
