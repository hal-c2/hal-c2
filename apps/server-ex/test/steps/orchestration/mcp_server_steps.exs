defmodule HalC2.Steps.Orchestration.McpServer do
  @moduledoc """
  Steps for `features/node/orchestration/mcp-server.feature`: the `hal-c2` MCP
  server, driven through `HalC2.Mcp.handle/2` as the agent of a thread would call it.

  Raw answers are kept in `context.mcp_response` (`{status, body}`); tool outcomes in
  `context.mcp_result` (see `HalC2.Test.Node.World.mcp_tool/5`). What the fake Codex CLI
  was given for a session comes from `World.codex_sessions/1`.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Node.World

  # --- background ------------------------------------------------------------------

  step "thread {string} in {string} runs on {string} in full-access mode and default interaction mode",
       %{args: [thread, project, instance]} = context do
    context
    |> World.providers()
    |> World.create_thread(thread, project, %{
      "modelSelection" => %{"instanceId" => instance, "model" => "gpt-5.4"},
      "runtimeMode" => "full-access",
      "interactionMode" => "default"
    })
  end

  step "{string} has a turn running on {string}", %{args: [thread, "codex"]} = context do
    context = World.send_turn(context, thread, "wait for it")
    await_active(context, thread)
    context
  end

  # --- credentials -----------------------------------------------------------------

  step("a run of {string} starts on {string}", %{args: [thread, "codex"]} = context,
    do: new_session(context, thread)
  )

  step("a run of {string} starts", %{args: [thread]} = context, do: new_session(context, thread))

  step "the agent is given the {string} server with a bearer credential for {string} on {string}",
       %{args: [name, thread, instance]} = context do
    server = get_in(latest_session(context), ["params", "config", "mcp_servers", name])
    assert %{"url" => url, "http_headers" => %{"Authorization" => "Bearer " <> _ = auth}} = server
    assert String.ends_with?(url, "/mcp")
    assert HalC2.Mcp.server(World.thread_id(context, thread), instance).authorization == auth

    # The credential acts as that thread.
    assert {200, %{"result" => %{"structuredContent" => %{"thread" => %{"threadId" => id}}}}} =
             HalC2.Mcp.handle(auth, tool_request("hal_c2_thread_read", %{}))

    assert id == World.thread_id(context, thread)
    Map.put(context, :credential, auth)
  end

  step "asking again for {string} on {string} gives the same credential",
       %{args: [thread, instance]} = context do
    assert HalC2.Mcp.server(World.thread_id(context, thread), instance).authorization ==
             context.credential

    context
  end

  step "{string} is given credentials for {string} and for {string}",
       %{args: [thread, first, second]} = context do
    id = World.thread_id(context, thread)

    Map.put(context, :credentials, [
      HalC2.Mcp.server(id, first).authorization,
      HalC2.Mcp.server(id, second).authorization
    ])
  end

  step "the two credentials are different", context do
    [first, second] = context.credentials
    assert "Bearer " <> _ = first
    assert "Bearer " <> _ = second
    assert first != second
    context
  end

  step ~r/^an MCP request arrives (?<how>with no authorization|with an unknown bearer credential|with a non-bearer authorization)$/,
       %{args: [how]} = context do
    authorization =
      case how do
        "with no authorization" -> nil
        "with an unknown bearer credential" -> "Bearer not-a-credential"
        "with a non-bearer authorization" -> "Basic " <> Base.encode64("agent:secret")
      end

    Map.put(context, :mcp_response, HalC2.Mcp.handle(authorization, request("ping")))
  end

  step "it is answered with status {int} and error {string}",
       %{args: [status, error]} = context do
    assert {^status, %{"error" => ^error}} = context.mcp_response
    context
  end

  step "project {string} turns agent access to HAL-C2 off", %{args: [project]} = context do
    id = World.project(context, project).id
    {settings, version} = HalC2.Settings.get()
    overrides = Map.get(settings, "projectSettingsOverrides", %{})

    settings =
      Map.put(
        settings,
        "projectSettingsOverrides",
        Map.put(overrides, id, %{"enableAgentBrowserAccess" => false})
      )

    {:ok, _} = HalC2.Settings.put(settings, version)
    assert HalC2.Settings.for_project(id)["enableAgentBrowserAccess"] == false
    context
  end

  step "the agent is given no {string} server", %{args: [name]} = context do
    session = latest_session(context)
    assert session["method"] in ["thread/start", "thread/resume"]
    assert get_in(session, ["params", "config", "mcp_servers", name]) == nil
    context
  end

  # --- protocol --------------------------------------------------------------------

  step "the agent of {string} initializes the MCP session", %{args: [caller]} = context do
    params = %{"protocolVersion" => "2025-03-26", "capabilities" => %{}}

    context
    |> Map.put(:mcp_response, World.mcp(context, caller, "initialize", params))
    |> Map.put(:protocol_version, "2025-03-26")
  end

  step "the answer names server {string}, offers tools and includes HAL-C2's agent instructions",
       %{args: [name]} = context do
    assert {200, %{"result" => result}} = context.mcp_response
    assert result["serverInfo"]["name"] == name
    assert Map.has_key?(result["capabilities"], "tools")
    assert result["instructions"] == HalC2.Mcp.instructions()
    assert result["instructions"] =~ "HAL-C2"
    context
  end

  step "the protocol version is the one the agent asked for", context do
    assert {200, %{"result" => %{"protocolVersion" => version}}} = context.mcp_response
    assert version == context.protocol_version
    context
  end

  step("the agent of {string} sends a ping", %{args: [caller]} = context,
    do: Map.put(context, :mcp_response, World.mcp(context, caller, "ping"))
  )

  step "it receives an empty result", context do
    assert {200, %{"jsonrpc" => "2.0", "id" => 1, "result" => result}} = context.mcp_response
    assert result == %{}
    context
  end

  step "the agent of {string} sends a notification without an id", %{args: [caller]} = context do
    body = JSON.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    Map.put(context, :mcp_response, HalC2.Mcp.handle(credential(context, caller), body))
  end

  step "the server accepts it with status {int} and no body", %{args: [status]} = context do
    assert context.mcp_response == {status, nil}
    context
  end

  step("the agent of {string} calls method {string}", %{args: [caller, method]} = context,
    do: Map.put(context, :mcp_response, World.mcp(context, caller, method))
  )

  step "it receives JSON-RPC error {int} {string}", %{args: [code, message]} = context do
    assert {200, %{"id" => 1, "error" => %{"code" => ^code, "message" => ^message}}} =
             context.mcp_response

    context
  end

  step "the agent of {string} sends a body that is not JSON", %{args: [caller]} = context do
    response = HalC2.Mcp.handle(credential(context, caller), "{not json")
    Map.put(context, :mcp_response, response)
  end

  step "it receives status {int} with JSON-RPC error {int}", %{args: [status, code]} = context do
    assert {^status, %{"error" => %{"code" => ^code}}} = context.mcp_response
    context
  end

  step("the agent of {string} lists the tools", %{args: [caller]} = context,
    do: Map.put(context, :mcp_response, World.mcp(context, caller, "tools/list"))
  )

  step "every thread, queue, project, worktree, pull request, schedule, delegation, preview and device tool is listed",
       context do
    assert {200, %{"result" => %{"tools" => tools}}} = context.mcp_response

    exported =
      Application.app_dir(:hal_c2, "priv/mcp_tools.json")
      |> File.read!()
      |> JSON.decode!()
      |> Enum.map(& &1["name"])

    listed = Enum.map(tools, & &1["name"])
    assert Enum.sort(listed) == Enum.sort(exported)

    for prefix <- ~w(hal_c2_thread_ hal_c2_queue_ hal_c2_project_ hal_c2_worktree_ preview_ device_),
        do: assert(Enum.any?(listed, &String.starts_with?(&1, prefix)), prefix)

    for name <- ~w(link_pull_request schedule_task delegate_task), do: assert(name in listed)
    assert Enum.all?(tools, &(is_binary(&1["description"]) and is_map(&1["inputSchema"])))
    context
  end

  # --- tool results ----------------------------------------------------------------

  step "the agent of {string} reads a thread that does not exist", %{args: [caller]} = context do
    response =
      World.mcp(context, caller, "tools/call", %{
        "name" => "hal_c2_thread_read",
        "arguments" => %{"threadId" => "thread-that-does-not-exist"}
      })

    Map.put(context, :mcp_response, response)
  end

  step "the tool result is marked as an error", context do
    assert {200, %{"result" => %{"isError" => true}}} = context.mcp_response
    context
  end

  step "it carries code {string} with a message", %{args: [code]} = context do
    {200, %{"result" => %{"content" => [%{"type" => "text", "text" => text}]}}} =
      context.mcp_response

    assert %{"_tag" => "OrchestratorMcpFailure", "code" => ^code, "message" => message} =
             JSON.decode!(text)

    assert message != ""
    context
  end

  step("the agent of {string} calls a tool {string}", %{args: [caller, name]} = context,
    do: Map.put(context, :mcp_result, World.mcp_tool(context, caller, name))
  )

  # A thread name, never a file path: review-diffs owns `"src/old.ts" was deleted`.
  step ~r/^"(?<thread>[^".]+)" was deleted$/, %{args: [thread]} = context do
    # The agent's credential was handed out before its thread went away.
    context = Map.put(context, :credential, credential(context, thread))
    context = end_turn(context, thread)

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.delete",
        "commandId" => "cmd-delete-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, thread)
      })

    World.await_row(World.thread_id(context, thread), &(&1 == nil or &1["deletedAt"] != nil))
    context
  end

  step "its agent calls any tool", context do
    {200, body} = HalC2.Mcp.handle(context.credential, tool_request("hal_c2_thread_list", %{}))
    %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} = body
    %{"code" => code, "message" => message} = JSON.decode!(text)
    Map.put(context, :mcp_result, {:error, code, message})
  end

  step "thread {string} belongs to project {string}", %{args: [thread, project]} = context do
    context =
      if Map.has_key?(context.projects, project),
        do: context,
        else: World.create_project(context, project)

    World.create_thread(context, thread, project)
  end

  step "the agent of {string} reads {string}", %{args: [caller, thread]} = context do
    result =
      World.mcp_tool(context, caller, "hal_c2_thread_read", %{
        "threadId" => World.thread_id(context, thread)
      })

    Map.put(context, :mcp_result, result)
  end

  # --- access rules ----------------------------------------------------------------

  step("{string} has no run starting, running or waiting", %{args: [thread]} = context,
    do: end_turn(context, thread)
  )

  step("{string} has no active run", %{args: [thread]} = context, do: end_turn(context, thread))

  # The thread still runs on its own instance; the calling agent holds another's credential.
  step "{string} is running on a different provider instance", %{args: [thread]} = context do
    await_active(context, thread)
    assert World.row(context, thread)["providerInstanceId"] in [nil, "codex"]
    Map.put(context, :mcp_instance, "claudeAgent")
  end

  step "the agent of {string} sends a message to another thread of {string}",
       %{args: [caller, project]} = context do
    context = World.create_thread(context, "other", project)

    result =
      World.mcp_tool(
        context,
        caller,
        "hal_c2_thread_send",
        %{"threadId" => World.thread_id(context, "other"), "message" => "say hi"},
        context[:mcp_instance] || "codex"
      )

    Map.put(context, :mcp_result, result)
  end

  step "the agent of {string} lists the threads of {string}",
       %{args: [caller, project]} = context do
    context = Map.put(context, :listed_project, World.project(context, project).id)
    Map.put(context, :mcp_result, World.mcp_tool(context, caller, "hal_c2_thread_list"))
  end

  step "it receives them", context do
    assert {:ok, %{"threads" => threads}} = context.mcp_result
    ids = Enum.map(threads, & &1["threadId"])

    for {_title, id} <- context.threads do
      {"thread", row} = HalC2.Shell.row(node(), id)
      if row["projectId"] == context.listed_project, do: assert(id in ids)
    end

    assert ids != []
    context
  end

  step ~r/^"(?<thread>[^"]+)" runs in (?<mode>approval-required|auto-accept-edits|auto|full-access) runtime mode$/,
       %{args: [thread, mode]} = context do
    set_mode(context, thread, "thread.runtime-mode.set", "runtimeMode", mode)
  end

  step ~r/^"(?<thread>[^"]+)" runs in (?<mode>plan|default) interaction mode$/,
       %{args: [thread, mode]} = context do
    set_mode(context, thread, "thread.interaction-mode.set", "interactionMode", mode)
  end

  step ~r/^thread "(?<thread>[^"]+)" in "(?<project>[^"]+)" runs in (?<mode>approval-required|auto-accept-edits|auto|full-access|plan|default) (?<kind>runtime|interaction) mode$/,
       %{args: [thread, project, mode, kind]} = context do
    World.create_thread(context, thread, project, %{"#{kind}Mode" => mode})
  end

  step "the agent of {string} changes {string}", %{args: [caller, thread]} = context do
    result =
      World.mcp_tool(context, caller, "hal_c2_thread_send", %{
        "threadId" => World.thread_id(context, thread),
        "message" => "say changed"
      })

    Map.put(context, :mcp_result, result)
  end

  step "the change is made", context do
    assert {:ok, %{"threadId" => id, "delivery" => "start_immediately"}} = context.mcp_result
    target = Enum.find_value(context.threads, fn {title, tid} -> if tid == id, do: title end)

    World.await_state(context, target, fn state ->
      Enum.any?(
        HalC2.StreamState.list(state, "message"),
        &(&1["text"] == "say changed" and
            &1["senderThreadId"] == World.thread_id(context, "caller"))
      )
    end)

    context
  end

  step ~r/^the agent of "(?<caller>[^"]+)" (?<change>creates a project|launches a thread|updates the environment preferences)$/,
       %{args: [caller, change]} = context do
    {tool, arguments} =
      case change do
        "creates a project" ->
          {"hal_c2_project_create",
           %{"workspaceRoot" => HalC2.Test.Node.tmp_dir(context.node, "new-project")}}

        "launches a thread" ->
          {"hal_c2_thread_launch", %{"title" => "Child", "message" => "say hi"}}

        "updates the environment preferences" ->
          {"hal_c2_environment_preferences_update", %{"defaultThreadEnvMode" => "worktree"}}
      end

    Map.put(context, :mcp_result, World.mcp_tool(context, caller, tool, arguments))
  end

  # --- credential lifetime ---------------------------------------------------------

  step "the agent of {string} has made no call for longer than the idle limit and has no turn in progress",
       %{args: [caller]} = context do
    context = end_turn(context, caller)
    "Bearer " <> token = auth = credential(context, caller)
    # A day and a minute since its last call (the liveness window is a day).
    idle_since = System.monotonic_time(:millisecond) - (24 * 60 + 1) * 60 * 1_000
    assert :ets.update_element(HalC2.Mcp.Credentials, token, {3, idle_since})
    Map.put(context, :credential, auth)
  end

  step "the provider session of {string} stops", %{args: [thread]} = context do
    context = Map.put(context, :credential, credential(context, thread))
    context = end_turn(context, thread)
    stop_session(context, thread)
    context
  end

  step ~r/^(?:it calls a tool|the old agent calls a tool with its credential)$/, context do
    response = HalC2.Mcp.handle(context.credential, tool_request("hal_c2_thread_list", %{}))
    Map.put(context, :mcp_response, response)
  end

  step "the call is refused with {string}", %{args: [error]} = context do
    assert {401, %{"error" => ^error}} = context.mcp_response
    context
  end

  # --- helpers ---------------------------------------------------------------------

  defp request(method, params \\ %{}),
    do: JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})

  defp tool_request(name, arguments),
    do: request("tools/call", %{"name" => name, "arguments" => arguments})

  defp credential(context, thread),
    do: HalC2.Mcp.server(World.thread_id(context, thread), "codex").authorization

  defp await_active(context, thread) do
    World.await_state(context, thread, fn state ->
      Enum.any?(HalC2.StreamState.list(state, "run"), &(&1["status"] == "running"))
    end)
  end

  # Ends the thread's running turn: steering the fake Codex with "say" answers and completes it.
  defp end_turn(context, thread) do
    if Enum.any?(World.runs(context, thread), &(&1["status"] in ~w(starting running waiting))) do
      await_active(context, thread)
      World.send_turn(context, thread, "say done")
    end

    World.await_state(context, thread, fn state ->
      Enum.all?(
        HalC2.StreamState.list(state, "run"),
        &(&1["status"] not in ~w(preparing starting running waiting))
      )
    end)

    context
  end

  defp stop_session(context, thread) do
    state = World.state(context, thread)
    [session | _] = HalC2.StreamState.list(state, "provider-session")

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "provider-session.detach",
        "commandId" => "cmd-detach-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, thread),
        "providerSessionId" => session["id"]
      })
  end

  # A fresh provider session for the thread: its turn ends, its session stops and a
  # new turn starts one again.
  defp new_session(context, thread) do
    context = end_turn(context, thread)
    stop_session(context, thread)
    before = length(World.codex_sessions(context))
    context = World.send_turn(context, thread, "wait again")
    await_active(context, thread)
    assert length(World.codex_sessions(context)) > before
    context
  end

  defp latest_session(context) do
    assert [_ | _] = sessions = World.codex_sessions(context)
    List.last(sessions)
  end

  defp set_mode(context, thread, type, field, mode) do
    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => type,
        "commandId" => "cmd-mode-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, thread),
        field => mode
      })

    World.await_row(World.thread_id(context, thread), &(&1[field] == mode))
    context
  end
end
