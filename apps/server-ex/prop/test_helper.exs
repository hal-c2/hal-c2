# The stateful property tests (`mix prop`), GPL-3.0 (LICENSE.md). See README.md for
# what belongs here and how to write one.
#
# PROPCHECK_NUMTESTS raises or lowers the number of cases every property runs, such
# as 1000 before a release or 20 while writing a model.
ExUnit.start(exclude: [:slow])

# An agent inside an MC runs this with the MC's git include in its environment
# (GIT_CONFIG_COUNT/KEY_n/VALUE_n, `HalC2.Git.use_gh_for_github/0`). It would rewrite
# the fake remotes the scenarios push to into real GitHub HTTPS ones.
for {name, _} <- System.get_env(),
    name =~ ~r/^GIT_CONFIG_(COUNT|KEY_\d+|VALUE_\d+)$/,
    do: System.delete_env(name)
