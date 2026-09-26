# TUI host

`createHost` is the app side of the QML shell: `store.ts` owns data and
server subscriptions, the host adds view state (mode, size, collapse) and
publishes both as `Shell.state` keys. Bricks in `apps/tui/qml` only read
keys and call `Shell.dispatch(action, payload)`.

Keys published today: `sidebar`, `layout`, `theme`, `notifications`,
`rightPanel` (the desktop shell's contract names, extended for the terminal),
`mode`, `status`, `size`, `page`, `git`, `diff`, `settings`.

Source control, diffs and settings (`sourceControl.ts`, `settingsState.ts`):

| Action                                                             | Payload                      |
| ------------------------------------------------------------------ | ---------------------------- |
| `rightPanel.toggle`, `.open`, `.close`, `.focus`, `.blur`          |                              |
| `git.next`, `git.previous`                                         |                              |
| `git.select`, `git.activate`                                       | `{ index }`                  |
| `git.run`                                                          | `{ action, label? }`         |
| `git.pull`, `git.openPr` (copies the PR link), `git.commit.cancel` |                              |
| `git.commit`                                                       | `{ message }`                |
| `diff.open`                                                        | `{ turnCount? }` (all: none) |
| `diff.next`, `diff.previous`, `diff.toggleView`, `diff.close`      |                              |
| `settings.open`, `settings.close`                                  |                              |

`detailCommands.ts` lists the palette entries for these ("View all changes",
"Show/Hide source-control panel", "Settings").

## Where the rest of ChatView's state goes

ChatView (`src/components/ChatView.tsx`) still owns the state below. Move it
here as each brick lands, keeping one key per concern:

| ChatView state                                         | Host key                 |
| ------------------------------------------------------ | ------------------------ |
| `focus` (compose, filter, command, select, ...)        | `mode`                   |
| timeline rows, working indicator, expanded work groups | `timeline`               |
| composer text, attachments, model/runtime/interaction  | `composer`               |
| pending approvals, pending user input answers          | `approvals`, `userInput` |
| command palette query and results                      | `palette`                |
| select overlay, context menu, confirm dialogs          | `overlay`                |
| right panel files and plan surfaces                    | `rightPanel`, `layout`   |
| terminal drawer tabs, height, attach state             | `terminal`               |
| image preview                                          | `overlay`                |
| toasts                                                 | `notifications`          |
