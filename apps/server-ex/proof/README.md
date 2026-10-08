# Proofs

Models of the MC's distributed protocols in [Maude](https://maude.cs.illinois.edu),
model checked through [ex_maude](https://hex.pm/packages/ex_maude). They run in their
own Mix environment, so neither reaches `lib/` or the MC that ships:

```sh
mix proof                                         # every proof
mix proof proof/hal_c2/thread_move_proof_test.exs # one model
MAUDE_PATH=/opt/maude/maude mix proof             # a Maude of your own
```

`mix proof` installs Maude into `_build/maude` the first time, unless `MAUDE_PATH`
names one. `mise run proof [files]` does the same from anywhere in the repository.

## What a proof is for

A property test (`prop/`) runs the real code on sequences of calls PropEr samples, so it
finds bugs in the code as written, but only on the cases it happens to draw. A proof
runs a model of the code on every interleaving up to a bound: every order of messages
between MCs, a crash or a partition at every step, every timeout. That is where a
protocol across machines goes wrong, and where sampling rarely looks. A proof checks:

- safety: no reachable state is bad (`refute_reachable`);
- liveness under fairness: what starts eventually ends, given that the code's steps
  are taken while they can be and that crashes restart and partitions heal
  (`assert_ltl`);
- deadlock freedom: no reachable state is stuck with work left (`refute_deadlock`).

A model is only as good as its likeness to the code, so a proof also checks that it
still covers the code (below). Use a proof for a protocol between processes or
machines; keep using properties for one service's behaviour.

## The introspection rule

Every proof declares which facts of the code its model covers, and the suite fails
when they drift apart. `HalC2.Proof` reads the code's facts: exported functions,
the messages a GenServer handles, the keys of its state, the stages of a hook, the
atoms of a type. Each must be mapped to a rule or an op of the model (`covers`), or
listed with the reason it does not matter to what is proven (`abstracts`). A new
message or state in the code fails the suite and names what is missing, and so does
a mapping to a rule the model no longer has, or a model rule nothing maps to (rules
for the environment, such as `crash`, are listed in `environment`). Every proof also
names the scenarios in `features/` it proves, and fails when one is renamed away.

When the code changes, change the model with it: a mapping updated without the
model is a proof of something else.

## Reading a counterexample

A failed `refute_reachable` prints the rule labels from the initial state to the bad
one, then each state on the way. A failed `assert_ltl` prints the labels of a path
and of the loop it ends in, repeated forever, then the loop's first state. Labels are
the model's rule labels, each named after the function it models (`taking` is
`taking/2`), so read the trace against the code. A bug a proof finds gets a plain
regression test in `test/`, and the property is never weakened to pass.

## License

ex_maude is MIT and this directory is the MC's license too. Maude is GPL, but runs as a
program of its own that ex_maude talks to over a pipe, is installed at test time and is
never shipped, so nothing here needs a license of its own (compare `prop/`, which
compiles PropCheck in).
