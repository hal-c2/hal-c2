# Property tests

Stateful property tests of the Qt clients' C++, written with
[RapidCheck](https://github.com/emil-e/rapidcheck) (BSD-2-Clause, fetched by
`cmake/RapidCheck.cmake`; only these tests link it). The desktop's live here, the
phone's in `apps/mobile-qt/tests/prop` on the same harness:

```sh
mise prop:desktop                              # every desktop property
mise prop:desktop SidebarProp                  # one
mise prop:mobile                               # the phone's
RC_PARAMS="max_success=1000" mise prop:desktop # a longer soak
RC_PARAMS="verbose_progress=1" mise prop:desktop
```

A failed property prints its shrunk command sequence and a `reproduce` string;
`RC_PARAMS="reproduce=<string>"` replays exactly that case, so a fix is checked
against the case that found the bug.

## What gets a property test

A class whose behaviour depends on the order of calls and messages it gets: the MC
client and its reconnects, the local cache, the thread and shell stores, the
sidebar and timeline models, the composer and its drafts, terminals, keybindings,
pairing. The test is a model of what the class promises, and RapidCheck looks for a
sequence of calls on which the real thing disagrees.

Pure functions with a law (a parser and its printer, a merge) get plain
`rc::check` properties stating it, in the same file as their class's model.

A bug a property finds also gets a focused regression test, plain QtTest, in
`tests/native/tst_<Name>Regression.cpp` (the phone's in
`apps/mobile-qt/tests`), or a scenario under `features/` when it is behaviour a
user sees. The native tests pick those files up, so the ordinary suite keeps
the bug fixed; the property build compiles them too, so they run without the
terminal.

## How to write one

Each `tst_<Name>Prop.cpp` here is a test executable of its own, picked up on the
next build (`cmake/GlobTests.cmake`). Sources it needs beyond `hal_c2_native`
(the fake MC, `../native/features/FakeMc.cpp`, for one) are listed one per line
in `tst_<Name>Prop.sources` beside it. `Prop.h` gives the main (`HAL_C2_PROP_MAIN`),
which points HOME, the XDG directories and `HAL_C2_HOME` at a temporary directory
before Qt starts.

A state machine test is a model struct, the class under test (or a small struct
holding it and its fakes), and one `rc::state::Command<Model, Sut>` per call:

- `checkPreconditions` must hold for a command to be generated or kept while
  shrinking, so a command on an existing thread checks the model has one.
- `apply` changes the model; `run` calls the real class and `RC_ASSERT`s what the
  model says it should now show. `run` is handed the model as it was before the
  command, so copy it and `apply` the copy to get the expected state. Keep the
  model as small as the promise: plain structs and Qt containers, never a copy of
  the implementation.
- Members are generated in the command's constructor
  (`*rc::gen::inRange(0, 4)`), from the model it is given. Keep them small and
  printable (`show`); they are what a shrunk counterexample shows.
- `RC_ASSERT` and `RC_PRE` take their expression apart to print it, overloading
  `&&` and `||`, so neither short-circuits: `RC_ASSERT(found && found->ok)`
  dereferences an empty `found`. Assert the guard first, then what it guards.
- Draw ids from small pools (`rc::gen::elementOf`) so commands collide, and bound
  nested generators (`rc::gen::resize`, `rc::gen::container(n, ...)`).
- Include the events that break things in production: the MC dropping and
  coming back, a reply arriving after its caller moved on, a restart reading the
  cache back, a window closing.

Run it with `rc::state::check(model, sut, rc::state::gen::execOneOfWithArgs<...>())`
inside `QVERIFY(rc::check("...", [] { ... }))`, one QtTest slot per property.

Asynchronous work is waited on with the signals the class already emits
(`halc2::prop::await`), or `halc2::prop::until` on what it exposes, never with
sleeps. A property that needs a sleep to pass is wrong. Never let a test open a
real HAL-C2 home, bind a fixed port, or start a real MC: the fake MC in
`../native/features` listens on a free port.
