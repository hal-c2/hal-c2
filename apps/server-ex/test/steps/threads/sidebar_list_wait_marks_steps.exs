defmodule HalC2.Steps.Threads.SidebarListWaitMarks do
  @moduledoc """
  Steps for the background-work scenarios of `features/threads/sidebar-list.feature`:
  which work holds a finished thread Working.

  The MC's part is the row: `pendingBackgroundTasks` is what holds the thread (the
  clients show it Working while it is not empty, in the inbox once it is), and
  `runningBackgroundTasks` is everything still running. Claude runs on the fake CLI
  (`test/support/fake_claude.py`); its agent marks work through the
  `hal_c2_background_wait` MCP tool, as the real one does.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc.World

  # The section is the client's: the MC lists what holds a thread either way.
  step "the Working section is on", context do
    context
  end

  step ~r/^"(?<title>[^"]+)" ended its turn leaving (?<work>.+) running$/,
       %{args: [title, work]} = context do
    case work do
      "a background command the agent waits on" ->
        context |> claude_turn(title, "background commands: tests") |> mark(["tests"], true)

      "a monitor the agent waits on" ->
        context |> claude_turn(title, "start a monitor") |> mark(["monitor"], true)

      "a subagent" ->
        # It starts a background command too (`"Build"`), which no one waits on.
        claude_turn(context, title, "in the background")

      "a background command the agent did not mark" ->
        claude_turn(context, title, "background commands: tests")

      "a monitor the agent did not mark" ->
        claude_turn(context, title, "start a monitor")
    end
  end

  step ~r/^"(?<title>[^"]+)" stays in the Working section$/, %{args: [title]} = context do
    row = await_settled(context, title, &(&1["pendingBackgroundTasks"] != []))
    # Only the work the agent waits on holds it.
    assert Enum.all?(row["pendingBackgroundTasks"], &holds?/1)
    context
  end

  step ~r/^"(?<title>[^"]+)" moves to the inbox$/, %{args: [title]} = context do
    await_settled(
      context,
      title,
      &(&1["pendingBackgroundTasks"] == [] and &1["runningBackgroundTasks"] != [])
    )

    context
  end

  # --- Claude marks and clears ----------------------------------------------------------

  step "Claude left the background commands {string} and {string} running in {string}",
       %{args: [first, second, title]} = context do
    context = claude_turn(context, title, "background commands: #{first}, #{second}")
    await_settled(context, title, &(length(&1["runningBackgroundTasks"]) == 2))
    context
  end

  step "Claude marks {string} as work it waits on", %{args: [name]} = context do
    mark(context, [name], true)
  end

  step "Claude clears the mark on {string}", %{args: [name]} = context do
    mark(context, [name], false)
  end

  step "{string} stays Working until {string} ends", %{args: [title, name]} = context do
    task = context.tasks[name]
    await_settled(context, title, &match?([%{"taskId" => ^task}], &1["pendingBackgroundTasks"]))

    context = finish(context, title, name)
    await_settled(context, title, &(&1["pendingBackgroundTasks"] == []))
    context
  end

  step "{string} holds {string}", %{args: [name, title]} = context do
    task = context.tasks[name]

    await_settled(
      context,
      title,
      &Enum.any?(&1["pendingBackgroundTasks"], fn t -> t["taskId"] == task end)
    )

    context
  end

  step "{string} no longer holds {string}", %{args: [name, title]} = context do
    task = context.tasks[name]

    await_settled(
      context,
      title,
      &(&1["pendingBackgroundTasks"] == [] and
          Enum.any?(&1["runningBackgroundTasks"], fn t -> t["taskId"] == task end))
    )

    context
  end

  step "marking a command that is not running reports it as unmatched and changes nothing",
       context do
    title = World.current(context)
    before = World.row(context, title)
    ended = context[:ended] || flunk("no command has ended")

    assert {:ok, %{"matched" => [], "unmatched" => [id]}} =
             World.mcp_tool(
               context,
               title,
               "hal_c2_background_wait",
               %{"taskIds" => [claude_task(context, ended)]},
               "claudeAgent"
             )

    assert id == claude_task(context, ended)
    # The runtime answers after it has committed anything it marked.
    assert World.row(context, title)["pendingBackgroundTasks"] ==
             before["pendingBackgroundTasks"]

    context
  end

  # --- providers that cannot mark ----------------------------------------------------

  step "a Codex thread asks to mark a background command as work it waits on", context do
    title = "Fix login"

    context =
      context
      |> World.fake_providers()
      |> World.launch_on(title, "codex", "hello", in_shop(context))

    World.await_runs(context, title, ["completed"])
    [run | _] = World.entities(context, title, "run")
    thread_id = World.thread_id(context, title)

    # What Codex left running when its turn ended: a command and a subagent.
    context =
      for {id, fields} <- [
            {"cmd-1", %{"type" => "command_execution", "input" => "npm run dev"}},
            {"sub-1", %{"type" => "subagent", "prompt" => "Survey the repo"}}
          ],
          reduce: context do
        context ->
          World.put_entity(context, title, "turn-item", id, %{
            "s" =>
              Map.merge(fields, %{
                "id" => id,
                "threadId" => thread_id,
                "runId" => run["id"],
                "status" => "running"
              })
          })
      end

    reply =
      World.mcp_tool(
        context,
        title,
        "hal_c2_background_wait",
        %{"taskIds" => ["cmd-1"]},
        "codex"
      )

    Map.put(context, :reply, reply)
  end

  step "the mark is refused as unsupported", context do
    assert {:error, "invalid_request", message} = context.reply
    assert message =~ "cannot mark"
    context
  end

  step "only the thread's subagents keep it Working", context do
    title = World.current(context)

    await_settled(
      context,
      title,
      &(match?([%{"taskId" => "sub-1", "taskType" => "subagent"}], &1["pendingBackgroundTasks"]) and
          length(&1["runningBackgroundTasks"]) == 2)
    )

    context
  end

  # --- helpers ----------------------------------------------------------------------

  # A Claude turn of `title` on `text`, over once it has left its work running.
  defp claude_turn(context, title, text) do
    context =
      context
      |> World.fake_providers()
      |> World.launch_on(title, "claudeAgent", text, in_shop(context))

    World.await_runs(context, title, ["completed"])
    await_settled(context, title, &(&1["runningBackgroundTasks"] != []))
    Map.put(context, :tasks, tool_ids(text))
  end

  # The tool use ids (the row's task ids) the fake CLI gives each named work in its
  # first turn.
  defp tool_ids("start a monitor"), do: %{"monitor" => "mon-1"}

  defp tool_ids("background commands: " <> names) do
    for name <- String.split(names, ", "),
        into: %{},
        do: {name, String.replace(name, " ", "-") <> "-1"}
  end

  defp tool_ids(_text), do: %{}

  # Claude's own task id, the one its tool result names and its agent passes.
  defp claude_task(context, name), do: "task-" <> context.tasks[name]

  defp mark(context, names, waiting) do
    ids = Enum.map(names, &claude_task(context, &1))

    assert {:ok, %{"matched" => ^ids, "unmatched" => []}} =
             World.mcp_tool(
               context,
               World.current(context),
               "hal_c2_background_wait",
               %{"taskIds" => ids, "waiting" => waiting},
               "claudeAgent"
             )

    context
  end

  # Claude reports the work ended, as its CLI does after the turn.
  defp finish(context, title, name) do
    [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, World.thread_id(context, title))

    message = %{
      "type" => "system",
      "subtype" => "task_notification",
      "task_id" => claude_task(context, name),
      "tool_use_id" => context.tasks[name],
      "status" => "completed",
      "summary" => "#{name} ended"
    }

    send(pid, {:claude, :sys.get_state(pid).session, {:message, message}})
    Map.put(context, :ended, name)
  end

  # The Background's first project.
  defp in_shop(context), do: %{"projectId" => World.project(context, "shop").id}

  defp await_settled(context, title, fun),
    do: World.await_row(World.thread_id(context, title), &(&1["activeRunId"] == nil and fun.(&1)))

  defp holds?(task),
    do: task["awaited"] == true or task["taskType"] not in ~w(command_execution dynamic_tool)
end
