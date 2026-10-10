# Install HAL-C2

HAL-C2 runs coding agents on your computer and lets you control them from its
desktop, terminal, or phone app. The MC (mission control) is the server that
runs the agents and keeps your threads; set it up on the machine where the
agents will work first.

## Requirements

You need an installed, authenticated provider before starting a thread. You can
launch HAL-C2 and configure providers afterwards.

## Command line

Each release publishes the MC as a single file for macOS on Apple Silicon
(`darwin-arm64`) and for Linux on x86_64 (`linux-x64`) and arm64 (`linux-arm64`).
Download `hal-c2-mc-<version>-<platform>` from
[GitHub Releases](https://github.com/hal-c2/hal-c2/releases), where the releases
named `mc-v<version>` hold it, beside its `.sha256`. It needs no Erlang or Elixir.
Make it executable and run it:

```bash
chmod +x hal-c2-mc-<version>-<platform>
./hal-c2-mc-<version>-<platform>
```

The first run unpacks the MC into HAL-C2's data directory and starts it; every
run after that starts the version the MC last moved to. It listens on
`127.0.0.1:3790`.

| Task                                             | Command                                      |
| ------------------------------------------------ | -------------------------------------------- |
| Start the MC in the terminal                     | `./hal-c2-mc-<version>-<platform>`           |
| Keep it running in the background (macOS, Linux) | `./hal-c2-mc-<version>-<platform> install`   |
| Inspect the background service                   | `./hal-c2-mc-<version>-<platform> status`    |
| Restart the background service                   | `./hal-c2-mc-<version>-<platform> restart`   |
| Stop and remove the background service           | `./hal-c2-mc-<version>-<platform> uninstall` |

See [Running in the background](./background-service.md) for what the service does.
An MC moves to a newer version from the client's update notice, and passes it on to
the other MCs in its cluster ([Updating HAL-C2](./updating.md)).

There is no Windows or Intel Mac build yet.

## Where HAL-C2 keeps its files

HAL-C2 follows the XDG Base Directory layout on every platform, macOS included,
and keeps four kinds of files apart:

| Kind   | What it holds                                                      | Linux and macOS         | Windows                       |
| ------ | ------------------------------------------------------------------ | ----------------------- | ----------------------------- |
| config | Settings, keybindings, themes, and your desktop shell              | `~/.config/hal-c2`      | `%APPDATA%\hal-c2\config`     |
| data   | Threads and projects, secrets, attachments, and new worktrees      | `~/.local/share/hal-c2` | `%LOCALAPPDATA%\hal-c2\data`  |
| state  | Logs and service state                                             | `~/.local/state/hal-c2` | `%LOCALAPPDATA%\hal-c2\state` |
| cache  | Downloaded tools and anything else HAL-C2 can fetch or build again | `~/.cache/hal-c2`       | `%LOCALAPPDATA%\hal-c2\cache` |

To back up HAL-C2, copy its config and data directories. Deleting the cache
directory loses nothing you made. The HAL-C2 MC keeps its own files in an
`elixir` directory inside each of these.

Set `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, or `XDG_CACHE_HOME` to
an absolute path to move one kind. Set `HAL_C2_HOME` to keep all four under one
directory instead, as its `config`, `data`, `state`, and `cache` subdirectories.

### Coming from T3 Code

The first time HAL-C2 starts with no data of its own, it copies your projects,
threads, settings, secrets, and logs from T3 Code's `~/.t3` into the directories
above. If you moved T3 Code with `T3CODE_HOME`, it copies from there instead,
and if an earlier HAL-C2 release left a `~/.hal-c2`, from that.

This happens once. HAL-C2 never changes `~/.t3` and never reads it again, so T3
Code keeps working, and changes you make in either app afterwards stay in that
app. Caches and downloaded tools are not copied; HAL-C2 fetches them again when
it needs them.

To bring over threads you made in T3 Code after that, run
`./hal-c2-mc-<version>-<platform> threads import` in a terminal while HAL-C2 is
running. It lists the threads of T3 Code and of an earlier HAL-C2 on this machine;
mark the ones you want with Space and press Enter. Each comes with its subagent
threads, attachments and terminal scrollback, and the old install is only read.

Worktrees your threads already use stay where they are, such as under
`~/.t3/worktrees`, and keep working. New worktrees go to HAL-C2's data
directory. Keep the old worktrees as long as a thread still works in one of
them.

To start fresh instead, start HAL-C2 the first time with `HAL_C2_NO_MIGRATE=1`.
HAL-C2 remembers the choice and does not copy later either. To copy again, stop
HAL-C2 and delete its data directory and `~/.local/state/hal-c2/migrated-from.json`.
If the copy fails, HAL-C2 starts empty and logs why; your old directory is left
as it was.

## Desktop, terminal, and phone apps

None of the clients has a download yet. To use one, run it from source: the
[README](../../README.md#running-from-source) lists what to install, and
`mise run release:install` builds the MC, and on x86_64 Linux and macOS the
desktop app, and installs them for your user. The desktop app uses the MC already
running on the same files, and starts the MC it carries when there is none. Link a
phone or another computer to an MC with [remote access](./remote-access.md).

## Providers

Open **Settings → Providers** in the desktop app, select the environment,
and enable the provider you want. Installation, login, and configuration belong
to that environment's machine, even when you connect from a phone or another
computer.

| Provider    | Install and authenticate                                                                     |
| ----------- | -------------------------------------------------------------------------------------------- |
| Codex       | Install [Codex CLI](https://developers.openai.com/codex/cli), then run `codex login`.        |
| Claude      | Install [Claude Code](https://claude.com/product/claude-code), then run `claude auth login`. |
| Cursor      | Install [Cursor CLI](https://cursor.com/cli), then run `agent login`.                        |
| Grok Build  | Install [Grok Build CLI](https://x.ai/cli), then run `grok login`.                           |
| OpenCode    | Install [OpenCode](https://opencode.ai), then run `opencode auth login`.                     |
| Antigravity | Install and sign in with Google from HAL-C2's provider settings.                             |
| Pi          | Install [Pi](https://pi.dev), then run `pi` once to finish its login or API-key setup.       |

Provider CLIs must be on the server's `PATH`. If HAL-C2 cannot find one, set its
**Binary path** in provider settings, especially when using a version manager.
Cursor's executable is `cursor-agent`, although its login command is
`agent login`. Antigravity can use its managed runtime without a `PATH` entry.

HAL-C2 warns when a provider version has known compatibility problems with your
release. Check **Settings → Providers** on that environment for the recommended
version or range. When its package manager supports installing a specific version,
you can install the recommendation there. Otherwise use the provider's installer
on the environment's machine. An unlisted version is unverified.

When a provider CLI is behind its latest release, its provider card shows the
available version. **Update now** appears only when HAL-C2 can tell which
installer owns the CLI (its own update command, Homebrew, or a global npm, pnpm,
bun, or Vite+ install) and runs that installer. Otherwise update the CLI the same
way you installed it. Homebrew installs compare against the version Homebrew
offers, which can trail the npm release by a few hours.

Add another provider instance for a separate account or configuration. Each
instance can have its own environment variables, such as API keys or a custom
base URL. Mark secret values as sensitive; after saving, HAL-C2 does not display
their original values.

For provider-specific setup and accounts, see [Codex](./providers-codex.md),
[Claude](./providers-claude.md), [OpenCode](./providers-opencode.md),
[Antigravity](./providers-antigravity.md), and [Pi](./providers-pi.md).

## Next steps

- [Working with threads](./thread-sidebar.md): start tasks and organize parallel work.
- [Permission modes](./permission-modes.md): choose when agents ask before acting.
- [Remote access](./remote-access.md): connect from another device.
- [Running in the background](./background-service.md): keep a Linux or macOS host available.
- [Updating HAL-C2](./updating.md): update the app and connected servers.
