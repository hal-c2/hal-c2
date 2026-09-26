# TUI host

`createHost` is the app side of the QML shell: `store.ts` owns data and
server subscriptions, the host adds view state (mode, size, collapse) and
publishes both as `Shell.state` keys. Bricks in `apps/tui/qml` only read
keys and call `Shell.dispatch(action, payload)`.

Keys published today: `sidebar`, `layout`, `theme`, `notifications` (the
desktop shell's contract names, extended for the terminal), `mode`, `status`,
`size`, `page`, `composer` and `select` (`composerState.ts`), `palette`
(`paletteState.ts`) and `keybindings` (`src/keymap.ts`: the chord layers per
mode, the reference groups and the web parity table).

## Keys and actions

Chords live in one place: `KEYMAP_LAYERS` in `src/keymap.ts` maps each mode's
chords to host actions, and `ShellKeymap.qml` binds only the current mode's
layer. A new chord is a layer entry plus a reference entry in
`KEYBINDING_GROUPS` (`keymap.test.ts` fails when one is missing), not a
`Shortcut` in a brick. Focused fields see plain keys first: the prompt takes
Enter (`composer.submit`) and ↑/↓ (`composer.history.*`), and hands a key on
when the host's `dispatch` returns false.

A palette command is a host action too (`buildPaletteCommands`), so running
one is the same as pressing its chord. The layers already name actions that
other areas handle: `terminal.*`, `rightPanel.*`, `diff.*`, `files.*`,
`settings.*`, `contextMenu.*`, `approval.approve` / `approval.decline`,
`plan.implement`, `userInput.reopen`, `timeline.pageUp` / `timeline.pageDown`
and `terminal.focus`. Until an area handles its actions, `dispatch` logs them
once as unknown.

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
