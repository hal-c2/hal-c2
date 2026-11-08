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
  run has replayed its launch (Upstream #23561). A wake also leaves a command running
  that the thread waits on (`hal_c2_background_wait`), whose end Claude answers in a
  wake of its own, never answers, or the user's next turn comes first; until one of
  those, the command holds the thread working.

  The promise: every run ends once Claude has said all it will, with no run left
  running or queued, no subagent or command left running, and the runtime holding no
  turn, no wake and no notice; each user message reaches Claude once, and a wake's run
  sends Claude nothing.
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
       {:call, __MODULE__, :take_over, [n, oneof([:steer, :fold, :ended, :ended_with_subagent])]}},
      {2,
       {:call, __MODULE__, :awaited_command, [n, oneof([:answered, :unanswered, :user_first])]}}
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

  # The wake that launched the command, then Claude's answer or the user's turn.
  def next_state(state, _result, {:call, _, :awaited_command, [_n, :answered]}),
    do: %{state | runs: state.runs + 2}

  def next_state(state, _result, {:call, _, :awaited_command, [_n, :unanswered]}),
    do: %{state | runs: state.runs + 1}

  def next_state(state, _result, {:call, _, :awaited_command, [_n, :user_first]}),
    do: %{state | runs: state.runs + 2, prompts: state.prompts + 1, n: state.n + 1}

  def postcondition(_state, {:call, _, :awaited_command, _}, %{held: false}), do: false

  def postcondition(state, call, seen) do
    next = next_state(state, seen, call)

    seen.statuses == List.duplicate("completed", next.runs) and seen.prompts == next.prompts and
      seen.subagents == [] and seen.commands == [] and seen.runtime == {nil, nil, []}
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

  # A wake launches a background command the thread then waits on, and Claude reports
  # it ended: Claude answers that in a wake (`:answered`), never does and the hold runs
  # out (its deadline's message is sent at once), or the user's turn starts first.
  # `held` is whether the command still held the thread once the notice was in.
  def awaited_command(n, how) do
    runs = run_count()
    tool = "bash-wake-#{runs}"
    task = "task-#{tool}"
    Enum.each(background_command(tool), &claude_says/1)
    claude_says(%{"type" => "result", "subtype" => "success", "is_error" => false})
    settled(runs + 1)
    {:ok, [^task]} = HalC2.Claude.ThreadRuntime.await_background(@tid, [task], true)

    claude_says(%{
      "type" => "system",
      "subtype" => "task_notification",
      "task_id" => task,
      "tool_use_id" => tool,
      "status" => "completed",
      "summary" => "Built"
    })

    _ = :sys.get_state(runtime_pid())
    held = Enum.any?(running_commands(), &(&1["nativeItemRef"]["nativeId"] == tool))

    case how do
      :answered ->
        claude_says(assistant("m-built-#{runs}", "It built"))
        claude_says(%{"type" => "result", "subtype" => "success", "is_error" => false})
        Map.put(settled(runs + 2), :held, held)

      :unanswered ->
        send(runtime_pid(), {:release_notices, task})
        await(fn -> running_commands() == [] end)
        Map.put(settled(runs + 1), :held, held)

      :user_first ->
        send_message(n, "hello")
        Map.put(settled(runs + 2), :held, held)
    end
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
        nil -> {nil, nil, []}
        pid -> pid |> :sys.get_state() |> then(&{&1.turn, &1.wake, &1.notices})
      end

    %{
      statuses: current() |> StreamState.list("run") |> Enum.map(& &1["status"]),
      subagents:
        for(%{"status" => "running"} = sub <- StreamState.list(current(), "subagent"), do: sub),
      commands: running_commands(),
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

  # Claude launching a command in the background, and registering its task.
  defp background_command(tool),
    do: [
      %{
        "type" => "assistant",
        "message" => %{
          "id" => "m-#{tool}",
          "content" => [
            %{
              "type" => "tool_use",
              "id" => tool,
              "name" => "Bash",
              "input" => %{"command" => "npm run build", "run_in_background" => true}
            }
          ]
        }
      },
      %{
        "type" => "system",
        "subtype" => "task_started",
        "task_id" => "task-#{tool}",
        "tool_use_id" => tool,
        "description" => "Build",
        "task_type" => "local_bash",
        "is_backgrounded" => true
      },
      %{
        "type" => "user",
        "message" => %{
          "role" => "user",
          "content" => [
            %{
              "type" => "tool_result",
              "tool_use_id" => tool,
              "content" => "Command running in background with ID: task-#{tool}",
              "is_error" => false
            }
          ]
        }
      }
    ]

  defp running_commands,
    do:
      for(
        %{"type" => "command_execution", "status" => "running"} = item <-
          StreamState.list(current(), "turn-item"),
        do: item
      )

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
