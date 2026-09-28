# Tests tagged :codex or :claude drive the real provider CLIs; run them with
# `mix test --include codex` / `--include claude`. Tests tagged :parity compare
# against Node output from real data; see HalC2.Projection.ShellParityTest.
ExUnit.start(exclude: [:codex, :claude, :opencode, :parity, :backlog])

# The Gherkin specification runs only when asked for (`mix features`, or
# `HAL_C2_FEATURES=threads/*.feature mix test --only cucumber`), so a plain
# `mix test <file>` stays quick. `--only cucumber` includes every scenario, so
# `@backlog` scenarios always run under `mix features` and fail by design; the
# exclude below only keeps them out of `HAL_C2_FEATURES=... mix test` without
# `--only`, where `--include backlog` brings them back.
if globs = System.get_env("HAL_C2_FEATURES") do
  HalC2.Test.Features.compile!(String.split(globs, ","))
end
