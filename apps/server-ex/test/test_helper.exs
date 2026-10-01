# Tests tagged :codex or :claude drive the real provider CLIs; run them with
# `mix test --include codex` / `--include claude`. Tests tagged :parity compare
# against Node output from real data; see HalC2.Projection.ShellParityTest.
ExUnit.start(exclude: [:codex, :claude, :opencode, :parity, :backlog])

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
