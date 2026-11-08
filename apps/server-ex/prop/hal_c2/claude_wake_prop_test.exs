defmodule HalC2.ClaudeWakePropTest do
  @moduledoc """
  A state machine over the turns one Claude thread (`HalC2.Claude.ThreadRuntime`)
  runs by itself (wakes), on the fake CLI in `test/support/fake_claude.py`: the
  user's own turns, a wake Claude opens and ends between turns (at once, or after
  its run started), and a wake the user's next turn takes over, where Claude answers
  the user's message as a turn of its own after the wake's result ("steer"), or folds
  it into the wake turn so that one result answers both ("fold", Upstream #28010),
  or had already ended the wake before the user's turn started, where a subagent the
  wake launched in the background may finish during the user's turn, before the wake's
  run has replayed its launch (Upstream #23561).

  The promise: every run ends once Claude has said all it will, with no run left
  running or queued, no subagent left running, and the runtime holding no turn and no
  wake; each user message reaches Claude once, and a wake's run sends Claude nothing.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}

  @moduletag timeout: :infinity

  @tid "claude-wake-thread"
  @fake_claude Path.expand("../../test/support/fake_claude.py", __DIR__)
  @wait_ms 15_000

  property "every Claude run ends, whether Claude wakes by itself or a user turn takes the wake over",
    numtests: HalC2.Prop.numtests(30),
    max_size: 12 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        start()
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()
        Application.delete_env(:hal_c2, :claude_command)

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp start do
    home = HalC2.Prop.scratch_home("claude-wake")
    work = Path.join(home, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
    prompts = Path.join(home, "prompts.log")
    Process.put(:prompts, prompts)

    Application.put_env(:hal_c2, :claude_command, [
      "env",
      "FAKE_CLAUDE_PROMPT_LOG=#{prompts}",
      "python3",
      "-u",
      @fake_claude
    ])

    HalC2.Prop.start_services([
      {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
      HalC2.Streams,
      HalC2.Shell,
      HalC2.Orchestration.TurnWatch,
      {Registry, keys: :unique, name: HalC2.Claude.Registry},
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Codex.Registry},
        id: :codex_registry
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

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => @tid,
        "projectId" => "project-1",
        "title" => "Claude",
        "modelSelection" => %{"instanceId" => "claudeAgent", "model" => "claude-opus-4-6"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => work
      })

    :ok
  end

  # --- model ----------------------------------------------------------------------

  # runs: the thread's runs, every one ended. prompts: the user messages Claude got.
  # n: the next message number.
  def initial_state, do: %{runs: 0, prompts: 0, n: 1}

  # Claude wakes only once it has a process, which the first user turn starts.
  def command(%{prompts: 0, n: n}), do: {:call, __MODULE__, :user_turn, [n]}

  def command(%{n: n}) do
    frequency([
      {2, {:call, __MODULE__, :user_turn, [n]}},
      {2, {:call, __MODULE__, :wake, [oneof([:at_once, :after_its_run_started])]}},
      {3,
       {:call, __MODULE__, :take_over, [n, oneof([:steer, :fold, :ended, :ended_with_subagent])]}}
    ])
  end

  # Shrinking keeps a wake behind the user turn that started Claude's process.
  def precondition(%{prompts: 0}, {:call, _, fun, _args}), do: fun == :user_turn
  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :user_turn, [_n]}),
    do: %{state | runs: state.runs + 1, prompts: state.prompts + 1, n: state.n + 1}

  def next_state(state, _result, {:call, _, :wake, [_how]}), do: %{state | runs: state.runs + 1}

  # The user's run and the wake's, queued behind it.
  def next_state(state, _result, {:call, _, :take_over, [_n, _how]}),
    do: %{state | runs: state.runs + 2, prompts: state.prompts + 1, n: state.n + 1}

  def postcondition(state, call, seen) do
    next = next_state(state, seen, call)

    seen.statuses == List.duplicate("completed", next.runs) and seen.prompts == next.prompts and
      seen.subagents == [] and seen.runtime == {nil, nil}
  end

  # --- commands -------------------------------------------------------------------

  # The user's turn, which Claude answers.
  def user_turn(n) do
    runs = run_count()
    send_message(n, "hello")
    settled(runs + 1)
  end

  # Claude answers background work by itself between turns, and ends that turn: at
  # once, or once the thread's run for it has started.
  def wake(how) do
    runs = run_count()
    claude_says(assistant("m-wake-#{runs}", "The build passed"))

    if how == :after_its_run_started,
      do: await(fn -> match?([_ | _], running()) end)

    claude_says(%{"type" => "result", "subtype" => "success", "is_error" => false})
    settled(runs + 1)
  end

  # Claude opens a wake while the runtime is held, and the user's message is sent
  # before it is let go: the user's run comes first and the wake's queues behind it.
  # `:ended` ends the wake before the user's turn starts; `:ended_with_subagent` also
  # has the wake launch a subagent in the background, which finishes once the user's
  # turn has started.
  def take_over(n, how) do
    runs = run_count()
    pid = runtime_pid()
    :ok = :sys.suspend(pid)
    claude_says(assistant("m-wake-#{runs}", "The build passed"))
    agent = "agent-wake-#{runs}"
    if how == :ended_with_subagent, do: Enum.each(launch(agent), &claude_says/1)

    if how in [:ended, :ended_with_subagent],
      do: claude_says(%{"type" => "result", "subtype" => "success", "is_error" => false})

    text = if how == :fold, do: "fold this in", else: "hello"
    # The runtime receiving the turn's start is traced, to send after it.
    if how == :ended_with_subagent, do: :erlang.trace(pid, true, [:receive])
    # The send starts its turn inline, on the held runtime.
    send_task = Task.async(fn -> send_message(n, text) end)
    await(fn -> run_count() == runs + 1 end)

    if how == :ended_with_subagent do
      # Behind the turn's start in the runtime's mailbox, ahead of Claude's answer.
      receive do
        {:trace, ^pid, :receive, {:"$gen_call", _, {:start_turn, _}}} -> :ok
      after
        @wait_ms -> raise "the turn never started"
      end

      :erlang.trace(pid, false, [:receive])
      flush_traces(pid)

      claude_says(%{
        "type" => "system",
        "subtype" => "task_notification",
        "task_id" => "task-#{agent}",
        "tool_use_id" => agent,
        "status" => "completed",
        "summary" => "Done"
      })
    end

    :ok = :sys.resume(pid)
    Task.await(send_task, @wait_ms)
    settled(runs + 2)
  end

  # --- the runtime ------------------------------------------------------------------

  # Once the thread has `count` runs and none is still going: their statuses, the
  # user messages Claude got, and the runtime's turn and wake. A run that never ends
  # fails the wait.
  defp settled(count) do
    await(fn ->
      runs = StreamState.list(current(), "run")

      length(runs) == count and
        Enum.all?(runs, &(&1["status"] in ["completed", "failed", "interrupted"]))
    end)

    runtime =
      case runtime_pid() do
        nil -> {nil, nil}
        pid -> pid |> :sys.get_state() |> then(&{&1.turn, &1.wake})
      end

    %{
      statuses: current() |> StreamState.list("run") |> Enum.map(& &1["status"]),
      subagents:
        for(%{"status" => "running"} = sub <- StreamState.list(current(), "subagent"), do: sub),
      prompts: prompts(),
      runtime: runtime
    }
  end

  defp prompts do
    case File.read(Process.get(:prompts)) do
      {:ok, log} -> log |> String.split("\n", trim: true) |> length()
      {:error, :enoent} -> 0
    end
  end

  defp assistant(id, text),
    do: %{
      "type" => "assistant",
      "message" => %{"id" => id, "content" => [%{"type" => "text", "text" => text}]}
    }

  # Claude launching a subagent in the background, and registering its task.
  defp launch(agent),
    do: [
      %{
        "type" => "assistant",
        "message" => %{
          "id" => "m-#{agent}",
          "content" => [
            %{
              "type" => "tool_use",
              "id" => agent,
              "name" => "Agent",
              "input" => %{
                "description" => "Check",
                "prompt" => "Check",
                "run_in_background" => true
              }
            }
          ]
        }
      },
      %{
        "type" => "system",
        "subtype" => "task_started",
        "task_id" => "task-#{agent}",
        "tool_use_id" => agent,
        "description" => "Check",
        "task_type" => "local_agent",
        "is_backgrounded" => true
      }
    ]

  defp flush_traces(pid) do
    receive do
      {:trace, ^pid, _, _} -> flush_traces(pid)
    after
      0 -> :ok
    end
  end

  defp claude_says(message) do
    pid = runtime_pid()
    send(pid, {:claude, :sys.get_state(pid).session, {:message, message}})
  end

  defp running,
    do: Enum.filter(StreamState.list(current(), "run"), &(&1["status"] == "running"))

  defp run_count, do: length(StreamState.list(current(), "run"))

  defp send_message(n, text) do
    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => @tid,
        "messageId" => "m#{n}",
        "text" => text,
        "attachments" => [],
        "dispatchMode" => %{"type" => "queue_after_active"}
      })
  end

  defp runtime_pid do
    case Registry.lookup(HalC2.Claude.Registry, @tid) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # Until `fun` gives a truthy value, rechecked on each change to the thread's stream.
  defp await(fun, deadline \\ System.monotonic_time(:millisecond) + @wait_ms) do
    if value = fun.() do
      value
    else
      receive do
        {:hal_c2_stream, @tid, _} -> await(fun, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) -> raise "never got there"
      end
    end
  end

  defp current, do: HalC2.Streams.Server.state(HalC2.Streams.ensure(@tid))
end
