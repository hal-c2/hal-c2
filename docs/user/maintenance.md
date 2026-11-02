# Maintenance

Maintenance is an MC plugin (see [Plugins](plugins.md)) that keeps
repositories up to date on a schedule. An agent you pick follows the
`maintain` skill on each repository: it updates dependencies, fixes open
security advisories, corrects docs that drifted from the code and fills gaps
in test coverage. Nothing reaches GitHub unless your publishing setting allows
it.

## Start

Put the `maintenance` folder from this repository's `plugins/` into your MC's
`plugins` folder and turn it on from **Settings → Plugins**. In its settings,
pick the repositories to maintain from the MC's projects whose remote is on
GitHub; to add another, add its checkout as a project first. Pick when it runs
(every day, every week, or only when you ask), the agent and model, and what
it may do.

The **Maintenance** page lists the repositories with when each runs next.
**Run now** starts a run at once. A run missed while the MC was off starts
once when it is back.

## What a run does

Each run is a thread of the agent you chose, marked as maintenance in the
thread list.

- **Fix** mode works on a new `maintenance/<date>` branch in a worktree of its
  own, made from the default branch. It never commits to or pushes the default
  branch. It makes one commit per category (`chore(deps)`, `fix(security)`,
  `docs`, `test`), only after the repository's own checks pass, and reverts
  what fails them.
- **Report only** changes nothing and says what it would do.
- **Security advisories only** limits a run to open advisories, each fixed
  with the smallest safe upgrade.

Major version bumps, and dependencies pinned with a comment, are always left
for you, with the command to run them. A repository that has its own
`maintain` skill (in `.agents/skills/maintain` or `.claude/skills/maintain`)
is maintained by that one. **Per-repository instructions** add text to one
repository's prompt, such as which checks to run.

A run is skipped while the repository still has an open pull request from a
`maintenance/` branch, so maintenance does not pile up.

## The report and the pull request

Every run ends with a report, even when nothing changed. A run whose agent
stopped without one fails, but continuing its thread until the agent reports
still counts, unless another run of the repository has started since. A run
stopped by the agent's usage limit is not a failure: it carries on when the
limit resets. The report holds, per category, what
was applied, what was deferred and why, and what needs discussing, then the
checks it ran. Tokens and keys in it are hidden. The report shows on the
page and becomes the pull request's description.

**Publishing** decides what happens to a fix run that made commits:

- **Wait for me to open the pull request** (the default): the run waits on
  the page until you choose **Open pull request**.
- **Open the pull request automatically**: the branch is pushed and its pull
  request opened as soon as the agent reports.
- **Keep in HAL-C2**: the branch stays in its worktree. You can still open a
  pull request for it from the page.

While a run waits for you, no new run of that repository starts. **Dismiss**
removes an ended run from the page and frees its repository; **Cancel** stops
a run that is still going.
