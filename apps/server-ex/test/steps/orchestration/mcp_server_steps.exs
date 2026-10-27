defmodule HalC2.Steps.Orchestration.McpServer do
  @moduledoc """
  Steps for `features/mc/orchestration/mcp-server.feature`: the `hal-c2` MCP
  server, driven through `HalC2.Mcp.handle/2` as the agent of a thread would call it.

  Raw answers are kept in `context.mcp_response` (`{status, body}`); tool outcomes in
  `context.mcp_result` (see `HalC2.Test.Mc.World.mcp_tool/5`). What the fake Codex CLI
  was given for a session comes from `World.codex_sessions/1`.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc.World

  @claude_thread "claude work"

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

  step "the agent's {string} server allows a tool call to run longer than an hour",
       %{args: [name]} = context do
    server = get_in(latest_session(context), ["params", "config", "mcp_servers", name])
    assert server["tool_timeout_sec"] * 1_000 > 3_600_000
    context
  end

  step "a Claude agent's tool timeout is longer than an hour", context do
    turn = %{ids: %{}, launch: %{mcp: %{url: "http://x/mcp", authorization: "Bearer t"}}}
    env = HalC2.Claude.ThreadRuntime.session_env(turn)
    assert String.to_integer(List.keyfind(env, "MCP_TOOL_TIMEOUT", 0) |> elem(1)) > 3_600_000
    context
  end

  step "a wait by an agent on {string} may last an hour", %{args: [instance]} = context do
    assert HalC2.Mcp.max_wait_ms(instance) == 3_600_000
    context
  end

  step "a wait by an agent on an ACP provider may not reach a minute", context do
    assert HalC2.Mcp.max_wait_ms("opencode") < 60_000
    context
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

    {status, headers, body} = HalC2.Mcp.handle_request(authorization, %{}, request("ping"))

    context
    |> Map.put(:mcp_response, {status, body})
    |> Map.put(:mcp_headers, headers)
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
    assert result["instructions"] =~ HalC2.Mcp.instructions()
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
      for file <- ~w(mcp_tools.json mcp_mc_tools.json),
          tool <-
            Application.app_dir(:hal_c2, Path.join("priv", file))
            |> File.read!()
            |> JSON.decode!(),
          do: tool["name"]

    listed = Enum.map(tools, & &1["name"])
    assert Enum.sort(listed) == Enum.sort(exported)

    for prefix <-
          ~w(hal_c2_thread_ hal_c2_queue_ hal_c2_project_ hal_c2_worktree_ preview_ device_),
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
           %{"workspaceRoot" => HalC2.Test.Mc.tmp_dir(context.mc, "new-project")}}

        "launches a thread" ->
          {"hal_c2_thread_launch", %{"title" => "Child", "message" => "say hi"}}

        "updates the environment preferences" ->
          {"hal_c2_environment_preferences_update", %{"defaultThreadEnvMode" => "worktree"}}
      end

    Map.put(context, :mcp_result, World.mcp_tool(context, caller, tool, arguments))
  end

  # --- a renewed credential in a running Claude thread -----------------------------

  # Claude takes the server on its command line, so what each start was given is in
  # its arguments (`World.claude_starts/1`).
  step "the agent of a running Claude thread uses the {string} server",
       %{args: [name]} = context do
    context =
      context
      |> World.create_thread(@claude_thread, "demo", %{
        "modelSelection" => %{"instanceId" => "claudeAgent", "model" => "claude-haiku"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default"
      })
      |> World.send_turn(@claude_thread, "hello")

    World.await_runs(context, @claude_thread, ["completed"])
    assert [auth] = claude_credentials(context, name)
    assert {200, _} = HalC2.Mcp.handle(auth, request("tools/list", %{}))
    Map.put(context, :credential, auth)
  end

  # The credential lapses once the idle agent presents it after the idle limit; the
  # thread's next turn is given a new one.
  step "the thread's credential is renewed", context do
    "Bearer " <> token = context.credential
    idle_since = System.monotonic_time(:millisecond) - (24 * 60 + 1) * 60 * 1_000
    assert :ets.update_element(HalC2.Mcp.Credentials, token, {3, idle_since})
    assert {401, _} = HalC2.Mcp.handle(context.credential, request("tools/list", %{}))

    context = World.send_turn(context, @claude_thread, "hello again")
    World.await_runs(context, @claude_thread, ["completed", "completed"])
    context
  end

  step "the agent keeps its tools with the new credential", context do
    assert [old, new] = claude_credentials(context, "hal-c2")
    assert old == context.credential and new != old

    assert new ==
             HalC2.Mcp.server(World.thread_id(context, @claude_thread), "claudeAgent").authorization

    # The same conversation, in a process that has the new credential.
    assert "--resume" in List.last(World.claude_starts(context))

    assert {200, %{"result" => %{"tools" => [_ | _]}}} =
             HalC2.Mcp.handle(new, request("tools/list", %{}))

    context
  end

  step "the old credential is refused from then on", context do
    assert {401, %{"error" => "invalid_mcp_credential"}} =
             HalC2.Mcp.handle(context.credential, request("tools/list", %{}))

    context
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

  # --- credential lifetime, continued ------------------------------------------------

  step "the agent of {string} holds a credential", %{args: [thread]} = context do
    Map.put(context, :credential, credential(context, thread))
  end

  step "a call with that credential is refused with {string}", %{args: [error]} = context do
    assert {401, %{"error" => ^error}} =
             HalC2.Mcp.handle(context.credential, tool_request("hal_c2_thread_list", %{}))

    context
  end

  step "{string} leaves its provider session to change workspace and a run of {string} starts again",
       %{args: [thread, _again]} = context do
    context = end_turn(context, thread)

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.metadata.update",
        "commandId" => "cmd-workspace-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, thread),
        "branch" => "workspace-move",
        "worktreePath" => World.project(context, "demo").root,
        "expectedWorktreePath" => nil
      })

    context = World.send_turn(context, thread, "wait again")
    await_active(context, thread)
    context
  end

  step "the agent is given the same credential", context do
    server = get_in(latest_session(context), ["params", "config", "mcp_servers", "hal-c2"])
    assert server["http_headers"]["Authorization"] == context.credential

    assert HalC2.Mcp.server(World.thread_id(context, "caller"), "codex").authorization ==
             context.credential

    context
  end

  # The stand-in pattern of `turn_lifecycle_test.exs`: the replacement registers
  # in the Codex registry (already released) while answering its own release
  # from the Claude registry, so the release sees a live session at its check.
  step "the provider session of {string} was replaced by a new one that holds the thread's credential",
       %{args: [thread]} = context do
    context = end_turn(context, thread)
    context = Map.put(context, :credential, credential(context, thread))
    thread_id = World.thread_id(context, thread)
    test = self()

    replaced =
      spawn(fn ->
        {:ok, _} = Registry.register(HalC2.Claude.Registry, thread_id, nil)
        send(test, :replaced_registered)

        receive do
          {:"$gen_call", from, :release} ->
            starter = self()

            spawn(fn ->
              {:ok, _} = Registry.register(HalC2.Codex.Registry, thread_id, nil)
              send(starter, :replacement_registered)

              receive do
                :stop -> Registry.unregister(HalC2.Codex.Registry, thread_id)
              end
            end)

            receive do
              :replacement_registered -> :ok
            after
              5_000 -> exit(:replacement_never_registered)
            end

            Registry.unregister(HalC2.Claude.Registry, thread_id)
            GenServer.reply(from, :ok)
        end
      end)

    assert_receive :replaced_registered, 5_000

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(replaced), do: Process.exit(replaced, :kill)
    end)

    context
  end

  step "the old session is released", context do
    assert :ok = HalC2.Orchestration.release_session(World.thread_id(context, "caller"))
    context
  end

  step "the agent of the new session can still call tools", context do
    assert {200, %{"result" => %{"tools" => [_ | _]}}} =
             HalC2.Mcp.handle(context.credential, request("tools/list", %{}))

    context
  end

  # A real failed open: the fake ACP agent refuses `session/new` until its
  # auth file exists, so preparing its session fails after minting.
  step "a credential was made for {string} and its provider session then failed to open",
       %{args: [thread]} = context do
    context =
      World.create_thread(context, "acp work", "demo", %{
        "modelSelection" => %{"instanceId" => "opencode", "model" => "openai/gpt-5"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default"
      })

    auth = HalC2.Mcp.server(World.thread_id(context, "acp work"), "opencode").authorization
    System.put_env("FAKE_AUTH_FILE", Path.join(context.mc.home, "no-such-auth-file"))
    ExUnit.Callbacks.on_exit(fn -> System.delete_env("FAKE_AUTH_FILE") end)

    context = World.send_turn(context, "acp work", "hello")
    World.await_runs(context, "acp work", ["failed"])
    _ = thread
    Map.put(context, :credential, auth)
  end

  step "a tool is called with that credential", context do
    Map.put(
      context,
      :mcp_response,
      HalC2.Mcp.handle(context.credential, tool_request("hal_c2_thread_list", %{}))
    )
  end

  step "the settings that grant agents browser and device access cannot be read", context do
    # The settings service is down for the one preparation, as with an
    # unreadable settings file, and is then started again (it re-reads the
    # document it last wrote).
    :ok = ExUnit.Callbacks.stop_supervised(HalC2.Settings)
    assert Process.whereis(HalC2.Settings) == nil

    capabilities =
      try do
        HalC2.Mcp.for_agent(World.thread_id(context, "caller"), "codex")
        HalC2.Mcp.capabilities(World.thread_id(context, "caller"), "codex")
      after
        HalC2.Test.Mc.ensure(HalC2.Settings)
      end

    Map.put(context, :unreadable_capabilities, capabilities)
  end

  step "the agent's credential carries neither the browser nor the device capability", context do
    assert context.unreadable_capabilities == MapSet.new()
    context
  end

  # --- browser access on the credential ----------------------------------------------

  step "the user withholds agent browser access from {string}", %{args: [project]} = context do
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

  step "the agent's credential carries no browser capability", context do
    capabilities = HalC2.Mcp.capabilities(World.thread_id(context, "caller"), "codex")
    assert capabilities != nil
    refute MapSet.member?(capabilities, "preview")
    context
  end

  step "a call to a {string} tool fails with code {string}",
       %{args: [prefix, code]} = context do
    auth = credential(context, "caller")

    {200, %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}}} =
      HalC2.Mcp.handle(auth, tool_request("#{prefix}status", %{}))

    assert %{"code" => ^code} = JSON.decode!(text)
    context
  end

  step "the instructions the agent receives do not tell it that browser tools exist", context do
    auth = credential(context, "caller")
    params = %{"protocolVersion" => "2025-03-26", "capabilities" => %{}}

    {200, %{"result" => %{"instructions" => instructions}}} =
      HalC2.Mcp.handle(auth, request("initialize", params))

    refute instructions =~ "preview_"
    refute instructions =~ "collaborative browser"
    assert instructions =~ "HAL-C2 orchestration"
    context
  end

  step "the agent of {string} holds a credential made while browser access was allowed",
       %{args: [thread]} = context do
    auth = credential(context, thread)
    capabilities = HalC2.Mcp.capabilities(World.thread_id(context, thread), "codex")
    assert MapSet.member?(capabilities, "preview")
    Map.put(context, :credential, auth)
  end

  step "the user withholds agent browser access from {string} and a run of {string} starts",
       %{args: [project, thread]} = context do
    id = World.project(context, project).id
    {settings, version} = HalC2.Settings.get()
    overrides = Map.get(settings, "projectSettingsOverrides", %{})

    {:ok, _} =
      HalC2.Settings.put(
        Map.put(
          settings,
          "projectSettingsOverrides",
          Map.put(overrides, id, %{"enableAgentBrowserAccess" => false})
        ),
        version
      )

    new_session(context, thread)
  end

  step "the agent is given a new credential without the browser capability", context do
    auth = HalC2.Mcp.server(World.thread_id(context, "caller"), "codex").authorization
    assert auth != context.credential

    capabilities = HalC2.Mcp.capabilities(World.thread_id(context, "caller"), "codex")
    refute MapSet.member?(capabilities, "preview")
    context
  end

  step "the answer asks for a bearer credential", context do
    assert context.mcp_headers["www-authenticate"] == "Bearer"
    context
  end

  step "it forbids storing the answer", context do
    assert context.mcp_headers["cache-control"] == "no-store"
    context
  end

  # --- the server an ACP agent is given ------------------------------------------------

  @acp_thread "acp work"

  step "an ACP agent that advertises HTTP MCP servers", context do
    acp_agent(context, %{"mcpCapabilities" => %{"http" => true}})
  end

  step "an ACP agent that advertises no HTTP MCP servers", context do
    acp_agent(context, %{"mcpCapabilities" => %{}})
  end

  step "an ACP agent that can carry MCP messages over the ACP connection", context do
    acp_agent(context, %{"mcpCapabilities" => %{"http" => true, "acp" => true}})
  end

  step "a session of {string} starts on it", %{args: [_thread]} = context do
    context = World.send_turn(context, @acp_thread, "hello")
    World.await_runs(context, @acp_thread, ["completed"])
    context
  end

  step "a session of {string} starts on an ACP agent", %{args: [_thread]} = context do
    context = acp_agent(context, %{"mcpCapabilities" => %{"http" => true}})
    context = World.send_turn(context, @acp_thread, "hello")
    World.await_runs(context, @acp_thread, ["completed"])
    context
  end

  step "the agent is given the {string} server by address with its credential as an authorization header",
       %{args: [name]} = context do
    [server] = acp_servers(context, name)
    assert server["type"] == "http"
    assert String.ends_with?(server["url"], "/mcp")

    assert [%{"name" => "Authorization", "value" => "Bearer " <> _ = auth}] = server["headers"]

    assert auth ==
             HalC2.Mcp.server(World.thread_id(context, @acp_thread), "opencode").authorization

    context
  end

  step "the agent is given the {string} server as a local command speaking over standard input and output",
       %{args: [name]} = context do
    [server] = acp_servers(context, name)
    assert is_binary(server["command"])
    assert "acp-mcp-bridge" in server["args"]
    Map.put(context, :acp_server, server)
  end

  step "the credential and address reach that command through its environment, never its command line",
       context do
    server = context.acp_server
    env = Map.new(server["env"], &{&1["name"], &1["value"]})
    assert String.ends_with?(env["HAL_C2_ACP_MCP_ENDPOINT"], "/mcp")
    assert env["HAL_C2_ACP_MCP_AUTHORIZATION"] =~ "Bearer "

    command_line = Enum.join([server["command"] | server["args"]], " ")
    refute command_line =~ env["HAL_C2_ACP_MCP_AUTHORIZATION"]
    refute command_line =~ "Bearer"
    context
  end

  step "the agent is also offered the {string} server over the ACP connection under the id {string}",
       %{args: [name, server_id]} = context do
    servers = acp_servers(context, name)
    assert Enum.any?(servers, &(&1["type"] == "acp" and &1["serverId"] == server_id))
    context
  end

  step "the agent's environment names the MCP address, the credential and the command to run the call",
       context do
    [env] = World.acp_requests(context, "env")
    assert String.ends_with?(env["HAL_C2_ACP_MCP_ENDPOINT"], "/mcp")
    assert env["HAL_C2_ACP_MCP_AUTHORIZATION"] =~ "Bearer "
    assert is_binary(env["HAL_C2_ACP_MCP_NODE"]) and env["HAL_C2_ACP_MCP_NODE"] != ""
    context
  end

  step "the agent's instructions say to call the tools from its terminal when its tools are absent",
       context do
    [first | _] = acp_prompts(context)
    assert first =~ "HAL_C2_ACP_MCP_NODE"
    assert first =~ "acp-mcp-call"
    context
  end

  # --- ACP prompt instructions ---------------------------------------------------------

  step "an ACP agent of {string} has the {string} server", %{args: [_thread, _name]} = context do
    acp_agent(context, %{"mcpCapabilities" => %{"http" => true}})
  end

  step "the agent receives its first prompt, then another in the same mode, then one after the mode changed",
       context do
    context = World.send_turn(context, @acp_thread, "first ask")
    World.await_runs(context, @acp_thread, ["completed"])
    context = World.send_turn(context, @acp_thread, "second ask")
    World.await_runs(context, @acp_thread, ["completed", "completed"])

    {:ok, _} =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.interaction-mode.set",
        "commandId" => "cmd-mode-#{System.unique_integer([:positive])}",
        "threadId" => World.thread_id(context, @acp_thread),
        "interactionMode" => "plan"
      })

    context = World.send_turn(context, @acp_thread, "third ask")
    World.await_runs(context, @acp_thread, ["completed", "completed", "completed"])
    context
  end

  step "the instructions are in the first prompt and in the one after the change, but not in the second",
       context do
    [first, second, third] = acp_prompts(context)
    assert first =~ "HAL-C2 orchestration"
    refute second =~ "HAL-C2 orchestration"
    assert third =~ "HAL-C2 orchestration"
    assert third =~ "interaction mode: Plan"
    context
  end

  step "the user sends {string} to an ACP agent of {string}",
       %{args: [text, _thread]} = context do
    context = acp_agent(context, %{"mcpCapabilities" => %{"http" => true}})
    context = World.send_turn(context, @acp_thread, text)
    World.await_runs(context, @acp_thread, ["completed"])
    context
  end

  step "the prompt is sent without HAL-C2's instructions in front of it", context do
    [first | _] = acp_prompts(context)
    assert String.starts_with?(first, "/compact")
    refute first =~ "HAL-C2 orchestration"
    context
  end

  # --- the local command (stdio bridge) -------------------------------------------------

  step "the local command runs with the MCP address and credential of {string}",
       %{args: [thread]} = context do
    bridge(context, thread, mc_transport())
  end

  step "the agent writes a request on its input", context do
    HalC2.Mcp.Bridge.line(context.bridge, request("tools/list", %{}))

    HalC2.Mcp.Bridge.line(
      context.bridge,
      ~s({"jsonrpc":"2.0","method":"notifications/initialized"})
    )

    HalC2.Mcp.Bridge.flush(context.bridge)
    context
  end

  step "the MC's answer is written to its output as one line", context do
    assert [line | _] = bridge_lines(context)
    assert %{"result" => %{"tools" => [_ | _]}} = JSON.decode!(line)
    context
  end

  step "acknowledgements without a body write nothing", context do
    assert length(bridge_lines(context)) == 1
    context
  end

  step "the MC answered the agent's initialization with a session and a protocol version",
       context do
    context = with_recorder(context)
    context = bridge(context, "caller", recording_transport(context.recorded))

    HalC2.Mcp.Bridge.line(
      context.bridge,
      request("initialize", %{"protocolVersion" => "2025-03-26"})
    )

    HalC2.Mcp.Bridge.flush(context.bridge)
    context
  end

  step "the agent sends its next request", context do
    HalC2.Mcp.Bridge.line(context.bridge, request("tools/list", %{}))
    HalC2.Mcp.Bridge.flush(context.bridge)
    context
  end

  step "the request carries that session and protocol version", context do
    requests = Agent.get(context.recorded, &Enum.reverse/1)

    assert [_, %{"mcp-session-id" => "session-1", "mcp-protocol-version" => "2025-03-26"}] =
             requests

    context
  end

  step "the agent sends a request before its initialization has been answered", context do
    context = with_recorder(context)
    context = bridge(context, "caller", gated_transport(context.recorded, self()))

    HalC2.Mcp.Bridge.line(
      context.bridge,
      request("initialize", %{"protocolVersion" => "2025-03-26"})
    )

    assert_receive {:init_started, worker}, 5_000
    HalC2.Mcp.Bridge.line(context.bridge, request("tools/list", %{}))

    HalC2.Mcp.Bridge.line(
      context.bridge,
      JSON.encode!(%{"jsonrpc" => "2.0", "id" => "srv-1", "result" => %{}})
    )

    assert_receive {:forwarded, "srv-1"}, 5_000
    refute_received {:forwarded, "tools/list"}, 100
    send(worker, :release_init)
    HalC2.Mcp.Bridge.flush(context.bridge)
    context
  end

  step "the request is held until the initialization has finished", context do
    methods = Agent.get(context.recorded, &Enum.reverse/1)
    assert methods == ["initialize", "srv-1", "tools/list"]
    context
  end

  step "the agent's own responses to the MC are not held", context do
    methods = Agent.get(context.recorded, &Enum.reverse/1)

    assert Enum.find_index(methods, &(&1 == "srv-1")) <
             Enum.find_index(methods, &(&1 == "tools/list"))

    context
  end

  step "the MC answers a request as a stream of events", context do
    post = fn _endpoint, _headers, _body, emit ->
      emit.(%{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => %{"progress" => 1}
      })

      emit.(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
      {:ok, 200, %{}}
    end

    bridge(context, "caller", post)
  end

  step "the local command relays it", context do
    HalC2.Mcp.Bridge.line(context.bridge, request("tools/call", %{}))
    HalC2.Mcp.Bridge.flush(context.bridge)
    context
  end

  step "each event is written to the agent's output as one line", context do
    lines = bridge_lines(context)
    assert length(lines) == 2
    assert Enum.all?(lines, &(JSON.decode!(&1)["jsonrpc"] == "2.0"))
    context
  end

  step "the MC answers with an HTTP error {int}", %{args: [status]} = context do
    bridge(context, "caller", fn _e, _h, _b, _emit -> {:ok, status, %{}} end)
  end

  step "the agent had sent a request", context do
    HalC2.Mcp.Bridge.line(context.bridge, request("tools/list", %{}))
    HalC2.Mcp.Bridge.flush(context.bridge)
    context
  end

  step "the agent had sent a notification", context do
    HalC2.Mcp.Bridge.line(
      context.bridge,
      ~s({"jsonrpc":"2.0","method":"notifications/cancelled"})
    )

    HalC2.Mcp.Bridge.flush(context.bridge)
    context
  end

  step ~r/^the agent receives error (?<code>-?\d+) "(?<message>[^"]+)" for that request$/,
       %{args: [code, message]} = context do
    assert [line] = bridge_lines(context)

    assert %{"id" => 1, "error" => %{"code" => parsed, "message" => ^message}} =
             JSON.decode!(line)

    assert parsed == String.to_integer(code)
    context
  end

  step "nothing is written, since a notification expects no answer", context do
    assert bridge_lines(context) == []
    context
  end

  step "the agent writes a line that is not valid JSON to the local command", context do
    context = bridge(context, "caller", mc_transport())
    HalC2.Mcp.Bridge.line(context.bridge, "this is not json")
    HalC2.Mcp.Bridge.flush(context.bridge)
    context
  end

  step ~r/^it receives error (?<code>-?\d+) "(?<message>[^"]+)"$/,
       %{args: [code, message]} = context do
    assert [line] = bridge_lines(context)
    assert %{"error" => %{"code" => parsed, "message" => ^message}} = JSON.decode!(line)
    assert parsed == String.to_integer(code)
    context
  end

  step ~r/^the local command is started with no MCP address$/, context do
    Map.put(
      context,
      :cli,
      HalC2.Mcp.BridgeCli.command("acp-mcp-bridge", [], %{
        "HAL_C2_ACP_MCP_AUTHORIZATION" => "Bearer x"
      })
    )
  end

  step ~r/^the local command is started with no credential$/, context do
    Map.put(
      context,
      :cli,
      HalC2.Mcp.BridgeCli.command("acp-mcp-bridge", [], %{
        "HAL_C2_ACP_MCP_ENDPOINT" => "http://127.0.0.1/mcp"
      })
    )
  end

  step "it ends with status {int} saying what is missing", %{args: [status]} = context do
    assert {:error, ^status, message} = context.cli
    assert message =~ "HAL_C2_ACP_MCP_ENDPOINT"
    assert message =~ "HAL_C2_ACP_MCP_AUTHORIZATION"
    context
  end

  # --- one tool call from a terminal ------------------------------------------------------

  step "the terminal has the MCP address and credential of {string}",
       %{args: [thread]} = context do
    env = %{
      "HAL_C2_ACP_MCP_ENDPOINT" => HalC2.Mcp.endpoint(),
      "HAL_C2_ACP_MCP_AUTHORIZATION" => credential(context, thread)
    }

    context
    |> Map.put(:terminal_env, env)
    |> Map.put(:sessions_before, :ets.info(HalC2.Mcp.Sessions, :size))
  end

  step ~r/^"call (?<tool>\S+) with (?<arguments>.+)" is run$/,
       %{args: [tool, arguments]} = context do
    Map.put(
      context,
      :cli,
      HalC2.Mcp.BridgeCli.command("acp-mcp-call", [tool, arguments], context.terminal_env)
    )
  end

  step "the tool's result is printed as JSON", context do
    assert {:ok, output} = context.cli
    assert %{"structuredContent" => %{"providers" => [_ | _]}} = JSON.decode!(output)
    context
  end

  step "the call used a fresh authenticated MCP session", context do
    assert :ets.info(HalC2.Mcp.Sessions, :size) > context.sessions_before
    context
  end

  step "the terminal call is made with arguments that are not a JSON object", context do
    env = %{
      "HAL_C2_ACP_MCP_ENDPOINT" => HalC2.Mcp.endpoint(),
      "HAL_C2_ACP_MCP_AUTHORIZATION" => credential(context, "caller")
    }

    Map.put(
      context,
      :cli,
      HalC2.Mcp.BridgeCli.command("acp-mcp-call", ["orchestrator_capabilities", "[]"], env)
    )
  end

  step "the terminal call is made to an MC that rejects the initialization", context do
    post = fn _e, _h, body, emit ->
      %{"id" => id} = JSON.decode!(body)

      if id,
        do:
          emit.(%{
            "jsonrpc" => "2.0",
            "id" => id,
            "error" => %{"code" => -32603, "message" => "no"}
          })

      {:ok, 200, %{}}
    end

    result =
      HalC2.Mcp.Bridge.call_tool(
        "http://mc.invalid/mcp",
        "Bearer x",
        "orchestrator_capabilities",
        %{},
        post
      )

    Map.put(context, :cli, wrap_cli(result))
  end

  step "the terminal call is made for a tool that fails", context do
    post = fn _e, _h, body, emit ->
      decoded = JSON.decode!(body)
      id = decoded["id"]
      method = decoded["method"]

      cond do
        method == "initialize" ->
          emit.(%{
            "jsonrpc" => "2.0",
            "id" => id,
            "result" => %{"protocolVersion" => "2025-06-18"}
          })

        id != nil ->
          emit.(%{
            "jsonrpc" => "2.0",
            "id" => id,
            "error" => %{"code" => -32603, "message" => "it broke"}
          })

        true ->
          :ok
      end

      {:ok, 200, %{}}
    end

    result =
      HalC2.Mcp.Bridge.call_tool(
        "http://mc.invalid/mcp",
        "Bearer x",
        "hal_c2_teleport",
        %{},
        post
      )

    Map.put(context, :cli, wrap_cli(result))
  end

  step "it ends with a non-zero status and says the arguments must be a JSON object", context do
    assert {:error, status, message} = context.cli
    assert status != 0
    assert message =~ "arguments must be a JSON object"
    context
  end

  step "it ends with a non-zero status and says {string}", %{args: [said]} = context do
    assert {:error, status, message} = context.cli
    assert status != 0
    assert message =~ String.trim(said, "\"")
    context
  end

  step "it ends with a non-zero status and says {string} with the reason",
       %{args: [said]} = context do
    assert {:error, status, message} = context.cli
    assert status != 0
    assert message =~ String.trim(said, "\"")
    assert message =~ "it broke"
    context
  end

  # --- MCP over the ACP connection -----------------------------------------------------------

  step "an ACP agent connects to an MCP server over the ACP connection", context do
    over_acp(context)
  end

  step "it names a server other than {string}", %{args: [name]} = context do
    Map.put(
      context,
      :over_acp_result,
      HalC2.Mcp.OverAcp.connect(context.over_acp, "other-#{name}")
    )
  end

  step ~r/^the connection is refused with "(?<text>[^"]+)" and the name$/,
       %{args: [text]} = context do
    assert {:error, message} = context.over_acp_result
    assert message =~ text
    assert message =~ "other-hal-c2"
    context
  end

  step "an ACP agent has {int} MCP connections open over the ACP connection",
       %{args: [count]} = context do
    context = over_acp(context)

    ids =
      for _ <- 1..count do
        {:ok, id} = HalC2.Mcp.OverAcp.connect(context.over_acp, "hal-c2")
        id
      end

    Map.put(context, :over_acp_ids, ids)
  end

  # "It is refused with ..." is the shared step in stacked_pull_requests_steps:
  # it reads `World.failure/1`, so the refusal is also put where that reads.
  step "it opens another", context do
    refused(context, HalC2.Mcp.OverAcp.connect(context.over_acp, "hal-c2"))
  end

  step "an ACP agent sends an MCP message larger than 8 MiB over the ACP connection", context do
    context = over_acp(context)
    {:ok, id} = HalC2.Mcp.OverAcp.connect(context.over_acp, "hal-c2")
    big = String.duplicate("a", 8 * 1024 * 1024 + 1)
    result = HalC2.Mcp.OverAcp.message(context.over_acp, id, "tools/list", %{"pad" => big})

    context
    |> refused(result)
    |> Map.put(:over_acp_id, id)
  end

  step "the connection stays usable for smaller messages", context do
    assert {:ok, %{}} = HalC2.Mcp.OverAcp.message(context.over_acp, context.over_acp_id, "ping")
    context
  end

  step "an ACP agent has an MCP connection open over the ACP connection", context do
    context = over_acp(context)
    {:ok, id} = HalC2.Mcp.OverAcp.connect(context.over_acp, "hal-c2")

    {:ok, _} =
      HalC2.Mcp.OverAcp.message(context.over_acp, id, "initialize", %{
        "protocolVersion" => "2025-06-18"
      })

    [session_id] = Agent.get(context.recorded, & &1)
    assert HalC2.Mcp.session?(session_id)

    context |> Map.put(:over_acp_id, id) |> Map.put(:mcp_session_id, session_id)
  end

  step "it disconnects", context do
    assert :ok = HalC2.Mcp.OverAcp.disconnect(context.over_acp, context.over_acp_id)
    context
  end

  step "the MC's MCP session for it is ended", context do
    refute HalC2.Mcp.session?(context.mcp_session_id)
    context
  end

  step "a session the MC no longer has is not an error", context do
    assert :ok = HalC2.Mcp.end_session(context.mcp_session_id)
    assert :ok = HalC2.Mcp.end_session("a-session-that-never-was")
    context
  end

  step "an ACP agent has several MCP connections open over the ACP connection", context do
    context = over_acp(context)

    ids =
      for _ <- 1..3 do
        {:ok, id} = HalC2.Mcp.OverAcp.connect(context.over_acp, "hal-c2")

        {:ok, _} =
          HalC2.Mcp.OverAcp.message(context.over_acp, id, "initialize", %{
            "protocolVersion" => "2025-06-18"
          })

        id
      end

    sessions = Agent.get(context.recorded, & &1)
    assert length(sessions) == 3
    assert Enum.all?(sessions, &HalC2.Mcp.session?/1)

    context |> Map.put(:over_acp_ids, ids) |> Map.put(:mcp_session_ids, sessions)
  end

  step "its session ends", context do
    assert :ok = HalC2.Mcp.OverAcp.dispose(context.over_acp)
    context
  end

  step "every one of them is closed", context do
    assert HalC2.Mcp.OverAcp.connection_count(context.over_acp) == 0
    refute Enum.any?(context.mcp_session_ids, &HalC2.Mcp.session?/1)
    context
  end

  # --- runtime and orchestration instructions ---------------------------------------------

  step "{string} runs on {string} with the model {string} and high reasoning effort",
       %{args: [_thread, _driver, model]} = context do
    Map.put(context, :runtime_model, model)
  end

  step "the agent's instructions say it is running in HAL-C2 through the Claude Code harness as {string} with high reasoning effort",
       %{args: [model]} = context do
    instructions = claude_system_prompt(context, model: model, effort: "high")

    assert instructions =~
             "running in HAL-C2 through the Claude Code harness, as #{model} with high reasoning effort"

    Map.put(context, :agent_instructions, instructions)
  end

  step "they say there is no need to mention this unless asked", context do
    assert context.agent_instructions =~ "No need to mention this otherwise"
    context
  end

  step "{string} runs on a provider whose model is chosen automatically",
       %{args: [_thread]} = context do
    Map.put(context, :runtime_model, "auto")
  end

  step "the agent's instructions name the harness but no model", context do
    instructions = claude_system_prompt(context, model: context.runtime_model, effort: nil)
    assert instructions =~ "through the Claude Code harness."
    refute instructions =~ "through the Claude Code harness, as"
    context
  end

  step "the agent's instructions say it can embed images and videos in its answer using Markdown with absolute file paths",
       context do
    instructions = claude_system_prompt(context, model: "claude-haiku", effort: nil)

    assert instructions =~
             "embed images and videos in your response using Markdown with absolute file paths"

    context
  end

  step "the {string} server is attached to {string}", %{args: [_name, thread]} = context do
    assert HalC2.Mcp.for_agent(World.thread_id(context, thread), "codex") != nil
    Map.put(context, :server_attached, true)
  end

  step "the {string} server is not attached to {string}", %{args: [_name, _thread]} = context do
    Map.put(context, :server_attached, false)
  end

  step "the agent's instructions require linking every pull request it creates or updates to the thread, each layer of a stack included",
       context do
    instructions = claude_system_prompt(context, model: "claude-haiku", effort: nil)
    assert instructions =~ "link_pull_request"
    assert instructions =~ "every pull request you create or work on"
    assert instructions =~ "every layer"
    Map.put(context, :agent_instructions, instructions)
  end

  step "they tell it to list the thread's pull requests before finishing", context do
    assert context.agent_instructions =~
             "Before finishing PR work, call list_thread_pull_requests"

    context
  end

  step "they forbid linking unrelated pull requests", context do
    assert context.agent_instructions =~ "Do not link unrelated PRs"
    context
  end

  step "they tell it to report a link that failed", context do
    assert context.agent_instructions =~
             "report that failure instead of claiming the PR is linked"

    context
  end

  step "{string} runs on an agent that has no system prompt of its own",
       %{args: [_thread]} = context do
    context
  end

  step "{string} runs on an agent that takes a system prompt", %{args: [_thread]} = context do
    context
  end

  step "the user sends the first message of {string} and then a second one",
       %{args: [_thread]} = context do
    first = HalC2.Mcp.Instructions.first_run_prompt("first ask", 1, context.server_attached)
    second = HalC2.Mcp.Instructions.first_run_prompt("second ask", 2, context.server_attached)

    context |> Map.put(:first_message, first) |> Map.put(:second_message, second)
  end

  step "the user sends the first message of {string}", %{args: [_thread]} = context do
    Map.put(
      context,
      :first_message,
      HalC2.Mcp.Instructions.first_run_prompt("first ask", 1, context.server_attached)
    )
  end

  step "the orchestration instructions are in front of the first message", context do
    assert context.first_message =~ "<hal_c2_orchestration_instructions>"
    assert context.first_message =~ "HAL-C2 orchestration"
    assert String.ends_with?(context.first_message, "<user_request>\nfirst ask\n</user_request>")
    context
  end

  step "the second message is sent without them", context do
    assert context.second_message == "second ask"
    context
  end

  step "the message is sent without the orchestration instructions", context do
    assert context.first_message == "first ask"
    context
  end

  step "the orchestration instructions are in the agent's system prompt", context do
    instructions = claude_system_prompt(context, model: "claude-haiku", effort: nil)
    assert instructions =~ "HAL-C2 orchestration"
    assert instructions =~ HalC2.Mcp.Instructions.system_prompt(true)
    assert HalC2.Mcp.Instructions.system_prompt(false) == nil
    context
  end

  step "the user's messages are sent as written", context do
    message = HalC2.Claude.Protocol.user_message("as written") |> IO.iodata_to_binary()
    assert JSON.decode!(message)["message"]["content"] == "as written"
    context
  end

  # --- helpers ---------------------------------------------------------------------

  defp request(method, params \\ %{}),
    do: JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})

  # The credential each fake Claude start was given for the server `name`, oldest first.
  defp claude_credentials(context, name) do
    for argv <- World.claude_starts(context),
        index = Enum.find_index(argv, &(&1 == "--mcp-config")),
        do:
          argv
          |> Enum.at(index + 1)
          |> JSON.decode!()
          |> get_in(["mcpServers", name, "headers", "Authorization"])
  end

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

  # --- orchestrator capabilities ---------------------------------------------------

  # Option trees the size of OpenCode's, whose 567 models made the answer 258 KB.
  step "provider {string} offers {int} models, each with its own option descriptors",
       %{args: [instance, count]} = context do
    own =
      HalC2.Environment.providers()
      |> Enum.find(&(&1["instanceId"] == instance))
      |> Map.fetch!("models")
      |> length()

    models =
      for n <- 0..(count - own - 1) do
        %{
          "slug" => "bulk-model-#{n}",
          "name" => "Bulk Model #{n}",
          "capabilities" => %{
            "optionDescriptors" => [
              %{
                "id" => "variant",
                "label" => "Variant #{n}",
                "type" => "select",
                "options" =>
                  for level <- ~w(minimal low medium high xhigh max) do
                    %{"id" => level, "label" => "Reasoning #{level} for model #{n}"}
                  end
              }
            ]
          }
        }
      end

    World.put_settings(context, %{"providers" => %{instance => %{"customModels" => models}}})
  end

  step(
    "the agent of {string} asks for the orchestrator capabilities",
    %{args: [caller]} = context,
    do: capabilities(context, caller, %{})
  )

  step ~r/^the agent of "(?<caller>[^"]+)" asks for the orchestrator capabilities with (?<arguments>.+)$/,
       %{args: [caller, arguments]} = context do
    args =
      for part <- String.split(arguments, " and "), into: %{} do
        case Regex.run(~r/^(\w+)(?: (?:"(.*)"|(\d+)))?$/, part) do
          [_, "includeOptions"] -> {"includeOptions", true}
          [_, key, "", number] -> {key, String.to_integer(number)}
          [_, key, value] -> {key, value}
        end
      end

    capabilities(context, caller, args)
  end

  step "each provider lists at most 25 models, each with an id and a label", context do
    assert {:ok, %{"providers" => providers}} = context.mcp_result

    for provider <- providers do
      assert length(provider["models"]) <= 25
      assert Enum.all?(provider["models"], &(is_binary(&1["id"]) and is_binary(&1["label"])))
    end

    context
  end

  step "{string} reports {int} models in all and that its list is cut short",
       %{args: [instance, count]} = context do
    provider = provider(context, instance)
    assert provider["modelCount"] == count
    assert provider["modelsTruncated"] == true
    assert length(provider["models"]) < count
    context
  end

  step "no listed model carries option descriptors", context do
    assert {:ok, %{"providers" => providers}} = context.mcp_result
    refute Enum.any?(providers, &Enum.any?(&1["models"], fn model -> model["options"] end))
    context
  end

  step "the answer is under {int} characters, where with every option descriptor it is over {int}",
       %{args: [compact, full]} = context do
    assert {:ok, answer} = context.mcp_result
    assert String.length(JSON.encode!(answer)) < compact

    {:ok, everything} =
      World.mcp_tool(context, "caller", "orchestrator_capabilities", %{
        "providerInstanceId" => "codex",
        "includeOptions" => true
      })

    assert String.length(JSON.encode!(everything)) > full
    context
  end

  step "{string} is the only provider and lists all {int} models",
       %{args: [instance, count]} = context do
    assert {:ok, %{"providers" => [provider]}} = context.mcp_result
    assert provider["providerInstanceId"] == instance
    assert length(provider["models"]) == count
    refute provider["modelsTruncated"]
    context
  end

  step "only {string} is listed, with its option descriptors", %{args: [model]} = context do
    assert {:ok, %{"providers" => [provider]}} = context.mcp_result
    assert [%{"id" => ^model, "options" => [_ | _]}] = provider["models"]
    context
  end

  step "the listed models are those whose id or label contains the text", context do
    provider = provider(context, "codex")
    assert provider["modelCount"] == 11
    assert length(provider["models"]) == 11

    for model <- provider["models"],
        do: assert(String.contains?(String.downcase(model["label"]), "model 12"))

    context
  end

  step "every listed model carries its option descriptors", context do
    provider = provider(context, "codex")

    bulk = Enum.filter(provider["models"], &String.starts_with?(&1["id"], "bulk-model-"))
    assert length(bulk) > 25
    assert Enum.all?(bulk, &(&1["options"] != nil))
    context
  end

  defp capabilities(context, caller, args),
    do:
      Map.put(
        context,
        :mcp_result,
        World.mcp_tool(context, caller, "orchestrator_capabilities", args)
      )

  defp provider(context, instance) do
    assert {:ok, %{"providers" => providers}} = context.mcp_result
    Enum.find(providers, &(&1["providerInstanceId"] == instance))
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

  # An ACP thread on the fake agent, which reports `capabilities` merged over
  # its defaults. The background's Codex thread is untouched.
  defp acp_agent(context, capabilities) do
    caps =
      Map.merge(
        %{
          "loadSession" => true,
          "sessionCapabilities" => %{"resume" => %{}, "list" => %{}, "delete" => %{}}
        },
        capabilities
      )

    System.put_env("FAKE_ACP_CAPS", JSON.encode!(caps))
    System.put_env("FAKE_ACP_LOG", Path.join(context.mc.home, "acp-requests.log"))

    ExUnit.Callbacks.on_exit(fn ->
      System.delete_env("FAKE_ACP_CAPS")
      System.delete_env("FAKE_ACP_LOG")
    end)

    if context[:threads][@acp_thread] do
      context
    else
      World.create_thread(context, @acp_thread, "demo", %{
        "modelSelection" => %{"instanceId" => "opencode", "model" => "openai/gpt-5"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default"
      })
    end
  end

  defp acp_servers(context, name) do
    params = World.acp_requests(context, "session/new") |> List.last()
    assert params, "the fake ACP agent was given no session"
    Enum.filter(params["mcpServers"] || [], &(&1["name"] == name))
  end

  defp acp_prompts(context) do
    for params <- World.acp_requests(context, "session/prompt"),
        do: params["prompt"] |> List.first() |> Map.get("text")
  end

  # The system prompt a Claude run of "caller" is launched with, from the same
  # args its runtime builds (`HalC2.Claude.Protocol.cli_args/1`).
  defp claude_system_prompt(context, opts) do
    mcp = HalC2.Mcp.for_agent(World.thread_id(context, "caller"), "claudeAgent")
    args = HalC2.Claude.Protocol.cli_args([mcp: mcp] ++ opts)
    index = Enum.find_index(args, &(&1 == "--append-system-prompt"))
    assert index, "the Claude launch carries no system prompt"
    Enum.at(args, index + 1)
  end

  # A bridge over `post`, collecting its output lines in an agent.
  defp bridge(context, thread, post) do
    {:ok, lines} = Agent.start_link(fn -> [] end)

    {:ok, bridge} =
      HalC2.Mcp.Bridge.start_link(
        endpoint: HalC2.Mcp.endpoint(),
        authorization: credential(context, thread),
        post: post,
        out: fn line -> Agent.update(lines, &[line | &1]) end
      )

    ExUnit.Callbacks.on_exit(fn -> if Process.alive?(bridge), do: GenServer.stop(bridge) end)

    context |> Map.put(:bridge, bridge) |> Map.put(:bridge_lines, lines)
  end

  defp bridge_lines(context),
    do:
      Agent.get(context.bridge_lines, &Enum.reverse/1)
      |> Enum.map(&String.trim_trailing(&1, "\n"))

  defp with_recorder(context) do
    {:ok, recorded} = Agent.start_link(fn -> [] end)
    Map.put(context, :recorded, recorded)
  end

  # The MC itself as a transport: the same handler its HTTP route calls.
  defp mc_transport do
    fn _endpoint, headers, body, emit ->
      {status, resp_headers, reply} =
        HalC2.Mcp.handle_request(headers["authorization"], headers, body)

      if reply, do: emit.(reply)
      {:ok, status, resp_headers}
    end
  end

  # Answers initialize with a session and the asked-for protocol version, and
  # records the headers of every request it is given.
  defp recording_transport(recorded) do
    fn _endpoint, headers, body, emit ->
      Agent.update(recorded, &[headers | &1])
      request = JSON.decode!(body)

      if request["method"] == "initialize" do
        emit.(%{
          "jsonrpc" => "2.0",
          "id" => request["id"],
          "result" => %{"protocolVersion" => "2025-03-26"}
        })

        {:ok, 200, %{"mcp-session-id" => "session-1"}}
      else
        if request["id"], do: emit.(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{}})
        {:ok, 200, %{}}
      end
    end
  end

  # Like the recording transport, but initialization waits for the test to
  # release it, so what the bridge holds back can be observed.
  defp gated_transport(recorded, test) do
    fn _endpoint, _headers, body, emit ->
      request = JSON.decode!(body)
      label = request["method"] || request["id"]
      Agent.update(recorded, &[label | &1])
      send(test, {:forwarded, label})

      if request["method"] == "initialize" do
        send(test, {:init_started, self()})

        receive do
          :release_init -> :ok
        end

        emit.(%{
          "jsonrpc" => "2.0",
          "id" => request["id"],
          "result" => %{"protocolVersion" => "2025-03-26"}
        })

        {:ok, 200, %{"mcp-session-id" => "session-1"}}
      else
        if request["id"] && request["method"],
          do: emit.(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{}})

        {:ok, 200, %{}}
      end
    end
  end

  defp wrap_cli({:ok, result}), do: {:ok, JSON.encode!(result) <> "\n"}
  defp wrap_cli({:error, message}), do: {:error, 1, message}

  # Puts a refusal where the shared "it is refused with" step reads it.
  defp refused(context, {:error, message}) do
    log = Path.join(context.mc.home, "empty-cli.log")
    File.write!(log, "")

    context
    |> Map.put(:over_acp_result, {:error, message})
    |> Map.put(:reply, {:error, message, nil})
    |> Map.put(:cli, %{log: log})
  end

  defp refused(context, other), do: Map.put(context, :over_acp_result, other)

  # An MCP-over-ACP bridge for "caller" over the MC transport, recording the
  # session ids the MC hands out.
  defp over_acp(context) do
    context = with_recorder(context)
    recorded = context.recorded

    post = fn endpoint, headers, body, emit ->
      result = mc_transport().(endpoint, headers, body, emit)

      case result do
        {:ok, _status, %{"mcp-session-id" => session_id}} ->
          Agent.update(recorded, &[session_id | &1])

        _ ->
          :ok
      end

      result
    end

    delete = fn _endpoint, headers ->
      HalC2.Mcp.end_session(headers["mcp-session-id"])
      {:ok, 200}
    end

    {:ok, bridge} =
      HalC2.Mcp.OverAcp.start_link(
        endpoint: HalC2.Mcp.endpoint(),
        authorization: credential(context, "caller"),
        post: post,
        delete: delete
      )

    ExUnit.Callbacks.on_exit(fn -> if Process.alive?(bridge), do: GenServer.stop(bridge) end)
    Map.put(context, :over_acp, bridge)
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
