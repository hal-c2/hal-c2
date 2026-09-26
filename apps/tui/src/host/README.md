# TUI host

`createHost` is the app side of the QML shell: `store.ts` owns data and
server subscriptions, the host adds view state (mode, size, collapse) and
publishes both as `Shell.state` keys. Bricks in `apps/tui/qml` only read
keys and call `Shell.dispatch(action, payload)`.

Keys published today: `sidebar`, `layout`, `theme`, `notifications` (the
desktop shell's contract names, extended for the terminal), `mode`, `status`,
`size`, `page`, `plugins`, `problems`, `connection`.

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
environments, pairingHint }`. The TUI knows one environment, the server that
  launched it; pairing lives in the other clients, so `pairingHint` is null.

Slots the bricks expose: `statusbar` (StatusLine, `replace`, data
`{ status, title }`), `composer.actions` (ComposerActions, `append`) and
`sidebar.footer` (Sidebar, `replace`). A user `shell.qml` can change a mode:
`DefaultShell { statusLine.slotMode: "append" }`.

User config lives in the TUI config dir (`userConfig.ts`): `plugins/` is
loaded as a plugin directory, `T3_TUI_PLUGINS` adds files or directories (a
path list), and `keymap.json` overrides keymaps by action (`{"ctrl+p":
"palette.open"}` for the global keymap, `{"list": {"n": "next"}}` for a named
one, `null` unbinds). The keymaps are `globalKeymap` in DefaultShell and
`list` in Sidebar.

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
