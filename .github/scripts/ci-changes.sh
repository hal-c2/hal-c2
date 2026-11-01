#!/usr/bin/env bash
# Says which of ci.yml's jobs a commit needs, as `name=value` lines for $GITHUB_OUTPUT:
#   mc, unit, props, tui   "true" or "false"
#   scenarios              a JSON list of the scenario groups to run
#   named                  every directory those groups name, for `rest` to leave out
#   proofs                 a JSON list of the Maude proofs to run
#
# Run with HEAD a pull request's merge commit or a push to main, so HEAD^1..HEAD is the
# whole change, unless a push to main holds several commits (a rebase merge). Then it is
# the last one, and at worst that merge's build isn't saved until the next. The argument
# says how much to test:
#   all       every job (the nightly run)
#   merged    only mc_check, whose build is what every pull request restores: the merge's
#             tests already ran on its pull request, and the nightly run covers the rest
#   pr        only what the change needs
#
# Each path list names what a job cannot depend on, not what it does: a path no one
# thought of runs everything.
set -euo pipefail

not_mc='^(docs/|apps/(tui|desktop-qt|mobile-qt|marketing)/|assets/|[^/]*\.md$|(.*/)?README\.md$)'
not_tui='^(docs/|apps/(server-ex|mobile-qt|marketing)/|native/|assets/|[^/]*\.md$)'
# test/support is shared by every tier, so it is in none of these. Unit tests read neither
# features/ nor test/steps/, which only scenarios_test.exs loads.
not_unit='^(features/|apps/server-ex/(prop|proof|test/steps)/)'
not_props='^(features/|apps/server-ex/(proof|test/steps|test/hal_c2)/)'
not_scenarios='^apps/server-ex/((prop|proof)/|test/hal_c2/)'
scenarios_test=apps/server-ex/test/hal_c2/scenarios_test.exs

# Directories under features/ in the same group run in one job, sized to stay under a
# quarter of an hour. `rest` runs every directory no other group names, new ones included.
scenario_groups=("mc/orchestration" "providers" "threads source-control" "mc/platform parity connections" "settings terminal files" "rest")
named=$(printf '%s\n' "${scenario_groups[@]}" | grep -vx rest | tr ' ' '\n' | paste -sd'|')

# A model check depends on the model and how it is checked, never on the MC's code:
# `mix proof --only` in mc_check holds the model to the code on every change. So a proof
# runs only when its model does, or when what every proof runs on changes.
all_proofs='^(apps/server-ex/(mix\.exs|mix\.lock|config/proof\.exs|proof/support/|proof/test_helper\.exs)|\.github/(workflows/ci\.yml|scripts/ci-changes\.sh|actions/setup-mc/))'

proofs=$(git ls-tree --name-only HEAD apps/server-ex/proof/hal_c2/ | sed -nE 's|.*/(.*)_proof_test\.exs$|\1|p')

# Whether anything changed outside the paths a job cannot depend on. Not `| grep -q .`: it
# exits at its first match, and pipefail then reads the writer's SIGPIPE as nothing changed.
needed() {
  [ -n "$(grep -vE "$not_mc" <<<"$changed" | grep -vE "$1" || true)" ] && echo true || echo false
}

# The groups holding the changed scenarios, or all of them when more than scenarios changed.
scenario_groups_for() {
  local inputs
  inputs=$(grep -vE "$not_mc" <<<"$changed" | grep -vE "$not_scenarios" || true)
  if [ -z "$inputs" ] && ! grep -qFx "$scenarios_test" <<<"$changed"; then
    return
  fi
  if grep -qvE '^features/.*\.feature$' <<<"$inputs" || grep -qFx "$scenarios_test" <<<"$changed"; then
    printf '%s\n' "${scenario_groups[@]}"
    return
  fi
  while read -r feature; do
    dir=${feature#features/}
    if [[ "$dir" =~ ^($named)/ ]]; then
      for group in "${scenario_groups[@]}"; do
        if tr ' ' '\n' <<<"$group" | grep -qx "${BASH_REMATCH[1]}"; then echo "$group"; fi
      done
    else
      echo rest
    fi
  done <<<"$inputs"
}

mode=${1:-pr}
if [ "$mode" = all ] || ! git rev-parse -q --verify HEAD^1 >/dev/null; then
  mc=true unit=true props=true tui=true selected=$proofs
  scenarios=$(printf '%s\n' "${scenario_groups[@]}")
else
  # Without rename detection a moved file lists both paths: it left one place and reached another.
  changed=$(git diff --no-renames --name-only HEAD^1 HEAD)
  mc=$(needed '^$')
  if [ "$mode" = merged ]; then
    unit=false props=false tui=false scenarios='' selected=''
  else
    unit=$(needed "$not_unit")
    props=$(needed "$not_props")
    scenarios=$(scenario_groups_for | sort -u)
    tui=false
    if grep -qvE "$not_tui" <<<"$changed"; then tui=true; fi
    if grep -qE "$all_proofs" <<<"$changed"; then
      selected=$proofs
    else
      touched=$(sed -nE 's#^apps/server-ex/proof/(hal_c2/(.*)_proof_test\.exs|models/(.*)\.maude)$#\2\3#p' <<<"$changed" | sort -u)
      # A proof deleted by this change has nothing left to run.
      selected=$(grep -Fx -f <(printf '%s\n' "$proofs") <<<"$touched" || true)
    fi
  fi
fi

json_list() { jq -Rsc 'split("\n") | map(select(. != ""))' <<<"$1"; }

echo "mc=$mc"
echo "unit=$unit"
echo "props=$props"
echo "tui=$tui"
echo "scenarios=$(json_list "$scenarios")"
echo "named=$named"
echo "proofs=$(json_list "$selected")"
