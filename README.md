<p align="center">
  <img src="./assets/brand/hal-c2-avatar.svg" width="160" alt="" />
</p>

<h1 align="center"><img src="./assets/brand/hal-c2-logotype.svg" height="44" alt="HAL-C2" /></h1>

HAL-C2 is an "agent harness control surface". It enables control of the agents on your machine).

Works with your subscriptions on Claude Code, Codex, Cursor, Grok Build, OpenCode, and Google Antigravity. If they're set up on your computer, HAL-C2 can control them.

## T3 Code Fork

This is friendly fork. We are standing on the shoulders of giants, I would never have created this and have been a happy user of T3 Code.
I just ended up make a bit too many modifications and they are too big to make sense for T3 Code.

This is still a work in progress you should still use T3 Code unless you are fine with things breaking and want to help.

## What is different

Customisation is the heart of the changes I'm making. Your setup is not going to be the same as my setup and that is great. So plugins and extending
the ui through a fully hot updatable qml shells. If you want multiple windows, add charts, see you issue from your issue tracker you should not have
to wait for a PR to merge and a release for you to be able to use your app the way you want it.

We already have some cool things like a hot updatable backend that doesn't eat all your memory. It also has a cluster mode and can communicate with
other computers.

We have a qml tui so you can customise your tui the way you want it.

We have a qml desktop app which allows for customising your app as much as you want.

## How it fits together

- **The MC** (`hal-c2-mc`, mission control) is the server, an Elixir/OTP app in
  [`apps/server-ex`](./apps/server-ex). Each machine runs one. It drives the provider CLIs,
  keeps threads in its SQLite event log, and hot-reloads new code without dropping agents
  or terminals. MCs on your machines cluster and share one sidebar, and threads move between
  them.
- **The desktop** is a Qt/QML app in [`apps/desktop-qt`](./apps/desktop-qt). Its QML can be
  rearranged and themed live from `~/.config/hal-c2/shell/`.
- **The TUI** is QML too, rendered in the terminal by OpenTUI, in [`apps/tui`](./apps/tui).
- **The phone app** is the desktop's QML with a phone layout, in
  [`apps/mobile-qt`](./apps/mobile-qt). Android first.
- **Plugins** under [`plugins/`](./plugins) extend the MC and the clients. See
  [Plugins](./docs/user/plugins.md).

Every client pairs with an MC by a one-time link, locally, over the LAN or Tailscale.

`apps/server` (Node), `apps/web`, `apps/desktop` (Electron) and `apps/mobile` (React Native) are
upstream's and on their way out. They still build, but new work targets the list above.

## Running from source

