# HAL-C2 feature specifications

Every behaviour HAL-C2 has, will have, or has deliberately dropped is written here in Gherkin.
This tree is the ledger of what HAL-C2 does, including everything the surfaces it started from did.
Those surfaces are no longer in the tree:

| Removed                                   | Replaced by                            |
| ----------------------------------------- | -------------------------------------- |
| the Node server (`apps/server`)           | the MC (`apps/server-ex`)              |
| the Electron desktop app (`apps/desktop`) | the Qt/QML desktop (`apps/desktop-qt`) |
| the React Native app (`apps/mobile`)      | the QML mobile client                  |
| the web app (`apps/web`)                  | nothing; there is no web client        |
|                                           | the QML TUI (`apps/tui`)               |

A behaviour that is not in this tree does not exist as far as HAL-C2 is concerned.

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
| `mc/`             | the MC (hal-c2-mc) itself: protocol, auth, orchestration engine, checkpoints |
| `providers/`      | each agent provider as a plugin: install, auth, models, usage, sessions      |
| `plugins/`        | the plugin system: UI plugins, MC plugins, agent plugins                     |
| `mobile/`         | behaviour that only exists on phones and tablets                             |
| `desktop/`        | behaviour that only exists in the desktop client                             |
| `tui/`            | behaviour that only exists in the terminal client                            |
| `parity/`         | scenario outlines generated from contracts: RPC methods, commands, protocol  |

## Tags

Surface tags say where a scenario must hold. A scenario carries every surface it applies to.

- `@mc` runs against an MC with no client.
- `@desktop` runs against the QML desktop client.
- `@mobile` runs against the QML mobile client.
- `@tui` runs against the terminal client rendered by opentui-qml.
- `@shared` is shorthand for `@desktop @mobile @tui` and means the QML is shared between them.

Status tags say whether the HAL-C2 stack delivers the scenario today. The HAL-C2 stack is the
MC, native QML, and the TUI.

- No status tag means the scenario passes on every one of its surfaces now.
- `@backlog` means it passes on none of its surfaces yet: a removed surface did this and it
  is not carried over, or it is new intended behaviour. This is the list of things we
  must not lose.
- `@backlog-mc`, `@backlog-desktop`, `@backlog-mobile` and `@backlog-tui` mean it does not
  pass on that one surface yet. When a `@backlog @desktop @mobile` scenario starts passing on
  the desktop it becomes `@desktop @mobile @backlog-mobile`; `@shared @backlog-mobile
@backlog-tui` passes only on the desktop. Each runner treats its own surface's tag like
  `@backlog`.
- `@dropped` means we decided not to carry the behaviour. The scenario stays so the decision
  is visible and reviewable.
- `@blocked` goes beside a backlog tag on work that cannot start yet. A comment above it
  names what it waits for: a question the maintainers have to answer, or another scenario
  that has to land first. Remove the tag once that is settled.

Tags on a `Feature`, `Rule` or `Examples` table apply to everything under it.

`@plugin-<id>` marks behaviour a plugin provides, for example `@plugin-claude`. The core must
work with that plugin absent.

`@priority-high` and `@priority-low` weight a backlog scenario for `mise run features:pick`,
which picks random backlog scenarios to work on. Low priority still comes up, just less often.
It takes a count, `@tag`s to require, `-@tag`s to exclude, and files or globs under `features/`:
`mise run features:pick 8 @mc -@plugin-antigravity 'providers/**'`. Requiring a surface keeps
only work still missing on it, so `@desktop` draws `@backlog` and `@backlog-desktop` scenarios.
`@blocked` work is left out; `mise run features:pick 20 @blocked` lists it with what each
scenario waits for.

## Writing rules

- Declarative, in the user's words. "When the user snoozes the thread until tomorrow", not
  "When the user clicks the snooze button". Never name widgets, icons, or layout.
