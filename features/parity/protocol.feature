# Sources:
#   apps/server-ex/lib/hal_c2/web/protocol.ex (@version 3, client and server frames, shapes, decode)
#   apps/server-ex/lib/hal_c2/web/socket.ex (hello, snapshot, events, live, resync, end, shell.*, config.*, rpc.*)
#   apps/server-ex/lib/hal_c2/web/router.ex (GET /ws)
#   apps/server-ex/lib/hal_c2/web/wire.ex (snapshot rows and event patches on the wire)
#   packages/client-runtime/src/v3/clusterSocket.ts (19 of the shape types, hello, resync, end)
#   packages/client-runtime/src/v3/session.ts (methods a protocol 3 environment does not serve yet;
#     updateSettings writes the whole settings document back)
#   packages/client-runtime/src/connection/compatibility.ts (SHAPE_PROTOCOL_VERSION, negotiation)
#   packages/contracts/src/rpc.ts (the subscription methods each shape replaces)
#   Counts: 5 client frames, 21 shape types (31 rows: the 10 routed shapes have an MC and an
#   environment form), 40 server frame types, 8 refusal reasons; all aligned, 1 dropped. The legacy client adapter
#   carries neither providerInstall nor relayClientInstall.
#   Behaviour of a single subscription (resume, merge, resync timing) lives in
#   mc/platform/websocket-protocol.feature. This file is the frame-by-frame ledger.

