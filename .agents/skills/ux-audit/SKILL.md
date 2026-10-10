---
name: ux-audit
description: Exhaustive UX/UI audit of the Qt desktop client (apps/desktop-qt) driven through cua-driver in the headless `mise run desktop:cua` sandbox against a scratch MC seeded with real data. Covers every area at several window sizes and appearances, clicks every feature, logs findings with screenshots and up to five solutions each, and builds an HTML report. Files a GitHub parent issue with sub-issues only on request. Use when asked to audit, review or QA the desktop UI, or to find every UX issue.
---

Run a leave-no-stone-unturned UX/UI audit of the Qt desktop and turn it into a
report. Everything runs against the real app and a real MC. The MC is a
scratch one seeded with a copy of real data. Nothing is stubbed, and nothing
touches the developer's display, session bus or HAL-C2 home.

Base severities on the **ui-ux-pro-max** skill. Its search tool
(`ux guide "<outcome>"`)
gives you a named guideline to argue a severity against and to phrase a fix
in (contrast, truncation, feedback, error messages, focus, navigation,
density). If the **qt-qml** skill is installed (bootstrap warns when it is
not), read it before proposing QML fixes. Fixes go
through the shared bricks (`ShellButton`, `ShellComboBox`,
`ShellSplitButton`, `ShellTabs`, `ShellCard`, `Theme` roles) in
`apps/desktop-qt/qml/HalC2/Bricks/`, never through one-off restyles.

Reference for intended behaviour: the legacy web app (`apps/web`) is what the
desktop is catching up to. Where they disagree, the web wins unless there is a
reason. Read its code to see what a desktop view should do, but do not run it.
The `features/` ledger says what the desktop claims to do (see
`references/checklist.md`).

Arguments (free text): scope (the whole desktop by default, or an area such as
"composer" or "settings"), extra flows, `--issues` to file GitHub issues after
the report, `--report-only` to rebuild from an existing findings file.

## 0. Prerequisites and bootstrap

1. Linux with sway (with Xwayland), dbus, at-spi2-core and `cua-driver` on
   the `PATH`. `docs/operations/development.md` § "Driving the desktop with
   cua-driver" is the reference for the sandbox.
2. `bash .agents/skills/ux-audit/scripts/bootstrap.sh` creates the audit dir
   (`$UX_AUDIT_DIR`, default `/tmp/hal-c2-ux-audit-<date>`, outside the
   worktree) with `shots/`, `scratch/`, `findings.jsonl`, `coverage.jsonl`
   and the helpers, including `ux`. It checks the prerequisites and
   ui-ux-pro-max. It refuses to run on a non-empty `findings.jsonl` or
   `coverage.jsonl`: point `UX_AUDIT_DIR` somewhere fresh, or set `UX_AUDIT_RESUME=1` to continue.
3. Start the sandbox seeded with real data. The seed is snapshotted
   read-only with `VACUUM INTO`, so the live database is never opened
   read-write:

       mise run desktop:cua --seed ~/.local/share/hal-c2-dev/elixir/hal-c2.sqlite
       export PATH=$UX_AUDIT_DIR:$PATH

   Seed only the database, never `settings.json` (see pitfalls).
   `mise run desktop:cua` again relaunches the app and picks up QML changes.
   `mise run desktop:cua:stop` ends everything.

4. Read `references/checklist.md` (what to cover) and
   `references/pitfalls.md` (sandbox and safety traps) before touching the
   app.
5. Plan from three lists, not from the sidebar:
   - `ux census` groups the seeded threads by what makes them unusual:
     markup or JSON in user messages, subagent activity, worktrees, errors,
     usage limits, pending requests, background tasks, pull requests,
     pinned, snoozed, archived, forked, long titles. The defects live in
     unusual data. The first threads in the sidebar are the ordinary ones.
   - `ux ledger` lists every `@desktop`/`@shared` scenario as claimed,
     backlog or dropped. A claimed scenario that does not hold is a finding.
   - `git log --since=2.weeks --oneline -- apps/desktop-qt` shows what
     changed recently. Fresh UI changes are where regressions are.

