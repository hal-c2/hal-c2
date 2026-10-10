# Storage layout

> For maintainers. Using HAL-C2? See [where HAL-C2 keeps its files](../user/install.md#where-hal-c2-keeps-its-files).

HAL-C2 keeps its files in the XDG Base Directory layout: config, data, state and cache, each in a
directory named `hal-c2` under its own base, or all four under one root. What goes in which kind,
and every precedence rule, is specified in
[storage-layout.feature](../../features/mc/platform/storage-layout.feature); the one-time copy
from an old home is in [storage-migration.feature](../../features/mc/platform/storage-migration.feature);
the MC's side is in [mc-startup.feature](../../features/mc/platform/mc-startup.feature).
This page records why the rules are what they are.

## One resolver per language

[`xdgDirs.ts`](../../packages/shared/src/xdgDirs.ts) is the only resolver for TypeScript: the TUI
and the desktop's Node host call it, and it is pure so each can. The MC mirrors the same rules in
Elixir ([`paths.ex`](../../apps/server-ex/lib/hal_c2/paths.ex)) and the Qt shell in C++
([`StoragePaths.h`](../../apps/desktop-qt/src/StoragePaths.h)). A rule change touches all three;
the feature files are what keeps them in agreement.

## XDG on macOS, not `~/Library`

A Mac is usually reached the same way as a Linux box: over SSH, from a service unit, from a
shell script that does not know which OS it is on. One set of POSIX defaults lets those scripts
and the docs name one path, and `~/Library/Application Support` has a space that unquoted shell
breaks on. The `XDG_*` variables are honoured on every OS, only when absolute, as the spec says.
`QStandardPaths` is not used for the same reason: it would send the Qt shell to `~/Library`
while the MC it talks to keeps its files under the XDG paths.

## Windows

Config goes to `%APPDATA%` (roaming, so settings follow a roaming profile); data, state and cache
go to `%LOCALAPPDATA%`. Because those three share one base, Windows nests the kind below the app
directory (`%LOCALAPPDATA%\hal-c2\data`) where Linux and macOS give each kind its own base. Runtime
is the state directory.

## Profiles and roots

The development profile swaps `hal-c2` for `hal-c2-dev` under each base, so a dev server from the
main checkout never opens the installed app's database. It only applies without a root. A root
(`HAL_C2_HOME`, a worktree's `.hal-c2`, `--home-dir`, `--base-dir`) holds exactly one profile, with
no `dev` or `userdata` level; the old layout's levels existed to keep two profiles apart in one
home, and XDG does that with the directory name instead.

`HAL_C2_HOME` that names `~/.t3` or `~/.hal-c2` exactly is not a root. Service units written
before always set it to the home they were installed with, so honouring it would pin those users
to the old home forever. It is treated as a migration source instead, which means nobody can point
HAL-C2 at an old home in place, deliberately or not.

## The MC's `elixir` level

The MC adds an `elixir` level inside every kind (`data/elixir`, `state/elixir/logs`), so its
`settings.json`, `environment-id`, secrets and worktrees stay apart from what the Qt shell and the
TUI keep in the same root, and from the files an install that came from the Node server still
holds. `HAL_C2_MC_HOME` is a root for the MC alone, so it has no `elixir` level, and it outranks
`HAL_C2_HOME` for the MC.

## Migration copies, once

`~/.t3` and `~/.hal-c2` are sources, never homes. A user coming from T3 Code may still run it
against `~/.t3`, and HAL-C2's schema migrations would break T3 Code if they ran on its database.
Copying leaves T3 Code working and makes going back trivial. It also retires the old behaviour of
using `~/.t3` in place, which made a developer's T3 Code install the live HAL-C2 install.

- It runs only when the data directory holds no data of its own and there is no
  `migrated-from.json` in the state directory. The record lives in state, not data, so deleting
  the data directory does not copy the old home back. `HAL_C2_NO_MIGRATE=1` writes the record too
  (`skipped`), so a later start without the variable does not migrate. The MC copies what it
  keeps under `<old home>/elixir` and records the source; the Node server's own state beside it
  is not read.
- Databases are copied with `VACUUM INTO`: the source may be open, and a file copy of a live
  SQLite database is a corrupt copy. Everything lands in a `data.migrating-<pid>` directory that is
  renamed into place, so a crash or failure leaves no half-migrated data directory and the next
  start begins again. A failure never blocks startup; HAL-C2 starts empty with a warning.
- Caches are not copied: they can be fetched again, and old tool binaries and `runtime/versions`
  are version-specific anyway. Anything put in the cache kind must be safe to delete. ACP sign-ins
  lived in `caches/` but are credentials, so they move to `data/acp-auth` and are copied.
- Existing worktrees are not moved. Git registers a worktree in its repository by absolute path,
  and the thread history refers to it by that path; moving one would mean `git worktree move` in
  every repository and rewriting immutable events. Old worktrees stay in `~/.t3/worktrees` and agents keep working there, so the
  old home is still in use by those threads even though HAL-C2 never reads its state again. New
  worktrees go to `data/worktrees`.
- A worktree's own `.t3` or pre-XDG `.hal-c2/userdata` is dev scratch, not a migration source.