Everything runs through [mise](https://mise.jdx.dev), which pins Erlang, Elixir, Node and Bun
in [`mise.toml`](./mise.toml). Besides mise you need:

- `vp`, the [Vite+](https://viteplus.dev/guide/) CLI, for the JS workspace:
  `curl -fsSL https://vite.plus | bash` (Windows: `irm https://vite.plus/ps1 | iex`).
- For the desktop and phone app: Qt 6.9+ and cmake from your system package manager. The
  desktop's [README](./apps/desktop-qt/README.md) lists the Qt modules and the optional FFmpeg.

```sh
mise install          # Erlang, Elixir, Node and Bun
mise run install      # vp i, then the MC's Elixir deps
mise run deps:check   # what is installed and what is missing, Qt and cmake included
```

Then start the MC and a client against it:

```sh
mise run mc           # terminal 1: the MC in the foreground, on 127.0.0.1:3780
mise run desktop      # terminal 2: build the Qt desktop, pair it with that MC, launch it
mise run tui          # or the terminal client on the same MC
mise run mobile       # or the phone app, in a window on this machine
```

A checkout's MC keeps its files in the XDG `hal-c2-dev` profile (`~/.local/share/hal-c2-dev/elixir`
and siblings), apart from an installed HAL-C2, and every checkout and worktree shares it.
`mise run mc --home <dir> --port <port>` runs a second, separate one.

### Day to day

| Task                                                           | Command                                     |
| -------------------------------------------------------------- | ------------------------------------------- |
| Load this checkout's changes into the running MC, no restart   | `mise run mc:reload`                        |
| Print a one-time pairing link (`--tailscale` to publish it)    | `mise run mc:pair`                          |
| Listen on the LAN or tailnet so other devices can pair         | `mise run mc --host <address>`              |
| Show, invite to, join or leave the cluster                     | `mise run mc:cluster [invite \| join LINK]` |
| Install this checkout's plugins into the running MC            | `mise run plugins:install [ID ...]`         |
| Import threads from T3 Code or an older HAL-C2                 | `mise run threads:import`                   |
| Build the desktop without launching it                         | `mise run desktop:build`                    |
| Let the desktop start its own MC, as the installed app does    | `mise run desktop -- --standalone`          |
| Build the phone app's APK and install it on an attached device | `mise run mobile:android`                   |
| List every task                                                | `mise tasks`                                |

### On another machine, over SSH

Run the MC where the agents work and drive it from a terminal there, without port forwarding:

```sh
ssh my-remote-box
cd hal-c2 && mise run mc      # in tmux or similar, if it is not already running
mise run tui                  # in another shell on the same box
```

To reach that MC from your own machine instead, start it with `--host` on a LAN or tailnet
address, run `mise run mc:pair` there, and give the link to a client:
`mise run tui -- --url <link>`, `mise run desktop -- --url <link>`, or the desktop's and phone's
pairing screens.

In the TUI the prompt is always ready: pick a thread with `↑`/`↓`, type, and press `Enter`.
`^A`/`^R` approve or deny a tool prompt, `^G` interrupts a turn, `^N` starts a thread, and `^E`
attaches to its terminal (`Ctrl-Q` detaches).

### Installing your build

```sh
mise run release:install
```

builds a release and installs it for your user: the MC as a background service (systemd on
Linux, launchd on macOS) and the desktop as `hal-c2` with a launcher entry on x86_64 Linux, or as
`~/Applications/HAL-C2.app` on macOS. The installed MC keeps its files in the XDG `hal-c2`
directories and listens on port 3790, so it runs beside a checkout's MC.
`mise run mc:reload --release` moves it to a newer build in place, and `mise run mc:pair --release`
and `mise run plugins:install --release` act on it instead of the dev MC.

### Tests

Behaviour is specified as Gherkin under [`features/`](./features) (read its
[README](./features/README.md) first), and each surface runs its own scenarios:

```sh
mise run features:mc threads/*.feature   # MC scenarios, by glob relative to features/
mise run features:tui tui/*.feature      # TUI scenarios
mise run features:desktop                # the desktop's native and QML tests
mise run features:mobile                 # the phone app's tests
```

[docs/operations/development.md](./docs/operations/development.md) has the rest: state and ports,
driving the desktop headlessly, release builds, and the legacy Node dev server.

## Documentation

Docs live in [docs/](./docs). There's no docs site yet. Some user guides still describe the
legacy Node server and web app.

- [Plugins](./docs/user/plugins.md)
- [Permission modes](./docs/user/permission-modes.md)
- [Keyboard shortcuts](./docs/user/keybindings.md)
- [Project settings](./docs/user/project-settings.md)
- [Appearance preferences](./docs/user/appearance.md)
- [Remote access from a phone or another machine](./docs/user/remote-access.md)
- [Source control integrations](./docs/user/source-control.md)
- Multiple accounts: [Codex](./docs/user/providers-codex.md) · [Claude](./docs/user/providers-claude.md)
- [Run HAL-C2 as a background service](./docs/user/background-service.md)

Working on the code? Start at [docs/internals/overview.md](./docs/internals/overview.md) and the
MC's [README](./apps/server-ex/README.md).

## Some notes

We are very very early in this project. Expect bugs.

We are (mostly) not accepting contributions yet. Small fixes may be considered. Big features will not be.
Read [CONTRIBUTING.md](./CONTRIBUTING.md) before reporting a bug or opening a PR.

Have a feature request? Start an [Ideas discussion](https://github.com/hal-c2/hal-c2/discussions/categories/ideas).
