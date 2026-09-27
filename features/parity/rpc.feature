# Sources:
#   packages/contracts/src/rpc.ts (WS_METHODS, every Rpc.make)
#   packages/contracts/src/orchestrationV2.ts (ORCHESTRATION_V2_WS_METHODS)
#   apps/server-ex/test/hal_c2/node_parity_test.exs (@methods: status and how each method is reached)
#   apps/server-ex/lib/hal_c2/rpc.ex, apps/server-ex/lib/hal_c2/orchestration.ex, apps/server-ex/lib/hal_c2/pull_requests.ex
#   apps/server-ex/lib/hal_c2/web/protocol.ex (shapes)
#   packages/client-runtime/src/v3/clusterSocket.ts (protocol 3 client adapter)
#   apps/server-ex/lib/hal_c2/acp/antigravity/installation.ex (provider.install.*), apps/server-ex/lib/hal_c2/connect/relay_client.ex (cloud.*)
#   Counts: 168 contract methods; 165 aligned, 3 dropped.
#   WS_METHODS also names projects.add, projects.list and projects.remove with no Rpc.make
#   behind them; neither server routes them, so they are recorded as dropped names.
#   "via" says how a protocol 3 client reaches the method: an rpc frame (under the node's
#   own name when it differs), a subscription shape, a socket frame, or the client adapter.

