# Agent code review

The code-review plugin has an agent of your choice review pull requests on the
repositories you pick. You decide when a review starts, what the agent is told,
and whether what it finds is posted to the pull request, waits for you, or stays
in HAL-C2.

It runs on an MC, like any [plugin that runs on your MC](plugins.md#plugins-that-run-on-your-mc).
Each machine reviews the repositories of its own projects, with its own agents.
When several of your machines are in one cluster and watch the same repository,
one of them reviews each commit of a pull request; the others show the review
with the machine it runs on, and take it over if that machine leaves before
starting it. If that machine leaves in the middle of a review, the others show it
as out of reach, and you can review the commit on one of them. Machines that cannot reach each other each review on their own, and
a commit another machine already posted a review of is not posted again, and shows
as published.

## Start

1. Put the `code-review` folder in the MC's `plugins` folder, click **Look for
   plugins** in **Settings → Plugins** and turn it on there. It asks to read and comment on pull requests, start
   threads and give the agent a tool to report with.
2. Sign in to GitHub with `gh auth login` on the MC's machine. Reviews use that
   login, both to read pull requests and to post reviews.
3. Open the plugin's settings and add the repositories to watch. A repository is
   watched only if a project on that MC has it as its remote; the settings
   suggest the ones that do.

GitHub is the only host today. GitLab, Forgejo, Bitbucket and Azure DevOps are
listed, but cannot be chosen yet.

## When a review starts

- **Every new pull request** reviews each one opened on a watched repository.
  Drafts, authors you ignore (bots, by default) and changes over a size you set
  are left out.
- **Only when asked** waits for you: start a review on the **Reviews** page, or
  ask on GitHub by requesting a review from the `gh` user, adding a label
  (`agent-review` by default), or commenting a command (`/review` by default).

The plugin looks for pull requests every few minutes; **Look now** on the page
looks at once. A commit is reviewed once. With **Review new pushes** on, a pull
request is reviewed again when its head changes; with it off, it is marked as
changed since its review. A pull request you asked for a review of is followed
from then on: new pushes to it are picked up in either mode, and even if you
later take its repository out of the watched list. Discarding its review stops
following it. A re-review is told the previous review's findings, so it can say
which of them the new commits address instead of raising them again.

## Who can start a review

Only pull requests from people the repository trusts are reviewed on their own:
its owners, members and collaborators, and the logins you list under **Trusted
logins**. A pull request from anyone else, or one whose commits come from
someone else's fork, waits on the **Reviews** page, which says why. **Approve
and review** reviews it at the commit shown next to it; a later push needs another
approval, even one that pushes back to the commit you approved, and **Withdraw
approval** takes an approval back whenever it is shown. A
push while the page is open is shown there, and **Show the new commit** takes it
in before you can approve it. Asks on GitHub count only from trusted people: a
review request or a label counts when GitHub shows who made it, and not when
someone untrusted made the same ask at the same time. A review you start in HAL-C2 is always
yours to ask for.

**Reviews per author a day** and **Reviews per repository a day** hold back
reviews over the limit, across all your machines, until enough of the day's
reviews are a day old to make room; the page says until when. Reviews you start
yourself are never held back, but they count toward the limits. While one of your machines in the cluster is out of reach,
even one that has never been in reach, each machine counts only its share of the
limits, so machines apart cannot each spend the whole day's allowance; the full
limits are back once it is in reach. If a machine is gone for good, switch it
off in the cluster settings.

A new review of a pull request stops the agent of the one before it if that agent
is still working, and removes its checkout. Whatever that agent had not reported
stays in its thread only; the new review covers the whole change again.

If the reviewing agent runs into its provider's usage limit, reviews pause
until the limit resets: the review it stopped and the ones behind it wait in
the queue instead of failing one by one, and the Reviews page says so.

## Reviews in a sandbox

A review of a pull request HAL-C2 does not trust runs in a sandbox, and so does
every review with **Sandbox every review** on. HAL-C2 trusts a pull request opened
by a member or collaborator of the repository, or by one of your **Trusted logins**,
unless its commits come from someone else's fork. With the switch off, reviews of the
pull requests it trusts run on your machine. A sandbox needs
[OpenShell on the MC](openshell.md), and its agent must be Claude or Codex with an API
key; any other agent, or an MC without OpenShell, fails the review and says what to
set up.

The agent reviews a copy of the pull request's commits and has no access to your
machine, your GitHub login or HAL-C2's tools. It reaches only its model's API and
one tool to report with. The first report it sends is the review, and its sandbox
is deleted then. The Reviews page, the review's thread and its row in the thread
list say a review runs in a sandbox.

The sandbox brings its own copy of the agent, so the agent doesn't have to be
installed or signed in on the MC, and the MC's version of it doesn't matter. None
of the MC's agent settings, skills or task lists reach the sandbox, and what the
review uses counts against its API key, not your account's usage limits. The
settings list an agent's models only when it is installed on the MC, so install
it there to pick a model.

A sandboxed review is stopped, and its sandbox deleted, when it runs past
**Sandboxed review time limit** or its agent uses up **Sandboxed review token
budget**, and when you stop, discard or review it again. The budget counts what
the agent reports, so a spending limit on the API key is the firm cap. **Stop** on the Reviews page or in the
review's thread stops a running review.

## The agent and its prompt

Pick the agent, its model, what that model offers beside itself (its reasoning
effort, most of all) and its access in the settings. Each review's agent
works in a checkout of the pull request's head of its own, made from the plugin's
own copy of the repository and fetched over HTTPS with your `gh` sign-in. Your
repository is not touched, but if it runs commands it runs the pull request's code. Choose its
access with that in mind. Reviewing a pull request again removes the last
review's checkout.

The prompt is a template: `{{pr.title}}`, `{{pr.base}}`, `{{repository}}` and the
others listed under it are filled in for each pull request. How the agent
reports what it finds is added after it. **Reset to the plugin's prompt** undoes
your changes to it. Each repository can have instructions of its own, and with
**Follow REVIEW.md** the `REVIEW.md` at the pull request's head is added too.

## What happens with the findings

The agent reports a verdict, a summary, comments on lines, and what it checked.
A comment on a line the pull request does not change goes into the summary
instead. A posted review opens with the count of its findings, such as "No
findings." or "2 findings: 1 high, 1 medium". It counts the comments you kept
and those moved into the summary, which cannot be dismissed. What the agent
checked follows the summary: what it left out and why, and what this machine
kept it from running, are listed in plain view, and the commands it ran are
folded away. A check this machine kept it from running,
such as a missing tool or credential, is a setup problem: the Reviews page
shows it apart from the verdict, so you can fix it on the machine and review
again. Each
comment can say how much it matters (high, medium or low, marked 🔴 🟡 🔵 when posted, with the findings listed at a glance at the end of the review) and carry a
suggested fix, which is posted as a GitHub suggestion you can apply from the
pull request. The agent also reads the pull request's description and the
review comments already on it, so it can judge the change against what it says
it does and leave out what someone else already raised.

**Publishing** decides what reaches GitHub, for every repository or per
repository:

- **Keep in HAL-C2** never posts, and its reviews cannot be published.
- **Wait for me to publish** keeps the review until you publish it. Dismiss the
  comments you do not want first.
- **Post automatically** posts it as soon as the agent is done. A pull request
  from someone the repository does not trust waits for you to publish instead.

With **Post verdicts as comments**, a review is posted as a comment rather than
an approval or a request for changes. On your own pull requests, which GitHub
does not let you approve or request changes on, it always is. If GitHub refuses
a review, you are told why and the review keeps waiting with its comments.

**Publish** posts the review as you see it. On the **Reviews** page it first
says whether the review goes up with its verdict or as a comment; in a review's
thread it first shows the summary and comments it will post. Either way it posts
only that, and if the review changes while it is shown, it shows the new one. If it changes in the meantime,
say a comment is dismissed from another of your devices, nothing is posted and
you are asked to look again. An agent reports once per review; what it writes
mentions nobody on GitHub, shows no images and hides nothing, and a report too
long to post is sent back for the agent to shorten. A draft kept from before
code review checked reports this way is shown the same way, but is not posted:
review it again, then publish.

## Where reviews show up

**Show reviews** picks where:

- **On the Reviews page** keeps review threads out of the thread list.
- **As threads** and **Both** list them, marked with the state of their review.

Changing this moves the review threads there already are, not only new ones.

When a review is done — reported, published or failed — its thread is settled,
so finished reviews leave your active list on their own. Unsettle one to bring
it back; writing in it brings it back too. Settled reviews stay off the
**Settled** shelf so they do not bury your own threads; search and the Reviews
page still find them. Turn on **Show plugin threads in Settled** in Settings →
General (or from the command palette in the terminal client) to list them there.

A review thread stays on the machine that ran the review. The agent works in a
checkout of the pull request's code, with that machine's credentials and
sandbox, so the thread cannot be moved or exported to another machine, and
HAL-C2 says so when you try. This holds for forks of a review, and even while
Code Review is turned off or removed. Reviews started before this was the rule
stay too, but only until you remove Code Review.

The **Reviews** page is a tab next to **Threads** with every review by state, and
the picked one's verdict, summary and comments. Publish, retry, dismiss comments
or discard a review there. Discarding a review forgets it and removes its
checkout. A review's thread shows its pull request, verdict and **Publish** above
the conversation, whichever you pick.
