# HAL-C2 feature specifications

Every behaviour HAL-C2 has, will have, or has deliberately dropped is written here in Gherkin.
This tree is the feature-loss ledger for the move from the legacy surfaces to the HAL-C2 stack:

| Legacy, to be deleted                     | Replaced by                            |
| ----------------------------------------- | -------------------------------------- |
| the Node server (`apps/server`)           | the Elixir node (`apps/server-ex`)     |
| the Electron desktop app (`apps/desktop`) | the Qt/QML desktop (`apps/desktop-qt`) |
| the React Native app (`apps/mobile`)      | the QML mobile client                  |
| the web app (`apps/web`)                  | nothing; there is no web client        |
|                                           | the QML TUI (`apps/tui`)               |

A legacy surface can be deleted once every scenario it served passes on its replacement. A
behaviour that is not in this tree does not exist as far as the move is concerned.

## Layout

One directory per product domain, not per surface. Surfaces are tags.

| Directory         | Covers                                                                       |
| ----------------- | ---------------------------------------------------------------------------- |
| `threads/`        | thread list and lifecycle: create, fork, pin, snooze, archive, search, moves |
| `composer/`       | writing a turn: text, attachments, context references, editors, voice        |
| `timeline/`       | reading a thread: messages, tool calls, approvals, plans, activity, alerts   |
| `navigation/`     | palette, keybindings, focus, welcome wizard, appearance, layout              |
| `source-control/` | git status, refs, worktrees, review, pull requests and stacks, Snap Shot     |
| `terminal/`       | terminal sessions, tabs, restart, graphics                                   |
| `preview/`        | in-app preview surfaces                                                      |
| `files/`          | project files, explorer, folder operations, project scripts and actions      |
| `settings/`       | every settings panel, scopes and inheritance, storage, diagnostics, updates  |
| `connections/`    | pairing, devices, remote access, HAL-C2 Connect, clustering                  |
| `node/`           | the Elixir node itself: protocol, auth, orchestration engine, checkpoints    |
| `providers/`      | each agent provider as a plugin: install, auth, models, usage, sessions      |
| `plugins/`        | the plugin system: UI plugins, node plugins, agent plugins                   |
| `mobile/`         | behaviour that only exists on phones and tablets                             |
| `tui/`            | behaviour that only exists in the terminal client                            |
| `parity/`         | scenario outlines generated from contracts: RPC methods, commands, protocol  |

## Tags

Surface tags say where a scenario must hold. A scenario carries every surface it applies to.

- `@node` runs against a node with no client.
- `@desktop` runs against the QML desktop client.
- `@mobile` runs against the QML mobile client.
- `@tui` runs against the terminal client rendered by opentui-qml.
- `@shared` is shorthand for `@desktop @mobile @tui` and means the QML is shared between them.

Status tags say whether the HAL-C2 stack delivers the scenario today. The HAL-C2 stack is the
Elixir node, native QML, and the TUI. Anything served by `apps/server`, `apps/web` or
`apps/mobile` does not count.

- No status tag means the scenario passes on the HAL-C2 stack now.
- `@backlog` means the product does this today through code that is going away, or it is new
  intended behaviour. This is the list of things we must not lose.
- `@dropped` means we decided not to carry the behaviour. The scenario stays so the decision
  is visible and reviewable.

`@plugin-<id>` marks behaviour a plugin provides, for example `@plugin-claude`. The core must
work with that plugin absent.

## Writing rules

- Declarative, in the user's words. "When the user snoozes the thread until tomorrow", not
  "When the user clicks the snooze button". Never name widgets, icons, or layout.
- One behaviour per scenario. Each scenario stands alone; a `Background` carries shared setup.
- Tables of the same behaviour use `Scenario Outline` with `Examples`, never copy-pasted scenarios.
- Reverse states are scenarios too. Snooze has unsnooze. Open has close. Pair has revoke.
- Failure and offline paths are scenarios. A node that is unreachable, a provider that is not
  installed, a file that no longer exists.
- Every file starts with a comment block naming the sources it was derived from, so the ledger
  can be audited:

  ```gherkin
  # Sources:
  #   docs/user/thread-sidebar.md
  #   apps/web/src/components/Sidebar.tsx
  #   packages/contracts/src/orchestrationV2.ts (thread.snooze, thread.unsnooze)
  ```

## Ledger rule

Each of these must be named in at least one `# Sources:` block:

- every page under `docs/user/`
- every settings panel in `apps/web/src/components/settings/*Settings.tsx`
- every RPC method in `packages/contracts/src/rpc.ts` (see `parity/rpc.feature`)
- every command and event in `packages/contracts/src/orchestrationV2.ts` (see `parity/commands.feature`)
- every keybinding id in `packages/contracts/src/keybindings.ts` (see `navigation/keybindings.feature`)
- every command palette entry

## Running

The mise tasks in `mise-tasks/` are the way to run them (`mise tasks ls`); globs are relative to
`features/`. On the TUI, `@backlog` scenarios run only with `--backlog` or `INCLUDE_BACKLOG=1`. On
the node they always run (`mix features` is `mix test --only cucumber`, whose include beats the
backlog exclude), so backlog scenarios failing there is expected.

| Surface    | Task                                                      | Raw command                                                                                  |
| ---------- | --------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| node       | `mise run features:node <globs>`, `features:node:all`     | `mix features <globs>` in `apps/server-ex`                                                   |
| TUI        | `mise run features:tui <globs>`, `features:tui:all`       | `TUI_FEATURES="<globs>" [TUI_INCLUDE_BACKLOG=1] bun test ./features/runner.ts` in `apps/tui` |
| Qt desktop | `mise run features:desktop` (`:qml` and `:native` halves) | `vp run --filter @hal-c2/desktop-qt test:qml`, ctest per `apps/desktop-qt/README.md`         |

Node globs are required; `features:node:all` runs the suite one top-level directory at a time,
because one run of everything is slow. `features:tui:all` runs every file with a `@tui` or
`@shared` scenario. The desktop has no Gherkin runner yet: `apps/desktop-qt/tests/tst_Scenarios.qml`
mirrors the `qt-scenarios.feature` files by hand. `mise run features` runs all three and reports
each. Step definitions live in `apps/server-ex/test/steps/` and `apps/tui/features/`.