## 1. Driving the app

    ux shot <name> [filter]      # shots/<name>.png + the AT-SPI tree in <name>.json; prints the elements
    ux click <x> <y> [count]     # screenshot pixels of the last shot
    ux click-name <label> [n]    # shoots, then clicks the nth element with that accessible label
    ux key ctrl k                # a chord; punctuation as the character: ux key ctrl '['
    ux type <text>               # into the focused control; click the field first
    ux scroll <x> <y> [down] [3]
    ux size 960 1000             # floats the window in the sandbox's sway and resizes it
    ux mc-stop / ux mc-start     # stop and restart only the scratch MC
    ux cov <area> <size> <appearance> <shot>   # or: ux cov <area> --skip <reason>
    ux sheet <out> <shot>...     # a contact sheet, to compare sizes or themes side by side
    ux logs [n]                  # tail app.log and mc.log

`ux` wraps `mise run desktop:cua:call <tool> [json]`, which is there for
anything it does not cover (`cua-driver describe <tool>` gives a schema).
Coordinates are pixels of the last shot, so shoot before you click. The
element list carries text that was elided on screen and the accessible
names. An element the screenshot shows and the list does not is an
accessibility finding. Check `ux logs` after each area for QML warnings and
MC errors.

## 2. Exploration (click everything)

Work through the checklist area by area at every window size and in both
appearances. For each feature, run the real flow to completion, shoot each
interesting state, and check the logs. Three things are not optional,
because skipping them is how earlier audits missed the worst defects:

- **Every census group.** Open at least one thread from each group `ux
census` prints, read its timeline top to bottom, and open every right-panel
  tab on it. Record `ux cov "Timeline › <group>" …`.
- **Every right-panel tab on several threads**: one in the main checkout,
  one on a worktree, one whose worktree lies outside its project's root.
  An empty panel and an error panel are both states to audit.
- **A live turn** in the scratch project (pitfalls says how). While it
  runs, watch the working state, then queue two messages, edit one, steer
  with the other, cancel a third, and interrupt. Then let a turn finish and
  look at the result. Record it as `Live turn`. Queued messages, steering
  and the transitions between states only exist during a turn.

Look at every screen as the user would. The user drives agents all day and
notices:

- **Text the user should never see**: raw markup, protocol payloads, ids,
  internal jargon, developer-facing error strings, untranslated enum
  values. It shows up wherever the app echoes text it did not write: user
  messages that a tool or agent sent, queued messages, notifications,
  titles, errors from the MC.
- **Labels that don't say what they are**: values with no name, the same
  label twice in one bar, ambiguous labels, icons with no tooltip or
  accessible name.
- **Truncation and crowding**: titles, breadcrumbs, pills and tabs at
  narrow widths with the sidebar and right panel open. Check what was cut
  and whether it can still be read anywhere. Window controls belong at the
  window's edge on every route and at every size.
- **States**: empty, loading, error, offline, long, many. Is each one
  explained, with a way forward? Is an error shown where it happened, at a
  size that fits the problem? Can the user act on it?
- **Consistency**: the same thing drawn and named the same way in the
  timeline, sidebar, panels, settings and palette. Controls from
  `QtQuick.Controls.Basic` outside the `Shell*` bricks ignore the theme.
- **Theming**: every `palette["…"]` key the QML reads exists in
  `ThemeController`, in light, dark and a custom theme. Popups are opaque
  and readable in all three.
- **Focus**: a popup or dialog takes focus when it opens and gives it back
  when it closes. Tab moves focus in every input, unless the input says it
  takes Tab. Escape closes what it should.
- **Reverse states**: every way in has a way out and a way to see it.
- **Stale or lying UI**: spinners, counters, "Working for…" timers and
  connection warnings that don't match the MC's state.
- **Performance you can see**: dropped frames when scrolling long threads,
  animations that never stop, slow panel switches.

Mutating flows run only in the scratch project (see pitfalls). When a bug
blocks the audit, log it as a finding, route around it, and keep going. Fix
it only if the user asked for fixes.

## 3. Findings log

Append one JSON object per line to `$UX_AUDIT_DIR/findings.jsonl`:

    {"id":"F012","sev":"medium","area":"Composer",
     "title":"...one line, the defect not the fix...",
     "desc":"...what happens, how verified, who is hurt...",
     "evidence":{"window":"960x1000","appearance":"dark","steps":"..."},
     "shots":["composer-960-dark.png"],
     "where":["apps/desktop-qt/qml/HalC2/Bricks/Composer.qml:212"],
     "ledger":["features/composer/model-picker.feature: Scenario name"],
     "solutions":["...","...","...","...","..."],
     "related":["F013"]}

