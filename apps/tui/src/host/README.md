# TUI host

`createHost` is the app side of the QML shell: `store.ts` owns data and
server subscriptions, the host adds view state (mode, size, collapse) and
publishes both as `Shell.state` keys. Bricks in `apps/tui/qml` only read
keys and call `Shell.dispatch(action, payload)`.

Keys published today: `sidebar`, `layout`, `theme`, `notifications` (the
desktop shell's contract names, extended for the terminal), `mode`, `status`,
`size`, `page`.

`threadView.ts` publishes the open thread's keys and handles their actions:

| Key                            | Actions                                                                                                                                                                 |
| ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `timeline`, `timelineScroll`   | `timeline.showOlder`, `timeline.showNewer`, `timeline.scroll {by}`, `timeline.workGroup.toggle`, `timeline.fold.toggle`, `timeline.message.toggle`, `timeline.files.toggleDir`, `timeline.files.toggleAll`, `link.open {url}` |
| `approvals`                    | `approval.approve`, `approval.decline`, `approval.next`, `approval.previous`                                                                                            |
| `userInput`                    | `userInput.move`, `userInput.toggle`, `userInput.answer.set`, `userInput.submit`, `userInput.defer`, `userInput.reopen`                                                  |
| `threadHints`                  | `plan.implement`                                                                                                                                                        |
| `revert`                       | `checkpoint.revert.open`, `checkpoint.revert.move`, `checkpoint.revert.confirm`, `checkpoint.revert.cancel`                                                             |
| `diff`                         | `diff.open`, `diff.all`, `diff.toggleView`, `diff.next`, `diff.previous`, `diff.close`                                                                                  |
| `notifications`                | `notification.dismiss`, `notification.action` (thread alerts from `notificationsState.ts`)                                                                             |

`mode` gains `userInput` (a question waits; "compose" resolves to it), `revert`
and `diff`.

## Where the rest of ChatView's state goes

ChatView (`src/components/ChatView.tsx`) still owns the state below. Move it
here as each brick lands, keeping one key per concern:

| ChatView state                                         | Host key                    |
| ------------------------------------------------------ | --------------------------- |
| `focus` (compose, filter, command, select, ...)        | `mode`                      |
| composer text, attachments, model/runtime/interaction  | `composer`                  |
| command palette query and results                      | `palette`                   |
| select overlay, context menu, confirm dialogs          | `overlay`                   |
| right panel (git, files, diff, plan) and its tab       | `rightPanel`, `layout`      |
| terminal drawer tabs, height, attach state             | `terminal`                  |
| image preview                                          | `overlay`                   |
| settings view                                          | `page` (`kind: "settings"`) |