Feature: RPC parity with the TypeScript server
  Every method in the RPC contract is either answered by the node, waiting in the backlog,
  or dropped with a reason. A protocol 3 client reaches each one without knowing which server
  it talks to.

  Background:
    Given a node
    And a paired protocol 3 client

  @node
  Scenario Outline: The node answers <method>
    When the client calls <method> through its <via>
    Then the node answers with the contract's response shape for <method>

    Examples: 165 aligned methods
      | method                                   | domain            | via                                                                       |
      | server.upsertKeybinding                  | server            | rpc as hal-c2.upsertKeybinding                                                |
      | server.removeKeybinding                  | server            | rpc as hal-c2.removeKeybinding                                                |
      | server.probe                             | server            | client adapter: answered by the client: a connected socket is a live node |
      | server.getConfig                         | server            | shape config                                                              |
      | server.refreshProviders                  | server            | rpc                                                                       |
      | server.updateProvider                    | server            | rpc                                                                       |
      | provider.consumeResetCredit              | provider          | rpc                                                                       |
      | provider.auth.start                      | provider          | rpc                                                                       |
      | provider.auth.respond                    | provider          | rpc                                                                       |
      | provider.auth.complete                   | provider          | rpc                                                                       |
      | provider.auth.cancel                     | provider          | rpc                                                                       |
      | provider.auth.logout                     | provider          | rpc                                                                       |
      | provider.auth.subscribe                  | provider          | shape providerAuth                                                        |
      | provider.install.start                   | provider          | rpc                                                                       |
      | provider.install.cancel                  | provider          | rpc                                                                       |
      | provider.install.remove                  | provider          | rpc                                                                       |
      | provider.install.subscribe               | provider          | shape providerInstall                                                     |
      | server.updateServer                      | server            | rpc                                                                       |
      | server.updateServerWithProgress          | server            | shape serverUpdate                                                        |
      | server.getSettings                       | server            | rpc                                                                       |
      | server.updateSettings                    | server            | rpc as hal-c2.writeSettings                                                   |
      | server.discoverSourceControl             | server            | rpc                                                                       |
      | server.searchAcpRegistry                 | server            | rpc                                                                       |
      | server.prepareAcpRegistryAgent           | server            | rpc                                                                       |
      | server.uninstallAcpRegistryManagedBinary | server            | rpc                                                                       |
      | server.acceptAcpRegistryUrlAuth          | server            | rpc                                                                       |
      | server.listAcpRegistrySessions           | server            | rpc                                                                       |
      | server.importAcpRegistrySession          | server            | rpc                                                                       |
      | server.deleteAcpRegistrySession          | server            | rpc                                                                       |
      | server.listAcpRegistryProviders          | server            | rpc                                                                       |
      | server.setAcpRegistryProvider            | server            | rpc                                                                       |
      | server.disableAcpRegistryProvider        | server            | rpc                                                                       |
      | server.logoutAcpRegistry                 | server            | rpc                                                                       |
      | server.getTraceDiagnostics               | server            | rpc                                                                       |
      | server.getProcessDiagnostics             | server            | rpc                                                                       |
      | server.getHostResources                  | server            | rpc                                                                       |
      | server.getProcessResourceHistory         | server            | rpc                                                                       |
      | server.getResourceTelemetryHistory       | server            | rpc                                                                       |
      | server.retryResourceTelemetry            | server            | rpc                                                                       |
      | server.getUsageSummary                   | server            | rpc                                                                       |
      | server.refreshUsageRates                 | server            | rpc                                                                       |
      | server.signalProcess                     | server            | rpc                                                                       |
      | server.reportClientActivity              | server            | socket frame                                                              |
      | server.reportHostPowerState              | server            | rpc                                                                       |
      | server.getBackgroundPolicy               | server            | rpc                                                                       |
      | pullRequests.list                        | pullRequests      | rpc                                                                       |
      | pullRequests.listStats                   | pullRequests      | rpc                                                                       |
      | pullRequests.routing                     | pullRequests      | rpc                                                                       |
      | pullRequests.routingIdentity             | pullRequests      | rpc                                                                       |
      | pullRequests.summary                     | pullRequests      | rpc                                                                       |
      | pullRequests.stack                       | pullRequests      | rpc                                                                       |
      | pullRequests.linkedThreads               | pullRequests      | rpc                                                                       |
      | pullRequests.detail                      | pullRequests      | rpc                                                                       |
      | pullRequests.preview                     | pullRequests      | rpc                                                                       |
      | pullRequests.checks                      | pullRequests      | rpc                                                                       |
      | pullRequests.activity                    | pullRequests      | rpc                                                                       |
      | pullRequests.threadComments              | pullRequests      | rpc                                                                       |
      | pullRequests.diffFileContents            | pullRequests      | rpc                                                                       |
      | pullRequests.filesViewed                 | pullRequests      | rpc                                                                       |
      | pullRequests.setFilesViewed              | pullRequests      | rpc                                                                       |
      | pullRequests.runAction                   | pullRequests      | rpc                                                                       |
      | pullRequests.update                      | pullRequests      | rpc                                                                       |
      | pullRequests.comment                     | pullRequests      | rpc                                                                       |
      | pullRequests.updateComment               | pullRequests      | rpc                                                                       |
      | pullRequests.submitReview                | pullRequests      | rpc                                                                       |
      | pullRequests.replyToThread               | pullRequests      | rpc                                                                       |
      | pullRequests.setThreadResolution         | pullRequests      | rpc                                                                       |
      | pullRequests.setReaction                 | pullRequests      | rpc                                                                       |
      | pullRequests.invalidate                  | pullRequests      | rpc                                                                       |
      | pullRequests.subscribeRefreshes          | pullRequests      | shape pullRequestRefreshes                                                |
      | pullRequests.reviewerCandidates          | pullRequests      | rpc                                                                       |
      | pullRequests.requestReviewers            | pullRequests      | rpc                                                                       |
      | pullRequests.labelCandidates             | pullRequests      | rpc                                                                       |
      | pullRequests.setLabels                   | pullRequests      | rpc                                                                       |
      | sourceControl.lookupRepository           | sourceControl     | rpc                                                                       |
      | sourceControl.cloneRepository            | sourceControl     | rpc                                                                       |
      | projectClone.start                       | projectClone      | rpc                                                                       |
      | projectClone.cancel                      | projectClone      | rpc                                                                       |
      | projectClone.retry                       | projectClone      | rpc                                                                       |
      | subscribeProjectClones                   | projectClone      | shape projectClones                                                       |
      | sourceControl.publishRepository          | sourceControl     | rpc                                                                       |
      | projects.searchEntries                   | projects          | rpc                                                                       |
      | projects.searchContents                  | projects          | rpc                                                                       |
      | projects.listEntries                     | projects          | rpc                                                                       |
      | projects.readFile                        | projects          | rpc                                                                       |
      | projects.writeFile                       | projects          | rpc                                                                       |
      | projects.mutate                          | projects          | rpc                                                                       |
      | shell.openInEditor                       | shell             | rpc                                                                       |
      | filesystem.browse                        | filesystem        | rpc                                                                       |
      | agentSessions.scan                       | agentSessions     | rpc                                                                       |
      | agentSessions.import                     | agentSessions     | rpc                                                                       |
      | assets.createUrl                         | assets            | rpc                                                                       |
      | assets.persistChatAttachments            | assets            | rpc                                                                       |
      | attachments.createUploadUrl              | attachments       | rpc                                                                       |
      | attachments.delete                       | attachments       | rpc                                                                       |
      | provider.uploadFeedback                  | provider          | rpc                                                                       |
      | subscribeVcsStatus                       | vcs               | shape vcs                                                                 |
      | vcs.pull                                 | vcs               | rpc                                                                       |
      | vcs.refreshStatus                        | vcs               | rpc                                                                       |
      | subscribeWorktreeSetup                   | worktreeSetup     | shape worktreeSetup                                                       |
      | worktreeSetup.cancel                     | worktreeSetup     | rpc                                                                       |
      | git.runStackedAction                     | git               | shape gitAction                                                           |
      | git.resolvePullRequest                   | git               | rpc                                                                       |
      | git.preparePullRequestThread             | git               | rpc                                                                       |
      | vcs.listRefs                             | vcs               | rpc                                                                       |
      | vcs.createWorktree                       | vcs               | rpc                                                                       |
      | vcs.removeWorktree                       | vcs               | rpc                                                                       |
      | vcs.createRef                            | vcs               | rpc                                                                       |
      | vcs.switchRef                            | vcs               | rpc                                                                       |
      | vcs.init                                 | vcs               | rpc                                                                       |
      | review.getDiffPreview                    | review            | rpc                                                                       |
      | review.getDiffFileContents               | review            | rpc                                                                       |
      | terminal.open                            | terminal          | rpc                                                                       |
      | terminal.attach                          | terminal          | shape terminal                                                            |
      | terminal.write                           | terminal          | rpc                                                                       |
      | terminal.resize                          | terminal          | rpc                                                                       |
      | terminal.clear                           | terminal          | rpc                                                                       |
      | terminal.restart                         | terminal          | rpc                                                                       |
      | terminal.close                           | terminal          | rpc                                                                       |
      | terminal.list                            | terminal          | rpc                                                                       |
      | preview.open                             | preview           | rpc                                                                       |
      | preview.navigate                         | preview           | rpc                                                                       |
      | preview.resize                           | preview           | rpc                                                                       |
      | preview.refresh                          | preview           | rpc                                                                       |
      | preview.close                            | preview           | rpc                                                                       |
      | preview.list                             | preview           | rpc                                                                       |
      | preview.reportStatus                     | preview           | rpc                                                                       |
      | previewAutomation.connect                | previewAutomation | shape previewAutomation                                                   |
      | previewAutomation.respond                | previewAutomation | rpc                                                                       |
      | previewAutomation.focusHost              | previewAutomation | rpc                                                                       |
      | subscribePreviewEvents                   | preview           | shape preview                                                             |
      | subscribeDiscoveredLocalServers          | preview           | shape localServers                                                        |
      | device.testHost                          | device            | rpc                                                                       |
      | device.list                              | device            | rpc                                                                       |
      | device.configure                         | device            | rpc                                                                       |
      | device.open                              | device            | rpc                                                                       |
      | device.close                             | device            | rpc                                                                       |
      | device.shutdown                          | device            | rpc                                                                       |
      | device.detail                            | device            | rpc                                                                       |
      | device.action                            | device            | rpc                                                                       |
      | subscribeDeviceState                     | device            | shape devices                                                             |
      | orchestration.dispatchCommand            | orchestration     | rpc                                                                       |
      | orchestration.getTurnDiff                | orchestration     | rpc                                                                       |
      | orchestration.getFullThreadDiff          | orchestration     | rpc                                                                       |
      | orchestration.searchThreads              | orchestration     | rpc                                                                       |
      | orchestration.getArchivedShellSnapshot   | orchestration     | rpc                                                                       |
      | orchestration.getThreadProjection        | orchestration     | rpc as hal-c2.threadRows                                                      |
      | orchestration.getWorkflowScript          | orchestration     | rpc                                                                       |
      | orchestration.launchThread               | orchestration     | rpc                                                                       |
      | orchestration.subscribeShell             | orchestration     | shape shell                                                               |
      | orchestration.subscribeThread            | orchestration     | shape stream                                                              |
      | subscribeTerminalMetadata                | terminal          | shape terminals                                                           |
      | subscribeServerConfig                    | server            | shape config                                                              |
      | subscribeServerLifecycle                 | server            | shape config                                                              |
      | scheduledTasks.list                      | scheduledTasks    | rpc                                                                       |
      | scheduledTasks.subscribe                 | scheduledTasks    | shape scheduledTasks                                                      |
      | scheduledTasks.upsert                    | scheduledTasks    | rpc                                                                       |
      | scheduledTasks.setEnabled                | scheduledTasks    | rpc                                                                       |
      | scheduledTasks.delete                    | scheduledTasks    | rpc                                                                       |
      | scheduledTasks.runNow                    | scheduledTasks    | rpc                                                                       |
      | subscribeAuthAccess                      | auth              | shape authAccess                                                          |
      | subscribeBackgroundPolicy                | server            | client adapter: reads server.getBackgroundPolicy once, then holds         |
      | subscribeResourceTelemetry               | server            | shape resourceTelemetry                                                   |
      | cloud.getRelayClientStatus               | cloud             | rpc                                                                       |
      | cloud.installRelayClient                 | cloud             | shape relayClientInstall                                                  |

  # The node refuses these as unserved methods: desktop update handoff is replaced by hot
  # upgrades, the archived-shell subscription has no subscriber, and terminal events arrive
  # through the terminal shape.
  @dropped @node
  Scenario Outline: The node does not serve <method>
    When the client calls <method>
    Then the node answers that the method is not served

    Examples: 3 dropped methods
      | method                               | domain        | reason                                                                    |
      | server.commitDesktopUpdate           | server        | desktop-app update handoff; nodes upgrade themselves in place             |
      | orchestration.subscribeArchivedShell | orchestration | no client subscribes; archived threads come from getArchivedShellSnapshot |
      | subscribeTerminalEvents              | terminal      | protocol 3 clients attach with the terminal shape                         |

  # These names exist in WS_METHODS but have no Rpc.make definition, and neither the
  # TypeScript server nor the node routes them. Projects are listed through the shell
  # snapshot and changed through projects.mutate.
  @dropped @node
  Scenario Outline: The contract name <method> is not a method
    When the client calls <method>
    Then the node answers that the method is not served

    Examples: 3 method names with no RPC definition
      | method          | instead                                  |
      | projects.add    | projects.mutate with a project.create    |
      | projects.list   | the projects in the shell snapshot       |
      | projects.remove | projects.mutate with a project.delete    |

  @node
  Scenario Outline: The node serves its own <method>
    When the client calls <method>
    Then the node answers with <result>

    Examples: node-only methods behind aligned contract methods
      | method                  | result                                                        |
      | hal-c2.readSettings     | the settings document with its version                        |
      | hal-c2.writeSettings    | the new version, or a stale-settings error for an old version |
      | hal-c2.threadRows       | one thread's stream rows with their offset and time           |
      | hal-c2.upsertKeybinding | the keybindings after the change                              |
      | hal-c2.removeKeybinding | the keybindings after the removal                             |

  @node
  Scenario: A method outside the contract is refused
    When the client calls "server.doesNotExist"
    Then the node answers that the method is not served
