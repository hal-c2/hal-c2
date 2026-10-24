defmodule HalC2.AcpModelsPropTest do
  @moduledoc """
  Model changes across successive turns and session resets. Both ACP model formats
  must run each prompt on the requested model, including switching back and keeping
  the current choice. The fake rejects the wrong model selection method.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}

  @moduletag timeout: :infinity
  @tid "models-thread"
  @fake Path.expand("../../test/support/fake_acme_agent.py", __DIR__)

  property "each turn uses its selected model with either ACP model format",
    numtests: HalC2.Prop.numtests(25),
    max_size: 12 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        Enum.all?([false, true], fn legacy ->
          start_case(legacy)

          try do
            {history, state, result} = run_commands(__MODULE__, cmds)

            if result != :ok,
              do: IO.puts(HalC2.Prop.report(cmds, history, state, result))

            result == :ok
          after
            HalC2.Prop.stop_services()
            HalC2.Acp.forget("grok")
            Application.delete_env(:hal_c2, :acp_commands)
          end
        end)
        |> aggregate(command_names(cmds))
      end
    end
  end

  def initial_state, do: %{turns: 0}

  def command(state) do
    frequency([
      {4, {:call, __MODULE__, :turn, [state.turns, oneof(["acme/fast", "acme/smart"])]}},
      {1, {:call, __MODULE__, :reset, []}}
    ])
  end

  def precondition(state, {:call, _, :turn, [n, _]}), do: n == state.turns
  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :turn, _}), do: %{state | turns: state.turns + 1}
  def next_state(state, _result, _call), do: state

  def postcondition(_state, {:call, _, :turn, [_, model]}, result),
    do: result == {"completed", "model: " <> model}

  def postcondition(_state, {:call, _, :reset, []}, result), do: result == :ok

  def reset do
    {:ok, _} = HalC2.Acp.ThreadRuntime.rollback(@tid, %{})
    :ok
  end

  def turn(n, model) do
    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => @tid,
        "messageId" => "m#{n}",
        "text" => "which model",
        "modelSelection" => %{"instanceId" => "grok", "model" => model}
      })

    await_turn(n + 1)
  end

  defp await_turn(count) do
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(@tid))
    runs = StreamState.list(state, "run")

    if length(runs) == count and Enum.all?(runs, &(&1["status"] in ~w(completed failed))) do
      run = Enum.find(runs, &(&1["userMessageId"] == "m#{count - 1}"))

      text =
        state
        |> StreamState.list("message")
        |> Enum.filter(&(&1["role"] == "assistant" and &1["runId"] == run["id"]))
        |> Enum.map_join(&(&1["text"] || ""))

      {run["status"], text}
    else
      receive do
        {:hal_c2_stream, @tid, _} -> await_turn(count)
      after
        10_000 -> raise "model turn did not finish"
      end
    end
  end

  defp start_case(legacy) do
    home = HalC2.Prop.scratch_home("acp-models")
    work = Path.join(home, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)

    File.write!(
      Path.join(home, "control.json"),
      JSON.encode!(%{"grok" => %{"legacyModels" => legacy}})
    )

    Application.put_env(:hal_c2, :acp_commands, %{
      "grok" => ["python3", "-u", @fake, "--control", home, "--name", "grok"]
    })

    HalC2.Prop.start_services([
      HalC2.Settings,
      {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
      HalC2.Streams,
      HalC2.Shell,
      {Registry, keys: :unique, name: HalC2.Acp.Registry},
      {DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one}
    ])

    HalC2.Acp.forget("grok")

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => @tid,
        "projectId" => "project-1",
        "title" => "Models",
        "modelSelection" => %{"instanceId" => "grok", "model" => "acme/fast"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => work
      })

    :ok = HalC2.Streams.subscribe(@tid, self(), nil)
  end
end