- One behaviour per scenario. Each scenario stands alone; a `Background` carries shared setup.
- Tables of the same behaviour use `Scenario Outline` with `Examples`, never copy-pasted scenarios.
- Reverse states are scenarios too. Snooze has unsnooze. Open has close. Pair has revoke.
- Failure and offline paths are scenarios. An MC that is unreachable, a provider that is not
  installed, a file that no longer exists.
- Every file starts with a comment block naming the sources it was derived from, so the ledger
  can be audited:

  ```gherkin
  # Sources:
  #   docs/user/thread-sidebar.md
  #   apps/web/src/components/Sidebar.tsx
  #   packages/contracts/src/orchestrationV2.ts (thread.snooze, thread.unsnooze)
  ```

  `# Sources:` lines that name `apps/server`, `apps/web`, `apps/desktop` or `apps/mobile` name files
  that are no longer in the tree. They are provenance, readable at commit `8212e08f9`
  (`git show 8212e08f9:<path>`).

## Ledger rule

Each of these must be named in at least one `# Sources:` block:

- every page under `docs/user/`
- every settings panel of the removed web app (`apps/web/src/components/settings/*Settings.tsx` at `8212e08f9`)
- every RPC method in `packages/contracts/src/rpc.ts` (see `parity/rpc.feature`)
- every command and event in `packages/contracts/src/orchestrationV2.ts` (see `parity/commands.feature`)
- every keybinding id in `packages/contracts/src/keybindings.ts` (see `navigation/keybindings.feature`)
- every command palette entry

## Upstream

T3 Code keeps shipping, and its behaviour is ledgered here even though its code is not carried.
`features/UPSTREAM` is the upstream commit the ledger has been reviewed through, and
`mise run upstream` digests the pull requests merged after it. The
[upstream-ledger skill](../.agents/skills/upstream-ledger/SKILL.md) turns them into scenarios.

## Running

The mise tasks in `mise-tasks/` are the way to run them (`mise tasks ls`); globs are relative to
`features/`. On the MC and the TUI, `@backlog` scenarios, and those tagged `@backlog-mc` or
`@backlog-tui` respectively, run only with `--backlog` or `INCLUDE_BACKLOG=1`, and are expected
to fail there.

| Surface    | Task                                                      | Raw command                                                                                  |
| ---------- | --------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| MC         | `mise run features:mc <globs>`, `features:mc:all`         | `mix features [--backlog] <globs>` in `apps/server-ex`                                       |
| TUI        | `mise run features:tui <globs>`, `features:tui:all`       | `TUI_FEATURES="<globs>" [TUI_INCLUDE_BACKLOG=1] bun test ./features/runner.ts` in `apps/tui` |
| Qt desktop | `mise run features:desktop` (`:qml` and `:native` halves) | `vp run --filter @hal-c2/desktop-qt test:qml`, ctest per `apps/desktop-qt/README.md`         |
| QML phone  | `mise run features:mobile [--backlog] [globs]`            | `[HAL_C2_FEATURES="<globs>"] [HAL_C2_BACKLOG=1]` ctest per `apps/mobile-qt/README.md`        |

MC globs are required; `features:mc:all` runs the suite one top-level directory at a time,
because one run of everything is slow. `features:tui:all` runs every file with a `@tui` or
`@shared` scenario. On the desktop, the native tests' `tst_Features` runs the `@desktop` scenarios
of `desktop/native-*.feature` and the desktop-passing `@shared` timeline scenarios against a fake MC (`HAL_C2_FEATURES="<globs>"` picks other files);
`apps/desktop-qt/tests/tst_Scenarios.qml` still mirrors the `qt-scenarios.feature` files by hand. On the phone, the tests' `tst_Features`
runs the `@mobile` and `@shared` scenarios of the `mobile/` files it lists against the same fake MC, tapping and typing into the phone's real
root; like the desktop's it leaves out `@backlog` and its own surface's `@backlog-mobile`, and `--backlog` runs only those instead.
`mise run features` runs all four and reports each. Step definitions live in `apps/server-ex/test/steps/`, `apps/tui/features/`,
`apps/desktop-qt/tests/native/features/` and `apps/mobile-qt/tests/features/`.
