# Desktop (Qt) shell

`apps/desktop-qt` is the desktop client. It
is a compiled Qt 6 / QML binary (`hal-c2-qt`) whose window, chrome, layout and
colours are QML "bricks" a user can rearrange and restyle from
`~/.config/hal-c2/shell/`, fed by the shell's own connection to the MC. It
embeds no web content. Nothing in `apps/server-ex` may become Qt-specific.

## Process model

```text
hal-c2-qt (C++/QML, the shell)
  └─ spawns ─► node apps/desktop-qt/host/main.ts  (the desktop host)
                 └─ spawns ─► bin/hal_c2 start | mix hal_c2.server  (the MC)
NativeShell (McClient) ── WebSocket (protocol 3) ──────────────────► MC
```

- **The shell talks to the MC itself.** `NativeShell` holds its own
  protocol-3 connection (`McClient`), and its C++ controllers own the state
  of every piece of the window.
- **The Node desktop host** owns everything TypeScript-owned: the MC's
  lifecycle today. It reports to the shell over its stdout as newline-delimited
  JSON (`ready {mc: {origin, token}}`, `error {message}`, `exit {code}`); the
  shell closes the host's stdin when it exits, which is the host's cue to stop
  the MC it started.
- **The host starts the MC.** A release
  (`HAL_C2_MC_RELEASE`, else the bundled `hal-c2-mc/`) runs `bin/hal_c2
start`; a checkout without one runs `mix hal_c2.server` in `apps/server-ex`.
  Either gets `HAL_C2_BOOTSTRAP_STDIN=1` and one JSON line on stdin (port, host
  `127.0.0.1`, `halC2Home` from `--base-dir`; `HalC2.Desktop`), and
  `HAL_C2_NODE_COMMAND` names the host's Node for the MC's JavaScript
  sidecars. The MC runs in its own process group so a stop reaches the BEAM
  behind `mix` and the release script. The shell connects with the MC's own
  access token, which the MC writes into its data directory at boot.
- **QML reads `Shell.state`; controllers fill it.** Controllers publish view
  models (`ShellBridge::publish(key, value)` → `Shell.state[key]`), and bricks
  act with `Shell.dispatch(action, payload)`, which the controllers take in
  turn. An action none of them handles reaches the bricks as
  `Shell.actionRequested`, as does what native code asks of a brick (focus the
  composer, open its model picker) through `sendToBricks`.
- **The shell's own MC client** does what the TUI's does. The host's
  `ready` line carries the MC's origin and access token, and `NativeShell`
  opens one protocol-3 socket (`McClient`) and folds the `shell` snapshot and
  row deltas (`ShellStore`, projects and threads). The controllers start on
  the first snapshot (`NativeShell::isActive`, `ready`); until then the windows
  only show what the client cache kept (see the client cache below), and no
  controller acts on it. Every environment the shell sees is the MC's own or a
  member of its cluster: `ShellStore` keeps each MC's rows by MC, and a
  member that goes offline keeps them, so the sidebar rows and header say
  `offline`. Another machine is added by clustering (`cluster.join`), never
  by a connection of the shell's own. The hello frame names the environment the MC
  serves, which is where the shell sends calls about the MC itself (its
  cluster). The scenarios are `features/desktop/native-*.feature` and the
  `@desktop` and `@shared` ones in the files `tests/native/tst_Features.cpp`
  lists, run by the native `tst_Features`.
- **One owner of retries.** `McClient` is the only thing that reconnects. Before
  each socket it reads the MC's descriptor and stays blocked on a protocol it
  does not speak; a drop is retried with growing delays, waits for the network
  when a remote MC's device is offline, and stops on a credential the MC
  refuses until the user pairs again. A failed handshake does not say why, so
  the client asks for a socket ticket: the MC's own token opens the socket
  directly, a paired session's token only through a ticket, and a token the MC
  no longer knows gets neither. A subscription says where it resumes from each
  time its `sub` frame is sent (`McClient::Resume`): the owner of the data is
  asked, never the client, so there is one copy of each offset. A thread's
  stream resumes from its model's cursor and the shell from the row versions
  it holds; every other shape is sent whole. `ConnectionHealthController` turns the phases into `connection`, which
  is not `connected` until the shell snapshot lands on that socket. Controllers
  must not add timers of their own to recover a connection.
- The UI-owned parts of `desktopBridge` (open external, window commands,
  colour scheme, dialogs/context menus) are served by the shell itself; the
  TypeScript-owned parts stay on the Node side.
- **Per-key bindings.** `Shell.state` is a `QQmlPropertyMap`, so a publish
  only re-evaluates bindings on that key. Keys are declared up front, in each
  native controller's registration for the ones it owns; a rice can read any
  of them, but a new key must be declared before a binding will follow it.

Attach mode (`--url <link>`) starts no MC. The shell hands the link to the
host (`--attach`), which needs an MC pairing link (`mix hal_c2.pair`,
`mise run mc:pair`) and refuses any other address. For an MC on this
machine the host finds its access token through the runtime record. For any
other MC it spends the link's single-use token on the shell's session.
Quitting leaves the attached MC running. `mise run desktop` attaches this way
to the MC `mise run mc` runs.

## Source layout

| Path                     | Role                                                                 |
| ------------------------ | -------------------------------------------------------------------- |
| `src/main.cpp`           | CLI flags, config dir resolution, wiring                             |
| `src/ShellRuntime.*`     | QML root generations, `shell.qml` resolution, hot reload, fallback   |
| `src/ShellBridge.*`      | The `Shell` QML singleton: published state and dispatched actions    |
| `src/ThemeStore.*`       | `theme.json` loader + watcher, `Theme` QML singleton                 |
| `src/BackendProcess.*`   | Spawns the Node desktop host, waits for `ready`                      |
| `src/native/`            | The shell's MC client and the controllers that take keys over        |
| `src/native/themes.json` | Built-in palettes, generated by `scripts/gen-themes.mjs`             |
| `qml/HalC2/Bricks/`      | Pure-QML bricks (see below)                                          |
| `scripts/gen-icons.mjs`  | Regenerates `js/lucide.js`, the icon paths `ShellIcon` draws         |
| `scripts/gen-themes.mjs` | Regenerates `src/native/themes.json` from `packages/shared` palettes |
| `host/main.ts`           | Node desktop host: starts or attaches an MC                          |
| `scripts/dev-qt.mjs`     | Build, pair with the running MC, launch                              |
| `examples/`              | Starter `theme.json` and `shell.qml`                                 |

QML modules: `HalC2.Shell` is C++-only (`Shell`, `Theme` and `Runtime`
singletons, registered once and used by one engine throughout its lifetime). `HalC2.Bricks` is
QML-only with a hand-written `qmldir` (no `prefer` line) so the same directory
works compiled into the binary and as an on-disk import path.

The bricks come in two layers. Chrome bricks each own one piece of the window
and read one key of `Shell.state`: `Sidebar`, `Workspace` (the header
strip), `Composer`, `RightPanel`, `SettingsNav`, `ClusterSettings`,
`ConnectionsSettings`, `GitActions`, `Notifications`, `ContextMenuHost`, plus
`CentreHost` (the view `route.kind` names), `SettingsHost`, `DefaultShell` and
`ShellErrorOverlay`. `TerminalDrawer` reads the native
`Terminals` controller instead (see the terminal drawer below), and `Timeline`
renders a native `Threads` timeline (see the thread store below). `RightPanel`'s
native tabs, `DiffPanel` and `FilesPanel`, take their `Panel` object as
`source` (see `rightPanel` and `panel` below).
Under them sit the primitives a rice composes its own
chrome from, all styled from `Theme`: `ShellWindow` (the root every rice
starts from: theme-driven colour, opacity and frame, `sidebarCollapsed`,
`route`, `settingsActive` and `settingsSection`, the shell's context menus, the error
overlay and the window commands), `ShellCard` (a rounded, hairlined
panel), `ShellButton` (outline, `subtle` ghost, `primary`), `ShellComboBox`
(ghost, `outline: true` for a field), `ShellSplitButton` (the header's action
and chevron pill), `ShellMenu` / `ShellMenuItem`, `ShellTextField`, `ShellIcon`,
`WindowControls` (glyph buttons, or macOS traffic lights with
`trafficLights: true`), `TitleBar` and `HalC2Wordmark` (the "HAL-C2"
mark as a filled `Shape`, sized by its height). `ShellIcon` draws lucide
icons as a `Shape` from the path table in `js/lucide.js`, so bricks
pass an icon name (`iconName: "git-branch"`) and get the glyph at any size or color.

