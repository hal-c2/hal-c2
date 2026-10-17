defmodule HalC2.Test.GitEnv do
  @moduledoc """
  Keeps an MC's git include out of the tests (`mix test`, `mix features`, `mix prop`).

  An agent inside an MC runs them with the MC's git include in its environment
  (`GIT_CONFIG_COUNT`/`KEY_n`/`VALUE_n`, `HalC2.Git.use_gh_for_github/0`). It would
  rewrite the fake GitHub remotes the tests use into real HTTPS ones.
  """

  @doc "Drops the inherited git include from this VM's environment; called from the test helpers."
  def scrub do
    System.get_env()
    |> Map.keys()
    |> Enum.filter(&(&1 =~ ~r/^GIT_CONFIG_(COUNT|KEY_\d+|VALUE_\d+)$/))
    |> Enum.each(&System.delete_env/1)
  end
end
