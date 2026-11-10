defmodule HalC2.ClaudeTasksPropTest do
  @moduledoc """
  A state machine over a Claude thread's task list from Claude 5's task tools
  (`HalC2.Claude.ThreadRuntime`, `task_tools/2`) on the fake CLI in
  `test/support/fake_claude.py`. Claude creates, updates, deletes and lists tasks, in a
  turn of the user's or from a subagent (whose results are only text); a call fails or
  a hook blocks it; turns end; and the runtime restarts between turns, losing what it
  held. Claude keeps the session's list on disk as it goes, as Claude Code does.

  The promise: the turn's task list is always Claude's list, whatever came before, and
  a change to that list shows in it (Upstream #14964, #18398, #20985).
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Orchestration, StreamState}

  @moduletag timeout: :infinity

  @tid "claude-tasks-thread"
  @fake_claude Path.expand("../../test/support/fake_claude.py", __DIR__)
  @wait_ms 15_000
  # The fake's session, which names Claude's task list.
  @session "fake-session-1"

  property "a Claude thread's task list is the list Claude keeps",
    numtests: HalC2.Prop.numtests(30),
    max_size: 20 do
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
    home = HalC2.Prop.scratch_home("claude-tasks")
    work = Path.join(home, "work")
    claude_home = Path.join(home, "claude")
    File.mkdir_p!(work)
    File.mkdir_p!(claude_home)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
    Process.put(:claude_home, claude_home)
    Application.put_env(:hal_c2, :claude_command, ["python3", "-u", @fake_claude])

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

    # Claude's home, where it keeps the session's task list.
    {:ok, _} =
      HalC2.Settings.update(fn settings ->
        put_in(settings, [Access.key("providerInstances", %{}), "claudeAgent"], %{
          "driver" => "claudeAgent",
          "enabled" => true,
          "config" => %{"homePath" => claude_home}
        })
      end)

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

  # tasks: Claude's list, oldest first, as `{id, subject, status}`. next: the id Claude
  # gives the next task. open: a turn is running. sub: that turn started a subagent.
  # n: the next message number. calls: tool calls made, which name their ids.
  def initial_state, do: %{tasks: [], next: 1, open: false, sub: false, n: 1, calls: 0}

  @statuses ["pending", "in_progress", "completed"]

  def command(%{open: false, n: n}) do
    frequency([
      {4, {:call, __MODULE__, :open_turn, [n]}},
      {1, {:call, __MODULE__, :restart, []}}
    ])
  end

  def command(%{tasks: tasks} = state) do
    by = oneof([:root, :subagent])
    ids = Enum.map(tasks, &elem(&1, 0))
    some_id = if ids == [], do: exactly("1"), else: oneof(ids ++ ["99"])

    frequency([
      {4, {:call, __MODULE__, :create, [state.next, oneof(["Inspect", "Fix", "Test"]), by]}},
      {4, {:call, __MODULE__, :update, [some_id, oneof(@statuses), by]}},
      {1, {:call, __MODULE__, :delete, [some_id]}},
      {1, {:call, __MODULE__, :list, []}},
      {2, {:call, __MODULE__, :refused, [some_id, oneof([:failed, :blocked, :unsuccessful])]}},
      {2, {:call, __MODULE__, :end_turn, []}}
    ])
  end

  def precondition(%{open: open}, {:call, _, fun, _}) when fun in [:open_turn, :restart],
    do: not open

  def precondition(%{open: open, next: next}, {:call, _, :create, [id, _, _]}),
    do: open and id == next

  def precondition(%{open: open}, _call), do: open

  def next_state(state, _result, {:call, _, :open_turn, [_n]}),
    do: %{state | open: true, sub: false, n: state.n + 1}

  def next_state(state, _result, {:call, _, :restart, []}), do: state

  def next_state(state, _result, {:call, _, :end_turn, []}), do: %{state | open: false}

  def next_state(state, _result, {:call, _, :create, [id, subject, by]}),
    do: %{
      called(state, by)
      | tasks: state.tasks ++ [{"#{id}", subject, "pending"}],
        next: state.next + 1
    }

  def next_state(state, _result, {:call, _, :update, [id, status, by]}) do
    tasks =
      Enum.map(state.tasks, fn
        {^id, subject, _} -> {id, subject, status}
        task -> task
      end)

    %{called(state, by) | tasks: tasks}
  end

  def next_state(state, _result, {:call, _, :delete, [id]}),
    do: %{called(state, :root) | tasks: List.keydelete(state.tasks, id, 0)}

  def next_state(state, _result, {:call, _, fun, _}) when fun in [:list, :refused],
    do: called(state, :root)

  defp called(state, :subagent), do: %{state | sub: true, calls: state.calls + 1}
  defp called(state, :root), do: %{state | calls: state.calls + 1}

  def postcondition(state, call, seen) do
    next = next_state(state, seen, call)
    want = for {id, subject, status} <- next.tasks, do: {"task-#{id}", subject, shown(status)}

    case call do
      {:call, _, fun, _} when fun in [:open_turn, :restart, :end_turn] ->
        true

      # A change to the list always shows; anything else leaves it as it was, if the
      # turn shows one yet.
      {:call, _, _, _} ->
        if next.tasks != state.tasks, do: seen == want, else: seen in [nil, want]
    end
  end

  defp shown("in_progress"), do: "running"
  defp shown(status), do: status

  # --- commands -------------------------------------------------------------------

  def open_turn(n) do
    runs = run_count()

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => @tid,
        "messageId" => "m#{n}",
        "text" => "wait for me #{n}",
        "attachments" => [],
        "dispatchMode" => %{"type" => "queue_after_active"}
      })

    await(fn ->
      run = current() |> StreamState.list("run") |> Enum.find(&(&1["status"] == "running"))
      pid = runtime_pid()

      run_count() == runs + 1 and run != nil and pid != nil and
        match?(%{turn: %{}}, :sys.get_state(pid))
    end)

    # The fake names its session once it reads the message, which may come after the
    # first task call here; saying it first keeps the order Claude's would have.
    claude_says(%{"type" => "system", "subtype" => "init", "session_id" => @session})
    :ok
  end

  # Between turns the runtime goes, and what it held with it.
  def restart do
    with pid when pid != nil <- runtime_pid() do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      after
        @wait_ms -> raise "the runtime did not go"
      end
    end

    :ok
  end

  def end_turn do
    claude_says(%{"type" => "result", "subtype" => "success", "is_error" => false})
    await(fn -> Enum.all?(StreamState.list(current(), "run"), &(&1["status"] != "running")) end)
    :ok
  end

  def create(id, subject, by) do
    id = "#{id}"
    save_task(id, %{"id" => id, "subject" => subject, "status" => "pending"})

    output =
      if by == :subagent,
        do: "Task ##{id} created successfully: #{subject}",
        else: %{"task" => %{"id" => id, "subject" => subject}}

    task_call("TaskCreate", %{"subject" => subject, "description" => "Work on it"}, output, by)
  end

  def update(id, status, by) do
    known? =
      case read_task(id) do
        nil ->
          false

        task ->
          save_task(id, %{task | "status" => status})
          true
      end

    output =
      cond do
        by == :subagent and known? -> "Updated task ##{id} status"
        by == :subagent -> "Task not found"
        true -> %{"success" => known?, "taskId" => id, "updatedFields" => ["status"]}
      end

    task_call("TaskUpdate", %{"taskId" => id, "status" => status}, output, by)
  end

  def delete(id) do
    known? = File.rm(task_path(id)) == :ok

    task_call(
      "TaskUpdate",
      %{"taskId" => id, "status" => "deleted"},
      %{"success" => known?, "taskId" => id, "updatedFields" => ["deleted"]},
      :root
    )
  end

  def list do
    tasks =
      for name <- task_files(), task = read_task(Path.rootname(name)), do: task

    task_call("TaskList", %{}, %{"tasks" => tasks}, :root)
  end

  # A call that changed nothing: it failed, a hook blocked it (text, no error flag), or
  # Claude reported it unsuccessful.
  def refused(id, how) do
    update = %{"taskId" => id, "status" => "completed"}

    case how do
      :failed -> task_call("TaskUpdate", update, "Task not found", :root, error: true)
      :blocked -> task_call("TaskUpdate", update, "Blocked by a hook", :subagent)
      :unsuccessful -> task_call("TaskUpdate", update, %{"success" => false}, :root)
    end
  end

  # --- Claude -------------------------------------------------------------------------

  # Claude calls a task tool (in its subagent's turn when `by` is :subagent, starting
  # that subagent first) and reports `output`; then the turn's task list, once the
  # runtime has handled it.
  defp task_call(name, input, output, by, opts \\ []) do
    id = "tool-#{System.unique_integer([:positive])}"
    under = if by == :subagent, do: %{"parent_tool_use_id" => subagent()}, else: %{}

    claude_says(
      Map.merge(under, %{
        "type" => "assistant",
        "message" => %{
          "id" => "m-#{id}",
          "content" => [%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}]
        }
      })
    )

    result = %{
      "type" => "tool_result",
      "tool_use_id" => id,
      "content" => if(is_binary(output), do: output, else: "Task tool finished."),
      "is_error" => opts[:error] == true
    }

    user =
      Map.merge(under, %{
        "type" => "user",
        "message" => %{"role" => "user", "content" => [result]}
      })

    claude_says(if(is_map(output), do: Map.put(user, "tool_use_result", output), else: user))
    _ = :sys.get_state(runtime_pid())
    turn_tasks()
  end

  # The running turn's subagent, started on first use.
  defp subagent do
    run = current() |> StreamState.list("run") |> Enum.find(&(&1["status"] == "running"))
    agent = "agent-#{run["id"]}"

    unless Process.get({:subagent, agent}) do
      claude_says(%{
        "type" => "assistant",
        "message" => %{
          "id" => "m-#{agent}",
          "content" => [
            %{
              "type" => "tool_use",
              "id" => agent,
              "name" => "Agent",
              "input" => %{"description" => "Helper", "prompt" => "Help with the tasks"}
            }
          ]
        }
      })

      claude_says(%{
        "type" => "system",
        "subtype" => "task_started",
        "task_id" => "task-#{agent}",
        "tool_use_id" => agent,
        "description" => "Helper",
        "task_type" => "local_agent"
      })

      Process.put({:subagent, agent}, true)
    end

    agent
  end

  # The running turn's task list, or nil when it shows none.
  defp turn_tasks do
    state = current()
    run = state |> StreamState.list("run") |> Enum.find(&(&1["status"] == "running"))

    case run && StreamState.get(state, "plan")["plan:claudeAgent:tasks:#{run["id"]}"] do
      nil -> nil
      plan -> for step <- plan["steps"], do: {step["id"], step["text"], step["status"]}
    end
  end

  # Where Claude keeps the session's tasks, one file each.
  defp task_dir, do: Path.join([Process.get(:claude_home), "tasks", @session])

  defp task_path(id), do: Path.join(task_dir(), "#{id}.json")

  defp task_files do
    case File.ls(task_dir()) do
      {:ok, names} -> Enum.sort_by(names, &String.to_integer(Path.rootname(&1)))
      {:error, _} -> []
    end
  end

  defp save_task(id, task) do
    File.mkdir_p!(task_dir())
    File.write!(task_path(id), JSON.encode!(task))
  end

  defp read_task(id) do
    case File.read(task_path(id)) do
      {:ok, text} -> JSON.decode!(text)
      {:error, _} -> nil
    end
  end

  defp claude_says(message) do
    pid = runtime_pid()
    send(pid, {:claude, :sys.get_state(pid).session, {:message, message}})
  end

  defp run_count, do: length(StreamState.list(current(), "run"))

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
