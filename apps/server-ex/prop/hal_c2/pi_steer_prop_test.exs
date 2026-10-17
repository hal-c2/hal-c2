defmodule HalC2.PiSteerPropTest do
  @moduledoc """
  A state machine over one Pi thread (`HalC2.Pi.ThreadRuntime`) driven through the
  orchestration commands a client sends: send a message whose turn works until it is
  steered or stopped, either taking the steer into its running work or settling just
  before the steer lands (so Pi answers it in a run of its own); steer the running turn;
  interrupt it.

  Turns run on the fake `pi --mode rpc` in `test/support/fake_pi_rpc.py`. The model
  checks that each turn ends once, with the status it should, and that every steer's
  answer is recorded in the thread, whichever way Pi ran it. After each command the test
  waits on the thread's stream until the runs it ended have ended and a running turn
  began saying "Working on it.".
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}

  @moduletag timeout: :infinity

  @tid "pi-thread"
  @model %{"instanceId" => "pi", "model" => "fake/one"}
  @fake_pi Path.expand("../../test/support/fake_pi_rpc.py", __DIR__)

  @turns [
    %{"match" => "joins", "steps" => [%{"text" => "Working on it."}, %{"waitAbort" => true}]},
    %{"match" => "ends", "steps" => [%{"text" => "Working on it."}, %{"settleOnSteer" => true}]}
  ]
  @active ~w(preparing starting running waiting)
  @wait_ms 10_000

  property "a Pi thread records every steer's answer in the turn it steered",
    numtests: HalC2.Prop.numtests(20),
    max_size: 12 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("pi-steer")
        work = Path.join(home, "work")
        File.mkdir_p!(work)
        {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
        bin = install_fake(home)

        HalC2.Prop.start_services([
          {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
          HalC2.Streams,
          HalC2.Shell,
          HalC2.Orchestration.TurnWatch,
          Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Codex.Registry},
            id: :codex_registry
          ),
          Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Claude.Registry},
            id: :claude_registry
          ),
          Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Acp.Registry},
            id: :acp_registry
          ),
          Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Pi.Registry},
            id: :pi_registry
          ),
          {DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one},
          HalC2.Settings
        ])

        HalC2.Acp.forget("pi")

        {:ok, _} =
          HalC2.Settings.put(
            %{"providers" => %{"pi" => %{"enabled" => true, "binaryPath" => bin}}},
            0
          )

        create(work)
        :ok = HalC2.Streams.subscribe(@tid, self(), nil)
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()
        HalC2.Acp.forget("pi")

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------

  # runs: [{msg, status}] in the order they were made; turn: the running turn's msg;
  # replies: the steers answered, in order.
  def initial_state, do: %{runs: [], turn: nil, replies: [], next: 1}

  def command(%{turn: nil, next: next}),
    do: {:call, __MODULE__, :send, ["m#{next}", oneof([:joins, :ends])]}

  def command(%{next: next}) do
    frequency([
      {3, {:call, __MODULE__, :steer, ["m#{next}"]}},
      {1, {:call, __MODULE__, :interrupt, []}}
    ])
  end

  def precondition(%{turn: turn}, {:call, _, :send, _}), do: turn == nil
  def precondition(%{turn: turn}, {:call, _, _, _}), do: turn != nil

  def next_state(state, _result, {:call, _, :send, [msg, _how]}),
    do: %{state | next: state.next + 1, runs: state.runs ++ [{msg, "running"}], turn: msg}

  def next_state(state, _result, {:call, _, :steer, [msg]}) do
    state = %{state | next: state.next + 1, replies: state.replies ++ [msg]}
    end_turn(state, "completed")
  end

  def next_state(state, _result, {:call, _, :interrupt, _}), do: end_turn(state, "interrupted")

  defp end_turn(%{turn: turn} = state, status) do
    runs = Enum.map(state.runs, fn {m, s} -> if m == turn, do: {m, status}, else: {m, s} end)
    %{state | runs: runs, turn: nil}
  end

  def postcondition(state, call, {reply, projection}) do
    model = next_state(state, nil, call)
    reply == :ok and projection == %{runs: model.runs, replies: model.replies}
  end

  # --- commands ---------------------------------------------------------------------

  defp create(work) do
    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => @tid,
        "projectId" => "project-1",
        "title" => "Pi",
        "modelSelection" => @model,
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => work
      })
  end

  # `how`: whether the turn's work takes a steer in (:joins) or settles as it lands (:ends).
  def send(msg, how) do
    reply(Orchestration.dispatch(message(msg, "#{how} #{msg}", "queue_after_active", "auto")), [])
  end

  def steer(msg) do
    ending = active_runs()
    result = Orchestration.dispatch(message(msg, "steer #{msg}", "start_immediately", "steer"))
    reply(result, ending)
  end

  def interrupt do
    ending = active_runs()
    reply(Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => @tid}), ending)
  end

  defp message(msg, text, mode, intent) do
    %{
      "type" => "message.dispatch",
      "threadId" => @tid,
      "messageId" => msg,
      "text" => text,
      "attachments" => [],
      "modelSelection" => @model,
      "dispatchMode" => %{"type" => mode},
      "deliveryIntent" => intent
    }
  end

  # --- the real side ----------------------------------------------------------------

  defp install_fake(home) do
    dir = Path.join(home, "fake-pi")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "config.json"), JSON.encode!(%{"turns" => @turns}))
    bin = Path.join([dir, "bin", "pi"])
    File.mkdir_p!(Path.dirname(bin))

    File.write!(bin, """
    #!/bin/sh
    export FAKE_DIR='#{dir}' FAKE_BIN="$0"
    exec python3 -u '#{@fake_pi}' "$@"
    """)

    File.chmod!(bin, 0o755)
    bin
  end

  defp current, do: HalC2.Streams.Server.state(HalC2.Streams.ensure(@tid))

  defp runs(state), do: state |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])

  defp active_runs, do: for(run <- runs(current()), run["status"] in @active, do: run["id"])

  defp reply(result, ending) do
    reply =
      case result do
        {:ok, %{}} -> :ok
        {:error, message} -> {:error, message}
        other -> {:unexpected, other}
      end

    {reply, settled(ending, System.monotonic_time(:millisecond) + @wait_ms)}
  end

  # Waits until the runs in `ending` ended, nothing is starting, and a running turn
  # began saying "Working on it.", after which the fake waits.
  defp settled(ending, deadline) do
    flush()
    state = current()
    by_id = Map.new(runs(state), &{&1["id"], &1})

    working? = fn run ->
      Enum.any?(
        StreamState.list(state, "turn-item"),
        &(&1["runId"] == run["id"] and &1["type"] == "assistant_message")
      )
    end

    quiet? =
      not Enum.any?(runs(state), &(&1["status"] in ~w(preparing starting))) and
        Enum.all?(ending, &(by_id[&1] == nil or by_id[&1]["status"] not in @active)) and
        Enum.all?(runs(state), &(&1["status"] not in @active or working?.(&1)))

    if quiet? do
      projection(state)
    else
      receive do
        {:hal_c2_stream, @tid, _} -> settled(ending, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) -> {:timeout, projection(state)}
      end
    end
  end

  defp flush do
    receive do
      {:hal_c2_stream, @tid, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp projection(state) do
    %{
      runs: for(run <- runs(state), do: {run["userMessageId"], run["status"]}),
      # Pi answers a steer it took in "steered: <text>", and one it ran on its own
      # "Reply to <text> after [...]".
      replies:
        for(
          m <- state |> StreamState.list("message") |> Enum.sort_by(& &1["createdAt"]),
          m["role"] == "assistant",
          [_, msg] <- [Regex.run(~r/^(?:steered: |Reply to )steer (m\d+)/, m["text"] || "")],
          do: msg
        )
    }
  end
end
