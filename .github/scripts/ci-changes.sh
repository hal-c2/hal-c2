#!/usr/bin/env bash
# Says which of ci.yml's jobs a commit needs, as `name=value` lines for $GITHUB_OUTPUT:
#   mc, tui   "true" or "false"
#   proofs    a JSON list of the Maude proofs to run
#
# Run with HEAD a pull request's merge commit or a push to main, so HEAD^1..HEAD is the
# whole change. With `all` as its argument, every job runs.
#
# Each path list names what a job cannot depend on, not what it does: a path no one
# thought of runs everything.
set -euo pipefail

not_mc='^(docs/|apps/(tui|desktop-qt|mobile-qt|marketing)/|assets/|.*\.md$)'
not_tui='^(docs/|apps/(server-ex|mobile-qt|marketing)/|native/|assets/|.*\.md$)'

# A model check depends on the model and how it is checked, never on the MC's code:
# `mix proof --only` in mc_check holds the model to the code on every change. So a proof
# runs only when its model does, or when what every proof runs on changes.
all_proofs='^(apps/server-ex/(mix\.exs|mix\.lock|config/proof\.exs|proof/support/|proof/test_helper\.exs)|\.github/(workflows/ci\.yml|scripts/ci-changes\.sh|actions/setup-mc/))'

proofs=$(git ls-tree --name-only HEAD apps/server-ex/proof/hal_c2/ | sed -nE 's|.*/(.*)_proof_test\.exs$|\1|p')

if [ "${1:-}" = all ] || ! git rev-parse -q --verify HEAD^1 >/dev/null; then
  mc=true tui=true selected=$proofs
else
  changed=$(git diff --name-only HEAD^1 HEAD)
  mc=false tui=false
  if grep -qvE "$not_mc" <<<"$changed"; then mc=true; fi
  if grep -qvE "$not_tui" <<<"$changed"; then tui=true; fi
  if grep -qE "$all_proofs" <<<"$changed"; then
    selected=$proofs
  else
    touched=$(sed -nE 's#^apps/server-ex/proof/(hal_c2/(.*)_proof_test\.exs|models/(.*)\.maude)$#\2\3#p' <<<"$changed" | sort -u)
    # A proof deleted by this change has nothing left to run.
    selected=$(grep -Fx -f <(printf '%s\n' "$proofs") <<<"$touched" || true)
  fi
fi

echo "mc=$mc"
echo "tui=$tui"
echo "proofs=$(jq -Rsc 'split("\n") | map(select(. != ""))' <<<"$selected")"
