# Dev container

> For maintainers. Using HAL-C2? See [docs/user](../user/).

`.devcontainer/` gives you a ready-to-code Linux environment for the repo: Ubuntu 24.04, Node 24, pnpm, Rust stable, the global `vp` CLI, the GitHub CLI, and mise with the toolchain named in `mise.toml` (Erlang, Elixir, Node, Bun), so the MC runs too. Bare `node` is the devcontainer feature's Node 24; `mise run` uses mise.toml's pinned node. Open the repo in VS Code and "Reopen in Container", or create a GitHub Codespace. Dependency install (`vp i`, and `mise run install:mc` for the MC's Elixir deps) runs automatically before you attach.

## What works in the container

- Focused `vp test run <files>`, `vp lint <files>`, package typechecks, the TUI and relay checks, and the resource-monitor cargo build and tests (`vp run build:resource-monitor`, `vp run test:resource-monitor`). (`vpr` is not on PATH here; the curl installer only shims `vp`. Use `vp run <script>` or `node_modules/.bin/vpr` after install.)
- `mise run mc`, the dev MC on port 3780, which is forwarded. mise's shims are on PATH (`remoteEnv`), so bare `mix test` and `mix hal_c2.server` work in a terminal too.

## State and safety

`HAL_C2_HOME` points at the workspace's gitignored `.hal-c2`, so all runtime state stays inside the container workspace, mirroring the worktree default. There is no live install to damage inside a container, but the test-data rule from AGENTS.md still holds: copy data in, never point at shared state.

## Caching

Two named volumes keep rebuilds fast and installs off the slow macOS/Windows bind mount: the pnpm store (shared across checkouts, mounted where `vp i` keeps it) and root `node_modules` (per-container, which covers the whole `.pnpm` virtual store since workspace packages just symlink into it). Deleting a container and recreating it reuses both, so a rebuild's `vp i` is seconds, not minutes. The host sees an empty `node_modules`; run host-side tooling inside the container.

## Out of scope

- The Qt desktop and the phone client are host-only: they need Qt, and the phone client the Android SDK and NDK.

## Prebuilds

Container creation from scratch does a full `vp i`, the mise toolchain (precompiled downloads today; the apt build deps in `on-create.sh` only cover mise's kerl fallback for a future OTP 29 with no precompiled build yet) and the MC's Elixir deps, which is worth prebuilding. Codespaces prebuilds are configured in repo settings, not files, and pick this config up as-is: the heavy steps live in `onCreateCommand` and `updateContentCommand`, which prebuilds bake in. Restrict prebuilds to one region and one retained version; storage bills per region per version. Note that prebuild snapshots exclude the caching volumes, so a prebuild-first workflow may prefer dropping the mounts. Outside Codespaces, the Dev Container CLI can push a prebuilt image:

```bash
devcontainer build --workspace-folder . --push true --image-name <registry>/hal-c2-devcontainer:latest
```
