# Agent code review

The code-review plugin has an agent of your choice review pull requests on the
repositories you pick. You decide when a review starts, what the agent is told,
and whether what it finds is posted to the pull request, waits for you, or stays
in HAL-C2.

It runs on an MC, like any [plugin that runs on your MC](plugins.md#plugins-that-run-on-your-mc).
Each machine reviews the repositories of its own projects, with its own agents.

## Start

1. Put the `code-review` folder in the MC's `plugins` folder and turn it on in
   **Settings → Plugins**. It asks to read and comment on pull requests, start
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
changed since its review.

## The agent and its prompt

Pick the agent, its model and its access in the settings. Each review's agent
works in a checkout of the pull request's head of its own, so your checkout is
not touched, but if it runs commands it runs the pull request's code. Choose its
access with that in mind. Reviewing a pull request again removes the last
review's checkout.

The prompt is a template: `{{pr.title}}`, `{{pr.base}}`, `{{repository}}` and the
others listed under it are filled in for each pull request. How the agent
reports what it finds is added after it. **Reset to the plugin's prompt** undoes
your changes to it. Each repository can have instructions of its own, and with
**Follow REVIEW.md** the `REVIEW.md` at the pull request's head is added too.

## What happens with the findings

The agent reports a verdict, a summary and comments on lines. A comment on a
line the pull request does not change goes into the summary instead.

**Publishing** decides what reaches GitHub, for every repository or per
repository:

- **Keep in HAL-C2** never posts, and its reviews cannot be published.
- **Wait for me to publish** keeps the review until you publish it. Dismiss the
  comments you do not want first.
- **Post automatically** posts it as soon as the agent is done.

With **Post verdicts as comments**, a review is posted as a comment rather than
an approval or a request for changes. On your own pull requests, which GitHub
does not let you approve or request changes on, it always is. If GitHub refuses
a review, you are told why and the review keeps waiting with its comments.

## Where reviews show up

**Show reviews** picks where:

- **On the Reviews page** keeps review threads out of the thread list.
- **As threads** and **Both** list them, marked with the state of their review.

The **Reviews** page is a tab next to **Threads** with every review by state, and
the picked one's verdict, summary and comments. Publish, retry, dismiss comments
or discard a review there. Discarding a review forgets it and removes its
checkout. A review's thread shows its pull request, verdict and **Publish** above
the conversation, whichever you pick.
