defmodule HalC2.Test.McHooks do
  @moduledoc """
  Every `@mc` scenario runs on its own fresh MC (`HalC2.Test.Mc.start/1`).
  Steps find it under `context.mc` and keep sockets under `context.clients`
  (name → `HalC2.Test.WsClient`), with `"default"` as the unnamed client.
  """
  use Cucumber.Hooks

  before_scenario context do
    dir =
      Path.join(
        System.tmp_dir!(),
        "hal-c2-features-#{System.unique_integer([:positive])}-#{:erlang.phash2(context.scenario_name)}"
      )

    mc = HalC2.Test.Mc.start(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
    {:ok, Map.merge(context, %{mc: mc, clients: %{}, projects: %{}, threads: %{}})}
  end
end