Rules that make the report worth reading:

- `sev` is one of `high | medium | low | info | ok`. **High**: blocks or
  misleads a task, shows the user internals they cannot act on, or loses
  work. **Medium**: a clear usability cost with a workaround. **Low**:
  polish or consistency. **Info**: an observation. **`ok`**: you looked, it
  is fine, and `why_ok` says why. The reader wants the reasons for leaving
  things alone as much as the defects.
- Aim for five `solutions`, fewer when fewer are honest. Each is concrete
  (brick, property, file). At least one is a test: a Qt native test, a
  RapidCheck property for stateful C++, or a `features/` scenario.
- `where` points at the QML or C++ behind the finding. Find it before you
  log it. `rg` the visible string in `apps/desktop-qt` (and in
  `apps/server-ex` for MC-originated text).
- `ledger` names the scenario the finding contradicts or that is missing.
  An untagged `@desktop` scenario that does not hold is worth calling out:
  the ledger is wrong. A `@backlog-desktop` gap is known, so log it as
  `info`.
- One finding per root cause, with every place it shows up in `evidence`.
  Don't log one finding per screen.
- Cite the ui-ux-pro-max guideline you checked when the severity could be
  argued.

Record each screen you covered with `ux cov`, which appends to
`$UX_AUDIT_DIR/coverage.jsonl`:
`{"area":"Settings › Providers","size":"960x1000","appearance":"dark","shot":"settings-providers-960-dark"}`.
Start each `area` with a checklist area name (`Right panel › Diff`,
`Timeline › Errors`, `Live turn`). The report builder lists every checklist
area with no row as never visited. Anything you could not reach is still a
row: `ux cov "Terminal" --skip "<reason>"`.

## 4. Report

    python3 $UX_AUDIT_DIR/build_report.py --dir $UX_AUDIT_DIR \
      --title "HAL-C2 desktop UX/UI audit" --env "<commit, seed, window sizes, theme, caveats>"

The report has these sections: Summary (counts, highest-impact items,
index), Method, Findings by area, OK as-is, Coverage (area by size and
appearance, linking every shot), and Environment. It is one `report/index.html`
plus `report/shots/` in the audit dir. The builder prints any screenshot it
could not find and every checklist area never visited. Fix the first and
visit the second, then look at the report.

The report and the screenshots stay out of the repository (AGENTS.md:
no work artifacts and no screenshot assets in commits).

## 5. Issues (only with `--issues` or when asked)

    python3 $UX_AUDIT_DIR/github_issues.py --dir $UX_AUDIT_DIR --repo hal-c2/hal-c2 \
      --env "<same caveats as the report>" --upload-shots --dry-run

Before filing, make each finding something a developer can fix from the
issue alone: `where` at the root cause on the current `main`, a `desc` with
steps to reproduce, the expected behaviour (the web's code path when it has
one) and the root cause, and solutions that include a test. Findings that
`main` already fixes get `"fixed": "<commit>"` and are not filed. Split a
finding that bundles unrelated causes.

Show the user the dry run, then run it without `--dry-run` once they agree.
The script creates the labels (`ux-audit`, `severity:*`) and one parent issue
with the summary, a checklist grouped by severity, what was already fixed,
and the OK-as-is list. Then it opens one sub-issue per remaining finding and
links each one with the sub-issue API. `--upload-shots` pushes the shots the
issues use to one secret gist and embeds them. The gist and the issues are
readable by anyone with the link, and `hal-c2/hal-c2` is public: check the
shots for tokens, pairing links and private content first, and leave the
flag off when in doubt. The issue text is just as public: titles,
descriptions, evidence, paths and the `--env` text come from real
conversations and checkouts. Read every field the dry run prints for private
text, usernames, home paths, hostnames, pairing links and credentials, and
redact them in `findings.jsonl` before the real run. The state file in the
audit dir makes a re-run resume instead of duplicating.

## 6. Hand-off

The final message gives the report path, the counts per severity, every
high item in a sentence each, the census groups and checklist areas you did
not reach, and what the sandbox made impossible to verify.
Also note what in this skill was wrong, missing or slowed you down, so it can
be fixed.
