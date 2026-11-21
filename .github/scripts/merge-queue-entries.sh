#!/usr/bin/env bash
# The merge queue's entries for main, front first, one tab-separated line each:
#   position  state  head commit ("-" until it is built)  PR number  PR node id
#
# Usage: merge-queue-entries.sh   (GH_TOKEN, GITHUB_REPOSITORY)
set -euo pipefail

repo=${GITHUB_REPOSITORY:?}

gh api graphql -F owner="${repo%/*}" -F name="${repo#*/}" -f query='
  query($owner: String!, $name: String!) {
    repository(owner: $owner, name: $name) {
      mergeQueue(branch: "main") {
        entries(first: 100) {
          nodes { position state headCommit { oid } pullRequest { id number } }
        }
      }
    }
  }' --jq '.data.repository.mergeQueue.entries.nodes // [] | sort_by(.position)[]
           | [(.position | tostring), .state, (.headCommit.oid // "-"),
              (.pullRequest.number | tostring), .pullRequest.id] | @tsv'
