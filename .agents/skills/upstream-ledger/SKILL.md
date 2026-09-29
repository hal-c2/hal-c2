---
name: upstream-ledger
description: Turn pull requests merged into upstream T3 Code (pingdotgg/t3code) into Gherkin scenarios in features/, so HAL-C2 keeps its behaviour while rewriting the code. Use when asked to catch up with upstream, ledger upstream changes, or run the scheduled upstream job.
---

# Ledger upstream T3 Code

HAL-C2 rewrites T3 Code, so upstream code does not port. Its behaviour does, and the
behaviour is ledgered in `features/` (read `features/README.md` first). This job reads what
upstream merged and records each behaviour HAL-C2 should have, already has, or declines.

## Get the batch

```bash
mise run upstream --limit 10        # the next 10 PRs after features/UPSTREAM, oldest first
mise run upstream --brief           # everything still to review, one line each
mise run upstream <from>..<to>      # an explicit upstream range
```

The digest prints each pull request's description, the areas it touched, any feature files
already citing it, and the commit to write to `features/UPSTREAM` when the batch is done.
Read the diff (`gh pr diff <n> --repo pingdotgg/t3code`) only when the description does not
say what a user can now do or observe.

If a previous upstream-ledger PR is still open, branch from its head and target it as the
base. Its `features/UPSTREAM` is already advanced, so the digest continues where it stopped.

## Decide each pull request

Every pull request gets exactly one disposition:

- **carry**: new or changed behaviour HAL-C2 should have. Write or edit scenarios.
- **covered**: the ledger already says it. Add the PR URL to that file's `# Sources:`. If
  upstream changed the behaviour, change the scenario, and mark it `@backlog` only if the
  node or QML no longer does what it now says.
- **drop**: behaviour HAL-C2 decides not to have. Write it as a `@dropped` scenario with the
  reason in a comment, so the decision can be reviewed.
- **skip**: nothing user-observable. CI, release and build tooling, tests, refactors,
  store screenshots, upstream's hosting and analytics, and visual polish of the legacy
  web or React Native UI (alignment, spacing, icons). Write nothing.

A fix to the legacy clients can still carry: "the draft survives a reconnect" is behaviour
every HAL-C2 client owes, whichever codebase upstream fixed it in. A performance fix carries
only when it states a budget a client can be tested against.

## Write scenarios like the rest of the ledger

These are the mistakes the first upstream batch (hal-c2/hal-c2#10) made and review caught:

- **File by behaviour, never by source.** Put each scenario in the domain file where the
  behaviour lives (`threads/`, `providers/claude.feature`, ...). No `upstream-*.feature`.
- **Search before writing.** `grep -rn` the ledger for the behaviour's nouns. Re-adding a
  scenario that already passes, tagged `@backlog`, makes the ledger contradict itself.
- **One behaviour per scenario.** Do not bundle an invariant the node already passes with a
  new one; the combined scenario gets the wrong status. Split it.
- **Status from evidence.** No status tag only when you ran it and it passes
  (`mise run features:node <file>`). Otherwise `@backlog`.
- **Every surface tag that applies.** Anything a user sees needs client tags (`@shared`, or
  `@desktop` / `@mobile` / `@tui`), not only `@node`, or the client runners never select it.
- **Existing plugin ids only.** `grep -rhoE '@plugin-[a-z0-9-]+' features | sort -u` lists
  them. Provider-specific behaviour carries its plugin tag; do not invent a family tag.
- **Declarative.** What the user does and observes, never widgets or layout, per the README.
- **Cite the pull request**, `https://github.com/pingdotgg/t3code/pull/<n>`, in the file's
  `# Sources:` block, not commit hashes.
- **No review register.** Nothing under `docs/`. The PR description is the record.

## Finish

1. Write the digest's commit to `features/UPSTREAM`.
2. Run `mise run features:node <each touched file>` (and `mise run features:tui <file>` for
   files with `@tui` or `@shared` scenarios). They parse the files and keep passing scenarios
   passing. If mix deps are missing, `mise run install:node` first.
3. Commit as `test(features): ledger upstream T3 Code through <short sha>`. When asked for a
   PR, its description is one table row per upstream pull request: number and title,
   disposition, and the scenario or reason in a few words.
