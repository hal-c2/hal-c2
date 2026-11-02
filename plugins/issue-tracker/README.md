# Issue Tracker

The triage queue in front of a repository's GitHub issues. The **Issues** page
lists the open issues of the repositories it follows; agents the user picks
prioritise the queue, draft follow-up questions for an issue's reporter, and
summarise an issue (naming its duplicates). What an agent wants to change comes
back as a proposal on the page — applying it sets priority labels or posts the
drafted comment, and nothing reaches GitHub before that. **Implement** starts
the implementing agent on an issue in a new worktree of its project, asked to
open a pull request that closes it, and the last such thread shows beside the
issue. How to use it is in
[docs/user/issue-tracker.md](../../docs/user/issue-tracker.md); what it does,
scenario by scenario, is in
[features/source-control/issue-tracker.feature](../../features/source-control/issue-tracker.feature).

It is an ordinary MC plugin and needs nothing from this repository but the
plugin API: copy the folder into an MC's `plugins` folder to install it.

## The package

- `plugin.json`: the name, description, the permissions it asks for and why,
  its settings (the four agents and their prompts among them) and what it adds
  to the clients.
- `mc/`: the MC part. `issue_tracker.ex` looks at GitHub, runs triage actions
  and implementing work as threads, applies proposals and publishes;
  `triage.ex` holds what shape a report must have and what applying one asks
  GitHub for, as plain functions.
- `ui/`: one QML file per part, each self-contained. `IssuesPage.qml` is the
  **Issues** tab (queue, issue, proposals) and `IssueTrackerSettings.qml`
  replaces the generated settings page.
- `assets/`: the icon.

## Between the parts

The UI parts follow one topic of the MC part: `tracker`, the followed
repositories and their open issues (bodies left out — opening an issue reads
it through the `issue` call), every triage run with its proposal, and each
issue's last implementing thread. The UI acts through calls such as `refresh`,
`prioritise`, `followUp`, `summarise`, `implement`, `apply` and `discard`.

Agents use two tools, offered only to threads this plugin started:
`issue_tracker_read` reads the queue or one issue in full, and
`issue_tracker_report` is how a triage agent reports its proposal. Each of the
four actions — prioritising, following up, summarising, implementing — has
its own agent, model, the model's options, access and prompt in the settings,
so a cheap model can triage while a stronger one writes the code.

## Tests

The triage rules run with the MC's tests, in
`apps/server-ex/test/hal_c2/issue_tracker_test.exs`:

```bash
mise exec -- mix test test/hal_c2/issue_tracker_test.exs   # in apps/server-ex
```

The page and the settings, against a fake MC part, from a hal-c2 checkout's
`apps/desktop-qt`:

```bash
QT_QPA_PLATFORM=offscreen qmltestrunner -import tests/imports -import qml \
  -input <this folder>/test
```
