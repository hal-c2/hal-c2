defmodule HalC2.OrchestrationTest do
  use ExUnit.Case, async: false

  alias HalC2.{Orchestration, StreamState}

  @moduletag :tmp_dir
  @fake_codex Path.expand("../support/fake_codex.py", __DIR__)
  @fake_claude Path.expand("../support/fake_claude.py", __DIR__)
  @fake_acp Path.expand("../support/fake_acp.py", __DIR__)

  setup %{tmp_dir: dir} do
    # Threads without a project run in the MC's cwd; make that a repo of its own so
    # checkpoints land there and not in this checkout.
    work = Path.join(dir, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)
    previous_cwd = File.cwd!()
    File.cd!(work)
    on_exit(fn -> File.cd!(previous_cwd) end)
    Application.put_env(:hal_c2, :home, dir)
    Application.put_env(:hal_c2, :codex_command, ["python3", "-u", @fake_codex])
    Application.put_env(:hal_c2, :claude_command, ["python3", "-u", @fake_claude])
    fake_acp = ["python3", "-u", @fake_acp]
    Application.put_env(:hal_c2, :acp_commands, %{"opencode" => fake_acp, "grok" => fake_acp})

    on_exit(fn ->
      Application.delete_env(:hal_c2, :codex_command)
      Application.delete_env(:hal_c2, :claude_command)
      Application.delete_env(:hal_c2, :acp_commands)
    end)

    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    start_supervised!({Registry, keys: :unique, name: HalC2.Codex.Registry})

    start_supervised!({Registry, keys: :unique, name: HalC2.Claude.Registry},
      id: :claude_registry
    )

    start_supervised!({Registry, keys: :unique, name: HalC2.Acp.Registry}, id: :acp_registry)
    start_supervised!({DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one})
    %{work: work}
  end

  defp launch(text, instance \\ "codex", mode \\ "full-access", interaction \\ "default") do
    thread_id = "thread-#{System.unique_integer([:positive])}"
    :ok = HalC2.Streams.subscribe(thread_id, self(), nil)

    {:ok, %{"threadId" => ^thread_id}} =
      Orchestration.launch_thread(%{
        "commandId" => "cmd-#{System.unique_integer([:positive])}",
        "threadId" => thread_id,
        "projectId" => "project-1",
        "title" => "Try codex",
        "modelSelection" => %{"instanceId" => instance, "model" => "gpt-5.4"},
        "runtimeMode" => mode,
        "interactionMode" => interaction,
        "workspaceStrategy" => %{"type" => "root"},
        "initialMessage" => %{"messageId" => "msg-user-1", "text" => text, "attachments" => []}
      })

    thread_id
  end

  # Waits on the thread's own event stream until its run reaches a terminal status.
  defp await_run(thread_id, status) do
    receive do
      {:hal_c2_stream, ^thread_id, _} ->
        state = HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))

        case StreamState.list(state, "run") do
          [%{"status" => ^status} | _] -> state
          _ -> await_run(thread_id, status)
        end
    after
      5_000 -> flunk("run never reached #{status}")
    end
  end

  test "a message runs a Codex turn and streams it into the thread" do
    thread_id = launch("list the files")
    state = await_run(thread_id, "completed")

    [run] = StreamState.list(state, "run")
    assert %{"ordinal" => 1, "startedAt" => started, "completedAt" => completed} = run
    assert started && completed

    items = StreamState.list(state, "turn-item")

    assert Enum.map(items, & &1["type"]) == [
             "user_message",
             "command_execution",
             "assistant_message",
             "checkpoint"
           ]

    assert Enum.map(items, & &1["ordinal"]) == [0, 1, 2, 3]

    [_user, command, answer, _checkpoint] = items

    assert %{"input" => "ls", "output" => "a.txt\n", "exitCode" => 0, "status" => "completed"} =
             command

    assert %{"text" => "Hello from codex", "streaming" => false, "status" => "completed"} = answer

    assert [%{"role" => "user"}, %{"role" => "assistant", "text" => "Hello from codex"}] =
             StreamState.list(state, "message")

    assert [%{"status" => "idle", "nativeThreadRef" => %{"nativeId" => "native-thread-1"}}] =
             StreamState.list(state, "provider-thread")

    assert [%{"status" => "completed"}] = StreamState.list(state, "provider-turn")
    # Every run, node, and item points at entities that exist.
    nodes = StreamState.get(state, "node")
    assert Map.has_key?(nodes, run["rootNodeId"])
    assert Enum.all?(items, &Map.has_key?(nodes, &1["nodeId"]))
  end

  test "the model options picked in the composer reach Codex's turn", %{tmp_dir: dir} do
    log = Path.join(dir, "codex.log")

    Application.put_env(:hal_c2, :codex_command, [
      "env",
      "FAKE_CODEX_TRACE=#{log}",
      "python3",
      "-u",
      @fake_codex
    ])

    thread_id = "thread-options"
    :ok = HalC2.Streams.subscribe(thread_id, self(), nil)

    {:ok, _} =
      Orchestration.launch_thread(%{
        "commandId" => "cmd-1",
        "threadId" => thread_id,
        "projectId" => "project-1",
        "title" => "Options",
        "modelSelection" => %{
          "instanceId" => "codex",
          "model" => "gpt-5.4",
          "options" => [
            %{"id" => "reasoningEffort", "value" => "high"},
            %{"id" => "serviceTier", "value" => "fast"}
          ]
        },
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "workspaceStrategy" => %{"type" => "root"},
        "initialMessage" => %{"messageId" => "msg-user-1", "text" => "hello", "attachments" => []}
      })

    await_run(thread_id, "completed")

    [params] =
      for line <- String.split(File.read!(log), "\n", trim: true),
          %{"in" => %{"method" => "turn/start", "params" => params}} <- [JSON.decode!(line)],
          do: params

    assert %{"effort" => "high", "serviceTier" => "fast"} = params
  end

  test "streamed text is stored as appends, not re-sent whole" do
    thread_id = launch("list the files")
    _ = await_run(thread_id, "completed")

    patches =
      HalC2.Store.reduce_stream(HalC2.Store.path(), thread_id, 0, [], fn e, acc ->
        if e.entity == "turn-item:codex:msg-1", do: [e.patch | acc], else: acc
      end)

    assert Enum.any?(patches, &Map.has_key?(&1, "a"))
    refute Enum.any?(patches, &(get_in(&1, ["s", "text"]) == "Hello from codex"))
  end

  test "a command id used for one parent thread is refused for another, even after a rejection" do
    command = %{"type" => "delegated_task.unknown", "commandId" => "c-parent"}

    first =
      Orchestration.handle(
        "orchestration.dispatchCommand",
        Map.put(command, "parentThreadId", "p1")
      )

    assert {:error, "delegated_task.unknown is not supported" <> _} = first

    assert Orchestration.handle(
             "orchestration.dispatchCommand",
             Map.put(command, "parentThreadId", "p1")
           ) ==
             first

    assert {:error, message} =
             Orchestration.handle(
               "orchestration.dispatchCommand",
               Map.put(command, "parentThreadId", "p2")
             )

    assert message =~ "already handled for thread p1"
  end

  test "interrupt ends the running turn" do
    thread_id = launch("wait for me")
    _ = await_run(thread_id, "running")

    assert {:ok, _} =
             Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

    state = await_run(thread_id, "interrupted")
    assert [%{"status" => "interrupted"}] = StreamState.list(state, "run-attempt")
  end

  test "a message's image upload reaches codex inline, with where it is saved" do
    png = <<137, 80, 78, 71, 13, 10, 26, 10>>

    {:ok, %{"attachmentId" => id, "relativeUrl" => "/api/attachments/upload/" <> token}} =
      HalC2.Attachments.create_upload_url(%{
        "name" => "a.png",
        "mimeType" => "image/png",
        "sizeBytes" => byte_size(png)
      })

    :ok = HalC2.Attachments.store(token, png)

    thread_id = "thread-#{System.unique_integer([:positive])}"
    :ok = HalC2.Streams.subscribe(thread_id, self(), nil)

    {:ok, _} =
      Orchestration.launch_thread(%{
        "commandId" => "c",
        "threadId" => thread_id,
        "projectId" => "project-1",
        "title" => "Look",
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "workspaceStrategy" => %{"type" => "root"},
        "initialMessage" => %{
          "messageId" => "m1",
          "text" => "look at this",
          "attachments" => [
            %{
              "type" => "image",
              "id" => id,
              "name" => "a.png",
              "mimeType" => "image/png",
              "sizeBytes" => byte_size(png)
            }
          ]
        }
      })

    state = await_run(thread_id, "completed")
    items = StreamState.list(state, "turn-item")
    assert Enum.any?(items, &(&1["text"] == "input text,image saved True"))

    assert %{"attachments" => [%{"id" => "thread-" <> _}]} =
             StreamState.get(state, "message")["m1"]
  end

  test "inline context reaches the agent as markers and an envelope, and stays on the message" do
    thread_id = "thread-#{System.unique_integer([:positive])}"
    :ok = HalC2.Streams.subscribe(thread_id, self(), nil)
    skill = %{"version" => 1, "contextId" => "ctx_s", "kind" => "skill", "name" => "pinchtab"}

    {:ok, _} =
      Orchestration.launch_thread(%{
        "commandId" => "c",
        "threadId" => thread_id,
        "projectId" => "project-1",
        "title" => "Context",
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "workspaceStrategy" => %{"type" => "root"},
        "initialMessage" => %{
          "messageId" => "m1",
          "text" => "repeat with [$pinchtab](hal-c2-context://v1/skill/ctx_s)",
          "context" => %{"version" => 1, "records" => [skill]},
          "attachments" => []
        }
      })

    state = await_run(thread_id, "completed")

    assert Enum.any?(
             StreamState.list(state, "turn-item"),
             &(&1["text"] ==
                 "repeat with [Skill: $pinchtab; ref=ctx_s]\n\n<hal_c2_context version=\"1\">\n" <>
                   ~s(<context kind="skill" id="ctx_s">\nname: pinchtab\n</context>\n</hal_c2_context>))
           )

    assert %{"context" => %{"records" => [^skill]}} = StreamState.get(state, "message")["m1"]
  end

  test "a launch reuses only an existing empty thread of its project" do
    reuse = fn thread_id, project_id ->
      Orchestration.launch_thread(%{
        "commandId" => "c-#{System.unique_integer([:positive])}",
        "threadId" => thread_id,
        "projectId" => project_id,
        "title" => "Draft",
        "reuseExistingThread" => true,
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "workspaceStrategy" => %{"type" => "root"},
        "initialMessage" => %{"messageId" => "m1", "text" => "hi", "attachments" => []}
      })
    end

    assert {:error, "Thread missing does not exist."} = reuse.("missing", "project-1")

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => "draft",
        "projectId" => "project-1",
        "title" => "Draft"
      })

    assert {:error, "Only an empty active thread" <> _} = reuse.("draft", "project-2")

    thread_id = launch("list the files")
    _ = await_run(thread_id, "completed")
    assert {:error, "Only an empty active thread" <> _} = reuse.(thread_id, "project-1")
  end

  test "feedback goes to Codex for the thread's provider thread" do
    thread_id = launch("list the files")
    _ = await_run(thread_id, "completed")
    :ok = HalC2.Shell.subscribe(self())
    await_shell_row(thread_id, &(&1["providerInstanceId"] == "codex"))

    assert {:ok, %{"feedbackId" => "feedback-for-" <> _}} =
             Orchestration.handle("provider.uploadFeedback", %{
               "threadId" => thread_id,
               "reason" => "wrong answer"
             })

    :ok = Orchestration.release_session(thread_id)

    assert {:error,
            %{"_tag" => "ProviderUploadFeedbackError", "cause" => "The provider session" <> _}} =
             Orchestration.handle("provider.uploadFeedback", %{"threadId" => thread_id})
  end

  describe "thread settings and plan mode" do
    test "thread commands set the thread's own fields" do
      thread_id = launch("list the files")
      _ = await_run(thread_id, "completed")

      for {type, fields} <- [
            {"thread.metadata.update", %{"title" => "Renamed"}},
            {"thread.interaction-mode.set", %{"interactionMode" => "plan"}},
            {"thread.runtime-mode.set", %{"runtimeMode" => "approval-required"}},
            {"thread.pin", %{"orderKey" => "a0"}},
            {"thread.visit", %{"visitedAt" => "2026-09-23T12:00:00.000Z"}},
            {"thread.visit", %{"visitedAt" => "2026-09-23T11:00:00.000Z"}},
            {"thread.archive", %{}}
          ] do
        {:ok, _} =
          Orchestration.dispatch(Map.merge(%{"type" => type, "threadId" => thread_id}, fields))
      end

      assert %{
               "title" => "Renamed",
               "interactionMode" => "plan",
               "runtimeMode" => "approval-required",
               "pinOrderKey" => "a0",
               "pinnedAt" => pinned,
               "lastVisitedAt" => "2026-09-23T12:00:00.000Z",
               "archivedAt" => archived
             } = StreamState.get(current(thread_id), "thread")[thread_id]

      assert is_binary(pinned) and is_binary(archived)
    end

    test "regenerating a title marks it in flight until the attempt ends" do
      thread_id = launch("list the files")
      _ = await_run(thread_id, "completed")

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "thread.metadata.update",
          "commandId" => "cmd-regen",
          "threadId" => thread_id,
          "regenerateTitle" => true
        })

      assert %{"titleRegeneration" => %{"requestId" => "cmd-regen"}} =
               StreamState.get(current(thread_id), "thread")[thread_id]

      # No text generator is installed in tests, so the attempt fails and clears it.
      await_thread(thread_id, &(&1["titleRegeneration"] == nil))
    end

    test "codex in plan mode proposes a plan and keeps a todo list; implementing completes it" do
      thread_id = launch("make a plan", "codex", "full-access", "plan")
      state = await_run(thread_id, "completed")

      assert [
               %{"kind" => "proposed_plan", "status" => "active", "markdown" => "# Plan\n- do it"} =
                 plan
             ] =
               Enum.filter(StreamState.list(state, "plan"), &(&1["kind"] == "proposed_plan"))

      items = StreamState.list(state, "turn-item")

      assert %{"markdown" => "# Plan\n- do it", "streaming" => false, "status" => "completed"} =
               Enum.find(items, &(&1["type"] == "proposed_plan"))

      assert %{
               "steps" => [%{"status" => "completed"}, %{"status" => "running"}],
               "explanation" => "Two steps"
             } =
               Enum.find(items, &(&1["type"] == "todo_list"))

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "message.dispatch",
          "threadId" => thread_id,
          "messageId" => "m-implement",
          "text" => "go ahead",
          "attachments" => [],
          "sourcePlanRef" => %{"threadId" => thread_id, "planId" => plan["id"]},
          "dispatchMode" => %{"type" => "start_immediately"}
        })

      state = await_statuses(thread_id, ["completed", "completed"])
      assert %{"status" => "completed"} = StreamState.get(state, "plan")[plan["id"]]
    end

    test "codex outside plan mode is told so" do
      thread_id = launch("make a plan", "codex")
      state = await_run(thread_id, "completed")
      assert Enum.any?(StreamState.list(state, "turn-item"), &(&1["text"] == "mode default"))
    end

    test "claude's ExitPlanMode becomes the proposed plan, and TodoWrite a todo list" do
      thread_id = launch("make a plan", "claudeAgent", "full-access", "plan")
      state = await_run(thread_id, "completed")

      assert [%{"status" => "active", "markdown" => "# Plan\n- do it"}] =
               Enum.filter(StreamState.list(state, "plan"), &(&1["kind"] == "proposed_plan"))

      refute Enum.any?(StreamState.list(state, "turn-item"), &(&1["toolName"] == "ExitPlanMode"))

      thread_id = launch("keep a todo list", "claudeAgent")
      state = await_run(thread_id, "completed")

      assert [%{"kind" => "todo_list", "status" => "active", "steps" => [first, second]}] =
               StreamState.list(state, "plan")

      assert {first["text"], first["status"], second["status"]} ==
               {"Read the code", "completed", "running"}
    end
  end

  test "pull requests link to a thread by host, repository and number" do
    thread_id = launch("hello")
    await_statuses(thread_id, ["completed"])
    key = %{"host" => "github.com", "repository" => "hal-c2/code", "number" => 7}

    link = fn url ->
      Orchestration.dispatch(
        Map.merge(key, %{
          "type" => "thread.pull-request.link",
          "threadId" => thread_id,
          "url" => url,
          "source" => "manual"
        })
      )
    end

    {:ok, _} = link.("https://github.com/hal-c2/code/pull/7")
    {:ok, _} = link.("https://github.com/hal-c2/code/pull/7?again")
    thread = StreamState.get(current(thread_id), "thread")[thread_id]

    assert [%{"number" => 7, "url" => "https://github.com/hal-c2/code/pull/7"}] =
             thread["pullRequests"]

    {:ok, _} =
      Orchestration.dispatch(
        Map.merge(key, %{"type" => "thread.pull-request.unlink", "threadId" => thread_id})
      )

    assert [] = StreamState.get(current(thread_id), "thread")[thread_id]["pullRequests"]
  end

  test "threads are found by what was said in them, the user's words first" do
    thread_id = launch("hello there")
    await_statuses(thread_id, ["completed"])
    :ok = HalC2.Shell.subscribe(self())

    # Search lists active threads from the sidebar rows.
    unless HalC2.Shell.row(node(), thread_id) do
      assert_receive {:hal_c2_shell, _}, 2_000
    end

    assert {:ok, %{"matches" => [%{"threadId" => ^thread_id, "source" => "assistant"} = match]}} =
             HalC2.Search.threads(%{"query" => "FROM CODEX"})

    assert match["snippet"] == "Hello from codex"

    assert {:ok, %{"matches" => [%{"source" => "user", "snippet" => "hello there"}]}} =
             HalC2.Search.threads(%{"query" => "hello"})

    assert {:ok, %{"matches" => []}} = HalC2.Search.threads(%{"query" => "100%"})
  end

  test "a scheduled task sends its prompt into its thread when run" do
    start_supervised!(HalC2.ScheduledTasks)
    thread_id = launch("hello")
    await_statuses(thread_id, ["completed"])

    {:ok, %{"task" => task}} =
      HalC2.ScheduledTasks.upsert(%{
        "title" => "Nightly",
        "prompt" => "where are we",
        "enabled" => false,
        "schedule" => %{"type" => "fixed_time", "timeOfDay" => "03:00"},
        "projectId" => "project-1",
        "threadId" => thread_id,
        "workspaceStrategy" => %{"type" => "root"},
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default"
      })

    assert %{"nextRunAt" => nil, "lastRunStatus" => "never"} = task

    assert {:ok, %{"task" => %{"lastRunStatus" => "succeeded", "runCount" => 1}}} =
             HalC2.ScheduledTasks.run_now(%{"id" => task["id"]})

    state = await_statuses(thread_id, ["completed", "completed"])
    assert Enum.any?(StreamState.list(state, "message"), &(&1["text"] == "where are we"))

    {:ok, %{"task" => %{"nextRunAt" => next}}} =
      HalC2.ScheduledTasks.set_enabled(%{"id" => task["id"], "enabled" => true})

    assert is_binary(next)
    {:ok, _} = HalC2.ScheduledTasks.delete(%{"id" => task["id"]})
    assert {:ok, %{"tasks" => []}} = HalC2.ScheduledTasks.list()
  end

  test "an agent's MCP credential reads its own project's threads, and nothing else" do
    start_supervised!(HalC2.Mcp)
    thread_id = launch("hello")
    await_statuses(thread_id, ["completed"])
    :ok = HalC2.Shell.subscribe(self())

    unless HalC2.Shell.row(node(), thread_id) do
      assert_receive {:hal_c2_shell, _}, 2_000
    end

    %{authorization: auth} = HalC2.Mcp.server(thread_id, "codex")
    rpc = &HalC2.Mcp.handle(auth, JSON.encode!(Map.merge(%{"jsonrpc" => "2.0", "id" => 1}, &1)))

    assert {200, %{"result" => %{"serverInfo" => %{"name" => "hal-c2"}, "instructions" => text}}} =
             rpc.(%{"method" => "initialize", "params" => %{"protocolVersion" => "2025-06-18"}})

    assert text =~ "hal-c2"

    assert {202, nil} =
             HalC2.Mcp.handle(auth, ~s({"jsonrpc":"2.0","method":"notifications/initialized"}))

    {200, %{"result" => %{"tools" => tools}}} = rpc.(%{"method" => "tools/list"})

    assert Enum.any?(
             tools,
             &(&1["name"] == "hal_c2_thread_list" and &1["inputSchema"]["type"] == "object")
           )

    {200, %{"result" => %{"structuredContent" => listed}}} =
      rpc.(%{
        "method" => "tools/call",
        "params" => %{"name" => "hal_c2_thread_list", "arguments" => %{}}
      })

    assert %{"currentThreadId" => ^thread_id, "threads" => [%{"threadId" => ^thread_id}]} = listed

    {200, %{"result" => %{"structuredContent" => read}}} =
      rpc.(%{
        "method" => "tools/call",
        "params" => %{"name" => "hal_c2_thread_read", "arguments" => %{"threadId" => thread_id}}
      })

    assert Enum.map(read["items"], & &1["type"]) == ["user_message", "assistant_message"]

    # An idle caller cannot change things, and other projects are out of reach.
    {200, %{"result" => %{"isError" => true, "content" => [%{"text" => denied}]}}} =
      rpc.(%{
        "method" => "tools/call",
        "params" => %{
          "name" => "hal_c2_thread_send",
          "arguments" => %{"threadId" => thread_id, "message" => "hi"}
        }
      })

    assert denied =~ "parent_not_active"
    assert {401, _} = HalC2.Mcp.handle("Bearer nope", "{}")
  end

  test "a running thread delegates a task, and hears the result when the child finishes" do
    start_supervised!(HalC2.Mcp)
    parent_id = launch("wait here")
    await_statuses(parent_id, ["running"])
    :ok = HalC2.Shell.subscribe(self())

    unless HalC2.Shell.row(node(), parent_id) do
      assert_receive {:hal_c2_shell, _}, 2_000
    end

    %{authorization: auth} = HalC2.Mcp.server(parent_id, "codex")

    call = fn name, arguments ->
      {200, %{"result" => result}} =
        HalC2.Mcp.handle(
          auth,
          JSON.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "tools/call",
            "params" => %{"name" => name, "arguments" => arguments}
          })
        )

      result
    end

    %{"structuredContent" => %{"taskId" => task_id, "childThreadId" => child_id}} =
      call.("delegate_task", %{"task" => "hello", "title" => "Say hello"})

    :ok = HalC2.Streams.subscribe(child_id, self(), nil)
    await_statuses(child_id, ["completed"])

    child = StreamState.get(current(child_id), "thread")[child_id]

    assert %{"relationshipToParent" => "subagent", "parentThreadId" => ^parent_id} =
             child["lineage"]

    # The parent is still running, so the result waits in its queue.
    state = await_statuses(parent_id, ["running", "queued"])

    assert [%{"status" => "completed", "result" => "Hello from codex"}] =
             StreamState.list(state, "subagent")

    assert Enum.any?(StreamState.list(state, "message"), &(&1["text"] =~ "delegated_task_result"))

    assert %{
             "structuredContent" => %{
               "workState" => "result_available",
               "summary" => "Hello from codex"
             }
           } =
             call.("task_status", %{"taskId" => task_id})
  end

  describe "queued messages" do
    test "a message sent during a run waits in the queue and starts when the run ends" do
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")

      {:ok, _} = send_message(thread_id, "m2", "then list the files")
      {:ok, _} = send_message(thread_id, "m3", "and once more")

      state = await_statuses(thread_id, ["running", "queued", "queued"])
      [_, second, third] = runs(state)
      assert {second["queuePosition"], third["queuePosition"]} == {1, 2}
      assert %{"text" => "then list the files"} = StreamState.get(state, "message")["m2"]

      # Queued messages join the transcript only when their run starts.
      refute Enum.any?(StreamState.list(state, "turn-item"), &(&1["messageId"] == "m2"))

      {:ok, _} = Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

      state = await_statuses(thread_id, ["interrupted", "completed", "completed"])

      assert %{"inputIntent" => "queued_turn", "text" => "then list the files"} =
               Enum.find(StreamState.list(state, "turn-item"), &(&1["messageId"] == "m2"))

      assert Enum.all?(runs(state), &(&1["queuePosition"] == nil))
    end

    test "archiving a thread cancels what it had queued" do
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      {:ok, _} = send_message(thread_id, "m2", "then list the files")
      _ = await_statuses(thread_id, ["running", "queued"])

      {:ok, _} = Orchestration.dispatch(%{"type" => "thread.archive", "threadId" => thread_id})

      assert [_, %{"status" => "cancelled", "queuePosition" => nil}] = runs(current(thread_id))
    end

    test "queued runs can be reordered, edited, and cancelled" do
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      {:ok, _} = send_message(thread_id, "m2", "second")
      {:ok, _} = send_message(thread_id, "m3", "third")
      [_, second, third] = runs(await_statuses(thread_id, ["running", "queued", "queued"]))

      {:ok, _} =
        queue_command("queued-run.reorder", thread_id, third["id"], %{
          "beforeRunId" => second["id"]
        })

      {:ok, _} =
        queue_command("queued-run.edit", thread_id, third["id"], %{"text" => "third, edited"})

      {:ok, _} = queue_command("queued-run.cancel", thread_id, second["id"])

      state = current(thread_id)
      by_id = Map.new(runs(state), &{&1["id"], &1})
      assert %{"status" => "cancelled", "queuePosition" => nil} = by_id[second["id"]]
      assert %{"status" => "queued", "queuePosition" => 1} = by_id[third["id"]]
      assert %{"text" => "third, edited"} = StreamState.get(state, "message")["m3"]
    end

    test "an agent that cannot be steered is interrupted, and the steered message goes next" do
      thread_id = launch("wait for it", "grok")
      _ = await_run(thread_id, "running")
      {:ok, _} = send_message(thread_id, "m2", "second")
      {:ok, _} = send_message(thread_id, "m3", "third")
      [active, _, third] = runs(await_statuses(thread_id, ["running", "queued", "queued"]))

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "queued-message.promote-to-steer",
          "threadId" => thread_id,
          "queuedRunId" => third["id"],
          "targetRunId" => active["id"]
        })

      state = await_statuses(thread_id, ["interrupted", "completed", "completed"])

      # The promoted message ran before the one queued ahead of it.
      order =
        state
        |> StreamState.list("turn-item")
        |> Enum.filter(&(&1["messageId"] in ["m2", "m3"]))
        |> Enum.sort_by(& &1["ordinal"])
        |> Enum.map(& &1["messageId"])

      assert order == ["m3", "m2"]
    end

    for instance <- ["codex", "claudeAgent"] do
      test "#{instance}: a message sent during a run steers it" do
        thread_id = launch("wait for it", unquote(instance))
        _ = await_run(thread_id, "running")

        {:ok, _} =
          send_message(thread_id, "m2", "look here instead", %{
            "dispatchMode" => %{"type" => "start_immediately"},
            "deliveryIntent" => "auto"
          })

        state = await_statuses(thread_id, ["completed"])
        items = StreamState.list(state, "turn-item")

        assert %{"inputIntent" => "steer", "runId" => run_id} =
                 Enum.find(items, &(&1["messageId"] == "m2"))

        assert [%{"id" => ^run_id}] = runs(state)
        assert Enum.any?(items, &(&1["text"] == "steered: look here instead"))
      end
    end

    test "a queued message promoted to steer joins the running turn" do
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      {:ok, _} = send_message(thread_id, "m2", "second")
      [active, queued] = runs(await_statuses(thread_id, ["running", "queued"]))

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "queued-message.promote-to-steer",
          "threadId" => thread_id,
          "queuedRunId" => queued["id"],
          "targetRunId" => active["id"]
        })

      state = await_statuses(thread_id, ["completed", "cancelled"])

      assert %{"inputIntent" => "promoted_queued_to_steer", "runId" => run_id} =
               Enum.find(StreamState.list(state, "turn-item"), &(&1["messageId"] == "m2"))

      assert run_id == active["id"]
    end

    test "restart interrupts the running turn and starts the message next" do
      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")

      {:ok, _} =
        send_message(thread_id, "m2", "do this instead", %{
          "dispatchMode" => %{"type" => "start_immediately"},
          "deliveryIntent" => "restart"
        })

      state = await_statuses(thread_id, ["interrupted", "completed"])
      assert Enum.any?(StreamState.list(state, "turn-item"), &(&1["messageId"] == "m2"))
    end
  end

  describe "Codex background terminals" do
    setup %{tmp_dir: dir} do
      log = Path.join(dir, "codex-requests.log")

      Application.put_env(:hal_c2, :codex_command, [
        "env",
        "FAKE_CODEX_LOG=#{log}",
        "python3",
        "-u",
        @fake_codex
      ])

      :ok = HalC2.Shell.subscribe(self())
      %{log: log}
    end

    test "a command left running keeps its session until Codex reports it ended" do
      Application.put_env(:hal_c2, :idle_session_check_ms, nil)
      Application.put_env(:hal_c2, :session_idle_ms, 0)

      on_exit(fn ->
        Application.delete_env(:hal_c2, :idle_session_check_ms)
        Application.delete_env(:hal_c2, :session_idle_ms)
      end)

      start_supervised!(HalC2.Orchestration.IdleSessions)
      thread_id = launch("start the dev server in the background")
      _ = await_run(thread_id, "completed")
      await_shell_row(thread_id, &(length(&1["pendingBackgroundTasks"] || []) == 1))
      assert [%{"status" => "running", "input" => "npm run dev"}] = commands(thread_id)

      assert HalC2.Orchestration.IdleSessions.check() == []
      assert [_] = Registry.lookup(HalC2.Codex.Registry, thread_id)

      codex_says(thread_id, "item/completed", %{
        "threadId" => "native-thread-1",
        "turnId" => "native-turn-1",
        "item" => %{
          "type" => "commandExecution",
          "id" => "cmd-bg",
          "command" => "npm run dev",
          "status" => "completed",
          "aggregatedOutput" => "listening on 5173\nbye\n",
          "exitCode" => 0
        }
      })

      await_shell_row(thread_id, &(&1["pendingBackgroundTasks"] == []))
      # The exit wakes the thread with a turn telling Codex; the session idles after it.
      state = await_runs(thread_id, 2)

      assert [_, %{"userMessageId" => wake}] = runs(state)

      assert StreamState.get(state, "message")[wake]["text"] ==
               "The background command `npm run dev` exited with code 0."

      assert [%{"status" => "completed", "output" => "listening on 5173\nbye\n", "exitCode" => 0}] =
               Enum.filter(commands(thread_id), &(&1["input"] == "npm run dev"))

      await_shell_row(thread_id, &(&1["activeRunId"] == nil))
      assert HalC2.Orchestration.IdleSessions.check() == [thread_id]
    end

    test "stopping the thread between turns terminates the command", %{log: log} do
      thread_id = launch("start the dev server in the background")
      _ = await_run(thread_id, "completed")
      await_shell_row(thread_id, &(length(&1["pendingBackgroundTasks"] || []) == 1))

      assert {:ok, _} =
               Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

      await_shell_row(thread_id, &(&1["pendingBackgroundTasks"] == []))
      assert [%{"status" => "interrupted"}] = commands(thread_id)
      assert [%{"processId" => "4275"}] = terminated(log)

      assert {:error, _} =
               Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})
    end

    test "an interrupted turn terminates the command it started", %{log: log} do
      thread_id = launch("start the dev server in the background and wait")
      _ = await_run(thread_id, "running")
      await_item(thread_id, "command_execution")

      assert {:ok, _} =
               Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

      _ = await_run(thread_id, "interrupted")
      assert [%{"status" => "interrupted"}] = commands(thread_id)
      assert [%{"processId" => "4275"}] = terminated(log)
    end

    test "the command fails when Codex exits" do
      thread_id = launch("start the dev server in the background")
      _ = await_run(thread_id, "completed")
      await_shell_row(thread_id, &(length(&1["pendingBackgroundTasks"] || []) == 1))

      [{pid, _}] = Registry.lookup(HalC2.Codex.Registry, thread_id)
      Process.exit(:sys.get_state(pid).conn, :kill)

      await_shell_row(thread_id, &(&1["pendingBackgroundTasks"] == []))
      assert [%{"status" => "failed"}] = commands(thread_id)
    end

    test "releasing the session ends the command" do
      thread_id = launch("start the dev server in the background")
      _ = await_run(thread_id, "completed")
      await_shell_row(thread_id, &(length(&1["pendingBackgroundTasks"] || []) == 1))

      assert :ok = Orchestration.release_session(thread_id)
      await_shell_row(thread_id, &(&1["pendingBackgroundTasks"] == []))
      assert [%{"status" => "interrupted"}] = commands(thread_id)
    end

    defp commands(thread_id) do
      current(thread_id)
      |> StreamState.list("turn-item")
      |> Enum.filter(&(&1["type"] == "command_execution"))
    end

    defp terminated(log) do
      for line <- String.split(File.read!(log), "\n", trim: true),
          %{"method" => "thread/backgroundTerminals/terminate", "params" => params} <-
            [JSON.decode!(line)],
          do: params
    end

    defp codex_says(thread_id, method, params) do
      [{pid, _}] = Registry.lookup(HalC2.Codex.Registry, thread_id)
      send(pid, {:json_rpc, :sys.get_state(pid).conn, {:notification, method, params}})
    end
  end

  describe "Grok background work" do
    setup do
      :ok = HalC2.Shell.subscribe(self())
      :ok
    end

    @child "0f8e2a4c-5b6d-4e7f-8a9b-1c2d3e4f5a6b"

    test "a background shell and subagent keep the agent until Grok reports them ended" do
      Application.put_env(:hal_c2, :idle_session_check_ms, nil)
      Application.put_env(:hal_c2, :session_idle_ms, 0)

      on_exit(fn ->
        Application.delete_env(:hal_c2, :idle_session_check_ms)
        Application.delete_env(:hal_c2, :session_idle_ms)
      end)

      start_supervised!(HalC2.Orchestration.IdleSessions)
      thread_id = launch("work in the background", "grok")
      _ = await_run(thread_id, "completed")
      await_shell_row(thread_id, &(length(&1["pendingBackgroundTasks"] || []) == 2))

      assert [
               %{"type" => "command_execution", "status" => "running", "input" => "npm run dev"},
               %{"type" => "subagent", "status" => "running"}
             ] = background_items(thread_id)

      assert HalC2.Orchestration.IdleSessions.check() == []
      assert [_] = Registry.lookup(HalC2.Acp.Registry, thread_id)

      grok_says(thread_id, "x.ai/task_completed", %{
        "sessionId" => session(thread_id),
        "update" => %{
          "sessionUpdate" => "task_completed",
          "task_snapshot" => %{"task_id" => "task-sh"}
        }
      })

      grok_says(thread_id, "session/update", %{
        "sessionId" => session(thread_id),
        "update" => %{
          "sessionUpdate" => "user_message_chunk",
          "content" => %{
            "type" => "text",
            "text" =>
              ~s[Background subagent "#{@child}" (type: "general") completed successfully.]
          }
        }
      })

      await_shell_row(thread_id, &(&1["pendingBackgroundTasks"] == []))
      assert ["completed", "completed"] = Enum.map(background_items(thread_id), & &1["status"])
      assert HalC2.Orchestration.IdleSessions.check() == [thread_id]
    end

    test "the subagent's answer after the turn still reaches its child thread" do
      thread_id = launch("work in the background", "grok")
      _ = await_run(thread_id, "completed")
      await_shell_row(thread_id, &(length(&1["pendingBackgroundTasks"] || []) == 2))

      grok_says(thread_id, "session/update", %{
        "sessionId" => @child,
        "update" => %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "the repo has a lib"}
        }
      })

      grok_says(thread_id, "x.ai/task_completed", %{
        "sessionId" => session(thread_id),
        "update" => %{
          "sessionUpdate" => "task_completed",
          "task_snapshot" => %{"task_id" => @child}
        }
      })

      await_shell_row(thread_id, &(length(&1["pendingBackgroundTasks"]) == 1))

      assert [%{"status" => "completed", "result" => "the repo has a lib"}] =
               StreamState.list(current(thread_id), "subagent")
    end

    test "stopping the thread between turns ends the work and the agent" do
      thread_id = launch("work in the background", "grok")
      _ = await_run(thread_id, "completed")
      await_shell_row(thread_id, &(length(&1["pendingBackgroundTasks"] || []) == 2))
      conn = :sys.get_state(runtime_pid(thread_id)).conn
      ref = Process.monitor(conn)

      assert {:ok, _} =
               Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

      await_shell_row(thread_id, &(&1["pendingBackgroundTasks"] == []))

      assert ["interrupted", "interrupted"] =
               Enum.map(background_items(thread_id), & &1["status"])

      assert_receive {:DOWN, ^ref, :process, _, _}

      assert {:error, _} =
               Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})
    end

    test "an interrupted turn ends the work it started, and the agent" do
      thread_id = launch("work in the background and wait", "grok")
      _ = await_run(thread_id, "running")
      await_item(thread_id, "subagent")
      conn = :sys.get_state(runtime_pid(thread_id)).conn
      ref = Process.monitor(conn)

      assert {:ok, _} =
               Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

      _ = await_run(thread_id, "interrupted")
      assert_receive {:DOWN, ^ref, :process, _, _}

      assert ["interrupted", "interrupted"] =
               Enum.map(background_items(thread_id), & &1["status"])

      assert [%{"status" => "interrupted"}] = StreamState.list(current(thread_id), "subagent")
    end

    test "releasing the agent ends the work it ran" do
      thread_id = launch("work in the background", "grok")
      _ = await_run(thread_id, "completed")
      await_shell_row(thread_id, &(length(&1["pendingBackgroundTasks"] || []) == 2))

      assert :ok = Orchestration.release_session(thread_id)
      await_shell_row(thread_id, &(&1["pendingBackgroundTasks"] == []))

      assert ["interrupted", "interrupted"] =
               Enum.map(background_items(thread_id), & &1["status"])
    end

    defp background_items(thread_id) do
      current(thread_id)
      |> StreamState.list("turn-item")
      |> Enum.filter(
        &(&1["nativeItemRef"]["nativeId"] in ["sh-1", "spawn-1"] or
            (&1["type"] == "subagent" and &1["status"] != nil))
      )
      |> Enum.uniq_by(& &1["id"])
      |> Enum.sort_by(& &1["type"])
    end

    defp runtime_pid(thread_id) do
      [{pid, _}] = Registry.lookup(HalC2.Acp.Registry, thread_id)
      pid
    end

    defp session(thread_id), do: :sys.get_state(runtime_pid(thread_id)).session_id

    defp grok_says(thread_id, method, params) do
      pid = runtime_pid(thread_id)
      send(pid, {:json_rpc, :sys.get_state(pid).conn, {:notification, method, params}})
    end
  end

  describe "Claude" do
    test "a message runs a Claude turn: thinking, a Bash call, and a streamed answer" do
      thread_id = launch("list the files", "claudeAgent")
      state = await_run(thread_id, "completed")

      items = StreamState.list(state, "turn-item")

      assert Enum.map(items, & &1["type"]) == [
               "user_message",
               "reasoning",
               "command_execution",
               "assistant_message",
               "checkpoint"
             ]

      [_, thinking, command, answer, _checkpoint] = items
      assert %{"text" => "Let me look.", "status" => "completed"} = thinking
      assert %{"input" => "ls", "output" => "a.txt\n", "status" => "completed"} = command

      assert %{"text" => "Hello from claude", "streaming" => false, "status" => "completed"} =
               answer

      assert [
               %{
                 "driver" => "claudeAgent",
                 "nativeThreadRef" => %{"nativeId" => "fake-session-1"}
               }
             ] =
               StreamState.list(state, "provider-thread")

      assert [%{"providerInstanceId" => "claudeAgent"}] = StreamState.list(state, "run")
    end

    test "interrupt ends a Claude run" do
      thread_id = launch("wait for me", "claudeAgent")
      _ = await_run(thread_id, "running")

      assert {:ok, _} =
               Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

      assert [%{"status" => "interrupted"}] =
               StreamState.list(await_run(thread_id, "interrupted"), "run-attempt")
    end

    test "Claude's background subagent and command keep its process until their tasks end" do
      Application.put_env(:hal_c2, :idle_session_check_ms, nil)
      Application.put_env(:hal_c2, :session_idle_ms, 0)

      on_exit(fn ->
        Application.delete_env(:hal_c2, :idle_session_check_ms)
        Application.delete_env(:hal_c2, :session_idle_ms)
      end)

      start_supervised!(HalC2.Orchestration.IdleSessions)
      :ok = HalC2.Shell.subscribe(self())
      thread_id = launch("work in the background", "claudeAgent")
      _ = await_run(thread_id, "completed")
      await_shell_row(thread_id, &(length(&1["pendingBackgroundTasks"] || []) == 2))

      assert %{
               "turn-item:subagent:node:subagent:claudeAgent:agent-1" => %{
                 "type" => "subagent",
                 "status" => "running",
                 "title" => "Survey the repo",
                 "prompt" => "List what is in the repo"
               }
             } = StreamState.get(current(thread_id), "turn-item")

      assert [%{"status" => "running", "output" => "Command running in background" <> _}] =
               current(thread_id)
               |> StreamState.list("turn-item")
               |> Enum.filter(&(&1["type"] == "command_execution"))

      # The idle timeout passed, but the process runs the work: it stays.
      assert HalC2.Orchestration.IdleSessions.check() == []
      assert [_] = Registry.lookup(HalC2.Claude.Registry, thread_id)

      claude_says(thread_id, %{
        "type" => "system",
        "subtype" => "task_progress",
        "task_id" => "task-agent-1",
        "tool_use_id" => "agent-1",
        "description" => "Survey the repo",
        "summary" => "Reading the README"
      })

      claude_says(thread_id, notification("task-agent-1", "agent-1", "completed", "3 files"))
      claude_says(thread_id, notification("task-bash-1", "bash-1", "stopped", "Stopped"))
      await_shell_row(thread_id, &(&1["pendingBackgroundTasks"] == []))

      state = current(thread_id)

      assert %{"status" => "completed", "result" => "3 files", "progress" => "Reading the README"} =
               StreamState.get(state, "turn-item")[
                 "turn-item:subagent:node:subagent:claudeAgent:agent-1"
               ]

      assert %{"status" => "completed", "origin" => "provider_native"} =
               StreamState.get(state, "subagent")["node:subagent:claudeAgent:agent-1"]

      assert [%{"status" => "cancelled", "output" => "Stopped"}] =
               state
               |> StreamState.list("turn-item")
               |> Enum.filter(&(&1["type"] == "command_execution"))

      assert HalC2.Orchestration.IdleSessions.check() == [thread_id]
    end

    test "stopping a Claude thread between turns ends its background work" do
      :ok = HalC2.Shell.subscribe(self())
      thread_id = launch("work in the background", "claudeAgent")
      _ = await_run(thread_id, "completed")
      await_shell_row(thread_id, &(length(&1["pendingBackgroundTasks"] || []) == 2))

      assert {:ok, _} =
               Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

      await_shell_row(thread_id, &(&1["pendingBackgroundTasks"] == []))

      assert ["interrupted", "interrupted"] =
               current(thread_id)
               |> StreamState.list("turn-item")
               |> Enum.filter(&(&1["type"] in ["subagent", "command_execution"]))
               |> Enum.map(& &1["status"])

      # With nothing left to stop, a second stop is refused as before.
      assert {:error, _} =
               Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})
    end

    test "releasing a Claude process ends the background work it ran" do
      :ok = HalC2.Shell.subscribe(self())
      thread_id = launch("work in the background", "claudeAgent")
      _ = await_run(thread_id, "completed")
      await_shell_row(thread_id, &(length(&1["pendingBackgroundTasks"] || []) == 2))

      assert :ok = Orchestration.release_session(thread_id)
      await_shell_row(thread_id, &(&1["pendingBackgroundTasks"] == []))

      assert %{"status" => "interrupted"} =
               StreamState.get(current(thread_id), "subagent")[
                 "node:subagent:claudeAgent:agent-1"
               ]
    end

    test "work Claude starts in a wake is recorded on the wake's run until its task ends" do
      :ok = HalC2.Shell.subscribe(self())
      thread_id = launch("hello", "claudeAgent")
      _ = await_run(thread_id, "completed")

      # The turn a task notification wakes Claude for launches a subagent and a command.
      claude_says(thread_id, %{
        "type" => "assistant",
        "message" => %{
          "id" => "m-wake",
          "content" => [
            %{"type" => "text", "text" => "Starting more"},
            %{
              "type" => "tool_use",
              "id" => "agent-wake",
              "name" => "Agent",
              "input" => %{"description" => "Check the tests", "run_in_background" => true}
            },
            %{
              "type" => "tool_use",
              "id" => "bash-wake",
              "name" => "Bash",
              "input" => %{"command" => "mix test", "run_in_background" => true}
            }
          ]
        }
      })

      claude_says(thread_id, task_started("task-agent-wake", "agent-wake", "local_agent"))
      claude_says(thread_id, task_started("task-bash-wake", "bash-wake", "local_bash"))

      claude_says(thread_id, %{
        "type" => "user",
        "message" => %{
          "content" => [
            %{"type" => "tool_result", "tool_use_id" => "agent-wake", "content" => "launched"},
            %{"type" => "tool_result", "tool_use_id" => "bash-wake", "content" => "running"}
          ]
        }
      })

      claude_says(thread_id, %{"type" => "result", "subtype" => "success", "is_error" => false})
      [_, %{"id" => run_id}] = runs(await_statuses(thread_id, ["completed", "completed"]))
      await_shell_row(thread_id, &(length(&1["pendingBackgroundTasks"] || []) == 2))

      assert %{"runId" => ^run_id, "status" => "running", "title" => "Check the tests"} =
               StreamState.get(current(thread_id), "subagent")[
                 "node:subagent:claudeAgent:agent-wake"
               ]

      assert [%{"runId" => ^run_id, "status" => "running", "output" => "running"}] =
               current(thread_id)
               |> StreamState.list("turn-item")
               |> Enum.filter(&(&1["input"] == "mix test"))

      claude_says(thread_id, notification("task-agent-wake", "agent-wake", "completed", "Fine"))
      claude_says(thread_id, notification("task-bash-wake", "bash-wake", "completed", "ok"))
      await_shell_row(thread_id, &(&1["pendingBackgroundTasks"] == []))
    end

    test "a subagent resumed through SendMessage keeps its process until its task ends" do
      :ok = HalC2.Shell.subscribe(self())
      thread_id = launch("wait for me", "claudeAgent")
      _ = await_run(thread_id, "running")

      claude_says(thread_id, %{
        "type" => "assistant",
        "message" => %{
          "id" => "m-send",
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "send-1",
              "name" => "SendMessage",
              "input" => %{"to" => "task-old", "message" => "Carry on"}
            }
          ]
        }
      })

      claude_says(thread_id, task_started("task-old", "send-1", "local_agent"))

      claude_says(thread_id, %{
        "type" => "user",
        "message" => %{
          "content" => [
            %{"type" => "tool_result", "tool_use_id" => "send-1", "content" => "sent"}
          ]
        }
      })

      claude_says(thread_id, %{"type" => "result", "subtype" => "success", "is_error" => false})
      _ = await_run(thread_id, "completed")
      await_shell_row(thread_id, &(length(&1["pendingBackgroundTasks"] || []) == 1))

      # The SendMessage call itself is done; the subagent it resumed runs on.
      assert [%{"status" => "completed"}] =
               current(thread_id)
               |> StreamState.list("turn-item")
               |> Enum.filter(&(&1["toolName"] == "SendMessage"))

      claude_says(thread_id, notification("task-old", "send-1", "completed", "Done"))
      await_shell_row(thread_id, &(&1["pendingBackgroundTasks"] == []))
    end

    test "after an upgrade, the progress of a subagent it never recorded records it" do
      :ok = HalC2.Shell.subscribe(self())
      thread_id = launch("hello", "claudeAgent")
      [%{"id" => run_id}] = StreamState.list(await_run(thread_id, "completed"), "run")

      # A runtime from before this version: no latest turn ids.
      [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, thread_id)
      :sys.replace_state(pid, &Map.drop(&1, [:last_ids]))
      :ok = :sys.suspend(pid)
      :ok = :sys.change_code(pid, HalC2.Claude.ThreadRuntime, 6, nil)
      :ok = :sys.resume(pid)

      claude_says(thread_id, %{
        "type" => "system",
        "subtype" => "task_progress",
        "task_id" => "task-unseen",
        "tool_use_id" => "agent-unseen",
        "description" => "Review the diff",
        "summary" => "Reading lib"
      })

      await_shell_row(thread_id, &(length(&1["pendingBackgroundTasks"] || []) == 1))

      assert %{"runId" => ^run_id, "status" => "running", "progress" => "Reading lib"} =
               StreamState.get(current(thread_id), "subagent")[
                 "node:subagent:claudeAgent:agent-unseen"
               ]

      claude_says(thread_id, notification("task-unseen", "agent-unseen", "completed", "LGTM"))
      await_shell_row(thread_id, &(&1["pendingBackgroundTasks"] == []))

      # Its progress after it ended does not bring it back.
      claude_says(thread_id, %{
        "type" => "system",
        "subtype" => "task_progress",
        "task_id" => "task-unseen",
        "tool_use_id" => "agent-unseen",
        "summary" => "late"
      })

      assert %{"status" => "completed"} =
               StreamState.get(current(thread_id), "subagent")[
                 "node:subagent:claudeAgent:agent-unseen"
               ]
    end

    test "ambient tasks between turns are not background work" do
      :ok = HalC2.Shell.subscribe(self())
      thread_id = launch("hello", "claudeAgent")
      _ = await_run(thread_id, "completed")

      claude_says(
        thread_id,
        Map.put(task_started("task-watch", "watch-1", "local_agent"), "ambient", true)
      )

      claude_says(thread_id, %{
        "type" => "system",
        "subtype" => "task_progress",
        "task_id" => "task-watch",
        "summary" => "watching"
      })

      # A round trip: both messages were handled.
      [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, thread_id)
      assert %{work: work} = :sys.get_state(pid)
      assert work == %{}
      assert StreamState.get(current(thread_id), "subagent") in [nil, %{}]
    end

    test "a turn Claude runs by itself is a run of its own until its result" do
      thread_id = launch("hello", "claudeAgent")
      _ = await_run(thread_id, "completed")

      # A background task ended; Claude answers its notification.
      claude_says(thread_id, notification("task-gone", "bash-gone", "completed", "Build passed"))
      claude_says(thread_id, wake_text("m-wake-1", "The build passed"))

      state = await_statuses(thread_id, ["completed", "running"])
      [_, %{"id" => wake_run, "userMessageId" => wake_message}] = runs(state)

      assert %{"role" => "user", "createdBy" => "agent", "creationSource" => "provider"} =
               StreamState.get(state, "message")[wake_message]

      claude_says(thread_id, wake_text("m-wake-2", "Nothing else to do"))
      claude_says(thread_id, %{"type" => "result", "subtype" => "success", "is_error" => false})
      state = await_statuses(thread_id, ["completed", "completed"])

      assert ["The build passed", "Nothing else to do"] =
               for(
                 %{"role" => "assistant", "runId" => ^wake_run} = m <-
                   StreamState.list(state, "message"),
                 do: m["text"]
               )

      # The next message is a turn of its own again.
      {:ok, _} = send_message(thread_id, "msg-user-2", "hello again")
      _ = await_statuses(thread_id, ["completed", "completed", "completed"])
    end

    test "a message sent while Claude runs a wake keeps its turn past the wake's result" do
      thread_id = launch("hello", "claudeAgent")
      _ = await_run(thread_id, "completed")
      [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, thread_id)
      session = :sys.get_state(pid).session

      # The user's run starts before the wake's: the runtime hears of the wake, then of
      # the user's turn, before asking for the wake's run.
      :ok = :sys.suspend(pid)
      send(pid, {:claude, session, {:message, wake_text("m-wake", "Checking the build")}})
      user = Task.async(fn -> send_message(thread_id, "msg-user-2", "and now?") end)
      await_mailbox(pid, 2)
      :ok = :sys.resume(pid)
      assert {:ok, _} = Task.await(user)

      # The fake answers the steer with the wake's aborted result, then the user's.
      state = await_statuses(thread_id, ["completed", "completed", "completed"])
      [_, %{"id" => user_run}, %{"userMessageId" => wake_message}] = runs(state)
      assert StreamState.get(state, "message")[wake_message]["creationSource"] == "provider"

      assert ["Checking the build", "steered: and now?"] =
               for(
                 %{"role" => "assistant", "runId" => ^user_run} = m <-
                   StreamState.list(state, "message"),
                 do: m["text"]
               )
    end

    test "a hot upgrade keeps the runtime going and takes the next wake" do
      thread_id = launch("hello", "claudeAgent")
      _ = await_run(thread_id, "completed")

      [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, thread_id)
      :sys.replace_state(pid, &Map.drop(&1, [:wake]))
      :ok = :sys.suspend(pid)
      :ok = :sys.change_code(pid, HalC2.Claude.ThreadRuntime, 7, nil)
      :ok = :sys.resume(pid)

      claude_says(thread_id, wake_text("m-wake", "Woke up"))
      claude_says(thread_id, %{"type" => "result", "subtype" => "success", "is_error" => false})
      _ = await_statuses(thread_id, ["completed", "completed"])
    end

    defp wake_text(id, text),
      do: %{
        "type" => "assistant",
        "message" => %{"id" => id, "content" => [%{"type" => "text", "text" => text}]}
      }

    defp await_mailbox(pid, count) do
      if Process.info(pid, :message_queue_len) |> elem(1) >= count do
        :ok
      else
        receive do
        after
          5 -> await_mailbox(pid, count)
        end
      end
    end

    defp task_started(task_id, tool_id, type),
      do: %{
        "type" => "system",
        "subtype" => "task_started",
        "task_id" => task_id,
        "tool_use_id" => tool_id,
        "description" => "A task",
        "task_type" => type,
        "is_backgrounded" => true
      }

    defp claude_says(thread_id, message) do
      [{pid, _}] = Registry.lookup(HalC2.Claude.Registry, thread_id)
      send(pid, {:claude, :sys.get_state(pid).session, {:message, message}})
    end

    defp notification(task_id, tool_id, status, summary),
      do: %{
        "type" => "system",
        "subtype" => "task_notification",
        "task_id" => task_id,
        "tool_use_id" => tool_id,
        "status" => status,
        "output_file" => "/tmp/#{task_id}.output",
        "summary" => summary
      }
  end

  describe "approvals" do
    for {instance, answer_text} <- [{"codex", nil}, {"claudeAgent", "allowed"}] do
      test "#{instance}: a prompt becomes a pending request, and accepting it lets the turn go on" do
        thread_id = launch("approve this", unquote(instance))
        request = await_request(thread_id)
        assert %{"status" => "pending", "kind" => "command"} = request

        assert [%{"type" => "approval_request", "status" => "waiting", "prompt" => "touch x"}] =
                 thread_id
                 |> current()
                 |> StreamState.list("turn-item")
                 |> Enum.filter(&(&1["type"] == "approval_request"))

        assert {:ok, _} =
                 Orchestration.dispatch(%{
                   "type" => "runtime-request.respond",
                   "threadId" => thread_id,
                   "requestId" => request["id"],
                   "decision" => "accept"
                 })

        state = await_run(thread_id, "completed")

        assert [%{"status" => "resolved", "decision" => "accept"}] =
                 StreamState.list(state, "runtime-request")

        if unquote(answer_text) do
          assert Enum.any?(
                   StreamState.list(state, "turn-item"),
                   &(&1["text"] == unquote(answer_text))
                 )
        else
          assert Enum.any?(
                   StreamState.list(state, "turn-item"),
                   &(&1["type"] == "command_execution" and &1["status"] == "completed")
                 )
        end
      end
    end

    # Each fake says what it was told; Claude keys answers by question text.
    for {instance, question_id, told} <- [
          {"codex", "color", ~s(answered {"color": {"answers": ["Red"]}})},
          {"claudeAgent", "Which color?", ~s(answered {"Which color?": "Red"})}
        ] do
      test "#{instance}: a question waits for the user's answer and passes it on" do
        thread_id = launch("ask me", unquote(instance))
        request = await_request(thread_id)
        assert %{"status" => "pending", "kind" => "user_input"} = request

        assert [%{"status" => "waiting", "questions" => [question]}] =
                 thread_id
                 |> current()
                 |> StreamState.list("turn-item")
                 |> Enum.filter(&(&1["type"] == "user_input_request"))

        assert %{"id" => unquote(question_id), "header" => "Color", "question" => "Which color?"} =
                 question

        assert %{"label" => "Red", "description" => "Warm"} = hd(question["options"])

        {:ok, _} =
          Orchestration.dispatch(%{
            "type" => "runtime-request.respond",
            "threadId" => thread_id,
            "requestId" => request["id"],
            "answers" => %{unquote(question_id) => "Red"}
          })

        state = await_run(thread_id, "completed")

        assert [%{"status" => "resolved", "answers" => %{unquote(question_id) => "Red"}}] =
                 StreamState.list(state, "runtime-request")

        assert Enum.any?(StreamState.list(state, "turn-item"), &(&1["text"] == unquote(told)))
      end
    end

    test "a file attached to an answer reaches the agent as where it is saved" do
      {:ok, %{"attachmentId" => id, "relativeUrl" => "/api/attachments/upload/" <> token}} =
        HalC2.Attachments.create_upload_url(%{
          "type" => "file",
          "name" => "notes.txt",
          "mimeType" => "text/plain",
          "sizeBytes" => 5
        })

      :ok = HalC2.Attachments.store(token, "notes")
      thread_id = launch("ask me")
      request = await_request(thread_id)
      file = %{"type" => "file", "id" => id, "name" => "notes.txt", "sizeBytes" => 5}

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "runtime-request.respond",
          "threadId" => thread_id,
          "requestId" => request["id"],
          "answers" => %{"color" => "Red"},
          "attachmentsByQuestionId" => %{"color" => [file]}
        })

      state = await_run(thread_id, "completed")

      assert [%{"questionAnswer" => %{"answers" => %{"color" => "Red"}} = answer}] =
               state
               |> StreamState.list("turn-item")
               |> Enum.filter(&(&1["type"] == "user_input_request"))

      # The file now belongs to the thread, and the agent was told where it is.
      assert [%{"id" => claimed, "name" => "notes.txt"}] =
               answer["attachmentsByQuestionId"]["color"]

      path = HalC2.Attachments.path(%{"id" => claimed})
      assert File.read!(path) == "notes"

      assert Enum.any?(
               StreamState.list(state, "turn-item"),
               &String.contains?(&1["text"] || "", ~s(Attached file \\"notes.txt\\": ))
             )
    end

    test "dismissing a question tells Claude no and cancels the request" do
      thread_id = launch("ask me", "claudeAgent")
      request = await_request(thread_id)

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "thread.user-input.dismiss",
          "threadId" => thread_id,
          "requestId" => request["id"]
        })

      state = await_run(thread_id, "completed")
      assert [%{"status" => "cancelled"}] = StreamState.list(state, "runtime-request")
      assert Enum.any?(StreamState.list(state, "turn-item"), &(&1["text"] == "denied"))
    end

    test "dismissing Claude's question about compacting a resumed conversation cancels it" do
      thread_id = launch("hello", "claudeAgent")
      _ = await_run(thread_id, "completed")
      # Without its process, the next message resumes the conversation.
      :ok = Orchestration.release_session(thread_id)
      {:ok, _} = send_message(thread_id, "m2", "long session")
      request = await_request(thread_id)
      assert %{"status" => "pending", "kind" => "user_input"} = request

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "thread.user-input.dismiss",
          "threadId" => thread_id,
          "requestId" => request["id"]
        })

      state = await_statuses(thread_id, ["completed", "completed"])
      assert [%{"status" => "cancelled"}] = StreamState.list(state, "runtime-request")
      assert Enum.any?(StreamState.list(state, "turn-item"), &(&1["text"] == "resume cancelled"))
    end

    test "declining a Claude prompt is passed on to Claude" do
      thread_id = launch("approve this", "claudeAgent")
      request = await_request(thread_id)

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "runtime-request.respond",
          "threadId" => thread_id,
          "requestId" => request["id"],
          "decision" => "decline"
        })

      state = await_run(thread_id, "completed")
      assert Enum.any?(StreamState.list(state, "turn-item"), &(&1["text"] == "denied"))
    end
  end

  describe "ACP agents (OpenCode)" do
    test "an agent that cannot start fails its run" do
      Application.put_env(:hal_c2, :acp_commands, %{"opencode" => ["/nonexistent/agent"]})

      # The runtime settles the turn itself, before creating its provider turn.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(self(), {:state, await_run(launch("hello", "opencode"), "failed")})
        end)

      assert_received {:state, state}
      refute log =~ "turn failed to start in"

      assert [%{"status" => "failed"}] = StreamState.list(state, "run-attempt")
      assert [%{"status" => "idle"}] = StreamState.list(state, "provider-thread")
      assert StreamState.list(state, "provider-turn") == []
    end

    test "a turn streams thinking, a command, and the answer; the session is recorded" do
      thread_id = launch("list the files", "opencode")
      state = await_run(thread_id, "completed")

      assert Enum.map(StreamState.list(state, "turn-item"), & &1["type"]) == [
               "user_message",
               "reasoning",
               "command_execution",
               "assistant_message",
               "checkpoint"
             ]

      items = StreamState.list(state, "turn-item")

      assert %{"input" => "ls", "output" => "a.txt\n", "status" => "completed"} =
               Enum.find(items, &(&1["type"] == "command_execution"))

      assert %{"text" => "Hello from acp", "streaming" => false} =
               Enum.find(items, &(&1["type"] == "assistant_message"))

      assert [%{"text" => "Hello from acp", "streaming" => false}] =
               Enum.filter(StreamState.list(state, "message"), &(&1["role"] == "assistant"))

      assert [%{"driver" => "opencode", "nativeThreadRef" => %{"nativeId" => "acp-1"}}] =
               StreamState.list(state, "provider-thread")

      # A follow-up is another prompt on the same session.
      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "message.dispatch",
          "threadId" => thread_id,
          "messageId" => "msg-user-2",
          "text" => "again"
        })

      state = await_runs(thread_id, 2)
      assert Enum.all?(StreamState.list(state, "run"), &(&1["status"] == "completed"))
    end

    test "a supervised thread asks before a command, and the answer goes to the agent" do
      thread_id = launch("approve the command", "opencode", "approval-required")
      request = await_request(thread_id)
      assert %{"kind" => "command"} = request

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "runtime-request.respond",
          "threadId" => thread_id,
          "requestId" => request["id"],
          "decision" => "decline"
        })

      state = await_run(thread_id, "completed")
      assert Enum.any?(StreamState.list(state, "turn-item"), &(&1["text"] == "not allowed"))
    end

    test "interrupt cancels the prompt" do
      thread_id = launch("wait for it", "opencode")
      await_item(thread_id, "command_execution")

      assert {:ok, _} =
               Orchestration.dispatch(%{"type" => "run.interrupt", "threadId" => thread_id})

      await_run(thread_id, "interrupted")
    end
  end

  describe "checkpoints" do
    test "a completed run records what it changed, and its diff is served", %{work: dir} do
      File.write!(Path.join(dir, "before.txt"), "already here\n")
      thread_id = launch("approve the command")
      request = await_request(thread_id)

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "runtime-request.respond",
          "threadId" => thread_id,
          "requestId" => request["id"],
          "decision" => "accept"
        })

      state = await_run(thread_id, "completed")
      scope_id = HalC2.Checkpoint.scope_id(thread_id)

      assert [%{"id" => ^scope_id, "kind" => "root_run", "cwd" => ^dir}] =
               StreamState.list(state, "checkpoint-scope")

      # The scope's baseline (ordinal 0) comes first, then the run's checkpoint.
      assert [
               %{"ordinalWithinScope" => 0, "appRunOrdinal" => nil},
               %{"status" => "ready", "appRunOrdinal" => 1, "files" => files} = checkpoint
             ] = StreamState.list(state, "checkpoint") |> Enum.sort_by(& &1["ordinalWithinScope"])

      # The baseline was taken before the turn, so only the turn's own file shows.
      assert [%{"path" => "x", "additions" => 1}] = files
      assert [%{"checkpointId" => checkpoint_id}] = StreamState.list(state, "run")
      assert checkpoint_id == checkpoint["id"]

      assert %{"type" => "checkpoint", "files" => ^files} =
               state |> StreamState.list("turn-item") |> List.last()

      assert {:ok, %{"diff" => diff, "toTurnCount" => 1}} =
               Orchestration.handle("orchestration.getTurnDiff", %{
                 "threadId" => thread_id,
                 "fromTurnCount" => 0,
                 "toTurnCount" => 1
               })

      assert diff =~ "+++ b/x"
      refute diff =~ "before.txt"

      assert {:ok, %{"diff" => ^diff}} =
               Orchestration.handle("orchestration.getFullThreadDiff", %{
                 "threadId" => thread_id,
                 "toTurnCount" => 1
               })
    end
  end

  describe "checkpoint rollback" do
    # A thread working in `work` as its own worktree, so files can be restored.
    defp launch_in(work, text, instance) do
      thread_id = "thread-#{System.unique_integer([:positive])}"
      :ok = HalC2.Streams.subscribe(thread_id, self(), nil)

      {:ok, _} =
        Orchestration.launch_thread(%{
          "commandId" => "cmd-#{System.unique_integer([:positive])}",
          "threadId" => thread_id,
          "projectId" => "project-1",
          "title" => "Rewind",
          "modelSelection" => %{"instanceId" => instance, "model" => "gpt-5.4"},
          "runtimeMode" => "full-access",
          "interactionMode" => "default",
          "workspaceStrategy" => %{
            "type" => "existing_worktree",
            "worktreePath" => work,
            "branch" => "main"
          },
          "initialMessage" => %{"messageId" => "msg-user-1", "text" => text, "attachments" => []}
        })

      thread_id
    end

    defp rollback(thread_id, ordinal, extra \\ %{}) do
      scope_id = HalC2.Checkpoint.scope_id(thread_id)

      Orchestration.dispatch(
        Map.merge(
          %{
            "type" => "checkpoint.rollback",
            "commandId" => "cmd-rollback",
            "threadId" => thread_id,
            "scopeId" => scope_id,
            "checkpointId" => HalC2.Checkpoint.checkpoint_id(scope_id, ordinal)
          },
          extra
        )
      )
    end

    test "Codex drops the later turns, the files go back, and the next run diffs from there",
         %{work: work} do
      thread_id = launch_in(work, "write a.txt", "codex")
      await_statuses(thread_id, ["completed"])
      {:ok, _} = send_message(thread_id, "msg-user-2", "write b.txt")
      await_statuses(thread_id, ["completed", "completed"])

      assert {:ok, _} = rollback(thread_id, 1)

      state = current(thread_id)
      assert ["completed", "rolled_back"] = Enum.map(runs(state), & &1["status"])
      assert File.exists?(Path.join(work, "a.txt"))
      refute File.exists?(Path.join(work, "b.txt"))

      assert [%{"lastRunOrdinal" => 1, "nativeThreadRef" => %{"nativeId" => native}}] =
               StreamState.list(state, "provider-thread")

      # Paginated history is cut before the first dropped turn.
      assert native == "native-thread-1-before-native-turn-2"

      assert %{"status" => "stale"} =
               StreamState.get(state, "checkpoint")[
                 HalC2.Checkpoint.checkpoint_id(HalC2.Checkpoint.scope_id(thread_id), 2)
               ]

      {:ok, _} = send_message(thread_id, "msg-user-3", "write c.txt")
      state = await_statuses(thread_id, ["completed", "rolled_back", "completed"])

      assert %{"files" => [%{"path" => "c.txt"}]} =
               StreamState.get(state, "checkpoint")[
                 HalC2.Checkpoint.checkpoint_id(HalC2.Checkpoint.scope_id(thread_id), 3)
               ]
    end

    test "a legacy Codex thread drops its later turns by count", %{work: work} do
      Application.put_env(:hal_c2, :codex_command, [
        "env",
        "FAKE_CODEX_LEGACY=1",
        "python3",
        "-u",
        @fake_codex
      ])

      thread_id = launch_in(work, "write a.txt", "codex")
      await_statuses(thread_id, ["completed"])
      {:ok, _} = send_message(thread_id, "msg-user-2", "write b.txt")
      await_statuses(thread_id, ["completed", "completed"])

      assert {:ok, _} = rollback(thread_id, 1)

      assert [%{"nativeThreadRef" => %{"nativeId" => "native-thread-1-dropped-1"}}] =
               StreamState.list(current(thread_id), "provider-thread")
    end

    test "files are only restored in a worktree of the thread's own" do
      thread_id = launch("write a.txt")
      await_statuses(thread_id, ["completed"])
      {:ok, _} = send_message(thread_id, "msg-user-2", "write b.txt")
      await_statuses(thread_id, ["completed", "completed"])

      assert {:error, "File restore requires an isolated worktree." <> _} = rollback(thread_id, 1)

      # Rewinding only the conversation leaves the files alone.
      assert {:ok, _} = rollback(thread_id, 1, %{"restoreFiles" => false})
      assert ["completed", "rolled_back"] = Enum.map(runs(current(thread_id)), & &1["status"])
      assert File.exists?("b.txt")
    end

    test "Claude resumes the next turn at the last message of the kept turn", %{work: work} do
      thread_id = launch_in(work, "hello", "claudeAgent")
      await_statuses(thread_id, ["completed"])
      {:ok, _} = send_message(thread_id, "msg-user-2", "hello again")
      await_statuses(thread_id, ["completed", "completed"])

      assert {:ok, _} = rollback(thread_id, 1, %{"restoreFiles" => false})

      {:ok, _} = send_message(thread_id, "msg-user-3", "where are we")
      state = await_statuses(thread_id, ["completed", "rolled_back", "completed"])

      assert Enum.any?(
               StreamState.list(state, "message"),
               &(&1["text"] == "resumed at uuid-1 fork False history False")
             )
    end

    test "rolling back ends the background work Claude was running", %{work: work} do
      :ok = HalC2.Shell.subscribe(self())
      thread_id = launch_in(work, "hello", "claudeAgent")
      await_statuses(thread_id, ["completed"])
      {:ok, _} = send_message(thread_id, "msg-user-2", "work in the background")
      await_statuses(thread_id, ["completed", "completed"])
      await_shell_row(thread_id, &(length(&1["pendingBackgroundTasks"] || []) == 2))

      assert {:ok, _} = rollback(thread_id, 1, %{"restoreFiles" => false})

      assert %{"status" => "interrupted"} =
               StreamState.get(current(thread_id), "subagent")[
                 "node:subagent:claudeAgent:agent-2"
               ]

      assert [%{"status" => "interrupted"}] =
               current(thread_id)
               |> StreamState.list("turn-item")
               |> Enum.filter(&(&1["input"] == "npm run build"))
    end
  end

  describe "forks and handoffs" do
    defp fork(source_id, run_id) do
      fork_id = "thread-#{System.unique_integer([:positive])}"
      :ok = HalC2.Streams.subscribe(fork_id, self(), nil)

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "thread.fork",
          "commandId" => "cmd-fork-#{fork_id}",
          "createdBy" => "user",
          "creationSource" => "web",
          "sourceThreadId" => source_id,
          "targetThreadId" => fork_id,
          "sourcePoint" => %{"type" => "run", "runId" => run_id}
        })

      fork_id
    end

    defp replies(state),
      do: for(m <- StreamState.list(state, "message"), m["role"] == "assistant", do: m["text"])

    defp claude, do: %{"modelSelection" => %{"instanceId" => "claudeAgent", "model" => "haiku"}}

    test "a fork starts with its source's history and continues the native Codex thread" do
      source_id = launch("hello")
      [run] = runs(await_statuses(source_id, ["completed"]))
      fork_id = fork(source_id, run["id"])

      state = current(fork_id)

      assert %{
               "title" => "Try codex fork",
               "lineage" => %{"parentThreadId" => ^source_id, "relationshipToParent" => "fork"},
               "forkedFrom" => %{"threadId" => ^source_id}
             } = StreamState.get(state, "thread")[fork_id]

      assert [%{"status" => "completed", "threadId" => ^fork_id}] = runs(state)
      assert "Hello from codex" in replies(state)

      assert [%{"type" => "fork", "status" => "pending"}] =
               StreamState.list(state, "context-transfer")

      {:ok, _} = send_message(fork_id, "msg-fork-1", "where are we")
      state = await_statuses(fork_id, ["completed", "completed"])

      assert "on forked-native-thread-1-at-native-turn-1 history False merged False" in replies(
               state
             )

      assert [%{"status" => "consumed", "resolution" => %{"strategy" => "native_fork"}}] =
               StreamState.list(state, "context-transfer")
    end

    test "a fork on another provider gets the history as a transcript" do
      source_id = launch("hello")
      [run] = runs(await_statuses(source_id, ["completed"]))
      fork_id = fork(source_id, run["id"])

      {:ok, _} = send_message(fork_id, "msg-fork-1", "where are we", claude())
      state = await_statuses(fork_id, ["completed", "completed"])

      assert "resumed at None fork False history True" in replies(state)

      assert [%{"resolution" => %{"strategy" => "portable_context"}}] =
               StreamState.list(state, "context-transfer")

      assert [%{"strategy" => "full_thread_summary", "summaryText" => summary}] =
               StreamState.list(state, "context-handoff")

      assert summary =~ "User: hello"
      assert summary =~ "Assistant: Hello from codex"
    end

    test "switching provider mid-thread hands the conversation over" do
      thread_id = launch("hello")
      await_statuses(thread_id, ["completed"])

      {:ok, _} = send_message(thread_id, "msg-user-2", "where are we", claude())
      state = await_statuses(thread_id, ["completed", "completed"])

      assert "resumed at None fork False history True" in replies(state)
    end

    test "provider.switch moves the next run to the new provider, with the conversation" do
      thread_id = launch("hello")
      await_statuses(thread_id, ["completed"])

      {:ok, _} =
        Orchestration.dispatch(
          Map.merge(claude(), %{"type" => "provider.switch", "threadId" => thread_id})
        )

      {:ok, _} = send_message(thread_id, "msg-user-2", "where are we")
      state = await_statuses(thread_id, ["completed", "completed"])

      assert "resumed at None fork False history True" in replies(state)
    end

    test "a turn a restart cut off goes on when the project asks for that" do
      start_supervised!(HalC2.Settings)
      {_, version} = HalC2.Settings.get()
      {:ok, _} = HalC2.Settings.put(%{"continueThreadsAfterServerUpdate" => true}, version)

      thread_id = launch("wait for it")
      _ = await_run(thread_id, "running")
      :ok = HalC2.Shell.subscribe(self())
      await_shell_row(thread_id, &(&1["activeRunId"] != nil))

      # The MC stops: its provider processes go with it.
      for {pid, _} <- Registry.lookup(HalC2.Codex.Registry, thread_id),
          do: :ok = DynamicSupervisor.terminate_child(HalC2.Codex.Supervisor, pid)

      assert thread_id in HalC2.Orchestration.Recovery.run()
      :ok = HalC2.Orchestration.Recovery.continue()

      state = await_statuses(thread_id, ["interrupted", "completed"])

      assert %{"text" => "Continue where you left off.", "createdBy" => "agent"} =
               StreamState.get(state, "message")[
                 "message:restart-continuation:" <> hd(runs(state))["id"]
               ]

      # It asks once.
      :ok = HalC2.Orchestration.Recovery.continue()
      assert length(runs(current(thread_id))) == 2
    end

    test "an idle session is stopped, and the next run starts it again" do
      Application.put_env(:hal_c2, :idle_session_check_ms, nil)
      Application.put_env(:hal_c2, :session_idle_ms, 0)

      on_exit(fn ->
        Application.delete_env(:hal_c2, :idle_session_check_ms)
        Application.delete_env(:hal_c2, :session_idle_ms)
      end)

      start_supervised!(HalC2.Orchestration.IdleSessions)
      thread_id = launch("list the files")
      _ = await_run(thread_id, "completed")
      :ok = HalC2.Shell.subscribe(self())
      await_shell_row(thread_id, &(&1["activeRunId"] == nil))

      assert HalC2.Orchestration.IdleSessions.check() == [thread_id]
      assert Registry.lookup(HalC2.Codex.Registry, thread_id) == []

      assert [%{"status" => "stopped"}] =
               StreamState.list(current(thread_id), "provider-session")

      {:ok, _} = send_message(thread_id, "m2", "list the files again")
      state = await_statuses(thread_id, ["completed", "completed"])
      assert [%{"status" => "ready"}] = StreamState.list(state, "provider-session")
    end

    test "a stopped session starts again on the next run and resumes its thread" do
      thread_id = launch("hello")
      await_statuses(thread_id, ["completed"])
      [session] = StreamState.list(current(thread_id), "provider-session")

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "provider-session.detach",
          "threadId" => thread_id,
          "providerSessionId" => session["id"]
        })

      assert [] = StreamState.list(current(thread_id), "provider-session")
      assert [] = Registry.lookup(HalC2.Codex.Registry, thread_id)

      {:ok, _} = send_message(thread_id, "msg-user-2", "where are we")
      state = await_statuses(thread_id, ["completed", "completed"])

      assert "on native-thread-1 history False merged False" in replies(state)
      assert [_] = StreamState.list(state, "provider-session")
    end

    test "merging a fork back brings its newer work to the parent's next run" do
      source_id = launch("hello")
      [run] = runs(await_statuses(source_id, ["completed"]))
      fork_id = fork(source_id, run["id"])
      {:ok, _} = send_message(fork_id, "msg-fork-1", "write fork.txt")
      [_, fork_run] = runs(await_statuses(fork_id, ["completed", "completed"]))

      {:ok, _} =
        Orchestration.dispatch(%{
          "type" => "thread.merge_back",
          "commandId" => "cmd-merge",
          "createdBy" => "user",
          "sourceThreadId" => fork_id,
          "targetThreadId" => source_id,
          "sourcePoint" => %{"type" => "run", "runId" => fork_run["id"]}
        })

      {:ok, _} = send_message(source_id, "msg-user-2", "where are we")
      state = await_statuses(source_id, ["completed", "completed"])

      assert "on native-thread-1 history False merged True" in replies(state)

      assert [%{"strategy" => "fork_delta_summary", "summaryText" => summary}] =
               StreamState.list(state, "context-handoff")

      # Only the fork's own work, not the history it started with.
      assert summary =~ "User: write fork.txt"
      refute summary =~ "User: hello"
    end
  end

  defp await_shell_row(thread_id, done?) do
    case HalC2.Shell.row(node(), thread_id) do
      {"thread", row} ->
        if done?.(row), do: :ok, else: await_shell_message(thread_id, done?)

      _ ->
        await_shell_message(thread_id, done?)
    end
  end

  defp await_shell_message(thread_id, done?) do
    receive do
      {:hal_c2_shell, {:rows, _, _}} -> await_shell_row(thread_id, done?)
    after
      5_000 -> flunk("the sidebar row never got there")
    end
  end

  defp await_thread(thread_id, done?) do
    if done?.(StreamState.get(current(thread_id), "thread")[thread_id]) do
      :ok
    else
      receive do
        {:hal_c2_stream, ^thread_id, _} -> await_thread(thread_id, done?)
      after
        5_000 -> flunk("the thread never got there")
      end
    end
  end

  defp await_runs(thread_id, count) do
    receive do
      {:hal_c2_stream, ^thread_id, _} ->
        state = current(thread_id)
        runs = StreamState.list(state, "run")

        if length(runs) == count and Enum.all?(runs, &(&1["status"] == "completed")),
          do: state,
          else: await_runs(thread_id, count)
    after
      5_000 -> flunk("runs never completed")
    end
  end

  defp await_item(thread_id, type) do
    receive do
      {:hal_c2_stream, ^thread_id, _} ->
        if Enum.any?(StreamState.list(current(thread_id), "turn-item"), &(&1["type"] == type)),
          do: :ok,
          else: await_item(thread_id, type)
    after
      5_000 -> flunk("no #{type} item")
    end
  end

  defp current(thread_id), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))

  defp runs(state), do: state |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])

  defp send_message(thread_id, message_id, text, extra \\ %{}) do
    Orchestration.dispatch(
      Map.merge(
        %{
          "type" => "message.dispatch",
          "threadId" => thread_id,
          "messageId" => message_id,
          "text" => text,
          "attachments" => [],
          "dispatchMode" => %{"type" => "queue_after_active"}
        },
        extra
      )
    )
  end

  defp queue_command(type, thread_id, run_id, extra \\ %{}),
    do:
      Orchestration.dispatch(
        Map.merge(%{"type" => type, "threadId" => thread_id, "runId" => run_id}, extra)
      )

  # Waits until the thread's runs, in order, have these statuses.
  defp await_statuses(thread_id, statuses) do
    state = current(thread_id)

    if Enum.map(runs(state), & &1["status"]) == statuses do
      state
    else
      receive do
        {:hal_c2_stream, ^thread_id, _} -> await_statuses(thread_id, statuses)
      after
        5_000 ->
          flunk(
            "runs never reached #{inspect(statuses)}: #{inspect(Enum.map(runs(state), & &1["status"]))}"
          )
      end
    end
  end

  defp await_request(thread_id) do
    receive do
      {:hal_c2_stream, ^thread_id, _} ->
        case thread_id |> current() |> StreamState.list("runtime-request") do
          [%{"status" => "pending"} = request] -> request
          _ -> await_request(thread_id)
        end
    after
      5_000 -> flunk("no approval request")
    end
  end
end
