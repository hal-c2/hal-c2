defmodule HalC2.PiSteerPropTest do
  @moduledoc """
  A state machine over one Pi thread (`HalC2.Pi.ThreadRuntime`) driven through the
  orchestration commands a client sends: send a message whose turn works until it is
  steered or stopped, either taking the steer into its running work or settling just
  before the steer lands (so Pi answers it in a run of its own), or just before two
  steers sent at once land; steer the running turn, with a message Pi takes, one it
  refuses, one it refuses only once the run settled (which finds the turn over, so it
  is sent as a message of its own), one Pi exits on before answering (which fails
  the turn, so it is sent on its own too), or one Pi never answers once the run settled
  (which the runtime takes as taken once its answer budget, shortened here, runs out);
  steer it twice at once, including a declined steer held behind one Pi never answers
  (in either order); steer it twice staggered, the second dispatched while the first
  is still in flight, so a held refusal outlives the first steer's own answer budget;
  interrupt it.

  Turns run on the fake `pi --mode rpc` in `test/support/fake_pi_rpc.py`. The model
  checks that each turn ends once, with the status it should, that every steer's
  answer is recorded in the thread, whichever way Pi ran it, and that a steer Pi refused
  is an error for its sender that leaves the turn running. Messages resent on their own
  at once may run in either order, so runs and replies compare as sets. After each command the test
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
    %{"match" => "ends", "steps" => [%{"text" => "Working on it."}, %{"settleOnSteer" => 1}]},
    %{"match" => "pair", "steps" => [%{"text" => "Working on it."}, %{"settleOnSteer" => 2}]}
  ]
  @finished ~w(completed failed interrupted cancelled)
  @active ~w(preparing starting running waiting)
  @wait_ms 10_000
  @answer_ms 2_000

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
        Application.put_env(:hal_c2, :pi_steer_answer_ms, @answer_ms)

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
        Application.delete_env(:hal_c2, :pi_steer_answer_ms)

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------

  # runs: [{msg, status}] in the order they were made; turn: the running turn's msg;
  # how: whether its work takes a steer in, settles as one lands, or as two land;
  # replies: the steers answered, in order.
  def initial_state, do: %{runs: [], turn: nil, how: nil, replies: [], next: 1}

  def command(%{turn: nil, next: next}),
    do: {:call, __MODULE__, :send, [id(next), oneof([:joins, :ends, :pair])]}

  # A turn that settles as two steers land waits for both: it is steered twice at once,
  # or with a message Pi refuses before it waits on.
  def command(%{how: :pair, next: next}) do
    frequency([
      {3,
       {:call, __MODULE__, :steer_pair,
        [
          id(next),
          id(next + 1),
          oneof([
            {:taken, :taken},
            {:taken, :declined},
            {:declined, :declined},
            {:declined, :joins},
            {:declined, :ignored},
            {:ignored, :declined}
          ])
        ]}},
      {2,
       {:call, __MODULE__, :steer_staggered,
        [id(next), id(next + 1), oneof([{:declined, :ignored}, {:ignored, :declined}])]}},
      {1, {:call, __MODULE__, :steer, [id(next), :refused]}},
      {1, {:call, __MODULE__, :interrupt, []}}
    ])
  end

  def command(%{next: next}) do
    frequency([
      {3, {:call, __MODULE__, :steer, [id(next), :taken]}},
      {1, {:call, __MODULE__, :steer, [id(next), :refused]}},
      {1, {:call, __MODULE__, :steer, [id(next), :declined]}},
      {1, {:call, __MODULE__, :steer, [id(next), :vanishes]}},
      {1, {:call, __MODULE__, :steer, [id(next), :ignored]}},
      {1, {:call, __MODULE__, :interrupt, []}}
    ])
  end

  # Padded, so the fake takes two steers sent at once in the order they were made.
  defp id(n), do: "m" <> String.pad_leading(Integer.to_string(n), 3, "0")

  def precondition(%{turn: turn}, {:call, _, :send, _}), do: turn == nil
  def precondition(%{how: how}, {:call, _, :steer_pair, _}), do: how == :pair
  def precondition(%{how: how}, {:call, _, :steer_staggered, _}), do: how == :pair

  def precondition(%{how: :pair}, {:call, _, :steer, [_, kind]}), do: kind == :refused
  # A turn taking a steer in answers it; one that settled as it landed never does.
  def precondition(%{how: how}, {:call, _, :steer, [_, :ignored]}), do: how == :ends
  def precondition(%{turn: turn}, {:call, _, _, _}), do: turn != nil

  def next_state(state, _result, {:call, _, :send, [msg, how]}) do
    runs = state.runs ++ [{msg, "running"}]
    %{state | next: state.next + 1, runs: runs, turn: msg, how: how}
  end

  # Staggered or at once, the pair's outcomes are the same.
  def next_state(state, result, {:call, mod, :steer_staggered, args}),
    do: next_state(state, result, {:call, mod, :steer_pair, args})

  # Pi takes the first, then the second, each after the run settled.
  def next_state(state, _result, {:call, _, :steer_pair, [a, b, kinds]}) do
    state = %{state | next: state.next + 2}

    case kinds do
      {:taken, :taken} ->
        end_turn(%{state | replies: state.replies ++ [a, b]}, "completed")

      # The second, declined once nothing else is out, ends the turn and runs on its own.
      {:taken, :declined} ->
        state = end_turn(%{state | replies: state.replies ++ [a]}, "completed")
        %{state | runs: state.runs ++ [{b, "completed"}], replies: state.replies ++ [b]}

      # Both find the turn over, and run on their own.
      {:declined, :declined} ->
        state = end_turn(state, "completed")
        own = [{a, "completed"}, {b, "completed"}]
        %{state | runs: state.runs ++ own, replies: state.replies ++ [a, b]}

      # The second starts work that runs on, so the first, declined, is an error for its
      # sender; the turn's work takes the next steer in.
      {:declined, :joins} ->
        %{state | how: :joins}

      # The unanswered one is taken as taken once its budget runs out, which is the
      # last steer out either way: the turn ends with it and no reply, and the
      # declined one, held until then, finds the turn over and runs on its own.
      {:declined, :ignored} ->
        state = end_turn(state, "completed")
        %{state | runs: state.runs ++ [{a, "completed"}], replies: state.replies ++ [a]}

      {:ignored, :declined} ->
        state = end_turn(state, "completed")
        %{state | runs: state.runs ++ [{b, "completed"}], replies: state.replies ++ [b]}
    end
  end

  # Pi never answers: once the budget ran out the steer is taken, and the turn ends with
  # it and no reply.
  def next_state(state, _result, {:call, _, :steer, [_msg, :ignored]}),
    do: end_turn(%{state | next: state.next + 1}, "completed")

  # Pi exits with the steer unanswered: the turn fails, and the message runs on its own.
  def next_state(state, _result, {:call, _, :steer, [msg, :vanishes]}) do
    state = end_turn(state, "failed")

    %{
      state
      | next: state.next + 1,
        runs: state.runs ++ [{msg, "completed"}],
        replies: state.replies ++ [msg]
    }
  end

  def next_state(state, _result, {:call, _, :steer, [_msg, :refused]}),
    do: %{state | next: state.next + 1}

  # Declined once the run settled: the turn is over, so the message runs on its own.
  def next_state(%{how: :ends} = state, _result, {:call, _, :steer, [msg, :declined]}) do
    state = end_turn(state, "completed")

    %{
      state
      | next: state.next + 1,
        runs: state.runs ++ [{msg, "completed"}],
        replies: state.replies ++ [msg]
    }
  end

  def next_state(state, _result, {:call, _, :steer, [msg, _taken_or_declined]}) do
    state = %{state | next: state.next + 1, replies: state.replies ++ [msg]}
    end_turn(state, "completed")
  end

  def next_state(state, _result, {:call, _, :interrupt, _}), do: end_turn(state, "interrupted")

  defp end_turn(%{turn: turn} = state, status) do
    runs = Enum.map(state.runs, fn {m, s} -> if m == turn, do: {m, status}, else: {m, s} end)
    %{state | runs: runs, turn: nil, how: nil}
  end

  def postcondition(state, call, {reply, projection}) do
    model = next_state(state, nil, call)

    replied? =
      case call do
        {:call, _, :steer, [_, :refused]} -> match?({:error, _}, reply)
        {:call, _, :steer_pair, [_, _, {:declined, :joins}]} -> match?([{:error, _}, :ok], reply)
        {:call, _, :steer_pair, _} -> reply == [:ok, :ok]
        {:call, _, :steer_staggered, _} -> reply == [:ok, :ok]
        _ -> reply == :ok
      end

    replied? and
      Enum.sort(projection.runs) == Enum.sort(model.runs) and
      Enum.sort(projection.replies) == Enum.sort(model.replies)
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

  # `kind`: whether Pi takes the steer (:taken), which ends the turn, refuses it, refuses
  # it only once the run settled (:declined), which a turn taking it in takes, exits
  # before answering it (:vanishes), or never answers it once the run settled (:ignored).
  def steer(msg, kind) do
    {text, ending} = steer_text(msg, kind)
    result = Orchestration.dispatch(message(msg, text, "start_immediately", "steer"))
    # A steer sent on its own runs to its end too.
    ending = if kind in [:declined, :vanishes], do: ending ++ active_runs(), else: ending
    reply(result, ending)
  end

  defp steer_text(msg, :taken), do: {"steer #{msg}", active_runs()}
  defp steer_text(msg, :refused), do: {"refuse #{msg}", []}
  defp steer_text(msg, :declined), do: {"steer #{msg}, declined once settled", active_runs()}
  defp steer_text(msg, :vanishes), do: {"steer #{msg}, vanish on it", active_runs()}
  defp steer_text(msg, :ignored), do: {"steer #{msg}, ignore it", active_runs()}
  # A steer whose own run matches the "joins" turn, which works on.
  defp steer_text(msg, :joins), do: {"steer #{msg}, joins the work", []}

  # Two steers sent at once, `kinds` as for `steer/2`.
  def steer_pair(a, b, {kind_a, kind_b}) do
    {text_a, ending} = steer_text(a, kind_a)
    {text_b, _} = steer_text(b, kind_b)

    replies =
      [{a, text_a}, {b, text_b}]
      |> Enum.map(fn {msg, text} ->
        Task.async(fn ->
          answer(Orchestration.dispatch(message(msg, text, "start_immediately", "steer")))
        end)
      end)
      |> Task.await_many(@wait_ms)

    # Unless the turn works on, every run it left, the ones sent on their own included,
    # runs to its end.
    ending = if kind_b == :joins, do: [], else: ending ++ unfinished_runs()
    {replies, settled(ending, System.monotonic_time(:millisecond) + @wait_ms)}
  end

  # Two steers staggered: the second is dispatched while the first is still in
  # flight, so whichever is declined is held behind the unanswered one's whole
  # answer budget (and the settling after it) before its sender hears. Its
  # caller must still hear the refusal, not a timeout taken as taken.
  def steer_staggered(a, b, {kind_a, kind_b}) do
    {text_a, ending} = steer_text(a, kind_a)
    {text_b, _} = steer_text(b, kind_b)

    first =
      Task.async(fn ->
        answer(Orchestration.dispatch(message(a, text_a, "start_immediately", "steer")))
      end)

    reply_b = answer(Orchestration.dispatch(message(b, text_b, "start_immediately", "steer")))
    replies = [Task.await(first, @wait_ms), reply_b]
    ending = ending ++ unfinished_runs()
    {replies, settled(ending, System.monotonic_time(:millisecond) + @wait_ms)}
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

  defp unfinished_runs,
    do: for(run <- runs(current()), run["status"] not in @finished, do: run["id"])

  defp reply(result, ending),
    do: {answer(result), settled(ending, System.monotonic_time(:millisecond) + @wait_ms)}

  defp answer({:ok, %{}}), do: :ok
  defp answer({:error, message}), do: {:error, message}
  defp answer(other), do: {:unexpected, other}

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
        Enum.all?(ending, &(by_id[&1] == nil or by_id[&1]["status"] in @finished)) and
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
