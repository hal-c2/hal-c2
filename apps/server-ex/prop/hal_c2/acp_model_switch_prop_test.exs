defmodule HalC2.AcpModelSwitchPropTest do
  @moduledoc """
  Model changes on an ACP agent whose session may not offer switching models. Once
  such a session is open, a model change, by a message or by setting the thread's
  model, is refused and leaves the thread's model alone, across session resets and
  runtime restarts, and the session being stopped. A session that offers switching takes every change.

  A model the session will not switch to fails the turn before the agent hears it, and
  leaves the model the session had for the next turn.

  A reasoning level a turn picks is the one it runs at, and a turn that picks none runs
  at the level its model starts at, whatever level an earlier turn set (Grok keeps it).

  A restart may also lose the agent's sessions. The next turn then runs in a new
  session that is handed every earlier turn, and the new session switches models as
  the agent's sessions do.
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
  @broken "acme/broken"
  # The level each model starts at, on an agent that can switch them.
  @levels %{"acme/fast" => "medium", "acme/smart" => "high"}
  @unswitched "Could not switch to the model acme/broken (model not available), " <>
                "so the turn was not sent. Try again, or pick another."

  property "a session that cannot switch models refuses every model change, and a lost one is handed the thread",
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
    do: %{
      switchable: switchable,
      sends: 0,
      turns: 0,
      opened: false,
      lost: false,
      model: "acme/fast"
    }

  def command(state) do
    frequency([
      {4, {:call, __MODULE__, :turn, [state.sends, oneof(@models), level(state)]}},
      {3, {:call, __MODULE__, :set_model, [oneof(@models)]}},
      {1, {:call, __MODULE__, :reset, []}},
      {1, {:call, __MODULE__, :detach, []}},
      {1, {:call, __MODULE__, :restart, [boolean()]}},
      {1, {:call, __MODULE__, :broken_turn, [state.sends]}}
    ])
  end

  # A level picked, or none (`nil`), which takes an earlier turn's pick off.
  defp level(%{switchable: true}), do: oneof([nil, "low", "max"])
  defp level(_state), do: nil

  def precondition(state, {:call, _, :turn, [n, _, _]}), do: n == state.sends
  # An agent that cannot switch refuses every change up front (`refused?/2`).
  def precondition(state, {:call, _, :broken_turn, [n]}),
    do: state.switchable and n == state.sends

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :turn, [_, model, _]}) do
    state = %{state | sends: state.sends + 1}
    # A message's model is its run's; the thread keeps its own.
    if refused?(state, model),
      do: state,
      else: %{state | opened: true, lost: false, turns: state.turns + 1}
  end

  # The refused turn's session is open; what it was to be handed waits for the next turn.
  def next_state(state, _result, {:call, _, :broken_turn, [_]}),
    do: %{state | sends: state.sends + 1, opened: true}

  def next_state(state, _result, {:call, _, :set_model, [model]}),
    do: if(refused?(state, model), do: state, else: %{state | model: model})

  # Only a session the agent had can be lost.
  def next_state(state, _result, {:call, _, :restart, [true]}),
    do: %{state | lost: state.opened}

  def next_state(state, _result, _call), do: state

  def postcondition(state, {:call, _, :turn, [_, model, level]}, result) do
    # A lost session after only a refused turn has no earlier turns to be handed.
    handed = if state.lost and state.turns > 0, do: " with #{state.turns} earlier turns", else: ""

    cond do
      refused?(state, model) ->
        result == {:error, @refused}

      state.switchable ->
        result == {"completed", "model: #{model} at #{level || @levels[model]}" <> handed}

      true ->
        handed?(result, handed)
    end
  end

  def postcondition(state, {:call, _, :set_model, [model]}, result) do
    expected = if refused?(state, model), do: state.model, else: model
    reply = if refused?(state, model), do: {:error, @refused}, else: :ok
    result == {reply, expected}
  end

  def postcondition(_state, {:call, _, :broken_turn, [_]}, result),
    do: result == {"failed", "", @unswitched}

  def postcondition(_state, {:call, _, :reset, []}, result), do: result == :ok
  def postcondition(_state, {:call, _, :detach, []}, result), do: result == :ok
  def postcondition(_state, {:call, _, :restart, [_]}, result), do: result == :ok

  # The model an agent that cannot switch reports is its own business.
  defp handed?({"completed", "model: " <> said}, ""), do: not String.contains?(said, " with ")
  defp handed?({"completed", "model: " <> said}, handed), do: String.ends_with?(said, handed)
  defp handed?(_result, _handed), do: false

  defp refused?(state, model), do: not state.switchable and state.opened and model != state.model

  def reset do
    {:ok, _} = HalC2.Acp.ThreadRuntime.rollback(@tid, %{})
    :ok
  end

  # "Stop session": the provider process stops and its session record goes; the next
  # turn resumes the agent's session, which still cannot switch models.
  def detach do
    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "provider-session.detach",
        "threadId" => @tid,
        "providerSessionId" => HalC2.Orchestration.Entities.provider_session_id("grok", @tid)
      })

    :ok
  end

  # A new runtime resumes the session, unless the agent has lost it (`lose`): the next
  # agent process cannot open a session an earlier one made.
  def restart(lose) do
    if lose, do: File.write!(Path.join(Process.get(:home), "grok.lost"), "")

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

  def turn(n, model, level) do
    id = "m#{n}"
    options = if level, do: [%{"id" => "reasoningEffort", "value" => level}], else: []

    case Orchestration.dispatch(%{
           "type" => "message.dispatch",
           "threadId" => @tid,
           "messageId" => id,
           "text" => "which model",
           "modelSelection" => %{"instanceId" => "grok", "model" => model, "options" => options}
         }) do
      {:ok, _} -> await_turn(id)
      {:error, _} = refused -> refused
    end
  end

  # A turn on a model the session will not switch to (its text is not "which model", so
  # no later turn counts it among the turns it was handed).
  def broken_turn(n) do
    id = "m#{n}"

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => @tid,
        "messageId" => id,
        "text" => "try the broken model",
        "modelSelection" => %{"instanceId" => "grok", "model" => @broken}
      })

    {status, text} = await_turn(id)
    {status, text, failure(id)}
  end

  defp failure(id) do
    HalC2.Streams.Server.state(HalC2.Streams.ensure(@tid))
    |> StreamState.list("run")
    |> Enum.find_value(&(&1["userMessageId"] == id && &1["failure"]))
  end

  defp thread_model do
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(@tid))
    get_in(StreamState.get(state, "thread"), [@tid, "modelSelection", "model"])
  end

  # Waits on the thread's stream until turn `id`'s run completes or fails; the
  # deadline, as long as `World.await_stream/3`'s, only stops a hung case.
  defp await_turn(id, deadline \\ System.monotonic_time(:millisecond) + 30_000) do
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
        {:hal_c2_stream, @tid, _} -> await_turn(id, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) ->
          raise "turn #{id} did not finish in 30 s (its run: #{inspect(run)})"
      end
    end
  end

  # An agent that names no models opens sessions that cannot switch them.
  defp start_case(switchable) do
    home = HalC2.Prop.scratch_home("acp-model-switch")
    Process.put(:home, home)
    work = Path.join(home, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)

    control =
      if switchable,
        do: %{"refuseModels" => [@broken], "reasoning" => @levels},
        else: %{"models" => []}

    control = Map.put(control, "loseSessions", true)
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

defmodule HalC2.AcpOpencodeVariantPropTest do
  @moduledoc """
  OpenCode's reasoning variants belong to a model. A turn that picks a variant runs on
  it, and a turn that picks none runs on its model's own: the variant OpenCode reported
  when the session first landed on that model. That holds whichever models earlier
  turns switched between and came back to, whatever they picked, and whether OpenCode
  keeps a model's last variant across switches or not. The turn is never sent a
  variant its model does not offer, and an options report in the middle of a turn
  never changes what the session opened on.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}

  @moduletag timeout: :infinity
  @tid "opencode-variant-thread"
  @fake Path.expand("../../test/support/fake_acp_scripted.py", __DIR__)
  # Each model's variants and its own one, the variant OpenCode lands on. A session
  # opens on the first.
  @variants %{
    "oc/a" => {~w(high max), "max"},
    "oc/b" => {~w(low medium high), "medium"},
    "oc/c" => {~w(minimal low), "low"}
  }
  @models Map.keys(@variants)
  @opens "oc/a"

  property "a turn runs on the variant it picks, else on its model's own",
    numtests: HalC2.Prop.numtests(20),
    max_size: 14 do
    forall keep <- boolean() do
      forall cmds <- commands(__MODULE__) do
        trap_exit do
          start_case(keep)

          try do
            {history, state, result} = run_commands(__MODULE__, cmds)

            if result != :ok,
              do: IO.puts(HalC2.Prop.report(cmds, history, state, result))

            result == :ok
          after
            HalC2.Prop.stop_services()
            HalC2.Acp.forget("opencode")
            Application.delete_env(:hal_c2, :acp_commands)
          end
          |> aggregate(command_names(cmds))
        end
      end
    end
  end

  # `session`: the model the session is on, nil when there is none (the next turn
  # opens one, on `@opens`).
  def initial_state, do: %{sends: 0, session: nil}

  def command(state) do
    frequency([
      {6, turn(state.sends)},
      {1, {:call, __MODULE__, :reset, []}}
    ])
  end

  # A turn on any model (so turns switch away and come back), picking one of its
  # variants or none, with or without OpenCode reporting its options mid-turn.
  defp turn(n) do
    let model <- oneof(@models) do
      {variants, _own} = @variants[model]
      {:call, __MODULE__, :turn, [n, model, oneof([nil | variants]), boolean()]}
    end
  end

  def precondition(state, {:call, _, :turn, [n, model, pick, _]}),
    do: n == state.sends and (pick == nil or pick in elem(@variants[model], 0))

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :turn, [_, model, _, _]}),
    do: %{state | sends: state.sends + 1, session: model}

  def next_state(state, _result, {:call, _, :reset, []}), do: %{state | session: nil}

  def postcondition(state, {:call, _, :turn, [_, model, pick, _]}, {result, sets}) do
    {_variants, own} = @variants[model]

    result == {"completed", "model: #{model} at #{pick || own}"} and
      offered?(sets, state.session || @opens)
  end

  def postcondition(_state, {:call, _, :reset, []}, result), do: result == :ok

  # Every variant set is one the model the session is on at that point offers.
  defp offered?([], _model), do: true
  defp offered?([{"model", model} | rest], _model), do: offered?(rest, model)

  defp offered?([{"effort", value} | rest], model),
    do: value in elem(@variants[model], 0) and offered?(rest, model)

  defp offered?([_ | rest], model), do: offered?(rest, model)

  def reset do
    {:ok, _} = HalC2.Acp.ThreadRuntime.rollback(@tid, %{})
    :ok
  end

  # The turn's outcome and what OpenCode was asked to set for it, in order.
  def turn(n, model, pick, report) do
    id = "m#{n}"
    seen = length(log())
    options = if pick, do: [%{"id" => "variant", "value" => pick}], else: []

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => @tid,
        "messageId" => id,
        "text" => if(report, do: "report, then which variant", else: "which variant"),
        "modelSelection" => %{"instanceId" => "opencode", "model" => model, "options" => options}
      })

    result = await_turn(id)

    sets =
      for %{"recv" => %{"method" => "session/set_config_option", "params" => p}} <-
            Enum.drop(log(), seen),
          do: {p["configId"], p["value"]}

    {result, sets}
  end

  defp log do
    case File.read(Path.join(Process.get(:fake_dir), "log.jsonl")) do
      {:ok, body} -> for line <- String.split(body, "\n", trim: true), do: JSON.decode!(line)
      {:error, :enoent} -> []
    end
  end

  # Waits on the thread's stream until turn `id`'s run completes or fails; the
  # deadline, as long as `World.await_stream/3`'s, only stops a hung case.
  defp await_turn(id, deadline \\ System.monotonic_time(:millisecond) + 30_000) do
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
        {:hal_c2_stream, @tid, _} -> await_turn(id, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) ->
          raise "OpenCode turn #{id} did not finish in 30 s (its run: #{inspect(run)})"
      end
    end
  end

  defp effort({variants, own}),
    do: %{
      "id" => "effort",
      "name" => "Effort",
      "type" => "select",
      "currentValue" => own,
      "options" => Enum.map(variants, &%{"value" => &1, "name" => &1})
    }

  # `keep`: OpenCode keeps a model's last variant across switches, so back on a model
  # it reports that one rather than the model's own.
  defp start_case(keep) do
    home = HalC2.Prop.scratch_home("acp-opencode-variant")
    dir = Path.join(home, "fake")
    work = Path.join(home, "work")
    File.mkdir_p!(dir)
    File.mkdir_p!(work)
    Process.put(:fake_dir, dir)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)

    model = %{
      "id" => "model",
      "name" => "Model",
      "type" => "select",
      "currentValue" => @opens,
      "options" => Enum.map(@models, &%{"value" => &1, "name" => &1})
    }

    echo = %{"echoOptions" => true}

    File.write!(
      Path.join(dir, "config.json"),
      JSON.encode!(%{
        "version" => "1.14.19",
        "configOptions" => [model, effort(@variants[@opens])],
        "modelOptions" => Map.new(@variants, fn {m, v} -> {m, [effort(v)]} end),
        "rejectUnknownValues" => true,
        "keepModelOptions" => keep,
        "turns" => [
          %{"match" => "report", "steps" => [%{"reportOptions" => true}, echo]},
          %{"match" => "which", "steps" => [echo]}
        ]
      })
    )

    Application.put_env(:hal_c2, :acp_commands, %{
      "opencode" => ["env", "FAKE_DIR=#{dir}", "python3", "-u", @fake]
    })

    HalC2.Prop.start_services([
      HalC2.Settings,
      {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
      HalC2.Streams,
      HalC2.Shell,
      {Registry, keys: :unique, name: HalC2.Acp.Registry},
      {DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one}
    ])

    HalC2.Acp.forget("opencode")

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => @tid,
        "projectId" => "project-1",
        "title" => "Variants",
        "modelSelection" => %{"instanceId" => "opencode", "model" => @opens},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => work
      })

    :ok = HalC2.Streams.subscribe(@tid, self(), nil)
  end
end
