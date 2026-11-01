#!/usr/bin/env bash
# Runs at creation and on every prebuild content refresh, so codespaces start
# with deps installed and caches warm. Everything here is idempotent.
set -euo pipefail

# Volume mounts (pnpm store, node_modules) and the directories docker creates
# for them arrive root-owned; hand them to the dev user before installing.
# Keep in step with on-create.sh, which chowns the same directories minus node_modules.
for dir in "$HOME/.cache" "$HOME/.cache/pnpm" node_modules; do
  if [ -d "$dir" ] && [ "$(stat -c %U "$dir")" != "$(id -un)" ]; then
    sudo chown "$(id -un):$(id -gn)" "$dir"
  fi
done

CI=true vp i
# install:mc also compiles the MC. A broken MC compile must not fail container
# creation for TypeScript-only work, so warn loudly instead of failing here;
# `mise run mc` will surface the same error when the MC is actually run.
# Under a prebuild nobody watches this run, so the warning also goes to a file
# (in the workspace, which prebuilds keep) that postAttachCommand prints.
warning=.hal-c2/devcontainer-mc-install-warning
mkdir -p "$(dirname "$warning")"
rm -f "$warning"
if ! mise run install:mc; then
  echo "warning: MC deps/compile failed; the container is usable, run 'bash .devcontainer/update-content.sh' to retry" | tee "$warning" >&2
fi
