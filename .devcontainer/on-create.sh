#!/usr/bin/env bash
# One-time container setup, baked into prebuilds. Content-dependent work
# (dependency install) lives in update-content.sh.
set -euo pipefail

# The pnpm-store volume mounts at ~/.cache/pnpm, so docker creates ~/.cache root-owned.
# Hand it to the dev user before anything below (vp, mise) makes its cache directory.
for dir in "$HOME/.cache" "$HOME/.cache/pnpm"; do
  if [ -d "$dir" ] && [ "$(stat -c %U "$dir")" != "$(id -un)" ]; then
    sudo chown "$(id -un):$(id -gn)" "$dir"
  fi
done

# The Vite+ CLI is the repo task runner (vp i, vp run <script>, vp test run).
# Download to a file first: a curl failure inside $( ) would yield an empty
# script and a false success. VP_NODE_MANAGER=no skips the installer's node
# shims; Node comes from the devcontainer feature. The VP_*_DIR group (set
# together, absolute) pins the install location instead of the installer's
# XDG platform defaults, which moved the binary from ~/.vite-plus/bin to
# ~/.local/share/vite-plus/bin between releases and would break the check
# below either way.
export VP_BIN_DIR="$HOME/.local/share/vite-plus/bin"
export VP_DATA_DIR="$HOME/.local/share/vite-plus"
export VP_CACHE_DIR="$HOME/.cache/vite-plus"
installer=$(mktemp)
curl -fsSL https://vite.plus -o "$installer"
VP_NODE_MANAGER=no bash "$installer"
rm -f "$installer"

# Non-login lifecycle shells never source the profile the installer edits,
# so expose vp on the default PATH. test -x keeps a bad install loud.
test -x "$VP_BIN_DIR/vp"
sudo ln -sf "$VP_BIN_DIR/vp" /usr/local/bin/vp

# mise pins Erlang, Elixir, Node and Bun in mise.toml, which the MC needs
# (`mise run mc`). Erlang compiles from source, so it needs its build deps.
installer=$(mktemp)
curl -fsSL https://mise.run -o "$installer"
sh "$installer"
rm -f "$installer"
sudo ln -sf "$HOME/.local/bin/mise" /usr/local/bin/mise
sudo apt-get update
sudo apt-get install -y build-essential autoconf m4 libncurses-dev libssl-dev libssh-dev
mise trust
mise install

# First-run terminal notice, rendered by the devcontainers base image.
sudo mkdir -p /usr/local/etc/vscode-dev-containers
sudo tee /usr/local/etc/vscode-dev-containers/first-run-notice.txt >/dev/null <<'EOF'
HAL-C2 devcontainer

  vp test run <files>   run the tests you touched (vp lint <files> to lint)
  cp .env.example .env  optional: enable HAL-C2 Connect cloud features
                        (public identifiers, not secrets)

Details: docs/internals/devcontainer.md
EOF
