#!/usr/bin/env bash
# One-time container setup, baked into prebuilds. Content-dependent work
# (dependency install) lives in update-content.sh.
set -euo pipefail

# The pnpm-store volume mounts at ~/.cache/pnpm, so docker creates ~/.cache root-owned.
# Hand it to the dev user before anything below (vp, mise) makes its cache directory.
# Keep in step with update-content.sh, which also chowns node_modules before vp i; nothing here writes to it.
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
# (`mise run mc`). The pinned mise installs Erlang precompiled on this image
# today; the apt build deps below are only insurance for its kerl fallback,
# for a future OTP 29 resolution with no precompiled build published yet
# (mise.toml floats on "29" and there is no mise.lock).
# mise comes from its release asset, pinned by version and checksum (not the
# mise.run installer, which is whatever that site serves at the time), so a new
# mise release cannot break every new container. Bump the version and checksums
# (from the release's SHASUMS256.txt) with mise.toml when a tool needs a newer
# mise. Its shims reach PATH through remoteEnv in devcontainer.json.
mise_version=v2026.9.9
case "$(dpkg --print-architecture)" in
  amd64)
    mise_arch=x64
    mise_sha256=bd481434a65ede6b2ec6162b88f129e5c6b94cf9de808b8ee7c6f027b13b4589
    ;;
  arm64)
    mise_arch=arm64
    mise_sha256=e98b7644f8fe908c7b6b9086de215eaa422736d44f8a72d8bb39cb73f7477720
    ;;
  *)
    echo "error: no pinned mise for $(dpkg --print-architecture)" >&2
    exit 1
    ;;
esac
mkdir -p "$HOME/.local/bin"
curl -fsSL "https://github.com/jdx/mise/releases/download/$mise_version/mise-$mise_version-linux-$mise_arch" -o "$HOME/.local/bin/mise"
echo "$mise_sha256  $HOME/.local/bin/mise" | sha256sum -c -
chmod +x "$HOME/.local/bin/mise"
sudo ln -sf "$HOME/.local/bin/mise" /usr/local/bin/mise
sudo apt-get update
sudo apt-get install -y --no-install-recommends build-essential autoconf m4 libncurses-dev libssl-dev
sudo rm -rf /var/lib/apt/lists/*
mise trust
mise install

# First-run terminal notice, rendered by the devcontainers base image.
sudo mkdir -p /usr/local/etc/vscode-dev-containers
sudo tee /usr/local/etc/vscode-dev-containers/first-run-notice.txt >/dev/null <<'EOF'
HAL-C2 devcontainer

  vp test run <files>   run the tests you touched (vp lint <files> to lint)
  mise run mc           run the dev MC (port 3780, forwarded)

Details: docs/internals/devcontainer.md
EOF
