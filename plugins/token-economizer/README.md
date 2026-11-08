# TokenEconomizer

Spends fewer tokens on the same work. Its loop guard watches every turn's tool calls
and, when an agent keeps repeating the same failing edit and check, redirects it once
and offers you a stop if it still does not recover. What counts as stuck is learned
per project from turns that ended green. Its micro-skills learn short facts about a
project's environment from those turns -- which way of running the tests works here,
which tool is not installed -- and state them at the start of a new conversation.
What they do, scenario by scenario, is in
[features/plugins/token-economizer-loop-guard.feature](../../features/plugins/token-economizer-loop-guard.feature)
and [features/plugins/token-economizer-micro-skills.feature](../../features/plugins/token-economizer-micro-skills.feature).

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
  keeps each one's guard, runs the judge's jobs, delivers redirects and notices,
  folds each finished turn into its project's micro-skills and states them as a
  conversation starts. The `loop_guard_*.ex` files are the guard itself, pure and
  ported from upstream: what a call means (`state`, `shell_edits`), when a turn
  looks stuck (`rules`), a turn's guard (`turn`), what a project learned
  (`envelope`) and the judge (`judge`). The `micro_skills_*.ex` files are the
  micro-skills, also pure: what a turn shows about its environment (`observe`),
  a fact's formation and retirement (`lifecycle`) and the facts themselves
  (`envfacts`). The plugin calls `microSkills`, `microSkills.drop` and
  `microSkills.restore` show a project's facts with their evidence, drop one so
  it is never learned again, and restore it; the `microSkills` topic carries the
  same listing as facts change.
- `assets/`: the icon.

## Tests

From `apps/server-ex`:

- the MC scenarios: `mise exec -- mix features plugins/token-economizer-loop-guard.feature plugins/token-economizer-micro-skills.feature`;
- upstream's tests, ported: `mise exec -- mix test test/hal_c2/token_economizer_loop_guard_test.exs test/hal_c2/token_economizer_micro_skills_test.exs`;
- a state machine of one turn's guard: `mise exec -- mix prop prop/hal_c2/token_economizer_prop_test.exs`;
- a state machine of the micro-skills' lifecycle laws: `mise exec -- mix prop prop/hal_c2/token_economizer_micro_skills_prop_test.exs`;
- a Maude model of the plugin hearing a thread's turns, with a feed that may miss
  events, late or lost verdicts and redirects delivered late:
  `mise exec -- mix proof proof/hal_c2/token_economizer_loop_guard_proof_test.exs`.
