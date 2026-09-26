# TUI host

`createHost` is the app side of the QML shell: `store.ts` owns data and
server subscriptions, the host adds view state (mode, size, collapse) and
publishes both as `Shell.state` keys. Bricks in `apps/tui/qml` only read
keys and call `Shell.dispatch(action, payload)`.

Keys published today: `sidebar`, `layout`, `theme`, `notifications` (the
desktop shell's contract names, extended for the terminal), `mode`, `status`,
`size`, `page`, `contextMenu`, `overlay`, `composer`, `select` and
`newThread` (`composerState.ts`), `palette` (`paletteState.ts`), `clock`,
`git`, `settings`, `paneScroll`, `terminal`, `files`, `addProject`,
`keybindings` (`src/keymap.ts`: the chord layers per mode, the reference
groups and the web parity table), `plugins`, `problems`, `connection` (see
"Plugins, problems and connection"), `graphics`, and the open thread's keys
from `threadView.ts` (below).

- `sidebar` adds each row's painted `lines` (an active thread is a four-line
  card, as in the OpenTUI client), the list viewport (`lines`, `listRows`,
  `scrollTop`, counted in lines; `sidebar.scroll` moves it without following
  the selection), `scopeLabel`/`scopeLine` for the project row, and a `draft`
  row while a new-thread draft is open. Section rows toggle their shelf; the
  "more" row pages the settled shelf.
- `layout` adds the extension slots a shell fills: `rightPanel`
  (`visible`, `focused`, `kind`, `asMain`, `width`;
  `ShellWindow.rightPanelComponent`, which loads only while visible)
  and `drawer` (`open`, `rows`; `ShellWindow.drawerComponent`), plus the
  capped content column (`contentWidth`, `contentOffset`) and the prompt's
  `editorRows` / `popoverRows`.
- `page` has `kind: "draft"` while a new-thread draft with a project is open.
- `contextMenu` (null when closed): the thread menu's `threadKey`, position,
  size, `rows` (items and separators) and highlighted index. Opening it never
  changes which thread is open.
- `graphics.inlineImages`: the host's one inline-image decision, fixed at
  start (`HostOptions.inlineImages`, from `detectInlineImageTransport` in
  `src/terminalGraphics.ts`). `"direct"` for a terminal known to draw Kitty
  graphics (Ghostty, Kitty, WezTerm, Konsole), `"tmux"` inside tmux when tmux's
  global environment names such a terminal (drawn through passthrough), null
  otherwise. There is no probing: an unknown terminal gets no previews, only
  the attachment's label and link line. Only when it is set does the timeline
  load previews (`attachmentPreviews.ts`) and add image lines.
- `overlay` (null when closed): `rename` or `confirmDelete` for a thread.
- `palette`: `open`, `query`, the filtered `commands`, highlighted `index`.
- `composer`: the prompt of the open thread or the new-thread draft (text,
  attachments, model, effort, modes, `rows`); `select` is its one open picker.
- `newThread` (null when closed): the draft's project, workspace mode,
  branch, worktree, refs and `pending`. Its first message is the composer's
  text; `composer.submit` starts the thread.
- `paneScroll` (`{pane, seq, by}`): PgUp/PgDn for a pane that scrolls itself
  (`settings`, `diff`); the brick scrolls when `seq` changes.
- `clock.refreshInMs`: when the list next needs a redraw (a minute, or the
  next snooze wake); `ShellWindow` dispatches `clock.tick` then.

Actions, by area (payloads use `key` / `projectKey` from `sidebarState.ts`):

| Area        | Actions                                                                                                                                                                                                                                         |
| ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Thread list | `thread.open`, `thread.next`, `thread.previous`, `thread.jump {index}`, `sidebar.toggle`, `sidebar.filter.focus/set/commit/cancel`, `sidebar.list.focus/blur`, `sidebar.section.toggle {section}`, `sidebar.more`, `sidebar.scope {projectKey}` |
| Thread rows | `thread.menu {key, x, y}`, `thread.rename {key, title?}`, `thread.archive`, `thread.unarchive`, `thread.delete` (asks), `thread.delete.confirm`, `thread.settle`, `thread.unsettle`, `thread.copy {key, what}`, `thread.stop`                   |
| Menus       | `contextMenu.move {delta}`, `contextMenu.select {index?}`, `overlay.cancel`, `palette.open/close/query.set/next/previous/run {index? id?}`                                                                                                      |
| Composer    | `composer.text.set {text}`, `composer.submit`, `composer.escape`, `composer.paste`, `composer.history.previous/next`, `composer.grow/shrink`, `composer.*Picker.toggle`, `composer.editor.open`, `select.*`, `composer.focus`                   |
| New thread  | `thread.new {projectKey?}`, `newThread.workspaceMode {mode}`, `newThread.branch {name}`, `newThread.submit {message?}`, `newThread.cancel`                                                                                                      |
| Layout      | `rightPanel.toggle/open {kind?}`, `rightPanel.focus/blur/close`, `terminal.*` (below), `layout.popover {rows}`, `clock.tick`, `app.quit` (or `quit`)                                                                                            |
| Plugins     | `plugins.refresh`, `plugin.remove {id}`, `plugin.load {file}`                                                                                                                                                                                   |

