# Tests tagged :codex or :claude drive the real provider CLIs; run them with
# `mix test --include codex` / `--include claude`. Tests tagged :parity compare
# against output HAL-C2 produced before the MC, from real data; see
# HalC2.Projection.ShellParityTest.
ExUnit.start(exclude: [:codex, :claude, :opencode, :parity, :backlog])

# An agent inside an MC runs this with the MC's git include in its environment
# (GIT_CONFIG_COUNT/KEY_n/VALUE_n, `HalC2.Git.use_gh_for_github/0`). It would rewrite
# the fake remotes the scenarios push to into real GitHub HTTPS ones.
for {name, _} <- System.get_env(),
    name =~ ~r/^GIT_CONFIG_(COUNT|KEY_\d+|VALUE_\d+)$/,
    do: System.delete_env(name)

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
