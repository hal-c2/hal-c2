# Install HAL-C2

HAL-C2 runs coding agents on your computer and lets you control them from its
desktop, web, or mobile app. Set up the machine where the agents will work first.

## Requirements

You need an installed, authenticated provider before starting a thread. You can
launch HAL-C2 and configure providers afterwards.

## Command line

The install script downloads the `hal-c2` archive for your platform from
[GitHub Releases](https://github.com/hal-c2/hal-c2/releases) and verifies it:

```bash
curl -fsSL https://raw.githubusercontent.com/hal-c2/hal-c2/main/scripts/install.sh | sh
```

On Windows, in PowerShell:

```powershell
irm https://raw.githubusercontent.com/hal-c2/hal-c2/main/scripts/install.ps1 | iex
```

This puts `hal-c2` in `~/.local/bin`. If your shell reports `command not found`
afterwards, that directory is not on your `PATH` yet; the installer prints the
line to add. Set `HAL_C2_CHANNEL=nightly` to install the nightly train, or
`HAL_C2_VERSION` to pin an exact version.

| Task                                             | Command                                                       |
| ------------------------------------------------ | ------------------------------------------------------------- |
| Start the server and open the web app            | `hal-c2`                                                      |
| Start the server without a browser               | `hal-c2 serve`                                                |
| Keep it running in the background (macOS, Linux) | `hal-c2 service install` ([details](./background-service.md)) |
| Move to the newest release                       | `hal-c2 update`                                               |
| Remove it again                                  | `hal-c2 uninstall`                                            |

Run `hal-c2 --help` for the full reference.

The `hal-c2` npm package is not yet published, so `npx hal-c2` does not work
yet.

### Intel Macs

There is no `hal-c2` executable for Intel Macs (the desktop app is available). To
run a server there, build it from source with Node.js 24 and `vp`
([Install vp](https://github.com/hal-c2/hal-c2#running-from-source)):

```bash
git clone https://github.com/hal-c2/hal-c2
cd hal-c2 && vp i && vp run build:desktop
node apps/server/dist/bin.mjs
```

`hal-c2 update` and the background service do not apply to a server run this way;
update it with `git pull` and a rebuild.

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
`hal-c2-service threads import` in a terminal while HAL-C2 is running. It lists
the threads of T3 Code and of an earlier HAL-C2 on this machine; mark the ones
you want with Space and press Enter. Each comes with its subagent threads,
attachments and terminal scrollback, and the old install is only read.

Worktrees your threads already use stay where they are, such as under
`~/.t3/worktrees`, and keep working. New worktrees go to HAL-C2's data
directory. Keep the old worktrees as long as a thread still works in one of
them.

To start fresh instead, start HAL-C2 the first time with `HAL_C2_NO_MIGRATE=1`.
HAL-C2 remembers the choice and does not copy later either. To copy again, stop
HAL-C2 and delete its data directory and `~/.local/state/hal-c2/migrated-from.json`.
If the copy fails, HAL-C2 starts empty and logs why; your old directory is left
as it was.

## Desktop app

Download a release from [GitHub Releases](https://github.com/hal-c2/hal-c2/releases).
Package-manager installs (winget, Homebrew, AUR) are not yet published for HAL-C2.

### Windows Subsystem for Linux

Choose a WSL distro in **Settings → Connections** to run agents and projects
there. Install the provider CLIs inside that distro. HAL-C2 installs its own
server runtime there automatically; the first launch after an app update can
take longer.

### Open a project from a terminal

With the desktop app already running on the same machine:

```bash
hal-c2 app
```

This opens a new thread for the current directory, adding the project if needed.
Pass a path, such as `hal-c2 app ../my-project`, to open another directory. It requires
the desktop app, so a standalone server or an SSH session is not enough. If the
command cannot reach the app, start or update the desktop app and try again.

## Mobile app

The HAL-C2 mobile app is not yet published to the App Store or Google Play;
until it is, build it from source. The phone connects to a server on another machine. Follow
[remote access](./remote-access.md) to link it through HAL-C2 Connect or a pairing URL.

If the app crashes during launch, open Settings → Diagnostics on the next launch
that succeeds. It lists startup crashes from the last 7 days with the error and
component stack that store crash reports leave out. Copy the report and paste it
into an issue on [hal-c2/hal-c2](https://github.com/hal-c2/hal-c2/issues). Error messages can quote values from the app, so read it over
before sharing.

## Providers

Open **Settings → Providers** in the web or desktop app, select the environment,
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
