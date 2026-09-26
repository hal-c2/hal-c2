# HAL-C2

HAL-C2 is an "agent harness control surface". It enables control of the agents on your machine).

Works with your subscriptions on Claude Code, Codex, Cursor, Grok Build, OpenCode, and Google Antigravity. If they're set up on your computer, HAL-C2 can control them.

## T3 Code Fork

This is friendly fork. We are standing on the shoulders of giants, I would never have created this and have been a happy user of T3.
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

### Terminal UI (over SSH, no port forwarding)

If you run a T3 Code server on a remote machine, you can monitor and drive its
threads from a terminal UI that talks to the already-running local server — no
port forwarding required. The TUI renders with [OpenTUI](https://opentui.com)
and runs on [Bun](https://bun.sh), so install Bun on the box first:

```bash
ssh my-remote-box
curl -fsSL https://bun.sh/install | bash   # if Bun isn't already installed
t3 tui                                      # or: npx t3@latest tui
```

`t3 tui` (Node) bootstraps auth and launches the UI in a Bun subprocess; if Bun
isn't on `PATH` it prints an install hint and exits.

The prompt is always ready: pick a thread with `↑`/`↓` and just start typing,
then press `Enter` to send. Conversations render as Markdown and follow the
latest reply; scroll with `PgUp`/`PgDn`. The TUI also lets you approve/deny tool
prompts (`^A`/`^R`), interrupt a running turn (`^G`), start new threads (`^N`),
and attach to a thread's terminal (`^E`; `Ctrl-Q` detaches). Start a server
first with `t3 serve` if one isn't already running. Long conversations stay
responsive by showing a bounded page; use the earlier/newer rows to move through
older history.

## Some notes

We are very very early in this project. Expect bugs.

We are (mostly) not accepting contributions yet. Small fixes may be considered. Big features will not be.

## Documentation

Full docs live in [docs/](./docs). There's no docs site yet.

- [Install and first run](./docs/user/install.md)
- [Permission modes](./docs/user/permission-modes.md)
- [Keyboard shortcuts](./docs/user/keybindings.md)
- [Project settings](./docs/user/project-settings.md)
- [Appearance preferences](./docs/user/appearance.md)
- [Remote access from a phone or another machine](./docs/user/remote-access.md)
- [Keeping app and server in sync](./docs/user/updating.md)
- [Source control integrations](./docs/user/source-control.md)
- Multiple accounts: [Codex](./docs/user/providers-codex.md) · [Claude](./docs/user/providers-claude.md)
- [Run T3 Code as a background service](./docs/user/background-service.md)

Building from source? Start at [docs/internals/overview.md](./docs/internals/overview.md).

## If you REALLY want to contribute still.... read this first

### Install `vp`

T3 Code uses Vite+ so you'll need to install the global `vp` command-line tool.

#### macOS / Linux

```bash
curl -fsSL https://vite.plus | bash
```

#### Windows

```bash
irm https://vite.plus/ps1 | iex
```

Checkout their getting started guide for more information: https://viteplus.dev/guide/

### Install dependencies

```bash
vp i
```

Read [CONTRIBUTING.md](./CONTRIBUTING.md) before reporting a bug or opening a PR.

Have a feature request? Start an [Ideas discussion](https://github.com/pingdotgg/t3code/discussions/categories/ideas).
