defmodule HalC2.LiveSteerTest do
  # Steers a real provider turn the way the Qt composer does: `message.dispatch` with
  # `deliveryIntent: "steer"` and `start_immediately`. Drives the real CLIs; run with
  # `mix test test/hal_c2/live_steer_test.exs --include claude --include codex --include opencode`.
  use ExUnit.Case, async: false

  alias HalC2.StreamState
  alias HalC2.Test.Node
  alias HalC2.Test.Node.World

  @moduletag timeout: 300_000

  setup %{tmp_dir: dir} do
    node = Node.start(dir)
    # What `World.agents/1` starts, without swapping in its fake CLIs.
    for name <- [HalC2.Codex.Registry, HalC2.Claude.Registry, HalC2.Acp.Registry],
        do: Node.ensure(Supervisor.child_spec({Registry, keys: :unique, name: name}, id: name))

    Node.ensure(HalC2.Settings)
    Node.ensure({DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one})
    {:ok, context: %{node: node, clients: %{}, projects: %{}, threads: %{}, agents: true}}
  end

  @tag :tmp_dir
  @tag :claude
  test "claude takes a steer mid-turn", %{context: context} do
    steer(context, %{"instanceId" => "claudeAgent", "model" => "claude-haiku-4-5"})
  end

  @tag :tmp_dir
  @tag :codex
  test "codex takes a steer mid-turn", %{context: context} do
    steer(context, %{"instanceId" => "codex", "model" => "gpt-5.5"})
  end

  # A local model, so it costs nothing to run; any OpenCode model will do.
  @tag :tmp_dir
  @tag :opencode
  test "opencode takes a steer mid-turn", %{context: context} do
    steer(context, %{"instanceId" => "opencode", "model" => "openrouter/meta/muse-glimmer-30b"})
  end

  defp steer(context, selection) do
    context = World.create_project(context, "live")

    context =
      World.create_thread(context, "Live", nil, %{
        "modelSelection" => selection,
        "runtimeMode" => "full-access"
      })

    id = World.thread_id(context, "Live")

    {{:ok, _}, context} =
      World.send_message(
        context,
        "Live",
        "Use your bash tool to run `sleep 30 && echo slept`, then reply with the single word FIRST.",
        %{"dispatchMode" => %{"type" => "start_immediately"}}
      )

    # Wait until the command is running inside the turn.
    World.await_stream(
      id,
      fn state ->
        Enum.any?(StreamState.list(state, "turn-item"), fn item ->
          item["type"] == "command_execution" and item["status"] == "running" and
            is_binary(item["input"]) and item["input"] =~ "sleep"
        end)
      end,
      120_000
    )

    {{:ok, _}, _context} =
      World.send_message(
        context,
        "Live",
        "Change of plan: stop waiting and reply with the single word STEERED.",
        %{
          "deliveryIntent" => "steer",
          "dispatchMode" => %{"type" => "start_immediately"}
        }
      )

    state =
      World.await_stream(
        id,
        fn state ->
          runs = StreamState.list(state, "run")

          if runs != [] and Enum.all?(runs, &(&1["status"] in ~w(completed failed interrupted))),
            do: state
        end,
        180_000
      )

    runs = StreamState.list(state, "run")
    assert length(runs) == 1, "the steer should join the running turn, not queue a new run"
    assert [%{"status" => "completed"}] = runs

    items = StreamState.list(state, "turn-item")
    assert Enum.any?(items, &(&1["type"] == "user_message" and &1["inputIntent"] == "steer"))

    assert Enum.any?(
             items,
             &(&1["type"] == "assistant_message" and is_binary(&1["text"]) and
                 &1["text"] =~ "STEERED")
           )
  end
end
