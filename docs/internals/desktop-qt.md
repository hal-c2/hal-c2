# Desktop (Qt) shell

`apps/desktop-qt` is the desktop client, replacing the legacy Electron app. It
is a compiled Qt 6 / QML binary (`hal-c2-qt`) whose window, chrome, layout and
colours are QML "bricks" a user can rearrange and restyle from
`~/.config/hal-c2/shell/`, fed by the shell's own connection to the node. It
still embeds the legacy web app in a `WebEngineView` for what has not moved to
QML yet; that page leaves piece by piece and nothing new is built on it (see
[Moving off the page](#moving-off-the-page)). Nothing in `apps/web` or
`apps/server-ex` may become Qt-specific.

## Process model

```text
hal-c2-qt (C++/QML, the shell)
  └─ spawns ─► node apps/desktop-qt/host/main.ts  (the desktop host)
                 ├─ serves ─► apps/web/dist on http://127.0.0.1:<web port>
                 └─ spawns ─► bin/hal_c2 start | mix hal_c2.server  (the Elixir node)
NativeShell (NodeClient) ── WebSocket (protocol 3) ──────────────────► node
WebEngineView (legacy page) ── WebSocket (protocol 3) ──────────────► node
WebEngineView ◄─── WebChannel ───► QML bricks
```

- **The shell talks to the node itself.** `NativeShell` holds its own
  protocol-3 connection (`NodeClient`), and its C++ controllers own the state
  of every piece that has left the page. The embedded page keeps its own
  WebSocket client, as in a browser tab, only for what it still renders.
- **The Node desktop host** owns everything TypeScript-owned: serving the web
  bundle and the node's lifecycle today; SSH, Tailscale, secrets and updates as
  they are ported from `apps/desktop`. It reports to the shell over its stdout
  as newline-delimited JSON (`ready {url}`, `error {message}`, `exit {code}`);
  the shell closes the host's stdin when it exits, which is the host's cue to
  stop the node it started.
- **The node is started the way Electron starts it.** A release
  (`HAL_C2_NODE_RELEASE`, else the bundled `hal-c2-node/`) runs `bin/hal_c2
start`; a checkout without one runs `mix hal_c2.server` in `apps/server-ex`.
  Either gets `HAL_C2_BOOTSTRAP_STDIN=1` and one JSON line on stdin (port, host
  `127.0.0.1`, `halC2Home` from `--base-dir`, a random `desktopBootstrapToken`;
  `HalC2.Desktop`), and `HAL_C2_NODE_COMMAND` names the host's Node for the
  node's JavaScript sidecars. The node runs in its own process group so a stop
  reaches the BEAM behind `mix` and the release script.
- **The app is served by the host, not the node.** The node serves no web
  bundle (`features/node/platform/http-and-hosting.feature`), so the web view
  runs the app the way the hosted static app runs: no same-origin server,
  every environment remote (`isHostedStaticApp` treats `window.halC2Shell` as
  hosted). Loopback HTTP rather than a custom scheme: `http://127.0.0.1` is a
  secure context (WebCrypto for DPoP), can still reach `http://` nodes on the
  LAN or tailnet, and needs no C++ scheme handler. The port is derived from the
  home (or `HAL_C2_WEB_PORT`) and stays the same across launches, because
  WebEngine keys IndexedDB and localStorage by origin: a new port would be a
  fresh app with no saved environments or drafts.
- **The ready URL opens the app paired.** It is the app's
  `/pair?host=<node>&auto=1#token=<desktopBootstrapToken>`; the pair route
  exchanges the token like any pairing link and goes to `/` on success. The
  connection catalog keys a bearer environment by its environment id, so the
  next launch re-pairs the same entry instead of adding one.
- **QML reads `Shell.state`, whoever fills it.** The web view publishes over
  WebChannel (`halC2Shell.publish(key, value)` → `Shell.state[key]`) and
  actions flow QML → web (`Shell.dispatch(action, payload)` →
  `halC2Shell.onAction(listener)`), except the ones the shell's own node
  client takes (below).
- **The shell's own node client** does what the TUI's does: the page is
  legacy, so RPC moves out of it key by key. In every mode the host's
  `ready` line carries the node's origin and access token, and `NativeShell`
  opens one protocol-3 socket (`NodeClient`) and folds the `shell` snapshot and
  row deltas (`ShellStore`, projects and threads). On the first snapshot it
  builds `sidebar` itself from those rows, its own drafts and its own `route`,
  claims the key so anything the page still publishes to it is dropped, and
  intercepts the row, project, draft and composer actions;
  it announces this as `native` and a `shell.native` action, and a page that
  loads later asks with `shell.native.query`. Nothing it builds reads
  page-published state. Environments outside the node's cluster are reached
  through the node's links (`ConnectionsController`). The shell subscribes
  with `{"type":"shell","links":true}`, and `ShellStore` keeps each linked
  node's rows beside the cluster's under a key of link and node (a linked
  environment's node names can collide with the cluster's), so everything
  that reads rows lists linked threads without special casing. A link that
  leaves `shell.links` takes its rows; one that drops keeps them, its nodes
  offline, and the sidebar rows and header say `offline`. The hello frame names the environment the node
  serves, which is where the shell sends calls about the node itself (its
  cluster). Pieces that never existed on the page, such as the cluster
  settings (`ClusterController`), have no page counterpart at all. The
  scenarios are `features/desktop/native-*.feature` and the `@desktop` and
  `@shared` ones in the files `tests/native/tst_Features.cpp` lists, run by
  the native `tst_Features`.
- The UI-owned parts of `desktopBridge` (open external, window commands,
  colour scheme, dialogs/context menus later) are served by the shell over the
  same channel; the TypeScript-owned parts stay on the Node side.

Attach mode (`--url <link>`) starts no node. The shell hands the link to the
host (`--attach`): a node pairing link (`mix hal_c2.pair`, `mise run node:pair`)
gets the app served and the shell's own client paired with that node, and any
other address is loaded as it is. For a node on this machine the host finds its
access token through the runtime record and the page keeps the link. For any
other node the host spends the link's single-use token on the shell's session,
then mints the page a fresh link with it; a link without `access:write` cannot
mint one, so the page opens unpaired (with whatever it saved before). Quitting
leaves the attached node running. `mise run desktop` attaches this way to the
node `mise run node` runs.

### Web engine

- **One profile.** `src/WebProfile.cpp` configures Qt WebEngine's default
  profile and registers it as the `WebProfile` singleton: storage and a 64 MiB
  disk HTTP cache under `<cache>/shell-web` (`~/.cache/hal-c2/shell-web`, or
  `<root>/cache/shell-web` under `--home-dir` or `HAL_C2_HOME`; see
  `src/StoragePaths.h`), cookies forced persistent, permissions stored.
  Every `WebSurface` shares it, so the embed surfaces reuse the primary's
  session and the bundle comes from cache on the next start. Chromium cannot
  share a profile directory between processes: a second shell on the same
  home finds the lock file taken and stays off-the-record for its run.
- **One renderer per surface.** Chromium gives each top-level view its own
  renderer process (roughly the app bundle's footprint each), so the shell
  keeps one: the right panel is native and embeds no second document. A
  surface that may hide sets `sleepsWhenHidden`, which freezes its page (no
  timers, no painting) until it shows again. The primary surface never sleeps.
- **The channel carries no properties.** QWebChannel re-sends a changed
  property to every connected page, so `Shell.state` is not on it: pages talk
  to `ShellChannel` (`publish`, `dispatch`, `snapshot`, `actionRequested`,
  `stateEntryChanged`), and `shell-connect.js` pulls the map lazily. A page
  that never reads it (the primary) is never sent its own publishes back.
- **Per-key bindings.** `Shell.state` is a `QQmlPropertyMap`, so a publish
  only re-evaluates bindings on that key. Keys are declared up front, in
  `ShellBridge.cpp` for the page's and in each native controller's
  registration for the ones it owns; a rice can read any of them, but a new
  key must be declared before a binding will follow it.
- **Permissions and downloads.** Pages get the async clipboard; other browser
  permissions are denied, notifications included: the shell raises its own
  (below). Downloads go to the user's download folder.
- **No width animation on the surfaces' neighbours.** Animating the sidebar
  or panel width resizes the web view every frame, which is a Chromium
  relayout and a new GPU surface each time; both snap instead.

## Source layout

| Path                     | Role                                                                 |
| ------------------------ | -------------------------------------------------------------------- |
| `src/main.cpp`           | CLI flags, config dir resolution, wiring                             |
| `src/ShellRuntime.*`     | QML root generations, `shell.qml` resolution, hot reload, fallback   |
| `src/ShellBridge.*`      | The `shell` WebChannel object / `Shell` QML singleton                |
| `src/ThemeStore.*`       | `theme.json` loader + watcher, `Theme` QML singleton, CSS injection  |
| `src/BackendProcess.*`   | Spawns the Node desktop host, waits for `ready`                      |
| `src/native/`            | The shell's node client and the controllers that take keys over      |
| `src/native/themes.json` | Built-in palettes, generated by `scripts/gen-themes.mjs`             |
| `qml/HalC2/Bricks/`      | Pure-QML bricks (see below) and the injected `js/shell-connect.js`   |
| `scripts/gen-icons.mjs`  | Regenerates `js/lucide.js`, the icon paths `ShellIcon` draws         |
| `scripts/gen-themes.mjs` | Regenerates `src/native/themes.json` from `packages/shared` palettes |
| `host/main.ts`           | Node desktop host: serves the web bundle, starts or attaches a node  |
| `scripts/dev-qt.mjs`     | Build, pair with the running node, launch                            |
| `examples/`              | Starter `theme.json` and `shell.qml`                                 |

QML modules: `HalC2.Shell` is C++-only (`Shell`, `Theme`, `Runtime`, and `WebProfile`
singletons, registered once and used by one engine throughout its lifetime). `HalC2.Bricks` is
QML-only with a hand-written `qmldir` (no `prefer` line) so the same directory
works compiled into the binary and as an on-disk import path.

The bricks come in two layers. Chrome bricks each own one piece of the page's
chrome and read one key of `Shell.state`: `Sidebar`, `Workspace` (the header
strip), `Composer`, `RightPanel`, `SettingsNav`, `ClusterSettings`,
`ConnectionsSettings`, `GitActions`, `Notifications`, `ContextMenuHost`, plus `WebSurface`,
`DefaultShell` and `ShellErrorOverlay`. `TerminalDrawer` reads the native
`Terminals` controller instead (see the terminal drawer below), and `Timeline`
renders a native `Threads` timeline (see the thread store below). `RightPanel`'s
native tabs, `DiffPanel` and `FilesPanel`, take their `Panel` object as
`source` (see `rightPanel` and `panel` below). A rice that
cards a surface passes the card's inner radius as `WebSurface.radius`
(`RightPanel` forwards its own; `TerminalDrawer` insets its terminal from its
own `radius`): the page clips itself to the curve and drops its own backdrop
(`data-shell-surface-radius` in `index.html` and `index.css`), so no QML layer is needed to
round a live web view. `WebSurface.transparentCanvas` additionally clears the
chat's web backdrop layers without fading text, messages, code or menus. A
transparent WebEngine background alone cannot clear CSS backgrounds or an
opaque parent `ShellCard`; wallpaper layouts must account for both.
Under them sit the primitives a rice composes its own
chrome from, all styled from `Theme`: `ShellWindow` (the root every rice
starts from: theme-driven colour, opacity and frame, `sidebarCollapsed`,
`settingsActive`, `settingsSection` and `nativeSettingsOpen`, the shell's context menus, the error
overlay and the page's window commands), `ShellCard` (a rounded, hairlined
panel), `ShellButton` (outline, `subtle` ghost, `primary`), `ShellComboBox`
(ghost, `outline: true` for a field), `ShellSplitButton` (the header's action
and chevron pill), `ShellMenu` / `ShellMenuItem`, `ShellTextField`, `ShellIcon`,
`WindowControls` (glyph buttons, or macOS traffic lights with
`trafficLights: true`), `TitleBar` and `HalC2Wordmark` (the web app's "HAL-C2"
mark as a filled `Shape`, sized by its height). `ShellIcon` draws the page's
lucide icons as a `Shape` from the path table in `js/lucide.js`, so bricks
pass an icon name (`iconName: "git-branch"`) and get the same glyph the HTML
shows, at any size or color.

`DefaultShell` is laid out like the page: the sidebar's brand band ("HAL-C2"
plus the collapse toggle), a 52 px header strip with the breadcrumb and the
run / open / git pills, the timeline, and the composer card with the checkout
strip welded under it. Frameless windows get their drag handle and buttons
from the brand band and the header strip (`Sidebar.window`,
`Workspace.window`), not from a `TitleBar`; the examples that want a title
bar row still use that brick.

## Setup

Requirements: CMake ≥ 3.21, Ninja, a C++20 compiler, Qt ≥ 6.9 with
`WebEngineQuick` and `WebChannel`, Node (the host runs from TypeScript source).

- macOS: `brew install qt` (6.11 at time of writing, WebEngine included).
- Linux: distro Qt often lacks WebEngine; prefer the official binaries via
  `uvx aqtinstall install-qt linux desktop 6.11.1 -m qtwebengine qtwebchannel qtpositioning`
  and set `QT_PREFIX=~/Qt/6.11.1/gcc_64`.
- CI/release builds use `aqtinstall` on every platform for reproducibility.

```sh
vp run --filter @hal-c2/web build   # once, and after web changes: the shell serves apps/web/dist
mise run node                       # terminal 1: the Elixir node on 3780 (HAL_C2_NODE_PORT)
mise run desktop                    # terminal 2: cmake build, `mix hal_c2.pair`, launch with --url
```

`mise run desktop` runs `scripts/dev-qt.mjs`. It uses `--home-dir`, else the
checkout's `.hal-c2`, as the shell's `HAL_C2_HOME`, so the shell rices from `<root>/config/shell/` and keeps its web
profile under `<root>/cache`. Its other flags are `--url` (attach to that link
instead of pairing), `--standalone` (start the shell's own node from source, as
the installed app does; not next to `mise run node` on the same home),
`--release` (no disk QML loading) and `--configure-only` (build, do not
launch, which `mise run desktop:build` runs); everything else is forwarded to
the binary, so `mise run desktop -- --screenshot out.png --action
rightPanel.toggle` works. Build output lands in
`apps/desktop-qt/build/<debug|release>` (gitignored).

Standalone: run the binary with no `--url`; the host serves the built web app
and starts the node for the shell's home.

CLI: `--url`, `--home-dir`, `--config-dir`, `--qml-dir`, `--host-entry`, `--node`, `--screenshot <png>`
(grab the window once the node's first snapshot is in, or with the error when the start fails, then quit with
0, or 2 on a failure; PR evidence without a screen-recording permission, and with
`QT_QPA_PLATFORM=offscreen` without a window at all), `--action name[=json]` (repeatable; dispatch shell
actions after that snapshot, e.g. `--action rightPanel.toggle`), `--key <chord>`
(repeatable; press a key chord after it, e.g. `--key Ctrl+1`, portable
`QKeySequence` names — `--action` and `--key` run in command-line order, 1.5 s
apart, so a key test can open a thread first); env `HAL_C2_HOME`,
`HAL_C2_QML_DIR`, `HAL_C2_NODE_BIN`, and for the host `HAL_C2_NODE_RELEASE`
(a node release or its `bin/hal_c2`), `HAL_C2_WEB_DIST` (a built
`apps/web/dist`), `HAL_C2_NODE_PORT` and `HAL_C2_WEB_PORT` (fixed ports; a taken
one is an error rather than a silent move).

## Ricing contract

Config dir: `<config>/shell/`, so `~/.config/hal-c2/shell/` by default on Linux
and macOS (`XDG_CONFIG_HOME` moves it), `%APPDATA%\hal-c2\config\shell\` on
Windows, and `<root>/config/shell/` under `--home-dir`, `HAL_C2_HOME` or a
sandboxed dev run's `<worktree>/.hal-c2`; `--config-dir` overrides just this
directory. The shell creates it at startup and watches it, so a shell the hosted
server migrates from an old `~/.hal-c2/shell/` or `~/.t3/shell/` loads without a
restart.

### `theme.json`

The file _is_ the interface for colour propagation: theme managers (omarchy
themes, pywal templates, a hand-written file) write it and the app follows.
The shell itself does not import terminal configs; the generator that comes
closest, `vp run theme:qt [shell-dir]` (`scripts/theme-from-terminal.mjs`),
asks the running terminal for its palette over OSC 10 / 11 / 12 / 17 / 4 and
writes `theme.json` into the shell directory from the answer, keeping the
shell on the file contract.

Its shape is the web app's own `ThemeFile` (`apps/web/src/themePalette.ts`;
the Settings → Theme editor exports it) plus a shell-only `window` section:

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

- `colors.*` keys are the web's theme roles (`canvas`, `chrome`, `surface`,
  `text`, `textMuted`, `accent`, `sidebar`, `terminalBackground`, … — the
  `ThemeColorRole` list in `packages/shared/src/themePalettes.ts`).
  `variants.<appearance>` overrides `colors` for that appearance.
- The native document-creation script applies the first-paint colors, then
  hands its override to the web theme module through `window.__halC2ShellTheme`.
  The web module applies the override after stored palettes and editor previews,
  without changing saved preferences. Native reinjections deliver data only.
  Embedded documents claim their own override without publishing native colors.
  Older pages retain the DOM-observer fallback. Supply the full role set
  (the files under `examples/*/` do) for consistent colors during startup.
- QML reads the same roles: `Theme.colors`, `Theme.palette.color("chrome", fallback)`,
  `Theme.appearance`, `Theme.id`.
- `window.*` is shell-only: `opacity` (whole-window), `transparent` (window and
  web view background cleared; compositor rules do the blur on Wayland),
  `blur` (advisory for platform hooks), `frameless` (default `true`).
- `window.followSystemAppearance` makes `variants` track the app's appearance
  (the system's unless the user pinned light or dark); otherwise the file's
  own `appearance` holds.
- The file is watched; edits apply live to QML and to the page. A malformed
  file keeps the previous good theme and sets `Theme.lastError`. Deleting it
  returns to the theme the shell resolves (below). The file never changes the
  user's saved choice.

### `shell.qml`

If `~/.config/hal-c2/shell/shell.qml` exists it is loaded as the root instead of the
built-in `DefaultShell.qml`. It composes bricks from `HalC2.Bricks` and reads the
`HalC2.Shell` singletons:

- `Shell.pageUrl`, `Shell.state` (whatever the web app published),
  `Shell.dispatch(action, payload)`, `Shell.windowCommandRequested(command)`.
- `Theme.*` as above.
- `Runtime.configDir`, `Runtime.userShellPath`, `Runtime.usingUserShell`,
  `Runtime.lastError`, `Runtime.reload()`.

Extra QML modules can live under `~/.config/hal-c2/shell/qml/` (it is on the import
path). If `shell.qml` fails to load, the default shell takes over with
`ShellErrorOverlay` showing the error; a broken rice never locks the app.

### Local extensions

Extensions are trusted QML components instantiated by `shell.qml`, not a plugin
registry or a sandbox. `DefaultShell` exposes `sidebar`, `composer`, `workspace`,
`webView`, `terminalDrawer`, and `rightPanel` so extensions do not need to copy
the layout. Removing a component removes its controls and signal subscriptions.
`DefaultShell.toolbar` accepts a component above the timeline. Give it an
`implicitHeight`; the empty slot takes no space. Use it for extension controls
rather than positioning buttons over web content.

`Composer.editorActions` accepts toolbar controls. `editorKeyPressed(event)`
allows opt-in input handling, and `insertText(text, capturedTarget)` replaces the
selection only while that draft remains selected and editable. Capture
`publishedTarget` before asynchronous work; insertion does not submit a turn.
`ComposerVimKeys` implements a deliberately limited, disabled-by-default modal
editor. Focus and rename entry points are `Composer.focusInput()`,
`Composer.toggleCheckoutPicker()`, `Workspace.beginRename()`, and
`TerminalDrawer.focusTerminal()`.

`Sidebar.model` can be overridden to filter or reorder the published rows.
The source includes `createdAt` and `latestUserMessageAt`; the latter excludes
agent replies and renames. Local filtering cannot recover rows omitted by the
page's 50-row Settled limit. `thread.markUnread {key}` uses the existing client
unread state.

`ProjectFolderDrop` imports one existing directory through `ProjectController`
(`projects.mutate`). It does not create, rename, move, or delete directories.
`ShellBridge::localFolders` decides whether this machine's folders are the
node's: the shell's own backend, or explicit `--allow-local-folder-import` for
an attached URL, and a node origin on loopback. Do not enable that flag for an
SSH-forwarded backend with a different filesystem; its loopback origin looks
local.

`examples/folders` adds a native folder explorer using Qt's `TreeView` and
asynchronous `QFileSystemModel` through `DefaultShell.navigationPanel`. The
thread sidebar stays visible beside the file browser, or above it on narrow
windows; the browser does not replace thread navigation. Files are listed
read-only. The `FolderExplorer` brick provides create,
rename, move and confirmed system-Trash actions through `LocalFolderModel`.
It never falls back to permanent deletion. Operations are limited to plain
folders inside the chosen root, not files or remote directories. Existing
destinations cannot be overwritten. The chosen root, symlinks, home and
filesystem roots, registered project roots, and their containing directories
are protected from rename, move and Trash. Moving a live project root would
leave thread paths stale, so that is not offered here. The model is enabled
only while the explorer is visible, the primary loopback environment is
connected, and native local-folder permission allows access. No native
filesystem methods are exposed to the web page.

`sidebar.localProjects` lists every checkout of the environment the shell's
node serves, independently of grouped sidebar representatives. "Remove from
HAL-C2" sends `project.remove {projectKey}` for one physical checkout, which
opens the shell's own confirmation (below). Confirming permanently deletes
that entry's conversation history, including archived threads, and its
drafts; it leaves files on disk. This is separate from Trash, not a safe
workaround for renaming or moving a registered project root.

### Independent views and windows

`window.new` (the palette's "New window", or `Shell.dispatch("window.new",
{id})` from a layout) opens another native window: its own QML engine
(`ShellRuntime`) on its own `ShellBridge`, loading the same `shell.qml`. The
node connection, the shell store and the shared controllers
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
asked; what every page needs (`clientSettings.follow`) goes to every window's
bridge. A shared controller meets each window in `attach()`.

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
it shows the window again (as Electron's `DesktopLifecycle` did). Qt's own
quit-on-last-window is off, since a hot reload or a closed popup must not
quit. Pass a stable `id` to reopen a known window rather than opening another;
ids name folders, so the shell accepts only `[A-Za-z0-9_-]{1,32}` and
generates one otherwise.

`AppView` and `AppWindow` are the web client's equivalent: another complete
page sharing `WebProfile` authentication, with a per-view `storageId`
namespace for the page's own drafts and panels and no primary shell bridge.
`AppWindow` clears its transient parent so it is a normal top-level window.
`--app-id` sets the native desktop identity before any window is created,
allowing launch-profile-specific window rules.

### Notification delivery

`AlertController` decides when a thread alerts, from the shell's own rows
(cluster and linked environments alike), as the web's
`ThreadNotificationCoordinator` does; the page's coordinator is not mounted in
the shell, so nothing alerts twice. It compares each thread with what it saw
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
argument vector, never a shell command. It is available to trusted local QML,
not to the hosted page. It starts only when the extension calls `start()`.
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
types. The web view is recreated with the window
and reloads the page; keeping it alive across generations is a follow-up.
QmlLive was evaluated and rejected: unmaintained since 2019, Qt 5 only.

## Page-side API

`WebSurface` injects `qwebchannel.js` (bundled from Qt's data dir at build
time) and `js/shell-connect.js` at document creation, which exposes:

```ts
window.halC2Shell: {
  protocolVersion: number;                           // 1
  surfaceId: string;                                 // "primary" | "rightPanel"
  ready: Promise<ShellObject>;                       // raw WebChannel proxy
  publish(key: string, value: unknown): Promise<void>;
  dispatch(action: string, payload?: unknown): Promise<void>;
  onAction(listener: (action: string, payload: unknown) => void): Promise<() => void>;
  getState(): Promise<Record<string, unknown>>;      // everything published, any document
  onState(listener: (state: Record<string, unknown>) => void): Promise<() => void>;
}
```

`window.halC2Shell` is undefined in a browser tab; the web app must keep working
without it. `apps/web/src/env.ts` exports `isHalC2Shell` (module-load-time, like
`isElectron`). The contract — what gets published under which key and which
actions exist — lives in `packages/contracts/src/shell.ts` and is imported as
`@hal-c2/contracts/shell`, not from the package barrel, so browsers never
bundle it. The bridges follow the same rule: `apps/web/src/shell/lazy.tsx`
wraps each one in `React.lazy`, and only a shell-hosted document ever imports
`shell/bridges.ts`. Every bridge decodes actions through `useShellActions`
(one subscription per bridge, handlers read live props) and publishes through
`useShellPublish` (skips unchanged JSON, clears the key on unmount).

### `sidebar`

`SidebarController` publishes `ShellSidebarState` from the shell's node rows
(`SidebarModel`, a port of the web sidebar's logic): project groups, the
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
`<environment>:<root>`. There is no manual project order yet. The page
publishes no sidebar; when hosted, `AppSidebarLayout` renders none either.

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
from the environment's `addProjectBaseDirectory` setting, else `~/`. The node
adds the project at once and clones in the background; each clone an online
environment reports on its `projectClones` shape (by environment, so a linked
one's come through the link) is one toast, updated in place, whose Cancel and
Retry keep it open. Only before the shell has
its node, or with a path where the page may not reach local folders, does
`project.add` fall through to the page. `project.remove
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
arrives, or whose project goes, is dropped. The page is told the draft's
`environmentId`, `projectId` and `threadId` with `route.follow`, and draws
the composer for that thread id; a draft the page opened itself comes back
the same way with `route.open` and is adopted. The draft's text is kept with
the draft: the composer's `composer.text.set` on a draft route saves it
through `DraftController`, so it survives a restart. As on the page, the
sidebar lists only drafts that hold something, and the open draft keeps the
row it had when the window opened it, so a fresh draft is not listed while
the user types into it.

The QML sidebar reconciles publications into a keyed `ListModel`, updating
and moving existing rows instead of replacing the list. This preserves row
hover, keyboard focus and scroll position while thread state changes.

Actions (`Shell.dispatch(name, payload)` in QML → `ShellAction` on the page):
`sidebar.scope {projectKey|null}`, `project.add {path?}`, `project.remove
{projectKey}`, `draft.menu {draftId, x, y}`, and the
navigation ones `route` takes once the shell has its node (`thread.open {key}`,
`draft.open {draftId}`, `thread.new {projectKey?}`, `settings.open`,
`pullRequests.open`, `usage.open`). The active row is the route's. Row actions run the
handlers the HTML row's hover buttons use (`useShellThreadRowActions`):
`thread.settle {key}`, `thread.unsettle {key}`, `thread.unsnooze {key}`,
`thread.snoozeMenu {key, x, y}` (the snooze durations open as the shell's
`menu` at those window coordinates), `thread.wokeDismiss {key}`, and
`thread.menu {key, x, y}` for the thread menu. Unknown or malformed actions
are dropped by the schema guard.

`SidebarThreadRow` mirrors the HTML row's states: Working/Monitoring,
Approval, Input, Failed, Woke (a pill that dismisses on click while `wokeAt`
is set) and Done (unread) take the age label's place, coloured with the
`info`, `warning`, `accent`, `error` and `success` theme roles; rows that
need nothing recede. Hovering or keyboard-focusing a row swaps that slot for
its actions — snooze and settle on live rows, wake on snoozed rows, un-settle
on settled rows — and a right-click anywhere on the row opens the thread
menu on press.

The HTML sidebar and native row actions share `threadParking.ts` for navigation
planning and pending commands. The plan is captured before a settle or snooze;
successful commands navigate only if the same thread is still open. HTML keeps
separate settle/snooze pending scopes and batch exclusions; native row actions
share one pending scope. Menus, Undo, and batch feedback stay with their callers.

The thread list is a Tab stop. Up/Down move a cursor (a ring in the `focus`
theme role) over rows and section headers, Home/End jump to the ends, Enter
or Space open the row or fold the header, and Menu or Shift+F10 open the
thread menu at the row. The cursor starts on the active thread. Row action
buttons are not Tab stops; the thread menu carries the same actions.

### `composer`

`ComposerController` publishes `composer` (`ShellComposerState`) and owns
the composer of the thread or new-thread draft the route shows; the page
publishes nothing for it. Each thread keeps its draft (text, caret, model,
options, modes, images) in the controller, saved on this machine; a new
thread's text is `DraftController`'s. It sends, queues, steers, stops,
answers approvals and questions and implements the plan with node RPCs, and
publishes the route thread's pending state as `turn` (see
`ComposerController.h`), which the `TurnRequests` brick stacks above the
`Composer`. A new thread's first send launches it
(`orchestration.launchThread` with the draft's checkout, model and modes) and
the window replaces the draft with the thread; a background send leaves the
draft for another prompt and toasts a way to open the thread, or to restore
the prompt if the launch fails.

The model catalogue is the `providers` of the route environment's config
(`WorkspaceController::environmentConfig`), so a linked thread lists its own
machine's models, gated on the environment being online rather than local.
It is its own key, `modelPicker`, because `composer` republishes on every
keystroke and an OpenCode catalogue runs to dozens of models. It holds the
enabled instances in rail order, their models already filtered, ordered and
marked (favourite, legacy, disabled reason), plus the picker's chords
resolved from the user's keybindings. The `ModelPicker` brick copies the web
picker's rail, ranking, rows and keys from that (`js/modelPicker.js` names
the web files it mirrors), so search stays in QML and only a choice or a star
crosses back. `composer.model.select` accepts only a ready instance's listed
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
without sending; `$` the provider's skills; `@` asks the node's workspace
search (`WorkspaceFiles`, the Files tab's) for the route's checkout. Selecting
sends the item id back and the controller applies the replacement.

Editing a queued message (the queue row's Edit, or the edit key with the
caret at the start of the draft) swaps its text into the thread's composer
and sets the thread's draft aside, so the set-aside draft is what is saved to
disk; a send saves the edit with `queued-run.edit` (text only, so its images
stay as they were) and gives the draft back. The web keeps the edit under its
own draft target instead; the swap keeps every composer path on one target.

Terminal excerpts (`composer.terminalContext.add`, from a terminal's
right-click Add to chat or the web's terminal document) are chips on the
draft, not inline links as in the web's editor: the Qt editor is plain text.
A send appends one inline context link per excerpt to the message text and
carries the excerpts as `context` records, because the node only hands the
provider records whose link is in the text (`HalC2.ComposerContext`). The
Ghostty `Terminal` does not say where its selection is, so the brick counts
the lines at the selection's last occurrence in the terminal's text. Excerpts
live in memory like images.

Prompt history (`composer.history.step`) is not the controller's yet: it
drops the step.

The page's `modelPicker.toggle` command dispatches
`composer.modelPicker.toggle` page → shell, and the toolbar commands
(`composer.effort`, `.mode`, `.host`, `.workspace`, `.branch`) dispatch
`composer.control.open {command}`; the `Composer` brick listens on
`Shell.actionRequested` and opens its own control.

### `rightPanel` and `panel`

The native `Panel` controller (`src/native/RightPanelController.cpp`) owns
the right panel: open or closed and which tab shows, per thread, published as
`panel`. The Diff and Files tabs are native bricks (`DiffPanel`, `FilesPanel`)
over the controller's `ThreadDiff` and `WorkspaceFiles`, which call the
node's `orchestration.getTurnDiff`, `getFullThreadDiff` and `projects.*` RPCs
on the thread's own environment. The Agents tab (`AgentsPanel` over
`AgentsModel`) needs no RPC: it reads the `subagent` entities and running
`command_execution` items the thread's stream already carries, and its
elapsed times tick only while it shows (the web dropped this tab when lineage
moved to the title bar; the desktop keeps it). A terminal tab is
`terminal:<group>`: one of `TerminalController`'s panel groups (below), made
by `rightPanel.add {kind: "terminal"}` and closed, terminals and all, with its
tab; `TerminalPanel` draws it. The Pull requests tab (`PullRequestsPanel`
over `ThreadPullRequests`) reads the links the thread row already carries,
links and unlinks with the `thread.pull-request.link`/`.unlink` commands, and
refreshes with `pullRequests.invalidate`; linking accepts any repository on a
host a project reads, as the web dialog does. Offline its rows stay as last
synced and nothing is sent. The Previews tab (`PreviewsPanel` over
`ThreadPreviews`) lists the thread's browser tabs from `preview.list` and the
`preview` shape, subscribed only while it shows, and opens each in the user's
browser. Moving another tab to QML is a line in `js/panelTabs.js` plus its kind
in `RightPanelController::nativeKinds`.

The desktop embeds no browser. QtWebEngine is the dependency being removed,
and QtWebView is WebEngine underneath on Linux with no input injection, zoom
or popup control, so neither can host the agent's preview tabs (that host was
only ever Electron's `desktopBridge`). The embedding scenarios in
`features/preview/surfaces.feature` are `@backlog-desktop` for that reason.

The Pull request review tab (`pull-request:<host>/<repository>#<number>`,
titled "PR #n") is `PullRequestReviewPanel` over the controller's
`PullRequestReview` (`Panel.review`). It opens from the add menu or a Pull
requests row's menu (`rightPanel.review {key}`) and reads the pull request
through the thread's environment: `pullRequests.detail` and `.activity` over
the socket, and the code over HTTP (`POST /api/pull-requests/diff`, one
`nextCursor` slice at a time, with `NodeClient::post`), which lands in a
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

Device tabs (`ThreadDevices`, `DeviceStream`) follow the node's `devices`
shape and stream through its device-hub proxy with the shell's bearer token,
decoding H.264 with FFmpeg's libavcodec (headers at build time, the libraries
loaded at run time; see [Devices](devices.md#the-viewers-decode-both-vendored-protocols)).
A device tab streams only while it is the active tab.

The panel never asks the page for anything. Per thread, the controller keeps
whether it is open, its tabs, the active one and the details column, plus one
width for all threads, in `shell-panel.json` in the state directory, so they
survive a restart (maximizing does not). `rightPanel.resize {width}` and `rightPanel.toggleMaximized`
come from the brick's edge and the keybinding. `panel.open {tab, path?,
line?, turn?, turnId?}` opens a native tab on a turn's diff or a file at a
line, for the timeline's links.

### `workspace`

`WorkspaceController` builds `workspace` from the node, in the page's
`ShellWorkspaceState` shape: the thread and its project are `ShellStore` rows,
the git summary the node's `vcs` shape for the checkout, the refs
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
draft's checkout (mode, start from
origin, branch, worktree, the machine it runs on) is kept natively by draft
id and the page is told each change: `workspace.envMode.set`,
`.startFromOrigin.set` and `.environment.set` go on to it after they land, and
a branch picked for a draft as `workspace.checkout.follow {draftId, branch,
worktreePath, envMode}`. Which thread a draft is, `NativeShell` asks
`DraftController` (`setDraftResolver`). The `vcs` shape names the thread's
environment, so a linked thread's git status comes through its link; while the
link is down the subscription fails at once with the link's message
(`gitError`), and it is followed again when the environment comes back.
`config` names the environment too, so another machine's editors, cluster or
linked, are watched while it is online.

The terminal drawer is native: `TerminalDrawer` draws each of the thread's
terminals with [qml-ghostty](https://github.com/hal-c2/qml-ghostty)'s
`Terminal` item (libghostty-vt, built as described in the app's README), and
`TerminalController` (the `Terminals` singleton) talks to the node for it over
the shell's own `NodeClient`, as the sidebar and composer do. It takes the thread (drafts included), its
project root, worktree and scripts from `WorkspaceController::place()`, and
the header's run pill (`workspace.runScript`, handled by the workspace) types
into a drawer terminal it launched itself. Its shapes name the
environment, not a node, so the node routes them to the cluster member that serves
it or through a link (`HalC2.Links`) to an environment outside the cluster; the
drawer is available wherever the header is, cluster and linked environments
alike (`features/terminal/drawer.feature`).
Environments outside the cluster are paired natively, as node links (see
`connections` below); the page's saved environments are not lent to the node.

- **Launch context.** Every attach and open sends the thread's cwd (worktree,
  else project root) and the same `HAL_C2_*`/`T3CODE_*` root variables as the
  web client. The node restarts a shell whose launch env changed, so the shell
  must send the same env every time.
- **Replay.** A session keeps the transcript it attached with plus what has
  arrived since (capped like other clients' buffers), so a tab created late replays
  with `Terminal.restore()`, which answers no queries. Only live output goes
  through `write()`; replaying history through it would answer stale device
  queries into the shell.
- **One write in flight.** Keys typed while `terminal.write` is pending
  coalesce into the next one, so the shell sees the user's order.
- **Hidden is not detached.** Once opened, the drawer stays attached while
  hidden, like the page's drawer did, so output keeps arriving and switching
  back costs nothing.
- **Groups.** Terminals are laid out in groups, as the web's terminal grid: a
  terminal never split is a group of its own, `terminal.split` (side by side)
  and `terminal.splitVertical` (stacked) add one after the focused terminal,
  at most four to a group. A panel group is a right panel tab and never shows
  in the drawer. Each `tabs` row carries its group and place in it, and
  `TerminalSplits` makes a `Terminal` only in the place (drawer or panel) the
  row belongs to, so no session has two views fighting over its size. Groups
  live in memory: a restart or another client sees ungrouped drawer terminals.

### Settings sections and the shell's own pages

The settings nav is the shell's (`SettingsNav`); the sections behind it are
either the shell's own or still HTML.

The shell's own sections work with no page loaded. `js/settingsPages.js`
lists every section in the page's order: a section with a `brick` is native,
and moving one to QML is giving its line a brick, the state key it
`requires` before it is listed, and the words and rows search finds it by.
`SettingsHost` loads the brick for `ShellWindow.settingsSection`, and layouts
put it where the page would be while `ShellWindow.nativeSettingsOpen`.
`NavigationController::isNative` lists the routes the page is never told
about; General and Appearance are native bricks but still `route.follow` the
(hidden) page, which draws with some of their preferences.

Search is the shell's too. `settingsPages.searchRows` matches sections by
label and keywords, and a section's settings (its `settingsRows.js` rows and
any `settings` entries) by title and description; every word of the query
must match, and a result names the setting's `targetId`. Opening one is
`settings.openResult {to, targetId}`: `NavigationController` opens the
section and bumps `route.targetSeq` with `route.target` set, and
`SettingsPage` scrolls the brick's child of that objectName to the top on
each bump, so opening the same result twice scrolls back to it. Sections
still on the page get the page's results, and the page scrolls those itself.

General and Appearance are rows over `Settings` (`js/settingsRows.js`: a key,
a kind and the web's wording). Each key's store and default are
`SettingsController`'s row table: `setting`, `defaultOf`, `isDefault`,
`onDevice`, `set` and `reset` read and write it wherever it lives. The node
leaves defaults out of its document, and a null `sidebarAutoSettleAfterDays`
means off. Rows the page still draws with are device preferences, and the
shell sends them to the page as `clientSettings.follow {settings}` whenever
they change. Appearance also draws the theme choice and this device's own
themes (`ThemeEditor`); errors are the shell's toasts.

Each other native section is a controller publishing one key, whose header
documents the shape and actions:

- **Cluster** (`ClusterController`, `cluster`) calls the node's `cluster.*`
  RPCs.
- **Connections** (`ConnectionsController`, `connections`). Other
  environments are the node's links from the `shell` shape; adding one is
  `hal-c2.linkEnvironment` with a pairing link, or a host and code (a host
  without a scheme tries HTTPS, then HTTP), and the node has no rename for a
  link. While open it follows the `authAccess` shape and calls the `hal-c2.*`
  access RPCs, which need `access:read`/`access:write`, so a session paired
  with standard scopes sees one explanation in place of the list. A created
  link's secret lives only in `created` until the section closes. A link
  needs a direct origin and a bearer token: an environment reached only
  through the relay (DPoP) cannot be linked yet.
- **Providers** (`ProviderSettingsController`, `providerSettings`) shows one
  environment at a time: its `config` shape brings the providers, and each
  provider that signs in from HAL-C2 has its `providerAuth` shape followed.
  That shape is node-addressed, so signing in works only on environments a
  cluster node serves. Turning a provider off is a settings edit on that
  environment, read back and retried on `StaleSettings` like the shell's own
  settings. Instances, custom models and a registry agent's sessions and model
  providers are edited through the same model; the ACP Registry search and a
  registry agent's sessions, model providers and logout are node RPCs asked
  from the followed environment, and their answers are held only while the
  section shows.
- **Archive** (`ArchivedThreadsController`, `archivedThreads`) is fetched,
  not streamed (`features/parity/rpc.feature`): opening it, refreshing, an
  action landing, or the online environments changing asks each one for
  `orchestration.getArchivedShellSnapshot`, which covers only the rows of the
  node that answers.

Home, the pull requests page and usage are routes of their own, drawn by
`HomePage`, `PullRequestsPage` and `UsagePage` over `PullRequestListController`
and `UsageController`; they too follow node shapes only while open. Home is
never where a window with projects stays: once every environment has
reported, `DraftController::land` replaces it with the most recent project's
draft (`sidebar::mostRecentProject`, the web's "updated_at" order), reusing
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
tools scans only the scope's first connected environment, as the web did,
and so does Integrations' device status. Integrations is only the device hub:
the desktop embeds no browser, so the web's browser defaults have no native
counterpart. A picked project follows its folders when the sidebar regroups
(`SidebarController::grouped`), as the web's settings project groups do. The
Project section also carries how new threads start (model, permissions,
workspace, submodules), which the web splits between it and General, since the
native General page holds only this device's settings.

SnapShots is still HTML: the desktop has no capture helper. The shell's
settings navigation and search are its own (`js/settingsPages.js`); picking
SnapShots sets the route and the page follows it there like any other page
route. When hosted, `AppSidebarLayout` renders no sidebar on any route.

### `route`

`NavigationController` owns where the window is once the shell has its node:
`route` is `{kind, threadKey, draftId, projectKey, section, title,
canGoBack, target, targetSeq}` with `kind` one of `home`, `thread`, `draft`, `newThread`,
`settings`, `pullRequests`, `usage` (the `ShellRoute` contract plus
`title`, `canGoBack` and the settings search's target). `ShellWindow` titles the window from `title` and derives
`settingsActive` and `settingsSection` from it; the sidebar's active row and the
composer's target thread come from it too. It keeps a back stack (home and a
new thread are passed through, and moving between settings sections is one
step) and writes the last route to `shell-route.json` in the shell's state
directory; the next launch reopens it unless the thread was deleted or the
user clicked somewhere in the page before the node answered.

The page still draws the centre, so it follows: the shell sends
`route.follow {kind, …}` (with the draft's thread for a draft) for every route
the page is not already on (and to a
page that reloads), and `HalC2ShellBridge` navigates there. Where the page's
own links, redirects and history take it comes back as `route.open {kind, …,
replace}` (`shellRoute.ts` maps paths), and the shell adopts it; a page
report that matches the top of the back stack pops it. The page never keeps
state of its own about where it is beyond its URL.

Bridges tied to a thread route (`workspace`, `rightPanel`)
publish `null` for their key on unmount, so leaving a thread clears the
native chrome instead of freezing it on the last thread.

### Settings and preferences

`SettingsController` (the `Settings` QML singleton; C++ reaches it with
`NativeShell::controller<SettingsController>()`) holds two stores. The API is
documented in its header; later settings pages build on it rather than on
page state.

- The node's settings document, shared by every client of the environment:
  `hal-c2.readSettings` gives `{settings, version}`, and `hal-c2.writeSettings`
  saves a whole document at the version it was read at. A change is an edit
  function (`change(edit, done)`, or `Settings.write(path, value)` from QML).
  When another client saved first, the node refuses the write as
  `StaleSettings`. The store then reads again and applies the same edit to what
  the node holds, a few times before it reports the failure, so a stale copy
  never overwrites a newer one. It subscribes to the node's `config` shape
  (the snapshot, `config.settings`, `config.providers`, `config.themes`) and
  reads again on each snapshot. A reconnect may reach a restarted node whose
  versions start over.
- This device's preferences, in `<config>/preferences.json` next to
  `theme.json`: anything that belongs to this desktop and no other client
  (appearance, theme choice, saved custom themes, the client settings rows).
  They are available before
  the node is. A save that fails sets `deviceError` and leaves them as they
  were. Nothing migrates from the page's storage; they start empty.

### `theme` (shell → page)

`ThemeController` (the `Themes` singleton) claims `theme` and publishes the
`ShellThemeState` it resolves; the page's own publishes to that key are
dropped. The choice lives in this device's preferences: `appearance`
(`system`, `light`, `dark`), `theme`, `themeHalves` (a theme per appearance)
and `customThemes`. An id is looked up among the built-ins first, then this
device's saved themes, then the themes the shell's own node publishes. Themes
from linked environments are never offered. The lookup mirrors the web's
`getThemeDefinition`: missing roles come from the T3 Chat palette, and a
theme with one appearance takes that half only. An id that is no longer found
draws the standard look, published as `hal-c2` so the page paints the variables
it is given. The built-ins are `src/native/themes.json`, generated from
`packages/shared/src/themePalettes.ts`. Run `node apps/desktop-qt/scripts/gen-themes.mjs`
after changing a palette. Colours are converted from `oklch()` natively.

`ThemeStore` paints the resolved theme with `theme.json` over it, role by role,
and hands the result to the page through the injection script above, so the
page follows the shell. `Theme.palette.color()` resolves theme.json first, then
the resolved theme, then the brick's fallback. The notified `palette` receiver
makes QML bindings follow theme changes; direct calls to the C++ `Theme.color()`
method do not create that dependency. `Theme.radius`, `Theme.fontUi` and
`Theme.fontMono` follow the same order (the shell-only `radius` / `fonts` keys in
theme.json win). The themed controls (`ShellButton` etc.) take radius, surfaces,
borders and fonts from `Theme`.

Settings → Appearance chooses and edits themes through `Themes` (`setMode`,
`choose`, `chooseHalf`, `draft`, `saveCustom`, `duplicate`, `removeCustom`).
The page's own picker and appearance shortcut reach the shell as `theme.mode
{mode}`, `theme.choose {id}`, `theme.chooseHalf {appearance, id}` and
`appearance.cycle`, which is `Themes.cycleAppearance()` (System → Light → Dark,
with one toast however fast it is pressed). Themes made in the page's own
editor live in the page's storage and are unknown to the shell.

### `layout`

The shell owns whether the thread list is hidden: `LayoutController` claims
`layout {sidebarCollapsed}` from the page, remembers it in the device's
`preferences.json`, and publishes it before the node's first snapshot so a
restart does not flash the list. `sidebar.toggle` (action and keybinding
command, Mod+B by default) flips it. The `Workspace` brick shows a toggle when
its `sidebarToggle` property is bound (it takes the sidebar's place at the
strip's left edge), and `Sidebar` shows the matching collapse toggle in its
brand band when `showBrand` is on. The right panel's toggle follows the same
pattern: `Workspace.panelToggle` puts it in the header strip and `RightPanel
{ ownToggle: false }` then takes no width while closed; a rice that leaves
`ownToggle` on gets the 36 px rail with the toggle instead.

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
tips stay unscaled, as native ones do. The embedded page is scaled as a
texture.
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
merges `src/native/Keybindings.cpp`'s copy of the web defaults with the rules
the node pushes as `config.keybindings` (a custom rule for a command replaces
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
it; only the order of the root list (`kRootCommands`, the web's hand-picked
actions) is its own. It adds the shell's threads by key (linked environments
and cluster threads alike), the sidebar's projects, the settings sections
`js/settingsPages.js` hands it (without those whose `requires` is missing)
and, from two characters, threads whose messages match. Go to file
(`filePicker.toggle`) and project search (`projectSearch.toggle`) are modes of
the same list against the route thread's environment, only while it is
online; node searches wait for typing to pause and only the newest answer
counts. It is its own list model and filters in C++, moving only the rows a
keystroke or an answer changes, never resetting the list. Dismissing it sends
`composer.focus` to the composer. The singleton is not `Palette`, which
QtQuick already names.

The application menu's accelerators (`menuKeys()`: mod+, for settings,
mod+=, mod++, mod+- and mod+0 for zoom) are not keymap rules and not rows in
Settings → Keybindings; they resolve only after every rule, so a user's rule
for the same chord wins, as it does over Electron's menu.

`ShellWindow` instantiates one window `Shortcut` per bound sequence and calls
`Keybindings.press`. Who takes a key follows focus:

- A focused `WebSurface` or terminal keeps every key except the sequences
  that resolve, in that focus, to a native command or a project script.
  Those `Shortcut`s stay enabled, so a native command runs once and a
  terminal still gets Ctrl+K. The web's defaults bind `mod+d` to
  `terminal.split` in a terminal, so off macOS a terminal loses Ctrl+D (EOF)
  unless the user rebinds it.
- From native chrome (a focused composer included), only a sequence that
  resolves to a native command or script is a window shortcut; any other
  key stays with the focused control. No key goes to the page as
  `keybinding.press`.
- Unmodified keys are never window shortcuts; they belong to whichever
  control has focus.

Secondary documents (the right panel) forward a keydown they did not consume
as `keybinding.press` when the chord resolves to the same command with and
without the embed's focus (`shellKeybindingPressToForward`). The controller
claims that dispatch and runs the command if it is native; the primary page
never sees it.

Mod+Q is not a shortcut. `QuitController` (shared, one per process) filters
the application's key events before any window or page sees them and ports
`apps/desktop/src/window/QuitHold.ts`: `confirmQuit` "hold" (the default)
quits after 1.2 seconds held, "double-click" after two presses within half a
second, "direct" at once, and two quick presses always quit. "Still held" is
proven by auto-repeat, as in Electron. The hint is the shared `quitHint`
({message} or null) that `ShellWindow` shows; `app.quit` in the palette quits
at once. The controller only emits `quitRequested` and `concealRequested`;
`main.cpp` quits and hides the windows, and tests swap its clock with
`setClock`.

Settings → Keybindings (`KeybindingsSettings`, route
`/settings/keybindings`) lists the merged rows, records chords with
`Keybindings.recordKey`, and saves through `hal-c2.upsertKeybinding` and
`hal-c2.removeKeybinding` on the shell's own environment. The rows refresh
from the node's push, not from the reply.

### `notifications`

The `Notifications` brick renders only the shell's own `toasts`.
`ToastController` is what native controllers call (`show`, `error`,
`showActions` with up to two buttons, `replace` to update one in place), with
its own timing; its ids start with `native:`. The page's `ShellToastBridge`
still publishes its toasts as `notifications`, but nothing shows them: every
toast the desktop needs has a native producer with the web's text, such as
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
window has one `ContextMenuHost`, for `menu`. The page's own menus still
publish `contextMenu` (`localApi.contextMenu.show`, answered by
`contextMenu.select {requestId, id}`), but only a visible `WebSurface`'s
inner host renders them; the hidden main page's are never shown.
`workspace.rename {title}` / `renameRequestId` drive an inline rename in
the header; the thread menu's "Rename" asks for it with
`workspace.rename.begin {threadKey}`.

### `git`

`GitController` publishes `git` itself from `WorkspaceController`'s `vcs`
status; the page's `ShellGitBridge` no longer writes the key. The recommended
action and the menu follow `apps/tui/src/gitActions.logic.ts`, not the web's
`GitActionsControl.logic.ts`: the ledger (`source-control/git-actions.feature`)
is written against the TUI's labels and reasons, named for the host's change
requests (PR, MR). Actions: `git.quick`, `git.menu {id}`, `git.commit
{message, filePaths|null, featureBranch}`, `git.defaultBranch {choice}`,
`git.init`, `git.publish`, `git.publish.submit`, `git.publish.cancel`,
`git.refresh`.

A stacked action is one `gitAction` subscription; its stage and last hook line
update one loading toast in place, and the node's result toast (with its
next-step CTA) replaces it. The subscription is dropped, not resent, when the
connection drops, since the node would run the action twice. `gitAction`
names the environment, so a linked thread's actions run through its link. While
an environment is offline the brick publishes `available: false`, with the
link's message (`EnvironmentUnreachableError`) as the `unavailableReason` it
shows; a refused action or call carries the same message in its error toast.

### Composer layout

The `Composer` brick is the page's composer card: a centered card (768 px
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
plugin) and a macOS bundle (`macdeployqt`). `scripts/stage-runtime.mjs` stages
the host's TypeScript, the built web app (`web/`), the node release
(`hal-c2-node/`, from `mix release`) and the Node executable that runs the
host and the node's sidecars. The Linux path was
written against the documented tooling but has only been exercised in CI, not
on this machine.

## Moving off the page

The embedded page is legacy and leaves the shell piece by piece. Every piece
of the original chrome has a brick (`Sidebar`, `Composer`, `RightPanel`,
`TerminalDrawer`, `Workspace`, `SettingsNav`), but several still get their
state from the page. Some settings sections are still HTML because they have
not moved yet, not by design (see
[Settings sections](#settings-sections-and-the-shells-own-pages)); the right
panel's tabs are all native.

A piece has moved when a native controller (`src/native/`, registered with
`NativeControllerRegistrar`) builds its state from the shell's own node client
and a brick renders it; the controller claims the key,
so the page's publishes to it are dropped. The terminal drawer (native, on
qml-ghostty), the cluster settings, the route, the shell's toasts and the
theme are built this way. New features skip
the page entirely: a controller, a brick the layouts place, and `@desktop`
scenarios run by `tst_Features`. They are never hosted in or over
`WebSurface`, and never gated on state the page publishes. The embed route
behind `RightPanel` (a second `WebEngineView` on its own connection) is a
stopgap for HTML that must sit where QML decides, not a pattern for new work;
web content the desktop cannot draw opens in the user's browser instead.

### Thread store and timeline

`ThreadStore` (`Threads`) follows each open thread through the node's `stream`
shape, folded into a `TimelineModel` per thread: the active one plus a few
recently active ones stay subscribed. The fold is
`packages/client-runtime/src/v3/threadShape.ts` in C++; the rows follow the
TUI's timeline (folds of settled turns, tool call groups, markers). A thread is
addressed by its environment (`ThreadStore::streamShape`), which the node
routes to a cluster member or through a link; a stream that errors waits for
the shell to list the thread's node online again. A part-0 snapshot after a reconnect or `resync` replaces the
entities but not the rows: row ids are stable, streamed text only emits
`dataChanged` for its row, and structural changes are applied as inserts,
moves and removes, so the `Timeline` brick keeps its scroll position. The
active thread is the navigation route's.

Which routes the shell draws in the window's centre is one list,
`Bricks/js/centreViews.js`; `ShellWindow.nativeCentreOpen` and `pageOpen`
follow it, and every layout puts a `CentreHost` beside the `WebSurface` the way
it does `SettingsHost`. Thread and draft routes load `ThreadView`: the route's
timeline, a quiet loading line, the draft's opening line with its project and
checkout, and Retry (`Threads.reload`) for a thread whose node stopped sending
it. Links in a reply open in the browser or, for a path, in the right panel
(`panel.open {tab: "files", path, line?}`); a reply's changed file opens the
diff on its turn. There is one revert, `Panel.diff` (`ThreadDiff`), which
follows the route's thread whether or not the panel is open: a reply's Revert
(on the turn `TimelineModel::checkpointOf` finds for its run) and the Diff
tab's both go through `requestRevert`, and `RevertDialog` asks before
`confirmRevert` sends `checkpoint.rollback`, keeping or restoring the files.
The node marks the later runs `rolled_back` and the fold drops them. Jump to
latest is also the
`timeline.jumpToLatest` command.

What the shell still lacks next to web and mobile is tracked as Gherkin, not
prose. The repository's `features/` tree tags every scenario with the surface it
must hold on and `@backlog` where the native shell does not deliver it yet;
`features/navigation/keybindings.feature` records which web keybindings work in
the shell. Add a new gap there, and turn a backlog scenario into a real test
(`tests/tst_Scenarios.qml` for brick behavior) when the feature lands.

## Release targets

Linux AppImage and macOS `.app` first, Windows later. Release staging bundles
the build's Node executable and license beside the host runtime, and the node
release, which carries its own Erlang runtime.
