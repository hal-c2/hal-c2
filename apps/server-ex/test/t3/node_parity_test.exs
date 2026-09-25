defmodule T3.NodeParityTest do
  @moduledoc """
  Where this node stands against the Node server's wire protocol, one row per
  RPC method in `packages/contracts/src/rpc.ts` and per command tag in
  `OrchestrationV2Command` (`packages/contracts/src/orchestrationV2.ts`), the
  union `orchestration.dispatchCommand` takes.

  Both lists are parsed from the contracts on every run, so a new method or
  command fails here until it has a row. Rows are checked against the code:

    * `:aligned` names how a protocol 3 client reaches it (see
      `packages/client-runtime/src/v3/session.ts`):
      * `{:rpc, name, {module, fun}}`: `T3.Rpc.handle(name, _)` serves it through
        `module.fun`. `name` differs from the method when the client adapter
        speaks a node-only RPC (`t3.*`) for it.
      * `{:shape, type}`: a subscription shape `T3.Web.Socket` serves.
      * `{:socket, {module, fun}}`: the socket itself handles the RPC.
      * `{:adapter, why}`: the client adapter answers without the node.
    * `:backlog` names its gap in `features_backlog_test.exs`; the node must still
      refuse it.
    * `:na` says why the node never needs it; the node must not serve it.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @server_ex Path.expand("../..", __DIR__)

  @methods [
    {"server.upsertKeybinding", :aligned,
     {:rpc, "t3.upsertKeybinding", {T3.Keybindings, :upsert}}},
    {"server.removeKeybinding", :aligned,
     {:rpc, "t3.removeKeybinding", {T3.Keybindings, :remove}}},
    {"server.probe", :aligned,
     {:adapter, "answered by the client: a connected socket is a live node"}},
    {"server.getConfig", :aligned, {:shape, "config"}},
    {"server.refreshProviders", :aligned,
     {:rpc, "server.refreshProviders", {T3.Environment, :refresh_providers}}},
    {"server.updateProvider", :aligned,
     {:rpc, "server.updateProvider", {T3.ProviderUpdates, :update}}},
    {"provider.consumeResetCredit", :aligned,
     {:rpc, "provider.consumeResetCredit", {T3.ProviderUsageLimits, :consume_reset_credit}}},
    {"provider.auth.start", :aligned, {:rpc, "provider.auth.start", {T3.ProviderAuth, :start}}},
    {"provider.auth.respond", :aligned,
     {:rpc, "provider.auth.respond", {T3.ProviderAuth, :respond}}},
    {"provider.auth.complete", :aligned,
     {:rpc, "provider.auth.complete", {T3.ProviderAuth, :complete}}},
    {"provider.auth.cancel", :aligned,
     {:rpc, "provider.auth.cancel", {T3.ProviderAuth, :cancel}}},
    {"provider.auth.logout", :aligned,
     {:rpc, "provider.auth.logout", {T3.ProviderAuth, :logout}}},
    {"provider.auth.subscribe", :aligned, {:shape, "providerAuth"}},
    {"provider.install.start", :backlog, "provider-install"},
    {"provider.install.cancel", :backlog, "provider-install"},
    {"provider.install.subscribe", :backlog, "provider-install"},
    {"provider.install.remove", :backlog, "provider-install"},
    {"server.updateServer", :aligned, {:rpc, "server.updateServer", {T3.Upgrade, :update}}},
    {"server.updateServerWithProgress", :aligned, {:shape, "serverUpdate"}},
    {"server.commitDesktopUpdate", :na,
     "only after a desktop-app update; this node updates itself with a hot upgrade"},
    {"server.getSettings", :aligned, {:rpc, "server.getSettings", {T3.Settings, :settings}}},
    {"server.updateSettings", :aligned, {:rpc, "t3.writeSettings", {T3.Settings, :put}}},
    {"server.discoverSourceControl", :aligned,
     {:rpc, "server.discoverSourceControl", {T3.SourceControl, :discover}}},
    {"server.searchAcpRegistry", :aligned,
     {:rpc, "server.searchAcpRegistry", {T3.Acp.Catalog, :search}}},
    {"server.prepareAcpRegistryAgent", :aligned,
     {:rpc, "server.prepareAcpRegistryAgent", {T3.Acp.Catalog, :prepare}}},
    {"server.uninstallAcpRegistryManagedBinary", :aligned,
     {:rpc, "server.uninstallAcpRegistryManagedBinary", {T3.Acp.Catalog, :uninstall}}},
    {"server.acceptAcpRegistryUrlAuth", :aligned,
     {:rpc, "server.acceptAcpRegistryUrlAuth", {T3.Acp.UrlAuth, :accept}}},
    {"server.listAcpRegistrySessions", :aligned,
     {:rpc, "server.listAcpRegistrySessions", {T3.Acp.Sessions, :list}}},
    {"server.importAcpRegistrySession", :aligned,
     {:rpc, "server.importAcpRegistrySession", {T3.Acp.Sessions, :import}}},
    {"server.deleteAcpRegistrySession", :aligned,
     {:rpc, "server.deleteAcpRegistrySession", {T3.Acp.Sessions, :delete}}},
    {"server.listAcpRegistryProviders", :aligned,
     {:rpc, "server.listAcpRegistryProviders", {T3.Acp.Sessions, :providers}}},
    {"server.setAcpRegistryProvider", :aligned,
     {:rpc, "server.setAcpRegistryProvider", {T3.Acp.Sessions, :set_provider}}},
    {"server.disableAcpRegistryProvider", :aligned,
     {:rpc, "server.disableAcpRegistryProvider", {T3.Acp.Sessions, :disable_provider}}},
    {"server.logoutAcpRegistry", :aligned,
     {:rpc, "server.logoutAcpRegistry", {T3.Acp.Sessions, :logout}}},
    {"server.getTraceDiagnostics", :aligned,
     {:rpc, "server.getTraceDiagnostics", {T3.Diagnostics, :traces}}},
    {"server.getProcessDiagnostics", :aligned,
     {:rpc, "server.getProcessDiagnostics", {T3.Diagnostics, :processes}}},
    {"server.getHostResources", :aligned,
     {:rpc, "server.getHostResources", {T3.Diagnostics, :host}}},
    {"server.getProcessResourceHistory", :aligned,
     {:rpc, "server.getProcessResourceHistory", {T3.Diagnostics, :history}}},
    {"server.getResourceTelemetryHistory", :aligned,
     {:rpc, "server.getResourceTelemetryHistory", {T3.Diagnostics, :telemetry_history}}},
    {"server.retryResourceTelemetry", :aligned,
     {:rpc, "server.retryResourceTelemetry", {T3.Diagnostics, :retry}}},
    {"server.getUsageSummary", :aligned, {:rpc, "server.getUsageSummary", {T3.Usage, :summary}}},
    {"server.refreshUsageRates", :aligned,
     {:rpc, "server.refreshUsageRates", {T3.Usage, :refresh_rates}}},
    {"server.signalProcess", :aligned, {:rpc, "server.signalProcess", {T3.Diagnostics, :signal}}},
    {"cloud.getRelayClientStatus", :backlog, "t3-connect-relay-client"},
    {"cloud.installRelayClient", :backlog, "t3-connect-relay-client"},
    {"server.reportClientActivity", :aligned,
     {:socket, {T3.BackgroundPolicy, :report_client_activity}}},
    {"server.reportHostPowerState", :aligned,
     {:rpc, "server.reportHostPowerState", {T3.BackgroundPolicy, :report_host_power}}},
    {"server.getBackgroundPolicy", :aligned,
     {:rpc, "server.getBackgroundPolicy", {T3.BackgroundPolicy, :snapshot}}},
    {"pullRequests.list", :aligned, {:rpc, "pullRequests.list", {T3.PullRequests, :list}}},
    {"pullRequests.listStats", :aligned,
     {:rpc, "pullRequests.listStats", {T3.PullRequests, :list_stats}}},
    {"pullRequests.routing", :aligned,
     {:rpc, "pullRequests.routing", {T3.PullRequests, :routing}}},
    {"pullRequests.routingIdentity", :aligned,
     {:rpc, "pullRequests.routingIdentity", {T3.PullRequests, :routing_identity}}},
    {"pullRequests.summary", :aligned,
     {:rpc, "pullRequests.summary", {T3.PullRequests, :summary}}},
    {"pullRequests.stack", :aligned, {:rpc, "pullRequests.stack", {T3.PullRequests, :stack}}},
    {"pullRequests.linkedThreads", :aligned,
     {:rpc, "pullRequests.linkedThreads", {T3.PullRequests, :linked_threads}}},
    {"pullRequests.detail", :aligned, {:rpc, "pullRequests.detail", {T3.PullRequests, :detail}}},
    {"pullRequests.preview", :aligned,
     {:rpc, "pullRequests.preview", {T3.PullRequests, :preview}}},
    {"pullRequests.checks", :aligned, {:rpc, "pullRequests.checks", {T3.PullRequests, :checks}}},
    {"pullRequests.activity", :aligned,
     {:rpc, "pullRequests.activity", {T3.PullRequests, :activity}}},
    {"pullRequests.threadComments", :aligned,
     {:rpc, "pullRequests.threadComments", {T3.PullRequests, :thread_comments}}},
    {"pullRequests.diffFileContents", :aligned,
     {:rpc, "pullRequests.diffFileContents", {T3.PullRequests, :diff_file_contents}}},
    {"pullRequests.filesViewed", :aligned,
     {:rpc, "pullRequests.filesViewed", {T3.PullRequests, :files_viewed}}},
    {"pullRequests.setFilesViewed", :aligned,
     {:rpc, "pullRequests.setFilesViewed", {T3.PullRequests, :set_files_viewed}}},
    {"pullRequests.runAction", :aligned,
     {:rpc, "pullRequests.runAction", {T3.PullRequests, :run_action}}},
    {"pullRequests.update", :aligned, {:rpc, "pullRequests.update", {T3.PullRequests, :update}}},
    {"pullRequests.comment", :aligned,
     {:rpc, "pullRequests.comment", {T3.PullRequests, :comment}}},
    {"pullRequests.updateComment", :aligned,
     {:rpc, "pullRequests.updateComment", {T3.PullRequests, :update_comment}}},
    {"pullRequests.submitReview", :aligned,
     {:rpc, "pullRequests.submitReview", {T3.PullRequests, :submit_review}}},
    {"pullRequests.replyToThread", :aligned,
     {:rpc, "pullRequests.replyToThread", {T3.PullRequests, :reply_to_thread}}},
    {"pullRequests.setThreadResolution", :aligned,
     {:rpc, "pullRequests.setThreadResolution", {T3.PullRequests, :set_thread_resolution}}},
    {"pullRequests.setReaction", :aligned,
     {:rpc, "pullRequests.setReaction", {T3.PullRequests, :set_reaction}}},
    {"pullRequests.invalidate", :aligned,
     {:rpc, "pullRequests.invalidate", {T3.PullRequests, :invalidate}}},
    {"pullRequests.subscribeRefreshes", :aligned, {:shape, "pullRequestRefreshes"}},
    {"pullRequests.reviewerCandidates", :aligned,
     {:rpc, "pullRequests.reviewerCandidates", {T3.PullRequests, :reviewer_candidates}}},
    {"pullRequests.requestReviewers", :aligned,
     {:rpc, "pullRequests.requestReviewers", {T3.PullRequests, :request_reviewers}}},
    {"pullRequests.labelCandidates", :aligned,
     {:rpc, "pullRequests.labelCandidates", {T3.PullRequests, :label_candidates}}},
    {"pullRequests.setLabels", :aligned,
     {:rpc, "pullRequests.setLabels", {T3.PullRequests, :set_labels}}},
    {"sourceControl.lookupRepository", :aligned,
     {:rpc, "sourceControl.lookupRepository", {T3.SourceControl, :lookup}}},
    {"sourceControl.cloneRepository", :aligned,
     {:rpc, "sourceControl.cloneRepository", {T3.SourceControl, :clone}}},
    {"projectClone.start", :aligned, {:rpc, "projectClone.start", {T3.ProjectClones, :start}}},
    {"projectClone.cancel", :aligned, {:rpc, "projectClone.cancel", {T3.ProjectClones, :cancel}}},
    {"projectClone.retry", :aligned, {:rpc, "projectClone.retry", {T3.ProjectClones, :retry}}},
    {"subscribeProjectClones", :aligned, {:shape, "projectClones"}},
    {"sourceControl.publishRepository", :aligned,
     {:rpc, "sourceControl.publishRepository", {T3.SourceControl, :publish}}},
    {"projects.searchEntries", :aligned,
     {:rpc, "projects.searchEntries", {T3.Workspace, :search_entries}}},
    {"projects.searchContents", :aligned,
     {:rpc, "projects.searchContents", {T3.Workspace, :search_contents}}},
    {"projects.listEntries", :aligned,
     {:rpc, "projects.listEntries", {T3.Workspace, :list_entries}}},
    {"projects.readFile", :aligned, {:rpc, "projects.readFile", {T3.Workspace, :read_file}}},
    {"projects.writeFile", :aligned, {:rpc, "projects.writeFile", {T3.Workspace, :write_file}}},
    {"projects.mutate", :aligned, {:rpc, "projects.mutate", {T3.Projects, :mutate}}},
    {"shell.openInEditor", :aligned, {:rpc, "shell.openInEditor", {T3.Editors, :open}}},
    {"filesystem.browse", :aligned, {:rpc, "filesystem.browse", {T3.Projects, :browse}}},
    {"agentSessions.scan", :aligned, {:rpc, "agentSessions.scan", {T3.AgentSessions, :scan}}},
    {"agentSessions.import", :aligned,
     {:rpc, "agentSessions.import", {T3.AgentSessions, :import_project}}},
    {"assets.createUrl", :aligned, {:rpc, "assets.createUrl", {T3.Attachments, :create_url}}},
    {"assets.persistChatAttachments", :aligned,
     {:rpc, "assets.persistChatAttachments", {T3.Attachments, :persist}}},
    {"attachments.createUploadUrl", :aligned,
     {:rpc, "attachments.createUploadUrl", {T3.Attachments, :create_upload_url}}},
    {"attachments.delete", :aligned, {:rpc, "attachments.delete", {T3.Attachments, :delete}}},
    {"provider.uploadFeedback", :aligned,
     {:rpc, "provider.uploadFeedback", {T3.Orchestration, :handle}}},
    {"subscribeVcsStatus", :aligned, {:shape, "vcs"}},
    {"vcs.pull", :aligned, {:rpc, "vcs.pull", {T3.Vcs, :pull}}},
    {"vcs.refreshStatus", :aligned, {:rpc, "vcs.refreshStatus", {T3.Vcs, :refresh_status}}},
    {"subscribeWorktreeSetup", :aligned, {:shape, "worktreeSetup"}},
    {"worktreeSetup.cancel", :aligned,
     {:rpc, "worktreeSetup.cancel", {T3.WorktreeSetup, :cancel}}},
    {"git.runStackedAction", :aligned, {:shape, "gitAction"}},
    {"git.resolvePullRequest", :aligned,
     {:rpc, "git.resolvePullRequest", {T3.PullRequests.Checkout, :resolve}}},
    {"git.preparePullRequestThread", :aligned,
     {:rpc, "git.preparePullRequestThread", {T3.PullRequests.Checkout, :prepare}}},
    {"vcs.listRefs", :aligned, {:rpc, "vcs.listRefs", {T3.Vcs, :list_refs}}},
    {"vcs.createWorktree", :aligned, {:rpc, "vcs.createWorktree", {T3.Vcs, :create_worktree}}},
    {"vcs.removeWorktree", :aligned, {:rpc, "vcs.removeWorktree", {T3.Vcs, :remove_worktree}}},
    {"vcs.createRef", :aligned, {:rpc, "vcs.createRef", {T3.Vcs, :create_ref}}},
    {"vcs.switchRef", :aligned, {:rpc, "vcs.switchRef", {T3.Vcs, :switch_ref}}},
    {"vcs.init", :aligned, {:rpc, "vcs.init", {T3.Vcs, :init}}},
    {"review.getDiffPreview", :aligned,
     {:rpc, "review.getDiffPreview", {T3.Review, :diff_preview}}},
    {"review.getDiffFileContents", :aligned,
     {:rpc, "review.getDiffFileContents", {T3.Review, :file_contents}}},
    {"terminal.open", :aligned, {:rpc, "terminal.open", {T3.Terminal, :open}}},
    {"terminal.attach", :aligned, {:shape, "terminal"}},
    {"terminal.write", :aligned, {:rpc, "terminal.write", {T3.Terminal, :write}}},
    {"terminal.resize", :aligned, {:rpc, "terminal.resize", {T3.Terminal, :resize}}},
    {"terminal.clear", :aligned, {:rpc, "terminal.clear", {T3.Terminal, :clear}}},
    {"terminal.restart", :aligned, {:rpc, "terminal.restart", {T3.Terminal, :restart}}},
    {"terminal.close", :aligned, {:rpc, "terminal.close", {T3.Terminal, :close}}},
    {"terminal.list", :backlog, "terminal-list"},
    {"preview.open", :aligned, {:rpc, "preview.open", {T3.Preview, :open}}},
    {"preview.navigate", :aligned, {:rpc, "preview.navigate", {T3.Preview, :navigate}}},
    {"preview.resize", :aligned, {:rpc, "preview.resize", {T3.Preview, :resize}}},
    {"preview.refresh", :aligned, {:rpc, "preview.refresh", {T3.Preview, :refresh}}},
    {"preview.close", :aligned, {:rpc, "preview.close", {T3.Preview, :close}}},
    {"preview.list", :aligned, {:rpc, "preview.list", {T3.Preview, :list}}},
    {"preview.reportStatus", :aligned,
     {:rpc, "preview.reportStatus", {T3.Preview, :report_status}}},
    {"previewAutomation.connect", :aligned, {:shape, "previewAutomation"}},
    {"previewAutomation.respond", :aligned,
     {:rpc, "previewAutomation.respond", {T3.PreviewAutomation, :respond}}},
    {"previewAutomation.focusHost", :aligned,
     {:rpc, "previewAutomation.focusHost", {T3.PreviewAutomation, :focus_host}}},
    {"subscribePreviewEvents", :aligned, {:shape, "preview"}},
    {"subscribeDiscoveredLocalServers", :aligned, {:shape, "localServers"}},
    {"device.testHost", :aligned, {:rpc, "device.testHost", {T3.Devices, :test_host}}},
    {"device.list", :aligned, {:rpc, "device.list", {T3.Devices, :list}}},
    {"device.configure", :aligned, {:rpc, "device.configure", {T3.Devices, :configure}}},
    {"device.open", :aligned, {:rpc, "device.open", {T3.Devices, :open}}},
    {"device.close", :aligned, {:rpc, "device.close", {T3.Devices, :close}}},
    {"device.shutdown", :aligned, {:rpc, "device.shutdown", {T3.Devices, :shutdown}}},
    {"device.detail", :aligned, {:rpc, "device.detail", {T3.Devices, :detail}}},
    {"device.action", :aligned, {:rpc, "device.action", {T3.Devices, :action}}},
    {"subscribeDeviceState", :aligned, {:shape, "devices"}},
    {"orchestration.dispatchCommand", :aligned,
     {:rpc, "orchestration.dispatchCommand", {T3.Orchestration, :dispatch}}},
    {"orchestration.getTurnDiff", :aligned,
     {:rpc, "orchestration.getTurnDiff", {T3.Orchestration, :handle}}},
    {"orchestration.getFullThreadDiff", :aligned,
     {:rpc, "orchestration.getFullThreadDiff", {T3.Orchestration, :handle}}},
    {"orchestration.searchThreads", :aligned,
     {:rpc, "orchestration.searchThreads", {T3.Search, :threads}}},
    {"orchestration.getArchivedShellSnapshot", :aligned,
     {:rpc, "orchestration.getArchivedShellSnapshot", {T3.Shell, :rows}}},
    {"orchestration.getThreadProjection", :aligned,
     {:rpc, "t3.threadRows", {T3.Streams.Server, :state}}},
    {"orchestration.getWorkflowScript", :aligned,
     {:rpc, "orchestration.getWorkflowScript", {T3.WorkflowScripts, :read}}},
    {"orchestration.launchThread", :aligned,
     {:rpc, "orchestration.launchThread", {T3.Orchestration, :launch_thread}}},
    {"orchestration.subscribeArchivedShell", :na,
     "no client subscribes; archived threads come from getArchivedShellSnapshot"},
    {"orchestration.subscribeShell", :aligned, {:shape, "shell"}},
    {"orchestration.subscribeThread", :aligned, {:shape, "stream"}},
    {"subscribeTerminalEvents", :na, "protocol 3 clients attach with the terminal shape"},
    {"subscribeTerminalMetadata", :aligned, {:shape, "terminals"}},
    {"subscribeServerConfig", :aligned, {:shape, "config"}},
    {"subscribeServerLifecycle", :aligned, {:shape, "config"}},
    {"scheduledTasks.list", :aligned, {:rpc, "scheduledTasks.list", {T3.ScheduledTasks, :list}}},
    {"scheduledTasks.subscribe", :aligned, {:shape, "scheduledTasks"}},
    {"scheduledTasks.upsert", :aligned,
     {:rpc, "scheduledTasks.upsert", {T3.ScheduledTasks, :upsert}}},
    {"scheduledTasks.setEnabled", :aligned,
     {:rpc, "scheduledTasks.setEnabled", {T3.ScheduledTasks, :set_enabled}}},
    {"scheduledTasks.delete", :aligned,
     {:rpc, "scheduledTasks.delete", {T3.ScheduledTasks, :delete}}},
    {"scheduledTasks.runNow", :aligned,
     {:rpc, "scheduledTasks.runNow", {T3.ScheduledTasks, :run_now}}},
    {"subscribeAuthAccess", :aligned, {:shape, "authAccess"}},
    {"subscribeBackgroundPolicy", :aligned,
     {:adapter, "reads server.getBackgroundPolicy once, then holds"}},
    {"subscribeResourceTelemetry", :aligned, {:shape, "resourceTelemetry"}}
  ]

  @commands [
    {"thread.create", :aligned, :dispatch},
    {"thread.archive", :aligned, :thread_update},
    {"thread.unarchive", :aligned, :thread_update},
    {"thread.delete", :aligned, :thread_update},
    {"thread.settle", :aligned, :thread_update},
    {"thread.auto-settle", :aligned, :dispatch},
    {"thread.unsettle", :aligned, :thread_update},
    {"thread.snooze", :aligned, :thread_update},
    {"thread.unsnooze", :aligned, :thread_update},
    {"thread.pin", :aligned, :thread_update},
    {"thread.unpin", :aligned, :thread_update},
    {"thread.pin.reorder", :aligned, :thread_update},
    {"thread.active.reorder", :aligned, :thread_update},
    {"thread.visit", :aligned, :thread_update},
    {"thread.mark-unread", :aligned, :thread_update},
    {"thread.metadata.update", :aligned, :thread_update},
    {"thread.pull-request.link", :aligned, :thread_update},
    {"thread.pull-request.unlink", :aligned, :thread_update},
    {"thread.pull-request-link.sync", :aligned, :dispatch},
    {"thread.pull-request.sync", :aligned, :dispatch},
    {"thread.title.regeneration.complete", :na,
     "Node's title worker reports back; here thread.metadata.update regenerates in place"},
    {"thread.runtime-mode.set", :aligned, :thread_update},
    {"thread.interaction-mode.set", :aligned, :thread_update},
    {"thread.model-selection.set", :aligned, :thread_update},
    {"provider-session.detach", :aligned, :dispatch},
    {"message.dispatch", :aligned, :dispatch},
    {"prepared-run.release", :na, "Node's launch worker; runs start in-process here"},
    {"notification.delivery.accept", :na, "Node's notification worker"},
    {"prepared-run.progress", :na, "Node's launch worker; runs start in-process here"},
    {"prepared-run.fail", :na, "Node's launch worker; runs start in-process here"},
    {"run.interrupt", :aligned, :dispatch},
    {"queued-message.promote-to-steer", :aligned, :dispatch},
    {"queue.resume", :aligned, :dispatch},
    {"queued-run.reorder", :aligned, :dispatch},
    {"queued-run.cancel", :aligned, :dispatch},
    {"queued-run.edit", :aligned, :dispatch},
    {"runtime-request.respond", :aligned, :dispatch},
    {"thread.user-input.dismiss", :aligned, :dispatch},
    {"checkpoint.rollback", :aligned, :dispatch},
    {"thread.fork", :aligned, :dispatch},
    {"thread.merge_back", :aligned, :dispatch},
    {"delegated_task.request", :na, "agents delegate over MCP (T3.Orchestration.Delegation)"},
    {"delegated_task.wake-policy", :na, "agents delegate over MCP (T3.Orchestration.Delegation)"},
    {"delegated_task.completion-delivery.acknowledge", :na,
     "agents delegate over MCP (T3.Orchestration.Delegation)"},
    {"delegated_task.completion-delivery.dispose", :na,
     "agents delegate over MCP (T3.Orchestration.Delegation)"},
    {"thread.created.record", :na, "Node's thread-creation receipt; thread.create records here"},
    {"provider.switch", :aligned, :thread_update}
  ]

  # Node-only RPCs the adapter calls besides a row's own, and for which method.
  @node_only_helpers %{"t3.readSettings" => "server.updateSettings"}

  @statuses [:aligned, :backlog, :na]

  # --- contracts ------------------------------------------------------------------

  defp read(path), do: File.read!(Path.join(@root, path))

  defp method_table(source, name) do
    [_, body] = Regex.run(~r/export const #{name} = \{(.*?)\n\} as const/s, source)

    for [_, key, value] <- Regex.scan(~r/^\s+(\w+): "([^"]+)"/m, body),
        into: %{},
        do: {key, value}
  end

  defp method_keys do
    %{
      "WS_METHODS" => method_table(read("packages/contracts/src/rpc.ts"), "WS_METHODS"),
      "ORCHESTRATION_V2_WS_METHODS" =>
        method_table(
          read("packages/contracts/src/orchestrationV2.ts"),
          "ORCHESTRATION_V2_WS_METHODS"
        )
    }
  end

  # The methods the RPC group is made of (a WS_METHODS key without an `Rpc.make`
  # is a leftover the server never serves).
  defp contract_methods do
    keys = method_keys()

    for [_, table, key] <-
          Regex.scan(
            ~r/Rpc\.make\(\s*(WS_METHODS|ORCHESTRATION_V2_WS_METHODS)\.(\w+)/,
            read("packages/contracts/src/rpc.ts")
          ),
        do: Map.fetch!(keys[table], key)
  end

  defp contract_commands do
    source = read("packages/contracts/src/orchestrationV2.ts")

    [_, union] =
      Regex.run(~r/export const OrchestrationV2Command = Schema\.Union\(\[(.*?)\n\]\);/s, source)

    for [_, tag] <- Regex.scan(~r/^    type: Schema\.Literal\("([^"]+)"\)/m, union), do: tag
  end

  # Methods the protocol 3 client adapter references by name.
  defp adapter_methods do
    keys = method_keys()

    for [_, table, key] <-
          Regex.scan(
            ~r/(WS_METHODS|ORCHESTRATION_V2_WS_METHODS)\.(\w+)/,
            read("packages/client-runtime/src/v3/session.ts")
          ),
        value = keys[table][key],
        into: MapSet.new(),
        do: value
  end

  # --- node -------------------------------------------------------------------------

  defp lib(path), do: File.read!(Path.join([@server_ex, "lib", path]))

  # `%{name => clause source}` for every `def handle("name", ...)` in a module.
  defp handle_clauses(path) do
    for part <- String.split(lib(path), ~r/\n(?=  (?:def |defp |@|#))/),
        [_, name] <- [Regex.run(~r/\A\s*def handle\("([^"]+)"[,)]/, part)],
        reduce: %{} do
      acc -> Map.update(acc, name, part, &(&1 <> part))
    end
  end

  defp pull_request_methods do
    for [_, suffix, fun] <- Regex.scan(~r/^\s+"(\w+)" => :(\w+)/m, lib("t3/pull_requests.ex")),
        into: %{},
        do: {"pullRequests." <> suffix, fun}
  end

  defp rpc_clauses, do: handle_clauses("t3/rpc.ex")
  defp orchestration_clauses, do: handle_clauses("t3/orchestration.ex")

  defp served do
    MapSet.new(
      Map.keys(rpc_clauses()) ++
        Map.keys(orchestration_clauses()) ++ Map.keys(pull_request_methods())
    )
  end

  defp dispatch_clauses do
    for [_, tag] <-
          Regex.scan(~r/def dispatch\(\s*%\{"type" => "([^"]+)"/, lib("t3/orchestration.ex")),
        into: MapSet.new(),
        do: tag
  end

  defp thread_updates do
    [_, list] = Regex.run(~r/@thread_updates ~w\((.*?)\)/s, lib("t3/orchestration.ex"))
    list |> String.split() |> MapSet.new()
  end

  defp exported?(module, fun) do
    Code.ensure_loaded?(module) and Keyword.has_key?(module.__info__(:functions), fun)
  end

  # Whether the clause serving `name` goes through `module.fun`.
  defp handled_by?("pullRequests." <> _ = name, T3.PullRequests, fun),
    do: pull_request_methods()[name] == Atom.to_string(fun)

  defp handled_by?(name, module, fun) do
    clauses =
      if String.starts_with?(name, "orchestration."),
        do: orchestration_clauses(),
        else: rpc_clauses()

    body = Map.get(clauses, name, "")
    own = module in [T3.Rpc, T3.Orchestration]

    String.contains?(body, "#{inspect(module)}.#{fun}(") or
      (own and (fun == :handle or String.contains?(body, "#{fun}(")))
  end

  defp by_status(rows, status), do: for({name, ^status, _} <- rows, do: name)

  defp rows_for(rows, name), do: Enum.find(rows, &(elem(&1, 0) == name))

  defp client_sources do
    for dir <- ~w(apps/web/src apps/mobile/src apps/tui/src packages/client-runtime/src),
        path <- Path.wildcard(Path.join([@root, dir, "**", "*.{ts,tsx}"])),
        not String.contains?(path, ".test."),
        do: path
  end

  # --- the table is honest --------------------------------------------------------

  describe "RPC methods" do
    test "every contract method has exactly one row, and no row is stale" do
      names = Enum.map(@methods, &elem(&1, 0))
      assert names -- Enum.uniq(names) == []

      contract = contract_methods()
      assert length(contract) == length(Enum.uniq(contract))
      assert contract -- names == [], "methods without a row"
      assert names -- contract == [], "rows for methods the contracts no longer have"
      assert Enum.all?(@methods, fn {_, status, _} -> status in @statuses end)
    end

    test "every aligned method is reached the way its row says" do
      served = served()
      adapter = adapter_methods()
      protocol = lib("t3/web/protocol.ex")
      session = read("packages/client-runtime/src/v3/session.ts")

      for {method, :aligned, via} <- @methods do
        assert method in adapter, "#{method}: the protocol 3 client adapter never names it"

        case via do
          {:rpc, name, {module, fun}} ->
            assert name in served, "#{method}: the node has no #{name} clause"
            assert exported?(module, fun), "#{method}: #{inspect(module)}.#{fun} is not exported"
            assert handled_by?(name, module, fun), "#{method}: #{name} does not call #{fun}"

            if name != method,
              do: assert(session =~ ~s("#{name}"), "#{method}: the adapter never sends #{name}")

          {:shape, type} ->
            assert protocol =~ ~r/decode_shape\(\s*%\{"type" => "#{type}"/,
                   "#{method}: the node has no #{type} shape"

            assert session =~ ~s(type: "#{type}"), "#{method}: the adapter never opens #{type}"

          {:socket, {module, fun}} ->
            assert lib("t3/web/socket.ex") =~ ~s(method == "#{method}")
            assert exported?(module, fun)

          {:adapter, why} ->
            assert is_binary(why) and why != ""
        end
      end
    end

    test "a backlog method names its gap, and the node still refuses it" do
      backlog = File.read!(Path.join(__DIR__, "features_backlog_test.exs"))
      served = served()

      for {method, :backlog, gap} <- @methods do
        assert backlog =~ ~s(id: "#{gap}"), "#{method}: no backlog gap #{gap}"
        assert backlog =~ ~s("RPC #{method}"), "#{method}: gap #{gap} does not list it"
        refute method in served, "#{method} is served; mark it aligned"

        assert T3.Rpc.handle(method, %{}) ==
                 {:error, "#{method} is not served by this node yet"}
      end
    end

    test "a not-applicable method says why, and nothing on the node serves it" do
      served = served()

      for {method, :na, why} <- @methods do
        assert is_binary(why) and why != ""
        refute method in served, "#{method} is served; mark it aligned"
      end
    end

    test "every node-only RPC stands in for a contract method" do
      contract = MapSet.new(contract_methods())
      node_only = MapSet.difference(served(), contract)
      stand_ins = for {_, :aligned, {:rpc, name, _}} <- @methods, into: MapSet.new(), do: name
      helpers = MapSet.new(Map.keys(@node_only_helpers))
      assert MapSet.difference(node_only, MapSet.union(stand_ins, helpers)) == MapSet.new()

      session = read("packages/client-runtime/src/v3/session.ts")

      for {helper, method} <- @node_only_helpers do
        assert helper in served()
        assert session =~ ~s("#{helper}")
        assert {^method, :aligned, _} = rows_for(@methods, method)
      end
    end
  end

  describe "orchestration commands" do
    test "every OrchestrationV2Command tag has exactly one row, and no row is stale" do
      tags = Enum.map(@commands, &elem(&1, 0))
      assert tags -- Enum.uniq(tags) == []
      contract = contract_commands()
      assert contract != []
      assert contract -- tags == [], "commands without a row"
      assert tags -- contract == [], "rows for commands the contracts no longer have"
      assert Enum.all?(@commands, fn {_, status, _} -> status in @statuses end)
    end

    test "every aligned command has its dispatch clause" do
      clauses = dispatch_clauses()
      updates = thread_updates()

      for {tag, :aligned, via} <- @commands do
        case via do
          :dispatch -> assert tag in clauses, "#{tag}: no dispatch clause"
          :thread_update -> assert tag in updates, "#{tag}: not in @thread_updates"
        end
      end

      # Every clause the node has is in the table as aligned.
      aligned = MapSet.new(by_status(@commands, :aligned))
      assert MapSet.subset?(MapSet.union(clauses, updates), aligned)
    end

    test "a not-applicable command is internal to the Node server: no client sends it" do
      sources = Enum.map(client_sources(), &File.read!/1)

      for {tag, :na, why} <- @commands do
        assert is_binary(why) and why != ""

        assert T3.Orchestration.dispatch(%{"type" => tag}) ==
                 {:error, "#{tag} is not supported by this node yet"}

        refute Enum.any?(sources, &String.contains?(&1, ~s("#{tag}"))),
               "a client sends #{tag}; it needs a handler"
      end
    end
  end

  # --- headline capabilities ------------------------------------------------------

  describe "headline capabilities" do
    test "Given a client creates a thread and sends a message, then both commands dispatch on the node" do
      assert {"orchestration.dispatchCommand", :aligned, {:rpc, _, {T3.Orchestration, :dispatch}}} =
               rows_for(@methods, "orchestration.dispatchCommand")

      assert {_, :aligned, _} = rows_for(@commands, "thread.create")
      assert {_, :aligned, _} = rows_for(@commands, "message.dispatch")
      assert {_, :aligned, _} = rows_for(@methods, "orchestration.launchThread")
    end

    test "Given a client resumes a thread from an offset, then the stream shape takes the offset" do
      assert {_, :aligned, {:shape, "stream"}} =
               rows_for(@methods, "orchestration.subscribeThread")

      assert {_, :aligned, {:shape, "shell"}} = rows_for(@methods, "orchestration.subscribeShell")
      assert lib("t3/web/protocol.ex") =~ ~s("offset")
      assert exported?(T3.Streams, :subscribe)
    end

    test "Given a device pairs, then the node serves the auth routes the client runtime calls" do
      router = lib("t3/web/router.ex")

      for route <-
            ~w(/oauth/token /api/auth/session /api/auth/websocket-ticket /api/auth/pairing-token
               /api/auth/pairing-links /api/auth/pairing-links/revoke /api/auth/clients
               /api/auth/clients/revoke /api/auth/clients/revoke-others),
          do: assert(router =~ ~s("#{route}"), "no #{route} route")

      assert {_, :aligned, {:shape, "authAccess"}} = rows_for(@methods, "subscribeAuthAccess")
    end

    test "Given git actions from the composer, then stacked actions stream and vcs RPCs are served" do
      assert {_, :aligned, {:shape, "gitAction"}} = rows_for(@methods, "git.runStackedAction")
      assert {_, :aligned, {:shape, "vcs"}} = rows_for(@methods, "subscribeVcsStatus")

      for method <- ~w(vcs.pull vcs.switchRef vcs.createRef vcs.createWorktree vcs.removeWorktree),
          do:
            assert({^method, :aligned, {:rpc, ^method, {T3.Vcs, _}}} = rows_for(@methods, method))
    end

    test "Given a provider sign-in, then its steps are RPCs and its progress is the providerAuth shape" do
      for method <- ~w(provider.auth.start provider.auth.respond provider.auth.complete
                       provider.auth.cancel provider.auth.logout),
          do:
            assert(
              {^method, :aligned, {:rpc, ^method, {T3.ProviderAuth, _}}} =
                rows_for(@methods, method)
            )

      assert {_, :aligned, {:shape, "providerAuth"}} =
               rows_for(@methods, "provider.auth.subscribe")
    end

    test "Given a turn's checkpoint, then diffs and rollback are served" do
      assert {_, :aligned, _} = rows_for(@commands, "checkpoint.rollback")
      assert {_, :aligned, _} = rows_for(@methods, "orchestration.getTurnDiff")
      assert {_, :aligned, _} = rows_for(@methods, "orchestration.getFullThreadDiff")
      assert exported?(T3.Checkpoint, :turn_diff)
    end

    test "Given a node joins a cluster, then one socket routes each environment to its node" do
      # Clustering has no Node counterpart; the socket picks the node per RPC.
      assert exported?(T3.Cluster, :invite)
      assert exported?(T3.Cluster, :join)
      assert exported?(T3.Shell, :environments)
      assert lib("t3/web/socket.ex") =~ "node_for(environment)"
    end
  end
end
