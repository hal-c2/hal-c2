defmodule HalC2.Steps.Settings.ScopesAndInheritance do
  @moduledoc """
  How an MC stores its settings document (versioned `hal-c2.readSettings` /
  `hal-c2.writeSettings`, pushed to `config` subscribers) and how a project's
  overrides resolve over it (`HalC2.Settings.for_project/1`). The scenario's MC
  is the first environment the Background names.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @environment_default %{"instanceId" => "claudeAgent", "model" => "claude-sonnet-4-6"}

  step "the user has environments {string} and {string}", %{args: [here, _other]} = context do
    Mc.ensure(HalC2.Settings)

    context
    |> Map.put(:environment_label, here)
    |> World.put_client(World.client(context))
  end

  step "the project {string} has a checkout on each environment", %{args: [title]} = context do
    World.create_project(context, title)
  end

  # --- versioned writes --------------------------------------------------------------

  step "a client has read the settings at their current version", context do
    read(context, "default")
  end

  step "the client writes a changed settings document at that version", context do
    write(context, "default", "24-hour")
  end

  step "the MC saves the document", context do
    assert HalC2.Settings.settings()["timestampFormat"] == "24-hour"
    context
  end

  step "the MC answers with the next version", context do
    assert {:ok, %{"version" => version}} = context.reply
    assert version == context.read["default"]["version"] + 1
    assert {_, ^version} = HalC2.Settings.get()
    context
  end

  step "two clients have read the settings at the same version", context do
    context = context |> read("first") |> read("second")
    assert context.read["first"]["version"] == context.read["second"]["version"]
    context
  end

  step "the first client has saved a change", context do
    context = write(context, "first", "24-hour")
    assert {:ok, _} = context.reply
    context
  end

  step "the second client writes its change at the old version", context do
    write(context, "second", "12-hour")
  end

  step "the MC refuses the write as stale settings", context do
    assert {:error, _, detail} = context.reply
    assert inspect(detail) =~ "StaleSettings"
    context
  end

  step "the first client's change is kept", context do
    assert HalC2.Settings.settings()["timestampFormat"] == "24-hour"
    context
  end

  step "a client is subscribed to this MC's settings", context do
    World.put_client(context, "subscriber", Mc.config(World.client(context, "subscriber")))
  end

  step "another client saves a settings change", context do
    context |> read("other") |> write("other", "24-hour")
  end

  step "the subscribed client receives the new settings document", context do
    {frame, client} =
      Mc.await(
        World.client(context, "subscriber"),
        &(&1["t"] == "config.settings" and &1["settings"]["timestampFormat"] == "24-hour")
      )

    assert frame["settings"] == HalC2.Settings.settings()
    World.put_client(context, "subscriber", client)
  end

  # --- project overrides ---------------------------------------------------------------

  step "the environment's default runtime mode is full access", context do
    World.update_settings(context, %{
      "defaultRuntimeMode" => "full-access",
      "timestampFormat" => "24-hour",
      "defaultThreadEnvMode" => "local"
    })
  end

  step "the project {string} overrides the default runtime mode to approval required",
       %{args: [project]} = context do
    override(context, project, %{"defaultRuntimeMode" => "approval-required"})
  end

  step "the MC resolves the settings for {string}", %{args: [project]} = context do
    Map.put(context, :resolved, HalC2.Settings.for_project(World.project(context, project).id))
  end

  step "the default runtime mode is approval required", context do
    assert context.resolved["defaultRuntimeMode"] == "approval-required"
    context
  end

  step "settings the project does not override keep the environment's values", context do
    environment = HalC2.Settings.settings()

    assert Map.delete(context.resolved, "defaultRuntimeMode") ==
             Map.delete(environment, "defaultRuntimeMode")

    assert environment["timestampFormat"] == "24-hour"
    context
  end

  # `timestampFormat` is not a `ProjectSettingsOverrides` key.
  step "the project {string} has an override for an environment-wide setting",
       %{args: [project]} = context do
    context
    |> World.update_settings(%{"timestampFormat" => "24-hour"})
    |> override(project, %{"timestampFormat" => "12-hour"})
  end

  step "that setting keeps the environment's value", context do
    assert context.resolved["timestampFormat"] == "24-hour"
    context
  end

  step "the project {string} overrides the default model with a model from {string}",
       %{args: [project, provider]} = context do
    assert provider == "Codex"

    context
    |> World.update_settings(%{"defaultModelSelection" => @environment_default})
    |> override(project, %{
      "defaultModelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"}
    })
  end

  step "the {string} provider is disabled on this environment", %{args: [provider]} = context do
    assert provider == "Codex"
    World.update_settings(context, %{"providers" => %{"codex" => %{"enabled" => false}}})
  end

  step "the default model is the environment's default model", context do
    assert context.resolved["defaultModelSelection"] == @environment_default
    context
  end

  # --- a project's provider switch ---------------------------------------------------
  #
  # Turns run on the fake Codex CLI; a turn that started is one the fake was asked to
  # start (`turn/start`), counted from when the project turned Codex off or on.

  step "the {string} provider is enabled on this environment", %{args: [provider]} = context do
    assert provider == "Codex"
    World.update_settings(context, %{"providers" => %{"codex" => %{"enabled" => true}}})
  end

  step "the project {string} turns {string} off", %{args: [project, provider]} = context do
    switch(context, project, provider, false)
  end

  step "the project {string} turns {string} on", %{args: [project, provider]} = context do
    switch(context, project, provider, true)
  end

  step "the project {string} has no provider switch of its own", context do
    context |> fakes() |> counted()
  end

  step "a turn on {string} starts in {string}", %{args: [provider, project]} = context do
    turn(context, provider, project, "turn")
  end

  step "the turn is refused because {string} is off", %{args: [provider]} = context do
    assert {:error, error, _} = context.reply
    assert error =~ "#{provider} is turned off"
    assert turn_starts(context) == context.turns_before
    context
  end

  step "the turn starts", context do
    assert {:ok, _} = context.reply
    World.await_runs(context, "turn", ["completed"], 10_000)
    assert turn_starts(context) == context.turns_before + 1
    context
  end

  # The six ways a turn starts. Each waits for the MC's answer: a refusal, or the run
  # that failed because its provider was off.

  step "the user starts a new thread on {string} in {string}",
       %{args: [_provider, project]} = context do
    {reply, context} = World.launch_thread(context, project, "hello")
    refused(context, reply)
  end

  step "the user sends a message on {string} in {string}",
       %{args: [_provider, project]} = context do
    context = World.create_thread(context, "sent", project)
    {reply, context} = World.dispatch(context, World.message_command(context, "sent", "hello"))
    refused(context, reply)
  end

  # Queued while the queue was held (as after a restart), so it comes up when resumed.
  step "a queued message comes up on {string} in {string}",
       %{args: [_provider, project]} = context do
    context =
      context
      |> World.create_thread("queued", project)
      |> World.add_message("queued", "user", "hello", nil, %{"id" => "msg-queued"})
      |> World.add_run("queued", "queued", nil, %{
        "userMessageId" => "msg-queued",
        "queuePosition" => 0,
        "queueHeld" => true,
        "startedAt" => nil
      })

    queued = World.thread_id(context, "queued")

    assert {:ok, _} =
             HalC2.Orchestration.dispatch(%{"type" => "queue.resume", "threadId" => queued})

    turned_off(context, "queued")
  end

  # The MC's own message carrying a delegated task's result is recorded; its run does
  # not start.
  step "a delegated task sends its follow-up on {string} in {string}",
       %{args: [_provider, project]} = context do
    context = World.create_thread(context, "parent", project)

    command =
      World.message_command(context, "parent", "<delegated_task_result>done", %{
        "commandId" => "command:delegate-result:task-1",
        "createdBy" => "system",
        "creationSource" => "server",
        "dispatchMode" => %{"type" => "queue_after_active"},
        "delegatedCompletion" => %{
          "parentRunId" => nil,
          "taskIds" => ["task-1"],
          "acceptedAt" => nil
        }
      })

    assert {:ok, _} = HalC2.Orchestration.dispatch(Map.delete(command, "modelSelection"))
    turned_off(context, "parent")
  end

  # The calling agent runs on Claude in the same project.
  step "an agent starts a child thread or delegates by MCP on {string} in {string}",
       %{args: [provider, project]} = context do
    claude = %{"instanceId" => "claudeAgent", "model" => "claude-sonnet-4-6"}

    context =
      context
      |> World.create_thread("caller", project, %{
        "modelSelection" => claude,
        "runtimeMode" => "full-access",
        "interactionMode" => "default"
      })
      |> World.add_run("caller", "running", nil, %{
        "providerInstanceId" => "claudeAgent",
        "modelSelection" => claude
      })

    target = %{"providerInstanceId" => World.instance(provider)}
    delegate = %{"task" => "hello", "mode" => "async", "target" => target}

    assert {:error, _, delegated} =
             World.mcp_tool(context, "caller", "delegate_task", delegate, "claudeAgent")

    child = %{"threads" => [%{"title" => "Child", "message" => "hello", "target" => target}]}

    created =
      case World.mcp_tool(context, "caller", "create_threads", child, "claudeAgent") do
        {:error, _, message} -> message
        {:ok, result} -> inspect(result)
      end

    assert delegated =~ "#{provider} is turned off"
    assert created =~ "#{provider} is turned off"
    context
  end

  step "a scheduled task runs on {string} in {string}",
       %{args: [_provider, project]} = context do
    Mc.ensure(HalC2.ScheduledTasks)
    Mc.ensure(HalC2.WorktreeSetup)

    input = %{
      "title" => "Nightly",
      "prompt" => "hello",
      "enabled" => true,
      "schedule" => %{"type" => "interval", "everyMs" => 3_600_000},
      "projectId" => World.project(context, project).id,
      "workspaceStrategy" => %{"type" => "root"},
      "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
      "runtimeMode" => "full-access",
      "interactionMode" => "default"
    }

    {{:ok, %{"task" => %{"id" => id}}}, context} =
      World.call(context, "scheduledTasks.upsert", input)

    {:ok, _} = HalC2.ScheduledTasks.subscribe(self())
    {_reply, context} = World.call(context, "scheduledTasks.runNow", %{"id" => id})
    task = await_task(id, &(&1["lastRunStatus"] == "failed"))
    assert task["lastRunError"] =~ "Codex is turned off"
    context
  end

  step "no {string} turn starts", %{args: [provider]} = context do
    assert provider == "Codex"
    assert turn_starts(context) == context.turns_before
    context
  end

  # --- a turn already running ----------------------------------------------------------

  # The parent delegates while Codex is on; the child's turn waits for the gate "answer".
  step "a {string} turn is running on a thread in {string} for a delegated task",
       %{args: [provider, project]} = context do
    context =
      context
      |> fakes()
      |> World.create_thread("parent", project, %{
        "runtimeMode" => "full-access",
        "interactionMode" => "default"
      })

    {{:ok, _}, context} = World.send_message(context, "parent", "wait for it")
    World.await_runs(context, "parent", ["running"])

    input = %{
      "task" => "answer from gate",
      "mode" => "async",
      "target" => %{"providerInstanceId" => World.instance(provider)}
    }

    assert {:ok, %{"taskId" => _}} =
             World.mcp_tool(context, "parent", "delegate_task", input, "codex")

    state =
      World.await_state(context, "parent", &(HalC2.StreamState.list(&1, "subagent") != []))

    [%{"childThreadId" => child}] = HalC2.StreamState.list(state, "subagent")
    World.await_row(child, & &1)
    context = put_in(context, [:threads, "child"], child)
    World.await_runs(context, "child", ["running"], 10_000)
    context
  end

  step "the running turn finishes", context do
    World.open_gate(context, "answer", "Migration written")
    World.await_runs(context, "child", ["completed"], 10_000)
    context
  end

  step "the delegated task's result still reaches its parent thread", context do
    World.await_state(context, "parent", fn state ->
      Enum.any?(
        HalC2.StreamState.list(state, "message"),
        &(&1["text"] =~ "<delegated_task_result" and &1["text"] =~ "Migration written")
      )
    end)

    context
  end

  # --- a prepared turn -----------------------------------------------------------------

  # A sibling's prepared run is released (and its turn finishes) while Codex is still on,
  # so its receipt is there to be asked for again.
  step "a {string} thread in {string} is preparing its worktree",
       %{args: [_provider, project]} = context do
    context = context |> fakes() |> prepared("prepared", project) |> prepared("earlier", project)

    command = %{
      "type" => "prepared-run.release",
      "commandId" => "cmd-release-earlier",
      "threadId" => World.thread_id(context, "earlier"),
      "runId" => hd(World.runs(context, "earlier"))["id"]
    }

    {reply, context} = World.dispatch(context, command)
    assert {:ok, %{"sequence" => _}} = reply
    World.await_runs(context, "earlier", ["completed"], 10_000)
    Map.merge(context, %{earlier: command, earlier_reply: reply})
  end

  step "its preparation failed", context do
    run = hd(World.runs(context, "prepared"))

    failure = %{
      "class" => "provider_error",
      "message" => "The worktree could not be made.",
      "code" => "worktree_failed",
      "retryable" => true
    }

    command = %{
      "type" => "prepared-run.fail",
      "threadId" => World.thread_id(context, "prepared"),
      "runId" => run["id"],
      "failure" => failure
    }

    {{:ok, _}, context} = World.dispatch(context, command)
    World.await_runs(context, "prepared", ["failed"])
    context
  end

  step "its preparation is still running", context do
    assert [%{"status" => "preparing"}] = World.runs(context, "prepared")
    context
  end

  step "the prepared turn is retried", context do
    run = hd(World.runs(context, "prepared"))
    thread = World.thread_id(context, "prepared")
    assert {:error, reason} = HalC2.Orchestration.retry_prepared(thread, run["id"])
    assert reason =~ "Codex is turned off for this project"
    assert [%{"status" => "failed"}] = World.runs(context, "prepared")
    context
  end

  step "the prepared turn is released", context do
    command = %{
      "type" => "prepared-run.release",
      "threadId" => World.thread_id(context, "prepared"),
      "runId" => hd(World.runs(context, "prepared"))["id"]
    }

    {reply, context} = World.dispatch(context, command)
    assert {:error, error, _} = reply
    assert error =~ "Codex is turned off for this project"
    assert [%{"status" => "failed"}] = World.runs(context, "prepared")
    context
  end

  step "a retry or release accepted before {string} was turned off is answered as before",
       context do
    {reply, context} = World.dispatch(context, context.earlier)
    assert reply == context.earlier_reply
    assert turn_starts(context) == context.turns_before
    context
  end

  # --- on for one project --------------------------------------------------------------

  step "{string} stays available for turns in {string}",
       %{args: [provider, project]} = context do
    id = World.project(context, project).id
    codex = Enum.find(HalC2.Settings.providers_for(id), &(&1["instanceId"] == "codex"))
    assert codex["enabled"] == true

    context = turn(context, provider, project, "turn")
    assert {:ok, _} = context.reply
    World.await_runs(context, "turn", ["completed"], 10_000)
    context
  end

  step "other projects still cannot start {string} turns", %{args: [provider]} = context do
    context = World.create_project(context, "other")
    context = turn(context, provider, "other", "elsewhere")
    assert {:error, error, _} = context.reply
    assert error =~ "#{provider} is turned off on this MC"
    context
  end

  # --- writing ---------------------------------------------------------------------------

  step "titles and commit messages are written by {string}", %{args: [provider]} = context do
    writer(context, provider)
  end

  step "commit messages are written by {string}", %{args: [provider]} = context do
    writer(context, provider)
  end

  step "a title is written for a thread in {string}", %{args: [project]} = context do
    root = World.project(context, project).root
    assert {:ok, _} = HalC2.TextGeneration.thread_title(root, "Fix the login form")
    Map.put(context, :written, [List.last(World.text_calls(context))])
  end

  step "it is written by the next usable provider", context do
    assert Enum.map(context.written, &writer_of/1) == ["claude"]
    context
  end

  step "titles in other projects are still written by {string}", %{args: [provider]} = context do
    context = World.create_project(context, "other")
    root = World.project(context, "other").root
    assert {:ok, _} = HalC2.TextGeneration.thread_title(root, "Fix the login form")
    assert writer_of(List.last(World.text_calls(context))) == String.downcase(provider)
    context
  end

  step "a draft thread in {string} works in a folder below the project root",
       %{args: [project]} = context do
    folder = Path.join(World.project(context, project).root, "apps/web")
    File.mkdir_p!(folder)
    Map.put(context, :folder, folder)
  end

  step "the user commits and opens a pull request from that thread", context do
    assert {:ok, _} =
             HalC2.TextGeneration.commit_message(context.folder, "main", "M a.txt", "+a")

    assert {:ok, _} =
             HalC2.TextGeneration.pr_content(context.folder, "main", "feature/a", "fix", "", "")

    Map.put(context, :written, World.text_calls(context))
  end

  step "the commit message and pull request text are written by the next usable provider",
       context do
    assert Enum.map(context.written, &writer_of/1) == ["claude", "claude"]
    context
  end

  # --- deleting the project ---------------------------------------------------------------

  step "the project {string} is deleted", %{args: [project]} = context do
    id = World.project(context, project).id
    assert {:ok, _} = HalC2.Projects.mutate(%{"type" => "project.delete", "projectId" => id})
    context
  end

  step "the settings keep no provider switch for {string}", %{args: [project]} = context do
    id = World.project(context, project).id
    refute Map.has_key?(HalC2.Settings.settings()["projectSettingsOverrides"] || %{}, id)
    assert HalC2.Settings.provider_off(id, "codex") == nil
    context
  end

  # --- the settings file --------------------------------------------------------------

  step "the settings file holds a project override written by a newer MC", context do
    World.update_settings(context, %{})
    id = World.project(context, "hal-c2").id

    document =
      Map.put(HalC2.Settings.settings(), "projectSettingsOverrides", %{
        id => %{"defaultAutoPull" => false, "someFutureSetting" => "kept"}
      })

    File.write!(settings_path(), JSON.encode!(document))
    Map.put(context, :project_id, id)
  end

  step "an older MC loads it and the user edits that project", context do
    mc = Mc.restart(context.mc)
    context = %{context | mc: mc, clients: %{}}
    context = read(context, "default")
    %{"settings" => settings, "version" => version} = context.read["default"]

    edited =
      put_in(settings, ["projectSettingsOverrides", context.project_id, "defaultAutoPull"], true)

    {reply, context} =
      World.call(context, "hal-c2.writeSettings", %{"settings" => edited, "version" => version})

    assert {:ok, _} = reply
    context
  end

  step "the newer override is still in the settings file", context do
    entry = saved()["projectSettingsOverrides"][context.project_id]
    assert entry == %{"defaultAutoPull" => true, "someFutureSetting" => "kept"}
    context
  end

  step "a client is connected to the MC", context do
    Mc.ensure(HalC2.Settings)
    World.put_client(context, "subscriber", Mc.config(World.client(context, "subscriber")))
  end

  step "the user changes a setting in settings.json with a text editor", context do
    edit_file(%{"timestampFormat" => "24-hour"})
    check()
    context
  end

  step "the client receives the changed settings without the MC restarting", context do
    {frame, _client} =
      Mc.await(
        World.client(context, "subscriber"),
        &(&1["t"] == "config.settings" and &1["settings"]["timestampFormat"] == "24-hour")
      )

    assert frame["settings"]["timestampFormat"] == "24-hour"
    context
  end

  step "the MC is running with its settings", context do
    context = World.update_settings(context, %{"timestampFormat" => "24-hour"})
    :ok = HalC2.Settings.watch(self())
    context
  end

  step "the user saves a settings.json that is not valid JSON", context do
    File.write!(settings_path(), "{not json")
    check()
    context
  end

  step "the MC keeps using the settings it had", context do
    assert HalC2.Settings.settings()["timestampFormat"] == "24-hour"
    context
  end

  step "connected clients are not sent broken settings", context do
    refute_received {:hal_c2_settings, _, _}
    context
  end

  step "the user edited settings.json by hand a moment ago", context do
    context = World.update_settings(context, %{"timestampFormat" => "24-hour"})
    context = read(context, "default")

    File.write!(
      settings_path(),
      JSON.encode!(Map.put(saved(), "defaultThreadEnvMode", "worktree"))
    )

    context
  end

  step "a client saves a different setting before the MC has read the edit", context do
    write(context, "default", "12-hour")
  end

  step "settings.json holds both the hand edit and the client's change", context do
    assert {:ok, _} = context.reply
    assert %{"defaultThreadEnvMode" => "worktree", "timestampFormat" => "12-hour"} = saved()
    context
  end

  step "the user edited one provider's settings in settings.json by hand a moment ago",
       context do
    providers = %{"codex" => %{"enabled" => true}, "claudeAgent" => %{"enabled" => true}}
    context = World.update_settings(context, %{"providers" => providers})
    context = read(context, "default")

    File.write!(
      settings_path(),
      JSON.encode!(put_in(saved(), ["providers", "codex", "binaryPath"], "/opt/codex"))
    )

    context
  end

  step "a client saves another provider's setting before the MC has read the edit", context do
    %{"settings" => settings, "version" => version} = context.read["default"]
    document = put_in(settings, ["providers", "claudeAgent", "binaryPath"], "/opt/claude")

    {reply, context} =
      World.call(context, "hal-c2.writeSettings", %{"settings" => document, "version" => version})

    Map.put(context, :reply, reply)
  end

  step "settings.json holds both providers' changes", context do
    assert {:ok, _} = context.reply

    assert %{
             "codex" => %{"enabled" => true, "binaryPath" => "/opt/codex"},
             "claudeAgent" => %{"enabled" => true, "binaryPath" => "/opt/claude"}
           } = saved()["providers"]

    context
  end

  step "settings.json holds a hand edit that is not valid JSON", context do
    context = World.update_settings(context, %{"timestampFormat" => "24-hour"})
    context = read(context, "default")
    File.write!(settings_path(), "{not json")
    check()
    context
  end

  step "a client saves a setting", context do
    context = if context[:read], do: context, else: read(context, "default")
    write(context, "default", "12-hour")
  end

  step "the save is refused", context do
    assert {:error, _, %{"_tag" => "ServerSettingsError"}} = context.reply
    context
  end

  step "settings.json still holds the user's text for them to fix", context do
    assert File.read!(settings_path()) == "{not json"
    context
  end

  # The MC is stopped and started again by "the MC starts".
  step "settings.json is not valid JSON", context do
    context = World.update_settings(context, %{"timestampFormat" => "24-hour"})
    File.write!(settings_path(), "{not json")
    context
  end

  step "the MC runs with the default settings", context do
    assert HalC2.Settings.settings() == %{}
    context
  end

  step "settings.json is left on disk unchanged", context do
    assert File.read!(settings_path()) == "{not json"
    context
  end

  step "later settings changes do not overwrite it until it is repaired", context do
    assert {:error, _} = HalC2.Settings.update(&Map.put(&1, "timestampFormat", "24-hour"))
    assert File.read!(settings_path()) == "{not json"
    context
  end

  step "settings.json is readable only by the user the MC runs as", context do
    assert File.stat!(settings_path()).mode |> Bitwise.band(0o777) == 0o600
    context
  end

  step "it is replaced in one step so a crash never leaves half a file", context do
    # Written beside itself and renamed over: no temporary file is left behind.
    refute File.exists?(settings_path() <> ".tmp")
    assert {:ok, %{}} = JSON.decode(File.read!(settings_path()))
    context
  end

  defp settings_path, do: Path.join(HalC2.Paths.config_dir(), "settings.json")

  defp saved do
    case File.read(settings_path()) do
      {:ok, text} -> JSON.decode!(text)
      {:error, :enoent} -> %{}
    end
  end

  defp edit_file(changes),
    do: File.write!(settings_path(), JSON.encode!(Map.merge(saved(), changes)))

  # The file check, run now and waited for.
  defp check do
    send(HalC2.Settings, :check)
    :sys.get_state(HalC2.Settings)
    :ok
  end

  defp read(context, client) do
    {{:ok, read}, context} = World.call(context, "hal-c2.readSettings", %{}, client)
    Map.update(context, :read, %{client => read}, &Map.put(&1, client, read))
  end

  defp write(context, client, format) do
    %{"settings" => settings, "version" => version} = context.read[client]
    document = Map.put(settings, "timestampFormat", format)

    {reply, context} =
      World.call(
        context,
        "hal-c2.writeSettings",
        %{"settings" => document, "version" => version},
        client
      )

    Map.put(context, :reply, reply)
  end

  defp override(context, project, values) do
    id = World.project(context, project).id
    World.update_settings(context, %{"projectSettingsOverrides" => %{id => values}})
  end

  defp fakes(%{agents: true} = context), do: context

  defp fakes(context) do
    File.mkdir_p!(Path.join(context.mc.home, "gate"))
    context |> World.agents() |> World.providers()
  end

  defp switch(context, project, provider, on) do
    assert provider == "Codex"

    context
    |> fakes()
    |> override(project, %{"providerInstances" => %{"codex" => %{"enabled" => on}}})
    |> counted()
  end

  defp counted(context), do: Map.put(context, :turns_before, turn_starts(context))

  defp turn_starts(context), do: length(World.codex_requests(context, "turn/start"))

  defp turn(context, provider, project, title) do
    context = context |> fakes() |> World.create_thread(title, project)

    command =
      World.message_command(context, title, "hello", %{
        "modelSelection" => %{"instanceId" => World.instance(provider), "model" => "gpt-5.4"}
      })

    {reply, context} = World.dispatch(context, command)
    Map.put(context, :reply, reply)
  end

  defp refused(context, reply) do
    assert {:error, error, _} = reply
    assert error =~ "Codex is turned off for this project"
    context
  end

  # The thread's run failed as one whose provider was turned off.
  defp turned_off(context, title) do
    World.await_runs(context, title, ["failed"])

    assert Enum.any?(
             World.state(context, title) |> HalC2.StreamState.list("turn-item"),
             &(&1["type"] == "error" and &1["failure"]["code"] == "provider_turned_off")
           )

    context
  end

  # Two copies of the first project, each its own run waiting for its workspace.
  defp prepared(context, title, project) do
    message = "msg-#{title}"

    context
    |> World.create_thread(title, project)
    |> World.add_message(title, "user", "hello", nil, %{"id" => message})
    |> World.add_run(title, "preparing", nil, %{"userMessageId" => message, "startedAt" => nil})
  end

  defp await_task(id, fun) do
    {:ok, %{"tasks" => tasks}} = HalC2.ScheduledTasks.list()
    task = Enum.find(tasks, &(&1["id"] == id))

    if task && fun.(task) do
      task
    else
      receive do
        {:hal_c2_scheduled_tasks, _, _} -> await_task(id, fun)
      after
        5_000 -> flunk("the scheduled task never got there: #{inspect(task)}")
      end
    end
  end

  defp writer(context, provider) do
    assert provider == "Codex"

    context
    |> World.fake_text_clis([:claude, :codex])
    |> World.update_settings(%{
      "textGenerationModelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4-mini"}
    })
  end

  # The CLI a text call ran: Codex runs `codex exec`.
  defp writer_of(%{"argv" => ["exec" | _]}), do: "codex"
  defp writer_of(%{"argv" => _}), do: "claude"
end
