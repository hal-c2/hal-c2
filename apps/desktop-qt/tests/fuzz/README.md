# Fuzz tests

Fuzz tests of the Qt clients' C++, written with
[FuzzTest](https://github.com/google/fuzztest) (Apache-2.0, fetched by
`cmake/FuzzTest.cmake`; only these tests link it). The engine generates inputs
and keeps the ones that reach new code. It looks for crashes, hangs, undefined
behaviour and memory errors, and for broken assertions in the test.

```sh
mise fuzz:desktop                              # every FUZZ_TEST, FUZZ_FOR (30s) each
mise fuzz:desktop KeybindingsFuzz              # one executable
mise fuzz:desktop Keybindings.RulesResolve     # one test
FUZZ_FOR=10m mise fuzz:desktop TimelineModel   # a longer run of one suite
mise fuzz:valgrind desktop                     # unit-test mode under Memcheck
mise fuzz:valgrind desktop TimelineModelFuzz
```

`FUZZ_STACK_KB` (8192, the main thread's stack) is the stack limit of every
run; fuzztest's own default is 128 KB, which reports deep but legitimate
recursion as a crash.

There are two builds of the same files:

- `fuzz:desktop` builds `build/fuzz` with Clang, coverage instrumentation,
  ASan, LSan and UBSan, and fuzzes each test (`--fuzz`). It needs `clang++`.
- `fuzz:valgrind` builds `build/fuzz-valgrind` in unit-test mode, with no
  instrumentation and `-O1 -g`, and runs each executable under Memcheck
  (`tests/valgrind/memcheck.sh`, the same launcher and suppressions as
  `prop:valgrind`). Each test replays the corpus database, its regressions and
  its seeds, then `FUZZ_FOR` (10s) of random inputs. It fails on invalid
  accesses, uninitialised reads, and definite or indirect leaks. Each report is
  `build/fuzz-valgrind/valgrind/<exe>.log`.

`mise fuzz:mobile` and `mise fuzz:valgrind mobile` run `apps/mobile-qt/tests/fuzz`
the same way. The phone has no fuzz tests yet: its own C++ reads camera frames
through zxing-cpp, and the code it shares with the desktop is fuzzed here. The
first phone fuzz test gets a `CMakeLists.txt` like this one's, with its includes
and libraries.

## What gets a fuzz test

Code that reads what this process did not write:

- what the MC sends, such as stream frames, RPC results and pushes;
- what a user writes by hand, such as `keybindings.json`, a `.hal-c2` project
  file or a pairing link;
- what another program hands over, such as diffs, terminal output and images.

Parsers are the cheapest targets. A parser that has a printer also gets the
law: what it writes reads back the same. Stateful classes are fed sequences of
messages. They must not crash, and what they then show must still read.

Behaviour that depends on the order of calls is a property test's job
(`tests/prop`). Many targets want both.

## How to write one

1. Add `tst_<Name>Fuzz.cpp` here. It is picked up on the next build
   (`cmake/GlobTests.cmake`). Each file is one executable, and the ctest name
   is `<Name>Fuzz`. Sources it needs beyond `hal_c2_native` go one per line in
   `tst_<Name>Fuzz.sources` beside it, relative to this directory (for example
   `../native/features/FakeMc.cpp`). `FuzzMain.cpp` is the main of every
   executable. Before any test runs, it points HOME, the XDG directories and
   `HAL_C2_HOME` at a temporary directory and starts an offscreen
   `QGuiApplication`.
2. Include `Fuzz.h` and the header under test. Write a function in an anonymous
   namespace that takes the inputs, and register it with
   `FUZZ_TEST(<Suite>, <Test>)`. The suite is the class or namespace under
   test. The fully qualified name, such as `Keybindings.RulesResolve`, is what
   the tasks and the corpus use.
3. Choose domains with `Fuzz.h`:
   - `fuzz::Text(words)` gives arbitrary bytes that splice in `words`.
     `fuzz::Word(words)` gives one of `words` as it is, or such bytes.
     Feed both through `fuzz::utf8()`, or through `fuzz::utf16()` for text
     with lone surrogates.
   - `fuzz::Json(keys, texts)` gives a `fuzz::JsonSteps`. Read it with
     `fuzz::object()` or `fuzz::array()`. Every step list reads as some JSON,
     so mutations stay message-shaped.
   - `fuzztest::VectorOf(fuzz::Json(...)).WithMaxSize(n)` gives a sequence of
     messages.

   Take the dictionaries from the string literals in the code under test.
   Qt is not instrumented, so the engine cannot learn the words Qt compares
   with.

4. Add seeds that reach deep code: real messages in the shape the MC sends,
   written as JSON. Use `.WithSeeds({{"mod+k"}, ...})` for plain values. For
   JSON, use the lazy form, since `fuzz::steps()` needs Qt:
   `.WithSeeds([] { return std::vector<std::tuple<...>>{{fuzz::steps(R"j({...})j"), ...}}; })`.
   `fuzz::messages({...})` builds a sequence. A seed that is not valid JSON
   aborts, so a typo cannot quietly seed nothing. Use `R"j(...)j"` when the
   JSON holds `)"`.
5. Check the laws with `ASSERT_*` and `EXPECT_*`, and print Qt values with
   `.toStdString()`. Call `fuzz::print(value)` on the message you build: it
   writes the value only under `HAL_C2_FUZZ_PRINT=1`, so a reproducer can be
   read. Call `fuzz::settle()` to run posted events and deferred deletes.
6. Keep each input cheap. Hundreds of runs a second is the floor. Skip work
   that cannot change from input to input (see `RulesResolve` and the
   defaults).
7. Run `mise fuzz:desktop <Name>Fuzz`, then `mise fuzz:valgrind desktop <Name>Fuzz`.

`tst_KeybindingsFuzz.cpp` (a parser and its printer, plain and JSON input) and
`tst_TimelineModelFuzz.cpp` (stream frames into a stateful model) are the
patterns.

## The corpus, and what a crash becomes

`FUZZ_CORPUS` (default `build/fuzz-corpus`, gitignored) holds
`<exe>/<Suite.Test>/`, with three directories:

- `coverage` holds the inputs that reached new code. Fuzzing starts from them,
  and `fuzz:valgrind` replays them.
- `crashing` holds the reproducers of failures.
- `regression` holds the inputs you keep. Both builds replay them on every run.

When a test fails, `fuzz:desktop` prints the error, the reproducer, and the
commands to replay it:

```sh
FUZZTEST_REPLAY=<reproducer> apps/desktop-qt/build/fuzz/tst_<Name>Fuzz --fuzz=<Suite.Test>
HAL_C2_FUZZ_PRINT=1 FUZZTEST_REPLAY=<reproducer> ...   # with the input printed
```

To fix the bug:

1. Copy the reproducer into `regression/` so both builds replay it.
2. Write the input out as a plain QtTest in
   `tests/native/tst_<Name>Regression.cpp` (the phone's in `apps/mobile-qt/tests`),
   minimised by hand to the few messages that matter. Use a scenario under
   `features/` instead when it is behaviour a user sees.
3. Fix the code. The regression test keeps it fixed in the ordinary suite.
   The corpus is local, so it is not what keeps a bug fixed.
