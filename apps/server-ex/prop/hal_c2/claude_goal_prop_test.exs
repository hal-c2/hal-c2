defmodule HalC2.ClaudeGoalPropTest do
  @moduledoc """
  A state machine over a Claude thread's goal (`/goal`, `HalC2.Claude.ThreadRuntime`)
  on the fake CLI in `test/support/fake_claude.py`: the user sets a goal Claude works
  on in the turn (one check comes back unmet first) or one Claude hands to a
  background subagent, sends an ordinary turn, has a turn stopped by a hook of their
  own, clears the goal, or sends `/goal pause` or `/goal resume`; a background
  subagent finishes, which Claude answers in a turn of its own; and Claude goes down
  before saving the prompt it was sent, so the next turn starts a new conversation.

  The promise: the thread shows the goal Claude has, active until a turn Claude worked
  in ends normally with no background subagent left running, then complete
  (Upstream #15592, #16598); a pause or resume is refused and never reaches Claude
  (Upstream #25426); a goal lost with the conversation it lived in is shown as none;
  and every run ends.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}

  @moduletag timeout: :infinity

  @tid "claude-goal-thread"
  @fake_claude Path.expand("../../test/support/fake_claude.py", __DIR__)
  @wait_ms 15_000

  property "a Claude goal is complete only once a turn ends normally with no background subagent",
    numtests: HalC2.Prop.numtests(30),
    max_size: 12 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        start()
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()
        Application.delete_env(:hal_c2, :claude_command)
        System.delete_env("CLAUDE_CONFIG_DIR")

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp start do
    home = HalC2.Prop.scratch_home("claude-goal")
    work = Path.join(home, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
    prompts = Path.join(home, "prompts.log")
    Process.put(:prompts, prompts)
    # Where the fake keeps its transcripts, and where the MC looks for them.
    System.put_env("CLAUDE_CONFIG_DIR", Path.join(home, "claude"))

    Application.put_env(:hal_c2, :claude_command, [
      "env",
      "FAKE_SESSIONS=1",
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

  # n: the next message number. turns: the messages the fake got. fake_turns: those the
  # running fake got (it numbers its tool calls by them). runs: the thread's run
  # statuses. goal: nil or {objective, status, checks}. background: the background
  # subagents still running, oldest first. said_background: whether a message said "in
  # the background", which a new conversation's history would repeat to the fake.
  # lost: Claude went down before saving the prompt it was sent.
  def initial_state,
    do: %{
      n: 1,
      turns: 0,
      fake_turns: 0,
      runs: [],
      goal: nil,
      background: [],
      said_background: false,
      lost: false
    }

  # After a loss the next turn is an ordinary one: the fake reads a new conversation's
  # history and message as one text, and would not see a command in it.
  def command(%{n: n, lost: true}), do: {:call, __MODULE__, :user_turn, [n]}

  def command(%{n: n} = state) do
    frequency(
      [
        {3, {:call, __MODULE__, :set_goal, [n, oneof([:in_the_turn, :in_the_background])]}},
        {2, {:call, __MODULE__, :user_turn, [n]}},
        {1, {:call, __MODULE__, :hook_stop, [n]}},
        {1, {:call, __MODULE__, :clear_goal, [n]}},
        {1, {:call, __MODULE__, :pause_or_resume, [n, oneof(["pause", "resume"])]}}
      ] ++
        if(state.background == [],
          do: [],
          else: [{3, {:call, __MODULE__, :subagent_finishes, [hd(state.background)]}}]
        ) ++
        if(state.turns > 0 and state.background == [] and not state.said_background,
          do: [{1, {:call, __MODULE__, :lose_session, []}}],
          else: []
        )
    )
  end

  def precondition(state, {:call, _, :subagent_finishes, [agent]}),
    do: agent in state.background and not state.lost

  def precondition(state, {:call, _, :lose_session, []}),
    do:
      state.turns > 0 and state.background == [] and not state.said_background and
        not state.lost

  def precondition(%{lost: true}, {:call, _, name, _}), do: name == :user_turn
  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :set_goal, [n, how]}) do
    state = message_sent(state, "completed")

    case how do
      :in_the_turn ->
        ended(%{state | goal: {"objective #{n}", "active", 1}})

      :in_the_background ->
        %{
          state
          | goal: {"objective #{n} in the background", "active", 0},
            background: state.background ++ ["agent-#{state.fake_turns}"],
            said_background: true
        }
    end
  end

  def next_state(state, _result, {:call, _, :user_turn, [_n]}),
    do: state |> message_sent("completed") |> ended()

  def next_state(state, _result, {:call, _, :hook_stop, [_n]}),
    do: message_sent(state, "completed")

  def next_state(state, _result, {:call, _, :clear_goal, [_n]}),
    do: %{message_sent(state, "completed") | goal: nil}

  # Refused before Claude sees it: the fake's turn count stays.
  def next_state(state, _result, {:call, _, :pause_or_resume, [_n, _word]}),
    do: %{state | n: state.n + 1, runs: state.runs ++ ["failed"]}

  def next_state(state, _result, {:call, _, :subagent_finishes, [agent]}),
    do:
      ended(%{state | runs: state.runs ++ ["completed"], background: state.background -- [agent]})

  # The goal still shows until the next turn finds the conversation gone.
  def next_state(state, _result, {:call, _, :lose_session, []}),
    do: %{state | lost: true, fake_turns: 0}

  # A turn after a loss starts a new conversation, which holds no goal.
  defp message_sent(state, status) do
    state = if state.lost, do: %{state | goal: nil, lost: false}, else: state

    %{
      state
      | n: state.n + 1,
        turns: state.turns + 1,
        fake_turns: state.fake_turns + 1,
        runs: state.runs ++ [status]
    }
  end

  # A turn Claude worked in ended normally: the goal's check passed unless background
  # work deferred it.
  defp ended(%{goal: {objective, "active", checks}, background: []} = state),
    do: %{state | goal: {objective, "complete", checks}}

  defp ended(state), do: state

  def postcondition(state, call, seen) do
    next = next_state(state, seen, call)

    seen.statuses == next.runs and seen.goal == (next.goal && Tuple.to_list(next.goal)) and
      length(seen.prompts) == next.turns and
      not Enum.any?(seen.prompts, &(&1 in ["/goal pause", "/goal resume"])) and
      seen.runtime == nil and
      not (match?([_, "complete", _], seen.goal) and next.background != [])
  end

  # --- commands -------------------------------------------------------------------

  # "/goal OBJECTIVE": Claude works, a check comes back unmet, and Claude ends the turn
  # normally; or Claude hands the work to a background subagent and ends the turn.
  def set_goal(n, :in_the_turn) do
    runs = run_count()
    send_message(n, "/goal objective #{n}")
    await(fn -> goal_now() == ["objective #{n}", "active", 1] end)
    claude_says(%{"type" => "result", "subtype" => "success", "is_error" => false})
    settled(runs + 1)
  end

  def set_goal(n, :in_the_background) do
    runs = run_count()
    send_message(n, "/goal objective #{n} in the background")
    settled(runs + 1)
  end

  def user_turn(n) do
    runs = run_count()
    send_message(n, "hello")
    settled(runs + 1)
  end

  # Claude answers part of the turn and a Stop hook of the user's ends it.
  def hook_stop(n) do
    runs = run_count()
    send_message(n, "answer halfway")
    await(fn -> answered_halfway?() end)

    claude_says(%{
      "type" => "result",
      "subtype" => "success",
      "is_error" => false,
      "terminal_reason" => "stop_hook_prevented"
    })

    settled(runs + 1)
  end

  def clear_goal(n) do
    runs = run_count()
    send_message(n, "/goal clear")
    settled(runs + 1)
  end

  def pause_or_resume(n, word) do
    runs = run_count()
    send_message(n, "/goal #{word}")
    settled(runs + 1)
  end

  # The subagent ends, and Claude answers that in a turn of its own.
  def subagent_finishes(agent) do
    runs = run_count()

    claude_says(%{
      "type" => "system",
      "subtype" => "task_notification",
      "task_id" => "task-#{agent}",
      "tool_use_id" => agent,
      "status" => "completed",
      "summary" => "Surveyed"
    })

    claude_says(%{
      "type" => "assistant",
      "message" => %{
        "id" => "m-done-#{agent}",
        "content" => [%{"type" => "text", "text" => "The survey is done"}]
      }
    })

    await(fn -> run_count() == runs + 1 end)
    claude_says(%{"type" => "result", "subtype" => "success", "is_error" => false})
    settled(runs + 1)
  end

  # The runtime lets go of Claude between turns, as when the MC restarts, and the
  # transcript Claude kept holds none of the prompts it was sent.
  def lose_session do
    pid = runtime_pid()
    ref = Process.monitor(pid)
    :ok = GenServer.call(pid, :release)

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    after
      @wait_ms -> raise "the runtime did not let go"
    end

    for path <-
          Path.wildcard(Path.join(System.get_env("CLAUDE_CONFIG_DIR"), "projects/*/*.jsonl")) do
      kept = path |> File.stream!() |> Enum.reject(&(JSON.decode!(&1)["type"] == "user"))
      File.write!(path, kept)
    end

    settled(run_count())
  end

  # --- the runtime ------------------------------------------------------------------

  # Once the thread has `count` runs and none is still going: their statuses, the
  # goal it shows, and the runtime's turn.
  defp settled(count) do
    await(fn ->
      runs = StreamState.list(current(), "run")

      length(runs) == count and
        Enum.all?(runs, &(&1["status"] in ["completed", "failed", "interrupted"]))
    end)

    %{
      statuses:
        current()
        |> StreamState.list("run")
        |> Enum.sort_by(& &1["ordinal"])
        |> Enum.map(& &1["status"]),
      goal: goal_now(),
      runtime: if(pid = runtime_pid(), do: :sys.get_state(pid).turn),
      prompts: prompts()
    }
  end

  defp goal_now do
    case current() |> StreamState.list("provider-thread") |> Enum.find_value(& &1["goal"]) do
      nil -> nil
      goal -> [goal["objective"], goal["status"], goal["checks"]]
    end
  end

  defp answered_halfway? do
    case Enum.find(StreamState.list(current(), "run"), &(&1["status"] == "running")) do
      nil ->
        false

      run ->
        Enum.any?(
          StreamState.list(current(), "message"),
          &(&1["runId"] == run["id"] and &1["text"] == "Half an answer")
        )
    end
  end

  # The user messages Claude got, in order.
  defp prompts do
    case File.read(Process.get(:prompts)) do
      {:ok, log} -> log |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      {:error, :enoent} -> []
    end
  end

  defp claude_says(message) do
    pid = runtime_pid()
    send(pid, {:claude, :sys.get_state(pid).session, {:message, message}})
  end

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