`DefaultShell` is a `ShellWindow` filled with `DefaultLayout`, the layout as
an item, so that another root can show it beside a layout of its own
(`apps/mobile-qt`, see [mobile-qt.md](mobile-qt.md)). It holds the sidebar's brand band ("HAL-C2"
plus the collapse toggle), a 52 px header strip with the breadcrumb and the
run / open / git pills, the timeline, and the composer card with the checkout
strip welded under it. Frameless windows get their drag handle and buttons
from the brand band and the header strip (`Sidebar.window`,
`Workspace.window`), not from a `TitleBar`; the examples that want a title
bar row still use that brick.

## Setup

Requirements: CMake ≥ 3.21, Ninja, a C++20 compiler, Qt ≥ 6.9 with
`WebSockets` and `Sql` with its SQLite driver, Node (the host runs from TypeScript source).

- macOS: `brew install qt` (6.11 at time of writing).
- Linux: the distro's Qt 6 with its WebSockets module, or the official
  binaries via `uvx aqtinstall install-qt linux desktop 6.11.1 -m qtwebsockets`
  with `QT_PREFIX=~/Qt/6.11.1/gcc_64`.
- CI/release builds use `aqtinstall` on every platform for reproducibility.

```sh
mise run mc       # terminal 1: the MC on 3780 (HAL_C2_MC_PORT)
mise run desktop    # terminal 2: cmake build, `mix hal_c2.pair`, launch with --url
```

`mise run desktop` runs `scripts/dev-qt.mjs`. It starts the shell with `--dev`, the
development profile: the XDG directories named `hal-c2-dev` that the dev MC uses,
from every checkout and worktree, so the shell rices from `~/.config/hal-c2-dev/shell/`.
Like the dev MC, a `--dev` shell does not read `HAL_C2_HOME`. `--home-dir <dir>`
replaces the profile with one root. Its other flags are `--url` (attach to that link
instead of pairing), `--standalone` (start the shell's own MC from source, as
the installed app does; without `--home-dir` that is the dev profile's MC, so not
next to `mise run mc`),
`--release` (no disk QML loading) and `--configure-only` (build, do not
launch, which `mise run desktop:build` runs); everything else is forwarded to
the binary, so `mise run desktop -- --screenshot out.png --action
rightPanel.toggle` works. Build output lands in
`apps/desktop-qt/build/<debug|release>` (gitignored).

Standalone: run the binary with no `--url`; the host starts the MC for the
shell's home.

CLI: `--url`, `--home-dir`, `--dev`, `--config-dir`, `--qml-dir`, `--host-entry`, `--node`, `--screenshot <png>`
(grab the window once the MC's first snapshot is in, or with the error when the start fails, then quit with
0, or 2 on a failure; PR evidence without a screen-recording permission, and with
`QT_QPA_PLATFORM=offscreen` without a window at all), `--action name[=json]` (repeatable; dispatch shell
actions after that snapshot, e.g. `--action rightPanel.toggle`), `--key <chord>`
(repeatable; press a key chord after it, e.g. `--key Ctrl+1`, portable
`QKeySequence` names — `--action` and `--key` run in command-line order, 1.5 s
apart, so a key test can open a thread first); env `HAL_C2_HOME`,
`HAL_C2_QML_DIR`, `HAL_C2_NODE_BIN`, and for the host `HAL_C2_MC_RELEASE`
(an MC release or its `bin/hal_c2`) and `HAL_C2_MC_PORT` (a fixed port; a
taken one is an error rather than a silent move).

## Ricing contract

