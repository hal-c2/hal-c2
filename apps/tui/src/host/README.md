# TUI host

`createHost` is the app side of the QML shell: `store.ts` owns data and
server subscriptions, the host adds view state (mode, size, collapse) and
publishes both as `Shell.state` keys. Bricks in `apps/tui/qml` only read
keys and call `Shell.dispatch(action, payload)`.

Keys published today: `sidebar`, `layout`, `theme`, `notifications` (the
desktop shell's contract names, extended for the terminal), `mode`, `status`,
`size`, `page`.

## Where the rest of ChatView's state goes

ChatView (`src/components/ChatView.tsx`) still owns the state below. Move it
here as each brick lands, keeping one key per concern:

| ChatView state                                         | Host key                    |
| ------------------------------------------------------ | --------------------------- |
| `focus` (compose, filter, command, select, ...)        | `mode`                      |
| timeline rows, working indicator, expanded work groups | `timeline`                  |
| composer text, attachments, model/runtime/interaction  | `composer`                  |
| pending approvals, pending user input answers          | `approvals`, `userInput`    |
| command palette query and results                      | `palette`                   |
| select overlay, context menu, confirm dialogs          | `overlay`                   |
| right panel (git, files, diff, plan) and its tab       | `rightPanel`, `layout`      |
| terminal drawer tabs, height, attach state             | `terminal`                  |
| image preview                                          | `overlay`                   |
| toasts                                                 | `notifications`             |
| settings view                                          | `page` (`kind: "settings"`) |
