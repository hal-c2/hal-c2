# HAL-C2

HAL-C2 is a minimal GUI for coding agents. It is a fork of [T3 Code](https://github.com/pingdotgg/t3code) (upstream `pingdotgg/t3code`), maintained at `hal-c2/hal-c2`. A server wraps provider CLIs and agents (Codex, Claude Code, Cursor, Grok, OpenCode, Antigravity) and serves desktop, mobile, and terminal clients.

## What the fork adds

HAL-C2 is:

- **The MC** (`hal-c2-mc`, mission control): an Elixir/OTP server in `apps/server-ex`. Each machine runs one MC; MCs cluster and share one sidebar. Clients pair with it like any other environment.
- **Qt/QML desktop** in `apps/desktop-qt`.
- **QML mobile** in `apps/mobile-qt`, the phone and tablet client, built from the same QML as the desktop. Android first.
- **QML TUI** in `apps/tui`, rendered by opentui-qml.
- **No web client.** There is no hosted web app and no locally served one.
- **Threads move between machines**, including the agent's own session, so work started on one MC continues on another. Specified under `features/threads/`.
- **Gherkin as the ledger.** Every behaviour HAL-C2 has, will have, or dropped is a scenario under `features/`, including what the clients and server HAL-C2 started from did (`@backlog` until the MC and the QML and TUI clients carry it). Read `features/README.md` before touching behaviour: one directory per domain, surfaces are tags (`@mc`, `@desktop`, `@mobile`, `@tui`, `@shared`), status is `@backlog`, a per-surface `@backlog-<surface>`, or `@dropped` (no tag means it passes on all its surfaces today), and `@plugin-<id>` marks plugin behaviour. Every file names its sources in a `# Sources:` comment. Run MC scenarios with `mise exec -- mix features <globs relative to features/>` in `apps/server-ex`, never without globs.

## What we keep from upstream

The values are upstream's, and we owe T3 Code and its maintainers the product this fork stands on.

- **Open.** The code and the reasoning are public.
- **Performance.** Audit for regressions: too much data over websockets, CSS animations spiking the GPU, lists that are hard to render. Every change considers its performance cost.
- **Remote ready.** The websocket layer (the MC) is what makes LAN, Tailscale, and HAL-C2 Connect (a self-hosted relay, also in this repo) work. New features must work over all of them.
- **Multi-surface.** Desktop (Qt), mobile (QML), and the TUI, all against the MC. Features reach every surface where reasonable.
- **Small systems.** Do not preserve complexity because it exists, and do not add machinery because it looks impressive. Understand the real constraint, then build the smallest model that makes the correct behavior unsurprising. Measure twice, cut once, and yagni. Honor the developer's intent minimally and realistically.

The rest of this document is good defaults, not hard rules. The developer's preferences override anything here.

HAL-C2 is often developed from inside HAL-C2 (or upstream T3 Code), controlled remotely. Be careful about accessing data, killing dev servers, and anything else that could damage the instance the developer is using.

## A small glossary

- **you** means the agent reading this file and changing HAL-C2.
- **we, us, and maintainers** mean the fork's maintainer, who you are talking to now. **Upstream** means T3 Code and its maintainers.
- **user** means the person using HAL-C2 to direct coding agents.
- **agent** means the coding agent a user runs inside HAL-C2. Depending on context, that may also include you.
- **provider** means the agent runtime or harness HAL-C2 talks to, such as Codex, Claude, Cursor, or OpenCode.
- **client** means the desktop, mobile, or terminal UI.
- **MC** means hal-c2-mc, the Elixir server in `apps/server-ex`.
- **environment** means one running MC and the machine, filesystem, provider credentials, and state it owns.
- **project** means an environment-local workspace record rooted at a directory.
- **thread** means the durable conversation and work history for a project.
- **turn** means one user-to-agent cycle, including follow-up work such as checkpointing.
- **HAL-C2 home** means where an environment keeps its files: the XDG config, data, state, and cache directories named `hal-c2` (`~/.local/share/hal-c2` and siblings), or all four under one root such as `$HAL_C2_HOME`. The MC's files sit one `elixir` level down. See `docs/internals/storage.md`.

## The two ways to hurt yourself

1. **Killing by pattern.** Never `pkill -f`, `pgrep | kill`, or `kill` a PID you found by matching a name, path, or worktree string. Your own agent process has this worktree's path in its argv, and this machine runs several other dev servers at once. Kill only a PID you captured at spawn, or the owner of your port from `ss -H -ltnp` after confirming `/proc/<pid>/cwd` is your worktree.
2. **Writing to the live install.** `~/.config/hal-c2`, `~/.local/share/hal-c2`, `~/.local/state/hal-c2`, and `~/.cache/hal-c2` (and their `hal-c2-dev` siblings) are the developer's real HAL-C2 install, in use while you work. `~/.t3` and `~/.hal-c2` are just as off limits: they hold the real data HAL-C2 migrates from, and T3 Code may still run against `~/.t3`. Reading and copying from any of them are fine, and a good way to get real test data (see Test data). Never start a server or MC against them, never open them read-write, never clean them up.

## Hit every surface

The most common defect in this repo is a change that works on the path you tested and is missing everywhere else. Before calling frontend work done, walk this list and say which entries applied:

- **Entry points.** A behavior reachable from the chat view is usually also reachable from Settings, the command palette, and a keybinding. Fixing one is not fixing the feature.
- **Clients.** Qt desktop, QML mobile, and the TUI. QML shared between them is `@shared` in `features/`.
- **Servers.** New behaviour lives in the MC. Behaviour it does not have yet needs a scenario under `features/` tagged `@backlog` so the ledger knows what the MC must gain.
- **Providers.** Codex, Claude, Cursor, Grok, OpenCode, and Antigravity each have an adapter. Provider-shaped features need a decision per adapter, even if the decision is "not supported here".
- **Contracts.** Anything crossing the wire is typed in `packages/contracts`; the MC and the QML clients follow the same RPC names (see `features/parity/`).
- **Reverse states.** If you added a way in, add the way out and the way to see it. Snooze needs unsnooze. Close needs reopen. A one-way door is a bug.
- **Connection modes.** Local, remote/relay, and tunnel behave differently. Multi-device and multi-environment cases are real.
- **Docs.** Check whether the change makes existing guidance inaccurate. Apply the [documentation rules](#documentation) before adding anything.

## Dev servers

- `mise run install` installs the JS workspace and the MC's Elixir deps. Worktrees get the JS half (`vp i`) from the `hal-c2.json` setup script (a legacy `t3.json` is still read); if module resolution looks broken, it probably did not run.
- The MC runs with `mise run mc` (from `apps/server-ex`, `mise exec -- mix hal_c2.server`). From any checkout or worktree it keeps dev state in the `elixir` level of the XDG `hal-c2-dev` directories, which are the developer's (rule 2). To run your own MC, point `HAL_C2_MC_HOME` at a scratch directory and `HAL_C2_MC_PORT` at a free port (`mise run mc --home <dir> --port <port>` does both).
- The desktop runs with `mise run desktop`, paired with the running MC (`apps/desktop-qt/README.md`). The terminal client runs with `mise run tui`.
- The phone client runs on this machine with `mise run mobile` and on Android with `mise run mobile:android` (`apps/mobile-qt/README.md`). It pairs with an MC by a pairing link (`mise run mc:pair`); its files go to the worktree's gitignored `.hal-c2/mobile`.
- Stop what you started, by the PID you tracked. See rule 1.

## Test data

An empty database is a bad test. Seed a scratch MC home with a copy of real data instead of pointing at live state:

- Copy from the MC's files in `~/.local/share/hal-c2/elixir` (the developer's real data, the most realistic test set) or `~/.local/share/hal-c2-dev/elixir`. A T3 Code install is a source too, through `mise run threads:import`.
- Snapshot the database with `VACUUM INTO`, which is safe even while the MC has the source open and yields one consistent file. The scratch home is `HAL_C2_MC_HOME` (`<home>/data/hal-c2.sqlite`; see "Dev servers"):

  ```bash
  export HAL_C2_MC_HOME="$PWD/.hal-c2/mc"
  mkdir -p "$HAL_C2_MC_HOME/data"
  rm -f "$HAL_C2_MC_HOME"/data/hal-c2.sqlite*  # VACUUM INTO refuses to overwrite
  sqlite3 -readonly ~/.local/share/hal-c2/elixir/hal-c2.sqlite "VACUUM INTO '$HAL_C2_MC_HOME/data/hal-c2.sqlite'"
  ```

  A plain `cp` is only safe when no MC has the source open, and must bring the `-wal` and `-shm` siblings along. A live file copy is a corrupt copy.

- Bring `secrets` (data) and `settings.json` (config) only if the flow under test needs them.
- Copy in, never symlink. Data flows one way: into your sandbox, never back out.

## Verifying

- Smallest proof that the change works. `vp test run <files>` for the tests you touched, targeted lint and typecheck for the scope you changed.
- Test meaningful logic or observable behavior. Do not render components to static markup to assert props or attributes, or add tests that merely assert callback wiring or mirror the implementation.
- **Do not run repo-wide checks.** No `vp check`, no `vp run -r test`, no `vp run -r typecheck` unless I ask. CI owns the full suite.
- Backend behavior changes ship with focused tests for that behavior.
- MC changes to a stateful service (a GenServer, supervisor, the event log, stream subscriptions, orchestration commands, auth, settings, scheduling, thread moves, the plugin host, and the MC part of a plugin under `plugins/`) or to a pure algebra such as `HalC2.Patch` ship with a property test in `apps/server-ex/prop`: extend the service's state machine model, or add one if it has none. A bug a property finds also gets a plain regression test in `test/`. The property tests are GPL-3.0 (PropCheck) and run apart from `mix test`, with `mise exec -- mix prop <files>`; read `apps/server-ex/prop/README.md` first, and never import them or PropCheck from `lib/` or `test/`.
- The Qt clients follow the same rule: a change to a C++ class whose behaviour depends on the order of calls and MC messages (the MC client, caches and stores, list models, controllers) ships with a RapidCheck state machine property in `apps/desktop-qt/tests/prop` (the phone's in `apps/mobile-qt/tests/prop`), and a bug one finds also gets a `tst_<Name>Regression.cpp` in the native tests. Run them with `mise prop:desktop <names>` or `mise prop:mobile <names>`; read `apps/desktop-qt/tests/prop/README.md` first.
- A protocol between MCs or processes (thread moves, the cluster, leases) also has a Maude model in `apps/server-ex/proof`, checked over every interleaving, crash and partition up to a bound with `mise exec -- mix proof <files>`. Change the model with the code: the proof fails when they stop matching. Read `apps/server-ex/proof/README.md` first; Maude and ex_maude never reach `lib/`.
- The server is event-sourced and its async flows emit typed receipts. Wait on receipts and worker drains, never on sleeps or polling. A test that needs a timeout to pass is wrong.
- Upon request, user-visible frontend changes should get one integrated pass in a real client (`mise run desktop`, `mise run mobile`, `mise run tui`). The primary agent does this once after integrating. Subagents do not launch their own dev servers. Ask permission before doing computer use.

## Pull requests

- Never make a PR unless the developer explicitly asks you to do so.
- Conventional commit titles, plain language: `fix(desktop): new threads no longer spike CPU`.
- Body: the problem in a sentence or two, then how you fixed it. End with the model and harness that did the work.
- UI changes need before/after images. Motion or timing needs a short video.
- Upload PR evidence to GitHub. Never commit PR-only screenshots or assets such as `.github/pr-assets/`.
- One concern per PR. If the description says "also", split it.
- When babysitting: poll checks and comments newer than the last push, verify each bot finding against the source, fix real ones, dismiss false positives with a written reason. Stay quiet when nothing is new. Stop when the bots are green on the latest commit.

## Documentation

Most code changes do not need an internal documentation change. Agents can read the code.

- `docs/internals/` is for architectural decisions and their reasons, constraints that span components, and implementation traps that are hard to discover from the source. Before adding a paragraph, ask what a maintainer would get wrong without it. If reading the relevant code answers the question, leave it out.
- Do not document every feature, enumerate fields or methods, narrate control flow, maintain file catalogs, or append PR summaries. Types, tests, and code already record the implementation. The glossary defines shared vocabulary; it is not a feature index.
- Keep a local implementation explanation in a nearby code comment. Use an internal doc when the reasoning crosses boundaries or needs context the code cannot carry well. Link to the relevant source instead of copying it.
- When a documented decision or constraint changes, rewrite or remove the affected text. Do not append another account of the new behavior. A new internal page needs a distinct, durable reason to exist.
- `docs/user/` helps users accomplish tasks. Give each major feature a concise section explaining what it does, how to start, and anything unintuitive. A settings path is useful; descriptions of visible buttons, icons, layouts, animations, or every UI state are not. Before adding text, ask what task or decision it helps the user with.
- Keep user docs in the shipped product's voice, without implementation details or contributor tooling. Update the relevant feature section when how to use it changes. A UI tweak does not need a documentation entry, and a new control does not need its own page.
- `docs/operations/` holds maintainer setup, release, and debugging procedures. Keep instructions for operating an installed HAL-C2 server in the user guides.

## Plans and work artifacts

- Do not commit implementation plans, research notes, or agent scratch files. Keep temporary working material outside the worktree. `.plans/` is gitignored only as a safety net for tooling that writes there.
- Track active work in the `hal-c2/hal-c2` issue that owns it. External proposals follow `CONTRIBUTING.md` and belong in the fork's Ideas discussions. Changes that make sense for everyone belong upstream.
- A merged PR is the implementation record. Close or update its tracking item when the work lands; do not preserve a second checklist in the repository.

## How it works

Clients send typed WebSocket requests to the MC. State lives in an append-only SQLite event log of _patches_ to entities, one _stream_ per project or thread. Each stream is an OTP process that decides a command and appends its patches in one step; clients subscribe to the shapes they render and resume from an offset. Provider CLIs run as subprocesses; per-provider _adapters_ translate their native protocols into patches on the thread's stream. Each turn ends with a _checkpoint_, a hidden git ref, so the app can diff and restore.

Full glossary with file links: `docs/internals/glossary.md`

## Where code lives

- `apps/server-ex` - the MC (Elixir/OTP): run and test with `mise exec -- mix ...`; read its README first.
- `apps/desktop-qt` - the Qt/QML desktop. `apps/mobile-qt` - the QML mobile client, the desktop's C++ and bricks with a phone layout; read `docs/internals/mobile-qt.md` first. `apps/tui` - the QML TUI on opentui-qml; its scenarios run with `TUI_FEATURES="<globs>.feature" bun test ./features/runner.ts`.
- `apps/marketing` is the site. `infra/relay` is the HAL-C2 Connect relay. `plugins/` holds the plugins. `native/` holds native helpers such as the SnapShot capture helpers and libghostty-vt.
- `features/` - the Gherkin behaviour ledger; see `features/README.md`.
- `packages/contracts` - Effect/Schema contracts plus small derived helpers. No heavy runtime logic.
- `packages/shared` - shared runtime utils, subpath exports, no barrel.
- `packages/client-runtime` - client protocol and state code the TUI uses; the Qt clients' C++ mirrors parts of it.
- `.repos/` - vendored read-only references. Prefer their patterns over invented ones. Never edit or import from them. Sync with `vpr sync:repos` when bumping the matching dependency.

## Taste

- Complexity belongs at the adapter boundary. Orchestration stays pure, UI stays dumb.
- Inferred types over annotations. `any` is the enemy.
- Comments describe how a thing is used, and move when the code moves. To be used mostly to describe functions, not to annotate every line of behavior.
- Our users drive agents all day and notice a dropped frame, a lying spinner, and a stale label. No continuously repainting animations; they peg the GPU on high-refresh displays.
- If a rule here fights the task in front of you, say so loudly and get a human sign-off before breaking it.

## Additional tips

- Don't verify with computer use unless the user explicitly agrees or requests it.
- Security is important, but should not be over-indexed on, especially for dev mode/maintainer-only features.
