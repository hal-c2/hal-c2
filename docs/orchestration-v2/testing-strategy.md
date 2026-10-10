# Testing Strategy

Orchestration is validated with a small number of high-value integration tests rather than a large suite of unit tests that mock away the behavior being tested.

The goal is not "no test doubles ever." The goal is that test doubles exist only at true process, network, clock, id, and filesystem boundaries. Core orchestration behavior must run for real.

## Testing Principle

The default test shape is:

```text
command dispatch
  -> real HalC2.Orchestration
  -> real provider runtime (HalC2.Codex, Claude, Pi, Acp)
  -> scripted fake provider process
  -> real normalizer and TurnWriter
  -> real HalC2.Store, with production persistence semantics
  -> real stream state the clients read
  -> real checkpoint policy
  -> assertions
```

The fake replaces the external provider process or network stream. It does not replace the runtime, the normalizer, the command and event infrastructure, the projections, the checkpoint policy, or the business logic. The fakes are executables under `apps/server-ex/test/support` (`fake_codex.py`, `fake_claude.py`, `fake_acp_scripted.py`, `fake_pi_rpc.py`, and others) that the runtime starts as it would the real CLI, so the process, the framing, and the shutdown path are the production ones.

## Allowed Test Substitutes

Allowed substitutes:

- the provider process or its network peer, backed by a scripted fake.
- time and ids, only where a test needs them fixed.
- temporary home, filesystem and git worktree (`HAL_C2_MC_HOME` pointing at a scratch directory).
- fake CLIs for `gh`, `adb`, `tailscale` and the like at the process boundary.
- a fake process supervisor only when it is testing process failure behavior directly.

Not allowed in integration tests:

- mocked orchestration.
- mocked provider runtime or event normalizer.
- mocked command/event infrastructure or event store.
- mocked projection or stream state.
- mocked checkpoint behavior.
- mocked provider capability policy.
- pre-normalized domain events used as the input for runtime tests.

Pure tests are still valid, but they should be few and targeted. They should test invariants of an algebra directly (`HalC2.Patch`, `HalC2.StreamState`), not replace integration coverage.

## Scripted Fakes

- A fake takes its script from the test (a config file, a turn's text, or environment), and logs every request it receives, so a test can assert what the MC sent.
- A fake keeps the provider's real protocol, ordering, and ids, including the races a real peer shows.
- A fake is deterministic. A test that needs to hold a turn open uses a gate the test controls (such as the gate files `fake_codex.py` documents) and does not sleep.
- A recorded real transcript is evidence for a fake, not a replacement for one. Redaction preserves ids, method names, lifecycle ordering, and correlation structure.

Recovery tests use the fake only at the provider process boundary. A restart is tested by stopping and restarting the MC's own processes against durable persistence. Idle cleanup and crash recovery are tested through the production lifecycle (`HalC2.Orchestration.Recovery`). Tests must not add runtime functions whose only purpose is to restart sessions for assertions.

## Waiting

The server is event-sourced and its async flows emit typed receipts and stream updates. A test waits on those, with `await_stream` and the worker drains, and never on a sleep or a poll. A test that needs a timeout to pass is wrong.

## Contract Test Levels

Recommended levels:

1. Pure tests for hard invariants and algebras.
2. Provider runtime tests from a scripted fake process to normalized entities.
3. Full orchestration integration tests from commands through a fake provider to the final stream state.
4. Property tests (`mix prop`, see `apps/server-ex/prop/README.md`) for stateful services, with a model of what the service promises.

The third level is the most important one. It is the test that catches lifecycle mismatches such as child turns closing parent runs or checkpoints being captured too early.

## Invariants Worth A Strong Test

Each of these protects a lifecycle invariant and deserves an integration test:

1. `simple`: sending one message creates one run, one root node, one provider turn, one assistant response, and one root checkpoint.
2. `multi_turn`: follow-up messages create monotonically ordered app runs on the same app thread.
3. `message_steering`: steering attaches to the active run intent instead of becoming an unrelated run.
4. `turn_interrupt`: interrupt acknowledgement does not complete the run until the provider terminal event arrives.
5. `steering_restart_fallback`: a provider without native steering interrupts the active attempt and creates a replacement attempt under the same run.
6. `subagent`: child provider turns create nested execution nodes and never complete the parent run.
7. `subagent_checkpoint`: child/subagent nodes create nested checkpoint scopes without advancing the app run count.
8. `thread_rollback`: rollback targets checkpoint scopes and reconciles provider rollback state.
9. `approval_request`: provider approval callbacks become durable runtime requests and are resolved through the real runtime path.
10. `provider_switch_return`: switching away from a provider creates a context handoff, and switching back resumes the prior provider thread with a delta handoff.

Additional tests should be added only when they protect a new invariant or reproduce a real failure mode.

## Assertions

Assertions should prefer final stream state and durable normalized events over incidental implementation calls.

Good assertions:

- duplicate command dispatch returns the original receipt without replaying provider transport.
- store sequence monotonicity.
- catch-up from an offset yields what live delivery would have.
- run status and ordinal.
- active/final run attempt.
- execution node parent/child structure.
- provider thread and provider turn correlation.
- checkpoint scope hierarchy.
- pending/resolved runtime requests.
- handoff coverage and strategy.

Weak assertions:

- exact internal function call counts.
- private helper invocation order.
- mocked callback arguments below the runtime boundary.
