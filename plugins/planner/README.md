# Planner

A plan of tasks and milestones for an MC's projects, shown as a Gantt chart, a
board or a list in views you save. Agents act on it through actions whose prompts
you edit, and what they want to change comes back as a proposal. How to use it is
in [docs/user/planner.md](../../docs/user/planner.md); what it does, scenario by
scenario, is in
[features/planning/planner.feature](../../features/planning/planner.feature).

It is an ordinary MC plugin and needs nothing from this repository but the plugin
API: copy the folder into an MC's `plugins` folder to install it.

## The package

- `plugin.json`: the name, description, the permissions it asks for and why, its
  settings (the actions and their prompts among them) and what it adds to the
  clients.
- `mc/`: the MC part. `planner.ex` keeps the plan, runs actions in threads of
  their own and publishes; `plan.ex` holds the rules of a plan (dependencies,
  progress, proposals) as plain functions; `sync.ex` follows GitHub issues,
  milestones, boards and pull requests; `slack.ex` talks to the plan's Slack
  channel.
- `ui/`: one QML file per part, each self-contained. `PlannerPage.qml` is the
  **Planner** tab with every view, `PlannerHeader.qml` and `PlannerRowMark.qml`
  are how its threads look, and `PlannerSettings.qml` replaces the generated
  settings page.
- `assets/`: the icon.

## Between the parts

The UI parts follow three topics of the MC part: `plan`, the tasks with what is
derived from them (late, progress, slip), the views, the status updates and the
state of GitHub and Slack; `runs`, every action run with its proposal; and
`threads`, each planner thread's run or task, for the header and row mark, sent
only when one of those changes. Views filter and group in the client, so a view
costs nothing on the wire. The UI acts through calls such as `addItem`,
`updateItem`, `saveView`, `run`, `dismissChange`, `apply` and `sync`.

Agents use three tools: `planner_read` reads the plan, `planner_report` is how an
action's agent reports its summary, changes and feedback, and `planner_progress`
is how a thread working on a task reports progress, notes and pull requests.

## Tests

The MC scenarios run with `mise exec -- mix features planning/planner.feature` in
`apps/server-ex`, and its state machine property with
`mise exec -- mix prop prop/hal_c2/planner_prop_test.exs`. The desktop draws these
QML files against a fake of the MC part:
`HAL_C2_FEATURES="planning/planner.feature"` with the desktop's `tst_Features`.