Config dir: `<config>/shell/`, so `~/.config/hal-c2/shell/` by default on Linux
and macOS (`XDG_CONFIG_HOME` moves it), `%APPDATA%\hal-c2\config\shell\` on
Windows, `<root>/config/shell/` under `--home-dir` or `HAL_C2_HOME`, and
`~/.config/hal-c2-dev/shell/` for a `--dev` shell; `--config-dir` overrides just this
directory. The shell creates it at startup and watches it, so a shell the hosted
server migrates from an old `~/.hal-c2/shell/` or `~/.t3/shell/` loads without a
restart.

### `theme.json`

The file _is_ the interface for colour propagation: theme managers (omarchy
themes, pywal templates, a hand-written file) write it and the app follows.
The shell itself does not import terminal configs; the generator that comes
closest, `vp run theme:qt [--dev] [shell-dir]` (`scripts/theme-from-terminal.mjs`),
asks the running terminal for its palette over OSC 10 / 11 / 12 / 17 / 4 and
writes `theme.json` into the shell directory from the answer, keeping the
shell on the file contract.

Its shape is a `ThemeFile` (the Settings → Theme editor exports one) plus a shell-only `window` section:

```json
{
  "version": 1,
  "id": "tokyo-night-shell",
  "name": "Tokyo Night (shell)",
  "appearance": "dark",
  "colors": { "canvas": "#1a1b26", "chrome": "#16161e", "text": "#c0caf5", "sidebar": "#16161e" },
  "variants": { "light": { "canvas": "#e1e2e7" } },
  "window": { "opacity": 0.96, "transparent": false, "blur": false, "frameless": true }
}
```

- `colors.*` keys are the theme roles (`canvas`, `chrome`, `surface`,
  `text`, `textMuted`, `accent`, `sidebar`, `terminalBackground`, … — the
  `ThemeColorRole` list in `packages/shared/src/themePalettes.ts`).
  `variants.<appearance>` overrides `colors` for that appearance.
- QML reads the roles: `Theme.colors`, `Theme.palette.color("chrome", fallback)`,
  `Theme.appearance`, `Theme.id`.
- `window.*` is shell-only: `opacity` (whole-window), `transparent` (window
  background cleared; compositor rules do the blur on Wayland),
  `blur` (advisory for platform hooks), `frameless` (default `true`).
- `window.followSystemAppearance` makes `variants` track the app's appearance
  (the system's unless the user pinned light or dark); otherwise the file's
  own `appearance` holds.
- The file is watched; edits apply live. A malformed
  file keeps the previous good theme and sets `Theme.lastError`. Deleting it
  returns to the theme the shell resolves (below). The file never changes the
  user's saved choice.

### `shell.qml`

If `~/.config/hal-c2/shell/shell.qml` exists it is loaded as the root instead of the
built-in `DefaultShell.qml`. It composes bricks from `HalC2.Bricks` and reads the
`HalC2.Shell` singletons:

- `Shell.state` (whatever the controllers published),
  `Shell.dispatch(action, payload)`, `Shell.windowCommandRequested(command)`.
- `Theme.*` as above.
- `Runtime.configDir`, `Runtime.userShellPath`, `Runtime.usingUserShell`,
  `Runtime.lastError`, `Runtime.reload()`.

Extra QML modules can live under `~/.config/hal-c2/shell/qml/` (it is on the import
path). If `shell.qml` fails to load, the default shell takes over with
`ShellErrorOverlay` showing the error; a broken rice never locks the app.

### Local extensions

Extensions are trusted QML components instantiated by `shell.qml`, with no
sandbox. `DefaultShell` exposes `sidebar`, `composer`, `workspace`,
`centreView`, `terminalDrawer`, and `rightPanel` so extensions do not need to copy
the layout. Removing a component removes its controls and signal subscriptions.
`DefaultShell.toolbar` accepts a component above the timeline. Give it an
`implicitHeight`; the empty slot takes no space. Use it for extension controls
rather than positioning buttons over the timeline.

`Composer.editorActions` accepts toolbar controls. `editorKeyPressed(event)`
allows opt-in input handling, and `insertText(text, capturedTarget)` replaces the
selection only while that draft remains selected and editable. Capture
`publishedTarget` before asynchronous work; insertion does not submit a turn.
`Composer` hosts a `ComposerVimKeys`, a deliberately limited modal editor the
`composerVimKeys` setting turns on; a layout must not add a second one. Focus and rename entry points are `Composer.focusInput()`,
`Composer.toggleCheckoutPicker()`, `Workspace.beginRename()`, and
`TerminalDrawer.focusTerminal()`.

`Sidebar.model` can be overridden to filter or reorder the published rows.
The source includes `createdAt` and `latestUserMessageAt`; the latter excludes
agent replies and renames. Local filtering cannot recover rows omitted by the
sidebar's 50-row Settled limit. `thread.markUnread {key}` uses the existing client
unread state.

`ProjectFolderDrop` imports one existing directory through `ProjectController`
(`projects.mutate`). It does not create, rename, move, or delete directories.
`ShellBridge::localFolders` decides whether this machine's folders are the
MC's: the shell's own backend, or explicit `--allow-local-folder-import` for
an attached URL, and an MC origin on loopback. Do not enable that flag for an
SSH-forwarded backend with a different filesystem; its loopback origin looks
local.

`DefaultShell` overlays `ProjectFolderDrop` and shows a native folder explorer
(Qt's `TreeView` over an asynchronous `QFileSystemModel`) beside the thread
list while `folders.open` is set (`folders.toggle`, "Manage folders" in the
palette). `examples/folders` keeps one open through
`DefaultShell.navigationPanel` instead. The thread sidebar stays visible
beside the file browser, or above it on narrow windows; the browser does not
replace thread navigation. Files are listed
read-only. The `FolderExplorer` brick provides create,
rename, move and confirmed system-Trash actions through `LocalFolderModel`.
It never falls back to permanent deletion. Operations are limited to plain
folders inside the chosen root, not files or remote directories. Existing
destinations cannot be overwritten. The chosen root, symlinks, home and
filesystem roots, registered project roots, and their containing directories
are protected from rename, move and Trash. Moving a live project root would
leave thread paths stale, so that is not offered here. The model is enabled
only while the explorer is visible, the primary loopback environment is
connected, and native local-folder permission allows access.

`sidebar.localProjects` lists every checkout of the environment the shell's
MC serves, independently of grouped sidebar representatives. "Remove from
HAL-C2" sends `project.remove {projectKey}` for one physical checkout, which
opens the shell's own confirmation (below). Confirming permanently deletes
that entry's conversation history, including archived threads, and its
drafts; it leaves files on disk. This is separate from Trash, not a safe
workaround for renaming or moving a registered project root.

### UI plugins

A plugin is a QML file in `<config dir>/plugins/` whose root is a `Plugin`
holding `Contribution`s, each naming a slot. The bricks place `PluginSlot`s:
`sidebar.footer` (`Sidebar`), `composer.actions` (`Composer`) and `statusbar`
(`DefaultShell`), the names the terminal client uses. A plugin is as trusted
as a rice: it runs in the shell's engine with the shell's access.

- **Two halves.** `PluginController` (native, shared by every window) owns
  the files: which exist, which are turned off, where a downloaded one came
  from (`plugins.json`, the terminal client's format), and it publishes each
  file's text in `plugins.files`. `PluginRegistry`, a QML singleton and so one
  per window's engine, instantiates that text and answers with
  `plugins.report`. The controller cannot make QML objects for an engine it
  does not own, and QML cannot read files, hence the split.
- **`import OpenTUI` is rewritten.** The terminal client's plugin files
  import its runtime's module. The registry replaces that import with
  `QtQuick` and `HalC2.Bricks` before `Qt.createQmlObject`, so one file loads
  on both as long as it keeps to what both have (`Text`, `Row`, `Column`,
  `Rectangle`, `Timer`). The terminal client's `data` context property cannot
  exist here (an `Item` has a `data` property of its own); a contribution
  declares `property var slotData` to be given the slot's data.
- **A report must not answer inside the change that caused it.** The report
  changes `plugins`, which the registry's `wanted` binding reads; it is sent
  with `Qt.callLater` and only when it differs from the last one.
- **The config directory is watched twice.** `ShellRuntime` reloads the
  whole shell on any QML change under the config directory, plugin files
  included, and the controller re-reads the saved file. The registry outlives
  the reload (same engine), so a file that no longer loads leaves the version
  already running.

### Independent views and windows

`window.new` (the palette's "New window", or `Shell.dispatch("window.new",
{id})` from a layout) opens another native window: its own QML engine
(`ShellRuntime`) on its own `ShellBridge`, loading the same `shell.qml`. The
MC connection, the shell store and the shared controllers
(`NativeControllerScope::Shared`: settings, alerts and quitting) are one per
process in `NativeShell`; everything a window shows (route, composer,
panels, terminals, palette, toasts, sidebar) is a `NativeWindow`'s. Unsent
work is not: every window's `DraftController` and `ComposerController` keep
one store (`NativeShell::common`), so a window that closes loses no drafts. The
`HalC2.Shell` singletons are registered as per-engine factories, and an engine
tagged with a bridge (`halC2Bridge`) gets that window's controllers, so a
controller must never be registered with `qmlRegisterSingletonInstance`, which
binds it to one engine. A shared controller reaches "its" window through
`NativeShell::of`, which answers the window the user last acted in, so an
answer that arrives later (a failed save's toast) must capture that window when
asked. A shared controller meets each window in `attach()`.

The drafts and composer text live in `<data>`. The window with the id `main`
keeps its route and panels directly in `<state>`; another keeps them under
`<state>/shell-windows/<id>/`, and `<state>/shell-windows.json` lists the ids
open, in order, so the same set reopens with the app. Closing a window
(`ShellWindows`: the window's `closing`, then a queued
`NativeShell::closeWindow`, never inside the close itself) forgets it and its
route and panels and nothing else. The oldest open window is `main()`: the
shared controllers still publish on the first window's bridge, which outlives
that window, and every other window mirrors the shared state from it. The
last window is never forgotten; the shell emits `lastWindowClosed` and
`main.cpp` quits, except on macOS, where the app stays running and activating
it shows the window again. Qt's own
quit-on-last-window is off, since a hot reload or a closed popup must not
quit. Pass a stable `id` to reopen a known window rather than opening another;
ids name folders, so the shell accepts only `[A-Za-z0-9_-]{1,32}` and
generates one otherwise.

`--app-id` sets the native desktop identity before any window is created,
allowing launch-profile-specific window rules.

### Notification delivery

`AlertController` decides when a thread alerts, from the shell's own rows
(every machine of the cluster). It compares each thread with what it saw
last, so the snapshot after connecting, or reconnecting, is a baseline rather
than a burst of old completions. This device's `notificationMode` and
`inAppNotificationsEnabled` pick a toast while the window has focus, or a
system notification while it has not; regaining focus clears them. A thread
muted from the palette (`mutedAlertThreads`, thread keys, device settings) is
still compared, only never alerted, so unmuting it does not replay what
finished while it was muted.

The platform side is the controller's `Presenter`, which `main.cpp` wires to
`NativeNotifications` (Linux's desktop notification D-Bus service; `supported`
is false without it and on macOS or Windows) and tests fake. Its click reports
the thread key it was shown for, even after newer notifications replaced
others, and turning notifications off makes late clicks open nothing. There is
no audio module: sound goes through the desktop sound theme's
`canberra-gtk-play` when it is installed, and is silent otherwise.

### Local dictation helpers

`LocalTranscriber` runs an explicitly configured absolute executable with an
argument vector, never a shell command. It is available to trusted local QML. It starts only when the extension calls `start()`.
Helpers emit newline-delimited JSON status and transcript messages;
`finishRecording()` writes `stop` to stdin. A transcript is delivered only
after a successful exit. Cancellation discards pending output and terminates
the owned helper and, on Unix, its process group. Output is bounded.

The optional Linux example uses PipeWire capture and a separately installed
faster-whisper interpreter/model. It downloads nothing. Recording directories
are explicitly configured and temporary audio is removed after use. An
extension captures the draft target before recording and uses checked composer
insertion afterward. If the target changed, it should retain the transcript
for manual recovery instead of putting it into another thread. No microphone
capture or speech model is included in the Qt binary.

### Hot reload

`ShellRuntime` watches the config dir and, in non-release builds, the in-repo
`qml/` directory. A change to any `.qml`/`.js`/`qmldir` file clears the component
cache and loads new root objects in the same engine. The new window loads before
the old roots are dropped, and a replaced root is not a closed window. If both
the user shell and default shell fail, the previous roots stay alive. Generations
share C++ singleton state, never QML-created objects with generation-specific
types.
QmlLive was evaluated and rejected: unmaintained since 2019, Qt 5 only.

## State keys and actions

What each `Shell.state` key carries and which actions its controller takes.

### `sidebar`

`SidebarController` publishes `ShellSidebarState` from the shell's MC rows
(`SidebarModel`): project groups, the
current scope, the drafts, and the thread list already bucketed
(`pinned`/`active`/`snoozed`/`settled`), sorted, and annotated with status,
status label, unread, branch, the snooze wake label, the woke timestamp and
whether settle/snooze apply (`wakeLabel`, `wokeAt`, `canSettle`,
`canSnooze`; neither while the thread's environment is `offline`). `settled` is capped at 50 rows with `settledTotal` carrying the
real count. Projects are grouped and ordered by this device's preferences
(`sidebarProjectGroupingMode`, `sidebarProjectGroupingOverrides`,
`sidebarProjectSortOrder`, `timestampFormat`, read through
`SettingsController`): folders sharing a repository identity are one project
unless grouping is separate, and a folder with none groups by
`<environment>:<root>`. There is no manual project order yet.

Projects are added and removed through `projects.mutate` by
`ProjectController`. `project.add {path}` (the sidebar's folder picker) and
`project.folder.open {path}` (a folder dropped on the window) register a local
folder, or open its latest thread if it already is a project, and otherwise
start the new project's draft once its row arrives; a failure is a toast.
Without a path, `project.add` runs the palette's Add project menu, which
`ProjectController` registers: an online environment when there is a choice,
then a folder browsed on that environment (`filesystem.browse`) in the
palette's browse mode, or a clone (`ProjectCloneController`): a Git URL or a
hosting provider's repository, asked for in the palette's ask mode, then a
destination browsed with the repository's folder name pinned. Both browse
from the environment's `addProjectBaseDirectory` setting, else `~/`. The MC
adds the project at once and clones in the background; each clone an online
environment reports on its `projectClones` shape (by environment, so another
machine's are followed too) is one toast, updated in place, whose Cancel and
Retry keep it open. A path does nothing when the MC is not on this
machine, whose folders it cannot reach. `project.remove
{projectKey}` publishes `projectRemoval {projectKey, title, workspaceRoot,
threadCount}`, which `ProjectRemovalDialog` asks about; `project.remove.confirm`
deletes with `force` and `project.remove.cancel` closes it, as does the
project going away.

Drafts are the shell's (`DraftController`), kept in `shell-drafts.json` in
the shell's data directory: one per project folder, each with the thread id
it will become. `thread.new {projectKey?}` opens the project's draft (the
scope's or the open route's project without a key), `draft.open`,
`draft.menu {draftId, x, y}` and `draft.delete` open and delete it, and the
first send promotes it (`ComposerController`); a draft whose thread row
arrives, or whose project goes, is dropped. The draft's text is kept with
the draft: the composer's `composer.text.set` on a draft route saves it
through `DraftController`, so it survives a restart. The
sidebar lists only drafts that hold something, and the open draft keeps the
row it had when the window opened it, so a fresh draft is not listed while
the user types into it.

The QML sidebar reconciles publications into a keyed `ListModel`, updating
and moving existing rows instead of replacing the list. This preserves row
hover, keyboard focus and scroll position while thread state changes.

Actions (`Shell.dispatch(name, payload)` in QML):
`sidebar.scope {projectKey|null}`, `project.add {path?}`, `project.remove
{projectKey}`, `draft.menu {draftId, x, y}`, and the
navigation ones `route` takes (`thread.open {key}`,
`draft.open {draftId}`, `thread.new {projectKey?}`, `settings.open`,
`pullRequests.open`, `usage.open`). The active row is the route's. Row actions are the
HTML row's hover buttons:
`thread.settle {key}`, `thread.unsettle {key}`, `thread.unsnooze {key}`,
`thread.snoozeMenu {key, x, y}` (the snooze durations open as the shell's
`menu` at those window coordinates), `thread.wokeDismiss {key}`, and
`thread.menu {key, x, y}` for the thread menu.

`SidebarThreadRow` mirrors the HTML row's states: Working/Monitoring,
Approval, Input, Failed, Woke (a pill that dismisses on click while `wokeAt`
is set) and Done (unread) take the age label's place, coloured with the
`info`, `warning`, `accent`, `error` and `success` theme roles; rows that
need nothing recede. Hovering or keyboard-focusing a row swaps that slot for
its actions — snooze and settle on live rows, wake on snoozed rows, un-settle
on settled rows — and a right-click anywhere on the row opens the thread
menu on press.

The thread list is a Tab stop. Up/Down move a cursor (a ring in the `focus`
theme role) over rows and section headers, Home/End jump to the ends, Enter
or Space open the row or fold the header, and Menu or Shift+F10 open the
thread menu at the row. The cursor starts on the active thread. Row action
buttons are not Tab stops; the thread menu carries the same actions.

### `composer`

`ComposerController` publishes `composer` (`ShellComposerState`) and owns
the composer of the thread or new-thread draft the route shows. Each thread keeps its draft (text, caret, model,
options, modes, images) in the controller, saved on this machine; a new
thread's text is `DraftController`'s. It sends, queues, steers, stops,
answers approvals and questions and implements the plan with MC RPCs, and
publishes the route thread's pending state as `turn` (see
`ComposerController.h`), which the `Composer` brick stacks above its prompt
(`TurnRequests`), so a shell that hosts the composer needs nothing more to answer them. A new thread's first send launches it
(`orchestration.launchThread` with the draft's checkout, model and modes) and
the window replaces the draft with the thread. In a cluster the launch first
asks the connected MC where the thread starts (`hal-c2.placeThread`, see
`ComposerController::place`) and goes to the machine and project it answers:
the MC holds the load-balancing rules, so the shell has none. A draft tied to
its machine (a "Run on" pick, a picked branch or worktree) is not asked about,
and the user's pick stands when the MC fails or does not answer in time, so a
send is never lost to placement. A background send leaves the
draft for another prompt and toasts a way to open the thread, or to restore
the prompt if the launch fails.

The model catalogue is the `providers` of the route environment's config
(`WorkspaceController::environmentConfig`), so a thread on another machine lists that
machine's models, gated on the environment being online rather than local.
It is its own key, `modelPicker`, because `composer` republishes on every
keystroke and an OpenCode catalogue runs to dozens of models. It holds the
enabled instances in rail order, their models already filtered, ordered and
marked (favourite, legacy, disabled reason), plus the picker's chords
resolved from the user's keybindings. The `ModelPicker` brick draws the
rail, ranking, rows and keys from that (`js/modelPicker.js`), so search stays in QML and only a
choice or a star crosses back. `composer.model.select` accepts only a ready instance's listed
model, and once a thread has run a turn only its own provider's. Runtime and
interaction modes are set on the thread before a send only when the user
changed them, and plan mode appears only with the `planModeEnabled` setting
and a provider that offers it. Its popup does not close on Escape by
`closePolicy`: a popup that does blocks every window shortcut, including the
`modelPicker.toggle` binding that must close it again.

Text edits and submissions carry an `edit: {clientId, revision}` stamp, which
the controller publishes back with the draft once applied. The brick ignores
publications that have not applied its latest edit, preserving newer text and
the caret even when publications are delayed, coalesced, or repeat an earlier
value; the controller's own changes (a picked suggestion, a cleared send, a
restored failure) still land. Switching targets resets the pending revision.

`@file`, `$skill` and `/command` suggestions are computed from the raw prompt
and caret: `/` lists the provider's commands (and skills, with
`showSkillsInSlashMenu`) plus `/model`, `/plan` and `/default`, which switch
without sending; `$` the provider's skills; `@` asks the MC's workspace
search (`WorkspaceFiles`, the Files tab's) for the route's checkout. Selecting
sends the item id back and the controller applies the replacement.

Editing a queued message (the queue row's Edit, or the edit key with the
caret at the start of the draft) swaps its text into the thread's composer
and sets the thread's draft aside, so the set-aside draft is what is saved to
disk; a send saves the edit with `queued-run.edit` (text only, so its images
stay as they were) and gives the draft back. The swap keeps every composer path on one target.

Terminal excerpts (`composer.terminalContext.add`, from a terminal's
right-click Add to chat) are chips on the
draft, not inline links: the Qt editor is plain text.
A send appends one inline context link per excerpt to the message text and
carries the excerpts as `context` records, because the MC only hands the
provider records whose link is in the text (`HalC2.ComposerContext`). The
Ghostty `Terminal` does not say where its selection is, so the brick counts
the lines at the selection's last occurrence in the terminal's text. Excerpts
live in memory like images.

Prompt history (`composer.history.step`) is not the controller's yet: it
drops the step.

The `modelPicker.toggle` binding sends `composer.modelPicker.toggle` to the
bricks, and the toolbar commands
(`composer.effort`, `.mode`, `.host`, `.workspace`, `.branch`) dispatch
`composer.control.open {command}`; the `Composer` brick listens on
`Shell.actionRequested` and opens its own control.

### `rightPanel` and `panel`

The native `Panel` controller (`src/native/RightPanelController.cpp`) owns
the right panel: open or closed and which tab shows, per thread, published as
`panel`. The Diff and Files tabs are native bricks (`DiffPanel`, `FilesPanel`)
over the controller's `ThreadDiff` and `WorkspaceFiles`, which call the
MC's `orchestration.getTurnDiff`, `getFullThreadDiff` and `projects.*` RPCs
on the thread's own environment. The Agents tab (`AgentsPanel` over
`AgentsModel`) needs no RPC: it reads the `subagent` entities and running
`command_execution` items the thread's stream already carries, and its
elapsed times tick only while it shows. A terminal tab is
`terminal:<group>`: one of `TerminalController`'s panel groups (below), made
by `rightPanel.add {kind: "terminal"}` and closed, terminals and all, with its
tab; `TerminalPanel` draws it. The Pull requests tab (`PullRequestsPanel`
over `ThreadPullRequests`) reads the links the thread row already carries,
links and unlinks with the `thread.pull-request.link`/`.unlink` commands, and
refreshes with `pullRequests.invalidate`; linking accepts any repository on a
host a project reads. Offline its rows stay as last
synced and nothing is sent. The Previews tab (`PreviewsPanel` over
`ThreadPreviews`) lists the thread's browser tabs from `preview.list` and the
`preview` shape, subscribed only while it shows, and opens each in the user's
browser. The add menu's "Browser tab" (`rightPanel.add {kind: "browser"}`) is
`preview.open` with no address: an empty tab the Previews tab fills from the
MC's `localServers` shape (the MC's machine's servers, never this one's), the
project scripts' `previewUrl`s and this device's last ten pages
(`previewRecentPages`), with `preview.navigate`. Moving another tab to QML is a line in `js/panelTabs.js` plus its kind
in `RightPanelController::nativeKinds`.

The desktop embeds no browser. QtWebView is WebEngine underneath on Linux,
with no input injection, zoom or popup control, so it cannot host the agent's
preview tabs. The embedding scenarios in
`features/preview/surfaces.feature` are `@backlog-desktop` for that reason.

The Pull request review tab (`pull-request:<host>/<repository>#<number>`,
titled "PR #n") is `PullRequestReviewPanel` over the controller's
`PullRequestReview` (`Panel.review`). It opens from the add menu or a Pull
requests row's menu (`rightPanel.review {key}`) and reads the pull request
through the thread's environment: `pullRequests.detail` and `.activity` over
the socket, and the code over HTTP (`POST /api/pull-requests/diff`, one
`nextCursor` slice at a time, with `McClient::post`), which lands in a
`DiffModel` that `DiffPanel` draws. Comments, reviews, thread resolutions and
viewed marks go back through the same environment, and the pull request is
read again once each lands. A viewed mark the host refuses is taken back.
Offline, what was read stays and nothing is sent.

