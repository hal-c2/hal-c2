# Development

## First checkout

Install `vp` using the [root README](../../README.md#running-from-source) and [mise](https://mise.jdx.dev).
From the repository root:

```sh
mise install       # Erlang, Elixir, Node and Bun, pinned in mise.toml
mise run install   # vp i, then mix deps.get and mix compile in apps/server-ex
mise run deps:check
```

`deps:check` also reports cmake and Qt 6.9+, which the Qt desktop needs from the system package
manager. Without mise: `vp i` at the root, `mix deps.get` in `apps/server-ex`.

## Running the target surfaces

```sh
mise run mc              # MC in the foreground, ready to cluster (--host, --port, --home)
mise run mc:cluster      # that MC's cluster: no args lists it; invite, join LINK, remove MEMBER
mise run mc:update-cluster olafura@ai-beast   # other machines' checkouts and dev MCs to this commit, over SSH
mise run mc:pair         # one-time pairing URL for that MC (--tailscale to publish it)
mise run mc:pair --release     # the same for the installed MC, when both run
mise run mc:reload       # compile this checkout and load it into that MC; sockets and agents stay up
mise run mc:reload --release   # build a release of this checkout and move the installed MC to it
mise run plugins:install [ID ...]   # this checkout's plugins/ into that MC, loaded at once (--release for the installed MC)
mise run desktop           # build the Qt shell, pair it with the running MC, launch
mise run desktop:build     # build only (--release for a Release build)
mise run desktop:cua       # the Qt shell in a headless sandbox for cua-driver; desktop:cua:call, desktop:cua:stop
mise run mobile            # build the phone client for this machine and run it, state in .hal-c2/mobile
mise run mobile:android    # the phone client's APK; with one device or emulator attached, install and start it
mise run tui               # bundle apps/tui and open it on the running MC
mise run tui:build         # the TUI bundle; tui depends on it
mise run release:linux     # the MC and the desktop AppImage in release/ (release:mc for the MC alone)
mise run release:macos     # the MC and the zipped desktop app in release/
mise run release:install   # build and install: the MC as this user's background service, the desktop as a launcher entry or in ~/Applications
```

Arguments pass straight through (`mise run desktop -- --help` for the Qt script's own
flags). The build tasks declare their sources, so a dependent task skips them while nothing
changed. The Qt shell pairs with the MC on
`HAL_C2_MC_PORT` (default 3780); `--url` takes a pairing link for another MC, and
`--standalone` starts the shell's own MC from source, as the installed app does; without
`--home-dir` that is the dev profile's MC, so do not combine it with `mise run mc`.

The Qt shell `mise run desktop` builds keeps its files in the XDG `hal-c2-dev` profile, beside
the dev MC's (`~/.config/hal-c2-dev/shell` for the rice, and so on), not in the checkout;
`--home-dir <dir>` gives one run a root of its own.

Every checkout and worktree shares the one dev MC, because its files are in the XDG `hal-c2-dev`
profile. `mise run mc:reload` therefore moves that MC to the build of the checkout it is run from,
whichever checkout started it.

The TUI finds the MC through the runtime record and access token the MC keeps in the
XDG `hal-c2-dev` profile, so start `mise run mc` first;
`mise run tui -- --url <link>` pairs it with another MC from an `mc:pair` link instead and
keeps that session for the next `--url <origin>`. Pair the MC into another client from Settings →
Connections with the URL `mc:pair` prints.

Prefer a container? See [Dev container](../internals/devcontainer.md) for VS Code and Codespaces setup.

### Driving the desktop with cua-driver

On Linux, `mise run desktop:cua` runs the Qt shell where [cua-driver](https://cua.ai) can see and
drive it, without touching your display or session bus. It needs sway (with Xwayland), dbus,
at-spi2-core and `cua-driver` on the `PATH`. Everything else is scratch: a headless sway with its own
bus and AT-SPI registry, and an MC and app home under `.hal-c2/cua` (or `HAL_C2_CUA_HOME`).
`--seed <hal-c2.sqlite>` snapshots a database into that MC read-only, so a copy of the dev MC's
works. `--url <pairing link>` attaches to another MC instead. Arguments it does not know go to
`hal-c2-qt`, such as `--qml-dir apps/desktop-qt/qml`. Running it again relaunches the app.

```sh
mise run desktop:cua --seed ~/.local/share/hal-c2-dev/elixir/hal-c2.sqlite
mise run desktop:cua:call get_window_state '{"screenshot_out_file":"/tmp/shot.png"}'
mise run desktop:cua:call scroll '{"x":700,"y":400,"direction":"up","amount":1}'
mise run desktop:cua:stop
```

`desktop:cua:call` fills in the app's pid, a shared `session` and `"delivery_mode":"foreground"`
wherever the tool takes them:

- Pointer coordinates are pixels of the session's last `get_window_state` screenshot. Without one,
  the call fails with `screenshot_context_missing`.
- cua-driver's default background delivery crashes Qt's xcb plugin.
- `desktop:cua` also turns off cua-driver's agent cursor. Its overlay window would take the
  clicks meant for the app.

## State

The MC, the Qt shell and the TUI keep their files in the XDG `hal-c2-dev` profile (`hal-c2-dev` in
place of `hal-c2` under each base), so the dev MC's database is in
`~/.local/share/hal-c2-dev/elixir`. The phone app and `desktop:cua` keep theirs in the worktree's
gitignored `.hal-c2` (`.hal-c2/mobile`, `.hal-c2/cua`). `HAL_C2_MC_HOME` (or `mise run mc --home`)
gives an MC a root of its own. Never run a development MC against the installed app's
`~/.local/share/hal-c2` and its sibling directories, or against `~/.t3` and `~/.hal-c2`, which
only the one-time migration reads ([storage](../internals/storage.md)). See
[test data](../../AGENTS.md#test-data) for copying a consistent database snapshot.

### Reusable dev credential

A development MC (the one `mise run mc` runs from source) accepts one
`HAL_C2_DEV_AUTH_TOKEN` as an administrative bearer token, so one client can sign in to the MC of
every worktree without pairing each. Set it in the environment `mise run mc` starts in: the MC reads
its process environment and no `.env` file. Each MC seeds its own session record from the
value's hash, so revoking it in one worktree does not affect another, and removing or rotating
the value and restarting invalidates it. Release builds ignore it. Never commit or publish the
value ([environment auth](../internals/environment-auth.md#reusable-dev-credential)).

### Importing threads from T3 Code or an older HAL-C2

`mise run threads:import` lists the threads of the T3 Code and older HAL-C2 installs on this machine
and imports the ones you pick into the running MC, each with its subagent threads, attachments and
terminal scrollback. The install is only read, so its server can stay up. An MC started before this
command existed needs `mise run mc:reload` first. That is the MC run from the checkout;
`mise run threads:import --release` imports into the installed MC instead, which also has the picker
as `hal-c2-service threads import`.

## Checks

Run checks for the files and packages you changed:

```sh
vp test run <files>
vp lint <files>
vp run --filter <package> typecheck
```

Behaviour scenarios run per surface with `mise run features:mc <globs>`, `features:tui` and
`features:desktop`; see [running features](../../features/README.md#running).
`mise run desktop:lint` runs qmllint over the desktop's QML. CI covers the MC, the TUI and the Qt
desktop ([ci.yml](../../.github/workflows/ci.yml), [desktop-qt.yml](../../.github/workflows/desktop-qt.yml)).

### Unused code

`vp run knip:check` checks unused files and dependencies across the repo, then unused runtime
exports in the TypeScript workspaces. CI does not run it.
Exported types and Effect schemas are allowed without consumers. The schema preprocessor
recognizes schema types, including aliases and schema classes; functions that create or decode
schemas remain checked. Canonical Effect service construction APIs stay exported with an explicit
`@public` annotation, which Knip recognizes. Completely unused files remain checked too.
Use `vp run knip --workspace <dir>` to audit one workspace, including exports,
or `vp run knip:production --workspace <dir>` to find code kept alive only by tests.
Review callers before deleting code; production mode can also report development scripts and test
fixtures. Runtime-discovered entrypoints and dependency exceptions belong in
[knip.jsonc](../../knip.jsonc).

## Desktop artifacts

`mise run release:linux` and `release:macos` build the desktop into `release/` beside the MC
([release](./release.md#building-one-locally)). They are unsigned: the AppImage tooling
(linuxdeploy and its Qt plugin) is downloaded on first use, and the macOS app is signed ad hoc.
Qt, cmake and the other build dependencies are those of `mise run desktop`
([desktop README](../../apps/desktop-qt/README.md)).
