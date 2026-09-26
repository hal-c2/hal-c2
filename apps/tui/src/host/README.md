# TUI host

`createHost` is the app side of the QML shell: `store.ts` owns data and
server subscriptions, the host adds view state (mode, size, collapse) and
publishes both as `Shell.state` keys. Bricks in `apps/tui/qml` only read
keys and call `Shell.dispatch(action, payload)`.

Keys published today: `sidebar`, `layout`, `theme`, `notifications` (the
desktop shell's contract names, extended for the terminal), `mode`, `status`,
`size`, `page`.

`terminal` is the thread's drawer: tabs, size and the active terminal's rows
as styled text. The host runs one headless emulator per open tab
(`terminalState.ts`), so switching tabs never replays and only the shown tab
tells the server its size. Actions are `terminal.*`; `host.commands()` lists
the palette commands that currently apply, and `host.settled()` resolves once
client calls and emulator writes have landed (tests wait on it). Copying goes
through `HostOptions.copyToClipboard` (OSC 52 in `src/index.ts`).

`files` is the workspace browser that replaces the conversation while open:
the visible window of tree rows around the selection, and `viewer` for an
opened file (a slice of its lines from `top`). Actions are `files.*`
(`filesState.ts`); stale listings and reads are dropped by generation.

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
| image preview                                          | `overlay`                   |
| toasts                                                 | `notifications`             |
| settings view                                          | `page` (`kind: "settings"`) |