The thread details column (`ThreadDetailsPanel`, `threadPanel.toggle` from
the header's info button or the keybinding) is not a tab. It sits beside the
right panel and reads `panel.details`, which the controller builds from store
rows: the environment and whether it is reachable, the project, the checkout
and branch, and the lineage parent and children. Changing the checkout stays
with the composer's strip.

Device tabs (`ThreadDevices`, `DeviceStream`) follow the MC's `devices`
shape and stream through its device-hub proxy with the shell's bearer token,
decoding H.264 with FFmpeg's libavcodec (headers at build time, the libraries
loaded at run time; see [Devices](devices.md#the-viewers-decode-both-vendored-protocols)).
A device tab streams only while it is the active tab.

Per thread, the controller keeps
whether it is open, its tabs, the active one and the details column, plus one
width for all threads, in `shell-panel.json` in the state directory, so they
survive a restart (maximizing does not). `rightPanel.resize {width}` and `rightPanel.toggleMaximized`
come from the brick's edge and the keybinding. `panel.open {tab, path?,
line?, turn?, turnId?}` opens a native tab on a turn's diff or a file at a
line, for the timeline's links.

### `workspace`

`WorkspaceController` builds `workspace` from the MC: the thread and its project are `ShellStore` rows,
the git summary the MC's `vcs` shape for the checkout, the refs
`vcs.listRefs`, the editors each environment's `config`. It keeps
`useThreadBranchSelection`'s rules (optimistic branch, `switchRef` /
`createRef`, then `thread.metadata.update` with the new branch and worktree),
and renames through `thread.metadata.update`. The git pill is the `GitActions`
brick's (`git`, below); the branch toolbar under the composer is not
rendered. The `Workspace` brick renders the breadcrumb and the run / open
pills; the branch toolbar's contents (environment, checkout mode, branch
picker, PR badge) are the context strip under the `Composer` brick.

`workspace.newThread` starts a draft in the header's project (`thread.new`),
`workspace.openPullRequest` opens the checkout's pull request in the system
browser, and `workspace.titleMenu {x, y}` opens the thread menu (below). A
draft's checkout (mode, start from origin, branch, worktree, the machine it
runs on) is kept by draft id, set with `workspace.envMode.set`,
`.startFromOrigin.set`, `.environment.set` and the branch picker. Which thread a draft is, `NativeShell` asks
`DraftController` (`setDraftResolver`). The `vcs` shape names the thread's
environment, so the MC routes it to the cluster member with the checkout; while
that member is offline the subscription fails at once with the MC's reason
(`gitError`), and it is followed again when the environment comes back.
`config` names the environment too, so another machine's editors are watched
while it is online.

The terminal drawer is native: `TerminalDrawer` draws each of the thread's
terminals with [qml-ghostty](https://github.com/hal-c2/qml-ghostty)'s
`Terminal` item (libghostty-vt, built as described in the app's README), and
`TerminalController` (the `Terminals` singleton) talks to the MC for it over
the shell's own `McClient`, as the sidebar and composer do. It takes the thread (drafts included), its
project root, worktree and scripts from `WorkspaceController::place()`, and
the header's run pill (`workspace.runScript`, handled by the workspace) types
into a drawer terminal it launched itself. Its shapes name the
environment, not an MC, so the MC routes them to the cluster member that serves
it; the drawer is available wherever the header is
(`features/terminal/drawer.feature`).

- **Launch context.** Every attach and open sends the thread's cwd (worktree,
  else project root) and the same `HAL_C2_*`/`T3CODE_*` root variables. The MC restarts a shell whose launch env changed, so the shell
  must send the same env every time.
- **Replay.** A session keeps the transcript it attached with plus what has
  arrived since (capped like other clients' buffers), so a tab created late replays
  with `Terminal.restore()`, which answers no queries. Only live output goes
  through `write()`; replaying history through it would answer stale device
  queries into the shell.
- **One write in flight.** Keys typed while `terminal.write` is pending
  coalesce into the next one, so the shell sees the user's order.
- **Hidden is not detached.** Once opened, the drawer stays attached while
  hidden, so output keeps arriving and switching
  back costs nothing. Leaving a thread parks its sessions, still attached,
  for the last ten threads left; returning reuses them instead of attaching
  again.
- **Restored state waits for the list.** The drawer's height and each
  thread's open flag and active terminal are kept in `shell-terminals.json`
  (state directory). After a restart they apply only once the MC's
  `terminals` snapshot says which terminals still exist, so the drawer never
  opens on a terminal that is gone.
- **A close asks, an exit does not.** Every close the user makes
  (`terminal.close`, a terminal tab of the right panel) goes through one
  `MenuController` question naming each terminal; a shell that exits on its
  own takes its terminal with it unasked. When `terminal.close` fails the
  shell is sent `exit` instead.
- **Links are found from the text.** qml-ghostty exposes no cell contents, so
  `TerminalSplits` maps a click to a character of `Terminal.text()`
  (`js/terminalLinks.js`)
  by counting a row per `columns` characters. Wide characters above the click
  shift that count; the fix is a link API in qml-ghostty, not more arithmetic
  here. Web addresses open in the system browser whatever `browserLinkTarget`
  says, since the desktop draws no pages.
- **Groups.** Terminals are laid out in groups: a
  terminal never split is a group of its own, `terminal.split` (side by side)
  and `terminal.splitVertical` (stacked) add one after the focused terminal,
  at most four to a group. A panel group is a right panel tab and never shows
  in the drawer. Each `tabs` row carries its group and place in it, and
  `TerminalSplits` makes a `Terminal` only in the place (drawer or panel) the
  row belongs to, so no session has two views fighting over its size. Groups
  live in memory: a restart or another client sees ungrouped drawer terminals.

### Settings sections

The settings nav (`SettingsNav`) and every section behind it are bricks.
`js/settingsPages.js` lists the sections: each names its
brick, the state key it `requires` before it is listed, and the words and
rows search finds it by. `SettingsHost` loads the brick for
`ShellWindow.settingsSection`, and `settings.navigate` opens any section from
anywhere. A section `under` another (Diagnostics and Open
source licenses, under General) is left out of the nav, reached
by a `link` row of its parent, and keeps the parent marked
(`settingsPages.current`).

Search is the shell's too. `settingsPages.searchRows` matches sections by
label and keywords, and a section's settings (its `settingsRows.js` rows and
any `settings` entries, each left out while a state key it `requires` is
missing) by title and description; every word of the query
must match, and a result names the setting's `targetId`. Opening one is
`settings.openResult {to, targetId}`: `NavigationController` opens the
section and bumps `route.targetSeq` with `route.target` set, and
`SettingsPage` scrolls the brick's child of that objectName to the top on
each bump, so opening the same result twice scrolls back to it. A folded
group that is a target opens itself on the same bump (`LoadBalancingGroup`).

General and Appearance are rows over `Settings` (`js/settingsRows.js`: a key,
a kind and its wording). Each key's store and default are
`SettingsController`'s row table: `setting`, `defaultOf`, `isDefault`,
`onDevice`, `set` and `reset` read and write it wherever it lives. The MC
leaves defaults out of its document, and a null `sidebarAutoSettleAfterDays`
means off. Appearance also draws the theme choice and this device's own
themes (`ThemeEditor`); errors are the shell's toasts.

Each other native section is a controller publishing one key, whose header
documents the shape and actions:

- **Cluster** (`ClusterController`, `cluster`) calls the MC's `cluster.*`
  RPCs.
- **Connections** (`ConnectionsController`, `connections`) is who may reach
  this machine. While open it follows the `authAccess` shape and calls the
  `hal-c2.*` access RPCs, which need `access:read`/`access:write`, so a
  session paired with standard scopes sees one explanation in place of the
  list. A created pairing link's secret lives only in `created` until the
  section closes. The link's address is the one the MC answers with
  (`hal-c2.createPairingLink`, `HalC2.Web.address/1`), never the origin this
  client connected at: the call is routed to whichever online member the user
  picks, and only that member knows where it is reached. The access list and
  client revocation stay the connected MC's (the MC refuses them across
  members), so a link made on another member is revoked from `created`, and a
  device paired there is not listed here. `created.qr` is the link as a QR
  code (`qr::path`), left out when the MC says only its own machine can open
  the address. Other machines are the Cluster section's, which the page
  leads to. With more than one machine the page also has the load-balancing
  group (`LoadBalancingController`, `loadBalancing`): its switch and each
  machine's preference are in the connected MC's settings document, because
  that MC is the one that places new threads.
- **Providers** (`ProviderSettingsController`, `providerSettings`) shows one
  environment at a time: its `config` shape brings the providers, and each
  provider that signs in from HAL-C2 has its `providerAuth` shape followed.
  That shape is MC-addressed, to the cluster member serving the environment. Turning a provider off is a settings edit on that
  environment, read back and retried on `StaleSettings` like the shell's own
  settings. Instances, custom models and a registry agent's sessions and model
  providers are edited through the same model; the ACP Registry search and a
  registry agent's sessions, model providers and logout are MC RPCs asked
  from the followed environment, and their answers are held only while the
  section shows.
- **Archive** (`ArchivedThreadsController`, `archivedThreads`) is fetched,
  not streamed (`features/parity/rpc.feature`): opening it, refreshing, an
  action landing, or the online environments changing asks each one for
  `orchestration.getArchivedShellSnapshot`, which covers only the rows of the
  MC that answers.

Home, the pull requests page and usage are routes of their own, drawn by
`HomePage`, `PullRequestsPage` and `UsagePage` over `PullRequestListController`
and `UsageController`; they too follow MC shapes only while open. Home is
never where a window with projects stays: once every environment has
reported, `DraftController::land` replaces it with the most recent project's
draft (`sidebar::mostRecentProject`, in "updated_at" order), reusing
the draft other windows landed on. `HomePage` shows the add-project hero with
no projects, and `landing.failed` with its `landing.retry` when the draft
could not be kept. The open thread vanishing (deleted, or its environment
gone) sends the window home, and so onto the draft.

Storage, Scheduled Tasks, Source Control, Integrations and Project edit settings scoped to one or
several environments or a project through `SettingsScopeController`
(`settingsScope`): it follows the targets' documents only while one of those
sections shows, reads a value across them as mixed or not, and writes a
change to every connected target, a project's as its
`projectSettingsOverrides` entry. Background activity is not project-scoped,
so its rows are read-only at a project scope. Discovery of source control
tools scans only the scope's first connected environment,
and so does Integrations' device status. Integrations is only the device hub:
the desktop embeds no browser, so there are no browser defaults to set. A picked project follows its folders when the sidebar regroups
(`SidebarController::grouped`). The
Project section also carries how new threads start (model, permissions,
workspace, submodules), since the General page holds only this device's settings.

SnapShots is native (`SnapShotController`, the `SnapShotSettings` brick), but
its platform half is only the xdg-desktop-portal backend (`PortalSnapShot`,
over QtDBus), used on every Wayland desktop (see `linux-snap-shot.md`). On
macOS, Windows and X11 the section says capture is unavailable; those
scenarios, and the compositor helpers, are `@backlog-desktop`. The portal gives no
flash, animation or accessibility tree, so those rows stay locked. A capture
lands through `ComposerController::attachImage`, shrunk to the attachment
limit. The shell's settings navigation and search are its own
(`js/settingsPages.js`).

### `route`

`NavigationController` owns where the window is:
`route` is `{kind, threadKey, draftId, projectKey, section, title,
canGoBack, target, targetSeq, search, searchSeq}` with `kind` one of `home`, `thread`, `draft`, `settings`,
`pullRequests`, `usage` (the `ShellRoute` contract plus
`title`, `canGoBack`, the settings search's target, and the query `settings.search {query}` puts in the
settings navigation's search field). `ShellWindow` titles the window from `title` and derives
`settingsActive` and `settingsSection` from it; the sidebar's active row and the
composer's target thread come from it too. It keeps a back stack (home is
passed through, and moving between settings sections is one step) and writes the last route to `shell-route.json` in the shell's state
directory; the next launch reopens it unless the thread or draft was
deleted.

Controllers tied to a thread route (`workspace`, `panel`) publish `null` for
their key off one, so leaving a thread clears the chrome instead of freezing
it on the last thread.

### Settings and preferences

`SettingsController` (the `Settings` QML singleton; C++ reaches it with
`NativeShell::controller<SettingsController>()`) holds two stores. The API is
documented in its header.

- The MC's settings document, shared by every client of the environment:
  `hal-c2.readSettings` gives `{settings, version}`, and `hal-c2.writeSettings`
  saves a whole document at the version it was read at. A change is an edit
  function (`change(edit, done)`, or `Settings.write(path, value)` from QML).
  When another client saved first, the MC refuses the write as
  `StaleSettings`. The store then reads again and applies the same edit to what
  the MC holds, a few times before it reports the failure, so a stale copy
  never overwrites a newer one. It subscribes to the MC's `config` shape
  (the snapshot, `config.settings`, `config.providers`, `config.themes`) and
  reads again on each snapshot. A reconnect may reach a restarted MC whose
  versions start over.
- This device's preferences, in `<config>/preferences.json` next to
  `theme.json`: anything that belongs to this desktop and no other client
  (appearance, theme choice, saved custom themes, the client settings rows).
  They are available before
  the MC is. A save that fails sets `deviceError` and leaves them as they
  were.

### `theme`

`ThemeController` (the `Themes` singleton) publishes the `ShellThemeState` it
resolves as `theme`. The choice lives in this device's preferences: `appearance`
(`system`, `light`, `dark`), `theme`, `themeHalves` (a theme per appearance)
and `customThemes`. An id is looked up among the built-ins first, then this
device's saved themes, then the themes the shell's own MC publishes. Themes
from other machines are never offered. Missing roles come from the T3 Chat palette, and a
theme with one appearance takes that half only. An id that is no longer found
draws the standard look, published as `hal-c2`. The built-ins are `src/native/themes.json`, generated from
`packages/shared/src/themePalettes.ts`. Run `node apps/desktop-qt/scripts/gen-themes.mjs`
after changing a palette. Colours are converted from `oklch()` natively.

`ThemeStore` paints the resolved theme with `theme.json` over it, role by
role. `Theme.palette.color()` resolves theme.json first, then
the resolved theme, then the brick's fallback. The notified `palette` receiver
makes QML bindings follow theme changes; direct calls to the C++ `Theme.color()`
method do not create that dependency. `Theme.radius`, `Theme.fontUi` and
`Theme.fontMono` follow the same order (the shell-only `radius` / `fonts` keys in
theme.json win). The themed controls (`ShellButton` etc.) take radius, surfaces,
borders and fonts from `Theme`.

Settings → Appearance chooses and edits themes through `Themes` (`setMode`,
`choose`, `chooseHalf`, `draft`, `saveCustom`, `duplicate`, `requestRemove`,
`importFiles`, `importText`, `exportTheme`). The editor's draft is the
controller's (`Themes.editing`), not the page's, so the one `ThemeEditor`
`ShellWindow` holds keeps unsaved changes while the user moves about.
The same choices are the actions `theme.mode {mode}`, `theme.choose {id}`,
`theme.chooseHalf {appearance, id}` and `appearance.cycle`, which is
`Themes.cycleAppearance()` (System → Light → Dark, with one toast however
fast it is pressed).

### `layout`

The shell owns whether the thread list is hidden and how wide it is: `LayoutController`
publishes `layout {sidebarCollapsed, sidebarWidth}`, remembers them in the device's
`preferences.json`, and publishes it before the MC's first snapshot so a
restart does not flash the list. `sidebar.toggle` (action and keybinding
command, Mod+B by default) flips it. The `Workspace` brick shows a toggle when
its `sidebarToggle` property is bound (it takes the sidebar's place at the
strip's left edge), and `Sidebar` shows the matching collapse toggle in its
brand band when `showBrand` is on. The right panel's toggle follows the same
pattern: `Workspace.panelToggle` puts it in the header strip and `RightPanel
{ ownToggle: false }` then takes no width while closed; a rice that leaves
`ownToggle` on gets the 36 px rail with the toggle instead.
`sidebar.resize {width}` sets the list's width (no width resets it), and `ShellWindow` reports its
own width as `layout.window {width}` so the published `sidebarWidth` shrinks when the thread would
be left less than its minimum.

It also owns the app's zoom, a device preference (`zoomLevel`, Chromium's
steps: factor 1.2^level in half steps) that every window follows, published
as `layout.zoom`. `view.zoomIn`, `view.zoomOut` and `view.resetZoom` change it.
`ShellWindow` scales its `body` rather than the fonts, so a rice needs no zoom
awareness; the menu hosts stay unscaled in window coordinates, so anything
that places a popup at a pointer maps through the scaled item
(`mapToItem(parent, ...)`, never `null`). Other popups and dialogs live in
the unscaled overlay, so each sets `scale` to `layout.zoom` about
`Item.TopLeft` (the origin the popup positioner assumes, centring included)
and divides any size it takes from the window by it; context menus and tool
tips stay unscaled, as native ones do.
`DefaultShell` snaps the sidebar (one relayout, no animated width); examples
that ease `Layout.preferredWidth` to 0 hide it once it is gone
(`visible: !sidebarCollapsed || width > 0` — guard on the collapsed flag, not
on width alone, or a layout-managed item never regains a size).

`Sidebar` carries the search and new-thread row, the project scope picker
and "add project" under its brand band, and the app's places (Settings, PRs,
Usage) in its footer. A rice that puts those somewhere else — the dashboard
example's icon rail — sets `showScope: false` and `showFooter: false` so the
same action is not reachable from two places; `showBrand` is off by default
because most rices bring their own title bar.

### `keybindings`

`KeybindingController` (the `Keybindings` singleton) keeps the keymap. It
merges `src/native/Keybindings.cpp`'s copy of the default keymap with the rules
the MC pushes as `config.keybindings` (a custom rule for a command replaces
that command's defaults, the newest match wins, rules naming an unknown
command are dropped) and evaluates `when` against the shell's own context:
terminal and composer focus, the drawer, `isDesktop`. Commands the shell can
run itself sit in a `CommandRegistry` (`Keybindings.commands`): new thread
through `thread.new`, back, the sidebar, the terminal drawer, next, previous
and numbered threads in the sidebar's order, the composer's pickers, stash,
previous worktree and stop, the Previews tab (`preview.toggle`), and steering
with or editing a queued message. A command no one registers (the in-app
browser's `preview.*` keys) does nothing.
A brick adds its own with `Keybindings.commands.add(command, title, callback,
owner)`, and a controller from its `activate()`. The controller that owns a
behaviour registers its command and keeps it current (title, description,
`setListed`, `setEnabled`) as its state changes: "Copy PR link" becomes "Copy
thread ID" without a linked pull request, "Mute alerts for this thread" turns
into "Unmute", pull request commands are listed only where an environment
can serve them. A menu command (`addMenu`: theme, appearance, "New thread
in...", Add project) hands the palette its choices when shown, so a submenu is
never stale. A QML callback that throws emits `failed`, and the palette
toasts "Unable to run command" only for the command it ran.

The command palette (`CommandPaletteController`, the `PaletteModel` singleton,
drawn by `CommandPalette`) lists those rows as its actions, so an action
reaches the palette by being registered there, never by the palette naming
it; only the order of the root list (`kRootCommands`, a hand-picked
list) is its own. It adds the shell's threads by key (every machine of
the cluster), the sidebar's projects, the settings sections
`js/settingsPages.js` hands it (without those whose `requires` is missing)
and, from two characters, threads whose messages match. Go to file
(`filePicker.toggle`) and project search (`projectSearch.toggle`) are modes of
the same list against the route thread's environment, only while it is
online; MC searches wait for typing to pause and only the newest answer
counts. It is its own list model and filters in C++, moving only the rows a
keystroke or an answer changes, never resetting the list. Dismissing it sends
`composer.focus` to the composer. The singleton is not `Palette`, which
QtQuick already names.

The application menu's accelerators (`menuKeys()`: mod+, for settings,
mod+=, mod++, mod+- and mod+0 for zoom) are not keymap rules and not rows in
Settings → Keybindings; they resolve only after every rule, so a user's rule
for the same chord wins.

`ShellWindow` instantiates one window `Shortcut` per bound sequence and calls
`Keybindings.press`. Each entry of `Keybindings.shortcuts` says whether the key is the shell's with
the chrome, the composer's field, another text field or a terminal focused, so a shortcut whose
condition fails there is disabled and the key stays with the control (mod+z in a text field).
Who takes a key follows focus:

- A focused terminal keeps every key except the sequences that resolve, in
  that focus, to a native command or a project script.
  Those `Shortcut`s stay enabled, so a native command runs once and a
  terminal still gets Ctrl+K. The default keymap binds `mod+d` to
  `terminal.split` in a terminal, so off macOS a terminal loses Ctrl+D (EOF)
  unless the user rebinds it.
- From native chrome (a focused composer included), only a sequence that
  resolves to a native command or script is a window shortcut; any other
  key stays with the focused control.
- Unmodified keys are never window shortcuts; they belong to whichever
  control has focus.

Mod+Q is not a shortcut. `QuitController` (shared, one per process) filters
the application's key events before any window sees them and implements
the `confirmQuit` setting: "hold" (the default)
quits after 1.2 seconds held, "double-click" after two presses within half a
second, "direct" at once, and two quick presses always quit. "Still held" is
proven by auto-repeat. The hint is the shared `quitHint`
({message} or null) that `ShellWindow` shows; `app.quit` in the palette quits
at once. The controller only emits `quitRequested` and `concealRequested`;
`main.cpp` quits and hides the windows, and tests swap its clock with
`setClock`.

Settings → Keybindings (`KeybindingsSettings`, route
`/settings/keybindings`) lists the merged rows, records chords with
`Keybindings.recordKey`, and saves through `hal-c2.upsertKeybinding` and
`hal-c2.removeKeybinding` on the shell's own environment. The rows refresh
from the MC's push, not from the reply.

### `notifications`

The `Notifications` brick renders only the shell's own `toasts`.
`ToastController` is what native controllers call (`show`, `error`,
`showActions` with up to two buttons, `replace` to update one in place), with
its own timing; its ids start with `native:`. Every toast has a native
producer, such as
`KeybindingController`'s "Keybindings updated" on a `config.keybindings` push
and `ProviderUpdateNotice`'s launch offer of provider updates
(`ProviderUpdatePrimaryNotification`), whose dismissed version sets are this
device's `dismissedProviderUpdateNotificationKeys`.

### `menu`, `confirmation` and `contextMenu`

The shell's own menus and questions are `MenuController`'s: a controller
opens a list of items (id, label, icon, enabled, checked, destructive,
separator, one level of children) at window coordinates with the function the
chosen id runs, or asks a question with the function a yes runs. They are
published as `menu` and `confirmation`; the window-level `ContextMenuHost`
(`stateKey: "menu"`) and `ConfirmDialog` render them and answer with
`menu.select {requestId, id|null}` and `confirmation.answer {requestId,
accepted}`. Only an enabled item that was offered can be picked, and a newer
menu replaces the open one.

The thread menu is `ThreadMenuController`'s, from a row (`thread.menu {key,
x, y}`) and from the header's title (`workspace.titleMenu`, which leaves out
the project filter; a draft's title opens the draft menu). It follows
`threadActionMenu.logic.ts`'s order and adds Fork and "Move to another
machine…" (`hal-c2.moveDestinations`, then `hal-c2.moveThread`, which may
answer with a question, a project to pick, or the moved thread's new key,
which the route follows). Items the environment does not support are left
out; on an offline thread only what needs no environment (copying, the new
thread on its branch, the project filter) can be chosen. Every command
reports a refusal as an error toast. Archive, unpin and settle offer Undo on
their toast for its five seconds, and `thread.undo` (mod+z outside text)
runs the newest Undo on offer. Delete, archive and unpin ask first when the
device's `confirmThread*` settings say so (delete's is on by default).

Every window menu is a native controller's (`thread.menu`,
`workspace.titleMenu`, `draft.menu`, `thread.snoozeMenu`, `git.menu`), so the
window has one `ContextMenuHost`, for `menu`.
`workspace.rename {title}` / `renameRequestId` drive an inline rename in
the header; the thread menu's "Rename" asks for it with
`workspace.rename.begin {threadKey}`.

### `git`

`GitController` publishes `git` from `WorkspaceController`'s `vcs` status.
The recommended
action and the menu follow `apps/tui/src/gitActions.logic.ts`: the ledger (`source-control/git-actions.feature`)
is written against the TUI's labels and reasons, named for the host's change
requests (PR, MR). Actions: `git.quick`, `git.menu {id}`, `git.commit
{message, filePaths|null, featureBranch}`, `git.defaultBranch {choice}`,
`git.init`, `git.publish`, `git.publish.submit`, `git.publish.cancel`,
`git.refresh`.

A stacked action is one `gitAction` subscription; its stage and last hook line
update one loading toast in place, and the MC's result toast (with its
next-step CTA) replaces it. The subscription is dropped, not resent, when the
connection drops, since the MC would run the action twice. `gitAction`
names the environment, so a thread's actions run on the machine with its
checkout. While an environment is offline the brick publishes
`available: false`, with the MC's reason for the failed `vcs` subscription as
the `unavailableReason` it shows; a refused action or call carries its reason
in its error toast.

### Composer layout

The `Composer` brick is a centered card (768 px
max) with the attachment chips, the editor and a footer of ghost pickers —
model, effort, permissions, the plan/build toggle — and the round send/stop
button. The context strip hangs under the card with the environment
selector, the checkout-mode picker, the PR badge and the branch button
(`workspace.*` actions); the branch picker pops upward from it.

### Composer extras

`composer.attach {files:[{name, mimeType, base64}]}` adds shell-read images to
the route's draft (the brick reads dropped or picked files through
`Shell.readImageFiles`, 10 MB cap, images only); they are published as
removable chips (`composer.attachment.remove`) and uploaded with
`assets.persistChatAttachments` when the turn is sent.

## Linux and packaging

`window.blur` is native on macOS (an `NSVisualEffectView` behind the Qt view,
`src/PlatformWindow.mm`, tinted by the theme's appearance). On Linux
`QGuiApplication::setDesktopFileName("hal-c2")` sets the Wayland app id /
X11 `WM_CLASS`, so compositor rules can target the window — on Hyprland:
`windowrulev2 = opacity 0.9, class:^(hal-c2)$` and `decorate:blur` — with
`window.transparent: true` in theme.json for the compositor to blur through.
`.github/workflows/desktop-qt.yml` builds Release binaries on Linux and
macOS with the official Qt 6.9 binaries (`jurplel/install-qt-action`) and
packages an AppImage (`scripts/package-linux.sh`, linuxdeploy + its Qt
plugin) and a macOS bundle (`scripts/package-macos.sh`, `macdeployqt`). `scripts/stage-runtime.mjs` stages
the host's TypeScript, the MC release
(`hal-c2-mc/`, from `mix release`) and the Node executable that runs the
host and the MC's sidecars. The Linux path was
written against the documented tooling but has only been exercised in CI, not
on this machine.

## Adding a feature

A feature is a native controller (`src/native/`, registered with
`NativeControllerRegistrar`) that builds its state from the shell's own MC
client, a brick the layouts place that renders it, and `@desktop` scenarios
run by `tst_Features`. Web content the desktop cannot draw opens in the
user's browser.

### Thread store and timeline

`ThreadStore` (`Threads`) follows each open thread through the MC's `stream`
shape, folded into a `TimelineModel` per thread: the active one plus a few
recently active ones stay subscribed. The fold is
`packages/client-runtime/src/v3/threadShape.ts` in C++; the rows follow the
TUI's timeline (folds of settled turns, tool call groups, markers) and the
brick draws them. A message's time and
actions fade in on hover but keep their place while hidden, so hovering never
re-lays out the list; `Timeline.alwaysShowMeta` shows them where there is no
hover (on by default on Android and iOS). A thread is
addressed by its environment (`ThreadStore::streamShape`), which the MC
routes to the cluster member serving it; a stream that errors waits for
the shell to list the thread's MC online again. A part-0 snapshot replaces the
entities but not the rows: row ids are stable, streamed text only emits
`dataChanged` for its row, and structural changes are applied as inserts,
moves and removes, so the `Timeline` brick keeps its scroll position. The
active thread is the navigation route's.

### Client cache

Why the MC sends a client only what it lacks is in [sync.md](sync.md). This is the client's half:
`LocalCache`, one SQLite file in the cache directory (`client-cache.sqlite`) written on a worker
thread. It holds the thread list by the origin the client was opened at, and the threads the user
opened by `environmentId:threadId`. It is a cache in the storage sense: deleting it, or opening
one of another schema, costs one full load and nothing else. The mobile client builds the same
`src/native`, so nothing in it may assume a desktop.

- **A copy is always whole as of its cursor.** A thread's entities and its cursor (`handle`,
  `offset`, `floor`) are written in one transaction, and so are an MC's rows and their version
  (`epoch`, `rev`). That is what lets the next `sub` say what the client holds. A change to a copy
  the cache no longer has is dropped rather than applied: half a copy would pass for a whole one.
- **The owner of the data owns its cursor.** `TimelineModel` and `ShellStore` say what a `sub`
  carries; `McClient` only asks them (`McClient::Resume`). A catch-up that takes several `events`
  frames is held until the frame that moves the offset, because a connection that dropped in
  between would be sent the same merged appends again.
- **Memory equals cache for an open thread.** A thread opens as its newest turns
  (`TimelineModel::windowItems`) and grows with `loadEarlier()`. When it is closed or evicted the
  cached copy is trimmed back to that window, so a thread never comes back larger than it opens
  and the cache never holds rows the model would not show.
- **Cached rows are not the MC's word.** `ShellStore::synchronized()` stays false until the
  `shell` frame, every MC reads as offline until then, and whatever removes or decides (drafts,
  routes, alerts, forgetting a thread) waits for it. Before it, `NativeShell` only previews
  (`NativeController::preview`): the sidebar, the route of a thread the cache lists, and that
  thread's kept rows as `loading` or `unreachable`, never `live`. Starting the controllers on
  cached rows instead would let them call an MC that has not answered. The first-run gate is the
  one thing preview settles: it covers the whole window until it knows setup is done, so a device
  that recorded finishing setup lifts it from that record. Without that the kept rows are painted
  under the cover and nobody sees them.
- **The cache is shown before the MC is known.** The desktop learns its MC's origin from the host,
  seconds after the window is up, so `ShellStore::showKept` holds the rows of the MC the client was
  last opened at until then. Only one origin's thread list is kept, and being opened at another
  drops it at once.

Which brick draws each route in the window's centre is one list,
`Bricks/js/centreViews.js`, which `CentreHost` loads from; every layout
places it the way it does `SettingsHost`. Thread and draft routes load `ThreadView`: the route's
timeline, a quiet loading line, the draft's opening line with its project and
checkout, and Retry (`Threads.reload`) for a thread whose MC stopped sending
it. Links in a reply open in the browser or, for a path, in the right panel
(`panel.open {tab: "files", path, line?}`); a reply's changed file opens the
diff on its turn. There is one revert, `Panel.diff` (`ThreadDiff`), which
follows the route's thread whether or not the panel is open: a reply's Revert
(on the turn `TimelineModel::checkpointOf` finds for its run) and the Diff
tab's both go through `requestRevert`, and `RevertDialog` asks before
`confirmRevert` sends `checkpoint.rollback`, keeping or restoring the files.
The MC marks the later runs `rolled_back` and the fold drops them. Scroll to
end is also the `timeline.jumpToLatest` command.

What the shell still lacks next to web and mobile is tracked as Gherkin, not
prose. The repository's `features/` tree tags every scenario with the surface it
must hold on and `@backlog` where the native shell does not deliver it yet;
`features/navigation/keybindings.feature` records which web keybindings work in
the shell. Add a new gap there, and turn a backlog scenario into a real test
(`tests/tst_Scenarios.qml` for brick behavior) when the feature lands.

## Release targets

Linux AppImage and macOS `.app` first, Windows later. Release staging bundles
the build's Node executable and license beside the host runtime, and the MC
release, which carries its own Erlang runtime.
