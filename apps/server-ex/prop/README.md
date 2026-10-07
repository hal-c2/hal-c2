# Property tests

Stateful property tests of the MC's core, written with
[PropCheck](https://hexdocs.pm/propcheck) (an Elixir front end to PropEr). They are
GPL-3.0 because PropCheck is ([LICENSE.md](LICENSE.md)), so they live here, apart
from the MIT suite in `test/`, and run in their own Mix environment:

```sh
mix prop                                  # every property
mix prop prop/hal_c2/store_prop_test.exs  # one file
PROPCHECK_NUMTESTS=1000 mix prop          # a longer soak
PROPCHECK_VERBOSE=1 mix prop              # progress and the command distribution
MIX_ENV=prop mix propcheck.clean          # forget stored counterexamples
```

A failed property stores its counterexample (`_build/propcheck.ctex`) and the next run
tries it first, so a fix is checked against the case that found the bug. Clean it
when the generator, not the code, was wrong.

## What gets a property test

A process or module whose behaviour depends on the order of calls made to it: the
event log, the stream servers and their subscribers, the sidebar shell, orchestration
commands on a thread, sessions and tokens, settings and their versions, scheduled
tasks, terminals, thread moves. The test is a model of what the service promises,
and PropEr looks for a sequence of calls on which the real thing disagrees.

Pure functions with an algebra (`HalC2.Patch.compose/2`, `HalC2.StreamState`) get
plain `forall` properties stating the law, in the same directory.

A bug a property finds also gets a focused regression test in `test/` (plain ExUnit,
no PropCheck), so the MIT suite keeps it fixed without this directory.

## How to write one

`prop/hal_c2/store_prop_test.exs` is the reference. A state machine test is one
module that is both the ExUnit case and the `:proper_statem` callback module:

- `initial_state/0`, `command/1`, `precondition/2`, `next_state/3` and
  `postcondition/3` describe the model. Keep the model as small as the promise:
  plain maps and lists, never a copy of the implementation.
- Commands call wrapper functions in the test module (`{:call, __MODULE__, :append,
[...]}`), which call the real API. Keep arguments small and printable; they are
  what a shrunk counterexample shows.
- `next_state/3` runs twice, symbolically during generation (results are
  `{:var, n}`) and for real during execution. Never inspect a result there except to
  store it opaquely.
- `precondition/2` must hold for a command to be generated or kept while shrinking,
  so commands that need an existing thread check the model has one.
- Draw ids from small pools (`HalC2.Prop.Generators`) so commands collide. A
  generator over nested collections must bound its sizes with `resize/2`: PropEr grows
  the size with every case, and unbounded nesting stalls generation without failing.
- Include the events that break things in production: restarts of the service
  (`HalC2.Prop.restart_service/1`), crashes of a subscriber, concurrent callers
  (`parallel_commands/1` once the sequential model passes), time passing.

PropEr runs each case in a process of its own, where ExUnit's `start_supervised` is
unavailable. Start the services a case needs with `HalC2.Prop.start_services/1` and
stop them with `HalC2.Prop.stop_services/0` before the case returns, and point the
MC at a fresh directory with `HalC2.Prop.scratch_home/1`. Never let a test open a
real HAL-C2 home, bind a fixed port, or start Erlang distribution on a cluster port.

Asynchronous services are waited on with the receipts and messages they already
send (a subscription's `{:live, seq}`, a watcher's notification), never with sleeps.
A property that needs a sleep to pass is wrong.

Wrap the run in `trap_exit` and report through `when_fail(HalC2.Prop.report(...))`, and
`aggregate(command_names(cmds))` so `PROPCHECK_VERBOSE=1` shows whether every command
is actually exercised.
