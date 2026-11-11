HalC2.Test.StopSignal.fail_run()

# A machine's own shell startup is not a test's: it may outlast a wait. A test that cares sets its own.
System.put_env("SHELL", "/bin/sh")

# Tests tagged :codex or :claude drive the real provider CLIs; run them with
# `mix test --include codex` / `--include claude`. Tests tagged :parity compare
# against output HAL-C2 produced before the MC, from real data; see
# HalC2.Projection.ShellParityTest.
# `HAL_C2_TEST_SLOWEST=25` ends the run with the 25 slowest tests and modules.
slowest = if HalC2.Test.SlowestFormatter.count() > 0, do: [HalC2.Test.SlowestFormatter], else: []

ExUnit.start(
  exclude: [:codex, :claude, :opencode, :parity, :backlog],
  formatters: [ExUnit.CLIFormatter | slowest]
)

# Keep the MC's git include, if we run inside one, out of the tests.
HalC2.Test.GitEnv.scrub()

# `tmp` holds the tests' scratch folders and sits inside the checkout: git must not find
# the checkout from them, or a git action under test would commit and push the developer's work.
System.put_env("GIT_CEILING_DIRECTORIES", Path.expand("../tmp", __DIR__))

# The Gherkin specification runs only when asked for (`mix features`, or
# `HAL_C2_FEATURES=threads/*.feature mix test --only cucumber`), so a plain
# `mix test <file>` stays quick. `@backlog` and `@backlog-mc` scenarios are left out unless
# HAL_C2_FEATURES_BACKLOG=1 (`mix features --backlog`): they name behaviour the
# MC does not have yet, and fail until it does.
if globs = System.get_env("HAL_C2_FEATURES") do
  HalC2.Test.Features.compile!(String.split(globs, ","),
    backlog: System.get_env("HAL_C2_FEATURES_BACKLOG") in ["1", "true"]
  )
end
