# TUI host

`createHost` is the app side of the QML shell: `store.ts` owns data and
server subscriptions, the host adds view state (mode, size, collapse) and
publishes both as `Shell.state` keys. Bricks in `apps/tui/qml` only read
keys and call `Shell.dispatch(action, payload)`.

Keys published today: `sidebar`, `layout`, `theme`, `notifications` (the
desktop shell's contract names, extended for the terminal), `mode`, `status`,
`size`, `page`, `contextMenu`, `overlay`, `palette`, `newThread`, `clock`,
`git`, `settings`, `terminal`, `files`, `addProject`, and the open thread's
keys from `threadView.ts` (below).

- `sidebar` adds the list viewport (`visibleRows`, `scrollTop`,
  `hiddenAbove`/`hiddenBelow`), `scopeLabel`, and a `draft` row while the
  new-thread form is open. Section rows toggle their shelf; the "more" row
  pages the settled shelf.
- `layout` adds the extension slots a shell fills: `rightPanel`
  (`visible`, `focused`, `kind`, `asMain`, `width`;
  `ShellWindow.rightPanelComponent`, which loads only while visible)
  and `drawer` (`open`, `rows`; `ShellWindow.drawerComponent`), plus the
  capped content column (`contentWidth`, `contentOffset`) and the prompt's
  `editorRows` / `popoverRows`.
- `page` has `kind: "draft"` while the new-thread form is open.
- `contextMenu` (null when closed): the thread menu's `threadKey`, position,
  size, `rows` (items and separators) and highlighted index.
- `overlay` (null when closed): `rename` or `confirmDelete` for a thread.
- `palette`: `open`, `query`, ranked `items`, highlighted index.
- `newThread` (null when closed): the form's project, workspace mode,
  branch, worktree, refs and `pending`.
- `clock.refreshInMs`: when the list next needs a redraw (a minute, or the
  next snooze wake); `ShellWindow` dispatches `clock.tick` then.

Actions, by area (payloads use `key` / `projectKey` from `sidebarState.ts`):

| Area        | Actions                                                                                                                                                                                                                       |
| ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Thread list | `thread.open`, `thread.next`, `thread.previous`, `thread.jump {index}`, `sidebar.toggle`, `sidebar.filter.focus/set/commit/cancel`, `sidebar.section.toggle {section}`, `sidebar.more`, `sidebar.scope {projectKey}`          |
| Thread rows | `thread.menu {key, x, y}`, `thread.rename {key, title?}`, `thread.archive`, `thread.unarchive`, `thread.delete` (asks), `thread.delete.confirm`, `thread.settle`, `thread.unsettle`, `thread.copy {key, what}`, `thread.stop` |
| Menus       | `contextMenu.move {delta}`, `contextMenu.select {index?}`, `overlay.cancel`, `palette.open/close/query/move/run`                                                                                                              |
| New thread  | `thread.new {projectKey?}`, `newThread.workspaceMode {mode}`, `newThread.branch {name}`, `newThread.submit {message}`, `newThread.cancel`                                                                                     |
| Layout      | `rightPanel.toggle/open {kind?}`, `rightPanel.focus/blur/close`, `terminal.*` (below), `composer.text.set {text}`, `layout.popover {rows}`, `clock.tick`, `app.quit`                                                          |

The palette also lists "Show project <name>" / "Show all projects"
(`sidebar.scope`), the selected thread's actions, and `detailCommands.ts`
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
| `approvals`                  | `approval.approve`, `approval.decline`, `approval.next`, `approval.previous`                                                                                                                                                  |
| `userInput`                  | `userInput.move`, `userInput.toggle`, `userInput.answer.set`, `userInput.submit`, `userInput.defer`, `userInput.reopen`                                                                                                       |
| `threadHints`                | `plan.implement`                                                                                                                                                                                                              |
| `revert`                     | `checkpoint.revert.open`, `checkpoint.revert.move`, `checkpoint.revert.confirm`, `checkpoint.revert.cancel`                                                                                                                   |
| `diff`                       | `diff.open`, `diff.all`, `diff.toggleView`, `diff.next`, `diff.previous`, `diff.close`                                                                                                                                        |
| `notifications`              | `notification.dismiss`, `notification.action` (thread alerts from `notificationsState.ts`)                                                                                                                                    |

`mode` gains `userInput` (a question waits; "compose" resolves to it), `revert`
and `diff`. `diff.open {turnCount?, path?}` opens one turn (all changes
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
An added project opens the new-thread form for it (`thread.new {projectKey}`).

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
