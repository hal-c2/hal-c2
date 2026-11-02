# Maintenance

Scheduled repository maintenance. An agent the user picks runs the `maintain`
skill on each repository the plugin follows, every day, every week or when
asked: it updates dependencies, fixes open security advisories, corrects docs
that drifted from the code and fills coverage gaps. A fix run works on a
`maintenance/<date>` branch in a worktree of its own, one commit per category
behind the repository's own gates; a report run changes nothing. Either way the
agent reports what it applied, what it deferred (with the command a human would
run) and the gate it ran, and that report is the pull request's body. The user
decides whether a branch stays in HAL-C2, waits to be opened as a pull request,
or is opened at once. How to use it is in
[docs/user/maintenance.md](../../docs/user/maintenance.md); what it does,
scenario by scenario, is in
[features/source-control/maintenance.feature](../../features/source-control/maintenance.feature).

It is an ordinary MC plugin and needs nothing from this repository but the
plugin API: copy the folder into an MC's `plugins` folder to install it.

## The package

- `plugin.json`: the name, description, the permissions it asks for and why,
  its settings and what it adds to the clients.
- `mc/`: the MC part. `maintenance.ex` starts runs as threads, keeps the
  schedule, takes the agent's report and opens pull requests; `runs.ex` is how a
  run moves, `report.ex` what a report must hold, how it is redacted and the
  pull request body made of it, and `schedule.ex` when a run is due, all as
  plain functions.
- `ui/`: one QML file per part. `MaintenancePage.qml` is the **Maintenance**
  page; `MaintenanceHeader.qml` and `MaintenanceRowMark.qml` show a run above
  and beside its thread.
- `skill/`: the `maintain` skill and the roles it names, vendored (see below).
- `assets/`: the icon.

## The skill

`skill/` is a copy of the `maintain` skill from
[olafura/skills](https://github.com/olafura/skills), MIT licensed, Copyright (c)
2026 Olafur Arason: `skill/LICENSE` is its licence and `skill/SOURCE.md` names
the commit it was taken from. A repository that has its own
`.agents/skills/maintain/SKILL.md` or `.claude/skills/maintain/SKILL.md` is
maintained by that one instead. To update the copy, replace `skill/` from
upstream and move the commit in `SOURCE.md`.

## Between the parts

The UI parts follow two topics of the MC part: `maintenance`, the followed
repositories with their next run and every run with its report, and `threads`,
each run by its thread. The UI acts through the calls `run`, `cancel`,
`dismiss` and `publish`. A run's agent reports with the `maintenance_report`
tool, offered only to threads this plugin started.

The MC's plugin API has no way to push a branch or open a pull request, so
`publish` runs `git push` and `gh pr create` in the run's worktree itself,
behind the `pullRequests:write` permission.

## Tests

The MC scenarios, from `apps/server-ex`:

```bash
mise exec -- mix features source-control/maintenance.feature
```

The property model of runs, schedules and redaction, from `apps/server-ex`:

```bash
mise exec -- mix prop prop/hal_c2/maintenance_prop_test.exs
```

The page, header and row mark, against a fake MC part, from a hal-c2
checkout's `apps/desktop-qt`:

```bash
QT_QPA_PLATFORM=offscreen qmltestrunner -import tests/imports -import qml \
  -input <this folder>/test
```
