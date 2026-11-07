defmodule HalC2.Projection.BackgroundWorkTest do
  # Pending background work cases.
  use ExUnit.Case, async: true

  alias HalC2.Projection.BackgroundWork

  defp run(id, ordinal, status), do: %{"id" => id, "ordinal" => ordinal, "status" => status}

  defp command(id, status, title, extra \\ %{}) do
    Map.merge(
      %{"id" => id, "type" => "command_execution", "status" => status, "title" => title},
      extra
    )
  end

  defp native(id), do: %{"nativeItemRef" => %{"nativeId" => id}}

  test "nothing is pending while the latest run is not settled" do
    assert BackgroundWork.derive(
             latest_run: run("run-1", 1, "running"),
             provider_threads: [
               %{"id" => "pt-1", "pendingBackgroundTasks" => [%{"taskId" => "bg-1"}]}
             ],
             turn_items: [command("item-1", "running", "npm test")]
           ) == []
  end

  test "an idle subagent does not keep a settled parent waiting" do
    idle = %{"id" => "idle-child", "type" => "subagent", "status" => "idle", "title" => "Review"}

    assert BackgroundWork.derive(
             latest_run: run("run-1", 1, "completed"),
             provider_threads: [],
             turn_items: [idle]
           ) == []
  end

  test "a waiting run (succeeded, checkpoint pending) surfaces active items" do
    assert BackgroundWork.derive(
             latest_run: run("run-1", 1, "waiting"),
             provider_threads: [%{"id" => "pt-1"}],
             turn_items: [command("item-1", "running", "npm test", native("cmd-1"))]
           ) == [
             %{
               "taskId" => "cmd-1",
               "description" => "npm test",
               "taskType" => "command_execution"
             }
           ]
  end

  test "the provider thread roster counts once the run settles" do
    task = %{"taskId" => "bg-1", "description" => "Run Codex review", "taskType" => "local_bash"}

    assert BackgroundWork.derive(
             latest_run: run("run-1", 1, "completed"),
             provider_threads: [
               %{"id" => "pt-1", "pendingBackgroundTasks" => [task]},
               %{"id" => "pt-2", "pendingBackgroundTasks" => [%{"taskId" => "other"}]}
             ],
             turn_items: [],
             active_provider_thread_id: "pt-1"
           ) == [task]
  end

  test "completed items are not pending" do
    assert BackgroundWork.derive(
             latest_run: run("run-1", 1, "completed"),
             provider_threads: [],
             turn_items: [
               command("item-1", "running", "npm test", native("cmd-1")),
               command("item-2", "completed", "done", native("cmd-2"))
             ]
           )
           |> Enum.map(& &1["taskId"]) == ["cmd-1"]
  end

  test "descriptions are trimmed and fall back to the tool name" do
    tool = %{
      "id" => "item-tool",
      "type" => "dynamic_tool",
      "status" => "running",
      "title" => :null,
      "toolName" => "  browser.search  "
    }

    assert BackgroundWork.derive(
             latest_run: run("run-1", 1, "completed"),
             provider_threads: [
               %{
                 "id" => "pt-1",
                 "pendingBackgroundTasks" => [
                   %{"taskId" => "native-task", "description" => "  native work  "}
                 ]
               }
             ],
             turn_items: [command("item-command", "running", "  npm test  "), tool]
           ) == [
             %{"taskId" => "native-task", "description" => "native work"},
             %{
               "taskId" => "item-command",
               "description" => "npm test",
               "taskType" => "command_execution"
             },
             %{
               "taskId" => "item-tool",
               "description" => "browser.search",
               "taskType" => "dynamic_tool"
             }
           ]
  end

  test "a many-line prompt or description is its first line that says anything" do
    subagent = %{
      "id" => "item-subagent",
      "type" => "subagent",
      "status" => "running",
      "prompt" => "\n  Read the issue first.\n\nWhat to build:\n- the style\n"
    }

    assert BackgroundWork.derive(
             latest_run: run("run-1", 1, "completed"),
             provider_threads: [
               %{
                 "id" => "pt-1",
                 "pendingBackgroundTasks" => [
                   %{"taskId" => "native-task", "description" => "  \r\nwatch CI\r\nthen merge"}
                 ]
               }
             ],
             turn_items: [subagent]
           ) == [
             %{"taskId" => "native-task", "description" => "watch CI"},
             %{
               "taskId" => "item-subagent",
               "description" => "Read the issue first.",
               "taskType" => "subagent"
             }
           ]
  end

  test "roster entries and turn items with the same native id are one task, roster first" do
    subagent =
      Map.merge(
        %{
          "id" => "item-sub",
          "type" => "subagent",
          "status" => "running",
          "title" => "Agent review"
        },
        native("task-9")
      )

    assert BackgroundWork.derive(
             latest_run: run("run-1", 1, "completed"),
             provider_threads: [
               %{
                 "id" => "pt-1",
                 "pendingBackgroundTasks" => [
                   %{"taskId" => "task-9", "description" => "Agent review"}
                 ]
               }
             ],
             turn_items: [subagent]
           ) == [%{"taskId" => "task-9", "description" => "Agent review"}]
  end

  test "persistent monitors never count as pending" do
    monitor = fn id, persistent ->
      %{
        "id" => id,
        "type" => "dynamic_tool",
        "status" => "running",
        "title" => id,
        "input" => %{"persistent" => persistent}
      }
    end

    assert BackgroundWork.derive(
             latest_run: run("run-1", 1, "completed"),
             provider_threads: [],
             turn_items: [monitor.("tail", true), monitor.("finite", false)]
           )
           |> Enum.map(& &1["taskId"]) == ["finite"]
  end

  test "items of rolled-back runs are abandoned; items without a run stay" do
    assert BackgroundWork.derive(
             latest_run: run("run-2", 2, "completed"),
             provider_threads: [],
             runs: [run("run-1", 1, "rolled_back"), run("run-2", 2, "completed")],
             turn_items: [
               command("old", "running", "old", %{"runId" => "run-1"}),
               command("new", "running", "new", %{"runId" => "run-2"}),
               command("orphan", "running", "orphan", %{"runId" => :null})
             ]
           )
           |> Enum.map(& &1["taskId"]) == ["new", "orphan"]
  end

  test "a rolled-back latest run hides even the roster" do
    assert BackgroundWork.derive(
             latest_run: run("run-1", 1, "rolled_back"),
             provider_threads: [
               %{"id" => "pt-1", "pendingBackgroundTasks" => [%{"taskId" => "bg-1"}]}
             ],
             turn_items: []
           ) == []
  end

  test "an older run still active is foreground work, not background" do
    assert BackgroundWork.derive(
             latest_run: run("run-2", 2, "cancelled"),
             provider_threads: [
               %{"id" => "pt-1", "pendingBackgroundTasks" => [%{"taskId" => "provider-task"}]}
             ],
             runs: [run("run-1", 1, "running"), run("run-2", 2, "cancelled")],
             turn_items: [command("item-active", "running", "vp check", %{"runId" => "run-1"})]
           ) == []
  end

  describe "holding/1" do
    defp settled(items, roster \\ []) do
      BackgroundWork.derive(
        latest_run: run("run-1", 1, "completed"),
        provider_threads: [%{"id" => "pt-1", "pendingBackgroundTasks" => roster}],
        turn_items: items
      )
    end

    test "commands and monitors hold only when the agent waits on them" do
      monitor = %{"type" => "dynamic_tool", "toolName" => "Monitor", "status" => "running"}

      tasks =
        settled([
          command("dev", "running", "npm run dev"),
          command("tests", "running", "mix test", %{"awaited" => true}),
          Map.put(monitor, "id", "watch"),
          Map.merge(monitor, %{"id" => "deploy", "awaited" => true}),
          command("cleared", "running", "make", %{"awaited" => false})
        ])

      assert Enum.map(tasks, & &1["taskId"]) == ~w(dev tests watch deploy cleared)

      assert [%{"taskId" => "tests", "awaited" => true}, %{"taskId" => "deploy"}] =
               BackgroundWork.holding(tasks)
    end

    test "subagents and other roster tasks always hold" do
      tasks =
        settled(
          [%{"id" => "child", "type" => "subagent", "status" => "running", "prompt" => "Review"}],
          [
            %{"taskId" => "agent", "taskType" => "local_agent"},
            %{"taskId" => "shell", "taskType" => "local_bash"},
            %{"taskId" => "build", "taskType" => "local_bash", "awaited" => true}
          ]
        )

      assert BackgroundWork.holding(tasks) |> Enum.map(& &1["taskId"]) == ~w(agent build child)
    end

    test "the mark is carried only when set" do
      assert [task] = settled([command("dev", "running", "npm run dev", %{"awaited" => false})])
      refute Map.has_key?(task, "awaited")
    end
  end
end
