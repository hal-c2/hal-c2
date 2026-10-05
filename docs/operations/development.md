# Development

## First checkout

Install `vp` using the [root README](../../README.md#install-vp) and [mise](https://mise.jdx.dev).
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
mise run mc:reload       # compile this checkout and load it into that MC; sockets and agents stay up
mise run desktop           # build the Qt shell, pair it with the running MC, launch
mise run desktop:build     # build only (--release for a Release build)
mise run tui               # bundle apps/tui and open it on the running MC
mise run tui:build         # the TUI bundle; tui depends on it
```

Arguments pass straight through (`mise run desktop -- --help` for the Qt script's own
flags). The build tasks declare their sources, so a dependent task skips them while nothing
changed. The Qt shell pairs with the MC on
`HAL_C2_MC_PORT` (default 3780); `--url` takes a pairing link for another MC, and
`--standalone` starts the shell's own MC from source, as the installed app does, so do not
combine it with `mise run mc` on the same home.

Every checkout and worktree shares the one dev MC, because its files are in the XDG `hal-c2-dev`
profile. `mise run mc:reload` therefore moves that MC to the build of the checkout it is run from,
whichever checkout started it.

The TUI finds the MC through the runtime record and access token the MC keeps in the
XDG `hal-c2-dev` profile, so start `mise run mc` first;
`mise run tui -- --url <link>` pairs it with another MC from an `mc:pair` link instead and
keeps that session for the next `--url <origin>`. Pair the MC into a web client from Settings → Connections with the
URL `mc:pair` prints.

Open the pairing URL printed by the dev runner. The bare origin does not authenticate
a new browser.

Prefer a container? See [Dev container](../internals/devcontainer.md) for VS Code and Codespaces setup.

## Choosing a dev process

Use `vp run dev` for server and web, or `vp run dev:desktop` for the Electron client.
`dev:server` and `dev:web` start those processes separately.
See the [mobile README](../../apps/mobile/README.md) for native builds and Metro.

Flags go directly after the task name, for example `vp run dev --home-dir /tmp/hal-c2-dev`.
Add `--browser` to open a browser automatically.

### State and ports

A linked worktree keeps everything in its own gitignored `.hal-c2`, as `config`, `data`, `state`,
and `cache` directories inside it, even when `HAL_C2_HOME` is set. The main checkout uses the
development profile: `hal-c2-dev` in place of `hal-c2` under each XDG base, so its database is in
`~/.local/share/hal-c2-dev`. An explicit `--home-dir` is a root that wins in both cases. Worktree
state from before the XDG layout (a `.t3`, or `.hal-c2/userdata`) is not read and not migrated;
seed the worktree again instead. Never run a development server against the installed app's
`~/.local/share/hal-c2` and its sibling directories, or against `~/.t3` and `~/.hal-c2`, which
only the one-time migration reads ([storage](../internals/storage.md)). See
[test data](../../AGENTS.md#test-data) for copying a consistent database snapshot.

Read ports from the `[dev-runner]` output. Worktrees derive stable preferences from their paths,
but occupied ports can shift them. `HAL_C2_PORT_OFFSET` or `HAL_C2_DEV_INSTANCE` can select a
different preference when needed.

### Importing threads from T3 Code or the Node server

`mise run threads:import` lists the threads of the T3 Code and Node HAL-C2 installs on this machine
and imports the ones you pick into the running MC, each with its subagent threads, attachments and
terminal scrollback. The install is only read, so its server can stay up. An MC started before this
command existed needs `mise run mc:reload` first.

### Moving a thread between data directories

`vp run thread:export --source <dir> --thread-id <id> --output <archive.json>` exports one thread
with its image attachments, and `vp run thread:import --archive <archive.json> --destination <dir>`
remaps it onto the destination project after backing up its database. `vp run thread:list --source
<dir>` finds thread ids. A source or destination can be a workspace containing `.hal-c2`, a root such as that `.hal-c2`, or
a data directory containing `statev2.sqlite`, such as `~/.local/share/hal-c2-dev` for the main
checkout's development database. A source can also be a T3 Code data directory holding
`state.sqlite`, such as `~/.t3/dev`; a destination cannot.
Stop the destination server before importing. Terminal history can hold credentials, so export
skips it unless you pass `--include-terminal-logs`.

### Sharing and remote debugging

`vp run dev --share` publishes the web port over the machine's tailnet and prints a pairing URL
for that origin. Give the tester the complete URL, including its token. The dev runner removes
its mapping on exit.

Leave `VITE_HTTP_URL` and `VITE_WS_URL` unset. Vite proxies the backend through the browser's
origin so the same build works over localhost and remote connections.

Shared runs enable bundled dev to avoid a network round trip for each import level.
`HAL_C2_BUNDLED_DEV=0` opts out when debugging bundler differences. Two reload traps matter
when changing this setup:

- The web entry must dynamically import the app so React refresh initializes before application
  chunks. Static imports can work on first load and fail after a route split.
- Bundled dev rebuilds Tailwind through watched files. Its ordinary Vite hot-update hook expects
  a server/module graph that Rolldown does not provide.

The workarounds live in the [web entry](../../apps/web/src/bootstrap.ts) and
[Tailwind plugin](../../apps/web/vite/tailwind.ts).

#### Reusable dev credential

Use this only on a hostname where you trust every service. Browsers send cookies to all ports
on that hostname. Any service you visit there can receive the reusable admin credential,
including services unrelated to HAL-C2. If you run untrusted services on that hostname, keep
normal per-environment pairing instead.

To use one browser profile across web dev worktrees on the same hostname, generate one fixed
value once:

```sh
openssl rand -hex 32
```

Put that value in the main checkout's gitignored `.env`:

```dotenv
HAL_C2_DEV_AUTH_TOKEN=<the value generated above>
```

The `hal-c2.json` Setup Worktree commands on Unix and Windows link that file to each worktree's
`.env`. The dev runner reads repository env files at startup. `.env.local` and inherited process
environment values override `.env`, so no per-worktree export is needed after setup.

For a manual worktree or launcher without that link, export the same fixed value instead:

```sh
export HAL_C2_DEV_AUTH_TOKEN="<the value generated above>"
```

Do not generate a new value at startup. Start or restart `vp run dev --share` after configuration,
then open its printed startup pairing URL once per browser profile on that hostname. Later web dev
servers on the same hostname accept the shared cookie across ports. The cookie expires after 30
days. Reload an old tab if its URL now serves a replacement environment.

The token and startup pairing URLs are reusable administrative secrets. Never put them in a
commit, pull request, or public output. Every server still seeds its own auth database record at
startup and keeps its own SQLite data, signing key, and revocation state. Desktop and non-dev
servers ignore the value. See [environment authentication](../internals/environment-auth.md#reusable-dev-credential)
for the security model.

## Checks

Run checks for the files and packages you changed:

```sh
vp test run <files>
vp lint <files>
vp run --filter <package> typecheck
```

Behaviour scenarios run per surface with `mise run features:mc <globs>`, `features:tui` and
`features:desktop`; see [running features](../../features/README.md#running).
Use `vp run lint:mobile` for native mobile changes. CI covers the MC, the TUI and the Qt desktop
([ci.yml](../../.github/workflows/ci.yml), [desktop-qt.yml](../../.github/workflows/desktop-qt.yml));
the legacy Node server, web, Electron and React Native apps have no CI, so check what you touch there
by hand.

### Unused code

`vp run knip:check` checks unused files and dependencies across the repo, then
unused runtime exports in `apps/server`, `apps/desktop`, `apps/web`, and every internal package under
`packages/`. CI does not run it.
Exported types and Effect schemas are allowed without consumers. The schema preprocessor
recognizes schema types, including aliases and schema classes; functions that create or decode
schemas remain checked. Canonical Effect service construction APIs stay exported with an explicit
`@public` annotation, which Knip recognizes. Completely unused files remain checked too.
Named exports in web UI component modules are kept as complete component sets. Knip ignores
unused exports in `apps/web/src/components/ui/*.tsx`, while still reporting an entire unused file.
Use `vp run knip --workspace apps/web` to audit one workspace, including exports,
or `vp run knip:production --workspace apps/web` to find code kept alive only by tests.
The full export audit still has findings and is not a repo-wide CI gate. Extend the
export check's workspace selectors as more workspaces become clean. Review callers before
deleting code; production mode can also report development scripts and test fixtures.
Runtime-discovered entrypoints and dependency exceptions belong in [knip.jsonc](../../knip.jsonc).

## Desktop artifacts

Local artifact builds are unsigned by default and write to `release/`:

```sh
vp run dist:desktop:dmg
vp run dist:desktop:linux
vp run dist:desktop:win
```

DMGs default to the host architecture. Use `--arch` to choose another target and `--keep-stage`
to retain packaging files for inspection. Run `vp run dist:desktop:artifact --help` for other
options.

### Linux AppImage prerequisites

Build on Linux because the browser-secret helper links against the host's libsecret. Install
Rust, C/C++ build tools, libsecret development headers, pkg-config, and ImageMagick.

Ubuntu and Debian:

```sh
sudo apt-get update
sudo apt-get install cargo rustc build-essential libsecret-1-dev pkg-config imagemagick
```

Fedora:

```sh
sudo dnf install rust cargo gcc gcc-c++ make libsecret-devel pkgconf-pkg-config ImageMagick
```

Arch Linux:

```sh
sudo pacman -S rust base-devel libsecret pkgconf imagemagick
```

The C toolchain, pkg-config, and libsecret headers are also needed for Linux desktop development.

### macOS DMG prerequisites

Install the Xcode Command Line Tools with `xcode-select --install` and install Rust.
For a cross-architecture or universal build, add the requested Rust targets:

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin
```

### Windows installer prerequisites

Install Rust, Python 3, and Visual Studio Build Tools with **Desktop development with C++**.
Include the Windows SDK and the MSVC build tools and Spectre-mitigated libraries for the target
architecture. Add its Rust target:

```powershell
rustup target add x86_64-pc-windows-msvc
# For an ARM64 installer:
rustup target add aarch64-pc-windows-msvc
```

NSIS is downloaded by electron-builder. WSL support additionally needs the Linux CLI archive
passed as `--wsl-runtime`; see the
[release runbook](./release.md#windows-payload-topology).

### Signing and passkeys

Add `--signed` after setting the platform credentials in the
[release runbook](./release.md#signing-local-electron-builds). macOS passkeys need a signed, provisioned app; follow the
[Connect setup](./connect-setup.md#desktop-passkeys) for local signing and renderer HMR.
