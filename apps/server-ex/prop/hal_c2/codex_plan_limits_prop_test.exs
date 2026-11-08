defmodule HalC2.CodexPlanLimitsPropTest do
  @moduledoc """
  A state machine over one Codex thread (`HalC2.Codex.ThreadRuntime`) running turn
  after turn: a turn may start subagents that report their own reasoning effort, or
  none, and ends completed, failed, stopped on an ordinary usage limit, or stopped on
  a ChatGPT plan's limit for other apps (a personal plan's or a Business workspace's,
  its code reported in the error's details, inside a JSON message, or as ChatGPT's
  prose); between turns Codex may report its usage windows.

  The promise: the thread's row carries the latest turn's sharing-limit code as
  `lastErrorCode` (class `usage_limit`, no reset), and no sharing code once a later
  turn ends otherwise. A usage window reported after a sharing stop never gives it a reset,
  while an ordinary usage stop learns its reset from one. A subagent's thread runs at
  the effort its spawn reported, and at none when it reported none, whatever the
  parent's.

  Turns run on the fake app-server in `test/support/fake_codex.py`, which leaves a
  turn saying "wait" open; the test plays Codex's side of its end.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @tid "codex-thread"
  @fake_codex Path.expand("../../test/support/fake_codex.py", __DIR__)
  @wait_ms 10_000
  @selection %{
    "instanceId" => "codex",
    "model" => "gpt-5.4",
    "options" => [%{"id" => "reasoningEffort", "value" => "medium"}]
  }
  @personal "subscription_sharing_usage_limit_exceeded"
  @workspace "subscription_sharing_workplace_individual_usage_limit_exceeded"
  @ends [
    :completed,
    :failed,
    :usage,
    {@personal, :details},
    {@personal, :json},
    {@personal, :prose},
    {@workspace, :details},
    {@workspace, :json}
  ]

  property "a Codex thread shows the plan limit its latest turn stopped on",
    numtests: HalC2.Prop.numtests(20),
    max_size: 16 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        start()
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()
        Application.delete_env(:hal_c2, :codex_command)

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp start do
    home = HalC2.Prop.scratch_home("codex-plan-limits")
    work = Path.join(home, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
    Application.put_env(:hal_c2, :codex_command, ["python3", "-u", @fake_codex])

    HalC2.Prop.start_services([
      {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
      HalC2.Streams,
      HalC2.Shell,
      HalC2.Orchestration.TurnWatch,
      HalC2.Mcp,
      {Registry, keys: :unique, name: HalC2.Codex.Registry},
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

    :ok = HalC2.Streams.subscribe(@tid, self(), nil)
    :ok = HalC2.Shell.subscribe(self())

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => @tid,
        "projectId" => "project-1",
        "title" => "Codex",
        "modelSelection" => @selection,
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => work
      })
  end

  # --- model ---------------------------------------------------------------------

  # running: whether a turn is open; spawned: subagents started so far; ended: how
  # the latest turn ended (nil before one did); windows: whether Codex has reported
  # a used-up usage window; reset: whether the latest turn's failure carries a reset.
  def initial_state,
    do: %{running: false, spawned: 0, ended: nil, windows: false, reset: false}

  def command(%{running: false}) do
    frequency([
      {3, {:call, __MODULE__, :turn, []}},
      {1, {:call, __MODULE__, :report_windows, []}}
    ])
  end

  def command(state) do
    frequency([
      {2, {:call, __MODULE__, :spawn, [state.spawned + 1, oneof(["low", "high", nil, ""])]}},
      {3, {:call, __MODULE__, :end_turn, [oneof(@ends)]}}
    ])
  end

  def precondition(state, {:call, _, :turn, []}), do: not state.running
  # Codex reports to the session a turn started.
  def precondition(state, {:call, _, :report_windows, []}),
    do: not state.running and state.ended != nil

  def precondition(state, {:call, _, :spawn, [n, _]}),
    do: state.running and n == state.spawned + 1

  def precondition(state, {:call, _, :end_turn, [_]}), do: state.running

  def next_state(state, _result, {:call, _, :turn, []}),
    do: %{state | running: true, reset: false}

  def next_state(state, _result, {:call, _, :spawn, _}),
    do: %{state | spawned: state.spawned + 1}

  # An ordinary usage stop takes its reset from the windows already reported.
  def next_state(state, _result, {:call, _, :end_turn, [ended]}),
    do: %{state | running: false, ended: ended, reset: ended == :usage and state.windows}

  def next_state(state, _result, {:call, _, :report_windows, []}),
    do: %{state | windows: true, reset: state.reset or state.ended == :usage}

  # The child's thread runs at the effort its spawn reported, or at none.
  def postcondition(_state, {:call, _, :spawn, [_, effort]}, seen),
    do: seen == if(effort in [nil, ""], do: nil, else: effort)

  def postcondition(_state, {:call, _, :turn, []}, seen), do: seen == :ok

  def postcondition(state, {:call, _, _, _} = call, seen),
    do: seen == expected(next_state(state, nil, call))

  defp expected(%{ended: {code, _}}),
    do: %{code: code, class: "usage_limit", reset: false, message: message(code)}

  # An ordinary usage stop carries Codex's own code for it.
  defp expected(%{ended: :usage, reset: reset}),
    do: %{code: "usageLimitExceeded", class: "usage_limit", reset: reset, message: :any}

  defp expected(%{ended: :completed}), do: %{code: nil, class: nil, reset: false, message: nil}

  defp expected(%{ended: :failed}),
    do: %{code: nil, class: nil, reset: false, message: "the turn failed"}

  defp message(code), do: HalC2.Codex.SharingLimit.failure(code)["message"]

  # --- commands ------------------------------------------------------------------

  def turn do
    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => @tid,
        "messageId" => "m#{System.unique_integer([:positive])}",
        "text" => "wait for it",
        "attachments" => [],
        "modelSelection" => @selection,
        "dispatchMode" => %{"type" => "start_immediately"}
      })

    await_until(
      fn ->
        case runtime() do
          {_, %{turn: %{native_turn_id: turn}}} when is_binary(turn) -> true
          _ -> false
        end
      end,
      "no Codex turn"
    )
  end

  # Codex starts subagent `n`, reporting `effort` for it (none for nil).
  def spawn(n, effort) do
    {_, runtime} = runtime()

    item =
      %{
        "type" => "collabAgentToolCall",
        "id" => "collab-#{n}",
        "tool" => "spawnAgent",
        "prompt" => "task #{n}",
        "senderThreadId" => runtime.native_thread_id,
        "receiverThreadIds" => ["native-child-#{n}"],
        "status" => "inProgress",
        "agentsStates" => %{}
      }
      |> then(&if(effort == nil, do: &1, else: Map.put(&1, "reasoningEffort", effort)))

    notify("item/started", Map.put(context(), "item", item))
    settle_runtime()

    case Enum.find(StreamState.list(current(@tid), "subagent"), &(&1["prompt"] == "task #{n}")) do
      nil ->
        :no_subagent

      %{"childThreadId" => child} ->
        options = current(child) |> StreamState.get("thread") |> get_in([child, "modelSelection"])

        Enum.find_value((options || %{})["options"] || [], fn
          %{"id" => "reasoningEffort", "value" => value} -> value
          _ -> nil
        end)
    end
  end

  def end_turn(ended) do
    {_, runtime} = runtime()
    turn = %{"id" => runtime.turn.native_turn_id, "status" => "failed"}

    case ended do
      :completed ->
        notify("turn/completed", %{"turn" => %{turn | "status" => "completed"}})

      :failed ->
        notify("turn/completed", %{
          "turn" => Map.put(turn, "error", %{"message" => "the turn failed"})
        })

      :usage ->
        error(%{
          "message" => "You've hit your usage limit.",
          "codexErrorInfo" => "usageLimitExceeded"
        })

        notify("turn/completed", %{"turn" => turn})

      {code, :details} ->
        error(%{
          "message" => "Codex could not continue.",
          "codexErrorInfo" => "other",
          "additionalDetails" => code
        })

        notify("turn/completed", %{"turn" => turn})

      {code, :json} ->
        message = JSON.encode!(%{"error" => %{"code" => code, "message" => "limit reached"}})
        notify("turn/completed", %{"turn" => Map.put(turn, "error", %{"message" => message})})

      {_personal, :prose} ->
        error(%{"message" => "The user has reached their Subscription Sharing usage limit."})
        notify("turn/completed", %{"turn" => turn})
    end

    await_until(fn -> match?({_, %{turn: nil}}, runtime()) end, "the turn never ended")
    settle_runtime()
    observed()
  end

  # Codex reports a used-up weekly window resetting in two hours.
  def report_windows do
    reset = DateTime.utc_now() |> DateTime.add(2 * 3600, :second) |> DateTime.to_unix()

    notify("account/rateLimits/updated", %{
      "rateLimits" => %{
        "limitId" => "codex",
        "primary" => %{"usedPercent" => 40, "windowDurationMins" => 300},
        "secondary" => %{
          "usedPercent" => 100,
          "windowDurationMins" => 10_080,
          "resetsAt" => reset
        }
      }
    })

    settle_runtime()
    observed()
  end

  # --- the real side ---------------------------------------------------------------

  defp error(error),
    do: notify("error", Map.merge(context(), %{"willRetry" => false, "error" => error}))

  defp context do
    {_, runtime} = runtime()
    %{"threadId" => runtime.native_thread_id, "turnId" => runtime.turn.native_turn_id}
  end

  # The latest run's failure as the stream holds it (`resetAt` is set there and
  # nowhere else), and the shell row's code, class and message for it.
  defp observed do
    state = current(@tid)
    {_, runtime} = runtime()
    run = state |> StreamState.list("run") |> Enum.find(&(&1["id"] == runtime.last_run))

    failure =
      HalC2.Projection.ThreadError.latest_root_provider_failure(
        run,
        StreamState.list(state, "turn-item")
      )

    # The row is derived apart from the stream: wait until it shows the run ended.
    row =
      await_row(
        &(&1["latestRunId"] == runtime.last_run and &1["latestRunCompletedAt"] != nil),
        System.monotonic_time(:millisecond) + @wait_ms
      )

    %{
      code: row["lastErrorCode"],
      class: any_class(row["lastErrorClass"]),
      reset: is_binary((failure || %{})["resetAt"]),
      message: any_message(row["lastError"], row["lastErrorClass"])
    }
  end

  # A failed turn's own class, and an ordinary usage stop's wording, are other
  # features' to pin down; here only whether they say usage limit matters.
  defp any_class("usage_limit"), do: "usage_limit"
  defp any_class(_class), do: nil

  defp any_message(message, "usage_limit") do
    if Enum.any?([@personal, @workspace], &(message(&1) == message)), do: message, else: :any
  end

  defp any_message(message, _class), do: message

  defp await_row(ready?, deadline) do
    row =
      case HalC2.Shell.row(node(), @tid) do
        {_kind, row} -> row
        nil -> %{}
      end

    if ready?.(row) do
      row
    else
      receive do
        {:hal_c2_shell, {:rows, _, _}} -> await_row(ready?, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) -> row
      end
    end
  end

  defp notify(method, params) do
    {pid, runtime} = runtime()
    send(pid, {:json_rpc, runtime.conn, {:notification, method, params}})
  end

  defp settle_runtime do
    case runtime() do
      {pid, _} -> GenServer.call(pid, :settle)
      nil -> :ok
    end
  end

  defp runtime do
    case Registry.lookup(HalC2.Codex.Registry, @tid) do
      [{pid, _}] -> {pid, :sys.get_state(pid)}
      [] -> nil
    end
  end

  defp await_until(fun, what, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @wait_ms

    if fun.() do
      :ok
    else
      receive do
        {:hal_c2_stream, @tid, _} -> await_until(fun, what, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) -> {:timeout, what}
      end
    end
  end

  defp current(tid), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(tid))
end
