defmodule T3.Test.NodeHooks do
  @moduledoc """
  Every `@node` scenario runs on its own fresh node (`T3.Test.Node.start/1`).
  Steps find it under `context.node` and keep sockets under `context.clients`
  (name → `T3.Test.WsClient`), with `"default"` as the unnamed client.
  """
  use Cucumber.Hooks

  before_scenario context do
    dir =
      Path.join(
        System.tmp_dir!(),
        "t3-features-#{System.unique_integer([:positive])}-#{:erlang.phash2(context.scenario_name)}"
      )

    node = T3.Test.Node.start(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
    {:ok, Map.merge(context, %{node: node, clients: %{}, projects: %{}, threads: %{}})}
  end
end
