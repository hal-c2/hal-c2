defmodule HalC2.AcpModelSwitchPropTest do
  @moduledoc """
  Model changes on an ACP agent whose session may not offer switching models. Once
  such a session is open, a model change, by a message or by setting the thread's
  model, is refused and leaves the thread's model alone, across session resets and
  runtime restarts. A session that offers switching takes every change.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}

  @moduletag timeout: :infinity
  @tid "model-switch-thread"
  @fake Path.expand("../../test/support/fake_acme_agent.py", __DIR__)
  @refused "The active ACP session does not expose a model-switch capability."
  @models ["acme/fast", "acme/smart"]

  property "a session that cannot switch models refuses every model change",
    numtests: HalC2.Prop.numtests(20),
    max_size: 12 do
    forall switchable <- boolean() do
      forall cmds <- commands(__MODULE__, initial_state(switchable)) do
        trap_exit do
          start_case(switchable)

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
          |> aggregate(command_names(cmds))
        end
      end
    end
  end

  def initial_state, do: initial_state(true)

  def initial_state(switchable),
    do: %{switchable: switchable, sends: 0, opened: false, model: "acme/fast"}

  def command(state) do
    frequency([
      {4, {:call, __MODULE__, :turn, [state.sends, oneof(@models)]}},
      {3, {:call, __MODULE__, :set_model, [oneof(@models)]}},
      {1, {:call, __MODULE__, :reset, []}},
      {1, {:call, __MODULE__, :restart, []}}
    ])
  end

  def precondition(state, {:call, _, :turn, [n, _]}), do: n == state.sends
  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :turn, [_, model]}) do
    state = %{state | sends: state.sends + 1}
    # A message's model is its run's; the thread keeps its own.
    if refused?(state, model), do: state, else: %{state | opened: true}
  end

  def next_state(state, _result, {:call, _, :set_model, [model]}),
    do: if(refused?(state, model), do: state, else: %{state | model: model})

  def next_state(state, _result, _call), do: state

  def postcondition(state, {:call, _, :turn, [_, model]}, result) do
    cond do
      refused?(state, model) -> result == {:error, @refused}
      state.switchable -> result == {"completed", "model: " <> model}
      true -> match?({"completed", _}, result)
    end
  end

  def postcondition(state, {:call, _, :set_model, [model]}, result) do
    expected = if refused?(state, model), do: state.model, else: model
    reply = if refused?(state, model), do: {:error, @refused}, else: :ok
    result == {reply, expected}
  end

  def postcondition(_state, {:call, _, cmd, []}, result) when cmd in [:reset, :restart],
    do: result == :ok

  defp refused?(state, model), do: not state.switchable and state.opened and model != state.model

  def reset do
    {:ok, _} = HalC2.Acp.ThreadRuntime.rollback(@tid, %{})
    :ok
  end

  # A new runtime resumes the session.
  def restart do
    case Registry.lookup(HalC2.Acp.Registry, @tid) do
      [{pid, _}] ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, _, _} -> :ok
        end

      [] ->
        :ok
    end
  end

  def set_model(model) do
    reply =
      case Orchestration.dispatch(%{
             "type" => "thread.model-selection.set",
             "threadId" => @tid,
             "modelSelection" => %{"instanceId" => "grok", "model" => model}
           }) do
        {:ok, _} -> :ok
        other -> other
      end

    {reply, thread_model()}
  end

  def turn(n, model) do
    id = "m#{n}"

    case Orchestration.dispatch(%{
           "type" => "message.dispatch",
           "threadId" => @tid,
           "messageId" => id,
           "text" => "which model",
           "modelSelection" => %{"instanceId" => "grok", "model" => model}
         }) do
      {:ok, _} -> await_turn(id)
      {:error, _} = refused -> refused
    end
  end

  defp thread_model do
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(@tid))
    get_in(StreamState.get(state, "thread"), [@tid, "modelSelection", "model"])
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
        10_000 -> raise "model turn did not finish"
      end
    end
  end

  # An agent that names no models opens sessions that cannot switch them.
  defp start_case(switchable) do
    home = HalC2.Prop.scratch_home("acp-model-switch")
    work = Path.join(home, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)

    control = if switchable, do: %{}, else: %{"models" => []}
    File.write!(Path.join(home, "control.json"), JSON.encode!(%{"grok" => control}))

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
        "title" => "Model switch",
        "modelSelection" => %{"instanceId" => "grok", "model" => "acme/fast"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => work
      })

    :ok = HalC2.Streams.subscribe(@tid, self(), nil)
  end
end
