# Dev container

> For maintainers. Using HAL-C2? See [docs/user](../user/).

`.devcontainer/` gives you a ready-to-code Linux environment for the TypeScript parts of the repo: Ubuntu 24.04, Node 24, pnpm, Rust stable, the global `vp` CLI, and the GitHub CLI. Open the repo in VS Code and "Reopen in Container", or create a GitHub Codespace. Dependency install (`vp i`) runs automatically before you attach.

## What works in the container

- Focused `vp test run <files>`, `vp lint <files>`, package typechecks, the TUI and relay checks, and the resource-monitor cargo build and tests (`vp run build:resource-monitor`, `vp run test:resource-monitor`). (`vpr` is not on PATH here; the curl installer only shims `vp`. Use `vp run <script>` or `node_modules/.bin/vpr` after install.)
- Port 3780, the dev MC's, is forwarded.

## State and safety

`HAL_C2_HOME` points at the workspace's gitignored `.hal-c2`, so all runtime state stays inside the container workspace, mirroring the worktree default. There is no live install to damage inside a container, but the test-data rule from AGENTS.md still holds: copy data in, never point at shared state.

## Caching

Two named volumes keep rebuilds fast and installs off the slow macOS/Windows bind mount: the pnpm store (shared across checkouts, mounted where `vp i` keeps it) and root `node_modules` (per-container, which covers the whole `.pnpm` virtual store since workspace packages just symlink into it). Deleting a container and recreating it reuses both, so a rebuild's `vp i` is seconds, not minutes. The host sees an empty `node_modules`; run host-side tooling inside the container.

## Out of scope

- The container does not install Elixir or mise, so it does not build or run the MC (`apps/server-ex`).
- The Qt desktop and the phone client are host-only: they need Qt, and the phone client the Android SDK and NDK.

## Prebuilds

Container creation from scratch does a full `vp i` plus toolchain installs, which is worth prebuilding. Codespaces prebuilds are configured in repo settings, not files, and pick this config up as-is: the heavy steps live in `onCreateCommand` and `updateContentCommand`, which prebuilds bake in. Restrict prebuilds to one region and one retained version; storage bills per region per version. Note that prebuild snapshots exclude the caching volumes, so a prebuild-first workflow may prefer dropping the mounts. Outside Codespaces, the Dev Container CLI can push a prebuilt image:

```bash
devcontainer build --workspace-folder . --push true --image-name <registry>/hal-c2-devcontainer:latest
```
