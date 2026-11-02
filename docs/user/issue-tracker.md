# Issue tracker

The issue tracker is an MC plugin (see [Plugins](plugins.md)): it turns the
open GitHub issues of the repositories you pick into one triage queue, and
puts agents to work on it. It only ever proposes — nothing a triage agent
wants to change reaches GitHub until you apply it.

## Start

Put the `issue-tracker` folder from this repository's `plugins/` into your
MC's `plugins` folder and turn it on from **Settings → Plugins**. It asks to
read the MC's projects, read and change issues, start threads, and offer its
tools to its agents; the changing permission is only ever used when you apply
a proposal.

In its settings, pick the repositories whose issues form the queue — with
none picked it follows every GitHub project on the machine. Repositories are
read through the machine's `gh` login. Each agent runs in a repository's own
project, and implementing an issue needs a checkout of that repository as a
project on the MC. **Look now** on the page reads GitHub again at once;
otherwise it looks on the interval you set.

## The queue and the agents

The **Issues** tab lists the open issues, newest activity first, with their
authors, labels and, when opened, their body, milestone and what blocks them.
From there:

- **Prioritise** (with a repository picked in the page's filter) ranks that
  repository's queue and gives each issue a priority with its reason.
  Applying the proposal sets a `priority: critical|high|medium|low` label on
  each, replacing the priority label it had.
- **Ask follow-up** on an issue drafts one comment asking its reporter for
  what is missing before anyone could act on it. Applying posts the comment;
  when the agent finds nothing missing, there is nothing to apply.
- **Summarise** writes what an issue asks for, what is known, its likely
  size, and which other open issues say the same thing. Applying keeps that
  summary as a comment on the issue.
- **Implement** starts the implementing agent in a new worktree of the
  issue's project, on a branch named for the issue, asked to commit and push
  and open a pull request that closes the issue. The last thread started for
  an issue is shown beside it with how its turn went, and opens the thread
  where you can direct it further.

Each action appears under **Proposals** as a run: running, waiting for you,
applied, or dismissed. A proposal that only partly reaches GitHub — a label
refused, say — stays waiting and names the issues that failed, so applying
again retries what is missing.

## Choosing the agents

Each of the four actions has its own agent, model, the model's options (its
reasoning effort first of all), access and prompt in the settings, so a cheap
model can prioritise and a stronger one can implement. The triage agents only
read and report, and need no more than "Ask before acting"; the implementing
agent works in a worktree of its own and usually wants "Accept edits". The
prompts fill in the issue, the queue and the date; what each one fills is
written under its prompt. How a triage agent must report is added after your
prompt, so keep that instruction out of your own text.
