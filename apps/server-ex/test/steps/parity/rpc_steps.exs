defmodule HalC2.Steps.Parity.Rpc do
  @moduledoc """
  Steps for `features/parity/rpc.feature`: every aligned contract method is called
  the way a protocol 3 client reaches it, with the smallest fixture that lets the
  node answer (`HalC2.Steps.Parity.Fixtures`).
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.Parity.Fixtures
  alias HalC2.Steps.Parity.Shapes
  alias HalC2.Test.Node
  alias HalC2.Test.Node.World

  # A client paired through an admin pairing link, as the desktop pairs a phone.
  step "a paired protocol 3 client", context do
    {:ok, %{"credential" => credential}} =
      HalC2.Auth.create_pairing_link(%{
        "label" => "Phone",
        "scopes" => HalC2.Auth.standard_scopes() ++ ~w(access:read access:write relay:write)
      })

    {:ok, access, _expires, _scopes} = HalC2.Auth.exchange(credential, %{"label" => "Phone"})
    {:ok, ticket, _} = HalC2.Auth.issue_ticket(access)
    World.put_client(context, Node.connect(context.node, "wsTicket=#{ticket}"))
  end

  step ~r/^the client calls (?<method>[\w.-]+) through its (?<via>.+)$/,
       %{args: [method, via]} = context do
    context = Fixtures.setup(context)

    case via do
      "rpc" ->
        rpc(context, method, method)

      "rpc as " <> name ->
        rpc(context, method, name)

      "shape " <> type ->
        {frame, context} = Shapes.first_frame(context, type)
        context = Shapes.settle(context, type)
        Map.merge(context, %{method: method, answer: {:shape, type, frame}})

      "socket frame" ->
        {reply, context} = World.call(context, method, %{"visible" => true})
        Map.merge(context, %{method: method, answer: {:rpc, method, reply}})

      "client adapter: answered by the client" <> _ ->
        # The adapter answers a probe from its open socket: a ping the node pongs.
        client = HalC2.Test.WsClient.send_json(World.client(context), %{"t" => "ping"})
        {frame, client} = Node.await(client, &(&1["t"] == "pong"))

        context
        |> World.put_client(client)
        |> Map.merge(%{method: method, answer: {:adapter, frame}})

      "client adapter: reads " <> rest ->
        [read | _] = String.split(rest, " ")
        rpc(context, method, read)
    end
  end

  step ~r/^the client calls "?(?<method>[\w.-]+)"?$/, %{args: [method]} = context do
    context = Fixtures.setup(context)
    rpc(context, method, method)
  end

  step ~r/^the node answers with the contract's response shape for (?<method>[\w.-]+)$/,
       %{args: [method]} = context do
    assert context.method == method

    case context.answer do
      {:adapter, frame} ->
        assert frame["t"] == "pong"

      {:shape, type, frame} ->
        assert frame["t"] in Shapes.frame_types(type), "#{type}: #{inspect(frame)}"

      {:rpc, name, {:ok, result}} ->
        Fixtures.assert_contract(method, name, result)

      {:rpc, name, {:error, error, detail}} ->
        refute error =~ "is not served by this node yet", "#{name} is not served"
        refute error =~ "** (", "#{name} crashed: #{error}"
        refute error =~ "node unavailable", "#{name}: #{error}"

        assert Fixtures.domain_error?(method, error, detail),
               "#{name}: #{error} #{inspect(detail)}"
    end

    context
  end

  step "the node answers with the settings document with its version", context do
    {:rpc, _, {:ok, result}} = context.answer
    assert %{"settings" => %{}, "version" => version} = result
    assert is_integer(version)
    context
  end

  step "the node answers with the new version, or a stale-settings error for an old version",
       context do
    {:rpc, _, {:ok, %{"version" => version}}} = context.answer
    assert version == context.fixtures.settings_version + 1

    # Writing again from the version read before is stale now.
    {reply, context} =
      World.call(context, "hal-c2.writeSettings", %{
        "settings" => %{},
        "version" => context.fixtures.settings_version
      })

    assert {:error, _error, %{"_tag" => "StaleSettings"}} = reply
    context
  end

  step "the node answers with one thread's stream rows with their offset and time", context do
    {:rpc, _, {:ok, result}} = context.answer
    assert %{"rows" => rows, "offset" => offset, "at" => at} = result
    assert is_integer(offset) and offset > 0 and at != nil
    thread = context.fixtures.thread
    assert Enum.any?(rows, &match?(["thread", ^thread, %{}], &1))
    context
  end

  step "the node answers with the keybindings after the change", context do
    {:rpc, _, {:ok, %{"rules" => rules}}} = context.answer
    assert Enum.any?(rules, &(&1["command"] == "terminal.toggle" and &1["key"] == "mod+shift+j"))
    context
  end

  step "the node answers with the keybindings after the removal", context do
    {:rpc, _, {:ok, %{"rules" => rules}}} = context.answer
    refute Enum.any?(rules, &(&1["command"] == "terminal.toggle" and &1["key"] == "mod+shift+j"))
    context
  end

  step "the node answers with a pairing link and its credential", context do
    {:rpc, _, {:ok, link}} = context.answer
    assert %{"id" => _, "credential" => _, "label" => "Parity", "expiresAt" => _} = link
    context
  end

  step "the node answers with the pairing links without their credentials", context do
    {:rpc, _, {:ok, links}} = context.answer
    assert is_list(links) and Enum.all?(links, &(not Map.has_key?(&1, "credential")))
    context
  end

  step ~r/^the node answers with whether the (?:link|client) was revoked$/, context do
    {:rpc, _, {:ok, %{"revoked" => false}}} = context.answer
    context
  end

  step "the node answers with the paired clients, the caller's own marked current", context do
    {:rpc, _, {:ok, clients}} = context.answer
    assert [%{"sessionId" => _, "connected" => true}] = Enum.filter(clients, & &1["current"])
    context
  end

  step "the node answers with how many other clients it revoked", context do
    {:rpc, _, {:ok, %{"revokedCount" => count}}} = context.answer
    assert is_integer(count)
    context
  end

  defp rpc(context, method, name) do
    {payload, context} = Fixtures.payload(context, name)
    {reply, context} = World.call(context, name, payload)
    Map.merge(context, %{method: method, reply: reply, answer: {:rpc, name, reply}})
  end
end

defmodule HalC2.Steps.Parity.Fixtures do
  @moduledoc """
  The smallest world each contract method can be called in: a project on a git
  repository with one thread, the services the method's domain runs on, and
  fakes in place of anything that would reach outside the node (GitHub, provider
  CLIs, the ACP registry, the user's home).
  """
  import ExUnit.Assertions

  alias HalC2.Test.Node
  alias HalC2.Test.Node.World

  @fake_acp Path.expand("../../support/fake_acp.py", __DIR__)

  @doc "Creates the fixtures once per scenario: `context.fixtures`."
  def setup(%{fixtures: _} = context), do: context

  def setup(context) do
    home = context.node.home
    Node.ensure(HalC2.Settings)

    # Nothing reaches a source control host, the user's provider homes or the
    # internet.
    for exe <- ~w(gh glab az), do: World.put_app_env(:"#{exe}_command", "hal-c2-test-no-#{exe}")
    World.put_app_env(:acp_commands, %{"opencode" => ["python3", "-u", @fake_acp]})
    World.put_app_env(:agent_sessions_home, Path.join(home, "user"))
    World.put_app_env(:usage_rates_url, write!(home, "rates.json", "{}"))
    World.put_env("CODEX_HOME", Path.join(home, "codex"))
    World.put_env("CLAUDE_CONFIG_DIR", Path.join(home, "claude"))
    ExUnit.Callbacks.on_exit(fn -> HalC2.Acp.forget("opencode") end)

    World.update_settings(context, %{
      "providerInstances" => %{"opencode" => %{"driver" => "opencode", "enabled" => true}}
    })

    context =
      context
      |> World.create_project("shop")
      |> World.create_thread("Work", "shop")

    project = World.project(context, "shop")
    {_, version} = HalC2.Settings.get()

    Map.put(context, :fixtures, %{
      root: project.root,
      project: project.id,
      thread: World.thread_id(context, "Work"),
      home: home,
      settings_version: version
    })
  end

  defp write!(dir, name, contents) do
    path = Path.join(dir, name)
    File.write!(path, contents)
    path
  end

  @doc "The payload `method` is called with, after any setup it needs."
  def payload(context, method) do
    services(method)
    f = context.fixtures
    pr = %{"projectId" => f.project, "host" => "github.com", "repository" => "acme/shop"}
    pr = Map.merge(pr, %{"number" => 1, "cwd" => f.root})

    case method do
      "server.refreshProviders" ->
        {%{"cwd" => f.root}, context}

      "server.updateProvider" ->
        {%{"provider" => "hal-c2-no-such-provider"}, context}

      "provider.consumeResetCredit" ->
        {%{"sourceId" => "hal-c2-missing"}, context}

      "provider.auth.start" ->
        {%{"instanceId" => "opencode", "methodId" => "hal-c2-none"}, context}

      "provider.auth.respond" ->
        {%{"instanceId" => "opencode", "flowId" => "hal-c2-none"}, context}

      "provider.auth." <> _ ->
        {%{"instanceId" => "opencode", "flowId" => "hal-c2-none"}, context}

      # Started against a download that fails at once: the reply is the new state.
      "provider.install.start" ->
        {%{"instanceId" => "antigravity"}, managed_install(context)}

      # No install is running, so the node refuses the stale operation.
      "provider.install.cancel" ->
        {%{"instanceId" => "antigravity", "operationId" => "hal-c2-none"},
         managed_install(context)}

      "provider.install.remove" ->
        {%{"instanceId" => "antigravity"}, managed_install(context)}

      "server.updateServer" ->
        {%{}, context}

      "hal-c2.readSettings" ->
        {%{}, context}

      "hal-c2.writeSettings" ->
        {%{"settings" => HalC2.Settings.settings(), "version" => f.settings_version}, context}

      "hal-c2.threadRows" ->
        {%{"threadId" => f.thread}, context}

      "hal-c2.upsertKeybinding" ->
        {keybinding(), context}

      "server.upsertKeybinding" ->
        {keybinding(), context}

      "hal-c2.removeKeybinding" ->
        {keybinding(), with_keybinding(context)}

      "server.removeKeybinding" ->
        {keybinding(), with_keybinding(context)}

      "hal-c2.createPairingLink" ->
        {%{"label" => "Parity", "scopes" => HalC2.Auth.standard_scopes()}, context}

      "hal-c2.revokePairingLink" ->
        {%{"id" => "pairing-missing"}, context}

      "hal-c2.revokeClient" ->
        {%{"sessionId" => "session-missing"}, context}

      "server.searchAcpRegistry" ->
        {%{"query" => ""}, registry(context)}

      "server.prepareAcpRegistryAgent" ->
        {%{"agentId" => "hal-c2-missing"}, registry(context)}

      "server.uninstallAcpRegistryManagedBinary" ->
        {%{"agentId" => "hal-c2-missing"}, context}

      "server.acceptAcpRegistryUrlAuth" ->
        {%{"instanceId" => "opencode", "elicitationId" => "hal-c2-none"}, context}

      "server." <> acp
      when acp in ~w(listAcpRegistrySessions listAcpRegistryProviders logoutAcpRegistry) ->
        {%{"instanceId" => "opencode", "projectId" => f.project}, context}

      "server.importAcpRegistrySession" ->
        {%{
           "instanceId" => "opencode",
           "projectId" => f.project,
           "sessionId" => "old-1",
           "title" => "Earlier work"
         }, context}

      "server.deleteAcpRegistrySession" ->
        {%{"instanceId" => "opencode", "projectId" => f.project, "sessionId" => "old/2"}, context}

      "server." <> acp when acp in ~w(setAcpRegistryProvider disableAcpRegistryProvider) ->
        {%{"instanceId" => "opencode", "projectId" => f.project, "providerId" => "fake"}, context}

      "server.get" <> history
      when history in ~w(ProcessResourceHistory ResourceTelemetryHistory) ->
        {%{"windowMs" => 60_000, "bucketMs" => 5_000}, context}

      "server.getUsageSummary" ->
        {%{"sinceDay" => "2026-09-01", "untilDay" => "2026-09-02", "timeZone" => "UTC"}, context}

      "server.signalProcess" ->
        {%{"pid" => 999_999_999, "startTimeMs" => 0, "signal" => "SIGTERM"}, context}

      "server.reportHostPowerState" ->
        {%{"onBattery" => false, "lowPowerMode" => false}, context}

      "pullRequests.list" ->
        {%{}, context}

      "pullRequests.listStats" ->
        {%{"refs" => []}, context}

      "pullRequests.routingIdentity" ->
        {%{"host" => "github.com"}, context}

      "pullRequests.invalidate" ->
        {pr, context}

      "pullRequests." <> _ ->
        {pr, context}

      "sourceControl.lookupRepository" ->
        {%{"provider" => "hal-c2-none", "repository" => "acme/shop"}, context}

      "sourceControl.cloneRepository" ->
        {%{
           "remoteUrl" => f.root,
           "destinationPath" => Path.join(Node.tmp_dir(context.node, "clones"), "shop")
         }, context}

      "projectClone.start" ->
        {%{
           "projectId" => "clone",
           "title" => "Clone",
           "createdAt" => World.iso_from_now(0),
           "remoteUrl" => f.root,
           "destinationPath" => Path.join(Node.tmp_dir(context.node, "clones"), "clone")
         }, context}

      "projectClone." <> _ ->
        {%{"projectId" => "hal-c2-missing"}, context}

      "sourceControl.publishRepository" ->
        {%{"cwd" => f.root, "provider" => "hal-c2-none", "repository" => "shop"}, context}

      "projects.searchEntries" ->
        {%{"cwd" => f.root, "query" => "READ"}, context}

      "projects.searchContents" ->
        {%{"cwd" => f.root, "query" => "shop"}, context}

      "projects.listEntries" ->
        {%{"cwd" => f.root}, context}

      "projects.readFile" ->
        {%{"cwd" => f.root, "relativePath" => "README.md"}, context}

      "projects.writeFile" ->
        {%{"cwd" => f.root, "relativePath" => "notes.md", "contents" => "hi\n"}, context}

      "projects.mutate" ->
        {%{"type" => "project.update", "projectId" => f.project, "title" => "Shop"}, context}

      "shell.openInEditor" ->
        {%{"cwd" => f.root, "editor" => "hal-c2-no-such-editor"}, context}

      "filesystem.browse" ->
        {%{"partialPath" => f.root <> "/"}, context}

      "agentSessions.scan" ->
        {%{}, context}

      "agentSessions.import" ->
        {%{"projectId" => f.project, "sessions" => []}, context}

      "assets.createUrl" ->
        {%{
           "resource" => %{
             "_tag" => "workspace-file",
             "threadId" => f.thread,
             "path" => "README.md"
           }
         }, context}

      "assets.persistChatAttachments" ->
        {%{"threadId" => f.thread, "attachments" => []}, context}

      "attachments.createUploadUrl" ->
        {%{"name" => "a.txt", "mimeType" => "text/plain", "sizeBytes" => 3}, context}

      "attachments.delete" ->
        {%{"attachmentId" => "pending-hal-c2"}, context}

      "provider.uploadFeedback" ->
        {%{"threadId" => f.thread, "reason" => "parity"}, context}

      "vcs.init" ->
        {%{"cwd" => Node.tmp_dir(context.node, "fresh")}, context}

      "vcs.createRef" ->
        {%{"cwd" => f.root, "refName" => "feature"}, context}

      "vcs.switchRef" ->
        {%{"cwd" => f.root, "refName" => "main"}, context}

      "vcs.createWorktree" ->
        {%{
           "cwd" => f.root,
           "refName" => "main",
           "newRefName" => "wt",
           "path" => Path.join(f.home, "wt")
         }, context}

      "vcs.removeWorktree" ->
        {%{"cwd" => f.root, "path" => Path.join(f.home, "gone")}, context}

      "vcs." <> _ ->
        {%{"cwd" => f.root}, context}

      "worktreeSetup.cancel" ->
        {%{"threadId" => f.thread}, context}

      "git.resolvePullRequest" ->
        {%{"cwd" => f.root, "reference" => "1"}, context}

      "git.preparePullRequestThread" ->
        {%{"cwd" => f.root, "reference" => "1", "mode" => "local"}, context}

      "review.getDiffPreview" ->
        {%{"cwd" => f.root}, context}

      "review.getDiffFileContents" ->
        {%{
           "cwd" => f.root,
           "sourceKind" => "working-tree",
           "changeType" => "change",
           "baseRef" => nil,
           "headRef" => nil,
           "oldPath" => "README.md",
           "newPath" => "README.md"
         }, context}

      "terminal.open" ->
        {terminal(f), context}

      "terminal.write" ->
        {Map.put(terminal(f), "data", "echo hi\n"), open_terminal(context)}

      "terminal.resize" ->
        {Map.merge(terminal(f), %{"cols" => 100, "rows" => 30}), open_terminal(context)}

      "terminal.list" ->
        {%{"threadId" => f.thread}, open_terminal(context)}

      "terminal." <> _ ->
        {terminal(f), open_terminal(context)}

      "preview.open" ->
        {%{"threadId" => f.thread, "url" => "http://127.0.0.1:1/"}, context}

      "preview.list" ->
        {%{"threadId" => f.thread}, context}

      "preview.navigate" ->
        preview_tab(context, %{"url" => "http://127.0.0.1:2/"})

      "preview.resize" ->
        preview_tab(context, %{"viewport" => %{"_tag" => "Fill"}})

      "preview.reportStatus" ->
        preview_tab(context, %{
          "navStatus" => %{"_tag" => "Success", "url" => "http://127.0.0.1:1/", "title" => ""}
        })

      "preview." <> _ ->
        preview_tab(context, %{})

      "previewAutomation.respond" ->
        {%{
           "clientId" => "hal-c2-none",
           "connectionId" => "hal-c2-none",
           "requestId" => "hal-c2-none",
           "ok" => true,
           "result" => %{}
         }, context}

      "previewAutomation.focusHost" ->
        {%{
           "clientId" => "hal-c2-none",
           "environmentId" => context.node.environment,
           "connectionId" => "hal-c2-none",
           "focused" => true
         }, context}

      "device.list" ->
        {%{"inspectOnly" => true}, context}

      "device.configure" ->
        {%{"onboardingCompleted" => true}, context}

      "device.testHost" ->
        {%{"id" => "hal-c2-host", "host" => "example.invalid"}, context}

      "device.open" ->
        {%{"threadId" => f.thread, "deviceId" => "hal-c2-none", "platform" => "android"}, context}

      "device.close" ->
        {%{"threadId" => f.thread}, context}

      "device.shutdown" ->
        {%{"deviceId" => "hal-c2-none", "platform" => "android"}, context}

      "device." <> _ ->
        {%{
           "threadId" => f.thread,
           "deviceId" => "hal-c2-none",
           "platform" => "android",
           "action" => %{"type" => "home"}
         }, context}

      "orchestration.dispatchCommand" ->
        {%{
           "type" => "thread.metadata.update",
           "commandId" => "cmd-parity",
           "threadId" => f.thread,
           "title" => "Renamed"
         }, context}

      "orchestration.getTurnDiff" ->
        {%{"threadId" => f.thread, "fromTurnCount" => 0, "toTurnCount" => 0}, context}

      "orchestration.getFullThreadDiff" ->
        {%{"threadId" => f.thread, "toTurnCount" => 0}, context}

      "orchestration.searchThreads" ->
        {%{"query" => "Work"}, context}

      "orchestration.getArchivedShellSnapshot" ->
        {%{}, context}

      "orchestration.getWorkflowScript" ->
        {%{"scriptPath" => Path.join(f.home, "missing.js")}, context}

      "orchestration.launchThread" ->
        {%{
           "threadId" => "launched",
           "projectId" => f.project,
           "title" => "Launched",
           "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"}
         }, context}

      "scheduledTasks.list" ->
        {%{}, context}

      "scheduledTasks.upsert" ->
        {task(), context}

      "scheduledTasks.setEnabled" ->
        {%{"id" => task_id(), "enabled" => true}, with_task(context)}

      "scheduledTasks.delete" ->
        {%{"id" => task_id()}, with_task(context)}

      "scheduledTasks.runNow" ->
        {%{"id" => "hal-c2-missing"}, context}

      # The test VM is not booted for clustering, so these fail as the contract's error.
      "cluster.join" ->
        {%{"link" => "http://127.0.0.1:1/?token=hal-c2-none"}, context}

      "cluster.remove" ->
        {%{"id" => "hal-c2-none"}, context}

      _ ->
        {%{}, context}
    end
  end

  # The services each domain runs on, as `HalC2.Application` starts them.
  defp services(method) do
    children =
      case method do
        "server.updateServer" ->
          [HalC2.Upgrade]

        "server.getBackgroundPolicy" ->
          [HalC2.BackgroundPolicy]

        "server.reportHostPowerState" ->
          [HalC2.BackgroundPolicy]

        "server." <> usage when usage in ~w(getUsageSummary refreshUsageRates) ->
          [HalC2.Usage]

        "provider.consumeResetCredit" ->
          [HalC2.UsageLimitSources]

        "provider.auth." <> _ ->
          provider_auth()

        "provider.install." <> _ ->
          provider_auth() ++ [HalC2.Acp.Antigravity.Installation]

        "provider.uploadFeedback" ->
          [registry_child(HalC2.Codex.Registry)]

        "server." <> "getProcess" <> _ ->
          [HalC2.Diagnostics]

        "server." <> d
        when d in ~w(getHostResources getResourceTelemetryHistory retryResourceTelemetry signalProcess getTraceDiagnostics) ->
          [HalC2.Diagnostics]

        "server." <> _ ->
          [
            registry_child(HalC2.Acp.Registry),
            HalC2.Acp.UrlAuth,
            {DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one}
          ]

        "pullRequests." <> _ ->
          [HalC2.PullRequests.Refreshes]

        "projectClone." <> _ ->
          [HalC2.ProjectClones]

        "projects." <> _ ->
          [HalC2.Workspace]

        "vcs." <> _ ->
          vcs()

        "worktreeSetup." <> _ ->
          [HalC2.WorktreeSetup]

        "terminal." <> _ ->
          terminals()

        "preview." <> _ ->
          [HalC2.Preview]

        "previewAutomation." <> _ ->
          [HalC2.PreviewAutomation]

        "device." <> _ ->
          [HalC2.Devices]

        "scheduledTasks." <> _ ->
          [HalC2.ScheduledTasks]

        "cluster." <> _ ->
          [HalC2.Cluster]

        _ ->
          []
      end

    Enum.each(children, &Node.ensure/1)
  end

  @doc false
  def terminals,
    do: [
      registry_child(HalC2.Terminal.Registry),
      {DynamicSupervisor, name: HalC2.Terminal.Supervisor, strategy: :one_for_one},
      HalC2.Terminal.Hub
    ]

  @doc false
  def vcs,
    do: [
      registry_child(HalC2.Vcs.Registry),
      {DynamicSupervisor, name: HalC2.Vcs.Supervisor, strategy: :one_for_one}
    ]

  @doc false
  def provider_auth,
    do: [
      registry_child(HalC2.ProviderAuth.Registry),
      {DynamicSupervisor, name: HalC2.ProviderAuth.Supervisor, strategy: :one_for_one},
      registry_child(HalC2.Acp.Registry)
    ]

  # A unique registry named `name`, with its own child id so several can start.
  defp registry_child(name),
    do: Supervisor.child_spec({Registry, keys: :unique, name: name}, id: name)

  @doc """
  An Antigravity instance whose runtime download fails at once, so a managed
  install never reaches the network or leaves anything behind.
  """
  def managed_install(context) do
    World.put_app_env(:antigravity_platform, {"linux", "x64"})
    World.put_app_env(:antigravity_free_space, fn _ -> nil end)
    World.put_app_env(:antigravity_fetch, fn _url, _dest, _progress -> {:error, "offline"} end)

    World.update_settings(context, %{
      "providerInstances" => %{"antigravity" => %{"driver" => "antigravity", "enabled" => false}}
    })
  end

  @doc false
  def keybinding, do: %{"key" => "mod+shift+j", "command" => "terminal.toggle"}

  defp with_keybinding(context) do
    {:ok, _} = HalC2.Keybindings.upsert(keybinding())
    context
  end

  @doc false
  def terminal(f), do: %{"threadId" => f.thread, "terminalId" => "term-1", "cwd" => f.root}

  defp open_terminal(context) do
    {_, context} = World.call!(context, "terminal.open", terminal(context.fixtures))
    context
  end

  defp preview_tab(context, extra) do
    f = context.fixtures

    {%{"tabId" => tab}, context} =
      World.call!(context, "preview.open", %{
        "threadId" => f.thread,
        "url" => "http://127.0.0.1:1/"
      })

    {Map.merge(%{"threadId" => f.thread, "tabId" => tab}, extra), context}
  end

  @doc false
  def task_id, do: "parity-task"

  @doc false
  def task,
    do: %{
      "id" => task_id(),
      "title" => "Nightly",
      "prompt" => "Check the build",
      "enabled" => false,
      "schedule" => %{"type" => "interval", "everyMs" => 600_000}
    }

  defp with_task(context) do
    {:ok, _} = HalC2.ScheduledTasks.upsert(task())
    context
  end

  defmodule AcpIndex do
    @moduledoc false
    @behaviour Plug
    def init(body), do: body
    def call(conn, body), do: Plug.Conn.send_resp(conn, 200, body)
  end

  # An empty ACP registry served on loopback in place of the public one.
  defp registry(context) do
    body = JSON.encode!(%{"version" => "1.0.0", "agents" => []})
    server = Node.ensure({Bandit, plug: {__MODULE__.AcpIndex, body}, port: 0, ip: :loopback})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    World.put_app_env(:acp_registry_url, "http://127.0.0.1:#{port}/registry.json")
    :persistent_term.erase({HalC2.Acp.Catalog, :index})
    ExUnit.Callbacks.on_exit(fn -> :persistent_term.erase({HalC2.Acp.Catalog, :index}) end)
    context
  end

  # The contract in `packages/contracts/src/rpc.ts`, read through its own schemas:
  # the keys each encoded success carries and the `_tag`s of each error union.
  @contract_script Path.expand("../../support/contract_keys.ts", __DIR__)
  @external_resource @contract_script
  @contract (case System.cmd("bun", [@contract_script], stderr_to_stdout: true) do
               {out, 0} -> out |> String.split("\n", trim: true) |> List.last() |> JSON.decode!()
               {out, _} -> raise "cannot read the rpc contract: #{out}"
             end)

  # Results the adapter does not decode as the contract's (`UNDECODED_RESULTS` in
  # packages/client-runtime/src/v3/session.ts).
  @undecoded ~w(orchestration.launchThread)

  @doc """
  Asserts a successful result carries the contract's success keys. A method read
  through another (`name`) is reshaped by the client adapter, so only its own
  answer is checked there.
  """
  def assert_contract(method, name, result) when name != method or method in @undecoded,
    do: assert(is_map(result), "#{name}: #{inspect(result)}")

  def assert_contract(method, name, result) do
    case @contract["results"][method] do
      keys when is_list(keys) ->
        assert is_map(result), "#{name}: #{inspect(result)}"
        missing = keys -- Map.keys(result)
        assert missing == [], "#{name} lacks #{inspect(missing)}: #{inspect(result)}"

      "null" ->
        assert result == nil, "#{name}: #{inspect(result)}"

      # A union: the adapter decodes the result as a whole.
      "Union" ->
        refute is_nil(result), "#{name}: #{inspect(result)}"
    end
  end

  @doc "Whether a failed call failed with one of the contract's errors, not as a crash."
  def domain_error?(method, error, detail) do
    match?(%{"_tag" => _}, detail) and detail["_tag"] in @contract["errors"][method] and
      is_binary(error) and error != ""
  end
end
