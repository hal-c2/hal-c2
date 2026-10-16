# Planner

The planner plugin keeps a plan of tasks and milestones for the projects on an MC:
when each starts and is due, what waits for what, how far along it is and who has
it. You see it as a Gantt chart, a board or a list, in views you save. Agents act on
the plan through actions whose prompts you write, and what they want to change
comes back as a proposal you accept or dismiss, one change at a time.

It runs on an MC, like any [plugin that runs on your MC](plugins.md#plugins-that-run-on-your-mc).
Each machine keeps its own plan, for its own projects, with its own agents.

## Start

1. Put the `planner` folder in the MC's `plugins` folder, click **Look for
   plugins** in **Settings → Plugins** and turn it on there. It asks to read
   projects, pull requests and issues, change issues, start threads, use Slack and
   give agents tools to read and report on the plan.
2. Open the **Planner** tab and add a task or a milestone, or follow GitHub
   issues (below) to start from the ones you have.
3. In the plugin's settings, pick the agent, its model and its access, and a
   **Default project** for actions that do not come from a task in a project.

## Tasks, milestones and dependencies

A task has a start and a due date. A milestone has only a date. Tasks can have
subtasks, and a task can wait for others: it is marked when it starts before
what it waits for is due, and the planner refuses a dependency that would make a
task wait for itself. A task's progress follows its subtasks, or the pull
requests linked to it, until you set it yourself.

**Save baseline** remembers today's dates, and **Clear baseline** forgets them.
With **Baseline** on in a view, each task shows where it was meant to be, and
how many days it slipped.

## Views

The planner starts with **Timeline** (a Gantt chart by week), **Board** (columns
by status) and **All tasks** (a list). A view is a layout with its own filter,
grouping, sort, zoom, fields and whether it shows dependencies and the baseline.
Change any of them and the view is marked as changed. **Save** keeps the change,
**Save as new** makes another view, **Revert** goes back. Views belong to the
plan, so everyone connected to that MC sees the same ones.

In the Gantt chart, drag a bar to move a task, or its end to change its due date.
On the board, drag a card to another column. Click any task to open it: edit its
fields and notes, see its issue, pull requests and threads, and run actions on it.

## Actions and their prompts

An action is a prompt for an agent. The planner comes with:

- **Validate progress** checks one task against its pull requests, threads and
  code, and proposes its status and progress.
- **Reschedule** looks at the whole plan and proposes new dates.
- **Give feedback** comments on tasks and on the plan.
- **Break down** proposes subtasks for a task.
- **Write status update** proposes how the plan stands: on track, at risk or off
  track, with a summary.
- **Start work** starts a thread that works on a task in a worktree of its own.

Edit any prompt in the plugin's settings. The prompt is a template:
`{{item.title}}`, `{{item.due}}`, `{{plan}}`, `{{today}}` and the others listed
under it are filled in for each run. How the agent reports is added after it.
**Reset to the plugin's prompt** undoes your changes. **Add action** makes your
own, for one task or the whole plan.

An action runs in a thread in the task's project, or the default project. Its
agent can read the plan, and its access is the one you picked, so analysis
actions only change your checkout if you let them. **Start work** uses its own
access setting, **Accept edits** by default.

## Proposals

What an agent wants to change waits as a proposal: on the **Planner** tab, in the
run's thread header, and as dashed bars in the Gantt chart. Dismiss the changes
you do not want, then **Apply** the rest, or **Discard** the whole proposal. A
change to a task that was removed since, or that no longer fits the plan, is
marked as no longer applicable; the rest overwrite edits made in the meantime. Set an action to **Applies changes** to skip the proposal.

Feedback shows on its task or on the plan until you dismiss it. Applied status
updates, and those you post yourself, form the plan's history.

## Work on a task

**Start work** links a new thread to the task and marks it in progress. Its agent
reports progress and notes, and links the pull requests it opens. With **Let
every thread read the plan**, every agent can read it, but only linked threads can
change it.

## GitHub

The planner reads GitHub through the `gh` login on the MC's machine.

- **Pull requests:** a task is done when every pull request linked to it is
  merged, and its progress counts the merged ones.
- **Issues:** add **Repositories**. Each open issue becomes a task, or only
  those with the label under **Only issues labelled**. Milestones, sub-issues and
  "blocked by" become milestones, subtasks and dependencies, and the pull requests
  that close an issue are linked to its task. A repository is followed only if a
  project on that MC has it as its remote.
- **Boards:** pick a **GitHub Project** from those of your projects' owners, or type
  one as `owner/number`, then pick which of its date fields hold the start and
  target dates (**Start date** and **Target date** by default). If the board
  renames or drops one of those fields, tasks keep their dates until you pick
  the field again. Listing and reading boards needs `gh auth refresh -s project`;
  until then the settings say so.
- **Sync:** **Import from GitHub** only reads GitHub. **Both ways** also sends your changes
  back: closing, renaming, labels, assignees, dependencies, sub-issues and board
  dates. A change GitHub refuses is kept and marked as not synced, with GitHub's
  reason, and goes again with your next change to that task; the mark clears once
  GitHub has taken all of it. **Create issue** on a task makes it an issue.

The planner looks every few minutes; **Look now** looks at once.

## Slack

With Slack connected to the MC (**Settings → Integrations → Slack**) and a channel
set under **Post to Slack channel**, the planner posts status updates there and,
with **Announce proposals in Slack**, the proposals that wait for you. Replies in the thread of a posted update
become feedback on the plan. Add the **Slash command** (`/planner` by default) to
your Slack app and:

- `/planner status` shows you what is late, what is in progress and how the plan
  stands.
- `/planner validate API` runs **Validate progress** on the task "API". Any
  action works, named by the first word of its label.
- `/planner run status` runs **Write status update** by its id, `status`. Use
  `run` and the id when the first word of an action's label is `status`, `run`,
  or shared with another action. A command the planner does not understand
  answers with every action written this way.

## Where runs show up

**Show planner threads** picks whether action threads stay on the **Planner**
tab, are listed as threads marked with their state, or both.

The **Planner** tab keeps the 50 latest runs that are applied or found nothing to
change. Older ones leave the tab, and their threads' marks stop showing the run's
state and read just **Planner** or **Task**. Proposals and failed runs stay until you
apply or discard them.
