defmodule HalC2.Test.NodeHooks do
  @moduledoc """
  Every `@node` scenario runs on its own fresh node (`HalC2.Test.Node.start/1`).
  Steps find it under `context.node` and keep sockets under `context.clients`
  (name → `HalC2.Test.WsClient`), with `"default"` as the unnamed client.
  """
  use Cucumber.Hooks

  before_scenario context do
    dir =
      Path.join(
        System.tmp_dir!(),
        "hal-c2-features-#{System.unique_integer([:positive])}-#{:erlang.phash2(context.scenario_name)}"
      )

    node = HalC2.Test.Node.start(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
    {:ok, Map.merge(context, %{node: node, clients: %{}, projects: %{}, threads: %{}})}
  end
end
