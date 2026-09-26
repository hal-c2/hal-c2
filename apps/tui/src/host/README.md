# TUI host

`createHost` is the app side of the QML shell: `store.ts` owns data and
server subscriptions, the host adds view state (mode, size, collapse) and
publishes both as `Shell.state` keys. Bricks in `apps/tui/qml` only read
keys and call `Shell.dispatch(action, payload)`.

Keys published today: `sidebar`, `layout`, `theme`, `notifications` (the
desktop shell's contract names, extended for the terminal), `mode`, `status`,
`size`, `page`, `contextMenu`, `overlay`, `palette`, `newThread`, `clock`.

- `sidebar` adds the list viewport (`visibleRows`, `scrollTop`,
  `hiddenAbove`/`hiddenBelow`), `scopeLabel`, and a `draft` row while the
  new-thread form is open. Section rows toggle their shelf; the "more" row
  pages the settled shelf.
- `layout` adds the extension slots a shell fills: `rightPanel`
  (`visible`, `kind`, `asMain`, `width`; `ShellWindow.rightPanelComponent`)
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
| Layout      | `rightPanel.toggle {kind?}`, `rightPanel.close`, `terminal.toggle`, `terminal.resize {height}`, `composer.text.set {text}`, `layout.popover {rows}`, `clock.tick`, `app.quit`                                                 |

The palette also lists "Show project <name>" / "Show all projects"
(`sidebar.scope`) and the selected thread's actions.

## Where the rest of ChatView's state goes

ChatView (`src/components/ChatView.tsx`) still owns the state below. Move it
here as each brick lands, keeping one key per concern:

| ChatView state                                         | Host key                    |
| ------------------------------------------------------ | --------------------------- |
| `focus` (compose, filter, command, select, ...)        | `mode`                      |
| timeline rows, working indicator, expanded work groups | `timeline`                  |
| composer text, attachments, model/runtime/interaction  | `composer`                  |
| pending approvals, pending user input answers          | `approvals`, `userInput`    |
| select overlay                                         | `overlay`                   |
| right panel (git, files, diff, plan) and its tab       | `rightPanel`, `layout`      |
| terminal drawer tabs, height, attach state             | `terminal`                  |
| image preview                                          | `overlay`                   |
| toasts                                                 | `notifications`             |
| settings view                                          | `page` (`kind: "settings"`) |
