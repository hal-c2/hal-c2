# TokenEconomizer

Spends fewer tokens on the same work. Its loop guard watches every turn's tool calls
and, when an agent keeps repeating the same failing edit and check, redirects it once
and offers you a stop if it still does not recover. What counts as stuck is learned
per project from turns that ended green. Its tool pruning counts the tools a
project's conversations had loaded and never used, and once the evidence is enough
turns them off from the next conversation — by itself under `auto` once the project
has been quiet a while, or when you apply the proposal under `propose` — and gives
them back when you restore them, for good unless you apply them by name. What it
does, scenario by scenario, is in
[features/plugins/token-economizer-loop-guard.feature](../../features/plugins/token-economizer-loop-guard.feature)
and
[features/plugins/token-economizer-tool-prune.feature](../../features/plugins/token-economizer-tool-prune.feature).

It is a port of Microsoft's [TokenEconomizer](https://github.com/microsoft/TokenEconomizer)
and, unlike the other packages here, is licensed under the Apache License 2.0
([LICENSE](LICENSE), [NOTICE](NOTICE)). Each file in `mc/` names what it was ported
from and what changed.

It is an ordinary MC plugin and needs nothing from this repository but the plugin
API: copy the folder into an MC's `plugins` folder to install it.

## The package

- `plugin.json`: the name, description, the permissions it asks for and why, and
  its settings.
- `mc/`: the MC part. `token_economizer.ex` is the plugin's process: it hears turns,
  keeps each one's guard, runs the judge's jobs, delivers redirects and notices, and
  shapes each new conversation for tool pruning.
  The `loop_guard_*.ex` files are the guard itself, pure and ported from upstream:
  what a call means (`state`, `shell_edits`), when a turn looks stuck (`rules`), a
  turn's guard (`turn`), what a project learned (`envelope`) and the judge (`judge`).
  `tool_prune_evidence.ex` is tool pruning's evidence and decisions, pure likewise.
- `assets/`: the icon.

The `toolPrune` topic, and the calls `toolPrune`, `toolPruneApply` and
`toolPruneRestore` (each taking a `projectId`, a `provider`, and tools by name to
apply or restore just those), carry what is off, proposed and kept per project,
with the evidence for each tool — what the plugin's page and settings show and
drive. Their `unresolved` lists the threads whose turns the plugin heard only in
part and could not read back yet: while there are any, the project's new
conversations are turned off nothing. So does a thread whose subagent used a tool
the plugin heard with no project, until the thread's next turn names it. A deleted
thread leaves that list. One
moved to another machine is listed under `away` instead, and holds nothing off
while it is there; once it is moved back, its turns are read back before
anything is turned off again.

## Tests

From `apps/server-ex`:

- the MC scenarios: `mise exec -- mix features plugins/token-economizer-loop-guard.feature plugins/token-economizer-tool-prune.feature`;
- upstream's tests, ported: `mise exec -- mix test test/hal_c2/token_economizer_loop_guard_test.exs test/hal_c2/token_economizer_tool_prune_test.exs`;
- a state machine of one turn's guard, and of tool pruning's evidence: `mise exec -- mix prop prop/hal_c2/token_economizer_prop_test.exs prop/hal_c2/token_economizer_tool_prune_prop_test.exs`;
- a Maude model of the plugin hearing a thread's turns, with a feed that may miss
  events, late or lost verdicts and redirects delivered late or refused:
  `mise exec -- mix proof proof/hal_c2/token_economizer_loop_guard_proof_test.exs`;
- a Maude model of tool pruning over conversations, applies, restores, mode
  changes, quiet spells and plugin restarts:
  `mise exec -- mix proof proof/hal_c2/token_economizer_tool_prune_proof_test.exs`.