The palette (`paletteState.ts`) lists the composer's commands (new thread,
plan mode, workspace, model, effort, access, editor, "Implement plan"), then
"Show project <name>" / "Show all projects" (`sidebar.scope`), the selected
thread's actions, and `detailCommands.ts`
("View all changes", "Revert to checkpoint…", "Show/Hide source-control
panel", "Settings"), then the entries of the files, add-project and terminal
controllers below ("Browse files", "Add project", "Show/Hide terminal", ...).

The source-control panel is the `rightPanel` kind `"sourceControl"`
(`RightPanel.qml`). `sourceControl.ts` publishes `git` and handles, with the
panel focused (`mode: "panel"`, or `"commit"` while a commit message is asked
for): `git.next`, `git.previous`, `git.select {index}`, `git.activate
{index?}`, `git.run {action, label?}`, `git.pull`, `git.openPr` (copies the PR
link), `git.commit {message}`, `git.commit.cancel`. `settings`
(`settingsState.ts`) is the read-only settings page in place of the
conversation: `settings.open`, `settings.close` (`mode: "settings"`).

`threadView.ts` publishes the open thread's keys and handles their actions
(the timeline wraps at `layout.contentWidth`):

| Key                          | Actions                                                                                                                                                                                                                       |
| ---------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `timeline`, `timelineScroll` | `timeline.showOlder`, `timeline.showNewer`, `timeline.scroll {by}`, `timeline.workGroup.toggle`, `timeline.fold.toggle`, `timeline.message.toggle`, `timeline.files.toggleDir`, `timeline.files.toggleAll`, `link.open {url}` |
| `imageViewer`                | `image.open {id}`, `image.close` (`mode: "imagePreview"`)                                                                                                                                                                     |
| `approvals`                  | `approval.approve`, `approval.decline`, `approval.next`, `approval.previous`                                                                                                                                                  |
| `userInput`                  | `userInput.move`, `userInput.toggle`, `userInput.answer.set`, `userInput.submit`, `userInput.defer`, `userInput.reopen`                                                                                                       |
| `threadHints`                | `plan.implement`                                                                                                                                                                                                              |
| `revert`                     | `checkpoint.revert.open`, `checkpoint.revert.move`, `checkpoint.revert.confirm`, `checkpoint.revert.cancel`                                                                                                                   |
| `diff`                       | `diff.open`, `diff.all`, `diff.toggleView`, `diff.next`, `diff.previous`, `diff.close`                                                                                                                                        |
| `notifications`              | `notification.dismiss`, `notification.action` (thread alerts from `notificationsState.ts`)                                                                                                                                    |

A timeline line with `image` is an attachment preview (`columns` × `rows`
cells, encoded `source`); its link line reads the URL, "resolving link…" or
"link unavailable". Previews that failed (network error, over the byte limit)
and unavailable links are retried when the thread is shown again.
`imageViewer` (null when closed) is one preview fitted inside the terminal
with its aspect kept; the timeline stays mounted under it, so closing returns
to the same scroll position.

`mode` gains `userInput` (a question waits; "compose" resolves to it), `revert`,
`diff`, `imagePreview`, and `list` (the thread list has the keys: `sidebar.list.focus`, left
with Esc or `sidebar.list.blur`; no chord enters it yet). `diff.open {turnCount?, path?}` opens one turn (all changes
without one); the timeline's changed-file rows and the palette open it.

`terminal` is the selected thread's drawer, painted in the `layout.drawer`
slot: tabs, size and the active terminal's rows as styled text. The drawer's
open state and the height the user asked for feed the layout, which clamps the
rows; the emulator is sized from `layout.drawer.rows` and `layout.mainWidth`.
The host runs one headless emulator per open tab (`terminalState.ts`), so
switching tabs never replays and only the shown tab tells the server its size.
Focusing it is `mode: "terminal"`, where Ctrl+C goes to the program. Actions:
`terminal.toggle/open/focus.toggle/new/next/previous/select {id}/close {id?}/clear/restart/copy`,
`terminal.input {data}`, `terminal.paste {text}`, `terminal.scroll {action}`,
`terminal.resize {height}` or `{delta}`. `host.settled()` resolves once
client calls and emulator writes have landed (tests wait on it). Copying goes
through `HostOptions.copyToClipboard` (OSC 52 in `src/index.ts`).

`files` is the workspace browser, the `rightPanel` kind `"files"`
(`FilesPanel.qml`, or `FileViewer.qml` while `viewer` is set): the visible
window of tree rows around the selection, and `viewer` for an opened file (a
slice of its lines from `top`). It opens focused (`mode: "files"`); another
panel kind or another thread closes it. Actions are `files.*`
(`filesState.ts`); stale listings and reads are dropped by generation.

`addProject` is the add-project flow (`addProjectState.ts`): source, then a
local folder or a repository and its clone destination, with the folders
under the typed path. `invite` is true while the environment has no
projects. Actions are `project.add` and `project.add.*` (`mode: "project"`).
An added project opens a new-thread draft for it (`thread.new {projectKey}`).

## Keys and actions

Chords live in one place: `KEYMAP_LAYERS` in `src/keymap.ts` maps each mode's
chords to host actions, and `ShellKeymap.qml` binds only the current mode's
layer. A new chord is a layer entry plus a reference entry in
`KEYBINDING_GROUPS` (`keymap.test.ts` fails when one is missing), not a
`Shortcut` in a brick. Keymap chords run before the focused field; an action
that does not apply right now (↑/↓ without two approvals or with text in the
prompt, ^A with nothing to approve, ^P with the terminal hidden) returns false
from `dispatch`, and the key reaches the field (the prompt's ↑/↓ then recall
earlier prompts through `composer.history.*`).

Some layer actions are aliases the host resolves (`handleAlias` in
`host.ts`): `thread.jump.N`, `timeline.pageUp/pageDown`, `terminal.focus`,
`terminal.grow/shrink`, `terminal.scroll.*`, `contextMenu.previous/next/run/close`,
`files.previous/next/scrollUp/scrollDown`, `rightPanel.previous/next/activate`,
`userInput.previous/next`, `checkpoint.revert.previous/next`,
`project.add.previous/next`, `settings.scrollUp/scrollDown` and
`diff.scrollUp/scrollDown`. A palette command is a host action too, so running
one is the same as pressing its chord.

The mode keymaps are unnamed, so a top-level entry in the user's
`keymap.json` reaches every mode (`{"ctrl+p": "palette.open"}`,
`{"ctrl+n": null}` unbinds). The thread list's keymap is named `list` (live
only in mode `list`, actions `next`/`previous`/`leave`) and takes the file's
`"list"` section, so its single-letter keys never fire while something else
has the keys. The global layer names Ctrl+C `quit`, the action a keymap file
uses; the host runs it as `app.quit`. Plugins can ship their own `Keymap`s;
a higher `priority` wins a chord the shell binds.

