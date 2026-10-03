defmodule HalC2.Rpc do
  @moduledoc """
  Client RPCs an MC serves, by the method names of `packages/contracts/src/rpc.ts`.
  Run on the MC that owns the environment (`HalC2.Web.Socket` routes them).
  """

  # Methods that answer for the calling session (`handle/3`).
  @session_methods ~w(hal-c2.clients hal-c2.revokeClient hal-c2.revokeOtherClients)

  @doc "Methods the socket runs with its session, through `handle/3`."
  def session_methods, do: @session_methods

  @doc """
  Handles one RPC. An error is a message, or a map with a `"message"` plus the
  contract error's `"_tag"` and fields, which the client decodes.
  """
  @spec handle(String.t(), term) :: {:ok, term} | {:error, String.t() | map}
  def handle("orchestration." <> _ = method, payload),
    do: HalC2.Orchestration.handle(method, payload)

  def handle("projects.mutate", mutation), do: HalC2.Projects.mutate(mutation)
  def handle("server.getSettings", _input), do: {:ok, HalC2.Settings.settings()}

  # A client applies settings patches itself and writes the whole document back
  # with the version it read (see `HalC2.Settings`).
  def handle("hal-c2.readSettings", _input) do
    {settings, version} = HalC2.Settings.get()
    {:ok, %{"settings" => settings, "version" => version}}
  end

  def handle("hal-c2.writeSettings", %{"settings" => %{} = settings, "version" => version}) do
    with :ok <- HalC2.Settings.validate(settings),
         {:ok, version} <- HalC2.Settings.put(settings, version) do
      {:ok, %{"version" => version}}
    else
      {:error, :stale} -> {:error, %{"_tag" => "StaleSettings", "message" => "settings changed"}}
      {:error, %{} = invalid} -> {:error, invalid}
    end
  end

  # One thread's entities at once, for a client that needs its projection without
  # subscribing (a socket holds one subscription per stream).
  def handle("hal-c2.threadRows", %{"threadId" => thread_id}) do
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))

    {:ok,
     %{
       "rows" =>
         for(
           {kind, id, entity} <- HalC2.StreamState.rows(state),
           do: [kind, id, HalC2.Web.Wire.entity(kind, entity)]
         ),
       "offset" => state.seq,
       "at" => state.updated_at
     }}
  end

  # Moving a thread to another machine of the cluster (`HalC2.ThreadMove`), and finding
  # one that moved.
  def handle("hal-c2.moveThread", %{"threadId" => id, "machine" => machine} = input),
    do:
      HalC2.ThreadMove.move(id, machine,
        project: input["projectId"],
        confirmed: input["confirmed"] == true
      )

  def handle("hal-c2.moveDestinations", %{"threadId" => id}),
    do: HalC2.ThreadMove.destinations(id)

  def handle("hal-c2.locateThread", %{"threadId" => id}), do: HalC2.ThreadMove.locate(id)

  # Settings → Connections over the socket: the twins of `/api/auth/pairing-token` and
  # `/api/auth/pairing-links*`, with the HTTP routes' bodies and replies.
  def handle("hal-c2.createPairingLink", input),
    do: HalC2.Auth.create_pairing_link(Map.take(input, ~w(label scopes)))

  def handle("hal-c2.pairingLinks", _input), do: {:ok, HalC2.Auth.pairing_links()}

  def handle("hal-c2.revokePairingLink", %{"id" => id}),
    do: {:ok, %{"revoked" => HalC2.Auth.revoke_pairing_link(id)}}

  def handle("hal-c2.revokePairingLink", _input), do: {:error, "a pairing link id is required"}

  def handle(method, payload) when method in @session_methods, do: handle(method, payload, nil)

  def handle("server.updateServer", input), do: HalC2.Upgrade.update(input)

  def handle("server.acceptAcpRegistryUrlAuth", input), do: HalC2.Acp.UrlAuth.accept(input)

  def handle("provider.uploadFeedback", input),
    do: HalC2.Orchestration.handle("provider.uploadFeedback", input)

  def handle("filesystem.browse", input), do: HalC2.Projects.browse(input)
  def handle("shell.openInEditor", input), do: HalC2.Editors.open(input)
  def handle("server.discoverSourceControl", input), do: HalC2.SourceControl.discover(input)
  def handle("sourceControl.lookupRepository", input), do: HalC2.SourceControl.lookup(input)
  def handle("sourceControl.cloneRepository", input), do: HalC2.SourceControl.clone(input)
  def handle("sourceControl.publishRepository", input), do: HalC2.SourceControl.publish(input)
  def handle("projectClone.start", input), do: HalC2.ProjectClones.start(input)
  def handle("projectClone.retry", input), do: HalC2.ProjectClones.retry(input)
  def handle("projectClone.cancel", input), do: HalC2.ProjectClones.cancel(input)
  def handle("server.getProcessDiagnostics", input), do: HalC2.Diagnostics.processes(input)
  def handle("server.signalProcess", input), do: HalC2.Diagnostics.signal(input)
  def handle("server.getTraceDiagnostics", input), do: HalC2.Diagnostics.traces(input)
  def handle("server.getHostResources", input), do: HalC2.Diagnostics.host(input)
  def handle("server.getProcessResourceHistory", input), do: HalC2.Diagnostics.history(input)

  def handle("server.getResourceTelemetryHistory", input),
    do: HalC2.Diagnostics.telemetry_history(input)

  def handle("server.retryResourceTelemetry", input), do: HalC2.Diagnostics.retry(input)
  def handle("server.getBackgroundPolicy", _input), do: {:ok, HalC2.BackgroundPolicy.snapshot()}

  def handle("server.reportHostPowerState", snapshot) do
    :ok = HalC2.BackgroundPolicy.report_host_power(snapshot)
    {:ok, nil}
  end

  def handle("server.getUsageSummary", input), do: HalC2.Usage.summary(input)
  def handle("server.refreshUsageRates", input), do: HalC2.Usage.refresh_rates(input)
  def handle("preview.open", input), do: HalC2.Preview.open(input)
  def handle("preview.navigate", input), do: HalC2.Preview.navigate(input)
  def handle("preview.reportStatus", input), do: HalC2.Preview.report_status(input)
  def handle("preview.resize", input), do: HalC2.Preview.resize(input)
  def handle("preview.refresh", input), do: HalC2.Preview.refresh(input)
  def handle("preview.close", input), do: HalC2.Preview.close(input)
  def handle("preview.list", input), do: HalC2.Preview.list(input)

  def handle("previewAutomation.respond", input) do
    :ok = HalC2.PreviewAutomation.respond(input)
    {:ok, nil}
  end

  def handle("previewAutomation.focusHost", input) do
    :ok = HalC2.PreviewAutomation.focus_host(input)
    {:ok, nil}
  end

  def handle("device.list", input), do: HalC2.Devices.list(input)
  def handle("device.configure", input), do: HalC2.Devices.configure(input)
  def handle("device.testHost", input), do: HalC2.Devices.test_host(input)
  def handle("device.open", input), do: HalC2.Devices.open(input)
  def handle("device.close", input), do: HalC2.Devices.close(input)
  def handle("device.shutdown", input), do: HalC2.Devices.shutdown(input)
  def handle("device.detail", input), do: HalC2.Devices.detail(input)
  def handle("device.action", input), do: HalC2.Devices.action(input)
  def handle("scheduledTasks.list", input), do: HalC2.ScheduledTasks.list(input)
  def handle("scheduledTasks.upsert", input), do: HalC2.ScheduledTasks.upsert(input)
  def handle("scheduledTasks.delete", input), do: HalC2.ScheduledTasks.delete(input)
  def handle("scheduledTasks.setEnabled", input), do: HalC2.ScheduledTasks.set_enabled(input)
  def handle("scheduledTasks.runNow", input), do: HalC2.ScheduledTasks.run_now(input)
  def handle("server.refreshProviders", input), do: HalC2.Environment.refresh_providers(input)
  def handle("server.updateProvider", input), do: HalC2.ProviderUpdates.update(input)

  def handle("provider.consumeResetCredit", input),
    do: HalC2.ProviderUsageLimits.consume_reset_credit(input)

  def handle("hal-c2.upsertKeybinding", input), do: HalC2.Keybindings.upsert(input)
  def handle("hal-c2.removeKeybinding", input), do: HalC2.Keybindings.remove(input)
  # The contract names take the same payload; the client adapter resolves `rules`.
  def handle("server.upsertKeybinding", input), do: HalC2.Keybindings.upsert(input)
  def handle("server.removeKeybinding", input), do: HalC2.Keybindings.remove(input)
  def handle("projects.searchEntries", input), do: HalC2.Workspace.search_entries(input)
  def handle("attachments.createUploadUrl", input), do: HalC2.Attachments.create_upload_url(input)
  def handle("attachments.delete", input), do: HalC2.Attachments.delete(input)
  def handle("assets.createUrl", input), do: HalC2.Attachments.create_url(input)
  def handle("worktreeSetup.cancel", input), do: HalC2.WorktreeSetup.cancel(input)
  def handle("assets.persistChatAttachments", input), do: HalC2.Attachments.persist(input)
  def handle("projects.listEntries", input), do: HalC2.Workspace.list_entries(input)
  def handle("projects.readFile", input), do: HalC2.Workspace.read_file(input)
  def handle("projects.writeFile", input), do: HalC2.Workspace.write_file(input)
  def handle("projects.searchContents", input), do: HalC2.Workspace.search_contents(input)
  def handle("server.searchAcpRegistry", input), do: HalC2.Acp.Catalog.search(input)
  def handle("server.prepareAcpRegistryAgent", input), do: HalC2.Acp.Catalog.prepare(input)

  def handle("server.uninstallAcpRegistryManagedBinary", input),
    do: HalC2.Acp.Catalog.uninstall(input)

  def handle("server.listAcpRegistrySessions", input), do: HalC2.Acp.Sessions.list(input)
  def handle("server.importAcpRegistrySession", input), do: HalC2.Acp.Sessions.import(input)
  def handle("server.deleteAcpRegistrySession", input), do: HalC2.Acp.Sessions.delete(input)
  def handle("server.listAcpRegistryProviders", input), do: HalC2.Acp.Sessions.providers(input)
  def handle("server.setAcpRegistryProvider", input), do: HalC2.Acp.Sessions.set_provider(input)

  def handle("server.disableAcpRegistryProvider", input),
    do: HalC2.Acp.Sessions.disable_provider(input)

  def handle("server.logoutAcpRegistry", input), do: HalC2.Acp.Sessions.logout(input)
  def handle("provider.auth.start", input), do: HalC2.ProviderAuth.start(input)
  def handle("provider.auth.respond", input), do: HalC2.ProviderAuth.respond(input)
  def handle("provider.auth.cancel", input), do: HalC2.ProviderAuth.cancel(input)
  def handle("provider.auth.logout", input), do: HalC2.ProviderAuth.logout(input)
  def handle("provider.auth.complete", input), do: HalC2.ProviderAuth.complete(input)
  def handle("provider.install.start", input), do: HalC2.Acp.Antigravity.Installation.start(input)

  def handle("provider.install.cancel", input),
    do: HalC2.Acp.Antigravity.Installation.cancel(input)

  def handle("provider.install.remove", input),
    do: HalC2.Acp.Antigravity.Installation.remove(input)

  def handle("agentSessions.scan", input), do: HalC2.AgentSessions.scan(input)
  def handle("agentSessions.import", input), do: HalC2.AgentSessions.import_project(input)
  def handle("review.getDiffPreview", input), do: HalC2.Review.diff_preview(input)
  def handle("review.getDiffFileContents", input), do: HalC2.Review.file_contents(input)
  def handle("pullRequests." <> method, input), do: HalC2.PullRequests.handle(method, input)
  def handle("plugins." <> method, input), do: HalC2.Plugins.handle(method, input)
  def handle("git.resolvePullRequest", input), do: HalC2.PullRequests.Checkout.resolve(input)

  def handle("git.preparePullRequestThread", input),
    do: HalC2.PullRequests.Checkout.prepare(input)

  def handle("vcs.refreshStatus", input), do: HalC2.Vcs.refresh_status(input)
  def handle("vcs.listRefs", input), do: HalC2.Vcs.list_refs(input)
  def handle("vcs.switchRef", input), do: HalC2.Vcs.switch_ref(input)
  def handle("vcs.createRef", input), do: HalC2.Vcs.create_ref(input)
  def handle("vcs.init", input), do: HalC2.Vcs.init(input)
  def handle("vcs.pull", input), do: HalC2.Vcs.pull(input)
  def handle("vcs.createWorktree", input), do: HalC2.Vcs.create_worktree(input)
  def handle("vcs.removeWorktree", input), do: HalC2.Vcs.remove_worktree(input)
  def handle("terminal.open", input), do: HalC2.Terminal.open(input)
  def handle("terminal.write", input), do: HalC2.Terminal.write(input)
  def handle("terminal.resize", input), do: HalC2.Terminal.resize(input)
  def handle("terminal.clear", input), do: HalC2.Terminal.clear(input)
  def handle("terminal.restart", input), do: HalC2.Terminal.restart(input)
  def handle("terminal.close", input), do: HalC2.Terminal.close(input)
  def handle("terminal.list", input), do: HalC2.Terminal.list(input)
  def handle("hal-c2.environmentLinks", _), do: {:ok, HalC2.Links.list()}

  def handle("hal-c2.linkEnvironment", %{"pairingUrl" => url}) when is_binary(url),
    do: HalC2.Links.add(url)

  def handle("hal-c2.unlinkEnvironment", %{"environmentId" => id}) when is_binary(id) do
    with :ok <- HalC2.Links.remove(id), do: {:ok, nil}
  end

  def handle("cloud.getRelayClientStatus", _), do: {:ok, HalC2.Connect.RelayClient.resolve()}
  # This machine's cluster (`HalC2.Cluster`); a client joins it to another with an invite.
  def handle("cluster.status", _input), do: {:ok, HalC2.Cluster.status()}
  def handle("cluster.invite", input), do: cluster(HalC2.Cluster.invite(input || %{}))

  def handle("cluster.join", %{"link" => link}) when is_binary(link),
    do: cluster(HalC2.Cluster.join(link))

  def handle("cluster.remove", %{"id" => id}) when is_binary(id) do
    case HalC2.Cluster.remove(id) do
      :ok -> {:ok, HalC2.Cluster.status()}
      error -> cluster(error)
    end
  end

  def handle(method, _payload), do: {:error, "#{method} is not served by this MC yet"}

  @doc """
  Handles one of `session_methods/0` for `session`, the caller's session id (`nil` for
  the MC's own token, which is no paired client): the twins of `/api/auth/clients*`.
  """
  @spec handle(String.t(), term, String.t() | nil) :: {:ok, term} | {:error, map}
  def handle("hal-c2.clients", _input, session),
    do: {:ok, for(c <- HalC2.Auth.clients(), do: %{c | "current" => c["sessionId"] == session})}

  def handle("hal-c2.revokeClient", %{"sessionId" => id}, session) when id == session,
    do:
      {:error,
       %{
         "_tag" => "EnvironmentOperationForbiddenError",
         "code" => "operation_forbidden",
         "reason" => "current_session_revoke_not_allowed",
         "message" => "the current session cannot be revoked"
       }}

  def handle("hal-c2.revokeClient", %{"sessionId" => id}, _session),
    do: {:ok, %{"revoked" => HalC2.Auth.revoke_client(id)}}

  def handle("hal-c2.revokeOtherClients", _input, session),
    do: {:ok, %{"revokedCount" => HalC2.Auth.revoke_other_clients(session)}}

  def handle("hal-c2.revokeClient", _input, _session), do: {:error, "a sessionId is required"}

  defp cluster({:ok, _} = ok), do: ok

  defp cluster({:error, reason}),
    do:
      {:error,
       %{
         "_tag" => "ClusterError",
         "reason" => HalC2.Cluster.reason(reason),
         "message" => HalC2.Cluster.describe(reason)
       }}

  # Methods a session with `orchestration:read` alone may call, as the Node server's
  # `RPC_REQUIRED_SCOPES` declares them; every other method changes something.
  @reads ~w(
    orchestration.getWorkflowScript orchestration.getTurnDiff orchestration.getFullThreadDiff
    orchestration.searchThreads orchestration.getArchivedShellSnapshot
    orchestration.getThreadProjection server.getSettings hal-c2.readSettings hal-c2.threadRows
    hal-c2.environmentLinks
    server.getConfig server.probe server.discoverSourceControl server.getTraceDiagnostics
    server.getProcessDiagnostics server.getHostResources server.getProcessResourceHistory
    server.getResourceTelemetryHistory server.getUsageSummary server.refreshUsageRates
    server.reportClientActivity server.getBackgroundPolicy server.searchAcpRegistry
    server.listAcpRegistrySessions server.listAcpRegistryProviders scheduledTasks.list
    sourceControl.lookupRepository projects.listEntries projects.readFile
    projects.searchContents projects.searchEntries filesystem.browse agentSessions.scan
    assets.createUrl vcs.refreshStatus vcs.listRefs preview.list device.list device.detail
  )
  @pull_request_writes ~w(
    runAction update comment updateComment submitReview replyToThread setThreadResolution
    setReaction setFilesViewed requestReviewers setLabels
  )

  @doc "The session scope a client needs to call `method`."
  @spec required_scope(String.t()) :: String.t()
  def required_scope("terminal." <> _), do: "terminal:operate"
  def required_scope("review." <> _), do: "review:write"
  # A link hands this MC's clients whatever its pairing grants on the other side.
  def required_scope("hal-c2." <> m) when m in ~w(linkEnvironment unlinkEnvironment),
    do: "access:write"

  # The access list, as `/api/auth/*` guards it.
  def required_scope("hal-c2." <> m) when m in ~w(pairingLinks clients), do: "access:read"

  def required_scope("hal-c2." <> m)
      when m in ~w(createPairingLink revokePairingLink revokeClient revokeOtherClients),
      do: "access:write"

  def required_scope("cloud.getRelayClientStatus"), do: "relay:read"
  def required_scope("cloud." <> _), do: "relay:write"
  def required_scope("cluster.status"), do: "access:read"
  def required_scope("cluster." <> _), do: "access:write"

  def required_scope("pullRequests." <> method),
    do:
      if(method in @pull_request_writes, do: "orchestration:operate", else: "orchestration:read")

  def required_scope(method) when method in @reads, do: "orchestration:read"
  def required_scope(_method), do: "orchestration:operate"
end
