defmodule HalC2.AcpModelSwitchTest do
  # Regression HalC2.AcpModelSwitchPropTest found: a session the agent lost was never
  # handed the thread when the first turn after the loss failed to switch models.
  use ExUnit.Case, async: false

  alias HalC2.{Orchestration, StreamState}

  @moduletag :tmp_dir
  @tid "model-switch-thread"
  @fake Path.expand("../support/fake_acme_agent.py", __DIR__)

  setup %{tmp_dir: dir} do
    work = Path.join(dir, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)

    control = %{
      "refuseModels" => ["acme/broken"],
      "reasoning" => %{"acme/fast" => "medium", "acme/smart" => "high"},
      "loseSessions" => true
    }

    File.write!(Path.join(dir, "control.json"), JSON.encode!(%{"grok" => control}))
    Application.put_env(:hal_c2, :home, dir)

    Application.put_env(:hal_c2, :acp_commands, %{
      "grok" => ["python3", "-u", @fake, "--control", dir, "--name", "grok"]
    })

    start_supervised!(HalC2.Settings)
    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    start_supervised!({Registry, keys: :unique, name: HalC2.Acp.Registry})
    start_supervised!({DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one})

    HalC2.Acp.forget("grok")

    on_exit(fn ->
      HalC2.Acp.forget("grok")
      Application.delete_env(:hal_c2, :acp_commands)
    end)

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => @tid,
        "projectId" => "project-1",
        "title" => "Model switch",
        "modelSelection" => %{"instanceId" => "grok", "model" => "acme/fast"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => work
      })

    :ok = HalC2.Streams.subscribe(@tid, self(), nil)
    {:ok, dir: dir}
  end

  test "a lost session is handed the thread after a turn whose model switch failed", %{dir: dir} do
    assert turn("m0", "acme/smart", "which model", "max") ==
             {"completed", "model: acme/smart at max"}

    # The agent loses its sessions with the runtime.
    File.write!(Path.join(dir, "grok.lost"), "")
    [{pid, _}] = Registry.lookup(HalC2.Acp.Registry, @tid)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}

    # The new session will not switch to this model: the turn is never sent.
    assert {"failed", ""} = turn("m1", "acme/broken", "try the broken model", nil)

    assert turn("m2", "acme/fast", "which model", "low") ==
             {"completed", "model: acme/fast at low with 1 earlier turns"}
  end

  defp turn(id, model, text, level) do
    options = if level, do: [%{"id" => "reasoningEffort", "value" => level}], else: []

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => @tid,
        "messageId" => id,
        "text" => text,
        "modelSelection" => %{"instanceId" => "grok", "model" => model, "options" => options}
      })

    await_turn(id)
  end

  defp await_turn(id) do
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(@tid))
    run = state |> StreamState.list("run") |> Enum.find(&(&1["userMessageId"] == id))

    if run && run["status"] in ~w(completed failed) do
      text =
        state
        |> StreamState.list("message")
        |> Enum.filter(&(&1["role"] == "assistant" and &1["runId"] == run["id"]))
        |> Enum.map_join(&(&1["text"] || ""))

      {run["status"], text}
    else
      receive do
        {:hal_c2_stream, @tid, _} -> await_turn(id)
      after
        10_000 -> flunk("turn #{id} did not finish")
      end
    end
  end
end