## Plugins, problems and connection

- `plugins` lists what the QML engine registered (`{ items: [{ id, kind:
"qml" | "script", file, order }] }`). The entry attaches the engine with
  `attachPlugins(enginePluginPort(engine))`; actions `plugins.refresh`,
  `plugin.remove { id }` and `plugin.load { file }` go through that port.
- `problems` holds what the runtime reported through `onError`/`onWarning`
  (plugin load, setup and render failures, bad keymap entries, missing plugin
  directories), capped at 50. The runtime never throws for a plugin, so this is
  the only place a failure shows.
- `connection` is `{ state: "connecting" | "connected" | "reconnecting",
environments, pairingHint }`, from the client's connection phase
  (`TuiClient.subscribeConnection`, `connectionPhases()` in `connection.ts`).
  The TUI knows one environment, the server that launched it; pairing lives in
  the other clients, so `pairingHint` is null.

Slots the bricks expose: `statusbar` (StatusLine, `replace`, data
`{ status, title }`), `composer.actions` (ComposerFooter, around the model,
effort, mode and access controls, `append`) and `sidebar.footer` (Sidebar,
`replace`). A user `shell.qml` can change a mode:
`DefaultShell { statusLine.slotMode: "append" }`, `composer.actionsMode`,
`sidebar.footerMode`.

User config lives in the TUI config dir (`userConfig.ts`), read before the
terminal is taken over so a `keymap.json` that is not valid JSON stops the
launch with a readable error: `plugins/` is loaded as a plugin directory,
`HAL_C2_TUI_PLUGINS` adds files or directories (a path list), and `keymap.json`
overrides keymaps (see "Keys and actions").

## Where the rest of ChatView's state goes

ChatView (`src/components/ChatView.tsx`) still owns the state below. Move it
here as each brick lands, keeping one key per concern:

| ChatView state                                        | Host key   |
| ----------------------------------------------------- | ---------- |
| `focus` (compose, filter, command, select, ...)       | `mode`     |
| composer text, attachments, model/runtime/interaction | `composer` |
| select overlay                                        | `overlay`  |
| right panel plan surface                              | `layout`   |
| image preview                                         | `overlay`  |