Feature: Protocol 3 wire parity
  A protocol 3 client talks to an MC over one WebSocket of JSON text frames. It subscribes to
  shapes, keeps each in sync from an offset, and calls methods with rpc frames. Every stream
  the TypeScript server offered as a subscription method is a shape here.

  Background:
    Given an MC
    And a protocol 3 client connected to it

  @mc
  Scenario: The MC greets every socket with its protocol version, name and environment
    When the client opens its socket
    Then the first frame is a hello carrying protocol 3, the MC's name and its environment

  @mc
  Scenario Outline: The MC answers a <frame> frame
    When the client sends a <frame> frame with <fields>
    Then the MC answers with <answer>

    Examples: 5 client frames
      | frame | fields                                    | answer                                      |
      | sub   | id, shape, offset (a number or null)      | the shape's first frames under that id      |
      | more  | id, items                                 | a page under that id                        |
      | unsub | id                                        | nothing further under that id               |
      | ping  | none                                      | a pong                                      |
      | rpc   | id, environment, method, optional payload | an rpc.result or an rpc.error under that id |

  @mc
  Scenario Outline: A <shape> subscription opens with <first frame>
    When the client subscribes to a <shape> shape with <fields>
    Then the first frame under that id is <first frame>
    And later changes arrive as <later frames>
    And the shape stands in for <replaces>

    # Routed by environment (HalC2.Web.Protocol.routed/0): stream, terminal, terminals, config,
    # vcs, gitAction, worktreeSetup, providerAuth and pullRequestRefreshes, which a client
    # needs for a thread on any machine, and projectClones, for a clone it started on any
    # machine; the environment form goes to this MC or the cluster member with that
    # environment (connections/cluster.feature). Every rpc is routed the same way,
    # but the paired-clients methods, which answer for the caller's own session. Not routed:
    # shell and authAccess are about the MC the client talks to; scheduledTasks,
    # preview, previewAutomation, resourceTelemetry, localServers, devices,
    # serverUpdate, providerInstall and relayClientInstall administer one MC's host, which
    # a client reaches by pairing with it.
    # previewAutomation: the MC's broker and the TypeScript PreviewAutomationBroker both
    # send the host a connected event as it subscribes, before any agent request.
    Examples: 31 shape forms
      | shape                | fields                  | first frame                                                     | later frames                                                                                                           | replaces                                                          |
      | shell                | none                    | a shell frame with every MC and every row                       | shell.rows, shell.environment and shell.mc frames                                                                      | orchestration.subscribeShell                                      |
      | stream               | mc, stream              | snapshot parts, the first with part 0                           | events frames after a live frame, or a resync                                                                          | orchestration.subscribeThread                                     |
      | stream               | environment, stream     | the same frames as the MC form for the environment's MC         | the same frames as the MC form                                                                                         | orchestration.subscribeThread                                     |
      | config               | mc                      | a config frame, then config.themes and config.usageLimitSources | config.settings, config.providers, config.keybindings, config.themes, config.usageLimitSources and config.ready frames | server.getConfig, subscribeServerConfig, subscribeServerLifecycle |
      | config               | environment             | the same frames as the MC form for the environment's MC         | the same frames as the MC form                                                                                         | server.getConfig, subscribeServerConfig, subscribeServerLifecycle |
      | terminal             | mc, input               | a terminal frame with the terminal's snapshot                   | terminal frames                                                                                                        | terminal.attach                                                   |
      | terminal             | environment, input      | the same frames as the MC form for the environment's MC         | the same frames as the MC form                                                                                         | terminal.attach                                                   |
      | terminals            | mc                      | a terminals frame                                               | terminals frames                                                                                                       | subscribeTerminalMetadata                                         |
      | terminals            | environment             | the same frames as the MC form for the environment's MC         | the same frames as the MC form                                                                                         | subscribeTerminalMetadata                                         |
      | vcs                  | mc, cwd                 | a vcs frame with the checkout's status                          | vcs frames                                                                                                             | subscribeVcsStatus                                                |
      | vcs                  | environment, cwd        | the same frames as the MC form for the environment's MC         | the same frames as the MC form                                                                                         | subscribeVcsStatus                                                |
      | providerAuth         | mc, instanceId          | a providerAuth frame with the sign-in state                     | providerAuth frames                                                                                                    | provider.auth.subscribe                                           |
      | providerAuth         | environment, instanceId | the same frames as the MC form for the environment's MC         | the same frames as the MC form                                                                                         | provider.auth.subscribe                                           |
      | worktreeSetup        | mc, threadId            | a worktreeSetup frame, null or a snapshot                       | worktreeSetup frames                                                                                                   | subscribeWorktreeSetup                                            |
      | worktreeSetup        | environment, threadId   | the same frames as the MC form for the environment's MC         | the same frames as the MC form                                                                                         | subscribeWorktreeSetup                                            |
      | scheduledTasks       | mc                      | a scheduledTasks frame with every task                          | scheduledTasks frames with the whole list                                                                              | scheduledTasks.subscribe                                          |
      | authAccess           | none                    | an authAccess frame with links and paired clients               | authAccess frames                                                                                                      | subscribeAuthAccess                                               |
      | projectClones        | mc                      | a projectClones frame with every clone in progress              | projectClones frames with the whole list                                                                               | subscribeProjectClones                                            |
      | projectClones        | environment             | the same frames as the MC form for the environment's MC         | the same frames as the MC form                                                                                         | subscribeProjectClones                                            |
      | preview              | mc                      | nothing until a preview tab changes                             | preview frames                                                                                                         | subscribePreviewEvents                                            |
      | resourceTelemetry    | mc                      | a resourceTelemetry frame                                       | a resourceTelemetry frame every few seconds while subscribed                                                           | subscribeResourceTelemetry                                        |
      | localServers         | mc                      | a localServers frame with the current list                      | localServers frames whenever the list changes                                                                          | subscribeDiscoveredLocalServers                                   |
      | devices              | mc                      | a devices frame with the whole device state                     | devices frames with the whole state                                                                                    | subscribeDeviceState                                              |
      | previewAutomation    | mc, host                | a previewAutomation frame saying it is connected                | previewAutomation frames                                                                                               | previewAutomation.connect                                         |
      | pullRequestRefreshes | mc                      | a pullRequestRefreshes frame with the revision                  | pullRequestRefreshes frames with each new revision                                                                     | pullRequests.subscribeRefreshes                                   |
      | pullRequestRefreshes | environment             | the same frames as the MC form for the environment's MC         | the same frames as the MC form                                                                                         | pullRequests.subscribeRefreshes                                   |
      | gitAction            | mc, input               | a gitAction frame as the action starts                          | gitAction progress frames                                                                                              | git.runStackedAction                                              |
      | gitAction            | environment, input      | the same frames as the MC form for the environment's MC         | the same frames as the MC form                                                                                         | git.runStackedAction                                              |
      | serverUpdate         | mc, input               | a serverUpdate frame as the update starts                       | serverUpdate progress frames                                                                                           | server.updateServerWithProgress                                   |
      | providerInstall      | mc, instanceId          | a providerInstall frame with the install state                  | providerInstall frames                                                                                                 | provider.install.subscribe                                        |
      | relayClientInstall   | mc                      | a relayClientInstall frame as the install checks                | relayClientInstall frames, then an end frame                                                                           | cloud.installRelayClient                                          |

  @mc
  Scenario Outline: A <shape> subscription ends on its own
    Given the client is subscribed to a <shape> shape
    When <ending>
    Then the MC sends <last frames>
    And the MC forgets the subscription

    Examples: shapes with an end
      | shape              | ending                                 | last frames                                                 |
      | gitAction          | the action finishes or fails           | a gitAction frame with action_finished or action_failed     |
      | serverUpdate       | the update completes                   | a serverUpdate frame with complete, then an end frame       |
      | serverUpdate       | the update fails                       | an error frame with the reason and its detail               |
      | previewAutomation  | the MC drops the client as its host    | an end frame                                                |
      | relayClientInstall | the relay client is found or installed | a relayClientInstall frame with complete, then an end frame |

  @mc
  Scenario Outline: The MC sends <frame> frames
    Given the client is subscribed to a shape that uses <frame> frames
    When <when>
    Then the client receives a <frame> frame carrying <fields>

    Examples: 32 socket, stream, config and MC frames
      | frame                    | when                                                   | fields                                                        |
      | hello                    | the socket opens                                       | protocol, mc, environment                                     |
      | pong                     | the client pings                                       | nothing else                                                  |
      | error                    | a frame or subscription is refused                     | reason, and the id when there is one                          |
      | rpc.result               | a method succeeds                                      | id, result                                                    |
      | rpc.error                | a method fails                                         | id, error, and the contract error as detail when there is one |
      | shell                    | the shell subscription opens                           | id, MCs with online, environment and version, rows            |
      | shell.rows               | projects or threads on one MC change                   | id, mc, rows, the version they bring the MC to                |
      | shell.environment        | an MC's environment descriptor changes                 | id, mc, environment                                           |
      | shell.mc                 | an MC joins or leaves the cluster                      | id, mc, online, and removed once it is no longer a member     |
      | snapshot                 | a stream subscription starts without a usable offset   | id, offset, at, part, rows in creation order, done, handle    |
      | events                   | stream entities change                                 | id, offset, events as seq, kind, id, patch and unix ms at     |
      | live                     | a stream has caught up                                 | id, offset, handle                                            |
      | page                     | a client asks for the runs before its window           | id, offset, rows, floor, done                                 |
      | resync                   | a client falls behind                                  | id, the offset to resubscribe from                            |
      | end                      | a shape is over                                        | id                                                            |
      | config                   | a config subscription opens                            | id, mc, the MC's server config                                |
      | config.ready             | the MC moves to another version in place               | id, new environment descriptor, update outcome                |
      | config.settings          | the MC's settings change                               | id, settings                                                  |
      | config.themes            | the MC's published themes change                       | id, themes                                                    |
      | config.usageLimitSources | the MC's usage limit sources change                    | id, sources                                                   |
      | config.keybindings       | the MC's keybinding rules change                       | id, the whole rule list                                       |
      | config.providers         | the MC's providers change                              | id, providers                                                 |
      | terminal                 | an attached terminal emits                             | id, event                                                     |
      | terminals                | terminal summaries change                              | id, event                                                     |
      | vcs                      | a checkout's status changes                            | id, event                                                     |
      | providerAuth             | a provider's sign-in state changes                     | id, state                                                     |
      | providerInstall          | a managed runtime installation progresses              | id, state                                                     |
      | worktreeSetup            | a thread's worktree setup progresses                   | id, event                                                     |
      | scheduledTasks           | a scheduled task changes                               | id, tasks                                                     |
      | authAccess               | a pairing link or paired client changes                | id, event                                                     |
      | projectClones            | a project clone progresses                             | id, clones                                                    |
      | pullRequestRefreshes     | pull requests are refreshed                            | id, revision                                                  |

  @mc
  Scenario Outline: The MC sends <frame> frames for its host
    Given the client is subscribed to a <shape> shape
    When <when>
    Then the client receives a <frame> frame carrying <fields>

    Examples: host frames
      | frame              | shape              | when                                            | fields       |
      | preview            | preview            | a preview tab changes                           | id, event    |
      | previewAutomation  | previewAutomation  | an agent drives the client's browser            | id, event    |
      | resourceTelemetry  | resourceTelemetry  | the resource monitor takes a sample             | id, snapshot |
      | localServers       | localServers       | a web server starts or stops on the host        | id, list     |
      | devices            | devices            | a simulator, emulator or device session changes | id, state    |
      | gitAction          | gitAction          | a git action progresses                         | id, event    |
      | serverUpdate       | serverUpdate       | a version move progresses                       | id, event    |
      | relayClientInstall | relayClientInstall | the relay client install progresses             | id, event    |

  @mc
  Scenario Outline: The MC refuses <case> with "<reason>"
    When the client sends <case>
    Then the MC answers with a <frame> frame whose reason is "<reason>"
    And the socket stays open

    Examples: 8 refusal reasons
      | case                                                          | frame     | reason                  |
      | text that is not JSON                                         | error     | invalid json            |
      | a frame with an unknown or missing type                       | error     | unknown message         |
      | a subscription to a shape type the MC does not know           | error     | unknown shape           |
      | a subscription naming an MC outside the cluster               | error     | unknown MC              |
      | a config subscription for an unknown environment              | error     | unknown environment     |
      | an authAccess subscription from a session without access:read | error     | access:read is required |
      | an rpc for an unknown environment                             | rpc.error | unknown environment     |
      | an rpc whose MC has gone away                                 | rpc.error | MC unavailable          |

  @mc
  Scenario: Activity reports go to the MC's background policy without a reply payload
    When the client calls server.reportClientActivity in an rpc frame
    Then the MC records the activity lease for the client's session and socket
    And the rpc.result carries no result

  @mc
  Scenario: Methods a protocol 3 environment does not serve fail in the client
    When a client calls a method the protocol 3 adapter does not carry
    Then the call fails in the client saying the method is not served by protocol-3 environments yet
    And no frame is sent to the MC

  # The adapter writes the whole settings document back (session.ts updateSettings); load
  # balancing is a setting it does not name (settings/load-balancing.feature).
  @mc
  Scenario: The client adapter leaves settings it does not know as they were
    Given the MC's settings have load balancing on and a machine preferred
    When a client changes another setting through the protocol 3 adapter
    Then the other setting is changed
    And load balancing is still on with the machine preferred

  # The MC speaks only protocol 3. Clients negotiate from the environment descriptor
  # (compatibility.ts) and use the protocol 3 adapter, so the MC does not also serve the
  # TypeScript server's Effect RPC wire protocol on /ws.
  @dropped @mc
  Scenario: A client speaking the TypeScript RPC wire protocol is served by the MC
    Given a client that speaks only the TypeScript server's orchestration protocol
    When it connects to the MC's socket
    Then the MC serves its requests
