# Tests tagged :codex or :claude drive the real provider CLIs; run them with
# `mix test --include codex` / `--include claude`. Tests tagged :parity compare
# against Node output from real data; see HalC2.Projection.ShellParityTest.
ExUnit.start(exclude: [:codex, :claude, :parity, :backlog])

# The Gherkin specification runs only when asked for (`mix features`, or
# `HALC2_FEATURES=threads/*.feature mix test --only cucumber`), so a plain
# `mix test <file>` stays quick. `@backlog` scenarios run with `--include backlog`.
if globs = System.get_env("HALC2_FEATURES") do
  HalC2.Test.Features.compile!(String.split(globs, ","))
end
