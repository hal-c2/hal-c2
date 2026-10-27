defmodule HalC2.McpTest do
  use ExUnit.Case, async: false

  alias HalC2.{Orchestration, StreamState}

  @moduletag :tmp_dir
  @fake_codex Path.expand("../support/fake_codex.py", __DIR__)
  @project "project-mcp"

  setup %{tmp_dir: dir} do
    work = Path.join(dir, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)

    {_, 0} =
      System.cmd("git", ~w(-c user.name=t -c user.email=t@t commit -q --allow-empty -m init),
        cd: work
      )

    Application.put_env(:hal_c2, :home, dir)
    Application.put_env(:hal_c2, :codex_command, ["python3", "-u", @fake_codex])
    on_exit(fn -> Application.delete_env(:hal_c2, :codex_command) end)

    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    start_supervised!({Registry, keys: :unique, name: HalC2.Codex.Registry})

    start_supervised!({Registry, keys: :unique, name: HalC2.Claude.Registry},
      id: :claude_registry
    )

    start_supervised!({Registry, keys: :unique, name: HalC2.Acp.Registry}, id: :acp_registry)
    start_supervised!({DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one})
    start_supervised!(HalC2.Mcp)
    :ok = HalC2.Shell.subscribe(self())

    {:ok, _} =
      HalC2.Projects.mutate(%{
        "type" => "project.create",
        "projectId" => @project,
        "title" => "Work",
        "workspaceRoot" => work
      })

    await_row(@project)
    %{work: work, dir: dir}
  end

  test "an agent launches a thread and works its own queue" do
    {caller, tool} = caller("wait for it")

    {:ok, launched} =
      tool.("hal_c2_thread_launch", %{"title" => "Side quest", "message" => "hello"})

    assert %{"projectId" => @project, "runId" => run_id} = launched
    assert is_binary(run_id)
    launched_id = launched["threadId"]

    assert [%{"status" => "completed"}] = runs(await_statuses(launched_id, ["completed"]))

    assert %{"createdBy" => "agent", "creationSource" => "mcp", "title" => "Side quest"} =
             StreamState.get(current(launched_id), "thread")[launched_id]

    {:ok, _} = tool.("hal_c2_thread_send", %{"message" => "first later", "mode" => "queue"})
    {:ok, _} = tool.("hal_c2_thread_send", %{"message" => "second later", "mode" => "queue"})
    [_, first, second] = runs(await_statuses(caller, ["running", "queued", "queued"]))

    {:ok, %{"items" => items, "nextCursor" => nil}} = tool.("hal_c2_queue_list", %{})
    assert Enum.map(items, & &1["text"]) == ["first later", "second later"]

    {:ok, _} =
      tool.("hal_c2_queue_edit", %{"queuedRunId" => second["id"], "text" => "second, edited"})

    {:ok, _} =
      tool.("hal_c2_queue_reorder", %{
        "queuedRunId" => second["id"],
        "beforeRunId" => first["id"]
      })

    {:ok, _} = tool.("hal_c2_queue_cancel", %{"queuedRunId" => first["id"]})

    {:ok, %{"items" => items}} = tool.("hal_c2_queue_list", %{})
    assert [%{"queuedRunId" => id, "text" => "second, edited"}] = items
    assert id == second["id"]

    assert {:ok, %{"text" => "second, edited", "truncated" => false}} =
             tool.("hal_c2_queue_read", %{"queuedRunId" => id})

    assert {:error, text} = tool.("hal_c2_queue_cancel", %{"queuedRunId" => first["id"]})
    assert text =~ "invalid_request"
  end

  # Reading a credential never rotates it; preparing a session does, and a
  # revoked credential's sessions go with it. A mid-session access flip must
  # not strand the token a live session still carries.
  test "a flipped access setting rotates at preparation, never on a read" do
    start_supervised!(HalC2.Settings)
    {thread_id, _tool} = caller("wait for it")
    %{authorization: auth} = HalC2.Mcp.server(thread_id, "codex")
    assert HalC2.Mcp.prepared?(thread_id, "codex")
    assert HalC2.Mcp.current(thread_id, "codex").authorization == auth

    initialize =
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{"protocolVersion" => "2025-06-18"}
      })

    {200, %{"mcp-session-id" => session_id}, _} = HalC2.Mcp.handle_request(auth, %{}, initialize)
    assert HalC2.Mcp.session?(session_id)

    {settings, version} = HalC2.Settings.get()

    {:ok, _} =
      HalC2.Settings.put(
        Map.put(settings, "projectSettingsOverrides", %{
          @project => %{"enableAgentBrowserAccess" => false}
        }),
        version
      )

    # Reads keep the live credential and its session.
    assert HalC2.Mcp.server(thread_id, "codex").authorization == auth
    assert HalC2.Mcp.current(thread_id, "codex").authorization == auth
    assert HalC2.Mcp.session?(session_id)
    refute HalC2.Mcp.prepared?(thread_id, "codex")

    # Preparation rotates: the old token and its sessions are gone.
    assert HalC2.Mcp.for_agent(thread_id, "codex") == nil
    assert {401, _} = HalC2.Mcp.handle(auth, initialize)
    refute HalC2.Mcp.session?(session_id)
    assert HalC2.Mcp.current(thread_id, "codex") == nil
    assert HalC2.Mcp.prepared?(thread_id, "codex")
  end

  test "an agent answers a pending question through MCP" do
    {caller, tool} = caller("ask me")
    request = await_request(caller)

    assert {:ok, %{"requestIds" => [id]}} = tool.("hal_c2_pending_request_list", %{})
    assert id == request["id"]

    assert {:ok, %{"questions" => [%{"id" => "color", "question" => "Which color?"}]}} =
             tool.("hal_c2_pending_request_read", %{"requestId" => id})

    assert {:ok, %{"sequence" => _}} =
             tool.("hal_c2_pending_request_respond", %{
               "requestId" => id,
               "answers" => %{"color" => "Red"}
             })

    state = await_statuses(caller, ["completed"])

    assert [%{"status" => "resolved", "answers" => %{"color" => "Red"}}] =
             StreamState.list(state, "runtime-request")

    assert {:ok, %{"requestIds" => []}} = tool.("hal_c2_pending_request_list", %{})
  end

  test "an agent registers and updates projects, and lists its workspace's branches", %{
    dir: dir,
    work: work
  } do
    {_caller, tool} = caller("wait for it")
    root = Path.join(dir, "other")

    {:ok, project} =
      tool.("hal_c2_project_create", %{
        "title" => "Other",
        "workspaceRoot" => root,
        "createWorkspaceRootIfMissing" => true
      })

    assert %{"title" => "Other", "workspaceRoot" => ^root} = project
    assert File.dir?(root)
    await_row(project["id"])

    assert {:error, text} =
             tool.("hal_c2_project_create", %{"title" => "Again", "workspaceRoot" => work})

    assert text =~ "already registered"

    assert {:ok, %{"title" => "Renamed", "autoPull" => true}} =
             tool.("hal_c2_project_update", %{
               "projectId" => project["id"],
               "title" => "Renamed",
               "autoPull" => true
             })

    assert {:ok, %{"isRepo" => true, "refs" => refs}} = tool.("hal_c2_worktree_list", %{})
    assert Enum.any?(refs, &(&1["name"] == "main"))

    assert {:ok, %{"attached" => false, "projectWorkspaceRoot" => ^work}} =
             tool.("hal_c2_worktree_status", %{})
  end

  test "an agent renames and pins its thread, and links its pull requests" do
    {caller, tool} = caller("wait for it")

    {:ok, %{"title" => "Renamed"}} =
      tool.("hal_c2_thread_update", %{"action" => "rename", "title" => "Renamed"})

    {:ok, _} = tool.("hal_c2_thread_organize", %{"action" => "pin"})
    assert current(caller) |> StreamState.get("thread") |> get_in([caller, "pinnedAt"])

    url = "https://github.com/acme/app/pull/7"

    assert {:ok, %{"host" => "github.com", "number" => 7, "alreadyLinked" => false}} =
             tool.("link_pull_request", %{"url" => url})

    assert {:ok, %{"alreadyLinked" => true}} = tool.("link_pull_request", %{"url" => url})

    assert {:ok, %{"pullRequests" => [%{"url" => ^url, "source" => "agent"}]}} =
             tool.("list_thread_pull_requests", %{})

    assert {:ok, %{"wasLinked" => true}} =
             tool.("unlink_pull_request", %{
               "repository" => "acme/app",
               "number" => 7,
               "host" => "github.com"
             })

    assert {:ok, %{"pullRequests" => []}} = tool.("list_thread_pull_requests", %{})
  end

  test "the new tools are advertised, and an idle caller cannot use them to change things" do
    thread_id = launch("hello")
    await_statuses(thread_id, ["completed"])
    await_row(thread_id)
    tool = tool(thread_id)

    %{authorization: auth} = HalC2.Mcp.server(thread_id, "codex")

    {200, %{"result" => %{"tools" => tools}}} =
      HalC2.Mcp.handle(
        auth,
        JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
      )

    names = Enum.map(tools, & &1["name"])
    assert "hal_c2_queue_list" in names and "hal_c2_thread_launch" in names
    assert "delegate_task" in names and "preview_snapshot" in names

    assert {:ok, %{"threadId" => ^thread_id, "runtimeMode" => "full-access"}} =
             tool.("hal_c2_thread_configuration", %{})

    assert {:error, text} = tool.("hal_c2_thread_launch", %{"title" => "Nope"})
    assert text =~ "parent_not_active"
  end

  # Two delegate_task calls with one request key, the second let through while
  # the first is held just before recording its task: the claim in the record's
  # transaction is what keeps it to one task and one child.
  test "two delegations with one request key racing start one task" do
    {caller, tool} = caller("wait for it")
    test_pid = self()
    Application.put_env(:hal_c2, :delegation_hook, {__MODULE__, :starting_gate, [test_pid]})
    on_exit(fn -> Application.delete_env(:hal_c2, :delegation_hook) end)

    args = %{"task" => "hello", "mode" => "async", "clientRequestId" => "race-1"}
    first = Task.async(fn -> tool.("delegate_task", args) end)
    assert_receive {:starting, first_pid}, 5_000
    second = Task.async(fn -> tool.("delegate_task", args) end)
    assert_receive {:starting, second_pid}, 5_000
    send(first_pid, :go)
    send(second_pid, :go)

    assert {:ok, %{"taskId" => task_id, "childThreadId" => child_id}} =
             Task.await(first, 10_000)

    assert {:ok, %{"taskId" => ^task_id, "childThreadId" => ^child_id}} =
             Task.await(second, 10_000)

    assert [%{"id" => ^task_id, "childThreadId" => ^child_id}] =
             StreamState.list(current(caller), "subagent")
  end

  @doc false
  def starting_gate(test_pid, :starting, _id) do
    send(test_pid, {:starting, self()})

    receive do
      :go -> :ok
    after
      10_000 -> :ok
    end
  end

  def starting_gate(_test_pid, _stage, _id), do: :ok

  # --- helpers ----------------------------------------------------------------------------

  # A running thread of the project and a function calling tools as its agent.
  defp caller(text) do
    thread_id = launch(text)
    await_statuses(thread_id, ["running"])
    await_row(thread_id)
    {thread_id, tool(thread_id)}
  end

  defp tool(thread_id) do
    %{authorization: auth} = HalC2.Mcp.server(thread_id, "codex")

    fn name, arguments ->
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      }

      case HalC2.Mcp.handle(auth, JSON.encode!(request)) do
        {200, %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}}} ->
          {:error, text}

        {200, %{"result" => %{"structuredContent" => result}}} ->
          {:ok, result}
      end
    end
  end

  defp launch(text) do
    thread_id = "thread-#{System.unique_integer([:positive])}"
    :ok = HalC2.Streams.subscribe(thread_id, self(), nil)

    {:ok, _} =
      Orchestration.launch_thread(%{
        "commandId" => "cmd-#{thread_id}",
        "threadId" => thread_id,
        "projectId" => @project,
        "title" => "Caller",
        "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "workspaceStrategy" => %{"type" => "root"},
        "initialMessage" => %{
          "messageId" => "msg-#{thread_id}",
          "text" => text,
          "attachments" => []
        }
      })

    thread_id
  end

  defp await_row(id) do
    unless HalC2.Shell.row(node(), id) do
      receive do
        {:hal_c2_shell, _} -> await_row(id)
      after
        5_000 -> flunk("no sidebar row for #{id}")
      end
    end
  end

  defp current(thread_id), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))

  defp runs(state), do: state |> StreamState.list("run") |> Enum.sort_by(& &1["ordinal"])

  # Waits until the thread's runs, in order, have these statuses.
  defp await_statuses(thread_id, statuses) do
    :ok = HalC2.Streams.subscribe(thread_id, self(), nil)
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
    case thread_id |> current() |> StreamState.list("runtime-request") do
      [%{"status" => "pending"} = request] ->
        request

      _ ->
        receive do
          {:hal_c2_stream, ^thread_id, _} -> await_request(thread_id)
        after
          5_000 -> flunk("no pending request")
        end
    end
  end
end
